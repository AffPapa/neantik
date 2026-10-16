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

There are29 unique pure Swift controls:12 ownership,6 lifecycle,7 scope and
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

## Remaining gates

1. QA extension is durably disabled and all own processes/rules are gone.
   Retain the inactive registration and installed QA3 bytes;uninstallation
   is not claimed. Before a successor, resolve exact QA replacement/removal
   through supported OS authorization;do not bypass SIP/Gatekeeper.
2. Explain private-IP A/B failure with safe typed errors and correct controls;
   establish supported loopback policy before another native attempt. Current
   results prohibit production enablement and do not justify blind retries.
3. Demonstrate full-token WebKit attribution, independent B, zero Direct,
   DNS/UDP/IPv6, provider death/revoke/disconnect/reconnect and ordinary traffic.
4. Integrate production dedicated hosts and authenticated kernel-peer IPC;
   fixed-upstream relay transport with remote DNS/TLS, no stored credentials.
5. Qualify persistence/migrations and the exact signed release candidate.

## Official basis

- [App proxy provider](https://developer.apple.com/documentation/networkextension/neappproxyprovider).
- [Deployment](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment).
- [App Groups entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups): macOS team-prefixed groups and `<group identifier>.<unique name>` Mach naming; actual OS acceptance still required.
- Installed SDK `NEAppProxyProvider.h`, `NEFlowMetaData.h`, `NEAppRule.h` and
  `SystemExtensions.h`; provider semantics do not promise every WK flow is
  captured or correctly attributed. The signature/profile guards are retained.
