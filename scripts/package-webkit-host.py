#!/usr/bin/env python3
"""Stage a separately linked owned-WebKit host inside a NeAntik app.

The host must already reference the bundled WebKit and must not link SwiftUI
or the system Swift WebKit overlay. A manager copy is rejected before signing.
Staging alone does not qualify startup or network isolation.
"""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
from webkit_runtime_notices import install_owned_webkit_notices, preflight_owned_webkit_notices

PRODUCTION_BUNDLE_ID = "app.neantik.desktop"
DEVELOPMENT_BUNDLE_ID = "app.neantik.desktop.dev"
HOST_BUNDLE_ID = PRODUCTION_BUNDLE_ID + ".webkit-host"
HOST_BUNDLE_RELATIVE_PATH = Path("Contents/Helpers/webkit-v1/NeAntikWebKitHost.app")
HOST_EXECUTABLE_RELATIVE_PATH = HOST_BUNDLE_RELATIVE_PATH / "Contents/MacOS/NeAntikWebKitHost"
PIN_KEY = "NeAntikWebKitHostV1"
RUNTIME_PIN_KEY = "NeAntikWebKitRuntimeV1"
NETWORK_PROCESS_PIN_KEY = "NeAntikWebKitNetworkProcessV1"
NETWORK_PROCESS_ID = "app.neantik.desktop.webkit.Networking"
RELEASE_XPC_ENTITLEMENTS: dict[str, dict[str, object]] = {
    "app.neantik.desktop.webkit.Networking": {
        "com.apple.security.fatal-exceptions": ["jit"],
    },
    "app.neantik.desktop.webkit.GPU": {
        "com.apple.security.fatal-exceptions": ["jit"],
    },
    "app.neantik.desktop.webkit.WebContent": {
        "com.apple.security.cs.allow-jit": True,
        "com.apple.security.fatal-exceptions": ["jit"],
    },
    "app.neantik.desktop.webkit.WebContent.CaptivePortal": {
        "com.apple.security.fatal-exceptions": ["jit"],
    },
    "app.neantik.desktop.webkit.WebContent.EnhancedSecurity": {
        "com.apple.security.fatal-exceptions": ["jit"],
    },
}
SYSTEM_WEBKIT_LOAD = "/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit"
OWNED_WEBKIT_LOAD = "@rpath/WebKit.framework/Versions/A/WebKit"
OWNED_WEBKIT_RPATH = "@executable_path/../Frameworks"
NETWORK_PROCESS_RELATIVE_PATH = Path(
    "WebKit.framework/Versions/A/XPCServices/"
    + NETWORK_PROCESS_ID + ".xpc"
)
TEAM_ID = "H6VGU2M6JD"
HOST_ENTITLEMENTS: dict[str, object] = {}
QA_HTTP_FIXTURE_ATS = {
    "NSExceptionDomains": {
        "127.0.0.1": {"NSExceptionAllowsInsecureHTTPLoads": True},
        "neantik-proxy-qa.invalid": {"NSExceptionAllowsInsecureHTTPLoads": True},
        "neantik-second-qa.invalid": {"NSExceptionAllowsInsecureHTTPLoads": True},
    }
}
QA_TLS_SCOPE_KEY = "NeAntikQATrustScope"
SYSTEM_ENGINE_FRAMEWORKS = (
    "WebKit.framework",
    "WebCore.framework",
    "JavaScriptCore.framework",
    "WebGPU.framework",
    "WebKitLegacy.framework",
)
MACHO_MAGICS = {bytes.fromhex(value) for value in (
    "cffaedfe", "cefaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"
)}


class ContractError(ValueError):
    pass


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def read_info(path: Path, allow_development_qa: bool = False) -> dict:
    for directory in (path, path / "Contents"):
        if directory.is_symlink() or not directory.is_dir():
            raise ContractError("Manager bundle path must contain physical directories")
    info_path = path / "Contents/Info.plist"
    if info_path.is_symlink() or not info_path.is_file():
        raise ContractError("Manager Info.plist must be a regular file")
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    allowed_ids = {PRODUCTION_BUNDLE_ID}
    if allow_development_qa:
        allowed_ids.add(DEVELOPMENT_BUNDLE_ID)
    if not isinstance(info, dict) or info.get("CFBundleIdentifier") not in allowed_ids:
        raise ContractError("Unexpected manager bundle identity")
    return info


def host_ats_policy(manager_id: str, allow_development_qa: bool,
                    qa_tls_origins: list[str] | None = None) -> dict:
    """Permit only exact synthetic QA origins in the isolated Dev host.

    QA18/19 omitted the QA17 exceptions and WKNavigation returned ATS -1022
    before a proxy request could reach the broker. Public hosts retain the
    platform default ATS policy.
    """
    if allow_development_qa and manager_id == DEVELOPMENT_BUNDLE_ID:
        # ATS can still reject a test CA after the WKNavigationDelegate has
        # accepted its SecTrust. The exception must name the exact synthetic
        # HTTPS host, and must never be copied into the production host.
        domains = dict(QA_HTTP_FIXTURE_ATS["NSExceptionDomains"])
        for origin in qa_tls_origins or []:
            parsed = urlsplit(origin)
            if (parsed.scheme != "https" or parsed.username or parsed.password
                    or parsed.path or parsed.query or parsed.fragment
                    or parsed.hostname is None or parsed.port is None
                    or not parsed.hostname.endswith(".invalid")):
                raise ContractError("QA TLS ATS origin must be an exact synthetic HTTPS origin")
            domains[parsed.hostname] = {"NSExceptionAllowsInsecureHTTPLoads": True}
        return {"NSAppTransportSecurity": {"NSExceptionDomains": domains}}
    return {}


