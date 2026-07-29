#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


CRITICAL_KEYS = [
    "canvas",
    "webgl_pixels",
    "audio",
    "client_rects",
]
PUBLIC_ALPHA_STABLE_CONTEXT_KEYS = [
    "webgl_vendor",
    "webgl_renderer",
    "webgl_extensions",
    "webgpu_policy",
    "user_agent",
    "platform",
    "client_hints",
    "screen",
    "hardware_concurrency",
    "device_memory",
    "touch_points",
    "fonts",
    "languages",
    "timezone",
]
PRODUCTION_EXTENDED_CONTEXT_KEYS = [
    "audio_repeat",
    "canvas_repeat",
    "client_rects_repeat",
    "webgl_pixels_repeat",
    "webgl_shader_precision",
    "css_screen_match",
    "intl_locale",
    "worker_canvas",
    "worker_webgl_pixels",
    "worker_webgl_vendor",
    "worker_webgl_renderer",
    "worker_webgl_extensions",
    "worker_webgl_shader_precision",
    "worker_user_agent",
    "worker_platform",
    "worker_languages",
    "worker_timezone",
    "worker_intl_locale",
    "worker_hardware_concurrency",
    "worker_client_hints",
    "network_route",
    "webrtc_probe",
    "webrtc_complete",
    "webrtc_stun_requests",
    "webrtc_candidate_summary",
]
PUBLIC_ALPHA_REQUIRED_KEYS = CRITICAL_KEYS + PUBLIC_ALPHA_STABLE_CONTEXT_KEYS
PRODUCTION_REQUIRED_KEYS = PUBLIC_ALPHA_REQUIRED_KEYS + PRODUCTION_EXTENDED_CONTEXT_KEYS
CURRENT_AUDIT_SCHEMA_VERSION = 5
CURRENT_IDENTITY_CATALOG_VERSION = 1
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
REPORT_KEYS = {
    "id",
    "createdAt",
    "managerVersion",
    "managerBuild",
    "auditSchemaVersion",
    "identityCatalogVersion",
    "executionMode",
    "runtimeName",
    "runtimeVersion",
    "runtimeFlavor",
    "runtimeCodeSignatureValid",
    "runtimeExecutableSHA256",
    "runtimeFrameworkSHA256",
    "webrtcDirectControl",
    "firstInitial",
    "second",
    "firstRepeat",
}
CAPTURE_KEYS = {
    "capturedAt",
    "profileID",
    "profileName",
    "identityCode",
    "values",
}
VALUE_KEYS = set(PRODUCTION_REQUIRED_KEYS)


@dataclass(frozen=True)
class AppleDeviceTuple:
    id: str
    gpu_model: str
    hardware_concurrency: int
    physical_memory_gb: int
    web_device_memory_gb: int
    screen: str
    device_scale_factor: int
    platform_version: str


APPLE_DEVICE_TUPLES = [
    AppleDeviceTuple("macbook-air-m1", "M1", 8, 8, 8, "1280x800x1280x775x24x2", 2, "15.5.0"),
    AppleDeviceTuple("macbook-pro-m1-pro", "M1 Pro", 10, 16, 8, "1512x982x1512x957x24x2", 2, "15.4.1"),
    AppleDeviceTuple("macbook-air-m2", "M2", 8, 8, 8, "1280x832x1280x807x24x2", 2, "15.4.0"),
    AppleDeviceTuple("macbook-pro-m2-max", "M2 Max", 12, 32, 8, "1728x1117x1728x1092x24x2", 2, "15.3.2"),
    AppleDeviceTuple("macbook-pro-m2-pro", "M2 Pro", 12, 16, 8, "1512x982x1512x957x24x2", 2, "15.3.1"),
    AppleDeviceTuple("macbook-air-m3", "M3", 8, 8, 8, "1280x832x1280x807x24x2", 2, "15.3.0"),
    AppleDeviceTuple("macbook-pro-m3-max", "M3 Max", 16, 36, 8, "1728x1117x1728x1092x24x2", 2, "15.2.0"),
    AppleDeviceTuple("macbook-pro-m3-pro", "M3 Pro", 12, 18, 8, "1512x982x1512x957x24x2", 2, "15.1.1"),
    AppleDeviceTuple("macbook-air-m4", "M4", 10, 16, 8, "1280x832x1280x807x24x2", 2, "15.1.0"),
    AppleDeviceTuple("macbook-pro-m4-max", "M4 Max", 16, 36, 8, "1728x1117x1728x1092x24x2", 2, "15.0.1"),
    AppleDeviceTuple("macbook-pro-m4-pro", "M4 Pro", 14, 24, 8, "1512x982x1512x957x24x2", 2, "15.5.0"),
]


