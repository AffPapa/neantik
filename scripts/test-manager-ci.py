#!/usr/bin/env python3
"""Clean CI shards: one cache per shard, separate serial suite processes."""
import argparse
import importlib.util
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("manager_fast", ROOT / "scripts/test-manager-fast.py")
fast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fast)


def catalog(root=ROOT):
    discovered = fast.suites(root)
    fixtures = json.loads((root / "scripts/swift-runtime-fixture-suites.json").read_text())
    if not isinstance(fixtures, dict) or not set(fixtures).issubset(discovered):
        raise ValueError("Fixture catalog does not match actual test suites")
    for path in (root / "Tests/NeAntikTests").rglob("*.swift"):
        text = path.read_text()
        if "@Test" in text and not re.search(r"\b(?:struct|class|actor|enum|extension)\s+[A-Za-z_][A-Za-z0-9_]*Tests\b", text):
            raise ValueError("Unsupported test declaration; review native discovery before changing CI coverage")
    return [suite for suite in discovered if not suite.startswith("Live") and suite not in fixtures]


def partition(suites, index, count):
    if type(index) is not int or type(count) is not int or not 1 <= count <= len(suites) or not 0 <= index < count:
        raise ValueError("Invalid or empty CI shard")
    return sorted(set(suites))[index::count]


def clean_environment(source):
    # Mixed suites have opt-ins and presence-based paths too. Ordinary CI must
    # not inherit a developer's runtime switches or QA data-root overrides.
    return {key: value for key, value in source.items() if not key.startswith("NEANTIK_")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shard", type=int, required=True)
    parser.add_argument("--shards", type=int, default=4)
    parser.add_argument("--plan", action="store_true")
    args = parser.parse_args()
    try:
        chosen = partition(catalog(), args.shard, args.shards)
    except ValueError as error:
        parser.error(str(error))
    if args.plan:
        print(json.dumps({"shard": args.shard, "shards": args.shards, "suites": chosen, "cleanPerCIJob": True,
                          "separateSuiteProcesses": True, "jobs": 2, "releaseGate": False}))
        return 0
    env = clean_environment(os.environ)
    env["DEVELOPER_DIR"] = subprocess.check_output([str(ROOT / "scripts/resolve-compatible-developer-dir.sh")], cwd=ROOT, text=True).strip()
    if not env["DEVELOPER_DIR"]:
        parser.error("Empty developer-dir resolver")
    cache = ROOT / ".build/neantik-ci" / str(args.shard)
    env["CLANG_MODULE_CACHE_PATH"] = str(cache / "clang-module-cache")
    env["SWIFTPM_MODULECACHE_OVERRIDE"] = env["CLANG_MODULE_CACHE_PATH"]
    before = fast.input_digest(ROOT)
    rows = []
    with fast.cache_lock(cache) as cache_fd:
        logs = cache / "receipts"
        logs.mkdir(mode=0o700, exist_ok=True)
        for suite in chosen:
            log = logs / (suite + ".log")
            started = time.monotonic()
            with log.open("wb") as output:
                os.chmod(log, 0o600)
                exit_code = fast.supervise(fast.command(ROOT, cache, fast.selection([suite], chosen)), cwd=ROOT,
                                           env=env, stdout=output, stderr=subprocess.STDOUT, pass_fds=(cache_fd,))
            row = {"suite": suite, "exitCode": exit_code, "seconds": round(time.monotonic() - started, 3), "status": "fail"}
            if exit_code == 0:
                try:
                    row.update(fast.positive_result(log.read_text(errors="replace")), status="pass")
                except ValueError:
                    row["failure"] = "no positive test count"
            rows.append(row)
            unchanged = before == fast.input_digest(ROOT)
            report = {"schemaVersion": 1, "shard": args.shard, "shards": args.shards, "inputSHA256": before,
                      "sourceUnchangedDuringRun": unchanged, "selectedSuites": chosen, "results": rows,
                      "jobs": 2, "separateSuiteProcesses": True, "releaseGate": False,
                      "status": "pass" if len(rows) == len(chosen) and unchanged and all(r["status"] == "pass" for r in rows) else "incomplete"}
            (logs / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps(row), flush=True)
            if row["status"] != "pass" or not unchanged:
                return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except fast.CacheBusy as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(75)
