#!/usr/bin/env python3
"""Run the bounded local NeAntik evidence checks and emit one safe summary.

This runner never publishes, downloads, signs, or mutates runtime/release
state. It intentionally reports Chromium baseline/rebase blockers instead of
turning them into successes.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def _run(
    command: list[str],
    timeout: int = 120,
    input_text: str | None = None,
) -> tuple[int, str, str]:
    result = subprocess.run(
        command,
        cwd=ROOT,
        capture_output=True,
        input=input_text,
        text=True,
        check=False,
        timeout=timeout,
    )
    return result.returncode, result.stdout, result.stderr


def _status_for_exit(code: int, stdout: str, stderr: str, expected_blocker: str | None) -> str:
    combined = f"{stdout}\n{stderr}"
    if code == 0:
        return "verified"
    if expected_blocker and expected_blocker in combined:
        return "blocked"
    return "failed"


def run_check(
    check_id: str,
    command: list[str],
    *,
    timeout: int = 120,
    expected_blocker: str | None = None,
    verifier_command: list[str] | None = None,
) -> dict[str, object]:
    result: dict[str, object] = {
        "id": check_id,
        "status": "failed",
        "exitCode": 126,
    }
    try:
        code, stdout, stderr = _run(command, timeout)
        status = _status_for_exit(code, stdout, stderr, expected_blocker)
        if code == 0:
            try:
                payload = json.loads(stdout.strip().splitlines()[-1])
            except (json.JSONDecodeError, IndexError):
                payload = None
            if isinstance(payload, dict) and payload.get("status") in {
                "partial",
                "unverified",
                "blocked",
                "failed",
                "verified",
            }:
                status = str(payload["status"])
            if verifier_command is not None:
                report_line = stdout.strip().splitlines()[-1]
                verifier_code, _, _ = _run(
                    verifier_command,
                    timeout,
                    input_text=report_line,
                )
                result["verifierExitCode"] = verifier_code
                if verifier_code != 0:
                    status = "failed"
        result["status"] = status
        result["exitCode"] = code
    except subprocess.TimeoutExpired:
        code = 124
        result["status"] = "blocked"
        result["exitCode"] = code
    except OSError:
        code = 126
        result["status"] = "failed"
        result["exitCode"] = code
    return result


def run_audit() -> dict[str, object]:
    checks = [
        run_check(
            "profile-isolation-harness",
            [sys.executable, "scripts/run-profile-isolation-harness.py", "--count", "3", "--json"],
            verifier_command=[
                sys.executable,
                "scripts/verify-profile-isolation-report.py",
                "-",
            ],
        ),
        run_check(
            "network-reality-harness",
            [sys.executable, "scripts/run-network-reality-harness.py", "--json"],
            verifier_command=[
                sys.executable,
                "scripts/verify-network-reality-report.py",
                "-",
            ],
        ),
        run_check(
            "runtime-security-baseline",
            [
                sys.executable,
                "scripts/verify-runtime-security-baseline.py",
                "--today",
                datetime.now(timezone.utc).date().isoformat(),
            ],
            expected_blocker="below the security baseline",
        ),
        run_check(
            "runtime-rebase-preflight",
            [
                sys.executable,
                "scripts/preflight-runtime-rebase-150.py",
                "/private/tmp/neantik-local-audit-rebase",
                "--plan",
                "runtime/chromium-152-rebase-plan.json",
                "--free-gib",
                "100",
                "--json",
            ],
            expected_blocker="below security baseline",
        ),
    ]
    statuses = {str(check["status"]) for check in checks}
    if "failed" in statuses:
        overall = "failed"
    elif "blocked" in statuses or "partial" in statuses or "unverified" in statuses:
        overall = "partial"
    else:
        overall = "verified"
    return {
        "schemaVersion": 1,
        "overallStatus": overall,
        "generatedAt": _now(),
        "checks": checks,
        "releaseDecision": "blocked-until-exact-runtime-and-live-gates",
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit compact JSON")
    args = parser.parse_args(argv)
    report = run_audit()
    print(
        json.dumps(
            report,
            ensure_ascii=False,
            separators=(",", ":") if args.json else None,
            indent=None if args.json else 2,
        )
    )
    return 0 if report["overallStatus"] != "failed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
