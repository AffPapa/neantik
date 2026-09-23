#!/usr/bin/env python3
"""Validate minimized performance evidence for an exact NeAntik runtime."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import re
import sys
from pathlib import Path
from typing import Any


MAX_JSON_BYTES = 64 * 1024
ALLOWED_ROOT_KEYS = {
    "schemaVersion",
    "status",
    "runtimeVersion",
    "runtimeHash",
    "generatedAt",
    "sampleCount",
    "coldStartMs",
    "warmStartMs",
    "idleCpuPercent",
    "idleMemoryMiB",
}
METRIC_NAMES = (
    "coldStartMs",
    "warmStartMs",
    "idleCpuPercent",
    "idleMemoryMiB",
)
METRIC_BUDGETS = {
    "coldStartMs": {"p50": 1_500.0, "p95": 3_000.0},
    "warmStartMs": {"p50": 500.0, "p95": 1_000.0},
    "idleCpuPercent": {"p50": 5.0, "p95": 15.0},
    "idleMemoryMiB": {"p50": 600.0, "p95": 1_000.0},
}
VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$")
HASH_PATTERN = re.compile(r"^[0-9a-f]{64}$")
ALLOWED_STATUSES = {"verified", "partial", "failed", "blocked", "unverified"}


class RuntimePerformanceReportError(ValueError):
    pass


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise RuntimePerformanceReportError(
                f"duplicate JSON key: {key}"
            )
        result[key] = value
    return result


def _reject_nonstandard_number(value: str) -> None:
    raise RuntimePerformanceReportError(
        f"non-standard JSON number: {value}"
    )


def load_report(source: str) -> dict[str, Any]:
    if source == "-":
        raw = sys.stdin.buffer.read(MAX_JSON_BYTES + 1)
    else:
        path = Path(source)
        try:
            if path.stat().st_size > MAX_JSON_BYTES:
                raise RuntimePerformanceReportError(
                    f"report exceeds {MAX_JSON_BYTES} bytes"
                )
            raw = path.read_bytes()
        except OSError as error:
            raise RuntimePerformanceReportError(
                f"cannot read report: {error}"
            ) from error

    if len(raw) > MAX_JSON_BYTES:
        raise RuntimePerformanceReportError(
            f"report exceeds {MAX_JSON_BYTES} bytes"
        )
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_nonstandard_number,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RuntimePerformanceReportError(
            f"invalid UTF-8 JSON report: {error}"
        ) from error
    if not isinstance(value, dict):
        raise RuntimePerformanceReportError("report root must be an object")
    return value


def _require_finite_nonnegative_number(
    value: Any,
    field: str,
) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RuntimePerformanceReportError(
            f"{field} must be a finite non-negative number"
        )
    numeric = float(value)
    if not math.isfinite(numeric) or numeric < 0:
        raise RuntimePerformanceReportError(
            f"{field} must be a finite non-negative number"
        )
    return numeric


def _validate_metric(name: str, value: Any) -> bool:
    if not isinstance(value, dict) or set(value) != {"p50", "p95"}:
        raise RuntimePerformanceReportError(
            f"{name} must contain exactly p50 and p95"
        )
    numeric_values: dict[str, float] = {}
    for percentile in ("p50", "p95"):
        raw = value[percentile]
        if raw is None:
            continue
        numeric_values[percentile] = _require_finite_nonnegative_number(
            raw,
            f"{name}.{percentile}",
        )
    if "p50" in numeric_values and "p95" in numeric_values:
        if numeric_values["p50"] > numeric_values["p95"]:
            raise RuntimePerformanceReportError(
                f"{name}.p50 cannot exceed p95"
            )
    return len(numeric_values) == 2


def _validate_timestamp(value: Any) -> None:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise RuntimePerformanceReportError(
            "generatedAt must be an RFC3339 UTC timestamp ending in Z"
        )
    try:
        parsed = dt.datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise RuntimePerformanceReportError(
            "generatedAt must be an RFC3339 UTC timestamp ending in Z"
        ) from error
    if parsed.tzinfo is None or parsed.utcoffset() != dt.timedelta(0):
        raise RuntimePerformanceReportError(
            "generatedAt must use UTC"
        )


def validate_report(
    report: dict[str, Any],
    *,
    require_verified: bool = False,
) -> None:
    if set(report) != ALLOWED_ROOT_KEYS:
        missing = sorted(ALLOWED_ROOT_KEYS - set(report))
        extra = sorted(set(report) - ALLOWED_ROOT_KEYS)
        raise RuntimePerformanceReportError(
            f"root keys mismatch; missing={missing}, extra={extra}"
        )
    if report["schemaVersion"] != 1:
        raise RuntimePerformanceReportError("schemaVersion must be 1")
    status = report["status"]
    if status not in ALLOWED_STATUSES:
        raise RuntimePerformanceReportError(
            f"unsupported status: {status}"
        )
    if require_verified and status != "verified":
        raise RuntimePerformanceReportError(
            "release mode requires status=verified"
        )

    runtime_version = report["runtimeVersion"]
    if runtime_version is not None and (
        not isinstance(runtime_version, str)
        or not VERSION_PATTERN.fullmatch(runtime_version)
    ):
        raise RuntimePerformanceReportError(
            "runtimeVersion must be a Chromium-style version or null"
        )
    runtime_hash = report["runtimeHash"]
    if runtime_hash is not None and (
        not isinstance(runtime_hash, str)
        or not HASH_PATTERN.fullmatch(runtime_hash)
    ):
        raise RuntimePerformanceReportError(
            "runtimeHash must be a lowercase SHA-256 digest or null"
        )
    _validate_timestamp(report["generatedAt"])

    sample_count = report["sampleCount"]
    if isinstance(sample_count, bool) or not isinstance(sample_count, int):
        raise RuntimePerformanceReportError("sampleCount must be an integer")
    if sample_count < 0 or sample_count > 10_000:
        raise RuntimePerformanceReportError(
            "sampleCount must be between 0 and 10000"
        )

    complete_metrics = {
        name: _validate_metric(name, report[name]) for name in METRIC_NAMES
    }
    if status == "verified":
        if runtime_version is None or runtime_hash is None:
            raise RuntimePerformanceReportError(
                "verified report requires runtimeVersion and runtimeHash"
            )
        if sample_count < 3:
            raise RuntimePerformanceReportError(
                "verified report requires at least three samples"
            )
        if not all(complete_metrics.values()):
            raise RuntimePerformanceReportError(
                "verified report requires all metric percentiles"
            )
        for metric_name in METRIC_NAMES:
            metric = report[metric_name]
            for percentile in ("p50", "p95"):
                measured = float(metric[percentile])
                budget = METRIC_BUDGETS[metric_name][percentile]
                if measured > budget:
                    raise RuntimePerformanceReportError(
                        f"verified report exceeds {metric_name}.{percentile} budget"
                    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Validate minimized exact-runtime performance evidence; this "
            "does not measure Chromium itself."
        )
    )
    parser.add_argument("report", help="JSON report path, or - for stdin")
    parser.add_argument(
        "--require-verified",
        action="store_true",
        help="reject partial/unverified reports for a release gate",
    )
    arguments = parser.parse_args()
    try:
        report = load_report(arguments.report)
        validate_report(report, require_verified=arguments.require_verified)
    except (OSError, RuntimePerformanceReportError) as error:
        print(f"runtime performance report rejected: {error}", file=sys.stderr)
        return 1
    print(
        "valid runtime performance report; producer/runtime provenance "
        "must be checked separately"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