class FingerprintReportError(ValueError):
    pass


def load_report(path: Path) -> dict[str, Any]:
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise FingerprintReportError(f"Cannot read fingerprint report: {error}") from error
    if not isinstance(report, dict):
        raise FingerprintReportError("Fingerprint report must be a JSON object")
    return report


def load_runtime_lock(path: Path) -> dict[str, Any]:
    try:
        lock = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise FingerprintReportError(f"Cannot read runtime lock: {error}") from error
    if not isinstance(lock, dict):
        raise FingerprintReportError("Runtime lock must be a JSON object")
    return lock


def expected_runtime_evidence(lock: dict[str, Any], *, lock_path: Path) -> dict[str, str]:
    try:
        runtime_version = str(lock["fingerprintChromium"]["chromiumVersion"])
        runtime_report = lock["verification"]["runtimeReport"]
    except KeyError as error:
        raise FingerprintReportError(f"Runtime lock is missing expected key: {error}") from error
    if not isinstance(runtime_report, str) or not runtime_report:
        raise FingerprintReportError("Runtime lock verification.runtimeReport must be a path")
    report_path = Path(runtime_report)
    if not report_path.is_absolute():
        report_path = lock_path.parent.parent / report_path
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise FingerprintReportError(f"Cannot read runtime verification report: {error}") from error
    if not isinstance(report, dict):
        raise FingerprintReportError("Runtime verification report must be a JSON object")
    try:
        executable_sha = str(report["executable"]["sha256"])
        framework_sha = str(report["framework"]["sha256"])
        report_version = str(report["chromiumVersion"])
        runtime_report_created_at = str(report["createdAt"])
    except KeyError as error:
        raise FingerprintReportError(f"Runtime verification report is missing expected key: {error}") from error
    for label, digest in {
        "runtime executable": executable_sha,
        "runtime framework": framework_sha,
    }.items():
        if not SHA256_RE.match(digest):
            raise FingerprintReportError(f"Runtime verification report has invalid {label} SHA-256")
    if report_version != runtime_version:
        raise FingerprintReportError(
            "Runtime lock chromiumVersion does not match runtime verification report"
        )
    return {
        "runtimeVersion": runtime_version,
        "runtimeExecutableSHA256": executable_sha,
        "runtimeFrameworkSHA256": framework_sha,
        "runtimeReport": str(report_path),
        "runtimeVerificationCreatedAt": runtime_report_created_at,
    }


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as file:
            for chunk in iter(lambda: file.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise FingerprintReportError(f"Cannot hash distributed runtime file: {error}") from error
    return digest.hexdigest()


def _distributed_path(runtime_app: Path, recorded_path: object, label: str) -> Path:
    if not isinstance(recorded_path, str) or "/Contents/" not in recorded_path:
        raise FingerprintReportError(
            f"Embedded runtime verification report has invalid {label} path"
        )
    relative = Path("Contents") / recorded_path.split("/Contents/", 1)[1]
    candidate = runtime_app / relative
    try:
        candidate.resolve().relative_to(runtime_app.resolve())
    except (OSError, ValueError) as error:
        raise FingerprintReportError(
            f"Embedded runtime verification report escapes the runtime bundle: {label}"
        ) from error
    if not candidate.is_file():
        raise FingerprintReportError(f"Distributed runtime {label} is missing: {candidate}")
    return candidate


def expected_runtime_evidence_from_app(integrated_app: Path) -> dict[str, str]:
    runtime_app = (
        integrated_app
        / "Contents"
        / "Resources"
        / "NeAntik Browser.app"
    )
    evidence_root = (
        integrated_app
        / "Contents"
        / "Resources"
        / "NeAntikRuntimeEvidence"
    )
    evidence_path = evidence_root / "runtime-verification.json"
    try:
        with (integrated_app / "Contents" / "Info.plist").open("rb") as file:
            manager_info = plistlib.load(file)
        with (runtime_app / "Contents" / "Info.plist").open("rb") as file:
            runtime_info = plistlib.load(file)
        evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    except (OSError, plistlib.InvalidFileException, json.JSONDecodeError) as error:
        raise FingerprintReportError(
            f"Cannot read distributed app/runtime evidence: {error}"
        ) from error
    if not isinstance(evidence, dict):
        raise FingerprintReportError(
            "Embedded runtime verification report must be a JSON object"
        )
    if evidence.get("schemaVersion") != 2:
        raise FingerprintReportError(
            "Embedded runtime verification report must use provenance schema 2"
        )
    provenance_files = {
        "sourceLockSHA256": evidence_root / "fingerprint-chromium.lock.json",
        "neantikPatchManifestSHA256": evidence_root / "neantik-patch-series.json",
        "appleDeviceTuplesManifestSHA256": evidence_root / "apple-device-tuples.json",
        "securityBaselineSHA256": evidence_root / "security-baseline.json",
    }
    for report_key, path in provenance_files.items():
        recorded = evidence.get(report_key)
        if not isinstance(recorded, str) or not SHA256_RE.fullmatch(recorded):
            raise FingerprintReportError(
                f"Embedded runtime verification report has invalid {report_key}"
            )
        if sha256_file(path) != recorded:
            raise FingerprintReportError(
                f"Embedded runtime provenance does not match {path.name}"
            )
    args_path = evidence_root / "args.gn"
    try:
        recorded_args_sha = str(evidence["buildArguments"]["sha256"])
        embedded_lock = load_runtime_lock(
            evidence_root / "fingerprint-chromium.lock.json"
        )
        lock_fingerprint_patch_sha = str(
            embedded_lock["fingerprintChromium"]["patchSeriesSHA256"]
        )
        lock_mac_patch_sha = str(
            embedded_lock["macPackaging"]["patchSeriesSHA256"]
        )
        lock_overlay_sha = str(
            embedded_lock["nevisionOverlay"]["scriptSHA256"]
        )
        lock_tuple_overlay_sha = str(
            embedded_lock["nevisionDeviceTuples"]["scriptSHA256"]
        )
    except (KeyError, TypeError) as error:
        raise FingerprintReportError(
            f"Embedded runtime provenance is missing expected key: {error}"
        ) from error
    immutable_provenance = {
        "buildArguments.sha256": (
            recorded_args_sha,
            sha256_file(args_path),
        ),
        "fingerprintChromiumPatchSeriesSHA256": (
            evidence.get("fingerprintChromiumPatchSeriesSHA256"),
            lock_fingerprint_patch_sha,
        ),
        "macPackagingPatchSeriesSHA256": (
            evidence.get("macPackagingPatchSeriesSHA256"),
            lock_mac_patch_sha,
        ),
        "nevisionOverlaySHA256": (
            evidence.get("nevisionOverlaySHA256"),
            lock_overlay_sha,
        ),
        "nevisionDeviceTupleOverlaySHA256": (
            evidence.get("nevisionDeviceTupleOverlaySHA256"),
            lock_tuple_overlay_sha,
        ),
    }
    for label, (recorded, expected) in immutable_provenance.items():
        if (
            not isinstance(recorded, str)
            or not SHA256_RE.fullmatch(recorded)
            or recorded != expected
        ):
            raise FingerprintReportError(
                f"Embedded runtime provenance mismatch: {label}"
            )
    try:
        executable = _distributed_path(
            runtime_app,
            evidence["executable"]["path"],
            "executable",
        )
        framework = _distributed_path(
            runtime_app,
            evidence["framework"]["path"],
            "framework",
        )
        created_at = str(evidence["createdAt"])
        recorded_version = str(evidence["chromiumVersion"])
        recorded_executable_sha = str(evidence["executable"]["sha256"])
        recorded_framework_sha = str(evidence["framework"]["sha256"])
    except (KeyError, TypeError) as error:
        raise FingerprintReportError(
            f"Embedded runtime verification report is missing expected key: {error}"
        ) from error
    runtime_version = str(runtime_info.get("CFBundleShortVersionString", ""))
    if not runtime_version or runtime_version != recorded_version:
        raise FingerprintReportError(
            "Distributed runtime version does not match its embedded verification report"
        )
    executable_sha = sha256_file(executable)
    framework_sha = sha256_file(framework)
    if executable_sha != recorded_executable_sha or framework_sha != recorded_framework_sha:
        raise FingerprintReportError(
            "Distributed runtime binaries do not match their embedded verification report"
        )
    return {
        "managerVersion": str(manager_info.get("CFBundleShortVersionString", "")),
        "managerBuild": str(manager_info.get("CFBundleVersion", "")),
        "runtimeVersion": runtime_version,
        "runtimeExecutableSHA256": executable_sha,
        "runtimeFrameworkSHA256": framework_sha,
        "runtimeReport": str(evidence_path),
        "runtimeVerificationCreatedAt": created_at,
    }


def runtime_lock_issues(report: dict[str, Any], expected: dict[str, str]) -> list[str]:
    issues: list[str] = []
    for report_key, expected_key, label in (
        ("managerVersion", "managerVersion", "manager version"),
        ("managerBuild", "managerBuild", "manager build"),
        ("runtimeVersion", "runtimeVersion", "runtime version"),
        ("runtimeExecutableSHA256", "runtimeExecutableSHA256", "runtime executable SHA-256"),
        ("runtimeFrameworkSHA256", "runtimeFrameworkSHA256", "runtime framework SHA-256"),
    ):
        if expected_key in expected and report.get(report_key) != expected[expected_key]:
            issues.append(f"The report {label} does not match the pinned runtime evidence.")
    return issues


def capture(report: dict[str, Any], key: str) -> dict[str, Any]:
    value = report.get(key)
    if not isinstance(value, dict):
        raise FingerprintReportError(f"Report is missing capture object: {key}")
    values = value.get("values")
    if not isinstance(values, dict) or not all(
        isinstance(k, str) and isinstance(v, str) for k, v in values.items()
    ):
        raise FingerprintReportError(f"Capture {key} must contain string values")
    return value


def values(capture_object: dict[str, Any]) -> dict[str, str]:
    return capture_object["values"]


def exact_schema_issues(report: dict[str, Any]) -> list[str]:
    issues: list[str] = []
    unknown_report_keys = sorted(set(report) - REPORT_KEYS)
    if unknown_report_keys:
        issues.append(
            "The report contains unsupported top-level fields: "
            + ", ".join(unknown_report_keys)
            + "."
        )

    for capture_key in (
        "webrtcDirectControl",
        "firstInitial",
        "second",
        "firstRepeat",
    ):
        capture_object = report.get(capture_key)
        if capture_object is None and capture_key == "webrtcDirectControl":
            continue
        if not isinstance(capture_object, dict):
            continue
        unknown_capture_keys = sorted(set(capture_object) - CAPTURE_KEYS)
        if unknown_capture_keys:
            issues.append(
                f"The {capture_key} capture contains unsupported fields: "
                + ", ".join(unknown_capture_keys)
                + "."
            )
        capture_values = capture_object.get("values")
        if not isinstance(capture_values, dict):
            continue
        unknown_value_keys = sorted(set(capture_values) - VALUE_KEYS)
        if unknown_value_keys:
            issues.append(
                f"The {capture_key} values contain unsupported fields: "
                + ", ".join(unknown_value_keys)
                + "."
            )
    return issues


def parse_iso8601(value: object, field: str) -> datetime:
    if not isinstance(value, str) or not value.strip():
        raise FingerprintReportError(f"{field} must be a non-empty ISO-8601 timestamp")
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as error:
        raise FingerprintReportError(f"{field} must be a valid ISO-8601 timestamp") from error
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def timestamp_issues(
    report: dict[str, Any],
    captures: list[tuple[str, dict[str, Any]]],
    *,
    expected_runtime: dict[str, str] | None,
) -> list[str]:
    issues: list[str] = []
    try:
        report_created_at = parse_iso8601(report.get("createdAt"), "createdAt")
    except FingerprintReportError as error:
        return [str(error)]

    capture_times: list[tuple[str, datetime]] = []
    for label, capture_object in captures:
        try:
            capture_times.append(
                (label, parse_iso8601(capture_object.get("capturedAt"), f"{label}.capturedAt"))
            )
        except FingerprintReportError as error:
            issues.append(str(error))
    if issues:
        return issues

    if any(capture_times[index][1] > capture_times[index + 1][1] for index in range(len(capture_times) - 1)):
        issues.append("Capture timestamps are not ordered as A → B → A.")
    if any(captured_at > report_created_at for _, captured_at in capture_times):
        issues.append("A capture timestamp is later than the report createdAt timestamp.")
    if expected_runtime is not None:
        try:
            runtime_created_at = parse_iso8601(
                expected_runtime.get("runtimeVerificationCreatedAt"),
                "runtimeVerificationCreatedAt",
            )
        except FingerprintReportError as error:
            issues.append(str(error))
        else:
            if report_created_at < runtime_created_at:
                issues.append(
                    "The report was created before the pinned runtime verification report."
                )
    return issues


def is_available(value: str | None) -> bool:
    return value is not None and value != "" and value != "unavailable"


def changed_keys(first: dict[str, str], second: dict[str, str]) -> list[str]:
    return sorted(key for key in set(first) | set(second) if first.get(key) != second.get(key))


def changed_critical_keys(
    first: dict[str, str],
    second: dict[str, str],
    repeat: dict[str, str],
) -> list[str]:
    return [
        key
        for key in CRITICAL_KEYS
        if is_available(first.get(key))
        and is_available(second.get(key))
        and is_available(repeat.get(key))
        and first.get(key) != second.get(key)
    ]


def unavailable_required_keys(
    first: dict[str, str],
    second: dict[str, str],
    repeat: dict[str, str],
    *,
    required_keys: list[str] = PRODUCTION_REQUIRED_KEYS,
) -> list[str]:
    return [
        key
        for key in required_keys
        if not is_available(first.get(key))
        or not is_available(second.get(key))
        or not is_available(repeat.get(key))
    ]


def unstable_required_keys(
    first: dict[str, str],
    repeat: dict[str, str],
    *,
    required_keys: list[str] = PRODUCTION_REQUIRED_KEYS,
) -> list[str]:
    return [key for key in required_keys if first.get(key) != repeat.get(key)]


def parsed_client_hints(value: str | None) -> dict[str, Any] | None:
    if not is_available(value):
        return None
    try:
        parsed = json.loads(value or "")
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def cross_realm_consistency_issues(
    label: str,
    capture_object: dict[str, Any],
) -> list[str]:
    v = values(capture_object)
    issues: list[str] = []

    for first, second in (
        ("audio", "audio_repeat"),
        ("canvas", "canvas_repeat"),
        ("canvas", "worker_canvas"),
        ("client_rects", "client_rects_repeat"),
        ("webgl_pixels", "webgl_pixels_repeat"),
        ("webgl_pixels", "worker_webgl_pixels"),
        ("webgl_vendor", "worker_webgl_vendor"),
        ("webgl_renderer", "worker_webgl_renderer"),
        ("webgl_extensions", "worker_webgl_extensions"),
        ("webgl_shader_precision", "worker_webgl_shader_precision"),
        ("user_agent", "worker_user_agent"),
        ("platform", "worker_platform"),
        ("languages", "worker_languages"),
        ("timezone", "worker_timezone"),
        ("intl_locale", "worker_intl_locale"),
        ("hardware_concurrency", "worker_hardware_concurrency"),
    ):
        if is_available(v.get(first)) and is_available(v.get(second)) and v.get(first) != v.get(second):
            issues.append(f"The {label} {first} value disagrees with {second}.")

    if (
        is_available(v.get("css_screen_match"))
        and v.get("css_screen_match") != "width:1|height:1|resolution:1"
    ):
        issues.append(f"The {label} CSS media queries disagree with the Screen API.")

    top_hints = parsed_client_hints(v.get("client_hints"))
    worker_hints = parsed_client_hints(v.get("worker_client_hints"))
    if top_hints is not None and worker_hints is not None:
        for key in (
            "architecture",
            "bitness",
            "mobile",
            "model",
            "platform",
            "platformVersion",
            "uaFullVersion",
            "wow64",
        ):
            if top_hints.get(key) != worker_hints.get(key):
                issues.append(
                    f"The {label} Client Hints {key} value disagrees between the page and worker."
                )
    return issues


def network_privacy_issues(
    label: str,
    capture_object: dict[str, Any],
) -> list[str]:
    v = values(capture_object)
    route = v.get("network_route")
    if route not in {"direct", "proxied"}:
        return [f"The {label} network route is invalid."]
    if v.get("webrtc_probe") != "loopback-stun-v1":
        return [f"The {label} WebRTC probe contract is invalid."]
    if v.get("webrtc_complete") != "true":
        return [f"The {label} WebRTC gathering did not complete."]
    request_text = v.get("webrtc_stun_requests")
    if (
        not isinstance(request_text, str)
        or not re.fullmatch(r"0|[1-9][0-9]{0,2}", request_text)
        or int(request_text) > 256
    ):
        return [f"The {label} STUN request count is invalid."]
    request_count = int(request_text)
    try:
        summary = json.loads(v.get("webrtc_candidate_summary", ""))
    except json.JSONDecodeError:
        summary = None
    expected_keys = {"total", "host", "srflx", "prflx", "relay", "unknown"}
    if not isinstance(summary, dict) or set(summary) != expected_keys:
        return [f"The {label} WebRTC candidate summary is invalid."]
    counts = [summary.get(key) for key in expected_keys]
    if (
        not all(isinstance(value, int) and not isinstance(value, bool) for value in counts)
        or any(value < 0 or value > 256 for value in counts)
        or summary["total"]
        != summary["host"]
        + summary["srflx"]
        + summary["prflx"]
        + summary["relay"]
        + summary["unknown"]
    ):
        return [f"The {label} WebRTC candidate summary is invalid."]
    issues: list[str] = []
    if summary["unknown"] > 0:
        issues.append(
            f"The {label} WebRTC candidate summary contains unknown candidate types."
        )
    if route == "direct" and request_count == 0:
        issues.append(
            f"The {label} direct route did not reach the loopback STUN control."
        )
    if route == "proxied" and request_count != 0:
        issues.append(
            f"The {label} proxied route sent a loopback STUN request."
        )
    if route == "proxied" and any(
        summary[key] > 0 for key in ("host", "srflx", "prflx")
    ):
        issues.append(
            f"The {label} proxied route exposed a direct WebRTC candidate."
        )
    return issues


def tuple_for_identity(identity_code: object) -> AppleDeviceTuple | None:
    if not isinstance(identity_code, str):
        return None
    if not re.match(r"^NA-[0-9A-Fa-f]{8}$", identity_code):
        return None
    seed = int(identity_code[3:], 16)
    return APPLE_DEVICE_TUPLES[seed % len(APPLE_DEVICE_TUPLES)]


def device_tuple_issues(
    label: str,
    capture_object: dict[str, Any],
    *,
    runtime_version: str,
) -> list[str]:
    tuple_ = tuple_for_identity(capture_object.get("identityCode"))
    if tuple_ is None:
        return [f"The {label} identity code cannot be mapped to the reviewed Apple device catalog."]
    v = values(capture_object)
    issues: list[str] = []

    expected_values = {
        "hardware_concurrency": str(tuple_.hardware_concurrency),
        "device_memory": str(tuple_.web_device_memory_gb),
        "screen": tuple_.screen,
        "platform": "MacIntel",
        "webgl_vendor": "Google Inc. (Apple)",
        "webgpu_policy": "disabled",
    }
    for key, expected in expected_values.items():
        if v.get(key) != expected:
            issues.append(f"The {label} {key} value does not match device tuple {tuple_.id}.")
    if f"Apple {tuple_.gpu_model}" not in v.get("webgl_renderer", ""):
        issues.append(f"The {label} WebGL renderer does not match device tuple {tuple_.id}.")

    try:
        hints = json.loads(v.get("client_hints", ""))
    except json.JSONDecodeError:
        hints = None
    if not isinstance(hints, dict):
        issues.append(f"The {label} Client Hints cannot be validated against device tuple {tuple_.id}.")
        return issues

    for key, expected in {
        "architecture": "arm",
        "bitness": "64",
        "platform": "macOS",
        "platformVersion": tuple_.platform_version,
        "uaFullVersion": runtime_version,
    }.items():
        if hints.get(key) != expected:
            issues.append(f"The {label} Client Hints {key} value does not match device tuple {tuple_.id}.")
    if f"Chrome/{runtime_version}" not in v.get("user_agent", ""):
        issues.append(f"The {label} User-Agent does not match the compiled runtime version.")
    return issues


def production_release_issues(
    report: dict[str, Any],
    *,
    expected_runtime: dict[str, str] | None = None,
) -> list[str]:
    issues = public_alpha_release_issues(
        report,
        expected_runtime=expected_runtime,
    )
    first_capture = capture(report, "firstInitial")
    second_capture = capture(report, "second")
    repeat_capture = capture(report, "firstRepeat")
    first = values(first_capture)
    second = values(second_capture)
    repeat = values(repeat_capture)

    if report.get("auditSchemaVersion", 1) != CURRENT_AUDIT_SCHEMA_VERSION:
        issues.append("The report does not use the current strict fingerprint audit schema.")
    if report.get("identityCatalogVersion") != CURRENT_IDENTITY_CATALOG_VERSION:
        issues.append("The report does not use the current immutable identity catalog.")

    try:
        direct_control = capture(report, "webrtcDirectControl")
    except FingerprintReportError:
        issues.append(
            "The report does not contain a WebRTC direct positive control."
        )
    else:
        issues.extend(
            network_privacy_issues(
                "WebRTC direct control",
                direct_control,
            )
        )

    unavailable = unavailable_required_keys(
        first,
        second,
        repeat,
        required_keys=PRODUCTION_EXTENDED_CONTEXT_KEYS,
    )
    if unavailable:
        issues.append("Required browser surfaces are unavailable: " + ", ".join(unavailable) + ".")
    unstable = unstable_required_keys(
        first,
        repeat,
        required_keys=PRODUCTION_EXTENDED_CONTEXT_KEYS,
    )
    if unstable:
        issues.append("Required browser surfaces are unstable: " + ", ".join(unstable) + ".")

    runtime_version = report.get("runtimeVersion")
    if isinstance(runtime_version, str) and runtime_version:
        issues.extend(
            device_tuple_issues(
                "profile A, first capture",
                first_capture,
                runtime_version=runtime_version,
            )
        )
        issues.extend(
            device_tuple_issues(
                "profile B",
                second_capture,
                runtime_version=runtime_version,
            )
        )
        issues.extend(
            device_tuple_issues(
                "profile A, repeat capture",
                repeat_capture,
                runtime_version=runtime_version,
            )
        )
    for label, capture_object in (
        ("profile A, first capture", first_capture),
        ("profile B", second_capture),
        ("profile A, repeat capture", repeat_capture),
    ):
        issues.extend(cross_realm_consistency_issues(label, capture_object))
        issues.extend(network_privacy_issues(label, capture_object))
    return issues


def public_alpha_release_issues(
    report: dict[str, Any],
    *,
    expected_runtime: dict[str, str] | None = None,
) -> list[str]:
    first_capture = capture(report, "firstInitial")
    second_capture = capture(report, "second")
    repeat_capture = capture(report, "firstRepeat")
    first = values(first_capture)
    second = values(second_capture)
    repeat = values(repeat_capture)

    issues = exact_schema_issues(report)
    issues.extend(
        timestamp_issues(
            report,
            [
                ("firstInitial", first_capture),
                ("second", second_capture),
                ("firstRepeat", repeat_capture),
            ],
            expected_runtime=expected_runtime,
        )
    )
    execution_mode = report.get("executionMode")
    if execution_mode != "browser":
        issues.append(
            "The report does not explicitly record browser mode."
            if execution_mode is None
            else "The report was captured in diagnostic mode."
        )
    if report.get("runtimeFlavor") != "fingerprintChromium":
        issues.append("The report does not identify a fingerprint-compatible runtime.")
    runtime_version = report.get("runtimeVersion")
    if not isinstance(runtime_version, str) or not runtime_version:
        issues.append("The report does not identify the runtime version.")
    if report.get("runtimeCodeSignatureValid") is not True:
        issues.append("The report does not prove a valid runtime code signature.")
    if not isinstance(report.get("runtimeExecutableSHA256"), str) or not SHA256_RE.match(
        report["runtimeExecutableSHA256"]
    ):
        issues.append("The report does not bind the runtime executable SHA-256.")
    if not isinstance(report.get("runtimeFrameworkSHA256"), str) or not SHA256_RE.match(
        report["runtimeFrameworkSHA256"]
    ):
        issues.append("The report does not bind the runtime framework SHA-256.")
    if expected_runtime is not None:
        issues.extend(runtime_lock_issues(report, expected_runtime))

    if first_capture.get("profileID") == second_capture.get("profileID") or first_capture.get(
        "profileID"
    ) != repeat_capture.get("profileID"):
        issues.append("The report does not contain a valid A → B → A profile sequence.")
    if first_capture.get("identityCode") == second_capture.get("identityCode") or first_capture.get(
        "identityCode"
    ) != repeat_capture.get("identityCode"):
        issues.append("The report does not contain distinct, stable profile identities.")
    for label, capture_object in (
        ("profile A, first capture", first_capture),
        ("profile B", second_capture),
        ("profile A, repeat capture", repeat_capture),
    ):
        if tuple_for_identity(capture_object.get("identityCode")) is None:
            issues.append(
                f"The {label} identity code is not a current NeAntik identity."
            )

    changed_critical = changed_critical_keys(first, second, repeat)
    unstable_critical = [key for key in CRITICAL_KEYS if first.get(key) != repeat.get(key)]
    if unstable_critical or len(changed_critical) < 2:
        issues.append("The critical-surface verdict is not verified.")

    unavailable = unavailable_required_keys(
        first,
        second,
        repeat,
        required_keys=PUBLIC_ALPHA_REQUIRED_KEYS,
    )
    if unavailable:
        issues.append("Required browser surfaces are unavailable: " + ", ".join(unavailable) + ".")
    unstable = unstable_required_keys(
        first,
        repeat,
        required_keys=PUBLIC_ALPHA_REQUIRED_KEYS,
    )
    if unstable:
        issues.append("Required browser surfaces are unstable: " + ", ".join(unstable) + ".")
    if "webgl_pixels" not in changed_critical:
        issues.append("WebGL pixels did not differ between profiles.")
    return issues


def verification_summary(
    report: dict[str, Any],
    *,
    expected_runtime: dict[str, str] | None = None,
) -> dict[str, Any]:
    first = values(capture(report, "firstInitial"))
    second = values(capture(report, "second"))
    repeat = values(capture(report, "firstRepeat"))
    issues = public_alpha_release_issues(report, expected_runtime=expected_runtime)
    production_issues = production_release_issues(
        report,
        expected_runtime=expected_runtime,
    )
    return {
        "qualified": not issues,
        "issues": issues,
        "productionQualified": not production_issues,
        "productionIssues": production_issues,
        "auditSchemaVersion": report.get("auditSchemaVersion", 1),
        "identityCatalogVersion": report.get("identityCatalogVersion"),
        "changedCriticalKeys": changed_critical_keys(first, second, repeat),
        "unstableRequiredKeys": unstable_required_keys(first, repeat),
        "changedKeys": changed_keys(first, second),
        "executionMode": report.get("executionMode"),
        "runtimeName": report.get("runtimeName"),
        "runtimeVersion": report.get("runtimeVersion"),
        "runtimeFlavor": report.get("runtimeFlavor"),
        "createdAt": report.get("createdAt"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify a NeAntik public-alpha GUI A -> B -> A fingerprint report.",
    )
    parser.add_argument("report", type=Path)
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print the machine-readable verification summary.",
    )
    parser.add_argument(
        "--runtime-lock",
        type=Path,
        help=(
            "Bind the GUI report to runtime/fingerprint-chromium.lock.json and "
            "its verification.runtimeReport binary hashes."
        ),
    )
    parser.add_argument(
        "--integrated-app",
        type=Path,
        help=(
            "Bind the GUI report to freshly hashed binaries and manager "
            "version/build inside the distributed NeAntik app."
        ),
    )
    args = parser.parse_args()
    try:
        if args.integrated_app:
            expected_runtime = expected_runtime_evidence_from_app(
                args.integrated_app
            )
        elif args.runtime_lock:
            expected_runtime = expected_runtime_evidence(
                load_runtime_lock(args.runtime_lock),
                lock_path=args.runtime_lock,
            )
        else:
            expected_runtime = None
        summary = verification_summary(load_report(args.report), expected_runtime=expected_runtime)
    except FingerprintReportError as error:
        raise SystemExit(str(error)) from error

    if args.json:
        print(json.dumps(summary, indent=2, ensure_ascii=False))
    elif summary["qualified"]:
        print("PASS: public-alpha GUI A -> B -> A fingerprint report is qualified.")
        if not summary["productionQualified"]:
            print("NOTE: strict coherent production hardening is still incomplete.")
            for issue in summary["productionIssues"]:
                print(f"- {issue}")
    else:
        print("FAIL: public-alpha GUI A -> B -> A fingerprint report is not qualified.")
        for issue in summary["issues"]:
            print(f"- {issue}")
    return 0 if summary["qualified"] else 1


if __name__ == "__main__":
    sys.exit(main())
