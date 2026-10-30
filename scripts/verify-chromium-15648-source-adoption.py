#!/usr/bin/env python3
"""Verify versioned Chromium source/DEPS/config adoption manifests."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]
VERSION = "156.0.8078.48"
SUPPORTED_MANIFESTS = {
    "chromium-15648-source-adoption-v3.json": "156.0.8078.48",
    "chromium-15674-source-adoption-v1.json": "156.0.8078.74",
    "chromium-15680-source-adoption-v1.json": "156.0.8078.80",
}
HEX = re.compile(r"^[0-9a-f]{64}$")
GIT = re.compile(r"^[0-9a-f]{40}$")


class AdoptionError(ValueError):
    pass


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def load(path: Path) -> dict:
    if path.is_symlink() or not path.is_file():
        raise AdoptionError(f"missing or unsafe evidence file: {path.name}")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise AdoptionError(f"evidence must be an object: {path.name}")
    return value


def safe_project_file(project: Path, relative: object, expected: object) -> Path:
    if not isinstance(relative, str) or not relative or "\\" in relative:
        raise AdoptionError("invalid project-relative evidence path")
    parts = PurePosixPath(relative).parts
    if relative.startswith("/") or any(part in {"", ".", ".."} for part in parts):
        raise AdoptionError("unsafe project-relative evidence path")
    if not isinstance(expected, str) or not HEX.fullmatch(expected):
        raise AdoptionError("invalid evidence SHA-256")
    result = project.joinpath(*parts)
    if result.is_symlink() or not result.is_file() or digest(result) != expected:
        raise AdoptionError(f"evidence hash mismatch: {relative}")
    return result


def git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *args], check=False, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise AdoptionError("Git source identity check failed")
    return result.stdout.strip()


def verify_dependency_checkouts(
    source: Path,
    entries: dict,
    expected_gclient_entries_sha256: object,
) -> int:
    """Verify every pinned gclient checkout, not just the patch targets."""
    if not isinstance(expected_gclient_entries_sha256, str) or not HEX.fullmatch(
            expected_gclient_entries_sha256):
        raise AdoptionError("invalid .gclient_entries SHA-256")
    entries_file = source.parent / ".gclient_entries"
    if entries_file.is_symlink() or not entries_file.is_file():
        raise AdoptionError("pinned .gclient_entries file is missing or unsafe")
    if digest(entries_file) != expected_gclient_entries_sha256:
        raise AdoptionError(".gclient_entries digest mismatch")
    if not entries:
        raise AdoptionError("pinned dependency checkout map is empty")

    for relative, pin in sorted(entries.items()):
        if not isinstance(relative, str) or "\\" in relative:
            raise AdoptionError("invalid dependency checkout path")
        parts = PurePosixPath(relative).parts
        if (not parts or parts[0] != "src" or relative.startswith("/") or
                any(part in {"", ".", ".."} for part in parts)):
            raise AdoptionError("unsafe dependency checkout path")
        if (not isinstance(pin, dict) or
                not isinstance(pin.get("commit"), str) or
                not GIT.fullmatch(pin["commit"]) or
                not isinstance(pin.get("tree"), str) or
                not GIT.fullmatch(pin["tree"])):
            raise AdoptionError("invalid dependency commit/tree pin")
        checkout = source.parent.joinpath(*parts)
        if checkout.is_symlink() or not checkout.is_dir():
            raise AdoptionError(f"pinned dependency checkout is missing or unsafe: {relative}")
        if Path(git(checkout, "rev-parse", "--show-toplevel")).resolve() != checkout.resolve():
            raise AdoptionError(f"dependency path is not a Git checkout root: {relative}")
        if git(checkout, "rev-parse", "HEAD") != pin["commit"]:
            raise AdoptionError(f"dependency commit mismatch: {relative}")
        if git(checkout, "rev-parse", "HEAD^{tree}") != pin["tree"]:
            raise AdoptionError(f"dependency tree mismatch: {relative}")
    return len(entries)


def verify(
    project: Path,
    source: Path,
    manifest_name: str = "chromium-15648-source-adoption-v3.json",
) -> dict:
    expected_version = SUPPORTED_MANIFESTS.get(manifest_name)
    if expected_version is None:
        raise AdoptionError("unsupported Chromium source-adoption manifest")
    manifest_path = project / "runtime" / manifest_name
    manifest = load(manifest_path)
    if (manifest.get("schemaVersion") != 1 or manifest.get("status") not in {
            "source-port-patch-frozen-build-in-progress",
            "source-port-patch-frozen-build-complete",
            "source-pins-verified-build-pending",
            } or
            manifest.get("chromiumVersion") != expected_version or
            manifest.get("officialRepository") !=
            "https://chromium.googlesource.com/chromium/src.git" or
            manifest.get("releaseReady") is not False):
        raise AdoptionError("source-adoption manifest identity/state mismatch")
    serialized = json.dumps(manifest, sort_keys=True)
    if any(marker in serialized for marker in ("/Users/", "/private/tmp/", "/var/folders/")):
        raise AdoptionError("public source-adoption manifest contains a local path")
    for key in ("officialCommit", "officialTree"):
        if not isinstance(manifest.get(key), str) or not GIT.fullmatch(manifest[key]):
            raise AdoptionError(f"invalid {key}")
    patch = safe_project_file(project, manifest.get("patchFile"), manifest.get("patchSHA256"))
    devtools_patch_info = manifest.get("devtoolsCompatibilityPatch")
    if not isinstance(devtools_patch_info, dict):
        raise AdoptionError("the pinned DevTools TypeScript compatibility patch is missing")
    devtools_patch = safe_project_file(
        project, devtools_patch_info.get("path"), devtools_patch_info.get("sha256")
    )
    v8_patch_info = manifest.get("v8CompatibilityPatch")
    if not isinstance(v8_patch_info, dict):
        raise AdoptionError("the pinned V8 ScopeIterator compatibility patch is missing")
    v8_patch = safe_project_file(
        project, v8_patch_info.get("path"), v8_patch_info.get("sha256")
    )
    deps = safe_project_file(project, manifest.get("dependencyLock"),
                             manifest.get("dependencyLockSHA256"))
    args = safe_project_file(project, manifest.get("buildArgsFile"),
                             manifest.get("buildArgsSHA256"))
    build_directory = manifest.get("buildOutputDirectory")
    if build_directory is None and expected_version == VERSION:
        build_directory = "out/NeAntikStable156_48"
    build_parts = PurePosixPath(build_directory).parts if isinstance(build_directory, str) else ()
    if (len(build_parts) != 2 or build_parts[0] != "out" or
            any(part in {"", ".", ".."} for part in build_parts)):
        raise AdoptionError("Chromium build output directory is invalid")
    if source.is_symlink() or not source.is_absolute() or not source.is_dir():
        raise AdoptionError("source root must be an absolute, non-symlinked directory")
    source = source.resolve()
    dep_lock = load(deps)
    if expected_version == "156.0.8078.80":
        entries = dep_lock.get("checkouts")
        if (dep_lock.get("id") != "chromium-15680-actual-macos-dependency-lock-V904" or
                dep_lock.get("upstreamChromiumCommit") != manifest.get("officialCommit") or
                dep_lock.get("upstreamChromiumTree") != manifest.get("officialTree") or
                dep_lock.get("processedGitCheckoutCount") != manifest.get("dependencyGitCheckoutCount") or
                dep_lock.get("gclientEntriesSHA256") != manifest.get("gclientEntriesSHA256") or
                not isinstance(entries, dict) or len(entries) != 150):
            raise AdoptionError("V904 Chromium 156.80 dependency lock is incomplete or mismatched")
        for relative, expected in ((".gclient", manifest.get("gclientConfigSHA256")),
                                   (".gclient_entries", manifest.get("gclientEntriesSHA256")),
                                   (".gcs_entries", manifest.get("gcsEntriesSHA256"))):
            path = source.parent / relative
            if (path.is_symlink() or not path.is_file() or not isinstance(expected, str) or
                    digest(path) != expected):
                raise AdoptionError(f"Chromium 156.80 sync metadata mismatch: {relative}")
        deps_file = source / "DEPS"
        if (deps_file.is_symlink() or not deps_file.is_file() or
                digest(deps_file) != manifest.get("depsFileSHA256")):
            raise AdoptionError("Chromium 156.80 DEPS source pin mismatch")
    else:
        entries = dep_lock.get("dependencyCheckouts")
        if (dep_lock.get("status") != "pinned-gclient-checkouts-observed" or
                dep_lock.get("dependencyGitCheckoutCount") != manifest.get("dependencyGitCheckoutCount") or
                not isinstance(entries, dict) or len(entries) < 100):
            raise AdoptionError("pinned Chromium dependency lock is incomplete")
    dependency_count = verify_dependency_checkouts(
        source, entries,
        dep_lock.get("gclientEntriesSHA256") if expected_version == "156.0.8078.80"
        else dep_lock.get("gclientEntriesSHA256")
    )
    dependency_path = devtools_patch_info.get("dependencyCheckout")
    dependency_pin = entries.get(dependency_path) if isinstance(dependency_path, str) else None
    if (not isinstance(dependency_pin, dict) or
            dependency_pin.get("commit") != devtools_patch_info.get("dependencyCommit") or
            devtools_patch_info.get("changedPaths") != 2 or
            devtools_patch_info.get("status") != "source-fix-required-by-TypeScript-6-isolated-declarations"):
        raise AdoptionError("DevTools compatibility patch is not bound to the exact DEPS checkout")
    if git(source, "rev-parse", "HEAD") != manifest["officialCommit"]:
        raise AdoptionError("Chromium source commit mismatch")
    if git(source, "rev-parse", "HEAD^{tree}") != manifest["officialTree"]:
        raise AdoptionError("Chromium source tree mismatch")
    version_file = {}
    for line in (source / "chrome/VERSION").read_text(encoding="ascii").splitlines():
        key, separator, value = line.partition("=")
        if separator:
            version_file[key] = value
    if ".".join(version_file.get(key, "") for key in
                 ("MAJOR", "MINOR", "BUILD", "PATCH")) != expected_version:
        raise AdoptionError("Chromium source version file mismatch")
    check = subprocess.run(
        ["git", "-C", str(source), "apply", "--check", "--reverse", str(patch)],
        check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if check.returncode:
        raise AdoptionError("frozen source patch does not reverse-apply cleanly")
    devtools_root = source / dependency_path.removeprefix("src/")
    if git(devtools_root, "rev-parse", "HEAD") != dependency_pin["commit"]:
        raise AdoptionError("DevTools dependency commit mismatch")
    check = subprocess.run(
        ["git", "-C", str(devtools_root), "apply", "--check", "--reverse", str(devtools_patch)],
        check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if check.returncode:
        raise AdoptionError("DevTools TypeScript patch does not reverse-apply cleanly")
    if (manifest.get("sourceChangeCount") != 746 or
            manifest.get("addedSourceFileCount") != 21 or
            manifest.get("patchBytes") != patch.stat().st_size or
            manifest.get("buildArgsBytes") != args.stat().st_size):
        raise AdoptionError("source patch/config counts differ from the frozen manifest")
    source_args = source / build_directory / "args.gn"
    if (source_args.is_symlink() or not source_args.is_file() or
            digest(source_args) != manifest.get("buildArgsSHA256")):
        raise AdoptionError("built source output args.gn differs from the pinned configuration")
    build_evidence_sha = manifest.get("buildEvidenceSHA256")
    build_evidence_status = "pending"
    if expected_version == "156.0.8078.80" and build_evidence_sha is None:
        if manifest.get("status") != "source-pins-verified-build-pending":
            raise AdoptionError("Chromium 156.80 build evidence is absent but not declared pending")
        if manifest.get("releaseReady") is not False:
            raise AdoptionError("Chromium 156.80 pre-build manifest must remain releaseReady=false")
    else:
        build_evidence_path = safe_project_file(
            project, manifest.get("buildEvidenceFile"), build_evidence_sha,
        )
        build_evidence = load(build_evidence_path)
        if (build_evidence.get("status") != "chromium-source-build-succeeded-unqualified" or
                build_evidence.get("chromiumVersion") != expected_version or
                build_evidence.get("officialCommit") != manifest.get("officialCommit") or
                build_evidence.get("officialTree") != manifest.get("officialTree") or
                build_evidence.get("buildOutputDirectory") != build_directory or
                build_evidence.get("buildConfigurationSHA256") != manifest.get("buildArgsSHA256") or
                build_evidence.get("sourcePatchSHA256") != manifest.get("patchSHA256") or
                build_evidence.get("dependencyLockSHA256") != manifest.get("dependencyLockSHA256") or
                build_evidence.get("ninjaExitCode") != 0 or
                build_evidence.get("releaseReady") is not False):
            raise AdoptionError("Chromium build evidence differs from the exact source inputs")
        build_evidence_status = "verified"
    v8_dependency_path = v8_patch_info.get("dependencyCheckout")
    v8_pin = entries.get(v8_dependency_path) if isinstance(v8_dependency_path, str) else None
    if (not isinstance(v8_pin, dict) or
            v8_pin.get("commit") != v8_patch_info.get("dependencyCommit") or
            v8_patch_info.get("changedPaths") != 1 or
            v8_patch_info.get("status") != "source-fix-required-by-new-pure-virtual-scope-iterator-method"):
        raise AdoptionError("V8 compatibility patch is not bound to the exact DEPS checkout")
    v8_root = source / v8_dependency_path.removeprefix("src/")
    if git(v8_root, "rev-parse", "HEAD") != v8_pin["commit"]:
        raise AdoptionError("V8 dependency commit mismatch")
    check = subprocess.run(
        ["git", "-C", str(v8_root), "apply", "--check", "--reverse", str(v8_patch)],
        check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if check.returncode:
        raise AdoptionError("V8 ScopeIterator patch does not reverse-apply cleanly")
    return {
        "status": "source-and-build-inputs-verified",
        "chromiumVersion": expected_version,
        "officialCommit": manifest["officialCommit"],
        "patchSHA256": digest(patch),
        "devtoolsCompatibilityPatchSHA256": digest(devtools_patch),
        "v8CompatibilityPatchSHA256": digest(v8_patch),
        "dependencyLockSHA256": digest(deps),
        "buildArgsSHA256": digest(args),
        "sourceChangeCount": manifest["sourceChangeCount"],
        "dependencyGitCheckoutCount": dependency_count,
        "buildEvidenceStatus": build_evidence_status,
        "releaseReady": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_root", type=Path)
    parser.add_argument("--project-root", type=Path, default=ROOT)
    parser.add_argument(
        "--manifest",
        choices=tuple(SUPPORTED_MANIFESTS),
        default="chromium-15648-source-adoption-v3.json",
    )
    args = parser.parse_args()
    try:
        report = verify(args.project_root.resolve(), args.source_root, args.manifest)
    except (OSError, json.JSONDecodeError, AdoptionError) as error:
        print(f"Chromium adoption verification failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
