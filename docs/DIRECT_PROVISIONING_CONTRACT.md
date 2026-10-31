# Direct provisioning contract — development gate

The validator and opt-in manager packaging are implemented. Published releases
still use the app-ID-only entitlement contract and have backup disabled. Product
enablement requires a qualified, notarized candidate; implementation is not a
delivered feature.

## Why a profile is necessary

Data protection Keychain groups require provisioning authorization. Successful
notarization, Gatekeeper assessment, CMS decoding or one successful Keychain
operation does not establish that all identity claims match the profile.

The existing Developer ID macOS profile grants the production App ID exactly and
a wildcard Keychain group. It does **not** grant the separate backup QA App ID.
The observed QA scope create/read/delete and service recovery results are kept,
but they are not accepted as a matching provisioning contract. The validator
rejects that combination. A separate matching macOS Developer ID QA profile was issued and validated on
2026-10-11. Its actual isolated create/new-process-read/delete/missing controls
passed. Full service recovery and GUI export/restore now pass under that matching
QA profile. Exact release packaging, legacy proxy ACL compatibility and the
notarized candidate remain separate gates before production adoption.

## One existing signing certificate

The release entry point already selects the exact public certificate SHA1
`474F7C78F33EE324C24F6F5AE0443EB713E85E60` by default. Use this same existing
Developer ID Application certificate for QA and product signing. The portal
contains two identically named certificates: match the public fingerprint,
not the display name. No additional certificate was issued or revoked for QA.

The production profile and isolated QA profile authorize different App IDs;
both use the existing selected certificate. Generate only the exact QA group
`H6VGU2M6JD.app.neantik.desktop.backup-qa` for the isolated QA application.
Original downloaded profiles stay outside source control. A provisioned product
must embed its authenticated macOS profile before signing; it contains public
authorization/certificate data, never the signing private key or backup key.
The separate QA profile is never included in a public product artifact.
Certificate renewal is an explicit signing-contract change, never an automatic
fallback to another identically named identity.

## Independent checks

1. Authenticate the CMS signature using Apple's macOS provisioning signing
   policy, exactly one signer, valid signer status and evaluated certificate
   trust. A decoded plist is insufficient.
2. Require OSX, all-devices Developer ID distribution, validity dates, exact
   team/prefix, authorized App ID/group and exact signing leaf certificate.
3. Generate only the exact App ID, Team ID and a single identity-derived group.
   A wildcard **grant** never becomes a wildcard **claim**.
4. Embed the authenticated bytes before signing, then check the actual signed
   app: Apple-anchored Developer ID Application leaf, exact identifier/team,
   hardened runtime, strict/all-architecture/nested signature validity, actual
   entitlements, authorized signing certificate and embedded byte equality.
5. An invalid or missing provisioned profile cannot fall back to legacy signing.
   Notarization, stapling, Gatekeeper and exact runtime tests remain separate.

## Build-only helper

`scripts/direct-provisioning-security.c` uses the private system policy factory
through `dlsym`. It is compiled into a disposable directory with the project
developer-dir resolver. It is **never shipped in or linked into the application**.
Missing policy symbol is a hard refusal, with no BasicX509/email-policy fallback.
The ordinary Apple OCSP policy is not a claim of a fresh positive OCSP response.
The helper has no Keychain-item operations.

Inspect a matching QA profile without signing or launching an app:

```sh
python3 scripts/verify-direct-provisioning-contract.py \
  --profile /absolute/path/to/matching-qa.provisionprofile \
  --bundle app.neantik.desktop.backup-qa \
  --certificate-sha1 EXACT_40_CHARACTER_PUBLIC_CERTIFICATE_SHA1
```

Preparation additionally requires `--app /absolute/path/to/unsigned-qa.app` and
`--output-entitlements /absolute/path/to/new-claims.plist`. Both output files
must be new, regular, non-symlink paths. On write failure, newly created outputs
are rolled back. This is preparation, not a signed-app verdict.

After the app is signed, run the same command with `--app` and without
`--output-entitlements`. Supplying the original profile binds its exact bytes.
Do not change the legacy proxy Keychain implementation or production groups
merely to make the QA test pass.

## Explicit manager packaging opt-in

`direct_backup_signing.py` is shared by standalone, manager-update and runtime
candidate signing paths. Defaults retain legacy claims. To opt in, supply both
`NEANTIK_BROWSER_DATA_BACKUP_ENABLED=1` and
`NEANTIK_DIRECT_PROVISIONING_PROFILE=/absolute/path/to/production.provisionprofile`.
The identity must equal the existing pinned certificate fingerprint above.
Missing profile, ad-hoc signing, profile/capability disagreement, foreign QA
metadata or silent downgrade of a provisioned source refuses preparation.

Only the owned staged app is changed. Authenticate the input profile first,
embed its bytes, atomically seal the capability, sign, and authenticate the actual
signed app with byte binding before enrollment. Source and rollback apps remain
immutable. An interrupted/failed preparation is an unenrolled candidate, never
publishable. The final ZIP re-extraction runs the same Direct verifier.

Production composition selects only `H6VGU2M6JD.app.neantik.desktop` explicitly
for its device-scoped backup key. Construction performs no key operation. Release
audits select an unavailable backend before any capability; QA/development
flags cannot enable product access. Proxy credentials retain the existing
classic Keychain backend and services without a new access-group query.

## Evidence and limits

- Nine unit tests cover grants, malformed input, late replacement, path limits,
  signing claims and preparation write-fault rollback.
- Nine actual Security controls passed: authentic Apple profile, incorrect QA
  App ID, incorrect certificate, unsigned/truncated/mutated/foreign-signed CMS,
  actual hardened QA code signature and actual QA/profile mismatch refusal.
- No production app was executed and no Keychain item operations were performed
  by these validator controls. No release-packaging adoption is claimed.
- A matching QA profile and signed-code postcheck now pass; actual synthetic
  scope creation, read in a new process, owned deletion and missing refusal pass.
  Full service/GUI qualification under that profile now passes. Qualified product
  packaging and the exact notarized candidate remain required for product
  enablement. Actual synthetic classic proxy upgrade now passes: legacy App-ID
  only -> provisioned three claims -> legacy rollback read, with migration,
  wrong-digest refusal, owned deletion and new-process missing checks.

## Classic proxy upgrade test identity

Use the same app basename in separate QA directories, matching a normal
`NeAntik.app` update, and compare actual designated requirement lines and the
manager hashes. A renamed `.app` is a separate negative control, not the normal
upgrade baseline. Apple Security's classic password deletion safety check compares
the trusted application's final path component; different QA filenames can
produce `errSecInvalidOwnerEdit` even when reads and designated requirements agree.
The qualified test used only random passwords in UUID-scoped QA services, kept
the binding digest in private pipes, and verified deletion of every owned item.
No proxy query, ACL or production credential was changed to pass this control.

Build output paths vary between Swift build systems. Bind the QA copy to the
actual compiler output and its hash before native testing; do not infer the
binary from a previously used scratch subdirectory.

References: [Apple TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles),
[CMS signer verification](https://developer.apple.com/documentation/security/cmsdecodercopysignerstatus(_:_:_:_:_:_:_:)),
[Apple Security CMS decoder](https://github.com/apple-oss-distributions/Security/blob/main/SecurityTool/macOS/cmsutil.c),
[Apple profile-signing policy](https://github.com/apple-oss-distributions/Security/blob/main/OSX/sec/Security/SecPolicy.c).
[Classic deletion safety check](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_keychain/lib/SecItem.cpp#L1997).
