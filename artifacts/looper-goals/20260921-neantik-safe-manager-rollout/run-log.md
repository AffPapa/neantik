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
