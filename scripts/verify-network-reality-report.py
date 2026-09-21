#!/usr/bin/env python3
"""Validate a minimized, local effective-network evidence report.

This is a contract verifier only. It does not perform network requests and
does not turn configured proxy/DNS settings into observed network evidence.
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
ALLOWED_KEYS = {
    "status",
    "routeMode",
    "effectiveHTTPRouteObserved",
    "dnsPath",
    "negotiatedProtocol",
    "tlsObserved",
    "webrtcDirectCandidates",
    "bypassDetected",
    "generatedAt",
    "runtimeHash",
}
REQUIRED_KEYS = ALLOWED_KEYS - {"runtimeHash"}
STATUSES = {"verified", "partial", "failed", "blocked", "unverified"}
ROUTE_MODES = {"direct", "proxied", "unknown"}
DNS_PATHS = {"observed", "not_observed", "blocked"}
PROTOCOLS = {"http1", "http2", "http3", "unknown"}
SHA256_RE = re.compile(r"[0-9a-f]{64}")


class NetworkRealityReportError(ValueError):
    """Raised when a report is malformed, over-specified, or unsafe."""


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise NetworkRealityReportError(
                f"Duplicate JSON field is not allowed: {key!r}"
            )
        result[key] = value
    return result


def _reject_constants(value: str) -> Any:
    raise NetworkRealityReportError(
        f"Non-standard JSON number is not allowed: {value}"
    )


def _load_json(path: Path) -> dict[str, Any]:
    try:
        raw = sys.stdin.buffer.read() if str(path) == "-" else path.read_bytes()
    except OSError as error:
        raise NetworkRealityReportError(f"Cannot read report: {error}") from error
    if len(raw) > MAX_JSON_BYTES:
        raise NetworkRealityReportError(
            f"Report exceeds maximum size of {MAX_JSON_BYTES} bytes"
        )
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_constants,
        )
    except UnicodeDecodeError as error:
        raise NetworkRealityReportError("Report must be UTF-8 JSON") from error
    except json.JSONDecodeError as error:
        raise NetworkRealityReportError(f"Invalid JSON: {error.msg}") from error
    if not isinstance(value, dict):
        raise NetworkRealityReportError("Report root must be a JSON object")
    return value


def _require_string(report: dict[str, Any], key: str, allowed: set[str]) -> str:
    value = report.get(key)
    if not isinstance(value, str) or value not in allowed:
        raise NetworkRealityReportError(
            f"{key} must be one of: {', '.join(sorted(allowed))}"
        )
    return value


def _require_bool(report: dict[str, Any], key: str) -> bool:
    value = report.get(key)
    if type(value) is not bool:
        raise NetworkRealityReportError(f"{key} must be a boolean")
    return value


def _require_nonnegative_count(report: dict[str, Any], key: str) -> int:
    value = report.get(key)
    if type(value) is not int or value < 0:
        raise NetworkRealityReportError(f"{key} must be a non-negative integer")
    return value


def _require_timestamp(report: dict[str, Any]) -> None:
    value = report.get("generatedAt")
    if not isinstance(value, str):
        raise NetworkRealityReportError("generatedAt must be an RFC3339 string")
    if not value.endswith("Z"):
        raise NetworkRealityReportError("generatedAt must use UTC and end with Z")
    try:
        datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise NetworkRealityReportError(
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
        raise NetworkRealityReportError("; ".join(details))

    status = _require_string(report, "status", STATUSES)
    route_mode = _require_string(report, "routeMode", ROUTE_MODES)
    effective_route = _require_bool(report, "effectiveHTTPRouteObserved")
    dns_path = _require_string(report, "dnsPath", DNS_PATHS)
    protocol = _require_string(report, "negotiatedProtocol", PROTOCOLS)
    tls_observed = _require_bool(report, "tlsObserved")
    direct_candidates = _require_nonnegative_count(
        report, "webrtcDirectCandidates"
    )
    bypass_detected = _require_bool(report, "bypassDetected")
    _require_timestamp(report)

    runtime_hash = report.get("runtimeHash")
    if runtime_hash is not None and (
        not isinstance(runtime_hash, str) or not SHA256_RE.fullmatch(runtime_hash)
    ):
        raise NetworkRealityReportError(
            "runtimeHash must be a lowercase 64-character digest"
        )

    if status == "verified" and (
        route_mode == "unknown"
        or not effective_route
        or dns_path != "observed"
        or protocol == "unknown"
        or not tls_observed
        or bypass_detected
        or direct_candidates != 0
    ):
        raise NetworkRealityReportError(
            "verified requires an observed route, DNS, protocol, TLS, zero "
            "direct WebRTC candidates, and no bypass"
        )
    if status == "failed" and not (
        bypass_detected
        or (route_mode == "proxied" and direct_candidates > 0)
    ):
        raise NetworkRealityReportError(
            "failed requires bypassDetected or direct WebRTC candidates on a proxied route"
        )
    if status == "blocked" and dns_path != "blocked":
        raise NetworkRealityReportError("blocked requires dnsPath=blocked")
    if route_mode == "proxied" and direct_candidates > 0 and status == "verified":
        raise NetworkRealityReportError(
            "a proxied route with direct WebRTC candidates cannot be verified"
        )
    return report


def verify_path(path: Path) -> str:
    validate_report(_load_json(path))
    return "valid network reality report"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate a minimized NeAntik effective-network evidence report."
    )
    parser.add_argument(
        "report",
        type=Path,
        help="JSON report path, or - to read JSON from stdin",
    )
    args = parser.parse_args(argv)
    try:
        print(verify_path(args.report))
    except NetworkRealityReportError as error:
        print(f"invalid network reality report: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
