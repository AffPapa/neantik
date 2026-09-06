# Code and usability review — September 6, 2026

## Scope and result

Three independent architecture, performance and UX reviews selected bounded
changes without deleting features, tests, release gates or privacy policies.
The requested 30% reduction is **not achieved**: the confirmed duplication does
not justify removing about 11,377 lines of supported production behavior.

Baseline includes the five existing uncommitted UX corrections at the start
of this review. Counts include all own `Sources/**/*.swift`, not tests,
documentation, generated/vendor code or Chromium.

| Measure | Before | After |
| --- | ---: | ---: |
| Physical production lines | 37,924 | 37,858 |
| Nonblank production lines | 35,436 | 35,370 |
| Production bytes | 1,348,057 | 1,347,043 |

Net reduction: 66 lines (0.17%). Raw size is not a quality score. Shared helpers
remove duplication; explicit ordering equivalence and UX guards still need code.
No compression/minification or test deletion is counted as an improvement.

### Follow-up: Apple-style clarity and local cleanup

The subsequent settings-navigation fix and persistent labels bring the current
working tree to 37,889 physical / 35,397 nonblank production lines and 1,347,846
bytes. Against the same baseline this is 35 fewer physical lines (0.09%), not
30%. This follow-up prioritizes predictable navigation over a line-count target.
The shortcut-reference command now requests its actual search section, instead
of merely opening the settings window at the density control. A redundant
density reset button is removed; the two-option native picker remains. Startup
URL labeling stays visible after entry, and truncated note profile names have
full-name tooltips. No new persisted settings or dependencies were added.

Ten obsolete local app bundles were moved to Trash with recorded restore paths;
installed app, profile data, keys, active build and current rollback were retained.
This is recoverable cleanup, not an assertion that disk space was reclaimed.
Targeted preference tests: 5 passed; responsive source contracts: 28 passed.
Full rebuilt Swift suite: 730 tests in 76 suites passed. Isolated Dev build
passed; live clicks verified repeated shortcut help, search/Escape/Find,
startup URL label and note cancellation without changing profile data.
Long-name tooltip and the final Direct release still need verification.

## Implemented

1. Shared locale validation preserves strict persisted metadata and the proxy
   response's separate trimming/first-language behavior.
2. Shared Russian quantity formatting retains accusative forms and verb agreement.
3. One canonical tag comparator replaces two identical implementations.
4. Name-equivalence ranks avoid repeating localized comparisons in six sort orders.
5. Folder draft cancellation confirms loss; unchanged renames cannot submit.
6. Folder picker clear action retains focus and full-name hints.
7. Invalid notes do not suggest a disabled Save shortcut; editing clears stale errors.
8. Accessible profile counts are grammatically correct for all quantities.
9. Retry says “Повторить проверку”, not “Повторить ошибки”.
10. Creation and proxy-status hints avoid unnecessary Direct/context terminology.
11. Density reset retains its precise hint without duplicating the paragraph.
12. New count tests are registered in CI shards so they cannot silently be omitted.

## Performance evidence

Local 10,000-profile sorting microbenchmark: localized comparisons decreased
from 715,121 to 198,141 (72.3%). Three measured direct/ranked runs were
0.557/0.351, 0.452/0.332 and 0.461/0.316 seconds. This is not an app-wide speed
claim. Equivalence is checked independently in the regular test suite using
case, accents, NFC/NFD, Cyrillic, emoji, dates and shuffled input.

The complete existing 10k index benchmark measured 0.510 seconds to build the
index and 1.399 seconds for 150 reused queries on this machine.

## Usability research and decisions

[Apple performance guidance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)
supports measuring repeated update work instead of guessing from source size.
[Apple interface writing](https://developer.apple.com/la/videos/play/wwdc2022/10037/)
informed clearer action/status language.

[Vision proxy creation](https://docs.browser.vision/proxy/create),
[Dolphin workspace documentation](https://docs.dolphin-anty.com/en/interface-dolphin-anty/application-interface-dolphin-anty)
and [GoLogin profile settings](https://support.gologin.com/en/articles/14854406-profile-settings)
were compared with existing local workflows. Profile-level proxy actions,
filters and contextual bulk actions already exist; no extra dashboard is added.

The hypothesis of collapsing the new-profile note was rejected: this user
previously reported not finding notes during creation. The field stays visible.
No cloud accounts, RPA, dependencies or low-level fingerprint controls were added.

## Verification and limitations

- Full native Swift: 729 tests / 76 suites passed.
- Python after build-resumption fixes: 680 tests, one expected skip, no failures;
  AffPapa: 43 passed.
- Clean ARM64 manager release build passed; isolated Dev build passed.
- Current-tree and reachable-history recognized-secret scanners passed. This is
  bounded scanner coverage, not a guarantee against all possible vulnerabilities.
- Actual Dev clicks verified creation, cancel/retain folder draft, note opening,
  1001-character rejection, original-note reset and density switch/reset. The
  workspace and settings were visually inspected. No test draft was persisted.
- Fresh signed runtime, A-B-A, notarization, full installed-browser checks and
  publication remain pending. A manager build is not a completed binary release.

The old temporary runtime build was absent on reinspection. Its pinned source
pair and official Metal toolchain were restored. After diagnosing TypeScript
dependency contamination, the stopped runtime tree was moved outside the parent
workspace's `node_modules`; the exact failed target passed without modifying
Chromium. The build script now rejects contaminated ancestors before building.
Resuming also exposed a missing Dawn Go binary behind valid package metadata.
The official [CIPD integrity mode](https://chromium.googlesource.com/infra/luci/luci-go/+/main/cipd/client/cipd/ensure/doc.go)
checks installed files instead of trusting metadata alone.
The runtime lock is not relabelled until a real new binary passes its gates.
Public version remains 0.3.23 (26); no 0.3.24 binary was published by this review.
