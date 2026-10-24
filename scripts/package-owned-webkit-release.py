#!/usr/bin/env python3
"""Embed the pinned production WebKit runtime into an owned release candidate.

The manager app must be a disposable, production-ID release candidate. This
helper signs it once so the runtime re-signer can authenticate its team, stages
and signs the pinned runtime, then packages the separately linked production
host and hash-checked notices. The caller signs the final manager again after
this helper updates the outer Info.plist and bundle contents.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
EXPECTED_COMMIT = "43d5b8d85e2e5eed41d7ff8a79da831bf405be6c"
EXPECTED_PATCH_SHA256 = "b33b9320bd8f3bae56eadebc738fe91d40f0cf77e89fd2885bf28679d2af0735"
SOURCE_CROSSWALK = ROOT / "docs/evidence/webkit-v20-source-license-crosswalk-20261024.json"
SOURCE_CROSSWALK_SHA256 = "a4855fed2d0f33b31c791440538dbc481b0176665268e9dd57dbdbc9c23d9191"
SOURCE_RECOVERY = ROOT / "docs/evidence/webkit-v20-source-recovery-20261025.json"
SOURCE_ARCHIVE = ROOT / "artifacts/neantik/webkit-v20-source-20261025/WebKit-43d5b8d85e2e5eed41d7ff8a79da831bf405be6c.tar.zst"
SOURCE_ARCHIVE_SHA256 = "658ca48ecfdaa341991bc9cd773a0aa394dabe90ccd1851021433fbd9e72df9f"
SOURCE_TREE = "86b6ee8faf130e81a149280914e4ea5718f60129"
EXPECTED_IMAGES = {
    "WebCore.framework/Versions/A/WebCore": "c309a063fe9285910d9a9a0ec78d960a5df73780b899e70f40412e6e351c3f9e",
    "WebKitLegacy.framework/Versions/A/WebKitLegacy": "1c2031452fa3ebeeb8644120382d3f4f2a39697a95292a941cc5e86db6644b76",
    "WebKit.framework/Versions/A/WebKit": "a114a212993c88681dacef826f964150df37b979d0d5ad5ded8debb137c0c6ef",
}
IDENTITY_SHA1 = "474F7C78F33EE324C24F6F5AE0443EB713E85E60"
PRODUCTION_BUNDLE_ID = "app.neantik.desktop"
STAGING_MANIFEST = ROOT / "runtime/webkit-production-staging-v4.json"
MARKER_FREE_RECEIPT = ROOT / "docs/evidence/webkit-v20-production-marker-free-rebuild-20261025.json"
PATCH = ROOT / "docs/evidence/third-party/webkit-v16-relink-candidate-20261020/webkit-v20-source-modifications.patch"


class PackageError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(arguments: list[str], *, env: dict[str, str] | None = None,
        cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(arguments, check=True, capture_output=True, text=True,
                              env=env, cwd=cwd, timeout=3600)
    except (OSError, subprocess.SubprocessError) as error:
        raise PackageError(f"owned WebKit packaging stage failed: {Path(arguments[0]).name}") from error


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise PackageError(f"required release verifier unavailable: {name}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def validate_manager_info(info: object, identity: str) -> None:
    if (not isinstance(info, dict) or info.get("CFBundleIdentifier") != PRODUCTION_BUNDLE_ID
            or info.get("CFBundleShortVersionString") != "1.0.0"):
        raise PackageError("owned WebKit release packaging requires the 1.0.0 production manager")
    try:
        build = int(info.get("CFBundleVersion", ""))
    except (TypeError, ValueError) as error:
        raise PackageError("1.0.0 manager build number is malformed") from error
    if build < 139:
        raise PackageError("1.0.0 manager build must advance beyond the public 0.8.26 (138)")
    forbidden = {"NeAntikBackupQualificationRunID", "NeAntikBackupQualificationRoot",
                 "NeAntikBrowserDataBackupDevelopmentEnabled"}
    if forbidden.intersection(info):
        raise PackageError("development or QA manager metadata is not allowed")
    if identity.upper() != IDENTITY_SHA1:
        raise PackageError("release must use the existing pinned Developer ID identity")


def verify_source_archive_identity() -> None:
    """Bind a no-.git source extraction to the pinned upstream archive receipt."""
    try:
        recovery = json.loads(SOURCE_RECOVERY.read_text(encoding="utf-8"))
        archive_identity = (SOURCE_ARCHIVE.is_file() and not SOURCE_ARCHIVE.is_symlink()
                            and SOURCE_ARCHIVE.stat().st_size == recovery.get("sourceArchiveBytes")
                            and sha256(SOURCE_ARCHIVE) == SOURCE_ARCHIVE_SHA256)
    except (OSError, ValueError, UnicodeError) as error:
        raise PackageError("pinned WebKit source archive receipt is unavailable") from error
    if (recovery.get("status") != "exact-source-commit-recovered-and-patched;offer-incomplete"
            or recovery.get("repository") != "https://github.com/WebKit/WebKit"
            or recovery.get("commit") != EXPECTED_COMMIT
            or recovery.get("tree") != SOURCE_TREE
            or recovery.get("sourceArchiveSHA256") != SOURCE_ARCHIVE_SHA256
            or recovery.get("patchSHA256") != EXPECTED_PATCH_SHA256
            or not archive_identity):
        raise PackageError("pinned WebKit source archive does not match the release identity")


def validate_inputs(app: Path, build_root: Path, source_root: Path, identity: str) -> tuple[Path, Path, Path]:
    for path, label in ((app, "candidate app"), (build_root, "WebKit build root"),
                        (source_root, "pinned WebKit source root")):
        if path.is_symlink() or not path.is_dir():
            raise PackageError(f"{label} must be an existing physical directory")
    app, build_root, source_root = (path.resolve(strict=True) for path in (app, build_root, source_root))
    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise PackageError("production manager metadata is unavailable") from error
    validate_manager_info(info, identity)
    host = app / "Contents/Helpers/webkit-v1/NeAntikWebKitHost.app"
    if host.exists() or host.is_symlink():
        raise PackageError("candidate already contains a WebKit host")
    try:
        home = None
        for line in (build_root / "CMakeCache.txt").read_text(encoding="utf-8").splitlines():
            if line.startswith("CMAKE_HOME_DIRECTORY:INTERNAL="):
                home = line.partition("=")[2]
                break
    except (OSError, UnicodeError) as error:
        raise PackageError("WebKit source/build binding is unavailable") from error
    build_source_root = Path(home or "")
    if build_source_root.is_symlink() or not build_source_root.is_dir():
        raise PackageError("configured WebKit source tree is unavailable")
    build_source_root = build_source_root.resolve(strict=True)
    # GitHub's source archive intentionally has no .git directory. Bind this
    # build to the verified upstream archive/commit receipt instead of making
    # a full local Git re-index a release prerequisite. The file-level
    # crosswalk below remains the check against both configured source roots.
    verify_source_archive_identity()
    if sha256(PATCH) != EXPECTED_PATCH_SHA256:
        raise PackageError("pinned WebKit patch hash mismatch")
    if sha256(SOURCE_CROSSWALK) != SOURCE_CROSSWALK_SHA256:
        raise PackageError("pinned WebKit source crosswalk hash mismatch")
    try:
        crosswalk = json.loads(SOURCE_CROSSWALK.read_text(encoding="utf-8"))
        bound_sources: dict[str, str] = {}
        for section, key in (("directCompileInputs", "sourceRows"),
                             ("webCoreUnityInputs", "sourceRows")):
            for row in crosswalk[section][key]:
                if row["path"].startswith("Source/"):
                    bound_sources[row["path"]] = row["sha256"]
        for row in crosswalk["runtimeResources"]["sourceRows"]:
            for mapped in row["mappedSources"]:
                if mapped["path"].startswith("Source/"):
                    bound_sources[mapped["path"]] = mapped["sha256"]
    except (KeyError, TypeError, ValueError, OSError) as error:
        raise PackageError("pinned WebKit source crosswalk is malformed") from error
    if (crosswalk.get("upstream", {}).get("commit") != EXPECTED_COMMIT
            or crosswalk.get("upstream", {}).get("sourcePatchSHA256") != EXPECTED_PATCH_SHA256
            or crosswalk.get("status") != "technical-source-license-crosswalk;not-legal-applicability-or-release-approval"
            or len(bound_sources) != 3344):
        raise PackageError("pinned WebKit source crosswalk scope differs from the release input")
    for candidate_root in (source_root, build_source_root):
        for relative, expected in bound_sources.items():
            source_file = candidate_root / relative
            if source_file.is_symlink() or not source_file.is_file() or sha256(source_file) != expected:
                raise PackageError(f"pinned WebKit source file differs from crosswalk: {relative}")
    reverse = run(["/usr/bin/git", "-C", str(source_root), "apply", "--reverse",
                   "--check", str(PATCH)])
    if reverse.returncode != 0:
        raise PackageError("the pinned WebKit patch is not applied to the selected source tree")
    for relative, expected in EXPECTED_IMAGES.items():
        image = build_root / relative
        if image.is_symlink() or not image.is_file() or sha256(image) != expected:
            raise PackageError(f"marker-free WebKit image does not match its pinned receipt: {relative}")
    try:
        receipt = json.loads(MARKER_FREE_RECEIPT.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeError) as error:
        raise PackageError("marker-free runtime receipt is unavailable") from error
    if (receipt.get("status") != "pass_marker_free_rebuild_only"
            or receipt.get("images") != EXPECTED_IMAGES):
        raise PackageError("marker-free runtime receipt does not match required WebKit images")
    return app, build_root, source_root


def _last_json(stdout: str, *, field: str) -> dict:
    for line in reversed(stdout.splitlines()):
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and field in value:
            return value
    raise PackageError("packaging helper did not return its stage receipt")


def package(app: Path, build_root: Path, source_root: Path, identity: str) -> dict:
    app, build_root, source_root = validate_inputs(app, build_root, source_root, identity)
    developer_dir = run([str(ROOT / "scripts/resolve-compatible-developer-dir.sh")]).stdout.strip()
    env = dict(os.environ)
    env["DEVELOPER_DIR"] = developer_dir
    env["NEANTIK_RELEASE_CHANNEL"] = "production"
    env["NEANTIK_SIGNING_IDENTITY"] = identity

    # A signed manager authenticates the recipient team for nested runtime signing.
    run([sys.executable, str(ROOT / "scripts/direct_backup_signing.py"),
         "sign", str(app), identity], env=env)

    with tempfile.TemporaryDirectory(prefix="neantik-webkit-production-package-") as temporary:
        temp = Path(temporary)
        unsigned_frameworks = temp / "Frameworks"
        signed_frameworks = temp / "Frameworks-signed"
        staged = run([sys.executable, str(ROOT / "scripts/stage-webkit-runtime.py"),
                      str(build_root), str(unsigned_frameworks), "--upstream-source", str(source_root),
                      "--manifest", str(STAGING_MANIFEST)], cwd=ROOT)
        stage_receipt = _last_json(staged.stdout, field="machOSHA256")
        if stage_receipt.get("networkSandbox", {}).get("policyRevision") != 13:
            raise PackageError("runtime staging did not apply the pinned broker-only sandbox policy")

        host_result = run([sys.executable, str(ROOT / "scripts/build-webkit-standalone-host.py"),
                           "--configuration", "release", "--production-proxy"], cwd=ROOT, env=env)
        host_receipt = _last_json(host_result.stdout, field="binarySHA256")
        if host_receipt.get("status") != "built-production-mode-unqualified" or host_receipt.get("qaProxy") is not False:
            raise PackageError("standalone host was not built with the production-only feature gate")
        host_binary = Path(host_receipt.get("binary", ""))
        if host_binary.is_symlink() or not host_binary.is_file():
            raise PackageError("standalone production host binary is unavailable")

        run([sys.executable, str(ROOT / "scripts/resign-webkit-recipient-runtime.py"),
             "--manager-app", str(app), "--source-frameworks", str(unsigned_frameworks),
             "--output-frameworks", str(signed_frameworks), "--identity", identity])
        run([sys.executable, str(ROOT / "scripts/package-webkit-host.py"),
             "--app", str(app), "--host-binary", str(host_binary),
             "--runtime-frameworks", str(signed_frameworks), "--identity", identity])

    packager = _load_module("neantik_webkit_host_packager", ROOT / "scripts/package-webkit-host.py")
    notice_installer = _load_module("neantik_webkit_runtime_notices", ROOT / "scripts/webkit_runtime_notices.py")
    frameworks = app / packager.HOST_BUNDLE_RELATIVE_PATH / "Contents/Frameworks"
    try:
        notices = notice_installer.verify_owned_webkit_notices(app, frameworks)
    except Exception as error:
        raise PackageError("staged WebKit notice byte verification failed") from error
    host_hash = sha256(app / packager.HOST_EXECUTABLE_RELATIVE_PATH)
    return {
        "status": "owned_webkit_host_and_runtime_embedded; outer_manager_resign_required",
        "managerBundleID": PRODUCTION_BUNDLE_ID,
        "managerVersion": "1.0.0 (200)",
        "upstreamCommit": EXPECTED_COMMIT,
        "sourcePatchSHA256": EXPECTED_PATCH_SHA256,
        "sourceCrosswalkSHA256": SOURCE_CROSSWALK_SHA256,
        "stagingManifestSHA256": sha256(STAGING_MANIFEST),
        "runtimeImageCount": len(stage_receipt.get("machOSHA256", {})),
        "networkSandboxPolicyRevision": 13,
        "hostSHA256": host_hash,
        "noticeVerification": notices,
        "releaseQualified": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--build-root", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--identity", required=True)
    args = parser.parse_args()
    try:
        result = package(args.app, args.build_root, args.source_root, args.identity)
    except (PackageError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Owned WebKit release packaging refused: {error}\n")
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
