# Exact-runtime performance evidence

`scripts/verify-runtime-performance-report.py` validates a minimized report
from an authorized local or self-hosted producer. It does not launch Chromium,
measure the machine, or upgrade a synthetic manager benchmark into runtime
evidence.

The report contains only:

- exact Chromium-style `runtimeVersion` and optional SHA-256 `runtimeHash`;
- UTC generation time and sample count;
- p50/p95 aggregates for cold start, warm start, idle CPU and idle memory.

It contains no paths, PIDs, command arguments, URLs, profile names, cookies,
credentials, IP addresses, headers or raw browser observations. Root keys are
allowlisted, duplicate JSON keys and non-standard JSON numbers are rejected.

## Verification semantics

`verified` is accepted only when the producer supplies at least three samples,
all four metrics, exact runtime identity and values within the development
budgets below:

| Metric | p50 | p95 |
| --- | ---: | ---: |
| cold start | 1500 ms | 3000 ms |
| warm start | 500 ms | 1000 ms |
| idle CPU | 5% | 15% |
| idle memory | 600 MiB | 1000 MiB |

These are NeAntik development ceilings, not a universal performance promise.
The verifier validates the producer's report; runtime provenance, exact
candidate binding, and the measurement environment remain separate gates.
Incomplete or unavailable measurements must remain `partial` or `unverified`.

Example verification command:

```bash
python3 scripts/verify-runtime-performance-report.py /path/to/report.json

# Only after exact source/runtime/release evidence gates are complete:
python3 scripts/verify-runtime-performance-report.py \
  --require-verified /path/to/report.json
```

The bounded local producer can be run only with an explicitly selected,
owner-readable executable. It creates disposable headless profiles, disables
background update/sync traffic, measures the DOM-ready launch interval and
aggregate process-group CPU/RSS, then terminates its own process group:

```bash
python3 scripts/measure-runtime-performance.py \
  --runtime "/absolute/path/to/NeAntik Browser" \
  --runs 3 \
  | python3 scripts/verify-runtime-performance-report.py -
```

The producer intentionally emits `partial`, never `verified`. A local
153.0.8010.52 ad-hoc candidate produced valid two-sample partial reports;
the short post-DOM window showed a CPU spike, while a three-second idle window
settled below the development CPU/RAM ceilings. These are candidate findings,
not release performance evidence, and must not be presented as such.

`--require-verified` is the fail-closed release mode. It rejects `partial`,
`unverified`, `blocked` and `failed` reports; it does not replace the existing
source, signing, notarization, Gatekeeper, GUI A → B → A or hosted-download
gates.

Until an authorized producer measures the exact packaged runtime, the
repository's runtime performance state remains `unverified`.
