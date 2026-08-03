# Authenticated GUI fingerprint evidence (schema 8)

Status: the source implementation, deterministic cross-language contract,
one-shot persistence, collector, notarization and hosted-release gates are
implemented. Physical Secure Enclave and fresh GUI A → B → A acceptance still
have to be run for every exact Developer ID candidate. This document is not
evidence that a public build has passed those hardware and GUI gates.

## Purpose

Schema 7 remains the private diagnostic contract for browser observations in
a direct-control plus A → B → A run. It contains profile-scoped data and must
never become release evidence. The signed manager derives a separate, strictly
typed aggregate payload without profile UUIDs or names, identity codes or
seeds, proxy data, URLs, cookies, or raw browser-surface values. Schema 8
authenticates only that privacy-safe aggregate so the release pipeline can
detect post-capture edits, evidence from another candidate and reuse of a
one-time challenge.

The full envelope is private release evidence. Base64 is encoding, not
encryption. Public artifacts may contain only the separately reviewed
sanitized attestation and its evidence hash.

## Candidate binding

The exact immutable candidate manifest contains one `fingerprintEvidence`
object:

```json
{
  "schemaVersion": 1,
  "algorithm": "P256-SHA256",
  "authorityKeyID": "lowercase SHA-256 of the 65-byte X9.63 public key",
  "publicKeyX963": "canonical padded Base64",
  "sessionID": "uppercase canonical UUID",
  "challenge": "canonical Base64 of exactly 32 random bytes"
}
```

The verifier requires candidate-manifest schema 3 and parses this object from
the exact bounded manifest bytes. The
whole manifest must be UTF-8 compact sorted-key canonical JSON with literal
forward slashes; duplicate keys, unknown binding keys and alternate whitespace
are rejected before decoding. A key, session or challenge supplied only by
the report is not trusted.

## Signed transcript

The P-256 ECDSA signature uses SHA-256 over this exact byte sequence:

```text
UTF8("NeAntik GUI fingerprint evidence v8\0")
|| SHA256(exact candidate manifest bytes)
|| UTF8(lowercase canonical session UUID)
|| raw 32-byte challenge
|| SHA256(exact payload bytes)
```

All variable fields after the fixed domain have fixed lengths: 32, 36, 32 and
32 bytes. The signature is stored as canonical padded Base64 of strict DER
ECDSA. Producers normalize P-256 signatures to low-S and verifiers reject the
mathematically equivalent high-S form, so transport bytes cannot be changed
through ECDSA malleability.

## Envelope

The outer JSON has schema version 8, kind
`neantik-gui-fingerprint-evidence`, encoding `base64-json-utf8`, the exact
payload and authentication metadata derived from the manifest. Swift emits
compact sorted-key JSON. Verification caps raw bytes before decoding, requires
that canonical representation, rejects unknown keys and verifies the
signature before accepting the inner aggregate. The inner payload must also
be compact sorted-key canonical JSON with an exact key set and exact UTC-second
timestamp. It records only candidate/runtime provenance, verdict, per-surface
stability states, sorted unavailable/unstable key names, sequence and
coherence booleans, and qualification limitations. Unknown keys and raw
schema-7 payloads are rejected. The private schema-7 semantic gate runs inside
the manager before derivation; release consumers accept only schema 8.

## Independent verifier

`scripts/verify-fingerprint-evidence-envelope.py` independently implements the
bounded duplicate-safe parser, exact aggregate structure check, exact
transcript and strict low-S DER contract with Python's standard library. CLI
inputs must be non-symlink regular files and are size-checked before reading.
The verifier invokes only the fixed `/usr/bin/openssl` executable without a
shell; there is no executable override. It has no pip dependency and prints
only non-secret content hashes; authority key, session, challenge, signature
and payload are not included in its summary. Read failures are reported
without echoing local paths.

The checked-in fixture pins the exact manifest, payload, transcript and
transport hashes. Its Swift/CryptoKit signature is verified through
Python/OpenSSL, and a separately generated OpenSSL low-S signature over the
same transcript is verified by Swift.

