# Authenticated GUI fingerprint evidence (schema 8)

Status: implementation in progress. This document describes the cryptographic
envelope contract. It is not evidence that a public build has passed the GUI
audit.

## Purpose

Schema 7 remains the semantic contract for the browser observations in a
direct-control plus A → B → A run. Schema 8 wraps the exact, already
privacy-sanitized schema-7 JSON bytes so that the release pipeline can detect
post-capture edits, a report from another candidate and replay against another
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
signature before accepting the inner schema-7 object. The inner payload must
also be compact sorted-key canonical JSON and decode as a complete current
`FingerprintAuditReport`. Report and capture UUIDs use uppercase canonical
wire form, and all report/capture timestamps use exact UTC-second
`YYYY-MM-DDTHH:MM:SSZ` form. Unknown schema-7 report or capture keys are
rejected. The existing schema-7 semantic and privacy gates still run
independently after authentication.

## Independent verifier

`scripts/verify-fingerprint-evidence-envelope.py` independently implements the
bounded duplicate-safe parser, complete schema-7 structure check, exact
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
creates or rotates one. Enrollment first claims a unique candidate session
with an atomic `WhenUnlockedThisDeviceOnly` Data Protection Keychain
reservation; key lookup requires exactly one matching private Secure Enclave
key. The reservation remains until explicit candidate abandonment, so a
failed or interrupted enrollment cannot silently reuse the same challenge.

This source and its deterministic tests do not prove a physical Secure
Enclave, non-exportability on the release Mac, persistence across relaunch or
update, access-control behavior, or continuity of the Developer ID identity.
A Direct release must therefore fail closed until all of these are verified:

- real enrollment by the exact final Developer ID-signed Apple Silicon
  candidate before finalizing the immutable candidate manifest;
- create, reload, sign, verify and exact-key deletion on that release Mac;
- already-sanitized payload creation inside the signed manager;
- production-candidate release-gate integration beyond the checked CI
  two-direction Swift/CryptoKit-to-OpenSSL fixture contract;
- collector, notarization and hosted-release gates that require schema 8;
- replay/single-use handling and unchanged schema-7 semantic/privacy checks.

Unsupported or unavailable Secure Enclave, locked or denied Keychain, a
missing/corrupt key, or a manifest mismatch is a hard failure. None may select
a software signer.

Schema 8 does not attest a remote device, prove an uncompromised macOS host or
provide anonymity. It proves only the stated candidate/key/challenge/payload
binding within the documented local trust boundary.
