# Building NeAntik from source

## Manager

Requirements:

- Apple Silicon Mac;
- macOS 14 or newer;
- Xcode 26 or newer;
- Swift 6.2 toolchain.

Run:

```bash
./scripts/verify-native-swift-tests.sh
./scripts/verify-native-swift-release.sh
```

`scripts/package-app.sh` creates a manager-only app bundle. It does not
download Google Chrome and does not produce the complete public application
without a runtime.

## Chromium runtime

The repository intentionally does not contain a multi-gigabyte Chromium source
checkout or build output. Runtime provenance is split into:

- `runtime/fingerprint-chromium.lock.json` — upstream source and build-time
  provenance;
- `runtime/nevision-patches/series.json` — release-ready Chromium 150 patch
  manifest;
- `runtime/nevision-patches/patches/` — patch files;
- `runtime/apple-device-tuples.json` — reviewed Apple Silicon tuple catalog;
- `runtime/licenses/` — upstream licenses.

The internal `nevision` names are retained in patch paths and compatibility
identifiers because renaming them changes the compiled runtime and must be
performed only with a complete rebuild and new binary evidence.

Prepare and build in a separate disposable directory with ample free space:

```bash
./scripts/preflight-runtime-rebase-150.py /absolute/path/to/build-root
./scripts/prepare-runtime-source.sh /absolute/path/to/build-root
./scripts/build-runtime.sh /absolute/path/to/build-root
```

The exact workflow and acceptance gates are documented in
[RUNTIME_SECURITY_REBASE_150.md](RUNTIME_SECURITY_REBASE_150.md).

The published `0.3.12` binary is source-pinned and its patches and build
evidence are auditable, but the project does not yet claim independently
reproducible bit-for-bit output. Developer ID signing and notarization also
make the public ZIP builder-specific.

## Direct release

Signing requires a Developer ID Application identity. Notarization requires a
Keychain profile created locally by the release owner. Never store either in
the repository or GitHub Actions secrets for the initial public workflow.

The local release path is:

```bash
export NEANTIK_SIGNING_IDENTITY="Developer ID Application: …"
export NEANTIK_NOTARY_PROFILE="your-keychain-profile"
export NEANTIK_RELEASE_CHANNEL="public-alpha" # or production
export NEXT_PUBLIC_NEANTIK_DOWNLOAD_URL="https://example.com/NeAntik-VERSION-arm64-notarized.zip"

./scripts/prepare-direct-runtime-candidate.sh \
  "/absolute/path/to/NeAntik Browser.app" \
  /absolute/path/to/args.gn \
  /absolute/path/to/chromium/src \
  /absolute/path/to/runtime-candidate-lock.json

# Run a fresh GUI A → B → A audit from dist/NeAntik.app, then collect it
# against dist/direct-candidate-manifest.json and the same release channel.
./scripts/release-direct.sh
```

The first phase signs one exact candidate and writes a non-overwriting manifest
of the complete bundle. The second phase refuses to rebuild or re-sign it and
requires GUI evidence created after that manifest. `production` requires strict
production qualification; `public-alpha` never silently upgrades that verdict.
Only upload after notarization, stapling, Gatekeeper, and SHA-256 pass.
