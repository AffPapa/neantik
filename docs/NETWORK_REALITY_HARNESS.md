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
| `effectiveHTTPRouteObserved` | boolean; true only when the producer observed the browser's HTTP route |
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
self-hosted transport fixture. It starts a temporary loopback endpoint and
performs one Python request with ambient system proxy settings disabled. It
always emits `unverified`, `effectiveHTTPRouteObserved=false`, and unknown
browser route/protocol. A successful Python connection cannot establish any
Chromium HTTP, proxy, DNS, TLS or WebRTC behavior. This legacy fixture tests
local wiring and report compatibility; it is not a browser qualification gate.
Actual owned Chromium traces use `scripts/controlled-browser-route-observer.py`
with separate runtime/session and endpoint evidence. That observer also has a
bounded scope; its result is not a continuous DNS or leak guarantee.

### Controlled DNS producer

`scripts/runtime-network/controlled-dns-fixture.py` extends the existing owned
HTTP-auth proxy fixture with a loopback UDP DNS server. Only its random test
names resolve, only to its own origin. DNS refusal, TCP cut/refusal and recovery
are independent operator controls. The optional `--doh` endpoint uses a one-day
self-signed certificate; nothing is added to macOS trust or system DNS settings.
The fixture denies the base fixture's external GeoIP destinations.

`run-controlled-dns.mjs` measures three fresh headed sessions of the exact
signed runtime identified by a published release report: proxy/failure/recovery,
Direct DoH with DNS refusal, and intentional proxy bypass. It uses mock Keychain,
private temporary data, restricted navigation/auth CDP over a pipe, and fresh
resource admission before each session. There is no arbitrary page JS evaluation.
The explicit SPKI override is confined to the fixture certificate and cannot
qualify OS-default-trusted HTTPS proxy support.

The operator first starts the fixture with `--root OWN_EMPTY_0700_DIRECTORY
--doh`, keeping its stdin open. In a second terminal, run:

```bash
node scripts/runtime-network/run-controlled-dns.mjs \
  /absolute/isolated/NeAntik.app /absolute/published-release.json \
  /absolute/fixture-root /absolute/empty-0700-output
python3 -B scripts/runtime-network/analyze-controlled-dns.py \
  /absolute/output/observations.json /absolute/published-release.json
```

Stop the fixture by sending `{"action":"stop"}` on its operator stdin. Keep
private descriptors, raw runtime logs, test keys and browser data local. The
minimized observations contain phase/count/hash evidence instead of addresses,
credentials or DNS names. Protocol, actual local UDP/TLS, failure, malformed
message, bypass sensitivity and shutdown controls have local tests. These tests
qualify the harness only: a complete successful headed observation is still
required. A refused or missing session fails analysis. Even a completed raw
runtime result does not cover the manager's relay, all OS DNS/UDP, background
requests, or other hardware; those remain separate gates.

### WebRTC source check

`scripts/verify-chromium-webrtc-policy.py` checks the expected Chrome switch,
preference and renderer source markers. Comment-only markers and markers
starting inside ordinary/raw literals are refused, including comments extended
by C++ line splicing. This is a source check, not compilation or evaluation of
preprocessor branches. Its PASS does not prove the effective browser policy.
Exact headed UDP/STUN controls, preference/policy/exception/extension influence
and process cleanup still need independent runtime evidence. A source-checker
fix does not change or requalify the already published Chromium runtime.
The switch definition may be in the legacy `chrome_switches.cc` or in the
M156 inline `chrome_switches.h`. A present invalid legacy file cannot be
bypassed by a valid header. The pinned M156 upstream blobs provide a real
source control; patched postimages and compiled runtime remain separate gates.

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
