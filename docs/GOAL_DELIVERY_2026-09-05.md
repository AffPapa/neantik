# Goal quality cycle: delivery and remaining scope

Date: 2026-09-05. Source baseline: `607c960`. Scope: local native manager.
This closes the first implementation slice, not the entire product backlog
or a public binary release. See [the 40-item plan](GOAL_IMPROVEMENT_PLAN_2026-09-05.md).

## Implemented

| Plan | Result | Evidence |
| --- | --- | --- |
| G-01 | Note edits compare the original note under the metadata lock; unrelated edits remain allowed | Two-store conflict, rename, missing-profile and normalization tests |
| G-02 | Folder dialog closes only on successful mutation; failures preserve choice | Throwing callback and commit-state regression test |
| G-03 | Retryable Undo failure retains its receipt; confirmed conflicts invalidate it | Injected persistence failure followed by successful retry |
| G-04–05 | Parent-owned tag draft survives collapsed settings and participates in Save, validation and discard confirmation | Draft parsing tests; Dev.app collapse/reopen and cancel checks |
| G-06 | Keyboard folder highlight scrolls into view without committing | Stable row IDs and ScrollViewReader wiring review; existing keyboard policy tests |
| G-07 | Empty suggestion search cannot commit the first tag | Whitespace/empty query tests |
| G-08 | Editing batch input/mode clears stale operation errors | Sheet state wiring review |
| G-09–10 | One batch preview and suggestion result per body evaluation | Final diff review; current preview recomputed at mutation time |
| G-11 | Batch suggestions use shared accent-insensitive matching with bounded results | Accent, scope and result-limit tests |
| G-12 | Route values are prepared once per profile indexing pass | Diff review and existing privacy/search regression suites |

## Verification

| Plan | Result |
| --- | --- |
| G-13 | Source-tree and reachable-history recognized-secret scanners passed for this cycle; scope is local checkout/reachable refs, not GitHub logs, inaccessible refs or proof of absence of every possible secret |
| G-14–17 | Full native suite: **708 tests, 75 suites passed**, including transaction, revision, Unicode and retry cases |
| G-18 | Python/source contracts: **674 tests, 1 skipped**, otherwise passed; AffPapa tooling: **43 tests passed** |
| G-19 | Native ARM64 Release script passed |
| G-20 | Latest isolated Dev.app built and opened; production application not replaced |
| G-21 | Responsive render suite passed; light/dark note forms and unavailable-folder render visually reviewed; minimum/wide layout cases passed automated render checks |
| G-22–23 | Live manager launch/stop and live browser fingerprint integration: **1 + 1 tests passed** |
| G-24 | Actual Dev.app pending tag survived collapse/reopen; Cancel prompted to discard. Only the new unsaved test draft was discarded; four existing Dev profiles remained. Large-folder scrolling and injected disk-error UI were not manually exercised; covered by code/model checks only |
| G-25 | Source budgets and installed Dev.app size audit passed without raising limits: **442.1 MiB total**, manager 20.0, runtime 381.9, compliance 38.3, other 1.9 MiB. This is installed size, not ZIP/DMG size or a measured speedup |
| G-26 | Three independent initial audits, owner-specific implementation, integrating-agent final diff review and full shared regression gates |
| G-27 | Plan, project map and changelog updated; delivery separates local work from publication |

Commands: `verify-native-swift-tests.sh`, Python unittest discovery,
`verify-native-swift-release.sh`, `Develop-NeAntik.command --no-open`,
`verify-native-swift-live.sh all`, `audit-source-budgets.py`,
`audit-app-size.py --check`, `verify-open-source-tree.py`,
`audit-git-history-secrets.py` and `git diff --check`.
Local execution receipts are kept in the ignored Goal artifact directory;
they are not bundled into the application.

## Remaining

G-28–38 remain a prioritized backlog: measured large-list/index optimization,
off-main-thread metadata design, focus restoration, folder counters, clickable
tags, read-only recovery, cleanup preview, saved views, safe templates and
presentation privacy. These need independent acceptance tests, not blanket
implementation for feature count. The dark-mode note placeholder also merits
a separate contrast review; no claim of exhaustive accessibility certification
is made here.

G-39–40 remain a separate source/public Direct release cycle. No GitHub upload,
website change, runtime replacement, signing-policy change or new dependency
was performed. Live integration is not a substitute for fresh release A→B→A,
notarization, stapling, Gatekeeper and re-downloaded artifact hashes.
