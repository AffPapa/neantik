# WebKit isolation: development component

**Strict network confinement is not qualified. Shipping WebKit proxy remains
disabled.** This separate Swift package does not change the shipping manager.
Build/preparation never installs an extension or saves a VPN configuration.
Those operations exist only in a separately authorized disposable QA stage.

## Current evidence

QA3, internal build3, used source `97afbb51bf02694f861046a2b3424dce832f9650`
and retained compiled input digest
`3d4c4992a671028a30fc87c760df405c69bdd10898bf1a180f1db139b7a26848`.
Its private ZIP SHA256 is
`0f4cdc51e99ba2d11700f79ecc165a6f70aa077c2778d65768dec472736214d3`.
This is a research fixture, not a NeAntik public release.

| Gate | Actual result |
|---|---|
| Signing | Existing release135 Developer ID; exact claims/certificate, hardened runtime and nested signatures pass. No new certificate or production/Keychain group. |
| Apple | QA3 Accepted, ticket/stapling and Gatekeeper pass; signed executable hashes unchanged. |
| OS setup | Exact QA extension activated; source-application rule saved and reread for signed Host A only. No global routing or domain/tool exceptions. |
| Provider | Process observed; own system journal reports connected and then stopProxy/disconnected. |
| Loopback | A and B each reached the own endpoint before and after the stop request. Strict zero Direct criterion is not met. |
| Private IPv4 | Neither A nor B loaded the endpoint; independent Python control reached it. The failing B control prevents a selective-blocking conclusion. |
| Owner attribution | Not established. Counter receiver contains a UUID spelling defect; corrected source is compiled/pure-tested, not native-verified. |
| Cleanup | All four QA processes and two servers exited; exact QA VPN configuration removed through System Settings. Controller removal returned AuthorizationRequired13. Later QA-only switch plus Done disabled the extension: both kernel status and daemon transition confirm activated disabled. Inactive registration/bundle remain;not uninstalled. |

Host A's exit was delayed. A PID/path/UID guard refused a fallback signal;
the host then exited without any signal being sent. This is not a fast-close
PASS. The controller's cleanup scope guard also refused; it was preserved.
System Settings removed only the exact named disposable QA configuration.

CUA window binding took1128.984s for A and149.810s for B. The initial HTTP
fixture expired before requests; it was retained as a setup failure. A fresh
fixture started after both existing windows were bound, within the same
approved stage. Apps, rule, provider and old suites were not restarted.
These delays do not establish an application performance measurement.

Detailed redacted evidence: [development report](../../docs/evidence/webkit-network-isolation-development.json).
Private receipts remain in the current checkpoint's `webkit-kernel-native5`.
No personal addresses, URLs, credentials or raw ICE are published.

## Boundary under investigation

A dedicated signed process owns one WebKit profile. An ordinary
`NEAppProxyProvider` system extension receives per-app flows; a full kernel
audit token plus exact Developer ID/CDHash selects an enrolled session.
The manager, an Apple process, a team ID and a UID are insufficient authority.
`NETransparentProxyProvider` is not substituted: rejecting a flow there can
permit an unproxied path. An app rule is not proof of captured WebKit traffic.

```
dedicated profile host -> OS per-app rule -> app proxy provider
                                             | unknown/UDP/revoked: refuse
                                             v
                                      fixed proxy tunnel
```

The diagram is the intended boundary. The concrete tunnel and production
host/IPC integration are not implemented; the native QA provider forwards
nothing. `WKWebsiteDataStore.proxyConfigurations` is not the firewall.
Previous HTTP/default/exact/SOCKS bypass observations remain failures; no
frontend permutations are repeated to manufacture a PASS.

## Implemented source

- Bounded ownership registry: profile generation/session, monotonic leases,
  replay refusal, flow capacity and active cancellation on expiry/revoke.
- `SignedHostPin`: dynamic SecCode validation from a complete kernel audit
  token, exact Developer ID identifier/team/CDHash. Native WebKit attribution
  to this token remains unproved.
- TCP adapter: inert tunnel factory, cancellation before establish, bounded
  writes/backpressure, half-close, lease checks and stop/drain ordering.
  A real authenticated fixed-upstream connector remains an interface.
- Separate QA controller, nonpersistent Host A/B and deny-only provider.
  No automatic navigation, installation or preference mutation on launch.
- Launch/configuration fence across asynchronous callbacks; fresh ownership
  and host-absence checks before cleanup. Counter reads cannot lock cleanup.
