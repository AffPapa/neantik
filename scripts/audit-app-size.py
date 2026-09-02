#!/usr/bin/env python3
"""Report bounded NeAntik app components without following bundle symlinks."""

from __future__ import annotations

import argparse
import json
import os
import stat
import sys
from pathlib import Path
from typing import Optional

MIB = 1024 * 1024
DEFAULT_LIMITS_MIB = {
    "total": 650,
    "manager": 32,
    "runtime": 580,
    "compliance": 64,
    "other": 32,
}
COMPONENT_FIELDS = {
    "total": "totalBytes",
    "manager": "managerBytes",
    "runtime": "runtimeBytes",
    "compliance": "complianceBytes",
    "other": "otherBytes",
}
DEFAULT_TOP_PATHS = 20


class SizeAuditError(ValueError):
    pass


def require_real_directory(path: Path, message: str) -> None:
    try:
        details = path.lstat()
    except OSError as error:
        raise SizeAuditError(message) from error
    if not stat.S_ISDIR(details.st_mode):
        raise SizeAuditError(message)


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
    if not app.is_absolute() or app.suffix != ".app":
        raise SizeAuditError("Expected one absolute .app bundle directory.")
    contents = app / "Contents"
    resources = contents / "Resources"
    manager_directory = contents / "MacOS"
    runtime = resources / "NeAntik Browser.app"
    compliance = resources / "NeAntikRuntimeCompliance"
    require_real_directory(
        app, "Expected one absolute .app bundle directory."
    )
    require_real_directory(contents, "Bundle Contents directory is missing.")
    require_real_directory(resources, "Bundle Resources directory is missing.")
    require_real_directory(
        manager_directory, "Manager executable directory is missing."
    )
    require_real_directory(
        runtime,
        "Bundled NeAntik Browser.app must be a real embedded directory, not a symlink.",
    )

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


def largest_paths(app: Path, limit: int) -> list[dict[str, object]]:
    """Return deterministic, bundle-relative file/symlink evidence."""
    if limit == 0:
        return []
    entries: list[tuple[int, str]] = []
    for current, directories, files in os.walk(app, followlinks=False):
        current_path = Path(current)
        kept_directories: list[str] = []
        for name in directories:
            candidate = current_path / name
            details = candidate.lstat()
            if stat.S_ISLNK(details.st_mode):
                entries.append(
                    (details.st_size, candidate.relative_to(app).as_posix())
                )
            else:
                kept_directories.append(name)
        directories[:] = kept_directories
        for name in files:
            candidate = current_path / name
            entries.append(
                (
                    candidate.lstat().st_size,
                    candidate.relative_to(app).as_posix(),
                )
            )
    entries.sort(key=lambda item: (-item[0], item[1]))
    return [
        {"path": relative_path, "bytes": size}
        for size, relative_path in entries[:limit]
    ]


def load_previous_components(manifest: Path) -> dict[str, int]:
    if not manifest.is_absolute() or not manifest.is_file():
        raise SizeAuditError(
            "Previous manifest must be one absolute JSON file."
        )
    try:
        payload = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SizeAuditError(f"Previous manifest is not valid JSON: {error}")
    components = payload.get("components")
    if not isinstance(components, dict):
        raise SizeAuditError("Previous manifest components are missing.")
    result: dict[str, int] = {}
    for field in COMPONENT_FIELDS.values():
        value = components.get(field)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise SizeAuditError(
                f"Previous manifest field {field} is invalid."
            )
        result[field] = value
    return result


def component_deltas(
    current: dict[str, int], previous: dict[str, int]
) -> dict[str, int]:
    return {
        field: current[field] - previous[field]
        for field in COMPONENT_FIELDS.values()
    }


def check(report: dict[str, int], limits_mib: dict[str, int]) -> list[str]:
    failures: list[str] = []
    for component, field in COMPONENT_FIELDS.items():
        limit = limits_mib[component] * MIB
        if report[field] > limit:
            failures.append(
                f"{component} is {report[field] / MIB:.1f} MiB; "
                f"budget is {limits_mib[component]} MiB"
            )
    return failures


def check_deltas(
    deltas: dict[str, int], limits_mib: dict[str, Optional[int]]
) -> list[str]:
    failures: list[str] = []
    for component, field in COMPONENT_FIELDS.items():
        limit_mib = limits_mib[component]
        if limit_mib is None:
            continue
        limit = limit_mib * MIB
        if deltas[field] > limit:
            failures.append(
                f"{component} grew by {deltas[field] / MIB:.1f} MiB; "
                f"delta budget is {limit_mib} MiB"
            )
    return failures


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("app", type=Path)
    result.add_argument("--json", action="store_true")
    result.add_argument("--check", action="store_true")
    result.add_argument(
        "--top-paths",
        type=int,
        default=DEFAULT_TOP_PATHS,
        help="Number of largest bundle-relative file paths to report.",
    )
    result.add_argument("--previous-manifest", type=Path)
    for name, default in DEFAULT_LIMITS_MIB.items():
        result.add_argument(
            f"--{name}-max-mib",
            type=int,
            default=default,
        )
        result.add_argument(
            f"--{name}-delta-max-mib",
            type=int,
            default=None,
            help="Optional growth budget against --previous-manifest.",
        )
    return result


def main() -> int:
    arguments = parser().parse_args()
    limits = {
        name: getattr(arguments, f"{name}_max_mib")
        for name in DEFAULT_LIMITS_MIB
    }
    delta_limits = {
        name: getattr(arguments, f"{name}_delta_max_mib")
        for name in DEFAULT_LIMITS_MIB
    }
    if arguments.top_paths < 0:
        print("Top-path count must not be negative.", file=sys.stderr)
        return 64
    if any(value < 0 for value in limits.values()) or any(
        value is not None and value < 0 for value in delta_limits.values()
    ):
        print("Size budgets must not be negative.", file=sys.stderr)
        return 64
    if any(value is not None for value in delta_limits.values()) and (
        arguments.previous_manifest is None
    ):
        print(
            "Delta budgets require --previous-manifest.",
            file=sys.stderr,
        )
        return 64
    try:
        report = inspect(arguments.app)
        top_paths = largest_paths(arguments.app, arguments.top_paths)
        previous = (
            load_previous_components(arguments.previous_manifest)
            if arguments.previous_manifest is not None
            else None
        )
    except (OSError, SizeAuditError) as error:
        print(f"App size audit failed: {error}", file=sys.stderr)
        return 1
    failures = check(report, limits) if arguments.check else []
    deltas = component_deltas(report, previous) if previous else None
    if arguments.check and deltas is not None:
        failures.extend(check_deltas(deltas, delta_limits))
    output = {
        "schemaVersion": 2,
        "components": report,
        "budgetsMiB": limits,
        "topPaths": top_paths,
        "previousDeltasBytes": deltas,
        "deltaBudgetsMiB": delta_limits,
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
        if deltas is not None:
            print("Delta from previous manifest")
            for label, field in COMPONENT_FIELDS.items():
                print(f"  {label}: {deltas[field] / MIB:+.1f} MiB")
        print(f"Largest bundle paths (top {len(top_paths)})")
        for entry in top_paths:
            print(f"  {entry['bytes'] / MIB:.1f} MiB  {entry['path']}")
        print(f"Verdict: {output['verdict'].upper()}")
        for failure in failures:
            print(f"  - {failure}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
