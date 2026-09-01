#!/usr/bin/env python3
"""Fail closed when oversized NeAntik Swift owners grow past their budget."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

DEFAULT_MAX_LINES = 1500
DEFAULT_MAX_BYTES = 60_000
FILE_BUDGETS = {
    "ContentView.swift": (3800, 145_000),
    "BrowserProcessManager.swift": (2800, 110_000),
    "FingerprintAudit.swift": (2800, 110_000),
    "ProfileStore.swift": (1600, 62_000),
}


def inspect(source_root: Path) -> dict[str, object]:
    if not source_root.is_dir():
        raise ValueError("Swift source root is missing.")
    files = sorted(source_root.glob("*.swift"))
    if not files:
        raise ValueError("Swift source root contains no .swift files.")
    failures: list[str] = []
    measurements: dict[str, dict[str, int]] = {}
    for path in files:
        data = path.read_bytes()
        lines = len(data.splitlines())
        maximum_lines, maximum_bytes = FILE_BUDGETS.get(
            path.name,
            (DEFAULT_MAX_LINES, DEFAULT_MAX_BYTES),
        )
        measurements[path.name] = {
            "lines": lines,
            "bytes": len(data),
            "maximumLines": maximum_lines,
            "maximumBytes": maximum_bytes,
        }
        if lines > maximum_lines:
            failures.append(
                f"{path.name}: {lines} lines exceeds {maximum_lines}"
            )
        if len(data) > maximum_bytes:
            failures.append(
                f"{path.name}: {len(data)} bytes exceeds {maximum_bytes}"
            )
    return {
        "schemaVersion": 1,
        "files": measurements,
        "failures": failures,
        "verdict": "fail" if failures else "pass",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "source_root",
        nargs="?",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "Sources" / "NeAntik",
    )
    parser.add_argument("--json", action="store_true")
    arguments = parser.parse_args()
    try:
        report = inspect(arguments.source_root)
    except (OSError, ValueError) as error:
        print(f"Source budget audit failed: {error}", file=sys.stderr)
        return 1
    if arguments.json:
        print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    else:
        largest = sorted(
            report["files"].items(),
            key=lambda item: item[1]["bytes"],
            reverse=True,
        )[:5]
        print("Largest NeAntik Swift owners")
        for name, values in largest:
            print(f"  {name}: {values['lines']} lines, {values['bytes']} bytes")
        print(f"Verdict: {report['verdict'].upper()}")
        for failure in report["failures"]:
            print(f"  - {failure}")
    return 1 if report["verdict"] == "fail" else 0


if __name__ == "__main__":
    raise SystemExit(main())
