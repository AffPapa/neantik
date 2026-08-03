#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]


class DeviceTupleError(ValueError):
    pass


@dataclass(frozen=True)
class DeviceTuple:
    id: str
    gpuModel: str
    hardwareConcurrency: int
    physicalMemoryGB: int
    webDeviceMemoryGB: int
    screen: str
    deviceScaleFactor: int
    platformVersion: str


SWIFT_TUPLE_RE = re.compile(
    r"AppleDeviceTuple\(\s*"
    r'id:\s*"(?P<id>[^"]+)",\s*'
    r'gpuModel:\s*"(?P<gpuModel>[^"]+)",\s*'
    r"hardwareConcurrency:\s*(?P<hardwareConcurrency>\d+),\s*"
    r"physicalMemoryGB:\s*(?P<physicalMemoryGB>\d+),\s*"
    r"webDeviceMemoryGB:\s*(?P<webDeviceMemoryGB>\d+),\s*"
    r'screen:\s*"(?P<screen>[^"]+)",\s*'
    r"deviceScaleFactor:\s*(?P<deviceScaleFactor>\d+),\s*"
    r'platformVersion:\s*"(?P<platformVersion>[^"]+)"\s*'
    r"\)",
    re.MULTILINE,
)

PYTHON_TUPLE_RE = re.compile(
    r"AppleDeviceTuple\(\s*"
    r'"(?P<id>[^"]+)",\s*'
    r'"(?P<gpu_model>[^"]+)",\s*'
    r"(?P<hardwareConcurrency>\d+),\s*"
    r"(?P<physicalMemoryGB>\d+),\s*"
    r"(?P<webDeviceMemoryGB>\d+),\s*"
    r'"(?P<screen>[^"]+)",\s*'
    r"(?P<deviceScaleFactor>\d+),\s*"
    r'"(?P<platformVersion>[^"]+)"\s*'
    r"\)",
    re.MULTILINE,
)

IDENTITY_CATALOG_RE = re.compile(
    r"static let tupleIDs = \[(?P<body>.*?)\]",
    re.DOTALL,
)
SWIFT_STRING_RE = re.compile(r'"([^"]+)"')


def tuple_from_mapping(value: dict[str, Any], *, label: str) -> DeviceTuple:
    try:
        item = DeviceTuple(
            id=str(value["id"]),
            gpuModel=str(value["gpuModel"]),
            hardwareConcurrency=int(value["hardwareConcurrency"]),
            physicalMemoryGB=int(value["physicalMemoryGB"]),
            webDeviceMemoryGB=int(value["webDeviceMemoryGB"]),
            screen=str(value["screen"]),
            deviceScaleFactor=int(value["deviceScaleFactor"]),
            platformVersion=str(value["platformVersion"]),
        )
    except (KeyError, TypeError, ValueError) as error:
        raise DeviceTupleError(f"{label} contains an invalid tuple") from error
    validate_tuple(item, label=label)
    return item


def validate_tuple(item: DeviceTuple, *, label: str) -> None:
    if not re.fullmatch(r"[a-z0-9-]+", item.id):
        raise DeviceTupleError(f"{label} tuple id is invalid: {item.id}")
    if not item.gpuModel.startswith("M"):
        raise DeviceTupleError(f"{label} gpuModel must be Apple Silicon-like: {item.gpuModel}")
    if item.hardwareConcurrency < 4 or item.hardwareConcurrency > 32:
        raise DeviceTupleError(
            f"{label} hardwareConcurrency is outside the reviewed Mac range: {item.hardwareConcurrency}"
        )
    if item.physicalMemoryGB < item.webDeviceMemoryGB:
        raise DeviceTupleError(
            f"{label} physicalMemoryGB cannot be below webDeviceMemoryGB"
        )
    if item.webDeviceMemoryGB not in {4, 8}:
        raise DeviceTupleError(
            f"{label} webDeviceMemoryGB must use a reviewed browser cohort"
        )
    if not re.fullmatch(r"\d+x\d+x\d+x\d+x24x2", item.screen):
        raise DeviceTupleError(f"{label} screen tuple is invalid: {item.screen}")
    if item.deviceScaleFactor != 2:
        raise DeviceTupleError(
            f"{label} deviceScaleFactor must match the reviewed Retina cohort"
        )
    if not re.fullmatch(r"15\.\d+\.\d+", item.platformVersion):
        raise DeviceTupleError(
            f"{label} platformVersion must remain a reviewed macOS 15 Client Hint value: {item.platformVersion}"
        )


def load_manifest(path: Path) -> list[DeviceTuple]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise DeviceTupleError(f"cannot read Apple device tuple manifest: {path}") from error
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1:
        raise DeviceTupleError("Apple device tuple manifest schemaVersion must be 1")
    tuples = payload.get("tuples")
    if not isinstance(tuples, list) or not tuples:
        raise DeviceTupleError("Apple device tuple manifest must contain tuples")
    parsed = [
        tuple_from_mapping(value, label=f"manifest[{index}]")
        for index, value in enumerate(tuples)
        if isinstance(value, dict)
    ]
    if len(parsed) != len(tuples):
        raise DeviceTupleError("Apple device tuple manifest tuples must be objects")
    validate_collection(parsed, label="manifest")
    return parsed


