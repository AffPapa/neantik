#!/usr/bin/env python3
"""Validate the privacy-safe NeAntik support-bundle contract.

The bundle is an allowlisted status snapshot, not a dump of application
state. It intentionally has no free-form text, profile identifiers, paths,
URLs, cookies, proxy values, network addresses, or fingerprint surfaces.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from pathlib import Path
from typing import Any


MAX_JSON_BYTES = 64 * 1024
VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?$")
BUILD_PATTERN = re.compile(r"^[0-9]{1,12}$")
HASH_PATTERN = re.compile(r"^[0-9a-f]{64}$")
ALLOWED_STATUSES = {"verified", "partial", "failed", "blocked", "unverified"}
ALLOWED_RUNTIME_STATUSES = {
    "ready",
    "attention",
    "unavailable",
    "unknown",
}
ALLOWED_SIGNATURES = {"valid", "invalid", "unverified", "unknown"}
ALLOWED_CHECKS = {
    "profileIsolation",
    "networkReality",
    "runtimeSecurity",
    "runtimePerformance",
    "fingerprintAudit",
    "releaseProvenance",
    "secretAudit",
}
ROOT_KEYS = {
    "schemaVersion",
    "generatedAt",
    "manager",
    "runtime",
    "workspace",
    "health",
    "checks",
    "performance",
}
MANAGER_KEYS = {"version", "build"}
RUNTIME_KEYS = {"status", "version", "architecture", "signature", "executableHash", "frameworkHash"}
WORKSPACE_KEYS = {"profileCount", "activeProfileCount", "archivedProfileCount", "folderCount"}
HEALTH_KEYS = {"failureCount", "attentionCount", "recoveryCount"}
PERFORMANCE_KEYS = {"managerStatus", "runtimeStatus"}
CHECK_KEYS = {"id", "status"}


class RedactedSupportBundleError(ValueError):
    pass


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise RedactedSupportBundleError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_nonstandard_number(value: str) -> None:
    raise RedactedSupportBundleError(f"non-standard JSON number: {value}")


def load_bundle(source: str) -> dict[str, Any]:
    if source == "-":
        raw = sys.stdin.buffer.read(MAX_JSON_BYTES + 1)
    else:
        path = Path(source)
        try:
            if path.stat().st_size > MAX_JSON_BYTES:
                raise RedactedSupportBundleError(
                    f"bundle exceeds {MAX_JSON_BYTES} bytes"
                )
            raw = path.read_bytes()
        except OSError as error:
            raise RedactedSupportBundleError(
                f"cannot read bundle: {error}"
            ) from error
    if len(raw) > MAX_JSON_BYTES:
        raise RedactedSupportBundleError(
            f"bundle exceeds {MAX_JSON_BYTES} bytes"
        )
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_nonstandard_number,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RedactedSupportBundleError(
            f"invalid UTF-8 JSON bundle: {error}"
        ) from error
    if not isinstance(value, dict):
        raise RedactedSupportBundleError("bundle root must be an object")
    return value


def _exact_keys(value: Any, expected: set[str], field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise RedactedSupportBundleError(f"{field} must be an object")
    actual = set(value)
    if actual != expected:
        raise RedactedSupportBundleError(
            f"{field} keys mismatch; missing={sorted(expected - actual)}, "
            f"extra={sorted(actual - expected)}"
        )
    return value


def _bounded_count(value: Any, field: str) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 100_000:
        raise RedactedSupportBundleError(
            f"{field} must be an integer between 0 and 100000"
        )


def _validate_timestamp(value: Any) -> None:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise RedactedSupportBundleError(
            "generatedAt must be an RFC3339 UTC timestamp ending in Z"
        )
    try:
        parsed = dt.datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise RedactedSupportBundleError(
            "generatedAt must be an RFC3339 UTC timestamp ending in Z"
        ) from error
    if parsed.tzinfo is None or parsed.utcoffset() != dt.timedelta(0):
        raise RedactedSupportBundleError("generatedAt must use UTC")


def _validate_version(value: Any, field: str) -> None:
    if not isinstance(value, str) or not VERSION_PATTERN.fullmatch(value):
        raise RedactedSupportBundleError(f"{field} must be a version")


def _validate_optional_hash(value: Any, field: str) -> None:
    if value is not None and (
        not isinstance(value, str) or not HASH_PATTERN.fullmatch(value)
    ):
        raise RedactedSupportBundleError(
            f"{field} must be a lowercase SHA-256 digest or null"
        )


def validate_bundle(bundle: dict[str, Any]) -> None:
    _exact_keys(bundle, ROOT_KEYS, "bundle")
    if bundle["schemaVersion"] != 1:
        raise RedactedSupportBundleError("schemaVersion must be 1")
    _validate_timestamp(bundle["generatedAt"])

    manager = _exact_keys(bundle["manager"], MANAGER_KEYS, "manager")
    _validate_version(manager["version"], "manager.version")
    if not isinstance(manager["build"], str) or not BUILD_PATTERN.fullmatch(manager["build"]):
        raise RedactedSupportBundleError("manager.build must be a bounded build number")

    runtime = _exact_keys(bundle["runtime"], RUNTIME_KEYS, "runtime")
    if runtime["status"] not in ALLOWED_RUNTIME_STATUSES:
        raise RedactedSupportBundleError("runtime.status is not allowed")
    if runtime["version"] is not None:
        _validate_version(runtime["version"], "runtime.version")
    if runtime["architecture"] not in {"arm64", "unknown"}:
        raise RedactedSupportBundleError(
            "runtime.architecture must be arm64 or unknown"
        )
    if runtime["signature"] not in ALLOWED_SIGNATURES:
        raise RedactedSupportBundleError("runtime.signature is not allowed")
    _validate_optional_hash(runtime["executableHash"], "runtime.executableHash")
    _validate_optional_hash(runtime["frameworkHash"], "runtime.frameworkHash")

    workspace = _exact_keys(bundle["workspace"], WORKSPACE_KEYS, "workspace")
    for field in WORKSPACE_KEYS:
        _bounded_count(workspace[field], f"workspace.{field}")
    if workspace["activeProfileCount"] > workspace["profileCount"]:
        raise RedactedSupportBundleError(
            "workspace.activeProfileCount cannot exceed profileCount"
        )
    if workspace["archivedProfileCount"] > workspace["profileCount"]:
        raise RedactedSupportBundleError(
            "workspace.archivedProfileCount cannot exceed profileCount"
        )

    health = _exact_keys(bundle["health"], HEALTH_KEYS, "health")
    for field in HEALTH_KEYS:
        _bounded_count(health[field], f"health.{field}")

    checks = bundle["checks"]
    if not isinstance(checks, list) or not 0 <= len(checks) <= len(ALLOWED_CHECKS):
        raise RedactedSupportBundleError("checks must contain at most seven entries")
    seen: set[str] = set()
    for index, item in enumerate(checks):
        check = _exact_keys(item, CHECK_KEYS, f"checks[{index}]")
        if check["id"] not in ALLOWED_CHECKS:
            raise RedactedSupportBundleError(f"checks[{index}].id is not allowed")
        if check["id"] in seen:
            raise RedactedSupportBundleError(f"duplicate check id: {check['id']}")
        seen.add(check["id"])
        if check["status"] not in ALLOWED_STATUSES:
            raise RedactedSupportBundleError(
                f"checks[{index}].status is not allowed"
            )

    performance = _exact_keys(bundle["performance"], PERFORMANCE_KEYS, "performance")
    if performance["managerStatus"] not in ALLOWED_STATUSES:
        raise RedactedSupportBundleError("performance.managerStatus is not allowed")
    if performance["runtimeStatus"] not in ALLOWED_STATUSES:
        raise RedactedSupportBundleError("performance.runtimeStatus is not allowed")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate a privacy-safe NeAntik support-bundle JSON."
    )
    parser.add_argument("bundle", help="JSON bundle path, or - for stdin")
    arguments = parser.parse_args()
    try:
        validate_bundle(load_bundle(arguments.bundle))
    except (OSError, RedactedSupportBundleError) as error:
        print(f"redacted support bundle rejected: {error}", file=sys.stderr)
        return 1
    print("valid redacted support bundle; no raw profile or network evidence")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
