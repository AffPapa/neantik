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

The compact schema above is separate from the richer private producer ledgers.
Raw signed Chromium DNS controls are recorded in the scoped
[0.8.15 report](../releases/v0.8.15.json). That does not qualify a manager session
or prove global absence of DNS/UDP leakage. TLS/HTTP2/3, background activity,
network changes and other environments require their own observations.
Public reports must not contain personal IPs, cookies, credentials, headers,
raw DNS names or ICE candidates.

## HTTPS identity and CONNECT custody

`scripts/runtime-platform/run-https-identity.mjs` is a separate finite producer.
It starts two owned TLS origins and a loopback CONNECT proxy. The proxy connects
only to those origins and refuses other destinations. Private pages execute
fixed probes and POST bounded results; the CDP pipe permits navigation and
lifecycle, not arbitrary JavaScript evaluation. An independent wire ledger binds
request nonce, origin role, TLS peer, CONNECT and the owned browser/helper kernel
process generation. Initial documents, warm-up frames and redirect hops are
checked as well as final fetches.

The four headed sessions are ordinary retained Chrome, unconfigured exact
NeAntik runtime, configured runtime, and intentional Direct. A real request with
contradictory `Accept-Language` tests identity sensitivity. The Direct session
must reach the TLS origin with affirmative own-browser custody and no CONNECT;
missing proxy evidence alone cannot qualify it. Client Hint availability is
measured anew for each path, with Accept-CH priming, explicit delegation and a
non-delegated frame control. See the [Client Hints specification](https://wicg.github.io/client-hints-infrastructure/)
for the distinction between opt-in and cross-origin delegation.

```bash
node scripts/runtime-platform/run-https-identity.mjs \
  /absolute/isolated/NeAntik.app /absolute/published-release.json \
  /absolute/retained/Google-Chrome.app /absolute/reference-binding.json \
  /absolute/empty-0700-output
python3 -B scripts/runtime-platform/analyze-https-identity.py \
  /absolute/output/observations.json /absolute/published-release.json \
  /absolute/reference-binding.json
```

The reference binding pins `version`, `executableSHA256`, and `frameworkSHA256`
from independently retained ordinary Chrome evidence; it is not generated from
whatever executable happens to be installed. Each session requires fresh native
resource admission, a new profile and mock Keychain. Runtime bytes are checked
before and after the matrix. All inputs, source copies, raw synthetic identity
and observations stay private; the public report contains only hashes, counts,
checks and limitations. Do not publish the raw output directory.

The one-day certificate is generated locally; only its SPKI is excepted inside
the disposable test browser. No macOS trust setting changes, and the private key
is removed after sockets drain. This proves the scoped TLS origin/HTTP identity
path, **not** OS-default-trusted HTTPS proxy support, production manager/relay,
global DNS/UDP, HTTP2/3, background traffic or network changes. The first matrix
on published runtime129 passed without repetition: [results](evidence/https-identity-0.8.17.json).
The immutable application archives were not rebuilt or replaced.

## Manager / relay DNS producer

The new source tools extend the existing normal manager route; they do not
change Chromium, Swift launch policy, system DNS, trust stores or production
profiles. Each new fixture owns its UDP resolver, authenticated HTTP upstream,
origin, random names/nonces and temporary data directory. External connections
are denied by default. `--allow-manager-preflight` permits only the manager's
existing three GeoIP TLS hosts; it does not turn GeoIP into route evidence.

| Tool | Responsibility |
| --- | --- |
| `scripts/runtime-network/manager-route-fixture.py --controlled-dns` | Headed manager with two synthetic profiles; independent resolver and origin observations; bounded stdin fault control. |
| `scripts/runtime-network/collect-manager-dns.py` | Read-only metadata/lease, exact kernel process generations, live/static CodeDirectory, tokenized argv and per-request socket custody. |
| `scripts/runtime-network/analyze-manager-dns.py` | Offline acceptance of linked observations; missing, contradictory, stale or rejected origin arrivals fail. |
| `scripts/runtime-network/manager-dns-transition.py` | Optional private offline proof of a preflight context commit followed by markLaunched; reconstructs both complete metadata/configuration digests without altering receipts. |

The protocol uses one proxy browser session for success → SERVFAIL → recovery.
An explicitly separate Direct profile opens the same owned origin by literal
IP while the fault remains armed. This proves **origin sensitivity**, not a
Direct DNS route. A protected request must have a TCP client socket owned by
the exact relay generation; the Direct socket must belong to its owned browser
or a verified helper ancestry. A different local HTTP client cannot stand in
for Chromium. Every nonce-valid origin arrival is recorded before peer/header
rejection so the fixture cannot hide a bypass by refusing its response.

Start with the current Direct QA enrollment/manifest workflow on unchanged
signed bytes, a fresh resource admission and an empty private receipt directory:

```bash
python3 -B scripts/runtime-network/manager-route-fixture.py \
  --app /path/to/NeAntik.app \
  --candidate-manifest /private/tmp/neantik-update-audit-UUID/candidate-manifest.json \
  --output /private/tmp/neantik-dns-receipts-UUID \
  --controlled-dns --allow-manager-preflight
```

Keep stdin open: `{"action":"fail-dns"}`, `{"action":"recover"}` and
`{"action":"stop"}` are operator controls. Page visits cannot switch faults.
Configure only `QA route proxy` using the fixture's public dummy credentials.
Before launching it, collect `before-launch`; then collect `proxy-success`,
`dns-refused`, `direct-control` and `proxy-recovered` after the corresponding
headed observations. Keep at least five seconds between observed SERVFAIL and
the intentional Direct origin arrival. Every phase is one new file; existing
receipts are never overwritten.

```bash
python3 -B scripts/runtime-network/collect-manager-dns.py \
  --state /private/tmp/neantik-dns-receipts-UUID/private-state.json \
  --phase before-launch
```

Quit the owned browsers and manager, finish the fixture, collect `cleanup`,
then analyze that same receipt directory with `analyze-manager-dns.py --receipts`.
Retire the supplemental QA authority through its supported narrow operation;
the published candidate's original evidence remains unchanged. Timeout/SIGTERM
cleanup is never a graceful-close qualification.

**Current evidence:** the downloaded signed 0.8.18 (130), with its new font-policy runtime, completed the owned
manager/relay DNS path after normal admission: origin success, SERVFAIL with
no protected origin hit, an independent Direct origin while the fault stayed
armed, and recovery in the same protected session. Kernel socket custody,
profile/revision/configuration, exact runtime and process generations were
linked. Own processes drained and the supplemental QA authority was retired.
See [the current scoped report](evidence/manager-dns-0.8.18.json). The [128 report](evidence/manager-dns-0.8.16.json) remains bound to its original bytes; it was not relabeled.

The original analyzer FAIL is preserved. Two harness assumptions were wrong:
launch preflight persists timezone/locale/evidence before markLaunched, and
Chromium may retry a failed navigation while SERVFAIL remains armed. The
optional `--transition-witness PRIVATE_FILE` independently reconstructs the
baseline by removing only those three previously absent fields, checks the
entire remaining profile digest, and verifies the exact two revision commits.
All protected receipts must match the retained post-launch metadata. A refusal
must precede its custody snapshot; every retry must remain inside the same
armed epoch. Wrong metadata, configuration, times, peer/session, a protected
origin during failure, and missing cleanup still fail. No native recapture or
receipt amendment was used to correct these assumptions.

This qualifies owned upstream DNS only. OS-global DNS/UDP, idle/background,
network change and default-trusted HTTPS upstream remain separate gates.
The previous 127 memory-warning refusal remains a setup refusal, not a PASS.

### Narrow authority retirement after Chromium launch

Chromium on macOS may retain hardlinks of its executable for code-sign clones.
A changed link count can therefore cause the existing `nlink == 1` retirement
inspection to refuse an otherwise unchanged app. Do not weaken that check or
delete unknown aliases. For an owned QA authority, the existing retirement
contract permits a byte/mode/symlink-identical regular copy as `--candidate-app`.
Verify it against the **same** manifest and Developer ID in the authorized
macOS context; execute the original manager retirement command, never the copy.
Use an owned project path without symlink parents for this inspected copy:
`/tmp` app paths conflict with the provisioning reader's nofollow custody.
Keep canonical manifest/output spellings accepted by the launch parser.
No new authority, manifest, signature or browser recapture is needed. Preserve
the original app and all refusal receipts; accept cleanup only after the exact
candidate-scoped retirement receipt confirms deletion. This path completed
for the130 supplemental DNS authority.