def host_qa_tls_scope(manager_id: str, allow_development_qa: bool,
                      anchor_der: bytes | None, origins: list[str]) -> dict:
    """Bind a synthetic TLS trust anchor to the signed Dev host only.

    The anchor is public certificate data. Production hosts and ordinary Dev
    hosts retain macOS trust without any override. Refuse partial or broad QA
    scopes before staging, so a bad fixture does not cost another notarization.
    """
    if anchor_der is None and not origins:
        return {}
    if not allow_development_qa or manager_id != DEVELOPMENT_BUNDLE_ID:
        raise ContractError("QA TLS trust is allowed only in an explicit Dev host")
    if not isinstance(anchor_der, bytes) or not 256 <= len(anchor_der) <= 32768:
        raise ContractError("QA TLS anchor must be one bounded DER certificate")
    try:
        certificate = subprocess.run(
            ["/usr/bin/openssl", "x509", "-inform", "DER", "-noout"],
            input=anchor_der, capture_output=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ContractError("QA TLS anchor parser unavailable") from error
    if certificate.returncode != 0:
        raise ContractError("QA TLS anchor is not an X.509 DER certificate")
    if not 1 <= len(origins) <= 4 or len(set(origins)) != len(origins):
        raise ContractError("QA TLS origins must be one to four distinct exact URLs")
    for value in origins:
        if not isinstance(value, str) or not re.fullmatch(
                r"https://[a-z0-9][a-z0-9.-]*\.invalid:[1-9][0-9]{0,4}", value):
            raise ContractError("QA TLS origin must be an exact synthetic HTTPS host and port")
        parsed = urlsplit(value)
        try:
            port = parsed.port
        except ValueError as error:
            raise ContractError("QA TLS origin port is invalid") from error
        if parsed.hostname is None or port is None or not 1 <= port <= 65535:
            raise ContractError("QA TLS origin port is invalid")
        labels = parsed.hostname.split(".")
        if (len(parsed.hostname) > 253 or len(labels) < 2 or labels[-1] != "invalid"
                or any(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) is None
                       for label in labels)):
            raise ContractError("QA TLS origin hostname is invalid")
    return {QA_TLS_SCOPE_KEY: {"anchorDER": anchor_der, "origins": origins}}


def verify_host_binary(path: Path) -> None:
    if path.is_symlink() or not path.is_file():
        raise ContractError("WebKit host executable must be a regular file")
    status = path.stat(follow_symlinks=False)
    if not status.st_mode & stat.S_IXUSR or status.st_size < 4:
        raise ContractError("WebKit host executable is missing or not executable")
    with path.open("rb") as stream:
        if stream.read(4) not in MACHO_MAGICS:
            raise ContractError("WebKit host executable is not a Mach-O file")


def verify_runtime_webkit_linkage(path: Path) -> None:
    """Require the helper to load the bundled WebKit through its own Frameworks.

    The shipped manager links to /System/Library/Frameworks/WebKit.framework.
    Copying that binary into a nested app does not switch its engine. A runtime
    host must have one exact @rpath WebKit load command and one private-bundle
    rpath; system WebKit, fallback rpaths, and multiple loads are refused.
    """
    try:
        linked = subprocess.run(["/usr/bin/otool", "-L", str(path)], check=True,
                                capture_output=True, text=True).stdout
        load_commands = subprocess.run(["/usr/bin/otool", "-l", str(path)], check=True,
                                       capture_output=True, text=True).stdout
    except subprocess.SubprocessError as error:
        raise ContractError("Could not inspect WebKit host load commands") from error
    if "libswiftWebKit" in linked:
        raise ContractError("Host links the system Swift WebKit overlay, which re-exports the system engine")
    # The manager carries SwiftUI even when its early child branch never
    # constructs a SwiftUI view. Exact notarized QA2d8f still loaded both
    # system and owned WebKit. Do not turn another manager copy into a host;
    # require a separately linked, narrow host executable instead.
    if "/System/Library/Frameworks/SwiftUI.framework/" in linked:
        raise ContractError("WebKit host must be linked separately without the SwiftUI manager framework")
    for framework in SYSTEM_ENGINE_FRAMEWORKS:
        if f"/System/Library/Frameworks/{framework}/" in linked:
            raise ContractError("Host links a system browser engine alongside the owned runtime")
    dependencies = [line.strip().split(" (compatibility", 1)[0]
                    for line in linked.splitlines()
                    if "WebKit.framework/Versions/A/WebKit" in line]
    if dependencies != [OWNED_WEBKIT_LOAD]:
        raise ContractError("Host must link only to the bundled WebKit framework")
    rpaths = []
    commands = load_commands.split("cmd LC_RPATH")
    for command in commands[1:]:
        match = re.search(r"^\s*path\s+(.+?)\s+\(offset\s+\d+\)", command, re.MULTILINE)
        if not match:
            raise ContractError("Malformed WebKit host runtime search path")
        rpaths.append(match.group(1))
    if rpaths.count(OWNED_WEBKIT_RPATH) != 1:
        raise ContractError("Host must have one private-framework runtime search path")
    allowed_rpaths = {OWNED_WEBKIT_RPATH, "@loader_path", "/usr/lib/swift"}
    if any(rpath not in allowed_rpaths for rpath in rpaths):
        raise ContractError("Host contains an unapproved runtime search path")


