# Profile performance harness

`scripts/benchmark-profile-workspace.py` is a safe, local, stdlib-only
benchmark for the NeAntik manager/profile projection layer. It creates a
deterministic synthetic workspace for 1, 50, and 100 profiles, then reports:

- cold setup: creation of synthetic profile directories and JSON metadata;
- warm projection: reading that metadata and building a small manager
  projection;
- approximate JSON metadata bytes written for each count.

Run it from this checkout:

```bash
python3 scripts/benchmark-profile-workspace.py --counts 1 50 100 --iterations 3
```

The command writes one JSON object to stdout with `counts`, `durations_ms`,
`bytes`, `platform`, `arch`, and `status`. Durations are milliseconds and use
nearest-rank p50/p95 values. The workspace is created below
`tempfile.TemporaryDirectory` and is cleaned up by its context manager.

This is a **synthetic manager-level signal**, not a production performance
claim. It does not launch Chromium, inspect user profiles, access Keychain,
measure real browser cold start, exercise crash/relaunch recovery, or perform
live CPU/RAM profiling. Its numbers must not be used as evidence for runtime
release readiness, browser startup latency, or hosted release quality.

The harness deliberately does not modify Swift or Chromium runtime code and
does not read or delete files outside its temporary synthetic workspace.
