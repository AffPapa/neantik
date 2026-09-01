# Run log

## 2026-09-02 — competitive-intelligence baseline

- Reviewed 28 products using official documentation or official product pages.
- Produced a 100-candidate matrix. Public reviews were supplementary UX signals, not proof of technical effectiveness.
- Kept local/minimal product boundaries and explicitly rejected cloud, teams, profile transfer, remote runtimes, visual RPA, public remote API, marketplaces, proxy commerce, AI assistant and credential-vault expansion.

## 2026-09-02 — actual implementation reconciliation

- Replaced the original aspirational top-product selection with the 25 changes actually present in the local worktree.
- Added an internal evidence index that maps selected matrix IDs to source and focused tests/contracts.
- Selected UX work: note and bulk-proxy dirty guards, explicit editor heading, advanced summary, search help, responsive batch actions, unified note command, spoken shortcut labels, readiness recovery and temporary password reveal.
- Selected security work: fail-closed fingerprint-runtime signature state, removal of unsafe diagnostic launch arguments, bounded and race-resistant DevTools port reading, strict loopback WebSocket validation, sanitized curl environment, unique versioned runtime-framework binding, hardened release shell entrypoints and isolated Python runner requirements.
- Set all 25 selected rows to `implemented` while leaving focused gates, full gates, release and publication pending.
- No source file was edited by this documentation reconciliation step.

## Documentation validation

- Matrix rows: **100**, sequential from AD-001 through AD-100.
- Matrix `SELECT` rows: **25**.
- Selected rows: **25** unique IDs; every ID resolves to the matrix and every status is `implemented`.
- `state.json`: valid JSON with `candidate_count=100`, `selected_count=25` and `status=local_implementation_complete_pending_full_gates`.
- `state.json.implemented_items` exactly matches the ordered selected table.
- `git diff --check`: clean at validation time.

## Local execution evidence

- Focused Swift coverage: **145 tests / 11 suites passed** for the selected UX, runtime and release-security changes.
- Full Swift gate: **613 tests / 68 suites passed**.
- Full Python gate: **664 tests passed, 1 skipped**. A natural shard-closure failure for the two new suites was fixed before the green rerun.
- AffPapa helper gate: **43 tests passed**.
- ARM64 release build: passed.
- Source, privacy, public-tree, reachable-history secret scan, GitHub workflow pinning, source-budget and public-workflow-closure contracts: passed.
- Live manager and live fingerprint-browser integration: passed against the rebuilt local development application.
- Rendered minimum-size review: passed. The compact batch bar keeps selection and its action menu visible; the profile editor keeps the note, proxy controls, temporary password reveal, advanced summary and save controls readable without horizontal scrolling.
- `./scripts/neantik-affpapa-release doctor`: passed for local tools and current immutable public release `v0.3.23`.

## Remaining gates

- The Computer Use bridge enumerated the running development app but could not attach to its duplicated development bundle identifier; real pointer/keyboard review remains a best-effort retry and is not being misreported as passed.
- GitHub PR checks, exact merged-commit rerun, Developer ID signing, notarization, stapling, Gatekeeper, immutable release publication and post-publication redownload verification remain pending.
- Public `v0.3.23 (26)` remains unchanged until every release gate agrees.