def derive_owned_webkit_host(manager_app: Path, manager_binary: Path,
                             destination: Path, allow_development_qa: bool = False) -> Path:
    """Retained rejection path for a manager passed as the host input.

    The old copy-and-rebind route produced mixed engine images on exact QA2d8f.
    A SwiftUI-linked manager is refused before any destination is written.
    """
    info = read_info(manager_app, allow_development_qa=allow_development_qa)
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,200}", executable_name):
        raise ContractError("Manager bundle executable name is invalid")
    executable_directory = manager_app / "Contents/MacOS"
    if executable_directory.is_symlink() or not executable_directory.is_dir():
        raise ContractError("Manager executable directory must be physical")
    expected_source = executable_directory / executable_name
    if (manager_binary.is_symlink() or not manager_binary.is_file()
            or manager_binary.resolve(strict=True) != expected_source.resolve(strict=True)):
        raise ContractError("Only the exact executable inside this NeAntik app can be rebound")
    verify_host_binary(manager_binary)
    try:
        linked = subprocess.run(["/usr/bin/otool", "-L", str(manager_binary)], check=True,
                                capture_output=True, text=True).stdout
    except (OSError, subprocess.SubprocessError) as error:
        raise ContractError("Could not inspect the manager WebKit load command") from error
    dependencies = [line.strip().split(" (compatibility", 1)[0]
                    for line in linked.splitlines()
                    if "WebKit.framework/Versions/A/WebKit" in line]
    if dependencies != [SYSTEM_WEBKIT_LOAD]:
        raise ContractError("Manager must have exactly one system WebKit load before rebinding")
    if "/System/Library/Frameworks/SwiftUI.framework/" in linked:
        raise ContractError("SwiftUI manager cannot be rebound as an owned WebKit host; build a narrow host executable")

    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(manager_binary, destination)
    shutil.copystat(manager_binary, destination, follow_symlinks=False)
    try:
        subprocess.run(["/usr/bin/install_name_tool", "-change", SYSTEM_WEBKIT_LOAD,
                        OWNED_WEBKIT_LOAD, str(destination)], check=True, capture_output=True)
        subprocess.run(["/usr/bin/install_name_tool", "-add_rpath", OWNED_WEBKIT_RPATH,
                        str(destination)], check=True, capture_output=True)
    except (OSError, subprocess.SubprocessError) as error:
        destination.unlink(missing_ok=True)
        raise ContractError("Could not rebind the isolated host copy to bundled WebKit") from error
    verify_host_binary(destination)
    verify_runtime_webkit_linkage(destination)
    return destination


def parse_cdhash(output: str) -> str:
    matches = re.findall(r"^CDHash=([0-9a-fA-F]{40})$", output, re.MULTILINE)
    if len(matches) != 1:
        raise ContractError("The nested host signature did not expose a CodeDirectory hash")
    return matches[0].lower()


def verify_signing_identity(identity: str, expected_team: str = TEAM_ID) -> None:
    """Fail before staging unless the selected, existing identity is usable.

    Public releases default to TEAM_ID. A recipient relink may opt into the
    team already used by the signed manager copy; all runtime images and the
    selected identity must still match that one team.
    """
    if not identity or identity == "-":
        raise ContractError("WebKit host requires the existing NeAntik Developer ID; ad-hoc signing cannot load the runtime")
    try:
        output = subprocess.run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
                                check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.SubprocessError) as error:
        raise ContractError("Could not verify the existing WebKit host signing identity") from error
    candidates = re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"\s*$',
                            output, re.MULTILINE)
    selected = [(sha1, name) for sha1, name in candidates
                if identity.lower() == sha1.lower() or identity == name]
    if len(selected) != 1 or not selected[0][1].startswith("Developer ID Application:"):
        raise ContractError("Selected signing identity is unavailable or is not a Developer ID Application identity")
    team = re.search(r"\(([A-Z0-9]{10})\)$", selected[0][1])
    if team is None or team.group(1) != expected_team:
        raise ContractError("Selected signing identity does not match the expected manager team")


