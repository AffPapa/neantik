#!/usr/bin/env python3
"""Verify that a manager's signed WebKit host pins still match its final bytes."""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

PIN_KEY = "NeAntikWebKitHostV1"
RUNTIME_PIN_KEY = "NeAntikWebKitRuntimeV1"
NETWORK_PIN_KEY = "NeAntikWebKitNetworkProcessV1"
NETWORK_ID = "app.neantik.desktop.webkit.Networking"


class PinError(ValueError):
    pass


def _regular_file(path: Path) -> bool:
    return not path.is_symlink() and path.is_file()


def _physical_dir(path: Path) -> bool:
    return not path.is_symlink() and path.is_dir()


def _read_plist(path: Path) -> dict:
    if not _regular_file(path):
        raise PinError("bundle metadata is missing or unsafe")
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise PinError("bundle metadata is invalid") from error
    if not isinstance(value, dict):
        raise PinError("bundle metadata is invalid")
    return value


def _codesign_display(path: Path, runner) -> str:
    try:
        # codesign -d writes its details to stderr on macOS. Capture both
        # streams explicitly so the verifier behaves the same when called
        # from a UI tool, CI runner, or a redirected shell.
        result = runner(["/usr/bin/codesign", "-dv", "--verbose=4", str(path)],
                        capture_output=True, text=True)
    except (OSError, subprocess.SubprocessError) as error:
        raise PinError("could not inspect WebKit host signature") from error
    if result.returncode:
        raise PinError("could not inspect WebKit host signature")
    streams = []
    for output in (result.stderr, result.stdout):
        if isinstance(output, bytes):
            streams.append(output.decode("utf-8", "replace"))
        elif output:
            streams.append(str(output))
    return "\n".join(streams)


