#!/usr/bin/env python3
"""Bind the unchanged Chromium 156.0.8078.74 build output before Developer ID signing."""
from __future__ import annotations

import hashlib
import json
import plistlib
import sys
import subprocess
from pathlib import Path


def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def require_regular_chain(path: Path, stop: Path) -> None:
    current = path
    stop = stop.resolve()
    while current != stop:
        require(not current.is_symlink(), "symlink in Chromium build-output path: " + str(current))
        require(stop in current.parents, "Chromium build-output path escaped GN output directory")
        current = current.parent


def main() -> int:
    require(len(sys.argv) == 4, "usage: verify app args.gn source-adoption-manifest")
    app, args_gn, adoption_path = map(Path, sys.argv[1:])
    root = Path(__file__).resolve().parents[1]
    evidence_path = root / "runtime/chromium-15674-build-evidence.json"
    require(not evidence_path.is_symlink() and not adoption_path.is_symlink(), "build evidence cannot be symlinked")
    evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    adoption = json.loads(adoption_path.read_text(encoding="utf-8"))
    require(adoption.get("buildEvidenceSHA256") == sha(evidence_path), "build evidence is not bound by adoption manifest")
    require(evidence.get("schemaVersion") == 1 and evidence.get("status") == "chromium-source-build-succeeded-unqualified", "unexpected build evidence state")
    require(evidence.get("chromiumVersion") == "156.0.8078.74" and evidence.get("targetArchitecture") == "arm64", "wrong Chromium build identity")
    require(evidence.get("ninjaTarget") == "chrome" and evidence.get("ninjaExitCode") == 0 and evidence.get("releaseReady") is False, "build evidence is incomplete or overstated")
    require(args_gn.is_file() and not args_gn.is_symlink() and sha(args_gn) == evidence.get("buildConfigurationSHA256"), "GN args differ from authenticated build")
    plist_path = app / "Contents/Info.plist"
    binary_path = app / "Contents/MacOS/NeAntik Browser"
    framework_path = app.parent / "NeAntik Browser Framework.framework/Versions/156.0.8078.74/NeAntik Browser Framework"
    out_dir = args_gn.parent.resolve()
    for path in (app, plist_path, binary_path, framework_path):
        require_regular_chain(path, out_dir)
        require(path.exists(), "missing build output: " + str(path))
    info = plistlib.loads(plist_path.read_bytes())
    require(info.get("CFBundleShortVersionString") == "156.0.8078.74" and info.get("CFBundleExecutable") == "NeAntik Browser", "Chromium app plist identity mismatch")
    require(sha(binary_path) == evidence.get("browserExecutableSHA256"), "browser executable changed since authenticated build")
    require(sha(framework_path) == evidence.get("frameworkSHA256"), "framework changed since authenticated build")
    for binary in (binary_path, framework_path):
        subprocess.run(["/usr/bin/lipo", "-verify_arch", "arm64", str(binary)], check=True, stdout=subprocess.DEVNULL)
    print("PASS: unchanged arm64 Chromium 156.0.8078.74 output and GN args match bound source build evidence.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, json.JSONDecodeError, subprocess.SubprocessError) as exc:
        print("Unsigned Chromium 156.74 candidate rejected: " + str(exc), file=sys.stderr)
        raise SystemExit(1)
