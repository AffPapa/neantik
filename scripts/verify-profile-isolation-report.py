#!/usr/bin/env python3
"""Validate a minimized, local profile-isolation evidence report.

This is a contract verifier only. It does not inspect profile directories,
launch Chromium, or prove real runtime isolation.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


MAX_JSON_BYTES = 16 * 1024
MAX_PROFILES = 100_000
ALLOWED_KEYS = {
    "status",
    "profileCount",
    "distinctBrowserDataDirectories",
    "distinctIdentitySeeds",
    "sharedCookieStores",
    "sharedLockFiles",
    "concurrentLaunchBlocked",
    "recoveryState",
    "generatedAt",
    "runtimeHash",
}
REQUIRED_KEYS = ALLOWED_KEYS - {"runtimeHash"}
STATUSES = {"verified", "partial", "failed", "blocked", "unverified"}
RECOVERY_STATES = {"clean", "recovered", "required", "failed", "unknown"}
SHA256_RE = re.compile(r"[0-9a-f]{64}")


class ProfileIsolationReportError(ValueError):
    """Raised when a report is malformed, over-specified, or unsafe."""


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ProfileIsolationReportError(
                f"Duplicate JSON field is not allowed: {key!r}"
            )
        result[key] = value
    return result


def _reject_constants(value: str) -> Any:
    raise ProfileIsolationReportError(
        f"Non-standard JSON number is not allowed: {value}"
    )


def _load_json(path: Path) -> dict[str, Any]:
    try:
        raw = sys.stdin.buffer.read() if str(path) == "-" else path.read_bytes()
    except OSError as error:
        raise ProfileIsolationReportError(f"Cannot read report: {error}") from error
    if len(raw) > MAX_JSON_BYTES:
        raise ProfileIsolationReportError(
            f"Report exceeds maximum size of {MAX_JSON_BYTES} bytes"
        )
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_constants,
        )
    except UnicodeDecodeError as error:
        raise ProfileIsolationReportError("Report must be UTF-8 JSON") from error
    except json.JSONDecodeError as error:
        raise ProfileIsolationReportError(f"Invalid JSON: {error.msg}") from error
    if not isinstance(value, dict):
        raise ProfileIsolationReportError("Report root must be a JSON object")
    return value


def _require_string(report: dict[str, Any], key: str, allowed: set[str]) -> str:
    value = report.get(key)
    if not isinstance(value, str) or value not in allowed:
        raise ProfileIsolationReportError(
            f"{key} must be one of: {', '.join(sorted(allowed))}"
        )
    return value


def _require_bool(report: dict[str, Any], key: str) -> bool:
    value = report.get(key)
    if type(value) is not bool:
        raise ProfileIsolationReportError(f"{key} must be a boolean")
    return value


def _require_count(report: dict[str, Any], key: str) -> int:
    value = report.get(key)
    if type(value) is not int or not 0 <= value <= MAX_PROFILES:
        raise ProfileIsolationReportError(
            f"{key} must be an integer between 0 and {MAX_PROFILES}"
        )
    return value


def _require_timestamp(report: dict[str, Any]) -> None:
    value = report.get("generatedAt")
    if not isinstance(value, str) or len(value) > 40:
        raise ProfileIsolationReportError(
            "generatedAt must be a bounded RFC3339 UTC string"
        )
    if not value.endswith("Z"):
        raise ProfileIsolationReportError("generatedAt must use UTC and end with Z")
    try:
        datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise ProfileIsolationReportError(
            "generatedAt must be a valid RFC3339 timestamp"
        ) from error


def validate_report(report: dict[str, Any]) -> dict[str, Any]:
    """Validate and return the same report without enriching its claims."""
    if not REQUIRED_KEYS <= set(report) or not set(report) <= ALLOWED_KEYS:
        missing = sorted(REQUIRED_KEYS - set(report))
        extra = sorted(set(report) - ALLOWED_KEYS)
        details = []
        if missing:
            details.append(f"missing fields: {', '.join(missing)}")
        if extra:
            details.append(f"unsupported fields: {', '.join(extra)}")
        raise ProfileIsolationReportError("; ".join(details))

    status = _require_string(report, "status", STATUSES)
    profile_count = _require_count(report, "profileCount")
    distinct_directories = _require_count(
        report, "distinctBrowserDataDirectories"
    )
    distinct_seeds = _require_count(report, "distinctIdentitySeeds")
    shared_cookie_stores = _require_count(report, "sharedCookieStores")
    shared_lock_files = _require_count(report, "sharedLockFiles")
    concurrent_launch_blocked = _require_bool(report, "concurrentLaunchBlocked")
    recovery_state = _require_string(report, "recoveryState", RECOVERY_STATES)
    _require_timestamp(report)

    if profile_count < 1:
        raise ProfileIsolationReportError("profileCount must be at least 1")
    for key, value in (
        ("distinctBrowserDataDirectories", distinct_directories),
        ("distinctIdentitySeeds", distinct_seeds),
        ("sharedCookieStores", shared_cookie_stores),
        ("sharedLockFiles", shared_lock_files),
    ):
        if value > profile_count:
            raise ProfileIsolationReportError(
                f"{key} cannot exceed profileCount"
            )

    runtime_hash = report.get("runtimeHash")
    if runtime_hash is not None and (
        not isinstance(runtime_hash, str) or not SHA256_RE.fullmatch(runtime_hash)
    ):
        raise ProfileIsolationReportError(
            "runtimeHash must be a lowercase 64-character digest"
        )

    if status == "verified" and (
        distinct_directories != profile_count
        or distinct_seeds != profile_count
        or shared_cookie_stores != 0
        or shared_lock_files != 0
        or not concurrent_launch_blocked
        or recovery_state != "clean"
    ):
        raise ProfileIsolationReportError(
            "verified requires one distinct directory and identity seed per "
            "profile, zero shared stores/locks, blocked concurrent launch, "
            "and recoveryState=clean"
        )
    if status == "failed" and (
        distinct_directories == profile_count
        and distinct_seeds == profile_count
        and shared_cookie_stores == 0
        and shared_lock_files == 0
        and concurrent_launch_blocked
        and recovery_state == "clean"
    ):
        raise ProfileIsolationReportError(
            "failed must identify at least one failed isolation condition"
        )
    if status == "blocked" and recovery_state not in {"required", "failed", "unknown"}:
        raise ProfileIsolationReportError(
            "blocked requires recoveryState=required, failed, or unknown"
        )
    return report


def verify_path(path: Path) -> str:
    validate_report(_load_json(path))
    return "valid profile isolation report"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate a minimized NeAntik profile-isolation report."
    )
    parser.add_argument(
        "report",
        type=Path,
        help="JSON report path, or - to read JSON from stdin",
    )
    args = parser.parse_args(argv)
    try:
        print(verify_path(args.report))
    except ProfileIsolationReportError as error:
        print(f"invalid profile isolation report: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