def manager_signing_team(app: Path, expected_identifier: str) -> str:
    """Return a strictly validated Developer ID team from this manager copy."""
    executable = app / "Contents/MacOS/NeAntik"
    if executable.is_symlink() or not executable.is_file():
        raise ContractError("Recipient relink requires the manager executable inside the target app")
    commands = (
        ("bundle signature", ["/usr/bin/codesign", "--verify", "--strict", "--deep", str(app)]),
        ("executable signature", ["/usr/bin/codesign", "--verify", "--strict", str(executable)]),
        ("executable identity", ["/usr/bin/codesign", "-dv", "--verbose=4", str(executable)]),
    )
    detail = ""
    for stage, argv in commands:
        try:
            result = subprocess.run(argv, check=True, capture_output=True, text=True)
        except (OSError, subprocess.SubprocessError) as error:
            # Do not surface raw codesign stderr: paths and local identities may
            # be sensitive. A sandbox denial here is setup, not proof of a bad
            # signature; the stage label permits one authoritative recheck.
            raise ContractError(f"Recipient manager {stage} check unavailable or failed") from error
        if stage == "executable identity":
            detail = result.stderr
    fields = dict(re.findall(r"^(Identifier|TeamIdentifier)=([^\r\n]+)$", detail, re.MULTILINE))
    team = fields.get("TeamIdentifier", "")
    if fields.get("Identifier") != expected_identifier or not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ContractError("Signed manager identity is not a valid Developer ID team")
    return team


def pinned_info(info: dict, executable_sha256: str, cdhash: str,
                host_bundle_id: str = HOST_BUNDLE_ID) -> dict:
    if not re.fullmatch(r"[0-9a-f]{64}", executable_sha256):
        raise ContractError("Invalid helper SHA-256")
    if not re.fullmatch(r"[0-9a-f]{40}", cdhash):
        raise ContractError("Invalid helper CDHash")
    result = dict(info)
    result[PIN_KEY] = {
        "schemaVersion": 1,
        "identifier": host_bundle_id,
        "sha256": executable_sha256,
        "cdHash": cdhash,
    }
    return result


def network_process_pin(runtime_frameworks: Path, expected_team: str = TEAM_ID) -> dict:
    """Pin the exact signed WebKit Networking XPC executable for live checks."""
    service = runtime_frameworks / NETWORK_PROCESS_RELATIVE_PATH
    contents = service / "Contents"
    info_path = contents / "Info.plist"
    for directory in (runtime_frameworks / "WebKit.framework",
                      runtime_frameworks / "WebKit.framework/Versions",
                      runtime_frameworks / "WebKit.framework/Versions/A",
                      runtime_frameworks / "WebKit.framework/Versions/A/XPCServices",
                      service, contents, contents / "MacOS"):
        if directory.is_symlink() or not directory.is_dir():
            raise ContractError("Runtime Networking XPC path is missing or unsafe")
    if info_path.is_symlink() or not info_path.is_file():
        raise ContractError("Runtime Networking XPC Info.plist is missing or unsafe")
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    executable_name = info.get("CFBundleExecutable") if isinstance(info, dict) else None
    if (not isinstance(info, dict)
            or info.get("CFBundleIdentifier") != NETWORK_PROCESS_ID
            or info.get("CFBundlePackageType") != "XPC!"
            or not isinstance(executable_name, str)
            or not re.fullmatch(r"[A-Za-z0-9._-]{1,200}", executable_name)
            or executable_name in (".", "..")):
        raise ContractError("Runtime Networking XPC identity is not the expected owned service")
    executable = contents / "MacOS" / executable_name
    if executable.is_symlink() or not executable.is_file():
        raise ContractError("Runtime Networking XPC executable is missing or unsafe")
    with executable.open("rb") as stream:
        if stream.read(4) not in MACHO_MAGICS:
            raise ContractError("Runtime Networking XPC executable is not a Mach-O file")
    try:
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(service)],
                       check=True, capture_output=True)
        detail = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(service)],
                                check=True, capture_output=True, text=True).stderr
    except (OSError, subprocess.SubprocessError) as error:
        raise ContractError("Could not verify the signed Networking XPC service") from error
    if (f"Identifier={NETWORK_PROCESS_ID}" not in detail
            or f"TeamIdentifier={expected_team}" not in detail):
        raise ContractError("Runtime Networking XPC is not signed by the expected Developer ID team")
    return {
        "schemaVersion": 1,
        "identifier": NETWORK_PROCESS_ID,
        "executable": executable_name,
        "sha256": digest(executable),
        "cdHash": parse_cdhash(detail),
    }


