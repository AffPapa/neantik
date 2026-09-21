# Run log

## 2026-09-21

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
