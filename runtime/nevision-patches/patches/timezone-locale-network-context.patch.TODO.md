# timezone-locale-network-context

This is a porting scaffold, not a Chromium patch file.

Release blocker: keep `series.json` group `timezone-locale-network-context` as `planned` until a real Chromium 150 patch exists, applies with `git apply --check --whitespace=nowarn`, and records `patchSHA256` plus Chromium 150 `postimageSHA256` values.

Required behavior:

- timezone is captured and stable in the GUI fingerprint report
- WebRTC candidate data is hashed rather than persisted raw
- proxy failover remains disabled by NeAntik launch configuration

Forbidden implementation scopes:

- automation-evasion
- webdriver-hiding
- headless-hiding
- fake-shadow-roots
- random-browser-version
- broad-fake-font-list
- independent-cpu-gpu-screen-guesses

Porting checklist:

- Replace this TODO with a real patch file named `timezone-locale-network-context.patch` only after the Chromium 150 source root exists.
- Verify the patch against the real Chromium 150 source tree with zero fuzz.
- Record the real patch hash in `runtime/nevision-patches/series.json`.
- Record postimage hashes for every Chromium source file touched by this group.