- Explicit QA-only navigation scope is a fixture restriction, not a firewall.
- Safe error/refusal diagnostics: no URL, localized error payload, endpoint,
  requirement or stored configuration dump. UUID run comparison uses parsed
  identity and still refuses missing, malformed, different or late runs.

## Tests and frozen evidence

The prior core stage has29 unique pure Swift controls:12 ownership,6 lifecycle,7 scope and
4 new observation identity controls. The latest run executed only the4 new
controls and compiled changed QA targets in5.613s, jobs2/serial/shared cache.
It used real Foundation UUID serialization as a regression control: the old
string comparator rejects the correct run. Missing/malformed/different runs
still refuse. The prior25 controls and shipping release gates were not replayed.

Two packaging defects were separately diagnosed by sysextd after Apple
Accepted: QA1 omitted the provider's purpose string; QA2 omitted its App Group.
The actual immutable old packages fail their focused preflight controls.
QA3 added only provider group `H6VGU2M6JD.app.neantik.desktop.network-qa`.
Five portable Mach-service packaging controls are in `test-prepare-qa.py`;
three prior purpose-string controls are retained in private receipts.
These are packaging checks, not kernel acceptance.

## Distinct hosts and bounded baseline (development)

The old A/B wrappers copied one Mach-O image. They had different signed bundle
IDs but the same executable UUID: an unsuitable independent macOS control.
A and B now build as separate executables; preparation rejects identical,
missing, duplicate or malformed LC_UUIDs. Five new portable controls passed,
including rejection of the actual retained old pair. The changed targets
compiled once in3.363s with the shared cache; previous suites were not replayed.

An optional own-endpoint probe in each headed host emits exactly one redacted
typed observation and exits. `owned-baseline.py` adds a25s outer deadline and
requires the matching signed run/role, HTTP200 and an independent origin event.
It refuses an active QA extension/rule and uses only endpoints it binds itself.
Missing, duplicate, foreign, failed or timed-out observations cannot pass.
No addresses, URLs, error payloads or real profile data enter its report.
This baseline diagnoses the private-IP control before installing a new rule;
even an all-green baseline does not prove isolation or a working proxy.
The exact signed baseline subsequently passed4/4 headed cases in4.189s total:
A/B each loaded the own loopback/privateIPv4 origin and exited normally.
Apple Accepted, both tickets/strict signatures/Gatekeeper passed;no rule was
installed. Own origins/processes are gone and the old extension remains disabled.
[Exact baseline evidence](../../docs/evidence/webkit-owned-baseline-development.json).
The old private-B failure is not root-caused by this result: UUID and active
rule state changed together. No IPv6/DNS/confinement result is inferred.

## Supplemental owned-loopback filter (not activated)

The SDK explicitly excludes loopback from wildcard/default filter rules.
An opt-in QA component now creates exact127/32 and::1/128 filterData rules for
1–4own server ports. It validates the original kernel source-app token against
exact signed A/B pins. A is dropped;B allowed;unknown or unsupported callbacks
allow unrelated traffic and explicitly invalidate the experiment.
This unknown behavior is unsuitable as a production firewall.

The adapter reuses the existing generation-fenced lifetime/FIFO:only successful
current apply publishes configuration;stop waits for pending apply. The QA
controller requires a per-run HMAC proof from both held loopback listeners,
refuses redirects and foreign/stale filter settings, and rereads exact saved
scope. No key is persisted. These are compiled controls;the Swift-to-origin
proof and actual filtering remain native acceptance work.

Preparation requires explicit `--include-owned-loopback-filter`. Default
preparation does not add the new class or content-filter grant. An additional
signed replacement recipe can target only inactive QA3's exact Developer ID
CDHash and build;default/unknown/active replacement still cancels. Neither
preparation nor compilation changes OS settings or signs these grants.
Three new pure scope controls and the ownIPv4/IPv6 HMAC socket control passed.
The current filter/controller compiles without product Sendable diagnostics;
native owner/crash/disable behavior is unqualified.
[Source and remaining gates](../../docs/evidence/webkit-owned-loopback-filter-development.json).

## Accepting the owned-loopback observation

`analyze-owned-filter.py` analyzes retained evidence offline. It requires the
12-case matrix: A/B over IPv4/IPv6 before activation, while filtering, and
after an independently observed provider failure. A must fail without an
origin request; B must actually load the own origin. An active A-drop/B-allow
event must match the request interval and exact provider run, PID and binary.
Missing contexts, timeouts, unknown ownership and unexpected callbacks refuse
completion. A stop callback alone never establishes provider unavailability.

