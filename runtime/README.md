# NeAntik Chromium runtime

NeAntik Direct embeds a patched Chromium runtime. Browser-visible changes are
implemented in Chromium source rather than injected into pages.

Current public-alpha target:

- Chromium `150.0.7871.186`;
- Apple Silicon ARM64 only;
- Metal enabled;
- outer bundle `NeAntik Browser.app`;
- bundle identifier `app.neantik.runtime`.

## Files

- `fingerprint-chromium.lock.json` — exact upstream and build-time provenance;
- `chromium-150-rebase-plan.json` — source preparation policy;
- `nevision-patches/series.json` — release-ready Chromium 150 patch manifest;
- `nevision-patches/patches/` — the seven owned patch groups;
- `apple-device-tuples.json` — reviewed Apple Silicon tuples;
- `security-baseline.json` — release security baseline;
- `licenses/` — required upstream licenses.

The internal `nevision` path and C++ namespace are legacy implementation
identifiers retained for source/binary compatibility. Renaming them requires a
new full Chromium build and new evidence; cosmetic file renaming would make
the published lock inaccurate.

## Build

Use a separate, disposable build root with substantial free space:

```bash
./scripts/preflight-runtime-rebase-150.py /absolute/path/to/build-root
./scripts/prepare-runtime-source.sh /absolute/path/to/build-root
./scripts/build-runtime.sh /absolute/path/to/build-root
```

Verify the patch manifest before building:

```bash
python3 scripts/verify-nevision-patchset-manifest.py --release
```

Verify a built app:

```bash
./scripts/verify-built-runtime.sh \
  "/absolute/path/to/NeAntik Browser.app" \
  /absolute/path/to/runtime-verification.json \
  /absolute/path/to/out/Default/args.gn
```

This checks version, ARM64-only Mach-O files, signature, source-lock markers,
runtime binary hashes, and Metal build evidence. It does not replace the GUI
A → B → A behavioral audit.

## Security boundary

The patch manifest explicitly forbids automation evasion, WebDriver/headless
hiding, random browser versions, broad fake-font lists, and unrelated
CPU/GPU/screen guesses. NeAntik is for privacy, separated sessions,
development, and QA—not bypassing third-party controls.

See [Chromium 150 runtime security](../docs/RUNTIME_SECURITY_REBASE_150.md).
