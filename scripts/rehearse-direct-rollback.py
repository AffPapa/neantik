#!/usr/bin/env python3
"""Stage retained Direct-release bytes in a temporary directory and verify them."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import tempfile
from pathlib import Path


def regular_file(path: Path) -> bool:
    return not path.is_symlink() and path.is_file()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def rehearse(evidence_path: Path, artifact_root: Path) -> dict[str, object]:
    if not regular_file(evidence_path) or evidence_path.stat().st_size > 128 * 1024:
        raise ValueError("release evidence must be a small regular file")
    evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    if not isinstance(evidence, dict):
        raise ValueError("release evidence must be an object")
    tag = evidence.get("tag")
    if not isinstance(tag, str) or not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError("release tag is invalid")
    expected = []
    for section in ("archive", "dmg"):
        record = evidence.get(section)
        if not isinstance(record, dict):
            raise ValueError(f"{section} evidence is missing")
        name = record.get("name")
        size = record.get("sizeBytes")
        digest = record.get("sha256")
        if (
            not isinstance(name, str)
            or Path(name).name != name
            or not name.endswith((".zip", ".dmg"))
            or not isinstance(size, int)
            or isinstance(size, bool)
            or size <= 0
            or not isinstance(digest, str)
            or not re.fullmatch(r"[0-9a-f]{64}", digest)
        ):
            raise ValueError(f"{section} evidence is invalid")
        expected.append((name, size, digest))

    staged = []
    with tempfile.TemporaryDirectory(prefix="neantik-rollback-rehearsal-") as temp:
        stage = Path(temp) / tag
        stage.mkdir()
        for name, size, digest in expected:
            source = artifact_root / name
            sidecar = artifact_root / f"{name}.sha256"
            if not regular_file(source) or not regular_file(sidecar):
                raise ValueError(f"retained artifact or checksum sidecar is missing: {name}")
            if source.stat().st_size != size or sha256(source) != digest:
                raise ValueError(f"retained artifact does not match release evidence: {name}")
            sidecar_text = sidecar.read_text(encoding="ascii").strip()
            if sidecar_text != f"{digest}  {name}":
                raise ValueError(f"checksum sidecar does not match release evidence: {name}")
            shutil.copyfile(source, stage / name)
            shutil.copyfile(sidecar, stage / f"{name}.sha256")
            staged_artifact = stage / name
            if staged_artifact.stat().st_size != size or sha256(staged_artifact) != digest:
                raise ValueError(f"staged artifact verification failed: {name}")
            staged.append({"name": name, "sizeBytes": size, "sha256": digest, "state": "passed"})
        # Verify source bytes again to detect accidental mutation during staging.
        for name, size, digest in expected:
            source = artifact_root / name
            if source.stat().st_size != size or sha256(source) != digest:
                raise ValueError(f"retained artifact changed during rehearsal: {name}")
    return {
        "state": "passed",
        "release": tag,
        "method": "temporary staging and byte verification",
        "artifacts": staged,
        "limitations": "Does not install or launch the app, replace current, or prove hosted rollback behavior.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, default=Path(__file__).resolve().parents[1] / "releases/v0.7.8.json")
    parser.add_argument("--artifact-root", type=Path, default=Path(__file__).resolve().parents[1] / "dist")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        result = rehearse(args.evidence, args.artifact_root)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        result = {"state": "blocked", "reason": str(error)}
    if args.json:
        print(json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2))
    else:
        print(f"Rollback staging rehearsal: {result['state']} · {result.get('release', 'unverified')}")
        for artifact in result.get("artifacts", []):
            print(f"{artifact['name']}: {artifact['state']} · SHA-256 {artifact['sha256']}")
        if result.get("limitations"):
            print(result["limitations"])
        if result.get("reason"):
            print(f"Reason: {result['reason']}")
    return 0 if result["state"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
