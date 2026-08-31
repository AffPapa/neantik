#!/usr/bin/env python3
"""Report bounded NeAntik app components without following bundle symlinks."""

from __future__ import annotations

import argparse
import json
import os
import stat
import sys
from pathlib import Path

MIB = 1024 * 1024
DEFAULT_LIMITS_MIB = {
    "total": 650,
    "manager": 32,
    "runtime": 580,
    "compliance": 64,
    "other": 32,
}


class SizeAuditError(ValueError):
    pass


def bounded_tree_size(root: Path) -> int:
    if not root.exists():
        return 0
    if root.is_symlink() or root.is_file():
        return root.lstat().st_size
    total = root.lstat().st_size
    for current, directories, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        kept_directories: list[str] = []
        for name in directories:
            candidate = current_path / name
            details = candidate.lstat()
            total += details.st_size
            if not stat.S_ISLNK(details.st_mode):
                kept_directories.append(name)
        directories[:] = kept_directories
        for name in files:
            total += (current_path / name).lstat().st_size
    return total


def inspect(app: Path) -> dict[str, int]:
    if not app.is_absolute() or app.suffix != ".app" or not app.is_dir():
        raise SizeAuditError("Expected one absolute .app bundle directory.")
    contents = app / "Contents"
    manager_directory = contents / "MacOS"
    runtime = contents / "Resources" / "NeAntik Browser.app"
    compliance = contents / "Resources" / "NeAntikRuntimeCompliance"
    if not manager_directory.is_dir():
        raise SizeAuditError("Manager executable directory is missing.")
    if not runtime.is_dir():
        raise SizeAuditError("Bundled NeAntik Browser.app is missing.")

    total = bounded_tree_size(app)
    manager = bounded_tree_size(manager_directory)
    runtime_size = bounded_tree_size(runtime)
    compliance_size = bounded_tree_size(compliance)
    other = total - manager - runtime_size - compliance_size
    if min(total, manager, runtime_size, compliance_size, other) < 0:
        raise SizeAuditError("Bundle component accounting is inconsistent.")
    return {
        "totalBytes": total,
        "managerBytes": manager,
        "runtimeBytes": runtime_size,
        "complianceBytes": compliance_size,
        "otherBytes": other,
    }


def check(report: dict[str, int], limits_mib: dict[str, int]) -> list[str]:
    failures: list[str] = []
    for component, field in [
        ("total", "totalBytes"),
        ("manager", "managerBytes"),
        ("runtime", "runtimeBytes"),
        ("compliance", "complianceBytes"),
        ("other", "otherBytes"),
    ]:
        limit = limits_mib[component] * MIB
        if report[field] > limit:
            failures.append(
                f"{component} is {report[field] / MIB:.1f} MiB; "
                f"budget is {limits_mib[component]} MiB"
            )
    return failures


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("app", type=Path)
    result.add_argument("--json", action="store_true")
    result.add_argument("--check", action="store_true")
    for name, default in DEFAULT_LIMITS_MIB.items():
        result.add_argument(
            f"--{name}-max-mib",
            type=int,
            default=default,
        )
    return result


def main() -> int:
    arguments = parser().parse_args()
    limits = {
        name: getattr(arguments, f"{name}_max_mib")
        for name in DEFAULT_LIMITS_MIB
    }
    if any(value < 0 for value in limits.values()):
        print("Size budgets must not be negative.", file=sys.stderr)
        return 64
    try:
        report = inspect(arguments.app)
    except (OSError, SizeAuditError) as error:
        print(f"App size audit failed: {error}", file=sys.stderr)
        return 1
    failures = check(report, limits) if arguments.check else []
    output = {
        "schemaVersion": 1,
        "components": report,
        "budgetsMiB": limits,
        "verdict": "fail" if failures else "pass",
        "failures": failures,
    }
    if arguments.json:
        print(json.dumps(output, sort_keys=True, separators=(",", ":")))
    else:
        print("NeAntik installed-size components")
        for label, field in [
            ("manager", "managerBytes"),
            ("runtime", "runtimeBytes"),
            ("compliance", "complianceBytes"),
            ("other", "otherBytes"),
            ("total", "totalBytes"),
        ]:
            print(f"  {label}: {report[field] / MIB:.1f} MiB")
        print(f"Verdict: {output['verdict'].upper()}")
        for failure in failures:
            print(f"  - {failure}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
