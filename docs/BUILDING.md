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

For day-to-day SwiftUI and manager work, use the isolated fast loop instead:

```bash
./Develop-NeAntik.command
```

The first run creates an APFS clone of the already packaged Chromium runtime.
Warm runs rebuild and replace only the Swift manager. `NeAntik Dev.app` uses
the bundle ID `app.neantik.desktop.dev`, Application Support directory
`NeAntik Development`, and Keychain service `app.neantik.dev.proxy`; it does
not migrate or read production credentials. Use `--no-open` in automated
checks and `--refresh-runtime` only when the local embedded runtime changed.
This command never creates or mutates a release candidate.

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

Do not use the Direct release path for UI iteration. Run
`./Release-NeAntik.command` only after the exact final candidate has passed
local tests; a changed candidate requires new exact evidence, while an
unchanged candidate resumes its existing transaction.

### Release failure shields

- Never modify `dist/NeAntik.app`, a prepared manifest, fingerprint evidence,
  ZIP or DMG after the exact candidate is sealed.
- Reuse A → B → A evidence only when it is bound to the same candidate; UI,
  manager, runtime or fingerprint changes require fresh evidence, while
  documentation-only changes do not.
- Do not delete or hand-edit an unfinished notarization transaction. Resume it
  only when its source snapshot and candidate digest still match; otherwise
  prepare a new exact candidate.
- Resolve the Developer ID identity from the already signed app. Never paste a
  display name into a script, because Unicode/terminal encoding can corrupt it.
- Synchronize runtime security baseline evidence before sealing a candidate;
  do not patch baseline metadata inside the sealed `.app`.
- Build ZIP and DMG from the same verified `.app`. A notarized empty or stale
  container is not a valid release even if Apple accepts the container itself.
- Publish only after local ZIP/DMG checks pass. Hosted verification downloads
  the public file again and compares its SHA-256; CDN lag is not fixed by
  changing the local candidate.

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

# Launch the exact app with its manifest and a new schema-8 output path.
# Run GUI A → B → A; the app signs only a privacy-safe aggregate.
# Then collect that explicit schema-8 file against the same manifest/channel.
./scripts/release-direct.sh
```

The first phase signs one exact candidate, invokes that exact signed executable
in a strict headless mode to create and self-test a candidate-scoped Secure
Enclave authority, then writes a non-overwriting schema-3 manifest of the
complete bundle and public binding. Every enrollment attempt receives a new
private state directory. Ad-hoc builds intentionally skip this release
manifest. The second phase refuses to rebuild or re-sign the candidate and
requires one-shot authenticated GUI evidence created after that manifest.
It pins the manifest, evidence, attestation and Info.plist in a private
transaction, packages the live app once, and submits only that sealed ZIP.
After Apple returns and independently confirms `Accepted`, stapling targets a
fresh app extracted from the accepted ZIP. The final ZIP is verified in the
transaction and published without replacement after its durable checksum.
Raw schema-7 diagnostic reports are never accepted. `production` requires
strict production qualification; `public-alpha` never silently upgrades that
verdict. Only upload after authenticated schema-8 GUI evidence, notarization,
stapling, Gatekeeper, and SHA-256 pass.

Immediately before notarization, the release entrypoint runs the read-only
local transaction continuity gate. It permits a candidate-version-matched
known transaction to enter the notarizer's exact recovery validation, but
blocks abandoned initialization, pre-effect active state, ambiguous
`submit-intent`, unsafe metadata, or interrupted retired state after a
possible Apple effect. The continuity layer checks the current versioned
archive, retained submitted/final artifacts and exclusive release lock. The
notarizer remains the final authority for channel, candidate inputs, clean
source/runtime evidence, private receipts and public destinations.
Owner-only `.notary-retired/` history is retained for
recovery evidence; the gate neither deletes it nor interprets a clean result
as approval to delete it.

`./scripts/verify-native-swift-suite.sh
SecureEnclaveFingerprintEvidenceSignerTests` checks deterministic lifecycle
and fail-closed behavior with an injected backend only. It is not a hardware
acceptance test. Before a candidate is published, the exact final
Developer ID-signed candidate must create, reload, sign, verify and delete its
candidate-scoped key on a supported Apple Silicon Mac. The release must stop
without that result; never export or request the private key.
