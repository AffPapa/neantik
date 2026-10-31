#!/usr/bin/env python3
"""Bind an unsigned Chromium 156.0.8078.80 app to completed build evidence."""

from __future__ import annotations

import hashlib
import json
import plistlib
import subprocess
import sys
from pathlib import Path


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
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


def verify_embedded_framework(app: Path, version: str, out_dir: Path, expected: str) -> None:
    embedded = app / "Contents/Frameworks/NeAntik Browser Framework.framework/Versions" / version / "NeAntik Browser Framework"
    require_regular_chain(embedded, out_dir)
    require(embedded.is_file(), "Embedded signing framework is missing")
    require(digest(embedded) == expected,
            "Embedded framework differs from selected link output; signing would ship stale code")


def main() -> int:
    require(len(sys.argv) in (4, 6), "usage: verify app args.gn source-adoption-manifest [--runtime-lock LOCK]")
    app, args_gn, adoption_path = map(Path, sys.argv[1:4])
    runtime_lock = None
    if len(sys.argv) == 6:
        require(sys.argv[4] == "--runtime-lock", "explicit runtime lock selector required")
        lock_path = Path(sys.argv[5])
        require(lock_path.is_absolute() and lock_path.is_file() and not lock_path.is_symlink(), "unsafe privacy lock path")
        runtime_lock = json.loads(lock_path.read_text())
    root = Path(__file__).resolve().parents[1]
    runtime = root / "runtime"
    evidence_path = runtime / "chromium-15680-build-evidence.json"
    contract_path = runtime / "chromium-15680-source-contract.json"
    require(not evidence_path.is_symlink() and evidence_path.is_file(),
            "Chromium 156.80 build evidence is missing or unsafe")
    require(not adoption_path.is_symlink() and adoption_path.is_file(),
            "Chromium 156.80 source-adoption manifest is missing or unsafe")
    require(not contract_path.is_symlink() and contract_path.is_file(),
            "Chromium 156.80 source contract is missing or unsafe")
    evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    adoption = json.loads(adoption_path.read_text(encoding="utf-8"))
    contract = json.loads(contract_path.read_text(encoding="utf-8"))
    require(adoption.get("chromiumVersion") == "156.0.8078.80" and
            adoption.get("buildEvidenceSHA256") == digest(evidence_path),
            "Chromium 156.80 build evidence is not bound by adoption manifest")
    require(contract.get("targetChromiumVersion") == "156.0.8078.80" and
            contract.get("binaryBindingStatus") == "pending-runtime-report" and
            contract.get("buildEvidenceSHA256") == digest(evidence_path) and
            contract.get("sourceAdoptionManifestSHA256") == digest(adoption_path),
            "Chromium 156.80 source contract does not bind the completed build")
    require(evidence.get("schemaVersion") == 1 and
            evidence.get("status") == "chromium-source-build-succeeded-unqualified" and
            evidence.get("chromiumVersion") == "156.0.8078.80" and
            evidence.get("targetArchitecture") == "arm64" and
            evidence.get("officialCommit") == "fb096c0011f9d50f0a264a9376420cdea9c421e3" and
            evidence.get("officialTree") == "9daca4c0f1670a0ead9a94888c1bfe4ace733f4d" and
            evidence.get("ninjaTarget") == "chrome" and evidence.get("ninjaExitCode") == 0 and
            evidence.get("releaseReady") is False,
            "Chromium 156.80 build evidence is incomplete or overstated")
    require(args_gn.is_file() and not args_gn.is_symlink() and
            digest(args_gn) == evidence.get("buildConfigurationSHA256"),
            "GN args differ from authenticated Chromium 156.80 build")
    plist_path = app / "Contents/Info.plist"
    binary_path = app / "Contents/MacOS/NeAntik Browser"
    version = "156.0.8078.80"
    framework_path = app.parent / "NeAntik Browser Framework.framework/Versions" / version / "NeAntik Browser Framework"
    embedded_framework = app / "Contents/Frameworks/NeAntik Browser Framework.framework/Versions" / version / "NeAntik Browser Framework"
    out_dir = args_gn.parent.resolve()
    for path in (app, plist_path, binary_path, framework_path, embedded_framework):
        require_regular_chain(path, out_dir)
        require(path.exists(), "missing Chromium 156.80 build output: " + str(path))
    info = plistlib.loads(plist_path.read_bytes())
    require(info.get("CFBundleShortVersionString") == version and
            info.get("CFBundleExecutable") == "NeAntik Browser",
            "Chromium 156.80 app plist identity mismatch")
    require(digest(binary_path) == evidence.get("browserExecutableSHA256"),
            "Chromium 156.80 browser executable changed since authenticated build")
    from chromium_15680_portable_crc import verify as verify_portable_crc
    portable = verify_portable_crc(root, contract)
    expected_framework = (portable["outputs"]["frameworkSHA256"] if portable
                          else evidence.get("frameworkSHA256"))
    if runtime_lock is not None:
        from chromium_15680_privacy_derivation import verify_lock_binding, verify_contract as verify_privacy
        verify_lock_binding(runtime_lock, root)
        _, layer = verify_privacy(root)
        expected_framework = layer["link"]["frameworkSHA256"]
    require(digest(framework_path) == expected_framework,
            "Chromium 156.80 framework differs from selected base/derived build evidence")
    verify_embedded_framework(app, version, out_dir, expected_framework)
    for binary in (binary_path, framework_path, embedded_framework):
        subprocess.run(["/usr/bin/lipo", "-verify_arch", "arm64", str(binary)],
                       check=True, stdout=subprocess.DEVNULL)
    print("PASS: arm64 Chromium 156.0.8078.80 output matches selected unqualified build evidence.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, json.JSONDecodeError, subprocess.SubprocessError) as error:
        print("Unsigned Chromium 156.80 candidate rejected: " + str(error), file=sys.stderr)
        raise SystemExit(1)
