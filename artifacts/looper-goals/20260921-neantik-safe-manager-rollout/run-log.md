# Run log

## 2026-09-21

- Goal resumed by the user after the previous blocked audit; a fresh blocked
  audit starts while the Chromium rebuild remains excluded.
- Goal system resumed under the existing active NeAntik goal.
- Plan gate created for stages 1–10.
- Stage 1 started: wire existing metadata-only transfer codec to macOS UI.
- Chromium rebuild remains excluded.
- Stage 1 delivered: connected Save/Open panels, bounded JSON size, explicit
  metadata-only copy, menu commands, and empty/shared-folder validation.
- Stage 1 delivery evidence: `./scripts/verify-native-swift-tests.sh` passed
  552 tests in 56 suites; `git diff --check`, open-source tree, runtime
  notices, and public workflow reference checks passed.
- Stage 2 started: replace unfiled import with one atomic profile-plus-folder
  transaction; shared folder names must map to one folder.
- Stage 2 delivered: imported profiles now use one recoverable ProfileStore
  transaction, reuse folders by normalized comparison key, and keep unfiled
  entries unassigned.
- Stage 2 failure evidence: folder-persistence injection and reload tests prove
  no partial profile metadata, folder assignment, or profile directory remains;
  full Swift gate passed 554 tests in 56 suites.
- Stage 3 started: add an aggregate lifecycle health center for locks,
  BrowserData size, recovery state, and last launch without exposing raw paths,
  PIDs, arguments, or secrets.
- Stage 3 delivered: added lock, BrowserData size/count, recovery, and last
  launch snapshot plus a profile detail health card. Raw paths, PIDs, and
  process arguments are intentionally absent from the card.
- Stage 3 evidence: full Swift gate passed 557 tests in 57 suites, including
  missing-data, active-lock, recovery-marker, and aggregate-presentation tests.
- Stage 4 started: expose only bounded media/permission status and never device
  IDs, raw media labels, or unredacted browser diagnostics.
- Stage 4 delivered: local audit results now feed a session-only privacy panel
  with availability, a count capped at 256, and camera/microphone permission
  states. The panel deliberately discards labels, IDs, identity codes, and raw
  surface values.
- Stage 4 evidence: full Swift gate passed 559 tests in 58 suites, including
  malformed/unbounded privacy input tests and UI render compatibility.
- Stage 5 started: replace any user-facing detected-IP success text with the
  bounded route-confirmed wording while retaining only coarse context.
- Stage 5 delivered: proxy editor success presentation now uses only
  «Маршрут подтверждён» plus optional coarse location; raw IP remains outside
  user-facing text. Presentation tests cover the redaction boundary.
- Stage 5 evidence: full Swift gate passed 560 tests in 58 suites.
- Stage 6 started: inventory the existing Chromium download/extension surface
  before adding provenance and quarantine without weakening Safe Browsing.
- Stage 6 delivered: added bounded Downloads/Extensions/Quarantine inventory,
  explicit-only quarantine policy, provenance metadata, source-root checks,
  symlink-tree rejection, and a user-facing aggregate card without raw IDs or
  paths.
- Stage 6 evidence: full Swift gate passed 563 tests in 59 suites, including
  outside-root, opaque-destination, and quarantine metadata rollback tests.
- Stage 7 started: measure and enforce manager-only performance budgets without
  changing Chromium runtime behavior.
- Stage 7 delivered: added explicit profile-list, lifecycle-scan, artifact-scan,
  and synchronous-byte budgets; both filesystem inspectors fail closed to an
  unavailable status when limits are exceeded.
- Stage 7 evidence: full Swift gate passed 565 tests in 60 suites, including
  direct budget boundary tests and existing 10k manager benchmarks.
- Stage 8 started: add a read-only runtime provenance card bound to current
  runtime inspection and evidence freshness; no runtime mutation is in scope.
- Stage 8 delivered: added a bounded runtime provenance card for name, version,
  source, flavor, architecture, signature state, digest presence, and preflight
  state. Full hashes, paths, and raw runtime arguments remain outside the UI.
- Stage 8 evidence: full Swift gate passed 567 tests in 61 suites; open-source
  tree, runtime notices, public workflow references, and diff checks passed.
- Stage 9 opened but remains blocked: the pinned Chromium runtime is below the
  current security baseline and the rebuild has not been explicitly allowed;
  the Direct deploy key is also unavailable, so no release work is claimed.
- Stage 9 gate evidence: `verify-runtime-security-baseline.py --today
  2026-09-21` reports pinned `152.0.7977.64` below required
  `153.0.8010.52`; `neantik-affpapa-release doctor` reports that the
  configured Direct deploy key is unavailable. The private key location is
  intentionally omitted from the public Goal log.
- Audit hygiene evidence: the public-tree verifier, dist-clean verifier,
  generated runtime notices check, and public workflow closure all pass after
  removing only Finder `.DS_Store` metadata from ignored `dist/` artifacts.
- Follow-up code audit: no user-facing SwiftUI view prints the proxy IP,
  device IDs, raw media values, or diagnostic JSON. The local BrowserData path
  remains available only inside the explicitly expandable technical-details
  block; lifecycle, privacy, artifact, and runtime-provenance cards stay
  aggregate-only. The 42 AffPapa release tests pass.
- Runtime documentation hygiene: corrected `runtime/README.md` so the
  source-qualified Chromium 152 lock is not described as an already-verified
  Chromium 151 binary. Historical AffPapa fallback content was not replaced
  with the public `0.7.3` snapshot because this checkout is a separate
  `0.3.20` candidate and is not that release source commit.
- Fresh gate recheck at `2026-09-21T13:09:22Z`: the runtime security baseline,
  Direct doctor, and local aggregate audit reproduce the same external
  blockers. Manager-only work is complete through stage 8; stage 9/10 cannot
  proceed without an explicitly permitted Chromium rebuild and the configured
  Direct deploy credential.
- Fresh official version check: Chrome Stable for macOS is `153.0.8010.52/.53`
  with 16 security fixes; NeAntik public `v0.7.3` is `153.0.8010.36`. Added
  `docs/RUNTIME_SECURITY_REBASE_153.md` as a source-only preparation boundary;
  no runtime lock or Chromium source was changed.
- Source-only prebuild checks: the NeAntik patchset manifest verifies all 11
  release-required groups as ported, and the official baseline reference
  verifier confirms `153.0.8010.52` / `.53` with 16 fixes. No binary or source
  checkout claim is made from these checks.
- Upstream availability check: ungoogled common publishes
  `153.0.8010.52-1`, while public ungoogled macOS packaging releases still
  stop at `152.0.7977.82-1.1`; the macOS 153 update remains an upstream work
  item. The NeAntik 153 source contract therefore remains uncreated until an
  exact macOS packaging pair is available.
- Stale-documentation audit: removed the obsolete Chromium 151 version
  reference from `docs/FINGERPRINT_RUNTIME.md`; the statement is now
  version-neutral and remains accurate across the source/runtime boundary.
- Fresh post-audit checks at `2026-09-21T13:17:58Z`: local aggregate audit is
  still partial/blocked only at runtime security, runtime rebase, and live
  network evidence; 42 AffPapa tests and the focused runtime/tree tests pass.
