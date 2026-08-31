#!/usr/bin/env python3
"""Measure first-window readiness for the isolated NeAntik Dev manager."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

DEV_BUNDLE_ID = "app.neantik.desktop.dev"
KEYCHAIN_SERVICE_PREFIX = "app.neantik.dev.startup."


class StartupMeasurementError(ValueError):
    pass


def validate_app(app: Path) -> Path:
    if not app.is_absolute() or app.suffix != ".app" or not app.is_dir():
        raise StartupMeasurementError("Expected one absolute Dev .app path.")
    info_path = app / "Contents" / "Info.plist"
    executable = app / "Contents" / "MacOS" / "NeAntik"
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise StartupMeasurementError("Dev app Info.plist is invalid.") from error
    if info.get("CFBundleIdentifier") != DEV_BUNDLE_ID:
        raise StartupMeasurementError(
            "Startup measurement is allowed only for NeAntik Dev.app."
        )
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise StartupMeasurementError("NeAntik Dev manager is not executable.")
    return executable


def measurement_service(temporary_name: str, index: int) -> str:
    safe_name = re.sub(r"[^A-Za-z0-9-]", "-", temporary_name)
    return f"{KEYCHAIN_SERVICE_PREFIX}{safe_name}.{index}"


def measure_once(
    executable: Path,
    ready_path: Path,
    data_root: Path,
    keychain_service: str,
    timeout: float,
) -> float:
    data_root.mkdir(mode=0o700)
    environment = os.environ.copy()
    environment["NEANTIK_STARTUP_READY_PATH"] = str(ready_path)
    environment["NEANTIK_STARTUP_DATA_ROOT"] = str(data_root)
    environment["NEANTIK_STARTUP_KEYCHAIN_SERVICE"] = keychain_service
    started = time.monotonic()
    process = subprocess.Popen(
        [str(executable)],
        env=environment,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        deadline = started + timeout
        while time.monotonic() < deadline:
            if ready_path.is_file():
                payload = json.loads(ready_path.read_text(encoding="utf-8"))
                if payload.get("state") != "ready":
                    raise StartupMeasurementError("Unexpected readiness payload.")
                return (time.monotonic() - started) * 1000
            exit_code = process.poll()
            if exit_code is not None:
                raise StartupMeasurementError(
                    f"Manager exited before readiness with code {exit_code}."
                )
            time.sleep(0.02)
        raise StartupMeasurementError("Manager readiness probe timed out.")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)


def summarize(samples: list[float]) -> dict[str, object]:
    if not samples:
        raise StartupMeasurementError("At least one startup sample is required.")
    warm = samples[1:]
    return {
        "schemaVersion": 1,
        "coldMilliseconds": round(samples[0], 1),
        "warmMilliseconds": [round(value, 1) for value in warm],
        "warmMedianMilliseconds": (
            round(statistics.median(warm), 1) if warm else None
        ),
        "sampleCount": len(samples),
    }


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("app", type=Path)
    result.add_argument("--runs", type=int, default=3)
    result.add_argument("--timeout", type=float, default=10)
    result.add_argument("--cold-max-ms", type=float, default=5000)
    result.add_argument("--warm-max-ms", type=float, default=3000)
    result.add_argument("--check", action="store_true")
    result.add_argument("--json", action="store_true")
    return result


def main() -> int:
    arguments = parser().parse_args()
    if not 1 <= arguments.runs <= 10 or arguments.timeout <= 0:
        print("Runs must be 1..10 and timeout must be positive.", file=sys.stderr)
        return 64
    try:
        executable = validate_app(arguments.app)
        with tempfile.TemporaryDirectory(
            prefix="neantik-startup-", dir="/private/tmp"
        ) as temporary:
            root = Path(temporary)
            samples = []
            for index in range(arguments.runs):
                samples.append(
                    measure_once(
                        executable,
                        root / f"ready-{index}.json",
                        root / f"data-{index}",
                        measurement_service(root.name, index),
                        arguments.timeout,
                    )
                )
        report = summarize(samples)
    except (OSError, json.JSONDecodeError, StartupMeasurementError) as error:
        print(f"Startup measurement failed: {error}", file=sys.stderr)
        return 1

    failures: list[str] = []
    if report["coldMilliseconds"] > arguments.cold_max_ms:
        failures.append("cold startup exceeded budget")
    warm_median = report["warmMedianMilliseconds"]
    if warm_median is not None and warm_median > arguments.warm_max_ms:
        failures.append("warm startup exceeded budget")
    report["budgetsMilliseconds"] = {
        "cold": arguments.cold_max_ms,
        "warmMedian": arguments.warm_max_ms,
    }
    report["verdict"] = "fail" if arguments.check and failures else "pass"
    report["failures"] = failures if arguments.check else []
    if arguments.json:
        print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    else:
        print(f"Cold manager ready: {report['coldMilliseconds']:.1f} ms")
        if warm_median is not None:
            print(f"Warm median: {warm_median:.1f} ms")
        print(f"Verdict: {str(report['verdict']).upper()}")
    return 1 if report["verdict"] == "fail" else 0


if __name__ == "__main__":
    raise SystemExit(main())
