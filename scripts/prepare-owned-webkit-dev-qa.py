#!/usr/bin/env python3
"""Seal an assembled owned-WebKit Dev app into one exact, isolated QA ZIP.

The input is a separately built, Developer ID signed Dev app that already
contains the reviewed owned-WebKit host/runtime and current notices. This
producer never builds an engine, touches real profiles, launches the app, or
submits anything to Apple. It changes only a disposable app copy.
"""
from __future__ import annotations

import argparse
import atexit
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile

import direct_signing_identity as signing
from urllib.parse import urlsplit
import zipfile


ROOT = Path(__file__).resolve().parents[1]
IDENTITY = "474F7C78F33EE324C24F6F5AE0443EB713E85E60"
TEAM = "H6VGU2M6JD"
APP_ID = "app.neantik.desktop.dev"
APPLICATION_ID = f"{TEAM}.{APP_ID}"
ENTITLEMENTS = ROOT / "runtime/neantik-dev-qa-entitlements.plist"
HOST_RELATIVE = Path("Contents/Helpers/webkit-v1/NeAntikWebKitHost.app")
FRAMEWORKS_RELATIVE = HOST_RELATIVE / "Contents/Frameworks"


class ProducerError(ValueError):
    pass


def require(ok: bool, code: str) -> None:
    if not ok:
        raise ProducerError(code)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def owner_only(path: Path, mode: int, *, directory: bool) -> bool:
    try:
        item = path.lstat()
    except OSError:
        return False
    return (item.st_uid == os.geteuid() and stat.S_IMODE(item.st_mode) == mode
            and (stat.S_ISDIR(item.st_mode) if directory else stat.S_ISREG(item.st_mode)))


def validate_fixture(root: Path) -> str:
    require(re.fullmatch(r"/private/tmp/neantik-[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*",
                         str(root)) is not None, "invalid-fixture-root")
    require(root.parent == Path("/private/tmp") and owner_only(root, 0o700, directory=True),
            "fixture-root-not-owner-only")
    current, previous = root / "profiles.json", root / "profiles.previous.json"
    require(owner_only(current, 0o600, directory=False)
            and owner_only(previous, 0o600, directory=False), "fixture-seed-not-owner-only")
    require(current.stat().st_nlink == 1 and previous.stat().st_nlink == 1,
            "fixture-seed-linked")
    digest = sha256(current)
    require(sha256(previous) == digest, "fixture-seed-mismatch")
    return digest


def fixture_tls_scope(root: Path) -> tuple[bytes, str]:
    """Read the fixture's public CA and exact HTTPS origin for the signed QA host."""
    try:
        document = json.loads((root / "profiles.json").read_text(encoding="utf-8"))
        profiles = document["profiles"]
        urls = [profile["startURL"] for profile in profiles]
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError) as error:
        raise ProducerError("fixture-tls-profile-invalid") from error
    profiles = document["profiles"]
    schema = document.get("schemaVersion")
    flags = [profile.get("webKitBlockPeerConnections", False) for profile in profiles]
    valid_peer_flags = (schema == 5 and all(type(flag) is bool and not flag for flag in flags)) or (
        schema == 6 and all("webKitBlockPeerConnections" in profile for profile in profiles)
        and len(flags) == 2 and all(type(flag) is bool for flag in flags) and flags == [True, False])
    require(valid_peer_flags and len(urls) == 2
            and all(isinstance(url, str) for url in urls) and urls[0] == urls[1],
            "fixture-tls-origin-mismatch")
    proxy_ports = [profile.get("proxy", {}).get("port") for profile in profiles]
    require([profile.get("name") for profile in profiles]
            == ["Owned WebKit A isolation QA", "Owned WebKit B isolation QA"]
            and all(profile.get("engine") == "webkit"
                    and profile.get("webKitRuntimeGeneration") == "isolatedV1"
                    and isinstance(profile.get("proxy"), dict)
                    and profile["proxy"].get("kind") == "http"
                    and profile["proxy"].get("host") == "127.0.0.1"
                    and profile["proxy"].get("username") == ""
                    and not profile["proxy"].get("password")
                    and isinstance(profile.get("identity"), dict)
                    for profile in profiles)
            and all(type(port) is int and 1 <= port <= 65535 for port in proxy_ports)
            and proxy_ports[0] != proxy_ports[1], "fixture-profile-contract-invalid")
    parsed = urlsplit(urls[0])
    try:
        port = parsed.port
    except ValueError as error:
        raise ProducerError("fixture-tls-origin-not-synthetic") from error
    require(parsed.scheme == "https" and parsed.hostname is not None
            and parsed.hostname == parsed.hostname.lower()
            and parsed.hostname.endswith(".invalid") and port is not None
            and parsed.path in ("", "/") and not parsed.query and not parsed.fragment
            and not parsed.username and not parsed.password,
            "fixture-tls-origin-not-synthetic")
    certificates = root / "certificates"
    anchor_path = root / "certificates/ca.der"
    require(certificates.is_dir() and not certificates.is_symlink()
            and anchor_path.is_file() and not anchor_path.is_symlink()
            and anchor_path.resolve().parent == certificates.resolve(),
            "fixture-tls-anchor-missing")
    anchor = anchor_path.read_bytes()
    require(256 <= len(anchor) <= 32768, "fixture-tls-anchor-size-invalid")
    return anchor, f"https://{parsed.netloc}"


