#!/usr/bin/env python3
"""Benchmark synthetic NeAntik manager/profile projection workspaces.

This intentionally measures filesystem and JSON-manager work only. It never
opens a browser, reads a user profile, accesses Keychain, or removes files
outside TemporaryDirectory's context-managed synthetic workspace.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import tempfile
import time
from pathlib import Path
from typing import Iterable


SUPPORTED_COUNTS = (1, 50, 100)
DEFAULT_ITERATIONS = 3
MAX_ITERATIONS = 100


def percentile(values: list[float], percentile_value: float) -> float:
    """Return the nearest-rank percentile in milliseconds."""
    if not values:
        raise ValueError("at least one duration is required")
    ordered = sorted(values)
    rank = max(1, int((percentile_value * len(ordered)) + 0.999999))
    return round(ordered[rank - 1], 3)


def _metadata(profile_id: int) -> dict[str, object]:
    """Return deterministic, non-user synthetic manager metadata."""
    return {
        "id": f"synthetic-{profile_id:04d}",
        "name": f"Synthetic Profile {profile_id:04d}",
        "revision": 1,
        "tags": ["benchmark", "synthetic"],
        "proxy": {"state": "unconfigured"},
    }


def create_synthetic_workspace(root: Path, count: int) -> int:
    """Create *count* deterministic metadata files and return their byte size."""
    total_bytes = 0
    for profile_id in range(1, count + 1):
        profile_dir = root / f"profile-{profile_id:04d}"
        profile_dir.mkdir()
        payload = json.dumps(
            _metadata(profile_id),
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        metadata_path = profile_dir / "metadata.json"
        metadata_path.write_bytes(payload)
        total_bytes += len(payload)
    return total_bytes


def warm_projection(root: Path) -> list[dict[str, object]]:
    """Read and project synthetic metadata in stable directory order."""
    projection = []
    for profile_dir in sorted(root.iterdir(), key=lambda path: path.name):
        metadata_path = profile_dir / "metadata.json"
        with metadata_path.open("r", encoding="utf-8") as metadata_file:
            metadata = json.load(metadata_file)
        projection.append(
            {
                "id": metadata["id"],
                "name": metadata["name"],
                "revision": metadata["revision"],
            }
        )
    return projection


def _duration_ms(start_ns: int, end_ns: int) -> float:
    return (end_ns - start_ns) / 1_000_000


def benchmark_count(
    count: int, iterations: int
) -> tuple[dict[str, dict[str, float]], int]:
    """Benchmark one count inside a context-managed temporary workspace."""
    cold_durations: list[float] = []
    warm_durations: list[float] = []
    metadata_bytes = 0

    with tempfile.TemporaryDirectory(prefix="neantik-profile-benchmark-") as temporary:
        benchmark_root = Path(temporary)
        for iteration in range(iterations):
            workspace = benchmark_root / f"iteration-{iteration:03d}"
            workspace.mkdir()

            start_ns = time.perf_counter_ns()
            metadata_bytes = create_synthetic_workspace(workspace, count)
            cold_durations.append(_duration_ms(start_ns, time.perf_counter_ns()))

            start_ns = time.perf_counter_ns()
            projection = warm_projection(workspace)
            warm_durations.append(_duration_ms(start_ns, time.perf_counter_ns()))
            if len(projection) != count:
                raise RuntimeError("synthetic projection count mismatch")

    return (
        {
            "cold_setup": {
                "p50": percentile(cold_durations, 0.50),
                "p95": percentile(cold_durations, 0.95),
            },
            "warm_projection": {
                "p50": percentile(warm_durations, 0.50),
                "p95": percentile(warm_durations, 0.95),
            },
        },
        metadata_bytes,
    )


def parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Benchmark a synthetic NeAntik manager/profile workspace."
    )
    parser.add_argument(
        "--counts",
        nargs="+",
        type=int,
        choices=SUPPORTED_COUNTS,
        default=list(SUPPORTED_COUNTS),
        help="profile counts to measure (default: 1 50 100)",
    )
    parser.add_argument(
        "--iterations",
        type=int,
        default=DEFAULT_ITERATIONS,
        help=f"iterations per count, 1-{MAX_ITERATIONS} (default: {DEFAULT_ITERATIONS})",
    )
    args = parser.parse_args(argv)
    if args.iterations < 1 or args.iterations > MAX_ITERATIONS:
        parser.error(f"--iterations must be between 1 and {MAX_ITERATIONS}")
    args.counts = list(dict.fromkeys(args.counts))
    return args


def run(argv: Iterable[str] | None = None) -> dict[str, object]:
    args = parse_args(argv)
    durations: dict[str, dict[str, dict[str, float]]] = {}
    byte_sizes: dict[str, int] = {}
    for count in args.counts:
        measured, metadata_bytes = benchmark_count(count, args.iterations)
        for metric, values in measured.items():
            for percentile_name, value in values.items():
                durations.setdefault(metric, {}).setdefault(percentile_name, {})[
                    str(count)
                ] = value
        byte_sizes[str(count)] = metadata_bytes

    return {
        "counts": args.counts,
        "durations_ms": durations,
        "bytes": byte_sizes,
        "platform": platform.system(),
        "arch": platform.machine() or os.uname().machine,
        "status": "synthetic-manager-level",
    }


def main() -> None:
    print(json.dumps(run(), sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
