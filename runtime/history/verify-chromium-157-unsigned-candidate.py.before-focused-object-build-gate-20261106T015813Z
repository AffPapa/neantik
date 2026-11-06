#!/usr/bin/env python3
"""Bind an unsigned M157 app to the completed exact source build receipt."""
from __future__ import annotations

import hashlib
import json
import plistlib
import subprocess
import sys
from pathlib import Path

from chromium_157_release_evidence import (
    M157EvidenceError,
    validate_focused_build_evidence,
    verify_contract,
    verify_provenance,
)

VERSION = "157.0.8103.39"


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def require_regular_chain(path: Path, stop: Path) -> None:
    stop = stop.resolve()
    current = path
    while current != stop:
        require(not current.is_symlink(), "symlink in Chromium build-output path: " + str(current))
        require(stop in current.parents, "Chromium build-output path escaped GN output directory")
        current = current.parent


def main() -> int:
    require(len(sys.argv) == 4, "usage: verify app args.gn source-provenance.json")
    app, args_gn, provenance_path = map(Path, sys.argv[1:])
    root = Path(__file__).resolve().parents[1]
    runtime = root / "runtime"
    evidence_path = runtime / "chromium-157-build-evidence.json"
    require(app.is_absolute() and args_gn.is_absolute() and provenance_path.is_absolute(),
            "M157 verification paths must be absolute")
    require(not evidence_path.is_symlink() and evidence_path.is_file(),
            "Chromium 157 build evidence is missing or unsafe")
    require(not provenance_path.is_symlink() and provenance_path.is_file(),
            "Chromium 157 source provenance is missing or unsafe")
    contract = verify_contract(root)
    evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    validate_focused_build_evidence(evidence)
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    verify_provenance(provenance, root)
    require(contract.get("binaryBindingStatus") == "pending-runtime-report" and
            contract.get("buildEvidenceSHA256") == digest(evidence_path),
            "Chromium 157 contract does not bind the completed build evidence")
    require(evidence.get("schemaVersion") == 1 and
            evidence.get("status") == "chromium-source-build-succeeded-unqualified" and
            evidence.get("chromiumVersion") == VERSION and
            evidence.get("targetArchitecture") == "arm64" and
            evidence.get("officialCommit") == "9a31f0acec1854d44e49a73fbf8017598151a583" and
            evidence.get("officialTree") == "e400810dee21ba266feeeef005ea83ae83fd274e" and
            evidence.get("portHead") == "95b9ebdb2192fb206f9838e1a2fbe791fbffb235" and
            evidence.get("sourcePatchSHA256") == contract["portSource"]["sourcePatchManifestSHA256"] and
            evidence.get("buildConfigurationSHA256") == contract["portSource"]["buildArgsSHA256"] and
            evidence.get("buildOutputDirectory") == contract["portSource"]["buildOutputDirectory"] and
            evidence.get("ninjaTarget") == "chrome + focused modified test objects" and
            evidence.get("ninjaExitCode") == 0 and
            evidence.get("releaseReady") is False,
            "Chromium 157 build evidence is incomplete or overstated")
    require(args_gn.is_file() and not args_gn.is_symlink() and
            digest(args_gn) == evidence.get("buildConfigurationSHA256"),
            "GN args differ from authenticated Chromium 157 build")
    out_dir = args_gn.parent.resolve()
    plist_path = app / "Contents/Info.plist"
    binary_path = app / "Contents/MacOS/NeAntik Browser"
    framework_path = app.parent / "NeAntik Browser Framework.framework/Versions" / VERSION / "NeAntik Browser Framework"
    embedded_framework = app / "Contents/Frameworks/NeAntik Browser Framework.framework/Versions" / VERSION / "NeAntik Browser Framework"
    for path in (app, plist_path, binary_path, framework_path, embedded_framework):
        require_regular_chain(path, out_dir)
        require(path.exists(), "missing Chromium 157 build output: " + str(path))
    info = plistlib.loads(plist_path.read_bytes())
    require(info.get("CFBundleShortVersionString") == VERSION and
            info.get("CFBundleExecutable") == "NeAntik Browser",
            "Chromium 157 app plist identity mismatch")
    require(digest(binary_path) == evidence.get("browserExecutableSHA256"),
            "Chromium 157 browser executable changed since authenticated build")
    require(digest(framework_path) == evidence.get("frameworkSHA256") and
            digest(embedded_framework) == evidence.get("frameworkSHA256"),
            "Chromium 157 framework changed since authenticated build")
    for binary in (binary_path, framework_path, embedded_framework):
        subprocess.run(["/usr/bin/lipo", "-verify_arch", "arm64", str(binary)],
                       check=True, stdout=subprocess.DEVNULL)
    print("PASS: unsigned arm64 Chromium 157 app, framework and args match exact completed source-build evidence.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, json.JSONDecodeError, subprocess.SubprocessError, M157EvidenceError) as error:
        print("Unsigned Chromium 157 candidate rejected: " + str(error), file=sys.stderr)
        raise SystemExit(1)