def run(argv: list[str], *, timeout: int = 180) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(argv, check=True, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as error:
        raise ProducerError("command-failed:" + Path(argv[0]).name) from error


def _module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    require(spec is not None and spec.loader is not None, "verifier-unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def source_offer_selection() -> tuple[Path | None, str | None]:
    root = os.environ.get("NEANTIK_WEBKIT_SOURCE_OFFER_ROOT")
    digest = os.environ.get("NEANTIK_WEBKIT_SOURCE_OFFER_MANIFEST_SHA256")
    require(not digest or (root and re.fullmatch(r"[0-9a-f]{64}", digest) is not None),
            "source-offer-identity-invalid")
    return (Path(root) if root else None, digest or None)


def install_fixture_tls_scope(app: Path, stage: Path, anchor: bytes, origin: str,
                              private_v508: dict[str, Path] | None = None) -> None:
    packager = _module("neantik_qa_webkit_tls_packager",
                       ROOT / "scripts/package-webkit-host.py")
    existing_host = app / HOST_RELATIVE
    host_input = stage / "NeAntikWebKitHost.source.app"
    require(existing_host.is_dir() and not existing_host.is_symlink(), "source-host-invalid")
    os.replace(existing_host, host_input)
    host_binary = host_input / "Contents/MacOS/NeAntikWebKitHost"
    runtime_frameworks = host_input / "Contents/Frameworks"
    source_offer, source_offer_digest = source_offer_selection()
    evidence = None
    if private_v508 is not None:
        evidence = packager.PrivateV508Evidence(
            source=private_v508['source'], baseline=private_v508['baseline'],
            modified=private_v508['modified'], binding=private_v508['binding'],
            receipt=private_v508['receipt'])
        runtime_frameworks = private_v508['runtime']
        source_offer = private_v508['offer']
        source_offer_digest = packager.V508_SOURCE_OFFER_SHA256
    packager.package(app, host_binary, runtime_frameworks, IDENTITY,
                     allow_development_qa=True,
                     qa_tls_anchor_der=anchor, qa_tls_origins=[origin],
                     source_offer_root=source_offer,
                     source_offer_manifest_sha256=source_offer_digest,
                     private_v508_evidence=evidence)
    shutil.rmtree(host_input)


def signing_team(app: Path) -> str:
    result = run(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)])
    match = re.search(r"^TeamIdentifier=([A-Z0-9]{10})$", result.stderr, re.MULTILINE)
    require(match is not None, "signing-team-unavailable")
    return match.group(1)


def validate_profile(profile: Path) -> None:
    require(profile.is_file() and not profile.is_symlink(), "dev-profile-missing")
    data = run(["/usr/bin/security", "cms", "-D", "-i", str(profile)]).stdout.encode()
    validate_profile_claims(data)


def validate_profile_claims(data: bytes) -> None:
    try:
        value = plistlib.loads(data)
        entitlements = value["Entitlements"]
        certificates = value["DeveloperCertificates"]
        expires = value["ExpirationDate"]
    except (KeyError, TypeError, ValueError, plistlib.InvalidFileException) as error:
        raise ProducerError("dev-profile-invalid") from error
    groups = entitlements.get("keychain-access-groups", []) if isinstance(entitlements, dict) else []
    require(isinstance(entitlements, dict)
            and entitlements.get("com.apple.application-identifier") == APPLICATION_ID
            and entitlements.get("com.apple.developer.team-identifier") == TEAM
            and value.get("Platform") == ["OSX"]
            and value.get("ProvisionsAllDevices") is True
            and isinstance(groups, list)
            # Apple's TN3125 allows this team-scoped wildcard in the profile;
            # the signed app still claims the exact, non-wildcard access group.
            and (APPLICATION_ID in groups or f"{TEAM}.*" in groups)
            and isinstance(certificates, list)
            and any(hashlib.sha256(cert).hexdigest() == signing.certificate_sha256_for_selector(IDENTITY)
                    for cert in certificates if isinstance(cert, bytes)),
            "dev-profile-claims-mismatch")
    if isinstance(expires, datetime):
        expiration = (expires.replace(tzinfo=timezone.utc) if expires.tzinfo is None
                      else expires.astimezone(timezone.utc))
        require(expiration > datetime.now(timezone.utc),
                "dev-profile-expired")
    else:
        raise ProducerError("dev-profile-expiration-missing")


