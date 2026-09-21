# Network Reality Harness

This document defines a small evidence contract for NeAntik's effective
network-route measurements. The verifier is intentionally local and
stdlib-only. It validates a producer's minimized report; it does not perform
network requests, inspect traffic, resolve DNS, or prove that an observed
route is real by itself.

## Scope and boundary

The report must come from an authorized local or self-hosted producer/harness.
The producer is responsible for performing the controlled measurement and
reducing its output to this contract. A configured proxy, resolver rule, or
Chromium launch flag is not an effective-route observation.

This contract is measurement infrastructure, not anti-fraud or evasion logic.
It does not promise anonymity, universal stealth, or a successful bypass of
third-party controls. Without an authorized local/self-hosted producer, a
valid report is only a well-formed claim and is not proof of real network
egress.

## Exact JSON schema

The root must be an object with exactly these fields. No additional fields,
nested objects, arrays, IP addresses, hostnames, credentials, cookies, raw ICE
candidates, headers, paths, or free-form notes are permitted.

| Field | Type and allowed values |
| --- | --- |
| `status` | `verified`, `partial`, `failed`, `blocked`, or `unverified` |
| `routeMode` | `direct`, `proxied`, or `unknown` |
| `effectiveHTTPRouteObserved` | boolean; true only when the producer observed the HTTP route |
| `dnsPath` | `observed`, `not_observed`, or `blocked` |
| `negotiatedProtocol` | `http1`, `http2`, `http3`, or `unknown` |
| `tlsObserved` | boolean |
| `webrtcDirectCandidates` | non-negative integer count, never raw candidates |
| `bypassDetected` | boolean |
| `generatedAt` | UTC RFC3339 timestamp ending in `Z` |
| `runtimeHash` | optional lowercase 64-character digest; digest only, never a secret |

The verifier also rejects duplicate JSON keys, non-standard JSON numbers,
oversized input, and non-UTF-8 input.

## Status semantics

- `verified` requires an observed route, observed DNS path, known negotiated
  protocol, observed TLS, zero direct WebRTC candidates, and no detected
  bypass. These are consistency gates, not an independent network probe.
- `partial` means some evidence exists but the complete verified contract is
  not satisfied.
- `failed` requires a detected bypass or direct WebRTC candidates on a route
  explicitly marked `proxied`.
- `blocked` requires a blocked DNS path.
- `unverified` is the honest state when the producer cannot establish the
  effective result. In particular, configured route data must remain
  `unverified` or `partial`, not `verified`.

The verifier does not infer status from configuration and does not upgrade a
report. The producer must explicitly set `effectiveHTTPRouteObserved`.

The repository includes `scripts/run-network-reality-harness.py`, a local
self-hosted HTTP smoke producer. It starts a temporary loopback endpoint and
performs one request with ambient system proxy settings disabled, then emits
`partial` evidence with HTTP/1 observation. It deliberately leaves DNS, TLS,
HTTP/2/3, proxy egress, and WebRTC as unobserved. If the local socket cannot
be created or cleaned up, it emits `unverified`; that is not DNS-block
evidence. A successful run must not be upgraded to `verified`.

## CLI

Validate a file:

```bash
python3 scripts/verify-network-reality-report.py /path/to/report.json

python3 scripts/run-network-reality-harness.py --json \
  | python3 scripts/verify-network-reality-report.py -
```

Or validate JSON from stdin:

```bash
cat /path/to/report.json | python3 scripts/verify-network-reality-report.py -
```

Exit code `0` means the report satisfies this schema and its consistency
gates. Any malformed, over-specified, unsafe, or contradictory report exits
nonzero. The CLI never makes an external network request.

## Example

```json
{
  "status": "partial",
  "routeMode": "direct",
  "effectiveHTTPRouteObserved": true,
  "dnsPath": "not_observed",
  "negotiatedProtocol": "http1",
  "tlsObserved": false,
  "webrtcDirectCandidates": 0,
  "bypassDetected": false,
  "generatedAt": "2026-09-19T12:34:56Z",
  "runtimeHash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
```

The example is accepted as a contract-shaped report. It becomes meaningful
network evidence only when an authorized local/self-hosted producer generated
it from a controlled measurement and its provenance is checked separately.

## Verification boundary

The loopback producer is only the first controlled step. The next step is an
authorized producer for controlled DNS, TLS, HTTP/2/3, proxy egress, and
WebRTC measurements. Every producer must retain no raw IP, DNS name, cookie,
credential, header, or ICE candidate in the report artifact.
