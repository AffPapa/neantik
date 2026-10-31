# NeAntik first-release acceptance plan — Chromium-only scope

This file defines release gates, not current candidate identity. The private maintainer checkpoint is maintained separately and is not included in public source archives.

## Current release scope

For the current first-release attempt, ship current stable Chromium for Mac only. Owned WebKit is deferred and must not be packaged or offered as a launchable engine in this candidate. Preserve existing WebKit profiles and their data; Chromium-only builds leave them readable and fail closed on launch. WebKit source, runtime and legal qualification remain a separate future milestone and do not block this Chromium-only candidate.

## Required gates

1. Freeze a clean source tree and bind exact Chromium and manager inputs, build outputs, notices and applicable license decisions; verify the package contains no owned WebKit host/runtime and exposes Chromium only.
2. Verify the recipient source offer can rebuild and relink the distributed Chromium runtime from the published source and documented tools.
3. Qualify the exact signed app: Chromium launch, profile isolation, per-profile proxy route, proxy refusal without direct fallback, and recovery.
4. Measure privacy behavior and document its limits. Do not promise maximum or absolute anonymity, undetectability, or bypass of site controls.
5. Sign and notarize the exact Apple Silicon ZIP and DMG, staple tickets, verify Gatekeeper, publish through GitHub Releases and browser.free, then verify downloaded bytes.

## Resume rule

Reuse evidence only when candidate bytes, harness, environment, and scope still match. After a repeated identical failure, diagnose its boundary before another attempt. A failed setup is not product-runtime evidence. Direct Distribution is the only release channel.