def _verify_runtime_pin(host_contents: Path, host_info: dict) -> str:
    """Catch a re-signed WebKit binary before sealing or shipping the host."""
    pin = host_info.get(RUNTIME_PIN_KEY)
    if (not isinstance(pin, dict)
            or set(pin) != {"schemaVersion", "webKitSHA256", "minimumOSVersion"}
            or pin.get("schemaVersion") != 2
            or not isinstance(pin.get("webKitSHA256"), str)
            or not re.fullmatch(r"[0-9a-f]{64}", pin["webKitSHA256"])
            or not isinstance(pin.get("minimumOSVersion"), str)
            or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", pin["minimumOSVersion"])):
        raise PinError("owned WebKit runtime pin is malformed")
    frameworks = host_contents / "Frameworks"
    webkit = frameworks / "WebKit.framework"
    versions = webkit / "Versions"
    version_a = versions / "A"
    executable = version_a / "WebKit"
    if (not all(_physical_dir(path) for path in
                (frameworks, webkit, versions, version_a))
            or not _regular_file(executable)):
        raise PinError("owned WebKit runtime image is missing or unsafe")
    digest = hashlib.sha256(executable.read_bytes()).hexdigest()
    if digest != pin["webKitSHA256"]:
        raise PinError("owned WebKit runtime image changed after its host pin was sealed")
    return digest


def _network_code(manager: dict, host_contents: Path, runner) -> tuple[dict, str, str]:
    pin = manager.get(NETWORK_PIN_KEY)
    if (not isinstance(pin, dict)
            or set(pin) != {"schemaVersion", "identifier", "executable", "sha256", "cdHash"}
            or pin.get("schemaVersion") != 1
            or pin.get("identifier") != NETWORK_ID
            or not isinstance(pin.get("executable"), str)
            or not re.fullmatch(r"[A-Za-z0-9._-]{1,200}", pin["executable"])
            or not isinstance(pin.get("sha256"), str)
            or not re.fullmatch(r"[0-9a-f]{64}", pin["sha256"])
            or not isinstance(pin.get("cdHash"), str)
            or not re.fullmatch(r"[0-9a-f]{40}", pin["cdHash"])):
        raise PinError("owned WebKit Networking pin is malformed")
    service = (host_contents / "Frameworks/WebKit.framework/Versions/A/XPCServices"
               / (NETWORK_ID + ".xpc"))
    contents = service / "Contents"
    info = _read_plist(contents / "Info.plist") if _physical_dir(service) and _physical_dir(contents) else None
    executable = contents / "MacOS" / pin["executable"]
    if (not info or info.get("CFBundleIdentifier") != NETWORK_ID
            or info.get("CFBundleExecutable") != pin["executable"]
            or info.get("CFBundlePackageType") != "XPC!"
            or not _physical_dir(contents / "MacOS") or not _regular_file(executable)):
        raise PinError("owned WebKit Networking service is missing or unsafe")
    sha = hashlib.sha256(executable.read_bytes()).hexdigest()
    signed = _codesign_display(service, runner)
    fields = {}
    for key in ("Identifier", "TeamIdentifier", "CDHash"):
        matches = re.findall(rf"(?m)^{key}=([^\r\n]+)$", signed)
        if len(matches) != 1:
            raise PinError("owned WebKit Networking signature metadata is incomplete")
        fields[key] = matches[0].strip().lower() if key == "CDHash" else matches[0].strip()
    if fields["Identifier"] != NETWORK_ID or fields["TeamIdentifier"] != manager.get("NeAntikDeveloperTeamIdentifier"):
        raise PinError("owned WebKit Networking signature identity is inconsistent")
    return pin, sha, fields["CDHash"]


def verify(app: Path, runner=subprocess.run) -> dict[str, str]:
    """Check the exact nested host hash and CodeDirectory pin after final signing."""
    if app.is_symlink() or app.suffix != ".app" or not _physical_dir(app):
        raise PinError("manager app bundle is missing or unsafe")
    contents = app / "Contents"
    if not _physical_dir(contents):
        raise PinError("manager app bundle is missing or unsafe")
    if (not _physical_dir(contents / "Helpers")
            or not _physical_dir(contents / "Helpers/webkit-v1")):
        raise PinError("nested WebKit host path is missing or unsafe")
    manager = _read_plist(contents / "Info.plist")
    manager_id = manager.get("CFBundleIdentifier")
    if not isinstance(manager_id, str) or not re.fullmatch(r"app\.neantik\.desktop(?:\.dev)?", manager_id):
        raise PinError("manager bundle identity is unsupported")

    host = contents / "Helpers/webkit-v1/NeAntikWebKitHost.app"
    host_contents = host / "Contents"
    host_info = _read_plist(host_contents / "Info.plist") if _physical_dir(host) and _physical_dir(host_contents) else None
    executable_name = host_info.get("CFBundleExecutable") if host_info else None
    host_id = f"{manager_id}.webkit-host"
    if (not host_info or host_info.get("CFBundleIdentifier") != host_id
            or host_info.get("CFBundlePackageType") != "APPL"
            or executable_name != "NeAntikWebKitHost"):
        raise PinError("nested WebKit host identity is missing or inconsistent")
    runtime_sha = _verify_runtime_pin(host_contents, host_info)

    executable = host_contents / "MacOS/NeAntikWebKitHost"
    if not _physical_dir(host_contents / "MacOS") or not _regular_file(executable):
        raise PinError("nested WebKit host executable is missing or unsafe")
    pin = manager.get(PIN_KEY)
    if (not isinstance(pin, dict)
            or set(pin) != {"schemaVersion", "identifier", "sha256", "cdHash"}
            or pin.get("schemaVersion") != 1
            or pin.get("identifier") != host_id
            or not isinstance(pin.get("sha256"), str)
            or not re.fullmatch(r"[0-9a-f]{64}", pin["sha256"])
            or not isinstance(pin.get("cdHash"), str)
            or not re.fullmatch(r"[0-9a-f]{40}", pin["cdHash"])):
        raise PinError("nested WebKit host pin is malformed")
    actual_sha = hashlib.sha256(executable.read_bytes()).hexdigest()
    if actual_sha != pin["sha256"]:
        raise PinError("nested WebKit host executable changed after its manager pin was sealed")

    signed = _codesign_display(executable, runner)
    fields = {}
    for key in ("Identifier", "TeamIdentifier", "CDHash"):
        matches = re.findall(rf"(?m)^{key}=([^\r\n]+)$", signed)
        if len(matches) != 1:
            raise PinError("nested WebKit host signature metadata is incomplete")
        fields[key] = matches[0].strip().lower() if key == "CDHash" else matches[0].strip()
    expected_team = manager.get("NeAntikDeveloperTeamIdentifier")
    if (fields["Identifier"] != host_id
            or not isinstance(expected_team, str)
            or fields["TeamIdentifier"] != expected_team
            or fields["CDHash"].lower() != pin["cdHash"]):
        raise PinError("nested WebKit host signature does not match its manager pin")
    network_pin, network_sha, network_cdhash = _network_code(manager, host_contents, runner)
    if network_sha != network_pin["sha256"] or network_cdhash != network_pin["cdHash"]:
        raise PinError("owned WebKit Networking changed after its manager pin was sealed")
    return {"status": "PASS", "hostIdentifier": host_id,
            "hostSHA256": actual_sha, "hostCDHash": fields["CDHash"],
            "teamIdentifier": expected_team, "webKitSHA256": runtime_sha,
            "networkSHA256": network_sha, "networkCDHash": network_cdhash}


def refresh_pin(app: Path, runner=subprocess.run) -> dict[str, str]:
    """Refresh the manager pin after the host's final signing pass.

    This deliberately edits only the manager Info.plist. The caller must
    shallow-sign the outer manager afterward, then run verify() on the final
    signed app. It never signs or changes nested WebKit code.
    """
    if app.is_symlink() or app.suffix != ".app" or not _physical_dir(app):
        raise PinError("manager app bundle is missing or unsafe")
    contents = app / "Contents"
    if not _physical_dir(contents):
        raise PinError("manager app bundle is missing or unsafe")
    if (not _physical_dir(contents / "Helpers")
            or not _physical_dir(contents / "Helpers/webkit-v1")):
        raise PinError("nested WebKit host path is missing or unsafe")
    manager_path = contents / "Info.plist"
    manager = _read_plist(manager_path)
    manager_id = manager.get("CFBundleIdentifier")
    team = manager.get("NeAntikDeveloperTeamIdentifier")
    if (not isinstance(manager_id, str)
            or not re.fullmatch(r"app\.neantik\.desktop(?:\.dev)?", manager_id)
            or not isinstance(team, str) or not re.fullmatch(r"[A-Z0-9]{10}", team)):
        raise PinError("manager identity metadata is unsupported")
    host_id = f"{manager_id}.webkit-host"
    host = contents / "Helpers/webkit-v1/NeAntikWebKitHost.app"
    host_contents = host / "Contents"
    if not _physical_dir(host) or not _physical_dir(host_contents):
        raise PinError("nested WebKit host bundle is missing or unsafe")
    host_info = _read_plist(host_contents / "Info.plist")
    executable = host_contents / "MacOS/NeAntikWebKitHost"
    if (host_info.get("CFBundleIdentifier") != host_id
            or host_info.get("CFBundleExecutable") != "NeAntikWebKitHost"
            or host_info.get("CFBundlePackageType") != "APPL"
            or not _physical_dir(host_contents / "MacOS")
            or not _regular_file(executable)):
        raise PinError("nested WebKit host identity is missing or inconsistent")
    _verify_runtime_pin(host_contents, host_info)
    try:
        checked = runner(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(host)])
    except (OSError, subprocess.SubprocessError) as error:
        raise PinError("could not verify nested WebKit host signature") from error
    if checked.returncode:
        raise PinError("nested WebKit host signature is invalid")
    signed = _codesign_display(executable, runner)
    fields = {}
    for key in ("Identifier", "TeamIdentifier", "CDHash"):
        matches = re.findall(rf"(?m)^{key}=([^\r\n]+)$", signed)
        if len(matches) != 1:
            raise PinError("nested WebKit host signature metadata is incomplete")
        fields[key] = matches[0].strip().lower() if key == "CDHash" else matches[0].strip()
    if fields["Identifier"] != host_id or fields["TeamIdentifier"] != team or not re.fullmatch(r"[0-9a-f]{40}", fields["CDHash"]):
        raise PinError("nested WebKit host signature does not match the manager identity")
    network_pin, network_sha, network_cdhash = _network_code(manager, host_contents, runner)
    network_pin["sha256"] = network_sha
    network_pin["cdHash"] = network_cdhash

    manager[PIN_KEY] = {"schemaVersion": 1, "identifier": host_id,
                         "sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
                         "cdHash": fields["CDHash"]}
    manager[NETWORK_PIN_KEY] = network_pin
    original_mode = manager_path.stat(follow_symlinks=False).st_mode & 0o777
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".webkit-host-pin-", dir=contents, delete=False) as stream:
            temporary = Path(stream.name)
            os.fchmod(stream.fileno(), original_mode)
            stream.write(plistlib.dumps(manager, fmt=plistlib.FMT_XML, sort_keys=True))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, manager_path)
        temporary = None
        directory = os.open(contents, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except OSError as error:
        raise PinError("could not atomically update manager host pin") from error
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return {"status": "REFRESHED", "hostIdentifier": host_id}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--refresh-pin", action="store_true",
                        help="refresh manager Info.plist after final nested-host signing; then shallow-sign manager and verify again")
    args = parser.parse_args()
    try:
        result = refresh_pin(args.app) if args.refresh_pin else verify(args.app)
    except (PinError, OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    if args.refresh_pin:
        print("PASS: manager host pin refreshed. Shallow-sign the manager, then run this verifier again.")
    else:
        print("PASS: final signed WebKit host matches the manager's sealed pin.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
