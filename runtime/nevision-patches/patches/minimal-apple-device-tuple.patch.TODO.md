# minimal-apple-device-tuple

This is a porting scaffold, not a Chromium patch file.

Release blocker: keep `series.json` group `minimal-apple-device-tuple` as `planned` until a real Chromium 150 patch exists, applies with `git apply --check --whitespace=nowarn`, and records `patchSHA256` plus Chromium 150 `postimageSHA256` values.

Required behavior:

- if tuple spoofing is retained, GPU, CPU, memory, screen, scale, platform, and Client Hints come from one reviewed tuple
- if tuple spoofing is deferred, real device values are kept and only rendered/noise surfaces differ
- independent random CPU/GPU/screen guesses are forbidden

Forbidden implementation scopes:

- automation-evasion
- webdriver-hiding
- headless-hiding
- fake-shadow-roots
- random-browser-version
- broad-fake-font-list
- independent-cpu-gpu-screen-guesses

Porting checklist:

- Replace this TODO with a real patch file named `minimal-apple-device-tuple.patch` only after the Chromium 150 source root exists.
- Verify the patch against the real Chromium 150 source tree with zero fuzz.
- Record the real patch hash in `runtime/nevision-patches/series.json`.
- Record postimage hashes for every Chromium source file touched by this group.
