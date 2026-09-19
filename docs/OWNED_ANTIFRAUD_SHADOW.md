# Own-origin shadow study: offline measurement

`scripts/owned_antifraud_metrics.py` summarizes aggregate results from a separately
run, authorized synthetic study. It makes no requests, collects no fingerprints,
changes no browser profiles and never enforces a decision. It is not an anti-fraud
detector and does not qualify the runtime or predict third-party detection.

```sh
python3 scripts/owned_antifraud_metrics.py /absolute/path/to/study.json \
  --acknowledge-owned-study
```

Required JSON fields:

- `schemaVersion`: 1; `mode`: `shadow`; `partition`: `evaluation`.
- `unit`: `independent-synthetic-profile`.
- `labelSource`: `independent-scenario-oracle` — never label fraud from a VPN,
  automation or fingerprint flag. Freeze evaluation separately from tuning.
- `rows`: aggregate cells, each with `cohort` (`baseline`, `privacy`, `vpn`,
  `accessibility`), `automation` (`manual`, `automated`), `truth` (`legitimate`,
  `abuse`), `decision` (`allow`, `challenge`, `block`), and integer `count`.
- `identity`: integer counts `falseMerge`, `distinctPairs`, `falseSplit`,
  `samePairs`, independently labelled by the synthetic scenario.

Unknown fields, duplicate cells/JSON keys, negative/boolean/excessive counts and
impossible identity rates are rejected. Do not include session IDs, cookies,
URLs, IPs, headers, credentials or raw telemetry. Input is at most 2 MB, regular
non-symlink file, with generic validation errors. Counts are bounded to 1M/cell.

Outputs separate false challenges and false blocks among legitimate profiles,
allowed abuse among abuse scenarios (missed intervention), and false merge/split
rates. Automation counts are descriptive, not fraud labels. Each rate includes
its numerator/denominator and a nominal 95% Wilson interval. Empty denominators
yield null, not zero. A challenge does not prove abuse detection.

The tool cannot verify that labels, independence or partition declarations are
true. Repeated reloads are not independent profiles. Distinct identity pairs may
also be dependent if they share subjects; arrange independent pairs or use an
appropriate clustered analysis instead of interpreting nominal intervals as
calibrated confidence. Do not pool overlapping cohorts into an overall rate.

Remaining integration: collect controlled own-origin observations, bind them to
the exact browser/collector versions, independently review scenario labels,
compare manual/driver runs and A→B→A controls, and review false-positive cohorts.
Synthetic calculator tests are not acceptance of that experiment or the release.
