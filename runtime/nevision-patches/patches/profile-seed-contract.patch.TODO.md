# profile-seed-contract

This is a porting scaffold, not a Chromium patch file.

Release blocker: keep `series.json` group `profile-seed-contract` as `planned` until a real Chromium 150 patch exists, applies with `git apply --check --whitespace=nowarn`, and records `patchSHA256` plus Chromium 150 `postimageSHA256` values.

Required behavior:

- browser-visible profile identity is derived from the stable NeAntik fingerprint seed
- missing or malformed seed fails closed to stock behavior
- ordinary pages do not receive audit-only DevTools probes

Forbidden implementation scopes:

- automation-evasion
- webdriver-hiding
- headless-hiding
- fake-shadow-roots
- random-browser-version
- broad-fake-font-list
- independent-cpu-gpu-screen-guesses

Porting checklist:

- Replace this TODO with a real patch file named `profile-seed-contract.patch` only after the Chromium 150 source root exists.
- Verify the patch against the real Chromium 150 source tree with zero fuzz.
- Record the real patch hash in `runtime/nevision-patches/series.json`.
- Record postimage hashes for every Chromium source file touched by this group.
