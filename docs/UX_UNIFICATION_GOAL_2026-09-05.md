# NeAntik: second usability unification goal

Baseline `f679ead`, 2026-09-05. Three independent read-only audits preceded
implementation. This cycle selects thirteen new changes, not a restatement of
the previous ten. Protected: production profiles/app, runtime, dependencies,
persisted schemas and public distribution. No claim of exhaustive security or
accessibility certification.

## Professional prompts

- UX engineer: reconcile list/settings/inspector labels, metrics and recovery
  behavior; every disabled action should have an understandable reason.
- Swift forms engineer: retain unfinished input and route validation to the
  actual offending field; never silently save a different proxy than intended.
- Navigation/layout engineer: keep bounded tokens and their controls reachable;
  reuse render-local computations without stale action-time decisions.
- Integrating QA/researcher: compare primary vendor documentation, challenge
  the diffs, run regression/build/live gates and document manual coverage limits.

## Research and product choices

Fresh primary-source checks: [Vision profile table](https://docs.browser.vision/profiles/overview),
[AdsPower list/search](https://help.adspower.com/docs/search),
[Octo tags](https://docs.octobrowser.net/en/profiles/tags/),
[GoLogin notes/tags](https://gologin.com/docs/browser-profiles/profile-management/notes-and-tags),
[Dolphin interface](https://docs.dolphin-anty.com/en/interface-dolphin-anty/application-interface-dolphin-anty),
[MoreLogin management](https://support.morelogin.com/en/articles/10137634-browser-management).

The documented patterns favor direct row actions, clear filtering, profile
organization and adjustable density. NeAntik already implements these concepts.
The useful next step is consistent behavior across existing surfaces, not copying
cloud/RPA/store sections or a full configurable table. These sources describe
vendor behavior, not independent usability scores or verified anonymity.

## Selected plan

| ID | Priority | Change | Acceptance |
| --- | --- | --- | --- |
| C01 | P1 | Block Save with unapplied proxy-import draft | Explain Apply/clear; retain input and focus import field |
| C02 | P1 | Retain overlong profile names | No silent truncation; validation and correction still work |
| C03 | P2 | Bulk import fallback names actual line number | No literal placeholder in recovery message |
| C04 | P1 | Bulk base-name failure has correction path | Open options/focus field; no misleading generated-name fallback |
| C05 | P1 | Folder + pinned/archive empty states describe combined scope | Offer scope recovery while retaining folder |
| C06 | P2 | Workspace search clear restores typing focus | Match settings search behavior |
| C07 | P2 | Shared actual/preview density metrics | Same padding/minimum height, unchanged persisted preference |
| C08 | P2 | List-view menu label describes density/filter/sort | Consistent visible label, help and accessibility |
| C09 | P2 | Inspector exposes existing disabled-launch reason | Reuse launchAction.help, no second policy |
| C10 | P2 | Settings empty search offers recovery and count | Explicit clear action, focus retained |
| C11 | P1 | Long accepted tags fit narrow editor | Remove control remains visible/reachable |
| C12 | P2 | Suggestion projection reused within render | Avoid repeated normalization/sorting; retain validation at action |
| C13 | P2 | Folder arrow movement snapshots row IDs once | Identical ordering/selection semantics |

No new P0 was established by these bounded audits. Remaining future work includes
stale sidebar-focus recovery, shortcut assignment/conflict UI, configurable columns,
metadata I/O redesign and safe saved views/templates. These are not counted as done.

## Gates

Targeted regressions, full Swift, Python, ARM64 release compilation, source/size
budgets, real selected UI paths in isolated Dev.app, responsive light/dark renders,
live manager/fingerprint smoke and final tree/reachable-history secret scans.
Three audit owners cross-review disjoint changes; root integrates and records
actual results. Public release remains a separate exact-commit Direct workflow.

## Delivery result

All thirteen selected changes C01–C13 implemented. Final shared verification:

| Gate | Evidence |
| --- | --- |
| Swift | 722 tests / 75 suites passed |
| Python | 676 tests, one skip; AffPapa tooling 43 tests passed |
| ARM64 | Native Release compilation passed |
| Live | Packaged browser launch/stop and fingerprint integration passed, 1 + 1 tests |
| Budgets | Source and installed Dev.app size passed without raising limits |
| Render | Responsive suite passed; 24-CJK-character tag in a 280pt editor inspected in both themes, remove button remains visible |
| Actual UI | Workspace clear restores focus; Settings empty-results clear restores catalog/focus; comfortable density preview inspected |
| Actual form | 121-character name retained with correct limit; unapplied import blocks Save even after choosing Direct; validation focuses retained SecureField without route mutation; explicit clear restores readiness |
| Data protection | Unsaved synthetic test draft discarded; four existing Dev profiles retained, production app/profiles/runtime untouched |

Cross-review found and corrected an intermediate suffix-feasibility regression:
a valid 4095-byte single grapheme may not fit the generated profile-number suffix.
The final base-name guard checks the generated name as well, with boundary tests.
Review also removed implicit `usesProxy` mutation during error navigation; only
an explicit recovery button enables proxy mode. Full tests ran again afterward.

Current-tree and reachable-history recognized-secret scans accompany the final
commit. They do not cover GitHub-only logs/unreachable refs or prove absence of
every possible secret. No public source upload, signed release, or site deployment
was performed. Source optimization removes duplicate work but carries no claimed
percentage speedup or download-size reduction.

Manual coverage is selected, not exhaustive: combined folder/scope permutations,
bulk base-name correction, forced text-selection failure and every launch-disabled
state are covered by model/source checks and review, not all manually reproduced.
Full keyboard rebinding, table customization and sidebar-focus recovery remain
in the explicitly deferred backlog. Execution logs are in ignored Goal artifacts.
