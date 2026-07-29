# Direct distribution

NeAntik is distributed directly for Apple Silicon. The Mac App Store is not a
release target.

## Source and binaries

The Git repository contains the manager source, runtime patchset, source locks,
build scripts, tests, licenses, and release metadata. It does not contain the
multi-gigabyte Chromium checkout, build cache, `.app`, or notarized ZIP.

Public binaries are attached to versioned GitHub Releases:

```text
https://github.com/AffPapa/neantik/releases/download/vVERSION/NeAntik-VERSION-arm64-notarized.zip
```

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

## Signing boundary

Developer ID certificates, private keys, Apple credentials, and notary
profiles remain in the release owner's Keychain. They are not committed,
printed, uploaded as GitHub Actions secrets, or requested in issues.

The initial GitHub workflow builds and tests unsigned source only. Signed
release artifacts are produced on the trusted local Apple Silicon builder and
uploaded after verification.

## Installation

1. Download the notarized ZIP from GitHub Releases.
2. Extract it.
3. Move `NeAntik.app` to Applications.
4. Open it.
5. Create a profile.
6. Configure a proxy if needed.
7. Launch the profile.
