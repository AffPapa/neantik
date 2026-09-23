#!/usr/bin/env python3
"""Measure an exact local runtime in disposable headless profiles.

The producer emits only aggregate launch/idle metrics and runtime identity.
It never reads user profiles, Keychain, cookies, network addresses, or raw
browser output. Its result is deliberately ``partial``: release qualification
and source/runtime provenance are separate gates.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import selectors
import signal
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Iterable


DEFAULT_TIMEOUT_SECONDS = 30.0
DEFAULT_IDLE_WINDOW_SECONDS = 0.5
MAX_RUNS = 10
HTML_MARKER = b"</html>"


def percentile(values: list[float], percentile_value: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, math.ceil(percentile_value * len(ordered)))
    return round(ordered[rank - 1], 3)


def metric_pair(values: list[float]) -> dict[str, float | None]:
    return {
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
    }


def exact_executable(path: str) -> Path:
    candidate = Path(path)
    if not candidate.is_absolute():
        raise ValueError("runtime path must be absolute")
    metadata = os.lstat(candidate)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_uid not in {0, os.geteuid()}
        or not os.access(candidate, os.X_OK)
    ):
        raise ValueError("runtime must be an owned regular executable")
    return candidate


def runtime_identity(runtime: Path) -> tuple[str | None, str]:
    digest = hashlib.sha256()
    with runtime.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    completed = subprocess.run(
        [str(runtime), "--version"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=10,
        check=False,
    )
    version_text = completed.stdout.decode("utf-8", errors="replace").strip()
    version = None
    for token in version_text.split():
        parts = token.split(".")
        if len(parts) == 4 and all(part.isdigit() for part in parts):
            version = token
            break
    return version, digest.hexdigest()


def parse_cpu_time(value: str) -> float | None:
    """Parse macOS ps cumulative CPU time into seconds."""
    try:
        parts = value.split(":")
        if len(parts) == 2:
            minutes, seconds = parts
            return float(minutes) * 60 + float(seconds)
        if len(parts) == 3:
            hours, minutes, seconds = parts
            return float(hours) * 3600 + float(minutes) * 60 + float(seconds)
    except ValueError:
        pass
    return None


def process_group_sample(process_group_id: int) -> tuple[float, float] | None:
    """Return cumulative CPU seconds and RSS MiB for the process group."""
    try:
        completed = subprocess.run(
            ["ps", "-axo", "pid=,pgid=,time=,rss="],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=0.2,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    cpu_seconds = 0.0
    rss_kib = 0.0
    found = False
    for line in completed.stdout.splitlines():
        fields = line.split()
        if len(fields) != 4:
            continue
        try:
            if int(fields[1]) != process_group_id:
                continue
            process_cpu_seconds = parse_cpu_time(fields[2])
            if process_cpu_seconds is None:
                continue
            cpu_seconds += process_cpu_seconds
            rss_kib += float(fields[3])
            found = True
        except ValueError:
            continue
    if (
        not found
        or not math.isfinite(cpu_seconds)
        or not math.isfinite(rss_kib)
    ):
        return None
    return round(max(0.0, cpu_seconds), 3), round(
        max(0.0, rss_kib / 1024), 3
    )


def terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)


def run_probe(
    runtime: Path,
    profile_directory: Path,
    timeout_seconds: float,
    idle_window_seconds: float,
) -> tuple[float | None, float | None, float | None]:
    profile_directory.mkdir(exist_ok=True)
    command = [
        str(runtime),
        "--headless=new",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-background-networking",
        "--disable-component-update",
        "--disable-sync",
        "--disable-default-apps",
        f"--user-data-dir={profile_directory}",
        "--dump-dom",
        "data:text/html,neantik",
    ]
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        close_fds=True,
        start_new_session=True,
    )
    assert process.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    started = time.perf_counter_ns()
    dom_observed = False
    ready_duration_ms: float | None = None
    cpu_samples: list[float] = []
    memory_samples: list[float] = []
    try:
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            remaining = max(0.0, min(0.1, deadline - time.monotonic()))
            events = selector.select(remaining)
            if events:
                chunk = process.stdout.read1(64 * 1024)
                if HTML_MARKER in chunk:
                    dom_observed = True
                    ready_duration_ms = round(
                        (time.perf_counter_ns() - started) / 1_000_000,
                        3,
                    )
                    break
            if process.poll() is not None:
                break

        if dom_observed:
            # Startup CPU is intentionally excluded. The idle contract begins
            # only after the same DOM-ready marker used for launch timing.
            idle_deadline = time.monotonic() + idle_window_seconds
            previous_sample: tuple[float, float] | None = None
            while time.monotonic() < idle_deadline:
                sample = process_group_sample(process.pid)
                if sample is not None:
                    observed_at = time.monotonic()
                    if previous_sample is not None:
                        elapsed = observed_at - previous_sample[1]
                        cpu_delta = max(0.0, sample[0] - previous_sample[0])
                        if elapsed > 0:
                            cpu_samples.append(
                                round(cpu_delta / elapsed * 100, 3)
                            )
                    memory_samples.append(sample[1])
                    previous_sample = (sample[0], observed_at)
                time.sleep(0.05)
    finally:
        selector.close()
        terminate_process_group(process)
        process.stdout.close()

    if not dom_observed:
        return None, None, None
    return (
        ready_duration_ms,
        percentile(cpu_samples, 0.95),
        percentile(memory_samples, 0.95),
    )


def build_report(
    runtime_version: str | None,
    runtime_hash: str,
    cold: list[float],
    warm: list[float],
    cpu: list[float],
    memory: list[float],
    sample_count: int,
) -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "status": "partial",
        "runtimeVersion": runtime_version,
        "runtimeHash": runtime_hash,
        "generatedAt": dt.datetime.now(dt.timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z"),
        "sampleCount": sample_count,
        "coldStartMs": metric_pair(cold),
        "warmStartMs": metric_pair(warm),
        "idleCpuPercent": metric_pair(cpu),
        "idleMemoryMiB": metric_pair(memory),
    }


def run(
    runtime: Path,
    runs: int,
    timeout_seconds: float,
    idle_window_seconds: float,
) -> dict[str, object]:
    runtime_version, runtime_hash = runtime_identity(runtime)
    cold: list[float] = []
    warm: list[float] = []
    cpu: list[float] = []
    memory: list[float] = []
    completed_pairs = 0
    root_path = Path(tempfile.mkdtemp(prefix="neantik-runtime-performance-"))
    try:
        warm_profile = root_path / "warm-profile"
        # Prime the warm profile outside the measured sample set.
        run_probe(runtime, warm_profile, timeout_seconds, idle_window_seconds)
        for index in range(runs):
            cold_result = run_probe(
                runtime,
                root_path / f"cold-profile-{index:02d}",
                timeout_seconds,
                idle_window_seconds,
            )
            warm_result = run_probe(
                runtime,
                warm_profile,
                timeout_seconds,
                idle_window_seconds,
            )
            if cold_result[0] is not None:
                cold.append(cold_result[0])
            if warm_result[0] is not None:
                warm.append(warm_result[0])
            for result in (cold_result, warm_result):
                if result[1] is not None:
                    cpu.append(result[1])
                if result[2] is not None:
                    memory.append(result[2])
            if cold_result[0] is not None and warm_result[0] is not None:
                completed_pairs += 1
    finally:
        # This target is the exact directory created above. Chromium may
        # finish a late profile write just after its process group exits; a
        # cleanup race must not turn valid measurements into a failed report.
        shutil.rmtree(root_path, ignore_errors=True)
    return build_report(
        runtime_version,
        runtime_hash,
        cold,
        warm,
        cpu,
        memory,
        completed_pairs,
    )


def parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Measure an exact local runtime in disposable headless profiles; "
            "the result is always partial until separate release gates pass."
        )
    )
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS)
    parser.add_argument(
        "--idle-window",
        type=float,
        default=DEFAULT_IDLE_WINDOW_SECONDS,
    )
    args = parser.parse_args(argv)
    if args.runs < 1 or args.runs > MAX_RUNS:
        parser.error(f"--runs must be between 1 and {MAX_RUNS}")
    if args.timeout <= 0 or args.timeout > 60:
        parser.error("--timeout must be between 0 and 60 seconds")
    if args.idle_window <= 0 or args.idle_window > 10:
        parser.error("--idle-window must be between 0 and 10 seconds")
    return args


def main(argv: Iterable[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        runtime = exact_executable(args.runtime)
        result = run(runtime, args.runs, args.timeout, args.idle_window)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"runtime performance measurement failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