def verify_release_xpc_entitlements(runtime_frameworks: Path) -> None:
    """Require valid, distribution-mode entitlements in every shipped XPC.

    A strict code signature alone does not prove that macOS can decode the
    embedded entitlement blob. In particular, `codesign --verify` can pass
    while `codesign -d --entitlements` reports that the OS will ignore it.
    """
    xpc_root = runtime_frameworks / "WebKit.framework/Versions/A/XPCServices"
    if xpc_root.is_symlink() or not xpc_root.is_dir():
        raise ContractError("Runtime XPC services directory is missing or unsafe")
    seen: set[str] = set()
    for bundle in sorted(xpc_root.glob("*.xpc")):
        if bundle.is_symlink() or not bundle.is_dir():
            raise ContractError("Runtime XPC bundle must be a physical directory")
        info_path = bundle / "Contents/Info.plist"
        if info_path.is_symlink() or not info_path.is_file():
            raise ContractError("Runtime XPC Info.plist is missing or unsafe")
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
        identifier = info.get("CFBundleIdentifier") if isinstance(info, dict) else None
        expected = RELEASE_XPC_ENTITLEMENTS.get(identifier)
        if expected is None or identifier in seen:
            raise ContractError(f"Unexpected or duplicate release XPC identity: {identifier}")
        seen.add(identifier)
        try:
            result = subprocess.run(
                ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(bundle)],
                check=True, capture_output=True,
            )
            warning = result.stderr.decode("utf-8", "replace").lower()
            if "invalid entitlements blob" in warning or not result.stdout:
                raise ContractError(f"XPC entitlement blob is invalid or empty: {identifier}")
            actual = plistlib.loads(result.stdout)
        except ContractError:
            raise
        except (OSError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
            raise ContractError(f"Could not decode signed XPC entitlements: {identifier}") from error
        if not isinstance(actual, dict):
            raise ContractError(f"Signed XPC entitlement payload is not a plist dictionary: {identifier}")
        if ("com.apple.security.get-task-allow" in actual
                or "com.apple.security.cs.disable-library-validation" in actual):
            raise ContractError(f"Debug entitlement is forbidden in release XPC: {identifier}")
        if actual != expected:
            raise ContractError(f"Signed XPC entitlement mismatch: {identifier}")
    missing = set(RELEASE_XPC_ENTITLEMENTS) - seen
    if missing:
        raise ContractError(f"Release runtime XPC set is incomplete: {', '.join(sorted(missing))}")


def install_info_atomically(path: Path, info: dict) -> None:
    target = path / "Contents/Info.plist"
    original_mode = stat.S_IMODE(target.stat(follow_symlinks=False).st_mode)
    with tempfile.NamedTemporaryFile(prefix=".webkit-host-info-", dir=target.parent, delete=False) as file:
        temporary = Path(file.name)
        file.write(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=True))
        file.flush()
        os.fsync(file.fileno())
    try:
        os.chmod(temporary, original_mode, follow_symlinks=False)
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)


def require_safe_parent_chain(app: Path) -> None:
    current = app / "Contents"
    for component in ("Helpers", "webkit-v1"):
        current = current / component
        if current.is_symlink():
            raise ContractError("Nested helper directory cannot be a symlink")
        if current.exists() and not current.is_dir():
            raise ContractError("Nested helper parent is not a directory")


def verify_runtime_frameworks(path: Path, expected_team: str = TEAM_ID) -> Path:
    """Validate a pre-signed private framework tree before it is staged.

    WebKit's upstream build archive is not signed. Packaging must receive a
    separately signed tree; copying an unsigned framework and letting the
    outer app's signing command silently bless it is not an acceptable trust
    boundary.
    """
    if path.is_symlink() or not path.is_dir():
        raise ContractError("Runtime Frameworks input must be a physical directory")
    root = path.resolve(strict=True)
    for entry in path.rglob("*"):
        if entry.is_symlink():
            try:
                entry.resolve(strict=True).relative_to(root)
            except (OSError, ValueError) as error:
                raise ContractError("Runtime Frameworks contains an unsafe symlink") from error
    webkit = path / "WebKit.framework/Versions/A/WebKit"
    if webkit.is_symlink() or not webkit.is_file():
        raise ContractError("Runtime WebKit image must be a regular versioned file")
    with webkit.open("rb") as stream:
        if stream.read(4) not in MACHO_MAGICS:
            raise ContractError("Runtime WebKit image is not a Mach-O file")
    bundles = [path / entry for entry in path.iterdir()
               if not entry.is_symlink() and entry.is_dir()
               and entry.suffix in {".framework", ".xpc", ".app", ".bundle"}]
    if not bundles:
        raise ContractError("Runtime Frameworks contains no signed code bundles")
    for bundle in bundles:
        try:
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(bundle)],
                           check=True, capture_output=True)
        except subprocess.CalledProcessError as error:
            detail = error.stderr.decode("utf-8", "replace") if isinstance(error.stderr, bytes) else str(error.stderr or "")
            if "a sealed resource is missing or invalid" in detail.lower():
                raise ContractError("Runtime code signature seal does not match its contents") from error
            if "code object is not signed at all" in detail.lower():
                raise ContractError("Runtime bundle contains unsigned code") from error
            if "CSSMERR_TP_NOT_TRUSTED" in detail:
                raise ContractError("Runtime signature chain is not trusted (CSSMERR_TP_NOT_TRUSTED)") from error
            raise ContractError("Runtime code signature verification failed") from error
        except OSError as error:
            raise ContractError("Could not run the code signature verifier") from error

    macho_count = 0
    for binary in path.rglob("*"):
        if binary.is_symlink() or not binary.is_file():
            continue
        with binary.open("rb") as stream:
            if stream.read(4) not in MACHO_MAGICS:
                continue
        macho_count += 1
        try:
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(binary)],
                           check=True, capture_output=True)
            detail = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(binary)],
                                    check=True, capture_output=True, text=True).stderr
        except (OSError, subprocess.SubprocessError) as error:
            raise ContractError("Could not verify a runtime Mach-O signature and identity") from error
        if f"TeamIdentifier={expected_team}" not in detail:
            relative = binary.resolve().relative_to(path.resolve())
            raise ContractError(
                f"Runtime Mach-O image {relative} must use the expected Developer ID team"
            )
        if not any(
            line.startswith("Timestamp=")
            and line.partition("=")[2].strip().lower() not in {"", "none"}
            for line in detail.splitlines()
        ):
            relative = binary.resolve().relative_to(path.resolve())
            raise ContractError(
                f"Runtime Mach-O image {relative} must have a secure code-signing timestamp"
            )
    if macho_count == 0:
        raise ContractError("Runtime Frameworks contains no Mach-O images")
    verify_no_system_engine_fallbacks(path)
    verify_relocatable_runtime_rpaths(path)
    return webkit


