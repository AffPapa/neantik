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
`dist/NeAntik.app`, runs its strict headless Secure Enclave enrollment from the
signed-in user's Terminal, then writes the compact schema-3
`dist/direct-candidate-manifest.json` with a full bundle inventory and the
validated public binding. Every attempt uses a new private `0700` state
directory; its binding and log are never public artifacts. A fresh GUI
A → B → A audit must be run by that exact candidate with explicit canonical
manifest/output paths. The app keeps raw schema-7 observations in memory and
writes one authenticated schema-8 privacy aggregate; release tooling rejects
raw diagnostic reports.
`release-direct.sh` only verifies and notarizes it; it never rebuilds or
re-signs after the GUI run. Notarization pins the manifest, schema-8 evidence,
attestation and Info.plist to a private owner-only transaction. The live app is
packaged exactly once. Apple receives that sealed private ZIP; after the same
submission ID is independently confirmed `Accepted`, only a fresh app
extracted from that ZIP is stapled. A new final ZIP is built from the staged
app, reverified, and published without replacement after its durable SHA-256
sidecar. The final ZIP path appears last and is the release commit point. A
private hash-bound schema-2 receipt records both the Apple-submitted and final
archive hashes, the exact clean Git commit/tree, a SHA-256 closure of the
security-sensitive release/verifier sources, and the candidate-manifest
runtime evidence hashes. The local Chromium toolchain lock is recorded only
as `reviewedToolchainLockSHA256`: until the next Chromium rebuild embeds that
lock into runtime provenance, the receipt does not claim that the binary was
built by that toolchain. The release channel is explicit:
`public-alpha` accepts the documented alpha threshold, while `production`
requires strict coherent production qualification.

Every external and publication boundary is an append-only, canonical,
hash-named and hash-linked state transition under the owner-only transaction:
`transaction-created → submission-ready → submit-intent → submission-known →
accepted → final-verified → sidecar-committed → zip-committed →
publication-complete`. The Apple upload uses `submit --no-wait`; its canonical
submission ID is durably committed before the separate wait. A restart from
`submission-known` polls only that ID. A restart from `accepted` re-extracts
the retained exact submitted ZIP, and publication recovery adopts a sidecar
or ZIP only when it is the same inode and hash as the retained private
artifact. The ZIP remains the only public commit marker. No recovery path
re-submits an already known Apple transaction.

Pre-activation directories use a canonical UUID name, a durable owner-only
marker, an exclusive lease, and a global initialization coordinator lock.
After activation the new path is reopened without following symlinks and its
device/inode is compared with the descriptor created before the rename. On
completion or an ordinary pre-effect failure, the exact transaction directory
is moved with no-overwrite semantics into owner-only `.notary-retired/`.
Release code does not recursively delete it: macOS has no unlink-by-open-inode
primitive, so a stat-then-unlink cleanup could remove a same-user replacement.
Unknown, replaced, or crash-abandoned initialization paths fail closed for
operator reconciliation; public archives, sidecars, and private receipts are
never included in this retirement policy.

Before a new Apple submission, `notary_transaction_inspector.py` performs a
strict read-only descriptor-relative inspection. It validates owner, mode,
device, link count, marker, lease, canonical hash chain and cross-stage seals.
An initialization path, a pre-effect active path, an ambiguous
`submit-intent`, an interrupted retired post-effect path, or unsafe metadata
blocks a new submission. A valid, version-matched active transaction from
`submission-known` onward may enter the notarizer's exact recovery validation;
this continuity verdict does not replace its candidate/source/receipt/public
destination checks. Safe `.notary-retired/` history
is counted but not enumerated, never blocks a release, and is never treated as
permission for automatic deletion. The report contains only bounded counts
and stage/status enums—no paths, per-entry identifiers, UUIDs, archive names,
hashes or Apple identifiers.

```bash
python3 scripts/notary_transaction_inspector.py \
  --project-root . \
  --expected-archive-name NeAntik-X.Y.Z-arm64-notarized.zip \
  --release-gate
```

One uncertainty boundary is intentionally fail-closed: if the process dies
after the durable `submit-intent` but before the Apple submission ID is
recorded, the service may have received the upload. The next run refuses to
submit again. An operator must reconcile the unique transaction-UUID filename
against `notarytool history`; zero or multiple matches are not guessed.

Release source provenance requires the exact clean `AffPapa/neantik` Git
worktree. Branch name, remote URL, clone path and user identity are not
recorded as provenance. Git-specific environment overrides are sanitized;
the wider build environment is not claimed as reproducible provenance.
Ignored `dist/` artifacts are allowed;
tracked, staged or untracked source changes fail closed. The historical
untracked development working directory therefore cannot be used as source
provenance for a new release; prepare and release the next candidate from the
clean open-source checkout instead.
The tracked inventory is read from the already captured tree object, accepts
only regular-file blob modes, and uses one NUL-framed `git cat-file --batch`
session with explicit file-count, path, per-file, aggregate, request and
response limits. Commit, tree and worktree status are checked again after the
descriptor-bound file reads; every worktree byte still has to match its
committed blob exactly.

The Direct release wrapper requires a native ARM64 Homebrew Python 3.11 or
newer at `/opt/homebrew/bin/python3`. Check it before release:

```bash
/opt/homebrew/bin/python3 -I -B -c \
  'import platform,sys; print(platform.machine(), sys.version.split()[0])'
```

The wrapper uses isolated mode and a private empty bytecode-cache prefix so
ignored `__pycache__` files cannot replace reviewed release helpers. The
interpreter version is an execution prerequisite, not a claim of reproducible
Chromium toolchain provenance.

After uploading the versioned ZIP without changing public links, repeat the
complete archive and Gatekeeper gate against fresh downloaded bytes:

```bash
python3 scripts/verify-direct-hosted-download.py \
  --candidate-manifest dist/direct-candidate-manifest.json \
  --fingerprint-evidence dist/fingerprint-audit.json \
  --fingerprint-attestation dist/fingerprint-audit-summary.json \
  --release-channel public-alpha \
  --download-url https://github.com/AffPapa/neantik/releases/download/vVERSION/NeAntik-VERSION-arm64-notarized.zip
```

The verifier rejects credentials, query strings, fragments, wrong filenames,
SHA-256 or size changes, and any downloaded archive that fails the same local
notarized-app, integrated-runtime, stapling, and Gatekeeper checks. For every
new release, the candidate manifest, release channel, authenticated schema-8
evidence and public-safe attestation are mandatory together;
the verifier extracts both local and freshly downloaded ZIPs and proves their
`NeAntik.app` bundle matches the prepared candidate. Historical artifacts
created before this contract require the explicit `--legacy-archive-only`
compatibility flag; that flag is forbidden for new releases.

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
./scripts/Run-NeAntik-0.3.14-DMG-Release.command
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