`SecureEnclaveFingerprintEvidenceSignerTests` verifies the production
signer's lifecycle and fail-closed API with an injected in-memory P-256
backend. These deterministic tests do not access Keychain or Secure Enclave.
Together with the cross-language fixture they prove the code contract, not
operation of physical hardware in a signed release candidate.

## Release boundary

The software P-256 signer exists only in debug builds for unit tests. The
production implementation requests a non-exportable P-256 private key from
Secure Enclave, stores only its reference in Data Protection Keychain as
`WhenUnlockedThisDeviceOnly` with `privateKeyUsage`, and has no software
fallback. Audit code loads an already enrolled, manifest-pinned key and never
creates or rotates one. Immediately before signing, the app claims the
candidate challenge with an atomic add-only `WhenUnlockedThisDeviceOnly` Data
Protection Keychain item. Key lookup requires exactly one matching private
Secure Enclave key. After signature self-verification, the authority is
not used again. The exact signed envelope is first committed to a private
owner-only recovery receipt under Application Support, then the authority is
deleted, and only those byte-identical receipt bytes may be atomically
published to the requested output. Recovery verifies the envelope against the
same manifest plus the exact Keychain claim digest; it runs during candidate
loading, before the GUI and before any signer lookup, and never needs a newly
captured report. Recovery therefore survives process relaunch after the
Secure Enclave key was deleted. Recovery directories are created and traversed
through no-follow directory descriptors, and every new directory entry plus
the final receipt is fsynced before the authority is deleted. A duplicate claim
or interruption before a complete receipt burns the candidate. A failure
during key deletion or output publication can resume only from the durable
signed receipt.

The final signed manager has one strict headless enrollment intent. The
release script reserves a new private `0700` attempt directory, then executes
the exact `Contents/MacOS/NeAntik` binary without a shell. The app generates
the session UUID and 32-byte challenge internally, creates and reloads the
Secure Enclave key, completes a local sign/verify self-test, and durably writes
only the compact six-field public binding as a new `0600` file. Existing or
symlinked outputs, unsafe parents, ad-hoc builds, unavailable user sessions,
timeouts and any Keychain/Secure Enclave error stop preparation. No key,
challenge, session or binding content is printed.

The release-mode app requires a new non-symlink output path, reads the
manifest and executable through bounded stable-file checks, verifies the exact
schema-3 root and all ten critical-file entries, and checks its running
executable hash and bundle version/build before opening the GUI. It keeps the
raw schema-7 report only in memory, signs the derived aggregate, self-verifies
the envelope, commits a private `0600` recovery receipt and atomically
publishes a byte-identical `0600` output without overwrite. If that receipt
already exists on relaunch, the app validates and publishes it immediately,
without opening the GUI or loading the destroyed signer. Diagnostic mode
may still save raw reports under Application Support, but release scripts
cannot collect them.

This source and its deterministic tests do not prove a physical Secure
Enclave, non-exportability on the release Mac, persistence across relaunch or
update, access-control behavior, or continuity of the Developer ID identity.
A Direct release must therefore fail closed until all of these are verified:

- real enrollment by the exact final Developer ID-signed Apple Silicon
  candidate before finalizing the immutable candidate manifest;
- create, reload, sign, verify and exact-key deletion on that release Mac;
- privacy-safe aggregate creation inside the signed manager;
- authenticated schema-8 collector, notarization and hosted-release gates;
- local attestation-to-evidence binding plus exact downloaded
  archive-to-candidate verification;
- a fresh physical-hardware and GUI acceptance run for that exact candidate.

Unsupported or unavailable Secure Enclave, locked or denied Keychain, a
missing/corrupt key, or a manifest mismatch is a hard failure. None may select
a software signer.

Schema 8 does not attest a remote device, prove an uncompromised macOS host or
provide anonymity. It proves only the stated candidate/key/challenge/payload
binding within the documented local trust boundary.
