# NeAntik release acceptance plan

This file defines release gates, not current candidate identity. The private maintainer checkpoint is maintained separately and is not included in public source archives.

## Published Chromium baseline and dual-engine development

Preserve the published Chromium-only baseline, rollback and existing profile data during dual-engine qualification. Private QA can include owned WebKit. Enable it in production only after the exact production runtime, its source offer and notices pass the applicable gates.

## Required gates

1. Freeze a clean source tree and bind the manager, each packaged runtime, build outputs, notices and license decisions. Check that the engine picker agrees with the exact bundle's launch capabilities.
2. Verify the recipient source offer and documented tools cover rebuilding and relinking each distributed engine where its license requires it.
3. On the same signed dual-engine candidate, qualify both manager launch paths, separate profile stores, stop/reopen and final process exit. For each enabled proxy path, measure the intended route, refusal without direct fallback, and recovery with an independent positive control.
4. Verify WebRTC blocking and any enabled relay mode with an owned observer. WebKit uses macOS language and time zone. Report that boundary and measure any other advertised privacy controls on the engine that applies them.
5. Sign and notarize the exact Apple Silicon ZIP and DMG, staple tickets, verify Gatekeeper, publish through GitHub Releases and browser.free, then verify downloaded bytes.

## Resume rule

Reuse evidence only when candidate bytes, harness, environment, and scope still match. After a repeated identical failure, diagnose its boundary before another attempt. A failed setup is not product-runtime evidence. Direct Distribution is the only release channel.