def runtime_minimum_os_version(path: Path) -> str:
    """Return the highest deployment floor declared by every runtime image.

    The owned engine may require a newer macOS than the NeAntik manager. Pin
    this floor into the signed host so the parent can refuse an unsupported OS
    before spawning any WebKit process.
    """
    versions = []
    for binary in sorted(path.rglob("*")):
        if binary.is_symlink() or not binary.is_file():
            continue
        with binary.open("rb") as stream:
            if stream.read(4) not in MACHO_MAGICS:
                continue
        try:
            # Universal Apple Swift libraries may also contain x86_64/arm64e
            # slices and a Mac Catalyst build record. Only the shipped arm64
            # macOS slice determines this application's deployment floor.
            commands = subprocess.run(["/usr/bin/otool", "-l", "-arch", "arm64", str(binary)], check=True,
                                      capture_output=True, text=True).stdout
        except (OSError, subprocess.SubprocessError) as error:
            raise ContractError("Could not read runtime Mach-O deployment target") from error
        macos_records = []
        for block in commands.split("cmd LC_BUILD_VERSION")[1:]:
            fields = {}
            for line in block.splitlines()[:8]:
                parts = line.strip().split()
                if len(parts) == 2 and parts[0] in {"platform", "minos"}:
                    fields[parts[0]] = parts[1]
            if fields.get("platform") == "1":
                macos_records.append(fields)
        if len(macos_records) != 1:
            raise ContractError("Every arm64 runtime Mach-O must target macOS exactly once")
        fields = macos_records[0]
        match = re.fullmatch(r"(\d+)\.(\d+)(?:\.(\d+))?", fields.get("minos", ""))
        if not match:
            raise ContractError("Runtime Mach-O has a missing or malformed minimum macOS version")
        versions.append(tuple(int(value or 0) for value in match.groups()))
    if not versions:
        raise ContractError("Runtime Frameworks contains no versioned Mach-O images")
    major, minor, patch = max(versions)
    return f"{major}.{minor}.{patch}"


def verify_no_system_engine_fallbacks(path: Path) -> None:
    """Reject an embedded runtime that directly loads Apple's system engine.

    Verifying and pinning the outer WebKit image is not enough: a nested
    WebCore/XPC image can still resolve an absolute system WebKit dependency.
    Scan every Mach-O in the supplied Frameworks tree, including XPC services.
    This is a necessary static gate, not proof of the complete dyld closure;
    runtime image attestation remains a separate release requirement.
    """
    root = path.resolve(strict=True)
    for binary in path.rglob("*"):
        if binary.is_symlink() or not binary.is_file():
            continue
        with binary.open("rb") as stream:
            if stream.read(4) not in MACHO_MAGICS:
                continue
        try:
            linked = subprocess.run(["/usr/bin/otool", "-L", str(binary)], check=True,
                                    capture_output=True, text=True).stdout
        except subprocess.SubprocessError as error:
            raise ContractError("Could not inspect a runtime Mach-O dependency list") from error
        for line in linked.splitlines()[1:]:
            dependency = line.strip().split(" (compatibility", 1)[0]
            if not dependency.startswith("/"):
                continue
            if dependency.startswith("/System/Library/PrivateFrameworks/WritingToolsUI.framework/"):
                raise ContractError(
                    f"Runtime image {binary.resolve().relative_to(root)} links WritingToolsUI, "
                    "which reaches the system WebKit engine"
                )
            if any(f"/{name}/" in dependency for name in SYSTEM_ENGINE_FRAMEWORKS):
                raise ContractError(
                    f"Runtime image {binary.resolve().relative_to(root)} directly loads a system WebKit engine"
                )


