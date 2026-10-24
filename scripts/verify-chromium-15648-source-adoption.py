#!/usr/bin/env python3
"""Verify the reproducible source/DEPS/config bundle for Chromium 156.0.8078.48."""

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


def verify(project: Path, source: Path) -> dict:
    manifest_path = project / "runtime/chromium-15648-source-adoption-v3.json"
    manifest = load(manifest_path)
    if (manifest.get("schemaVersion") != 1 or manifest.get("status") not in {
            "source-port-patch-frozen-build-in-progress",
            "source-port-patch-frozen-build-complete",
            } or
            manifest.get("chromiumVersion") != VERSION or
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
    dep_lock = load(deps)
    entries = dep_lock.get("dependencyCheckouts")
    if (dep_lock.get("status") != "pinned-gclient-checkouts-observed" or
            dep_lock.get("dependencyGitCheckoutCount") != manifest.get("dependencyGitCheckoutCount") or
            not isinstance(entries, dict) or len(entries) < 100):
        raise AdoptionError("pinned Chromium dependency lock is incomplete")
    dependency_path = devtools_patch_info.get("dependencyCheckout")
    dependency_pin = entries.get(dependency_path) if isinstance(dependency_path, str) else None
    if (not isinstance(dependency_pin, dict) or
            dependency_pin.get("commit") != devtools_patch_info.get("dependencyCommit") or
            devtools_patch_info.get("changedPaths") != 2 or
            devtools_patch_info.get("status") != "source-fix-required-by-TypeScript-6-isolated-declarations"):
        raise AdoptionError("DevTools compatibility patch is not bound to the exact DEPS checkout")
    if source.is_symlink() or not source.is_absolute() or not source.is_dir():
        raise AdoptionError("source root must be an absolute, non-symlinked directory")
    source = source.resolve()
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
                 ("MAJOR", "MINOR", "BUILD", "PATCH")) != VERSION:
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
        "chromiumVersion": VERSION,
        "officialCommit": manifest["officialCommit"],
        "patchSHA256": digest(patch),
        "devtoolsCompatibilityPatchSHA256": digest(devtools_patch),
        "v8CompatibilityPatchSHA256": digest(v8_patch),
        "dependencyLockSHA256": digest(deps),
        "buildArgsSHA256": digest(args),
        "sourceChangeCount": manifest["sourceChangeCount"],
        "dependencyGitCheckoutCount": len(entries),
        "releaseReady": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_root", type=Path)
    parser.add_argument("--project-root", type=Path, default=ROOT)
    args = parser.parse_args()
    try:
        report = verify(args.project_root.resolve(), args.source_root)
    except (OSError, json.JSONDecodeError, AdoptionError) as error:
        print(f"Chromium 156.48 adoption verification failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
