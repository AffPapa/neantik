# nevision-branding-and-source-lock

This is a porting scaffold, not a Chromium patch file.

Release blocker: keep `series.json` group `nevision-branding-and-source-lock` as `planned` until a real Chromium 150 patch exists, applies with `git apply --check --whitespace=nowarn`, and records `patchSHA256` plus Chromium 150 `postimageSHA256` values.

Required behavior:

- bundle metadata identifies NeAntik Browser and app.neantik.runtime
- source lock records Chromium base, mac packaging base, patchset hash, notices, and binary hashes
- ARM64 Metal build and normal GUI A -> B -> A evidence are regenerated after Chromium 150 port

Forbidden implementation scopes:

- automation-evasion
- webdriver-hiding
- headless-hiding
- fake-shadow-roots
- random-browser-version
- broad-fake-font-list
- independent-cpu-gpu-screen-guesses

Porting checklist:

- Replace this TODO with a real patch file named `nevision-branding-and-source-lock.patch` only after the Chromium 150 source root exists.
- Verify the patch against the real Chromium 150 source tree with zero fuzz.
- Record the real patch hash in `runtime/nevision-patches/series.json`.
- Record postimage hashes for every Chromium source file touched by this group.
