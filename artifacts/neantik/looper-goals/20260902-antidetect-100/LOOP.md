# Antidetect-100 implementation loop

## Current status

`local_implementation_complete_pending_full_gates`

The 25 selected source changes exist locally. This status deliberately does not assert that the complete repository, release, signing, notarization, Gatekeeper, GitHub or public-site workflow is complete.

## Objective

Keep the 28-product/100-candidate research trace while binding the selected set to the 25 UX, runtime and release hardening changes actually implemented in the current worktree.

## Selected slices

1. Draft-loss protection: AD-001 through AD-006.
2. Editor/search/responsive/accessibility clarity: AD-007 through AD-014.
3. Runtime, DevTools and child-process trust boundaries: AD-015 through AD-022.
4. Direct-release process isolation: AD-023 through AD-025.

## Full-gate loop

1. Confirm the exact source diff and ownership boundary.
2. Run focused Swift and Python tests named in `selected-25.md`.
3. Run all Swift shards and all Python/source/privacy/security contracts.
4. Run history secret scan and GitHub CodeQL/secret/dependency checks.
5. Run ARM64 Release build, runtime inspection and live manager/browser integration.
6. Render the affected states and inspect them visually.
7. On an unlocked macOS session, exercise note/proxy dirty guards, editor/search/batch layout, password reveal, shortcuts and readiness recovery by pointer and keyboard.
8. Only after an exact merged commit is green may the separate Direct release workflow start.

## Release ladder after full local gates

1. Checkout the exact merged commit, not a mutable branch.
2. Run `./scripts/neantik-affpapa-release doctor`.
3. Build one Developer ID candidate through `./Release-NeAntik.command`.
4. Require fresh A→B→A evidence, notarization, stapling, Gatekeeper, ZIP/DMG and SHA-256.
5. Publish immutable GitHub Release assets.
6. Update the public site only through the authorized publish workflow.
7. Redownload every artifact, compare hashes, recheck Gatekeeper, version, page and download links.

## Stop rules

- Stop on any source, privacy, secret, CodeQL, ARM64, runtime, signing, notarization, Gatekeeper, hash, version, site or download-link mismatch.
- Do not weaken a natural verifier to make a gate green.
- Do not call screenshot rendering a pointer/keyboard pass.
- Do not move the public version until immutable signed/notarized artifacts and post-publication verification agree.
- Cloud, teams, profile transfer, visual RPA, remote public API, marketplaces, proxy commerce, AI assistant and credential-vault scope remain excluded.

## Next resumable action

Run the focused tests for AD-001 through AD-025, record exact commands and results in `run-log.md`, then advance to the complete Swift/Python/source/security gate set. Until that happens, status remains `local_implementation_complete_pending_full_gates`.
