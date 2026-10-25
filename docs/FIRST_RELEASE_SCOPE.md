# NeAntik first release scope

**Target:** Direct 0.9.0 (140), public alpha. It is the shortest supported release path that ships the current Chromium manager without claiming the unfinished owned-WebKit feature set as complete.

## Current progress

- Source scope and version floor: **PASS**; 0.9.0 (140) follows the reconciled public baseline 0.8.26 (138).
- MCP documentation contract: **PASS**, 18 management and 7 read tools.
- Full Swift regression: **PASS**, 1,837 tests in 222 suites, 80 explicit skips; source unchanged during run. Receipt: `.build/neantik-local/test-receipts/20261025T103242Z-1541.json`.
- Candidate build, alpha GUI qualification, notarization, GitHub publication, and browser.free update: **not started**.

## Included

- Chromium M156.0.8078.48 from the pinned, existing runtime build.
- Isolated Chromium profiles and the existing manager workflow.
- Cancellation of a profile launch while preparation is still in progress, with the existing admission retained until cleanup finishes.
- Separate system-WebKit preview where macOS provides it.
- Apple Developer ID signature, notarized ZIP and DMG, and the existing Direct Distribution channels.

## Not included or qualified

- NeAntik-bundled WebKit runtime or a claim that this is Safari.app.
- WebKit proxy, extensions, or any fallback to direct networking when a proxy is configured.
- WebKit BrowserData backup/restore.
- Stable 1.0 claim, complete owned-WebKit license applicability decisions, or a complete matching source/build/relink offer.

## Release sequence

1. Freeze a clean source commit and build 0.9.0 (140) using the existing `public-alpha` route.
2. Reuse the completed full Swift suite and all matching receipts; perform one alpha-qualified A→B→A check on the frozen candidate. The release runner is capped at one GUI attempt, so a setup failure is diagnosed instead of retried in a loop.
3. Sign and notarize one ZIP and DMG; verify the exact local bytes.
4. Publish matching GitHub assets and browser.free version/download metadata; fetch and compare live bytes and links.

The 1.0 plan resumes after this alpha. Its remaining owned-WebKit work is tracked in `NEXT_1_0_SLICES.md`; no public claim should imply those gates passed.