def verify_relocatable_runtime_rpaths(path: Path) -> None:
    """Reject developer-machine search paths in every bundled Mach-O.

    CMake research builds can link successfully while embedding absolute
    Xcode-toolchain and build-directory LC_RPATH entries. Those paths are not
    available on a user's Mac and can select libraries outside the app. Keep
    only bundle-relative paths and Apple's system Swift runtime location.
    This is a static relocation guard, not a full dyld-closure proof.
    """
    allowed_system_rpaths = {"/usr/lib/swift"}
    for binary in path.rglob("*"):
        if binary.is_symlink() or not binary.is_file():
            continue
        with binary.open("rb") as stream:
            if stream.read(4) not in MACHO_MAGICS:
                continue
        try:
            commands = subprocess.run(["/usr/bin/otool", "-l", str(binary)], check=True,
                                      capture_output=True, text=True).stdout
        except subprocess.SubprocessError as error:
            raise ContractError("Could not inspect runtime Mach-O rpaths") from error
        rpaths = []
        for command in commands.split("cmd LC_RPATH")[1:]:
            match = re.search(r"^\s*path\s+(.+?)\s+\(offset\s+\d+\)", command, re.MULTILINE)
            if not match:
                raise ContractError("Malformed runtime Mach-O rpath")
            rpaths.append(match.group(1))
        for rpath in rpaths:
            if rpath in ("@loader_path", "@executable_path") or rpath.startswith(
                ("@loader_path/", "@executable_path/")
            ):
                continue
            if rpath in allowed_system_rpaths:
                continue
            if Path(rpath).is_absolute():
                raise ContractError(
                    f"Runtime image {binary.resolve().relative_to(path.resolve())} has an absolute non-system rpath"
                )
            raise ContractError("Runtime Mach-O rpath must be bundle-relative or the system Swift runtime")


def _package_verified_host(app: Path, host_binary: Path, runtime_frameworks: Path,
                           identity: str, allow_development_qa: bool = False,
                           expected_team: str = TEAM_ID,
                           qa_tls_anchor_der: bytes | None = None,
                           qa_tls_origins: list[str] | None = None) -> Path:
    if app.is_symlink() or not app.is_dir():
        raise ContractError("Target NeAntik app must be an existing physical bundle")
    info = read_info(app, allow_development_qa=allow_development_qa)
    qa_tls_policy = host_qa_tls_scope(info["CFBundleIdentifier"], allow_development_qa,
                                      qa_tls_anchor_der, qa_tls_origins or [])
    host_bundle_id = info["CFBundleIdentifier"] + ".webkit-host"
    # Verify before creating any staging directories or copying runtime data.
    verify_signing_identity(identity, expected_team)
    verify_host_binary(host_binary)
    verify_runtime_webkit_linkage(host_binary)
    runtime_source = verify_runtime_frameworks(runtime_frameworks, expected_team)
    minimum_os_version = runtime_minimum_os_version(runtime_frameworks)
    network_pin = network_process_pin(runtime_frameworks, expected_team)
    verify_release_xpc_entitlements(runtime_frameworks)
    require_safe_parent_chain(app)
    host_bundle = app / HOST_BUNDLE_RELATIVE_PATH
    if host_bundle.exists() or host_bundle.is_symlink():
        raise ContractError("Existing WebKit host is preserved; use a fresh app staging directory")
    preflight_owned_webkit_notices(app, runtime_frameworks)
    host_executable = app / HOST_EXECUTABLE_RELATIVE_PATH
    host_executable.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(host_binary, host_executable)
    shutil.copystat(host_binary, host_executable, follow_symlinks=False)
    framework_destination = host_bundle / "Contents/Frameworks"
    shutil.copytree(runtime_frameworks, framework_destination, symlinks=True)
    staged_webkit = framework_destination / "WebKit.framework/Versions/A/WebKit"
    runtime_hash = digest(runtime_source)
    if digest(staged_webkit) != runtime_hash:
        raise ContractError("Staged WebKit image differs from the validated runtime input")
    host_info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "NeAntikWebKitHost",
        "CFBundleIdentifier": host_bundle_id,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "NeAntik WebKit Host",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": info.get("CFBundleShortVersionString", "0.0"),
        "CFBundleVersion": info.get("CFBundleVersion", "1"),
        RUNTIME_PIN_KEY: {"schemaVersion": 2, "webKitSHA256": runtime_hash,
                          "minimumOSVersion": minimum_os_version},
    }
    host_info.update(host_ats_policy(info["CFBundleIdentifier"], allow_development_qa,
                                     qa_tls_policy.get(QA_TLS_SCOPE_KEY, {}).get("origins", [])))
    host_info.update(qa_tls_policy)
    (host_bundle / "Contents/Info.plist").write_bytes(
        plistlib.dumps(host_info, fmt=plistlib.FMT_XML, sort_keys=True))
    args = ["/usr/bin/codesign", "--force", "--options", "runtime", "--identifier", host_bundle_id]
    args += ["--timestamp", "--sign", identity, str(host_bundle)]
    subprocess.run(args, check=True, capture_output=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(host_bundle)], check=True, capture_output=True)
    signed_entitlements = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(host_bundle)],
                                         check=True, capture_output=True).stdout
    observed_entitlements = plistlib.loads(signed_entitlements) if signed_entitlements else {}
    if observed_entitlements != HOST_ENTITLEMENTS:
        raise ContractError("Signed WebKit host entitlement set mismatch")
    detail = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(host_executable)],
                            check=True, capture_output=True, text=True).stderr
    if f"Identifier={host_bundle_id}" not in detail:
        raise ContractError("Nested host signing identifier mismatch")
    if f"TeamIdentifier={expected_team}" not in detail:
        raise ContractError("Nested host signing team mismatch")
    cdhash = parse_cdhash(detail)
    installed = pinned_info(info, digest(host_executable), cdhash, host_bundle_id)
    installed[NETWORK_PROCESS_PIN_KEY] = network_pin
    install_info_atomically(app, installed)
    install_owned_webkit_notices(app, framework_destination)
    return host_bundle


