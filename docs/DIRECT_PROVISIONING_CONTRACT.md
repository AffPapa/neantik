# Direct provisioning contract — development gate

This build-tool validator is implemented and tested. Existing release packaging
still uses the app-ID-only entitlement contract. Production backup remains
disabled; this document does not describe a delivered backup feature.

## Why a profile is necessary

Data protection Keychain groups require provisioning authorization. Successful
notarization, Gatekeeper assessment, CMS decoding or one successful Keychain
operation does not establish that all identity claims match the profile.

The existing Developer ID macOS profile grants the production App ID exactly and
a wildcard Keychain group. It does **not** grant the separate backup QA App ID.
The observed QA scope create/read/delete and service recovery results are kept,
but they are not accepted as a matching provisioning contract. The validator
rejects that combination. A matching macOS Developer ID QA profile is needed
before adoption into production signing.

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

## Evidence and limits

- Nine unit tests cover grants, malformed input, late replacement, path limits,
  signing claims and preparation write-fault rollback.
- Nine actual Security controls passed: authentic Apple profile, incorrect QA
  App ID, incorrect certificate, unsigned/truncated/mutated/foreign-signed CMS,
  actual hardened QA code signature and actual QA/profile mismatch refusal.
- No production app was executed and no Keychain item operations were performed
  by these validator controls. No release-packaging adoption is claimed.
- A matching QA profile, qualified packaging, actual backup restore/GUI tests
  and the exact notarized candidate are still required for product enablement.

References: [Apple TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles),
[CMS signer verification](https://developer.apple.com/documentation/security/cmsdecodercopysignerstatus(_:_:_:_:_:_:_:)),
[Apple Security CMS decoder](https://github.com/apple-oss-distributions/Security/blob/main/SecurityTool/macOS/cmsutil.c),
[Apple profile-signing policy](https://github.com/apple-oss-distributions/Security/blob/main/OSX/sec/Security/SecPolicy.c).
