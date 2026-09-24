#!/usr/bin/env python3
"""Read-only, privacy-safe snapshot of local NeAntik release evidence."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run_git(*args: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(ROOT), *args], check=True,
            capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout.strip()


def safe_gate_value(key: str, value: object) -> str:
    allowed = {
        "developerId": {"passed", "failed", "blocked", "not-run"},
        "notarization": {"accepted", "rejected", "blocked", "not-run"},
        "stapling": {"passed", "failed", "blocked", "not-run"},
        "gatekeeper": {"passed", "failed", "blocked", "not-run"},
        "hostedDownload": {"passed", "failed", "blocked", "not-run"},
    }
    return value if isinstance(value, str) and value in allowed[key] else "unknown"


def summary() -> dict[str, object]:
    releases = []
    for path in (ROOT / "releases").glob("v*.json"):
        if path.is_symlink() or not re.fullmatch(r"v\d+\.\d+\.\d+\.json", path.name):
            continue
        try:
            item = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(item, dict) and re.fullmatch(r"\d+\.\d+\.\d+", str(item.get("version", ""))):
                releases.append(item)
        except (OSError, json.JSONDecodeError):
            continue
    latest = max(
        releases,
        key=lambda item: tuple(int(part) for part in item.get("version", "0.0.0").split(".")),
        default=None,
    )
    head = run_git("rev-parse", "HEAD")
    branch = run_git("branch", "--show-current")
    changed = run_git("status", "--porcelain")
    changed_count = len(changed.splitlines()) if changed is not None else None
    manifest = ROOT / "dist" / "direct-candidate-manifest.json"
    source = ROOT / "dist" / "direct-candidate-source.json"
    candidate = "missing"
    if manifest.is_symlink() or source.is_symlink():
        candidate = "invalid"
    elif manifest.is_file() and source.is_file():
        try:
            manifest_bytes = manifest.read_bytes()
            candidate_data = json.loads(manifest_bytes)
            source_data = json.loads(source.read_text(encoding="utf-8"))
            tree = run_git("rev-parse", "HEAD^{tree}")
            if not isinstance(candidate_data, dict) or not isinstance(source_data, dict):
                candidate = "invalid"
            elif not re.fullmatch(r"[0-9a-f]{40}", str(source_data.get("commit", ""))) or not re.fullmatch(r"[0-9a-f]{40}", str(source_data.get("tree", ""))) or not re.fullmatch(r"[0-9a-f]{64}", str(source_data.get("manifestSHA256", ""))):
                candidate = "invalid"
            elif source_data.get("manifestSHA256") != hashlib.sha256(manifest_bytes).hexdigest():
                candidate = "invalid"
            elif source_data.get("commit") != head or source_data.get("tree") != tree:
                candidate = "stale"
            elif changed_count is None or changed_count != 0:
                candidate = "blocked"
            else:
                candidate = "pass"
        except (OSError, json.JSONDecodeError):
            candidate = "invalid"
    release_version = latest.get("version") if latest else None
    release_tag = latest.get("tag") if latest else None
    release_build = latest.get("build") if latest else None
    runtime = latest.get("runtime") if latest else None
    verification = latest.get("verification") if latest else None
    release_valid = bool(
        latest
        and isinstance(release_version, str)
        and re.fullmatch(r"\d+\.\d+\.\d+", release_version)
        and release_tag == "v" + release_version
        and isinstance(release_build, int)
        and not isinstance(release_build, bool)
        and 1 <= release_build <= 999_999
        and isinstance(runtime, dict)
        and isinstance(runtime.get("chromiumVersion"), str)
        and re.fullmatch(r"\d+(?:\.\d+){2,3}", runtime["chromiumVersion"])
    )
    recorded_gates = {}
    if isinstance(verification, dict):
        recorded_gates = {
            key: safe_gate_value(key, verification.get(key))
            for key in ("developerId", "notarization", "stapling", "gatekeeper", "hostedDownload")
        }
    rollback = latest.get("rollbackRelease") if latest else None
    if not isinstance(rollback, str) or not re.fullmatch(r"v\d+\.\d+\.\d+", rollback):
        rollback = None
    return {
        "schemaVersion": 1,
        "privacy": "No credentials, filesystem paths, URLs, proxy values, or fingerprint data are emitted.",
        "checkout": {
            "state": "blocked" if changed_count is None or changed_count > 0 else "pass",
            "branch": branch or "unknown",
            "head": head[:12] if head else "unknown",
            "changedFileCount": changed_count,
        },
        "candidate": {"state": candidate},
        "latestRecordedRelease": {
            "state": "stale" if release_valid else ("invalid" if latest else "missing"),
            "tag": release_tag if release_valid else None,
            "version": release_version if release_valid else None,
            "build": release_build if release_valid else None,
            "chromiumVersion": runtime.get("chromiumVersion") if release_valid else None,
            "rollbackRelease": rollback,
            "recordedGates": recorded_gates,
            "note": "Историческая запись не является текущей проверкой подписи, notarization или hosted assets.",
        },
        "candidateGates": {
            "signing": "not-run",
            "notarization": "not-run",
            "gatekeeper": "not-run",
            "githubAccess": "not-run",
            "hostedDownload": "not-run",
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    args = parser.parse_args()
    result = summary()
    if args.json:
        print(json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2))
    else:
        checkout = result["checkout"]
        release = result["latestRecordedRelease"]
        print(f"Checkout: {checkout['state']} · {checkout['branch']} · {checkout['head']} · changed files: {checkout['changedFileCount']}")
        print(f"Candidate source binding: {result['candidate']['state']}")
        print(f"Last recorded release: {release['tag'] or 'none'} ({release['state']}); recorded gates are historical")
        print("New-candidate signing / notarization / Gatekeeper / GitHub / hosted checks: not-run")
        print("Read-only summary; no credentials or raw fingerprint evidence read.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
