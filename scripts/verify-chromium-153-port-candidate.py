#!/usr/bin/env python3
"""Verify and export path-free evidence for the Chromium 153 owned macOS port.

This verifier is deliberately narrower than the historical 152 source-pair
verifier: public macOS packaging has no reviewed 153 release, so NeAntik uses
an explicit own-port decision. The output binds one local ARM64/Metal build
candidate to the pinned source evidence without claiming signing, notarization,
Gatekeeper, runtime qualification, or publication.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
STATUS_PATH = PROJECT_ROOT / "runtime" / "chromium-153-port-status.json"
EXPORTER_PATH = PROJECT_ROOT / "scripts" / "export-chromium-153-port-input-manifest.py"


class PortCandidateError(ValueError):
    pass


def load_exporter() -> Any:
    spec = importlib.util.spec_from_file_location("chromium_153_manifest", EXPORTER_PATH)
    if spec is None or spec.loader is None:
        raise PortCandidateError("cannot load Chromium 153 manifest exporter")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PortCandidateError(f"cannot read {label}: {error}") from error
    if not isinstance(value, dict):
        raise PortCandidateError(f"{label} must be a JSON object")
    return value


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise PortCandidateError(result.stderr.strip() or "git verification failed")
    return result.stdout.strip()


def require(value: Any, label: str) -> Any:
    if value is None:
        raise PortCandidateError(f"missing {label}")
    return value


def path_free_binding(binding: dict[str, Any]) -> dict[str, Any]:
    return {
        "status": binding["status"],
        "candidateExecutableSHA256": binding["candidateExecutableSHA256"],
        "candidateExecutableSize": binding["candidateExecutableSize"],
        "candidateVersionOutput": binding["candidateVersionOutput"],
        "sourceVersion": binding["sourceVersion"],
        "architecture": binding["architecture"],
        "angleEnableMetal": binding["angleEnableMetal"],
        "argsGNSHA256": binding["argsGNSHA256"],
        "policy": binding["policy"],
    }


def verify(
    source_root: Path,
    binary_app: Path,
    args_gn: Path,
    status_path: Path,
) -> dict[str, Any]:
    source_root = source_root.resolve()
    status_path = status_path.resolve()
    if not source_root.is_absolute() or not source_root.is_dir():
        raise PortCandidateError("source root must be an existing absolute directory")
    if not status_path.is_file() or status_path.is_symlink():
        raise PortCandidateError("port status must be a regular non-symlinked file")
    status = load_json(status_path, "Chromium 153 port status")
    if status.get("schemaVersion") != 1:
        raise PortCandidateError("unsupported Chromium 153 port status schema")
    if status.get("targetChromiumVersion") != "153.0.8010.52":
        raise PortCandidateError("port status target is not Chromium 153.0.8010.52")
    if status.get("packagingDecision", {}).get("mode") != "owned-macos-packaging-port":
        raise PortCandidateError("port status does not declare the owned packaging decision")

    official = require(status.get("officialChromiumBase"), "official Chromium base")
    if git(source_root, "rev-parse", "HEAD") != official["commit"]:
        raise PortCandidateError("source HEAD does not match official Chromium commit")
    if git(source_root, "rev-parse", "HEAD^{tree}") != official["tree"]:
        raise PortCandidateError("source tree does not match official Chromium tree")

    exporter = load_exporter()
    manifest = exporter.build_manifest(
        source_root,
        ("build", "out", "tools/gn"),
        binary_app.resolve(),
        args_gn.resolve(),
    )
    expected_source = status["localCandidateEvidence"]
    actual_git = manifest["git"]
    expected_pairs = {
        "commit": expected_source["sourceCommit"],
        "tree": expected_source["sourceTree"],
        "trackedDiffSHA256": expected_source["trackedDiffSHA256"],
    }
    for key, expected in expected_pairs.items():
        if actual_git[key] != expected:
            raise PortCandidateError(f"source evidence mismatch: {key}")
    if manifest["untrackedInventorySHA256"] != expected_source["untrackedInventorySHA256"]:
        raise PortCandidateError("source evidence mismatch: untracked inventory")
    if manifest["untrackedFileCount"] != expected_source["untrackedInputCount"]:
        raise PortCandidateError("source evidence mismatch: untracked input count")

    binding = manifest.get("binaryBinding")
    if not isinstance(binding, dict):
        raise PortCandidateError("manifest did not emit binary binding evidence")
    binding_view = path_free_binding(binding)
    for key in (
        "argsGNSHA256",
        "candidateExecutableSHA256",
        "candidateVersionOutput",
        "architecture",
        "angleEnableMetal",
    ):
        if binding_view[key] != expected_source[key]:
            raise PortCandidateError(f"candidate evidence mismatch: {key}")

    safe_manifest = {
        "schemaVersion": manifest["schemaVersion"],
        "sourceMode": manifest["sourceMode"],
        "git": manifest["git"],
        "excludedPrefixes": manifest["excludedPrefixes"],
        "untrackedInventorySHA256": manifest["untrackedInventorySHA256"],
        "untrackedFileCount": manifest["untrackedFileCount"],
        "binaryBinding": binding_view,
    }
    safe_manifest_sha = sha256_bytes(
        json.dumps(safe_manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    )
    output = {
        "schemaVersion": 1,
        "status": "candidate-bound",
        "releaseReady": False,
        "targetArchitecture": "arm64",
        "targetChromiumVersion": status["targetChromiumVersion"],
        "officialChromiumBase": status["officialChromiumBase"],
        "commonUngoogledInput": status["commonUngoogledInput"],
        "macPackagingInput": status["macPackagingInput"],
        "packagingDecision": status["packagingDecision"],
        "sourceEvidence": safe_manifest,
        "sourceEvidenceSHA256": safe_manifest_sha,
        "binaryBinding": binding_view,
        "signatureStatus": "ad-hoc-or-unqualified",
        "policy": (
            "Path-free local candidate evidence only. Signing, notarization, "
            "Gatekeeper, runtime behavior, publication, and release readiness "
            "remain unproven."
        ),
    }
    serialized = json.dumps(output, ensure_ascii=False, sort_keys=True)
    if any(token in serialized for token in ("/Users/", "/private/tmp/", "sourceRoot", "candidateAppPath", "argsGNPath")):
        raise PortCandidateError("path-free evidence contains a local path")
    return output


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    parser.add_argument("binary_app", type=Path)
    parser.add_argument("args_gn", type=Path)
    parser.add_argument("--status", type=Path, default=STATUS_PATH)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = verify(args.source_root, args.binary_app, args.args_gn, args.status)
        output = args.output.resolve()
        if not output.is_absolute():
            raise PortCandidateError("output must be absolute")
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=output.parent, delete=False
        ) as temporary:
            json.dump(result, temporary, ensure_ascii=False, indent=2, sort_keys=True)
            temporary.write("\n")
            temporary_path = Path(temporary.name)
        os.replace(temporary_path, output)
    except (OSError, PortCandidateError) as error:
        print(f"Chromium 153 port candidate verification failed: {error}", file=sys.stderr)
        return 1
    print(f"PASS: Chromium 153 own-port candidate verified: {output}")
    print(f"Source evidence SHA-256: {result['sourceEvidenceSHA256']}")
    print("Release readiness: false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