def validate_source_app(app: Path) -> tuple[str, str]:
    require(app.is_dir() and not app.is_symlink() and app.suffix == ".app",
            "source-app-not-physical")
    info_path = app / "Contents/Info.plist"
    require(info_path.is_file() and not info_path.is_symlink(), "source-info-missing")
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise ProducerError("source-info-invalid") from error
    build = str(info.get("CFBundleVersion", ""))
    require(info.get("CFBundleIdentifier") == APP_ID
            and info.get("CFBundleShortVersionString") == "1.0.0"
            and build.isdecimal() and int(build) > 139,
            "source-dev-identity-or-build-invalid")
    require(info.get("NeAntikBrowserDataBackupEnabled", False) is False,
            "dev-backup-capability-refused")
    host = app / HOST_RELATIVE
    frameworks = app / FRAMEWORKS_RELATIVE
    require(host.is_dir() and not host.is_symlink()
            and (frameworks / "WebKit.framework/Versions/A/WebKit").is_file(),
            "owned-webkit-host-missing")
    require(signing_team(app) == TEAM and signing_team(host) == TEAM,
            "source-signing-team-mismatch")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    packager = _module("neantik_qa_webkit_packager", ROOT / "scripts/package-webkit-host.py")
    notices = _module("neantik_qa_webkit_notices", ROOT / "scripts/webkit_runtime_notices.py")
    packager.verify_runtime_frameworks(frameworks, TEAM)
    packager.verify_release_xpc_entitlements(frameworks)
    source_offer, source_offer_digest = source_offer_selection()
    notices.verify_owned_webkit_notices(
        app, frameworks,
        source_offer_root=source_offer,
        source_offer_manifest_sha256=source_offer_digest,
    )
    return "1.0.0", build


def write_private_json(path: Path, value: dict) -> None:
    with path.open("x", encoding="utf-8") as stream:
        os.fchmod(stream.fileno(), 0o600)
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")


