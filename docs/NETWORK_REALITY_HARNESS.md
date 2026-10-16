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

### Physical upstream TCP listener failure

`manager-route-fixture.py --physical-tcp` uses the separate
`manager-tcp-fixture.py` successor. It closes the owned upstream listener with
`shutdown()` and `server_close()`, checks actual connection refusal with an
independent fixture socket, and rebinds the same endpoint on recovery. The
origin stays available. This differs from returning HTTP 502 or closing a
connection after accepting it. It does not change macOS networking or DNS.

Start with the exact signed downloaded app, one enrolled QA authority and a
matching candidate manifest. Native resource admission is required. Use a new
private output directory:

```bash
python3 -B scripts/runtime-network/manager-route-fixture.py \
  --app /absolute/NeAntik.app \
  --candidate-manifest /absolute/qa/candidate-manifest.json \
  --output /absolute/qa/tcp-run --duration 900 --physical-tcp
```

The fixture seeds **two metadata profiles, initially without a proxy**. Before
the `before-launch` snapshot, configure only `QA route proxy` through the audit
GUI, using its private state's proxy port and the fixture's public dummy
credentials. The audit GUI uses memory-only password storage. Leave
`QA route direct` unchanged. Do not use a separate ordinary MCP process to
write a proxy password: it does not share the audit GUI's password backend.

Capture `before-launch` and `proxy-success` with `collect-manager-tcp.py
--state /absolute/qa/tcp-run/private-state.json --phase <phase>`. Send
`{"action":"stop-listener"}` to the fixture's operator stdin. Navigate the
same protected browser to the private state's `listener-refused` URL. Retain
only the exact matching omnibox address and visible connection error from an
explicitly selected owned CUA window, one value per line, in a private0600
`owned-cua-failure-values.txt`. Reduce it with:

```bash
python3 -B scripts/runtime-network/observe-manager-tcp-failure.py \
  --state /absolute/qa/tcp-run/private-state.json \
  --ax-observation /absolute/qa/tcp-run/owned-cua-failure-values.txt
```

This is an operator-mediated CUA observation, not unattended UI attestation.
Missing/mismatched address or error fails. For automated address entry, prefer
setting and reading back the omnibox value before Enter; a mistyped URL is a
harness failure, not a successful navigation.

Capture `listener-refused`; after a failure window of at least five seconds,
launch the separate Direct profile and capture `direct-control`. Send
`{"action":"recover-listener"}` to the fixture, navigate the original
protected session to its recovery URL and capture `proxy-recovered`. Native
Stop/Quit must finish before capturing `cleanup`. Then run:

```bash
python3 -B scripts/runtime-network/analyze-manager-tcp.py \
  --receipts /absolute/qa/tcp-run --release /absolute/releases/v0.8.21.json
```

The analyzer requires unchanged live manager/browser/relay generations,
revision, lease, session, configuration and exact runtime hashes; real peer
socket ownership; a refused nonce navigation; no protected origin arrival;
an independent Direct hit during the outage; same-endpoint recovery and
settled cleanup. Source hashes and the retained reduced CUA input must match.
Retire the temporary authority separately; no fingerprint rerun is needed.

This scenario passed on the exact downloaded0.8.21(133):
[minimized evidence](evidence/manager-tcp-0.8.21.json). It does not establish
the manager's POSIX errno, a TCP RST, physical network switching, global
DNS/UDP behavior, default-trusted HTTPS upstream support or all1.0 gates.

### Headed WebRTC boundary matrix on downloaded133

`scripts/runtime-network/run-webrtc-boundaries.mjs` runs a separate, closed
eleven-case matrix. It uses the signed runtime from the downloaded app, an
independent binding to the published runtime tree and all 16 Mach-O files,
temporary profiles, mock Keychain, and owned HTTP/STUN loopback servers.
It never reads real profiles or exports raw ICE/SDP. This is QA tooling, not
an MCP tool or an arbitrary script execution interface.

Each case first proves that its UDP collector can receive and acknowledge a
canary. It then checks three named effective preferences, executes the browser
operation, waits for ICE completion, closes the browser, and reads final UDP
counters. A timeout, crash, forced termination, wrong realm or failed cleanup
cannot pass. Stored user preferences and effective preferences are separate:
CLI, extension and policy stores have different priorities. The renderer's
strict CLI guard must also survive a permissive higher-priority store.

Cases cover direct/guarded traffic, permissive URL exceptions, own MV3 privacy
extension setters/getters, a profile-local test policy, and a local-IP allowlist.
The final pair proves that a matching URL exception actually enables STUN when
the CLI guard is absent, while a nonmatching exception does not.

Run the three `test-webrtc-*.mjs` files for model, pipe and owned UDP controls.
For native QA, supply explicit absolute `--app`, `--binding`, and new private
`--output` paths. `--case direct` runs a pilot; `--resume` skips matching passed
cases only when the binding, harness and environment match. Admission is checked
before each browser. Never replace a failed receipt or treat these controls as
global networking evidence. Model tests do not launch a browser.

[Published observations](evidence/webrtc-boundaries-0.8.21.json) cover eleven real
headed runs on macOS27 ARM64. They do not cover manager relay integration,
OS-managed policy, IPv6/TURN, full mDNS disclosure behavior, network transitions,
or an ordinary Chrome comparison. The frozen earlier research harness and its
receipts remain unchanged.

### Normal manager / authenticated relay WebRTC integration

`manager-route-fixture.py --manager-webrtc` selects the separate
`manager-webrtc-fixture.py`. It seeds the usual two metadata profiles and
permissive user WebRTC preferences in the fresh protected BrowserData. Configure
only the owned proxy profile through the audit GUI with the fixture's dummy
HTTP credentials. The signed audit manager uses memory-only password storage.
Keep the Direct profile unchanged. No CDP, browser flag override, extension,
OS policy or ordinary user profile is introduced by this fixture.

