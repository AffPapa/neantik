# Direct distribution

NeAntik is distributed directly for Apple Silicon. The Mac App Store is not a
release target.

## Source and binaries

The Git repository contains the manager source, runtime patchset, source locks,
build scripts, tests, licenses, and release metadata. It does not contain the
multi-gigabyte Chromium checkout, build cache, `.app`, or notarized ZIP.

Public binaries are attached to versioned GitHub Releases. ZIP is the canonical
archive; a DMG with an Applications shortcut may be published as an additional
installation option:

```text
https://github.com/AffPapa/neantik/releases/download/vVERSION/NeAntik-VERSION-arm64-notarized.zip
https://github.com/AffPapa/neantik/releases/download/vVERSION/NeAntik-VERSION-arm64-notarized.dmg
```

## Chromium 150 provenance boundary

`runtime/chromium-150-source-contract.json` records the exact Chromium and
macOS-packaging source pair for the next runtime build. It deliberately has
`binaryBindingStatus: pending-new-build`: it is source evidence, not a claim
about an older distributed binary. A release build must emit and verify both
`source-provenance.json` and `runtime-candidate-lock.json` beside the source
root; `prepare-direct-runtime-candidate.sh` refuses to package a runtime
without those records.

The `releases/` directory records archive name, size, SHA-256, runtime version,
platform, and verification status. The ZIP itself must never be committed to
Git.

## Release requirements

A public release must:

1. use a version and build newer than the previous public release;
2. build the manager in Release mode for ARM64;
3. embed the source-pinned Chromium runtime;
4. preserve all third-party notices;
5. pass the Swift, privacy, localization, runtime, and A → B → A gates;
6. sign every nested Mach-O with Developer ID Application;
7. use Hardened Runtime and a trusted timestamp;
8. be accepted by Apple notarization;
9. staple the ticket to `NeAntik.app`;
10. pass `codesign`, `stapler`, and Gatekeeper after a fresh extraction;
11. publish a SHA-256 sidecar and release metadata;
12. be downloaded again from GitHub and independently reverified before the
    release is marked public.

The release is deliberately two-phase. First,
`prepare-direct-runtime-candidate.sh` creates and signs one exact
`dist/NeAntik.app`, then writes `dist/direct-candidate-manifest.json` with a
full bundle inventory. A fresh GUI A → B → A audit must be collected from that
exact candidate. `release-direct.sh` only verifies and notarizes it; it never
rebuilds or re-signs after the GUI run. The release channel is explicit:
`public-alpha` accepts the documented alpha threshold, while `production`
requires strict coherent production qualification.

After uploading the versioned ZIP without changing public links, repeat the
complete archive and Gatekeeper gate against fresh downloaded bytes:

```bash
python3 scripts/verify-direct-hosted-download.py \
  --candidate-manifest dist/direct-candidate-manifest.json \
  --release-channel public-alpha \
  --download-url https://github.com/AffPapa/neantik/releases/download/vVERSION/NeAntik-VERSION-arm64-notarized.zip
```

The verifier rejects credentials, query strings, fragments, wrong filenames,
SHA-256 or size changes, and any downloaded archive that fails the same local
notarized-app, integrated-runtime, stapling, and Gatekeeper checks. For every
new release, the candidate manifest and release channel are mandatory together;
the verifier extracts both local and freshly downloaded ZIPs and proves their
`NeAntik.app` bundle matches the prepared candidate. Omitting both flags remains
available only for historical artifacts created before this manifest contract.

## Signing boundary

Developer ID certificates, private keys, Apple credentials, and notary
profiles remain in the release owner's Keychain. They are not committed,
printed, uploaded as GitHub Actions secrets, or requested in issues.

The initial GitHub workflow builds and tests unsigned source only. Signed
release artifacts are produced on the trusted local Apple Silicon builder and
uploaded after verification.

For schema-8 evidence, the final Developer ID-signed candidate must enroll its
candidate-scoped Secure Enclave authority before candidate-manifest schema 3
is finalized. The manifest pins that public key; the same protected key must
sign the GUI envelope. CI and injected-backend tests are not hardware
acceptance evidence, and Direct publication has no software-signing fallback.

## Creating the DMG

After `dist/NeAntik.app` has passed the normal signed release gate, run:

```bash
./scripts/Run-NeAntik-0.3.12-DMG-Release.command
```

The script derives the Developer ID identity from the signed application and
uses the `neantik-notary` Keychain profile. It refuses to submit an empty,
undersized, unsigned, or incomplete image to Apple. The resulting DMG is moved
to `dist/` only after notarization is Accepted and the image, outer signature,
stapled ticket, Gatekeeper assessment, embedded app, and SHA-256 all pass.
Publishing to GitHub or the product site remains a separate hosted-verification
gate.

Before upload, the release flow runs
`scripts/verify-direct-notarized-dmg.sh` against the temporary final image.
After upload, run `scripts/verify-direct-hosted-dmg.sh` with the final public
HTTPS URL. The hosted gate downloads the image into a new temporary directory,
requires byte-for-byte SHA-256 and size equality with the local artifact, then
repeats the container, mounted-app, stapling, runtime and Gatekeeper checks.

## Installation

1. Download the notarized DMG or ZIP from GitHub Releases.
2. Open the DMG (or extract the ZIP).
3. Drag or move `NeAntik.app` to Applications.
4. Open it.
5. Create a profile.
6. Configure a proxy if needed.
7. Launch the profile.
