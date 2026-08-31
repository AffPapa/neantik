#!/usr/bin/env python3
"""Sample CPU and resident memory for the manager PID only."""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import time


class ResourceMeasurementError(ValueError):
    pass


def parse_ps_sample(output: str) -> tuple[float, int]:
    fields = output.strip().split()
    if len(fields) != 2:
        raise ResourceMeasurementError("Unexpected ps output.")
    cpu = float(fields[0].replace(",", "."))
    rss_kib = int(fields[1])
    if cpu < 0 or rss_kib <= 0:
        raise ResourceMeasurementError("Invalid process resource values.")
    return cpu, rss_kib


def sample(pid: int) -> tuple[float, int]:
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "%cpu=", "-o", "rss="],
        check=False,
        capture_output=True,
        text=True,
        timeout=5,
    )
    if result.returncode != 0:
        raise ResourceMeasurementError("Manager PID is not available.")
    return parse_ps_sample(result.stdout)


def summarize(samples: list[tuple[float, int]]) -> dict[str, float | int]:
    if not samples:
        raise ResourceMeasurementError("At least one sample is required.")
    cpu = [value[0] for value in samples]
    rss_mib = [value[1] / 1024 for value in samples]
    return {
        "sampleCount": len(samples),
        "averageCPUPercent": round(statistics.fmean(cpu), 2),
        "maximumCPUPercent": round(max(cpu), 2),
        "averageRSSMiB": round(statistics.fmean(rss_mib), 2),
        "maximumRSSMiB": round(max(rss_mib), 2),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("pid", type=int)
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--interval", type=float, default=1)
    parser.add_argument("--cpu-max", type=float, default=5)
    parser.add_argument("--rss-max-mib", type=float, default=180)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--json", action="store_true")
    arguments = parser.parse_args()
    if arguments.pid <= 1 or not 1 <= arguments.samples <= 60:
        print("PID must be >1 and samples must be 1..60.", file=sys.stderr)
        return 64
    if not 0 <= arguments.interval <= 60:
        print("Interval must be 0..60 seconds.", file=sys.stderr)
        return 64
    try:
        values = []
        for index in range(arguments.samples):
            values.append(sample(arguments.pid))
            if index + 1 < arguments.samples:
                time.sleep(arguments.interval)
        report: dict[str, object] = {"schemaVersion": 1, **summarize(values)}
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Resource measurement failed: {error}", file=sys.stderr)
        return 1
    failures = []
    if report["averageCPUPercent"] > arguments.cpu_max:
        failures.append("average manager CPU exceeded budget")
    if report["maximumRSSMiB"] > arguments.rss_max_mib:
        failures.append("manager RSS exceeded budget")
    report["budgets"] = {
        "averageCPUPercent": arguments.cpu_max,
        "maximumRSSMiB": arguments.rss_max_mib,
    }
    report["verdict"] = "fail" if arguments.check and failures else "pass"
    report["failures"] = failures if arguments.check else []
    if arguments.json:
        print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    else:
        print(
            f"Manager idle: CPU avg {report['averageCPUPercent']}%, "
            f"RSS max {report['maximumRSSMiB']} MiB"
        )
        print(f"Verdict: {str(report['verdict']).upper()}")
    return 1 if report["verdict"] == "fail" else 0


if __name__ == "__main__":
    raise SystemExit(main())
