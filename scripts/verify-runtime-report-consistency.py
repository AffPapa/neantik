#!/usr/bin/env python3
"""Compare immutable facts in packaged and freshly generated runtime reports."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


FIELDS = (
    "schemaVersion",
    "chromiumVersion",
    "architecture",
    "gpuMode",
    "sourceLockSHA256",
    "nevisionOverlaySHA256",
    "machoCount",
    "codeSignature",
    "codeSignatureKind",
    "fingerprintProtocolStrings",
    "executable.sha256",
    "framework.sha256",
    "buildArguments.sha256",
)


def fail(message: str) -> None:
    raise SystemExit(message)


def load(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"Cannot read runtime report {path}: {error}")
    if not isinstance(value, dict):
        fail(f"Runtime report {path} must contain a JSON object.")
    return value


def field(value: dict[str, Any], dotted: str) -> Any:
    current: Any = value
    for component in dotted.split("."):
        if not isinstance(current, dict) or component not in current:
            fail(f"Runtime report is missing immutable field {dotted}.")
        current = current[component]
    return current


def verify(packaged_path: Path, fresh_path: Path) -> None:
    packaged = load(packaged_path)
    fresh = load(fresh_path)
    mismatches = [
        dotted
        for dotted in FIELDS
        if field(packaged, dotted) != field(fresh, dotted)
    ]
    if mismatches:
        fail(
            "Packaged runtime verification report is stale or inconsistent: "
            + ", ".join(mismatches)
            + "."
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("packaged", type=Path)
    parser.add_argument("fresh", type=Path)
    args = parser.parse_args()
    verify(args.packaged, args.fresh)
    print("Packaged runtime verification report matches fresh evidence.")


if __name__ == "__main__":
    main()
