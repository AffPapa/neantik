#!/usr/bin/env python3
"""Check a frozen owned-WebKit Dev QA ZIP before any external submission.

This is a package-binding preflight, not a signature, notarization, launch, or
runtime qualification. It validates the archive bytes and the exact app/root,
manager, host, and runtime paths consumed by the one-use QA launcher.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
from urllib.parse import urlsplit
import zipfile

V508_WEBGPU_SHA256 = "6dbb393c3fae9515e10e6cc9fd42e960ca89270cb35e948c3fe8434a65aa0abc"
V508_BINDING_SHA256 = "c4264d49e80670c09cf769f4031fae9740cbc1accfa5d37372b78d270b0df39a"


class PreflightError(ValueError):
    pass


def require(condition: bool, code: str) -> None:
    if not condition:
        raise PreflightError(code)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _owner_file(path: Path, *, private: bool = False) -> bool:
    try:
        item = path.lstat()
    except OSError:
        return False
    return (stat.S_ISREG(item.st_mode) and item.st_uid == os.geteuid()
            and item.st_nlink == 1 and (not private or stat.S_IMODE(item.st_mode) == 0o600))


def _fixture_scope(root: Path, seed_sha: str) -> tuple[str, str]:
    try:
        root_stat = root.lstat()
    except OSError as error:
        raise PreflightError("qa-fixture-root-not-private") from error
    require(stat.S_ISDIR(root_stat.st_mode) and root_stat.st_uid == os.geteuid()
            and stat.S_IMODE(root_stat.st_mode) == 0o700,
            "qa-fixture-root-not-private")
    profile_path = root / "profiles.json"
    previous_path = root / "profiles.previous.json"
    certificates = root / "certificates"
    anchor_path = certificates / "ca.der"
    try:
        cert_stat = certificates.lstat()
    except OSError as error:
        raise PreflightError("qa-fixture-anchor-invalid") from error
    require(_owner_file(profile_path, private=True) and _owner_file(previous_path, private=True)
            and stat.S_ISDIR(cert_stat.st_mode) and cert_stat.st_uid == os.geteuid()
            and stat.S_IMODE(cert_stat.st_mode) == 0o700
            and _owner_file(anchor_path), "qa-fixture-anchor-invalid")
    try:
        profile_bytes = profile_path.read_bytes()
        previous_bytes = previous_path.read_bytes()
        document = json.loads(profile_bytes)
        urls = [profile["startURL"] for profile in document["profiles"]]
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError) as error:
        raise PreflightError("qa-fixture-scope-unreadable") from error
    require(_owner_file(profile_path, private=True) and _owner_file(previous_path, private=True)
            and hashlib.sha256(profile_bytes).hexdigest() == seed_sha
            and hashlib.sha256(previous_bytes).hexdigest() == seed_sha,
            "qa-fixture-profile-seed-mismatch")
    anchor_sha = sha256(anchor_path)
    profiles = document["profiles"]
    schema = document.get("schemaVersion")
    flags = [profile.get("webKitBlockPeerConnections", False) for profile in profiles]
    valid_peer_flags = (schema == 5 and all(type(flag) is bool and not flag for flag in flags)) or (
        schema == 6 and all("webKitBlockPeerConnections" in profile for profile in profiles)
        and len(flags) == 2 and all(type(flag) is bool for flag in flags) and flags == [True, False])
    require(valid_peer_flags and len(urls) == 2
            and all(isinstance(url, str) for url in urls) and urls[0] == urls[1],
            "qa-fixture-origin-mismatch")
    parsed = urlsplit(urls[0])
    try:
        port = parsed.port
    except ValueError as error:
        raise PreflightError("qa-fixture-origin-not-synthetic") from error
    require(parsed.scheme == "https" and parsed.hostname is not None
            and parsed.hostname == parsed.hostname.lower()
            and parsed.hostname.endswith(".invalid") and port is not None
            and parsed.path in ("", "/") and not parsed.query and not parsed.fragment
            and not parsed.username and not parsed.password,
            "qa-fixture-origin-not-synthetic")
    return anchor_sha, f"https://{parsed.netloc}"


def _read_unique(zf: zipfile.ZipFile, names: list[str], path: str) -> bytes:
    matches = [name for name in names if name == path]
    require(len(matches) == 1, "archive-path-not-unique:" + path)
    return zf.read(matches[0])


def _read_unique_regular(zf: zipfile.ZipFile, names: list[str], path: str, maximum: int) -> bytes:
    require(names.count(path) == 1, "archive-path-not-unique:" + path)
    info = zf.getinfo(path)
    mode = (info.external_attr >> 16) & 0xffff
    require(not info.is_dir() and not stat.S_ISLNK(mode) and info.file_size <= maximum,
            "qa-v508-archive-entry-invalid:" + path)
    return zf.read(info)


def inspect(candidate: dict, plan: dict) -> dict:
    require(isinstance(candidate, dict) and isinstance(plan, dict), "invalid-input-schema")
    candidate_variant = candidate.get("qaRuntimeVariant")
    plan_variant = plan.get("qaRuntimeVariant")
    require(candidate_variant == plan_variant and candidate_variant in (None, "V508"),
            "qa-runtime-variant-mismatch")
    v508 = candidate_variant == "V508"
    if v508:
        for key, expected in (("qaWebGPUSHA256", V508_WEBGPU_SHA256),
                              ("qaRuntimeBindingSHA256", V508_BINDING_SHA256)):
            require(candidate.get(key) == expected and plan.get(key) == expected,
                    "qa-v508-candidate-plan-identity-mismatch:" + key)
    else:
        require(not any(key in obj for obj in (candidate, plan)
                        for key in ("qaWebGPUSHA256", "qaRuntimeBindingSHA256")),
                "qa-v508-fields-without-variant")
    archive = Path(candidate.get("archive", ""))
    expected_sha = candidate.get("sha256")
    root = candidate.get("root")
    require(archive.is_file() and not archive.is_symlink(), "archive-not-regular-file")
    require(isinstance(expected_sha, str) and re.fullmatch(r"[0-9a-f]{64}", expected_sha),
            "invalid-archive-sha")
    require(plan.get("archiveSHA256") == expected_sha, "plan-archive-sha-mismatch")
    require(isinstance(root, str) and re.fullmatch(
        r"/private/tmp/neantik-[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*", root), "invalid-fixture-root")
    require(plan.get("profileSeedSHA256") == candidate.get("profileSeedSHA256")
            and isinstance(candidate.get("profileSeedSHA256"), str)
            and re.fullmatch(r"[0-9a-f]{64}", candidate["profileSeedSHA256"]),
            "profile-seed-mismatch")
    trust_sha = candidate.get("qaTrustAnchorSHA256")
    trust_origin = candidate.get("qaTrustOrigin")
    require(isinstance(trust_sha, str) and re.fullmatch(r"[0-9a-f]{64}", trust_sha)
            and plan.get("qaTrustAnchorSHA256") == trust_sha,
            "qa-tls-anchor-hash-mismatch")
    require(isinstance(trust_origin, str)
            and re.fullmatch(r"https://[a-z0-9][a-z0-9.-]*\.invalid:[1-9][0-9]{0,4}", trust_origin)
            and plan.get("qaTrustOrigin") == trust_origin,
            "qa-tls-origin-mismatch")
    actual_sha = sha256(archive)
    require(actual_sha == expected_sha, "archive-sha-mismatch")
    fixture_anchor_sha, fixture_origin = _fixture_scope(Path(root), candidate["profileSeedSHA256"])
    require(fixture_anchor_sha == trust_sha, "qa-tls-fixture-anchor-mismatch")
    require(fixture_origin == trust_origin, "qa-tls-fixture-origin-mismatch")

    app_name = Path(candidate.get("app", "")).name
    require(app_name.endswith(".app"), "invalid-app-name")
    with zipfile.ZipFile(archive) as zf:
        infos = zf.infolist()
        names = [item.filename for item in infos]
        require(len(names) == len(set(names)), "duplicate-archive-path")
        for name in names:
            path = PurePosixPath(name)
            require(not path.is_absolute() and ".." not in path.parts, "unsafe-archive-path")

        app_prefix = app_name + "/Contents/"
        app_info_path = app_prefix + "Info.plist"
        app_info = plistlib.loads(_read_unique(zf, names, app_info_path))
        require(app_info.get("CFBundleIdentifier") == "app.neantik.desktop.dev", "not-dev-bundle")
        marker_key = "NeAntikPrivateQARuntimeVariant"
        require((app_info.get(marker_key) == "V508") if v508 else (marker_key not in app_info),
                "qa-runtime-variant-app-marker-mismatch")
        require(app_info.get("CFBundleShortVersionString") == candidate.get("version"), "version-mismatch")
        require(app_info.get("CFBundleVersion") == candidate.get("build"), "build-mismatch")
        require(app_info.get("NeAntikDevelopmentFixtureRoot") == root, "embedded-root-mismatch")
        require(plan.get("root") == root, "plan-root-mismatch")

        manager_name = app_info.get("CFBundleExecutable")
        require(isinstance(manager_name, str) and manager_name, "manager-executable-missing")
        manager_path = app_prefix + "MacOS/" + manager_name
        manager_expected = candidate.get("managerSignedSHA256") or candidate.get("managerSHA256")
        require(isinstance(manager_expected, str) and re.fullmatch(r"[0-9a-f]{64}", manager_expected),
                "manager-sha-missing")
        require(hashlib.sha256(_read_unique(zf, names, manager_path)).hexdigest() == manager_expected,
                "manager-sha-mismatch")
        if v508:
            require(plan.get("managerSignedSHA256") == manager_expected,
                    "qa-v508-plan-manager-sha-mismatch")

        host_prefix = app_prefix + "Helpers/webkit-v1/NeAntikWebKitHost.app/Contents/"
        host_info = plistlib.loads(_read_unique(zf, names, host_prefix + "Info.plist"))
        require(host_info.get("CFBundleIdentifier") == "app.neantik.desktop.dev.webkit-host",
                "host-bundle-id-mismatch")
        scope = host_info.get("NeAntikQATrustScope")
        require(isinstance(scope, dict) and isinstance(scope.get("anchorDER"), bytes)
                and hashlib.sha256(scope["anchorDER"]).hexdigest() == trust_sha,
                "qa-tls-anchor-not-bound-to-host")
        require(scope.get("origins") == [trust_origin], "qa-tls-origin-not-bound-to-host")
        origin_host = urlsplit(trust_origin).hostname
        ats_policy = host_info.get("NSAppTransportSecurity")
        ats_domains = ats_policy.get("NSExceptionDomains") if isinstance(ats_policy, dict) else None
        expected_ats_hosts = {"127.0.0.1", "neantik-proxy-qa.invalid",
                              "neantik-second-qa.invalid", origin_host}
        require(isinstance(origin_host, str) and isinstance(ats_domains, dict)
                and set(ats_domains) == expected_ats_hosts
                and all(policy == {"NSExceptionAllowsInsecureHTTPLoads": True}
                        for policy in ats_domains.values()),
                "qa-tls-ats-origin-not-bound-to-host")
        host_executable = host_info.get("CFBundleExecutable")
        require(isinstance(host_executable, str) and host_executable, "host-executable-missing")
        host_path = host_prefix + "MacOS/" + host_executable
        host_expected = candidate.get("hostSHA256")
        require(isinstance(host_expected, str) and re.fullmatch(r"[0-9a-f]{64}", host_expected),
                "host-sha-missing")
        require(hashlib.sha256(_read_unique(zf, names, host_path)).hexdigest() == host_expected,
                "host-sha-mismatch")
        if v508:
            require(plan.get("hostSHA256") == host_expected, "qa-v508-plan-host-sha-mismatch")

        runtime_prefix = host_prefix + "Frameworks/"
        for relative in (
            "WebKit.framework/Versions/A/WebKit",
            "JavaScriptCore.framework/Versions/A/JavaScriptCore",
            "WebCore.framework/Versions/A/WebCore",
            "WebKitLegacy.framework/Versions/A/WebKitLegacy",
        ):
            _read_unique(zf, names, runtime_prefix + relative)
        if v508:
            gpu_path = runtime_prefix + "WebGPU.framework/Versions/A/WebGPU"
            binding_path = host_prefix + "Resources/NeAntikRuntimeEvidence/NeAntikRuntimeImageBinding.json"
            gpu = _read_unique_regular(zf, names, gpu_path, 128 * 1024 * 1024)
            binding = _read_unique_regular(zf, names, binding_path, 2_000_000)
            require(hashlib.sha256(gpu).hexdigest() == V508_WEBGPU_SHA256, "qa-v508-webgpu-sha-mismatch")
            require(hashlib.sha256(binding).hexdigest() == V508_BINDING_SHA256, "qa-v508-binding-sha-mismatch")
        _read_unique(zf, names, app_prefix + "Resources/NeAntikRuntimeNotices.md")

    return {
        "status": "PASS",
        "archiveSHA256": actual_sha,
        "bundleIdentifier": app_info["CFBundleIdentifier"],
        "fixtureRootBound": True,
        "managerAndHostBytesMatch": True,
        "ownedWebKitRuntimePresent": True,
        "qaTLSAnchorAndOriginBound": True,
        **({"qaRuntimeVariant": "V508", "qaWebGPUAndBindingBytesMatch": True} if v508 else {}),
        "scope": "static exact-ZIP consumer preflight only; signature, Gatekeeper, launch and runtime remain separate gates",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--run-plan", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = inspect(json.loads(args.candidate.read_text()), json.loads(args.run_plan.read_text()))
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        code = str(error) if isinstance(error, PreflightError) else "unreadable-input"
        print(json.dumps({"status": "REFUSED", "code": code, "externalSubmission": False}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
