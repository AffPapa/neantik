# Versioned fingerprint observations

## Current development contract

| Field | Current | Historical |
| --- | --- | --- |
| Raw audit | 8 | 7 |
| Signed payload | 2 | 1 |
| Candidate public binding | 2 | 1 |
| Authenticated envelope / transcript domain | 9 / v9 | 8 / v8 |
| Public attestation | 4 | 3 |
| Policy | `repeatable-critical-observations-v1` | mandatory cross-profile WebGL difference |

Binding2 pins envelope9, audit8, payload2 and the policy ID in the authenticated
candidate manifest. Closed dispatch has no fallback after failed verification.
Historical bytes, fixtures and schema8 verification remain unchanged.
The current development contract has local tests and scoped headed runtime
observations. It is not an issued major release or a notarized final app.

## What the result means

All critical observations must be available and repeatable for profile A.
Production additionally requires repeated API reads, page/worker coherence,
the reviewed device tuple, profile/identity sequence, exact runtime signature
and hashes, and network privacy controls. Errors or unavailable contexts never
become PASS. Complete mathematical API behavior, storage isolation and actual
browser route tests remain separate mandatory qualification work.

`changedCriticalKeys` records actual observed differences. The raw `verdict`
continues to summarize their count: `verified` for at least two, `partial` for
one, `unchanged` for none; unstable observations remain `unstable`.
`criticalObservationsStable` is a separate signed field. Equal WebGL pixels
between profiles do not imply broken isolation: the same GPU and draw can
legitimately produce the same output. Artificial uniqueness is not required.
Neither a unique hash nor stable equal pixels prove anonymity or data isolation.

The UI shows availability/repeatability separately from observed differences.
A production-qualified claim must carry all strict coherence flags and no
missing/unstable measurements, even inside a public-alpha envelope.

## Verification

- Swift audit, envelope, enrollment, recovery and observation tests.
- Swift-produced schema9 signature verified by Python/OpenSSL, and the reverse.
- Historical schema8 still verifies; a stable-same schema8 payload is refused.
- Wrong policy/schema tuple, domain replay, manifest/key/challenge/runtime
  substitution, missing/unstable readbacks, forged changed keys and contradictory
  production claims are refused.
- Headed M156 extraction uses the manager's exact shader/readPixels block,
  with added SHA256/byte-count observations after reading. A/B/A with distinct
  seeds on the same hardware cohort reproduces stable equal readback. It is
  research runtime evidence; it does not replace the final signed manager gate.

Raw legacy collector mode intentionally accepts only audit7. Current release
collection requires the exact integrated candidate and signed schema9 input.
Private recovery uses `envelope.schema9.json`; old recovery receipts are not
rewritten or promoted. Old immutable public assets are never modified.