def seal(source: Path, fixture_root: Path, provisioning_profile: Path | None = None,
         proxy_target_host: str = "127.0.0.1",
         private_v508: dict[str, Path] | None = None) -> dict:
    require(proxy_target_host in {"127.0.0.1", "neantik-proxy-qa.invalid"},
            "unsupported-synthetic-proxy-target")
    seed_hash = validate_fixture(fixture_root)
    version, build = validate_source_app(source)
    profile = provisioning_profile or source / "Contents/embedded.provisionprofile"
    validate_profile(profile)
    expected_entitlements = plistlib.loads(ENTITLEMENTS.read_bytes())
    require(expected_entitlements == {
        "com.apple.application-identifier": APPLICATION_ID,
        "com.apple.developer.team-identifier": TEAM,
        "keychain-access-groups": [APPLICATION_ID],
    }, "dev-entitlements-drift")

    qa_anchor, qa_origin = fixture_tls_scope(fixture_root)

    stage = Path(tempfile.mkdtemp(prefix="neantik-owned-webkit-qa-", dir="/private/tmp"))
    cleanup_failed_stage = lambda: shutil.rmtree(stage, ignore_errors=True)
    atexit.register(cleanup_failed_stage)
    app = stage / "NeAntik.app"
    run(["/usr/bin/ditto", str(source), str(app)], timeout=600)
    install_fixture_tls_scope(app, stage, qa_anchor, qa_origin, private_v508)
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["NeAntikDevelopmentFixtureRoot"] = str(fixture_root)
    if private_v508 is not None:
        info["NeAntikPrivateQARuntimeVariant"] = "V508"
    else:
        require("NeAntikPrivateQARuntimeVariant" not in info, "unexpected-qa-runtime-marker")
    require(info.get("CFBundleIdentifier") == APP_ID, "copied-app-identity-drift")
    with tempfile.NamedTemporaryFile(dir=info_path.parent, prefix=".qa-info-", delete=False) as temporary:
        os.fchmod(temporary.fileno(), 0o644)
        temporary.write(plistlib.dumps(info))
        temporary.flush()
        os.fsync(temporary.fileno())
        temporary_path = Path(temporary.name)
    os.replace(temporary_path, info_path)

    staged_profile = app / "Contents/embedded.provisionprofile"
    require(not staged_profile.is_symlink(), "copied-profile-symlink")
    with tempfile.NamedTemporaryFile(dir=staged_profile.parent, prefix=".qa-profile-", delete=False) as temporary:
        os.fchmod(temporary.fileno(), 0o644)
        temporary.write(profile.read_bytes())
        temporary.flush()
        os.fsync(temporary.fileno())
        temporary_profile = Path(temporary.name)
    os.replace(temporary_profile, staged_profile)

    run(["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp",
         "--entitlements", str(ENTITLEMENTS), "--sign", IDENTITY, str(app)], timeout=300)
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], timeout=300)
    require(signing_team(app) == TEAM, "sealed-team-mismatch")
    validate_profile(staged_profile)
    host_pin = _module("neantik_qa_webkit_host_pin",
                       ROOT / "scripts/verify-webkit-host-pin.py")
    require(host_pin.verify(app).get("status") == "PASS", "sealed-webkit-host-pin-refused")

    manager = app / "Contents/MacOS/NeAntik"
    host = app / HOST_RELATIVE / "Contents/MacOS/NeAntikWebKitHost"
    archive = stage / f"NeAntik-{version}-{build}-dev-owned-webkit-qa.zip"
    run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
         str(app), str(archive)], timeout=900)
    candidate = {"stage": str(stage), "root": str(fixture_root), "app": str(app),
                 "archive": str(archive), "sha256": sha256(archive),
                 "profileSeedSHA256": seed_hash, "managerSignedSHA256": sha256(manager),
                 "hostSHA256": sha256(host), "version": version, "build": build,
                 "qaTrustAnchorSHA256": hashlib.sha256(qa_anchor).hexdigest(),
                 "qaTrustOrigin": qa_origin}
    if proxy_target_host != "127.0.0.1":
        candidate["proxyTargetHost"] = proxy_target_host
    plan = {"archiveSHA256": candidate["sha256"], "root": str(fixture_root),
            "profileSeedSHA256": seed_hash,
            "qaTrustAnchorSHA256": candidate["qaTrustAnchorSHA256"],
            "qaTrustOrigin": qa_origin}
    if private_v508 is not None:
        variant = {"qaRuntimeVariant": "V508",
                   "qaWebGPUSHA256": "6dbb393c3fae9515e10e6cc9fd42e960ca89270cb35e948c3fe8434a65aa0abc",
                   "qaRuntimeBindingSHA256": "c4264d49e80670c09cf769f4031fae9740cbc1accfa5d37372b78d270b0df39a"}
        candidate.update(variant)
        plan.update(variant, hostSHA256=candidate["hostSHA256"],
                    managerSignedSHA256=candidate["managerSignedSHA256"])
    verifier = _module("neantik_qa_archive_preflight",
                       ROOT / "scripts/verify_owned_webkit_qa_archive.py")
    require(verifier.inspect(candidate, plan).get("status") == "PASS",
            "exact-zip-preflight-refused")
    receipt = stage / "stage.json"
    write_private_json(receipt, candidate)
    write_private_json(stage / "run-plan.json", plan)
    launcher_path = stage / "launch-owned-webkit-qa"
    run(["/usr/bin/swiftc", "-parse-as-library",
         str(ROOT / "scripts/runtime-network/launch-owned-webkit-qa.swift"),
         "-o", str(launcher_path)], timeout=600)
    launcher = run([str(launcher_path), str(receipt), candidate["sha256"],
                    "--check-only"], timeout=600)
    require("PASS: exact QA archive" in launcher.stdout, "launcher-check-only-refused")
    atexit.unregister(cleanup_failed_stage)
    return {"status": "exact-signed-dev-qa-zip-preflight-pass;not-notarized-or-runtime-qualified",
            "stage": str(stage), "archive": str(archive), "archiveSHA256": candidate["sha256"],
            "managerSHA256": candidate["managerSignedSHA256"], "hostSHA256": candidate["hostSHA256"],
            "launcherSHA256": sha256(launcher_path),
            "fixtureRoot": str(fixture_root), "appleSubmission": False, "appLaunched": False}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-app", required=True, type=Path)
    parser.add_argument("--fixture-root", required=True, type=Path)
    parser.add_argument("--proxy-target-host", choices=("127.0.0.1", "neantik-proxy-qa.invalid"),
                        default="127.0.0.1")
    parser.add_argument("--provisioning-profile", type=Path,
                        help="existing exact Dev profile; defaults to the source app's embedded profile")
    for field in ("runtime", "offer", "source", "baseline", "modified", "binding", "receipt"):
        parser.add_argument("--v508-" + field, type=Path, help="private V508 QA input: " + field)
    args = parser.parse_args()
    try:
        names = ("runtime", "offer", "source", "baseline", "modified", "binding", "receipt")
        inputs = {name: getattr(args, "v508_" + name) for name in names}
        require(not any(inputs.values()) or all(inputs.values()), "v508-inputs-incomplete")
        result = seal(args.source_app, args.fixture_root, args.provisioning_profile,
                      args.proxy_target_host, inputs if all(inputs.values()) else None)
    except (ProducerError, OSError, ValueError, TypeError, RuntimeError,
            zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        parser.exit(1, f"Owned-WebKit Dev QA ZIP refused: {error}\n")
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
