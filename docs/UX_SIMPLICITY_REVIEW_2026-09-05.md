# NeAntik: usability and simplicity follow-up

Date: 2026-09-05. Baseline: `8c6859e`. Scope: native manager, local source
and isolated Dev.app. Three independent read-only audits preceded edits.
No runtime, dependency, persisted-schema, production-profile or public-release
change. This is a targeted source/documentation review, not a claim to have
installed and tested every competitor or exhaustively certified NeAntik.

## Working prompts and acceptance

1. UX researcher: compare documented profile organization and common actions;
   prefer existing NeAntik concepts over adding whole competitor subsystems.
2. SwiftUI engineer: find wrong focus, lost drafts and unclear disabled controls;
   preserve data and make errors actionable. Add focused regressions.
3. Performance engineer: remove provably duplicated computation without changing
   action-time eligibility, matching rules or privacy boundaries.
4. Integrating QA: inspect the combined diff, run Swift/Python/ARM64 gates and
   test selected real UI paths. Distinguish automated coverage from manual checks.

## Current primary-source comparison

Vendor documentation describes intended behavior, not independently measured
speed, anonymity or user satisfaction. Conflicting competitor-vs-competitor
marketing claims were not used as evidence.

| Product and source | Relevant documented pattern | NeAntik decision |
| --- | --- | --- |
| [Vision](https://docs.browser.vision/profiles/overview) | Row-level start, profile metadata, contextual mass actions and column controls | Keep list-first actions; avoid adding a table designer in this slice |
| [Dolphin](https://docs.dolphin-anty.com/en/interface-dolphin-anty/application-interface-dolphin-anty) | Profiles, search/filter and configurable list columns | Improve existing search before adding navigation sections |
| [GoLogin](https://gologin.com/docs/browser-profiles/profile-management/notes-and-tags) | Direct notes, tags and status editing/filtering | Prioritize reliable note/tag drafts; do not copy cloud-sharing semantics |
| [Octo](https://docs.octobrowser.net/en/profiles/tags/) | Search/create tags, bulk tags and clearable tag filters | Consistent identity matching and explicit commits, already mostly present |
| [AdsPower](https://help.adspower.com/docs/search) | Search conditions, row spacing and window focus action | Existing density and structured search cover the core; make keyboard access reliable |
| [MoreLogin](https://support.morelogin.com/en/articles/10137634-browser-management) | Quick field edits, group/tag filters and filter reset | Fix validation navigation and folder discoverability; no marketplace or cloud phones |
| [Incogniton](https://incogniton.com/getting-started/) | Profile creation with name, optional group and tags | Keep the short default creation path; do not add mandatory onboarding |
| [Kameleo](https://kameleo.io/release-notes) | Profile ID visibility and full/partial ID search | NeAntik already supports ID search; no new parallel identifier tool |

## Ranked implementation plan

P0: no new critical failure established by these bounded audits. Do not infer
absence of vulnerabilities from this statement.

| ID | Priority | Selected change | Acceptance |
| --- | --- | --- | --- |
| U01 | P1 | Existing-tag selection preserves unfinished input | Success and rejected suggestion both retain draft |
| U02 | P1 | Proxy username errors identify/focus username, not host | Invalid login and invalid host have distinct targets |
| U03 | P1 | Invalid folder name has visible explanation | Empty/unsafe/oversize/duplicate cases are explainable |
| U04 | P1 | Folder search follows accent-insensitive identity | Café found by cafe; empty Return still does not commit |
| U05 | P1 | Settings Escape matches its own help | First clears, second releases focus |
| U06 | P2 | Settings Cmd+F focuses local shortcut search | Does not add a global binding or trigger workspace action |
| U07 | P2 | Plus-separated Return chords are searchable | Natural chord names work without changing actual bindings |
| U08 | P2 | Note placeholders remain legible in dark theme | Secondary semantic style, inspect light/dark renders |
| U09 | P2 | Reuse folded folder/route index values | Equivalent general/structured search; no credentials indexed |
| U10 | P2 | Reuse operational profile subset in header | No duplicate render filter, keep action-time checks |

Future, not selected: exact density-preview metrics; dedicated shortcut-reference
destination; editable shortcut assignment with conflict detection; user-defined
columns; asynchronous metadata I/O; saved views and safe metadata templates.
These need separate designs/tests and are not justified merely by competitor
feature counts. Runtime fingerprint sliders, RPA, credential exports and cloud
collaboration remain outside this minimal local-manager pass.

## Gates

Focused regression tests, full native Swift suite, Python contracts, ARM64
Release build, source budgets, isolated Dev.app, selected click/keyboard paths,
light/dark renders and live browser smoke. A local source commit is not a signed
Direct release. Final results and any limits will be appended after verification.

## Delivery

U01–U10 are implemented. Three cross-reviews found no blocking issue in the
combined changes. The entire deferred list remains deferred.

| Check | Result |
| --- | --- |
| Native tests | 714 tests / 75 suites passed, including new draft, username, folder, chord and index-equivalence regressions |
| Python contracts | 674 tests passed with 1 skip; AffPapa tooling 43 tests passed |
| ARM64 Release | Native release verification passed |
| Live smoke | Real packaged profile launch/stop and browser fingerprint integration passed (1 + 1 tests) |
| Secret scanners | Current source tree and locally reachable Git history passed recognized-secret scans; remote-only content is outside this check |
| Index budgets | Existing 10k-profile search, reusable-index and startup budgets passed; no before/after percentage speedup claimed |
| Source/size | Budgets passed without raised limits; installed Dev.app 442.1 MiB, runtime unchanged at 381.9 MiB |
| Visual | Dark new-profile note placeholder and Settings render inspected, plus light note editor; responsive render suite passed |
| Real Settings UI | Cmd+F focused shortcut search; Command+Return returned only its matching action; first Escape cleared input while retaining focus; second released focus without closing Settings |
| Real folder UI | 65-character draft retained with limit explanation; hidden-direction character explained; valid correction enabled Save; cancelled without creating a folder |
| Data boundaries | Four existing Dev profiles remained; production application, profiles, runtime and public release unchanged |

The first sandboxed Swift run failed only when a loopback STUN test was denied
its socket; the same full suite passed with appropriate local permission.
The old Python source contract asserted the former case-only API name; it now
asserts shared folder-identity folding, paired with behavioral Swift tests.
Neither failure was hidden by disabling a test or increasing a budget.

Live smoke and final source/history scan receipts are recorded in the ignored
`artifacts/neantik/looper-goals/20260905-ux-simplicity/` execution log.
The tag-suggestion and proxy-username paths were verified through model tests
and focus wiring review, not manually exercised against saved user profiles.
This is not comprehensive accessibility certification or a GitHub-wide security
audit. Direct publication still requires its separate exact-candidate gates.