def parse_swift_tuples(path: Path) -> list[DeviceTuple]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise DeviceTupleError(f"cannot read Swift fingerprint audit source: {path}") from error
    parsed = [
        DeviceTuple(
            id=match.group("id"),
            gpuModel=match.group("gpuModel"),
            hardwareConcurrency=int(match.group("hardwareConcurrency")),
            physicalMemoryGB=int(match.group("physicalMemoryGB")),
            webDeviceMemoryGB=int(match.group("webDeviceMemoryGB")),
            screen=match.group("screen"),
            deviceScaleFactor=int(match.group("deviceScaleFactor")),
            platformVersion=match.group("platformVersion"),
        )
        for match in SWIFT_TUPLE_RE.finditer(text)
    ]
    validate_collection(parsed, label="Swift")
    return parsed


def parse_python_tuples(path: Path) -> list[DeviceTuple]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise DeviceTupleError(f"cannot read Python GUI verifier source: {path}") from error
    parsed = [
        DeviceTuple(
            id=match.group("id"),
            gpuModel=match.group("gpu_model"),
            hardwareConcurrency=int(match.group("hardwareConcurrency")),
            physicalMemoryGB=int(match.group("physicalMemoryGB")),
            webDeviceMemoryGB=int(match.group("webDeviceMemoryGB")),
            screen=match.group("screen"),
            deviceScaleFactor=int(match.group("deviceScaleFactor")),
            platformVersion=match.group("platformVersion"),
        )
        for match in PYTHON_TUPLE_RE.finditer(text)
    ]
    validate_collection(parsed, label="Python")
    return parsed


def parse_identity_catalog_ids(path: Path) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise DeviceTupleError(
            f"cannot read Swift identity catalog source: {path}"
        ) from error
    match = IDENTITY_CATALOG_RE.search(text)
    if match is None:
        raise DeviceTupleError("Swift identity catalog tupleIDs are missing")
    ids = SWIFT_STRING_RE.findall(match.group("body"))
    if not ids:
        raise DeviceTupleError("Swift identity catalog tupleIDs are empty")
    if len(ids) != len(set(ids)):
        raise DeviceTupleError(
            "Swift identity catalog contains duplicate tuple ids"
        )
    return ids


def validate_collection(items: list[DeviceTuple], *, label: str) -> None:
    if len(items) < 8:
        raise DeviceTupleError(f"{label} must contain a reviewed Apple Silicon tuple catalog")
    seen: set[str] = set()
    for index, item in enumerate(items):
        validate_tuple(item, label=f"{label}[{index}]")
        if item.id in seen:
            raise DeviceTupleError(f"{label} contains duplicate tuple id: {item.id}")
        seen.add(item.id)


def compare(actual: list[DeviceTuple], expected: list[DeviceTuple], *, label: str) -> list[str]:
    issues: list[str] = []
    if len(actual) != len(expected):
        issues.append(f"{label} tuple count {len(actual)} does not match manifest count {len(expected)}")
    for index, (actual_item, expected_item) in enumerate(zip(actual, expected)):
        if actual_item != expected_item:
            issues.append(
                f"{label} tuple {index} drifted: "
                f"{asdict(actual_item)} != {asdict(expected_item)}"
            )
    return issues


def verify_consistency(
    *,
    manifest_path: Path,
    swift_path: Path,
    python_path: Path,
    models_path: Path = PROJECT_ROOT / "Sources" / "NeAntik" / "Models.swift",
) -> dict[str, Any]:
    manifest = load_manifest(manifest_path)
    swift = parse_swift_tuples(swift_path)
    python = parse_python_tuples(python_path)
    identity_ids = parse_identity_catalog_ids(models_path)
    manifest_ids = [item.id for item in manifest]
    issues = [
        *compare(swift, manifest, label="Swift"),
        *compare(python, manifest, label="Python"),
    ]
    if identity_ids != manifest_ids:
        issues.append(
            "Swift identity catalog tuple order does not match the immutable manifest"
        )
    return {
        "schemaVersion": 1,
        "tupleCount": len(manifest),
        "manifest": str(manifest_path),
        "swift": str(swift_path),
        "python": str(python_path),
        "models": str(models_path),
        "consistent": not issues,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify NeAntik Apple device tuple catalog consistency across Swift, Python, and manifest sources.",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=PROJECT_ROOT / "runtime" / "apple-device-tuples.json",
    )
    parser.add_argument(
        "--swift",
        type=Path,
        default=PROJECT_ROOT / "Sources" / "NeAntik" / "FingerprintAudit.swift",
    )
    parser.add_argument(
        "--python",
        type=Path,
        default=PROJECT_ROOT / "scripts" / "verify-gui-fingerprint-report.py",
    )
    parser.add_argument(
        "--models",
        type=Path,
        default=PROJECT_ROOT / "Sources" / "NeAntik" / "Models.swift",
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        report = verify_consistency(
            manifest_path=args.manifest,
            swift_path=args.swift,
            python_path=args.python,
            models_path=args.models,
        )
    except DeviceTupleError as error:
        print(f"Apple device tuple verification failed: {error}", file=sys.stderr)
        return 65
    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    elif report["consistent"]:
        print(f"Apple device tuple catalog verified: {report['tupleCount']} tuple(s).")
    else:
        print("Apple device tuple catalog drift detected.", file=sys.stderr)
        for issue in report["issues"]:
            print(f"- {issue}", file=sys.stderr)
    return 0 if report["consistent"] else 65


if __name__ == "__main__":
    sys.exit(main())
