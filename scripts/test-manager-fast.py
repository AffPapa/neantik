#!/usr/bin/env python3
"""Cached local Swift tests. Does not package, sign, launch or publish an app."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from native_cache_lock import cache_lock, CacheBusy, supervise


def suites(root=ROOT):
    found = set()
    for path in (root / "Tests/NeAntikTests").rglob("*.swift"):
        found.update(re.findall(r"\b(?:struct|class|actor|enum)\s+([A-Za-z_][A-Za-z0-9_]*Tests)\b", path.read_text()))
    return sorted(found)


def selection(requested, catalog):
    if not requested or any(not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*Tests", x) or x not in catalog for x in requested):
        raise ValueError("Choose an existing suite from --list; regex/unknown suites are refused")
    # SwiftPM's filter accepts regular expressions in test-specifier format.
    # Use portable explicit boundaries, not Python-style \b/(?:...) tokens.
    return r"(^|[./])(" + "|".join(sorted(set(requested))) + r")([./]|$)"


def positive_result(text):
    matches = re.findall(r"Test run with ([1-9][0-9]*) tests? in ([1-9][0-9]*) suites? passed", text)
    if not matches:
        raise ValueError("No positive Swift Testing count; an empty selection is not PASS")
    # Swift Testing's summary includes disabled tests. Require an actual
    # passed operation as well, and expose skip lines without claiming they ran.
    passed = re.findall(r"^\s*✔ Test (?!run with ).+ passed(?: after |\.)", text, re.MULTILINE)
    skipped = re.findall(r"^\s*➜ Test .+ skipped(?:[:.]|$)", text, re.MULTILINE)
    if not passed:
        raise ValueError("No passed Swift Testing operation; skipped-only output is not PASS")
    return {"tests": int(matches[-1][0]), "suites": int(matches[-1][1]),
            "passedTestLogLines": len(passed), "skippedTestLogLines": len(skipped)}


def command(root, cache, pattern):
    args = ["swift", "test", "--build-system", "native", "--disable-sandbox",
            "--disable-dependency-cache", "--manifest-cache", "local", "--jobs", "2", "--no-parallel",
            "--scratch-path", str(cache / "swift"), "--cache-path", str(cache / "cache"),
            "--config-path", str(cache / "config"), "--security-path", str(cache / "security")]
    if pattern:
        args += ["--filter", pattern]
    return args


def input_digest(root):
    digest = hashlib.sha256()
    paths = [root / "Package.swift"]
    compiled = {".swift", ".c", ".h", ".cpp", ".m", ".mm", ".metal", ".S"}
    paths += sorted(p for p in (root / "Sources").rglob("*") if p.is_file() and p.suffix in compiled)
    paths += sorted(p for p in (root / "Tests").rglob("*") if p.is_file() and p.suffix in compiled)
    for path in paths:
        digest.update(str(path.relative_to(root)).encode()); digest.update(b"\0"); digest.update(path.read_bytes())
    return digest.hexdigest()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--suite", action="append", help="Exact suite; repeat to test several in one build")
    group.add_argument("--all", action="store_true", help="Full serial local regression; release gates remain separate")
    group.add_argument("--list", action="store_true")
    parser.add_argument("--plan", action="store_true", help="Show selection without running Swift or accessing Keychain")
    opts = parser.parse_args(argv)
    catalog = suites()
    if opts.list:
        print("\n".join(catalog)); return 0
    try:
        pattern = None if opts.all else selection(opts.suite, catalog)
    except ValueError as error:
        parser.error(str(error))
    cache = ROOT / ".build/neantik-local"
    args = command(ROOT, cache, pattern)
    if opts.plan:
        print(json.dumps({"mode": "full" if opts.all else "targeted", "suites": sorted(set(opts.suite or [])),
                          "jobs": 2, "parallel": False, "cache": "project-owned persistent", "release": False})); return 0
    cache.mkdir(parents=True, exist_ok=True)
    with cache_lock(cache) as cache_fd:
        env = os.environ.copy()
        # -B covers this interpreter, not Python children spawned by tests.
        # Keep generated executable caches out of the release source tree.
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["DEVELOPER_DIR"] = subprocess.check_output([str(ROOT / "scripts/resolve-compatible-developer-dir.sh")], cwd=ROOT, text=True).strip()
        if not env["DEVELOPER_DIR"]:
            raise ValueError("Empty toolchain resolver result")
        env["CLANG_MODULE_CACHE_PATH"] = str(cache / "clang-module-cache")
        env["SWIFTPM_MODULECACHE_OVERRIDE"] = env["CLANG_MODULE_CACHE_PATH"]
        reports = cache / "test-receipts"; reports.mkdir(mode=0o700, exist_ok=True)
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + str(os.getpid())
        log = reports / (stamp + ".log"); receipt = reports / (stamp + ".json")
        before = input_digest(ROOT); started = time.monotonic()
        with log.open("xb") as output:
            os.chmod(log, 0o600)
            exit_code = supervise(args, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT, pass_fds=(cache_fd,))
        record = {"schemaVersion": 1, "mode": "full" if opts.all else "targeted", "selectedSuites": sorted(set(opts.suite or [])),
                  "inputSHA256": before, "sourceUnchangedDuringRun": before == input_digest(ROOT),
                  "seconds": round(time.monotonic() - started, 3), "jobs": 2, "parallel": False,
                  "developerDir": env["DEVELOPER_DIR"],
                  "status": "fail", "log": str(log), "exitCode": exit_code, "releaseGate": False}
        if exit_code == 0 and record["sourceUnchangedDuringRun"]:
            try:
                record.update(positive_result(log.read_text(errors="replace")), status="pass")
            except ValueError:
                record["failure"] = "no positive test count"
        with receipt.open("x") as output:
            os.chmod(receipt, 0o600); json.dump(record, output, indent=2); output.write("\n")
        print(json.dumps({k: v for k, v in record.items() if k != "log"}))
        print("Receipt:", receipt)
        return 0 if record["status"] == "pass" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CacheBusy as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(75)