def package(app: Path, host_binary: Path, runtime_frameworks: Path, identity: str,
            allow_development_qa: bool = False, recipient_relink: bool = False,
            qa_tls_anchor_der: bytes | None = None,
            qa_tls_origins: list[str] | None = None) -> Path:
    """Package a pre-linked host, or derive one only from this app's manager."""
    if app.is_symlink() or not app.is_dir():
        raise ContractError("Target NeAntik app must be an existing physical bundle")
    # Validate before copying a large runtime tree or changing a signed app.
    manager_info = read_info(app, allow_development_qa=allow_development_qa)
    host_qa_tls_scope(manager_info["CFBundleIdentifier"], allow_development_qa,
                      qa_tls_anchor_der, qa_tls_origins or [])
    expected_team = TEAM_ID
    if recipient_relink:
        info = read_info(app, allow_development_qa=allow_development_qa)
        expected_team = manager_signing_team(app, info["CFBundleIdentifier"])
        # Never inspect/rebind runtime inputs until the selected identity
        # matches the validated recipient manager team.
        verify_signing_identity(identity, expected_team)
    else:
        # Preserve the release path's original fail-fast order and fixed team.
        verify_signing_identity(identity)
        info = read_info(app, allow_development_qa=allow_development_qa)
    manager_name = info.get("CFBundleExecutable")
    if not isinstance(manager_name, str):
        return _package_verified_host(app, host_binary, runtime_frameworks, identity,
                                      allow_development_qa=allow_development_qa,
                                      expected_team=expected_team,
                                      qa_tls_anchor_der=qa_tls_anchor_der,
                                      qa_tls_origins=qa_tls_origins)
    manager_binary = app / "Contents/MacOS" / manager_name
    try:
        is_manager = (host_binary.resolve(strict=True) == manager_binary.resolve(strict=True)
                      and not host_binary.is_symlink())
    except OSError:
        is_manager = False
    if not is_manager:
        return _package_verified_host(app, host_binary, runtime_frameworks, identity,
                                      allow_development_qa=allow_development_qa,
                                      expected_team=expected_team,
                                      qa_tls_anchor_der=qa_tls_anchor_der,
                                      qa_tls_origins=qa_tls_origins)

    with tempfile.TemporaryDirectory(prefix="neantik-webkit-host-rebind-") as temporary:
        derived = Path(temporary) / "NeAntikWebKitHost"
        derive_owned_webkit_host(app, host_binary, derived,
                                 allow_development_qa=allow_development_qa)
        return _package_verified_host(app, derived, runtime_frameworks, identity,
                                      allow_development_qa=allow_development_qa,
                                      expected_team=expected_team,
                                      qa_tls_anchor_der=qa_tls_anchor_der,
                                      qa_tls_origins=qa_tls_origins)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--host-binary", type=Path, required=True,
                        help="separately linked host executable with private WebKit load and no SwiftUI")
    parser.add_argument("--runtime-frameworks", type=Path, required=True,
                        help="pre-signed Frameworks directory containing WebKit.framework")
    parser.add_argument("--identity", required=True, help="Existing Developer ID identity name or SHA-1")
    parser.add_argument("--development-qa", action="store_true",
                        help="Allow only the app.neantik.desktop.dev bundle for an isolated QA copy")
    parser.add_argument("--recipient-relink", action="store_true",
                        help="For local LGPL relinking only: use the signed manager's Developer ID team; public releases stay pinned to NeAntik's team")
    parser.add_argument("--qa-tls-anchor-der", type=Path,
                        help="Dev QA only: public DER CA certificate for exact synthetic HTTPS origins")
    parser.add_argument("--qa-tls-origin", action="append", default=[],
                        help="Dev QA only: exact https://host.invalid:port; repeat up to four times")
    args = parser.parse_args()
    try:
        anchor = None
        if args.qa_tls_anchor_der is not None:
            source = args.qa_tls_anchor_der
            if source.is_symlink() or not source.is_file() or source.stat().st_size > 32768:
                raise ContractError("QA TLS anchor must be a regular bounded file")
            anchor = source.read_bytes()
        path = package(args.app, args.host_binary, args.runtime_frameworks, args.identity,
                       allow_development_qa=args.development_qa,
                       recipient_relink=args.recipient_relink,
                       qa_tls_anchor_der=anchor,
                       qa_tls_origins=args.qa_tls_origin)
    except ContractError as error:
        parser.exit(1, f"WebKit host packaging refused: {error}\n")
    except (OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"WebKit host packaging refused: {type(error).__name__}\n")
    print(f"Packaged WebKit host: {path.relative_to(args.app)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