With one fresh admitted QA authority and exact downloaded-app manifest:

```bash
python3 -B scripts/runtime-network/manager-route-fixture.py \
  --app /absolute/NeAntik.app \
  --candidate-manifest /absolute/qa/candidate-manifest.json \
  --output /absolute/qa/webrtc-run --duration 900 --manager-webrtc
```

Capture `before-launch` after configuring the proxy. Start the protected profile,
wait for its own page's WebRTC completion, capture `proxy-success`, then start
the separate Direct profile and capture `direct-control`. In the original
protected browser, follow its `proxy-repeat` link and capture `proxy-repeat`.
Use `collect-manager-webrtc.py --state <private-state.json> --phase <phase>`.
The same protected browser/relay/configuration must survive both reads.

Every phase has an independent UDP4 STUN socket and real canary→ACK→zero-counter
control. The page returns bounded candidate-category/error counts and completion
over the normal HTTP route, never SDP/addresses/raw ICE. The collector links
each protected HTTP request to its live relay socket through an owned request
ID. Direct HTTP and the positive UDP source port are linked to the live signed
browser/helper generation. A single UID or a page-provided count is insufficient.

Stop both profiles through the manager, then Quit the manager. After the fixture
has closed, capture `cleanup`; it retains reduced termination reason/status
from each fresh private manager log. Require one normal main-process exit with
status0 per profile, zero remaining processes and no fixture termination signals.
This is not a claim about all renderer exit statuses or saved user data. Retire
the temporary authority through the existing narrow operation, then analyze:

```bash
python3 -B scripts/runtime-network/analyze-manager-webrtc.py \
  --receipts /absolute/qa/webrtc-run --release /absolute/releases/v0.8.21.json
```

The first offline analysis overclassified generic HTTP refusals as failed
WebRTC. An independent socket-only test reproduces a rejected favicon CONNECT
that leaves an empty origin connection. Actual native refused request targets
were not retained: their cause remains unclassified. The corrected analyzer
keeps their counts/times and requires all original nonce, ICE, UDP, live socket,
session and exit controls. It never reports an all-HTTP-clean result. The
original refusal is retained; the browser was not rerun for this analysis fix.

[Downloaded133 observations](evidence/manager-webrtc-0.8.21.json) confirm
protected/Direct/protected-repeat STUN counts **0/1/0**. This does not cover
OS-managed policies, IPv6/TURN, external interfaces or network transitions.
The earlier eleven-case raw-runtime matrix remains separate evidence.

### Future HTTP refusal diagnostics

New WebRTC fixtures retain only closed enums for the failure stage, request
category and failure category. No URL, query, header, exception message or
credential is copied. A private per-run salt and the actual own loopback TCP
tuple produce an optional digest shared by the proxy and origin ends. Foreign
origins, non-loopback endpoints and closed sockets produce no digest.

The analyzer retains legacy events as `unclassified`. Complete new metadata
must use the declared schema and enums; malformed or partial metadata is
rejected. Two opposite events with the same digest within two seconds receive
an **event-pair hint**, not proven socket identity or cause. Duplicate, distant
and unpaired groups remain ambiguous. Port reuse cannot be ruled out solely
by this hint. `causeEstablished`, `browserCustodyEstablished` and
`allHTTPCleanQualified` remain false.

Owned Python socket controls reproduce favicon rejection and its empty origin
connection, verify the matching digest, and confirm that formatter failures
preserve the original refusal event. Pure controls reject wrong enums/types,
partial metadata, duplicate groups and false cause/custody claims. These are
fixture tests; no browser is launched. Generic HTTP/DNS fixtures keep the
previous ledger through an empty default hook.

This instrumentation applies to **future observations**. The original native
two proxy failures and two origin refusals have no retained request categories
or digest; their cause is still unknown. Old native reports and source hashes
are not rewritten. See [development evidence](evidence/http-refusal-diagnostics-development.json).

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

## Background and download operations on the130 runtime

[The scoped current report](evidence/background-network-0.8.18.json) records
a unique signed DEBUG QA manager with the exact public130 runtime. Its80s
window includes startup, owned completed/canceled downloads, idle observation,
a proxy outage and recovery. Background/component/sync/extensions suppression
flags were absent. Seven accepted fixture connections were bound to the retained
lease/session, kernel process generations, live/static CDHash and exact relay
client socket. The original manager had exited; this is deliberately a retained
DEBUG session measurement, not a live shipping-GUI manager claim.

`background-peer-custody.py` handles this lifetime explicitly. Its baseline raw
lease hash covers all fields; generation/code/accepted socket are read anew for
each request. It never authorizes arbitrary same-UID or Apple networking processes.

`observe-background-downloads.mjs` uses the existing download observer with
scoped `Browser.setDownloadBehavior` ACK before the fixture opens its attachment
endpoint. Only two fixed owned download URLs and explicit download/target
operations are admitted. The completed4096-byte file was verified after native
close; cancellation was acknowledged and left no final file. An intentional
headed Direct control reached its separate owned origin with kernel helper
ancestry and was classified Direct, with zero expectedRelay selections.

Default NetLog selected seven relay legs and zero Direct legs in the protected
window; one request failed during the controlled outage. Socket evidence applies
only to the owned fixture requests. No vendor/unclassified request in this
window is not proof of no telemetry. Global DNS/UDP, explicit component-update
activation, network changes, other environments and default-trusted HTTPS upstream
remain open. The production runtime and immutable release archives did not change.