The native collector must bind origin events to the exact run, role, family
and request label. The own server accepts only its per-run path and known
label; snapshots must come from that label's held server. Preserve producer
and receipt hashes when reusing the four completed signed-QA5 baseline cases.
Those older cases contain real origin and headed-completion uptimes, not
launch intervals. The analyzer checks freshness/order without inventing the
missing launch times or rerunning those browsers.

`normalize_journal` accepts the actual macOS JSON field names and matches the
provider image path and parsed Mach-O UUID. It retains unknown/unexpected
events and refuses malformed timestamps or wall-clock/uptime drift. Matching
journal fields does not authenticate collection: the operator still needs an
actual OS capture and verified signed provider/PID. Raw journal text is not a
public artifact.

Nineteen offline controls passed, including intentionally broken lifecycle,
Direct fallback, failed B, stale evidence and foreign identity. They test the
analysis, not the OS filter. Even complete input reports leave
`productionQualified` and `workingProxyProved` false. External destinations,
DNS, UDP, existing connections and the actual proxy tunnel need separate
native evidence before shipping WebKit proxy support.
[Analysis controls and remaining boundaries](../../docs/evidence/webkit-owned-filter-analysis-development.json).

## QA5 installation refusal: bundle readability

The approved QA5 stage stopped before filter activation or new A/B probes.
macOS returned requestCanceled11. The replacement callback requires strict
verification of the inactive old provider. QA3's staged `Contents/MacOS`
directory is root-owned0700; the ordinary controller gets PermissionDenied
when accessing its executable. That independently prevents the signature
check; the exact callback guard branch was not logged. A restricted-context
codesign failure must not be described as missing bytes or unsigned code.

The assembler now normalizes only fresh owned QA bundles before signing:
directories/executables0755 and resources0644. Private output parents and
entitlement templates stay private. It refuses symlinks, hardlinks, missing
executables and foreign ownership before changing modes. Five new controls
pass, and the actual retained QA5 modes are rejected. A separate corrected
QA5 copy has identical file contents; strict signatures and Gatekeeper pass
in the authorized macOS context. No signing, compilation or Apple submission
was repeated. The frozen original and OS staging were not modified.

The legacy root-owned QA3 requires administrator-assisted metadata repair or
supported removal before replacement. Do not weaken signature checks, enable
an unqualified proxy or retry identical activation inputs. Own controller and
origins are closed; QA3 remains disabled and no filter was enabled.
[Result and limits](../../docs/evidence/webkit-qa-bundle-readability-development.json).

## Remaining gates

1. QA extension is durably disabled and all own processes/rules are gone.
   Retain the inactive registration and installed QA3 bytes;uninstallation
   is not claimed. Before a successor, resolve exact QA replacement/removal
   through supported OS authorization;do not bypass SIP/Gatekeeper.
2. The new no-rule A/B reachability baseline is complete. Qualify the new
   owned-loopback filter on exact signed bytes;observe current-run/PID apply
   success and saved scope before launchingA. Old app-proxy permutations do
   not need another run. Unknown attribution or anyDirect invalidates acceptance.
3. Demonstrate full-token WebKit attribution, independent B, zero Direct,
   DNS/UDP/IPv6, provider death/revoke/disconnect/reconnect and ordinary traffic.
4. Integrate production dedicated hosts and authenticated kernel-peer IPC;
   fixed-upstream relay transport with remote DNS/TLS, no stored credentials.
5. Qualify persistence/migrations and the exact signed release candidate.

## Official basis

- [App proxy provider](https://developer.apple.com/documentation/networkextension/neappproxyprovider).
- [Deployment](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment).
- [App Groups entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups): macOS team-prefixed groups and `<group identifier>.<unique name>` Mach naming; actual OS acceptance still required.
- [Local network privacy, TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy): distinct executable UUIDs matter. WKWebView/app-proxy exemptions do not establish the cause of the earlier failed control; no TCC reset or global exception is justified.
- Installed SDK `NEAppProxyProvider.h`, `NEFlowMetaData.h`, `NEAppRule.h` and
  `SystemExtensions.h`; provider semantics do not promise every WK flow is
  captured or correctly attributed. The signature/profile guards are retained.

QA5 internal build5 is now signed with the same certificate/profiles, Apple
Accepted, stapled and Gatekeeper checked. Exact new host bytes passed four
headed ownIPv4/IPv6 baseline cases before any filter. The local QA app bundle
was atomically replaced with QA3 rollback retained;the OS extension is still
inactive QA3. The new content-filter access requires action-time confirmation.
No filter/apply/owner/failure PASS or public release is claimed.
