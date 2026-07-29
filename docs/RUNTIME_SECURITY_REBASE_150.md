# Chromium 150 runtime source and security boundary

The current public-alpha runtime is Chromium `150.0.7871.186`, ARM64, with
Metal enabled.

## Pinned evidence

- `runtime/fingerprint-chromium.lock.json` records upstream repositories,
  commits, trees, build-time overlay hashes, branding hashes, and licenses.
- `runtime/nevision-patches/series.json` targets Chromium
  `150.0.7871.186`; all seven release-required groups are `ported`.
- every patch records its own SHA-256 and expected Chromium postimage hashes;
- `runtime/security-baseline.json` records the primary Chrome Releases source
  used for the release security gate;
- `runtime/apple-device-tuples.json` contains the reviewed Apple Silicon
  device catalog.

The lock is build-time provenance and intentionally preserves the verification
state that was embedded into the built runtime. Post-build public release
status is recorded separately in `releases/v0.3.12.json`; rewriting the lock
after signing would break the provenance relationship.

## Verification

Manifest-only:

```bash
python3 scripts/verify-nevision-patchset-manifest.py --release
python3 scripts/verify-apple-device-tuples.py
python3 scripts/verify-runtime-security-baseline.py --allow-public-alpha-tuples
```

Against a real Chromium checkout:

```bash
python3 scripts/verify-nevision-patchset-manifest.py \
  --release \
  --source-evidence \
  --source-root /absolute/path/to/chromium/src
```

The source-root gate requires clean `git apply --check` results and matching
postimage hashes. A version bump requires a new baseline, new port evidence, a
complete runtime rebuild, and fresh GUI A → B → A evidence.

## Explicitly forbidden scope

The patch manifest rejects automation/anti-detection evasion work, including
WebDriver hiding, headless hiding, fake shadow roots, random browser versions,
broad fake font lists, and independently guessed CPU/GPU/screen values.

NeAntik's legitimate scope is stable profile separation, privacy, development,
and QA. It does not provide CAPTCHA, ban, anti-fraud, or platform-rule bypass.

## Current limitation

The `0.3.12` release passed the public-alpha GUI isolation gate. This does not
claim strict production coherence across every fingerprint, network, TLS, font,
locale, timezone, and proxy-geography surface.
