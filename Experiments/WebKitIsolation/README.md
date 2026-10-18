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

## QA5 setup: supported container lifecycle

The QA5 stage stopped before filter activation or new A/B probes. macOS
returned requestCanceled11. The old-signature guard could not read the
OS-managed provider copy. Administrator inspection confirmed directory0700
and file0604 with the expected old digest/signature. Attempts to repair those
permissions, including rollback, were refused by macOS before an observed
mode change. The permission-repair helper is retired. Do not modify protected
staging, disable SIP or interpret synthetic tests as permission to do so.

The assembler's0755/0644 rule remains a conventional fresh-bundle packaging
check. It does not control OS staging permissions or solve this lifecycle gate.
The earlier administrator-repair recommendation is withdrawn.

The OS registration referred to the original containing app by file identity.
That object had been renamed into a rollback folder while another QA5 copy
occupied its old path. Removing the newer copy therefore did not uninstall
QA3. After the original object was returned to its canonical Applications
location, Finder showed the system-extension removal warning. The resulting
OS state is **terminated waiting to uninstall on reboot**. It is stopped,
not fully uninstalled. The signed QA3 archive/copy remains preserved.

Frozen QA5 was restored with identical signed file bytes. On2026-10-18 the
user rebooted; the old QA3 registration was confirmed absent. No rebuild,
re-signing or Apple submission was needed. Four new pre-filter A/B controls
passed on IPv4/IPv6 because reboot invalidated the prior uptime epoch.

The exact QA5 provider then installed and applied its own loopback scope.
Actual PID/executable hash/signature/run and OS journal were bound. All four
new socket flows reached the provider, but all were classified **unknown**;
both A requests reached the origin directly, as did independent B. Therefore
selective confinement **failed**. The current binary hides whether the app
audit token was missing or dynamic guest/signature validation failed; this
result does not identify that deeper cause. Provider-unavailable checks were
skipped after this prerequisite failure, rather than spending another run on
an already disqualified mechanism.

Cleanup readback confirmed the own filter absent, both listeners closed,
provider exited and QA5 **activated disabled** (not uninstalled). The own
controller required PID-bound termination because its Quit shortcut/menu did
not exit. No working profiles, Keychain or other extensions were changed.
[Native result and limits](../../docs/evidence/webkit-owned-filter-native-development.json).
The historical [lifecycle correction](../../docs/evidence/webkit-qa-bundle-readability-development.json)
remains valid; protected staging repair stays retired.

## Launch Services diagnostic boundary

Two read-only samples of the owned direct/Launch Services hosts completed,
but the system profiler exposed no Responsible field. Their parent process
relationship is not a substitute for original-app network attribution. No
more profiler/root/private-API permutations are justified by these samples.

`open -W` is the launcher, not the host process. Its zero exit code cannot
establish normal host exit. The earlier Launch Services baseline proves
reachability and observed host termination only. The prepared comparison now
records launcherExitCode separately, hostExitCode:null and
normalHostExitVerified:false. It cannot pass the generic full-acceptance
analyser's exitCode:0 condition. Installed kqueue(2) documents NOTE_EXITSTATUS
only for child processes; a Launch Services host is not this fixture's child.
Exact production lifecycle qualification still needs its own supported evidence.

## Launch Services active comparison — 18 October

The approved two-request comparison on the unchanged signed QA5 completed.
The actual provider successfully applied before both IPv4 A/B requests and
its PID, executable hash, signature, run and journal image were bound. Both
requests reached the owned origin with HTTP200; both flows were unknown-owner
allows. Launch Services therefore did not resolve the observed failure.
No unavailable-provider matrix or same-byte replay is justified by this result.

The own filter was removed and read back absent, QA5 is activated disabled,
and all owned host/controller/provider processes and listeners exited.
An AX read after closing the controller reopened an empty controller; it was
closed immediately without saving settings. Future cleanup observes PID exit
without querying an exited app binding. Host normal exit remains unmeasured
for Launch Services; launcher exit0 is not substituted for it.

## QA6 diagnostic result — 18 October

Apple accepted the distinct signed QA6 with unchanged certificate/grants.
Replacement5→6 used the supported framework and preserved the canonical
container inode;oldQA5 is inactive pending eventual OS reboot cleanup.
Fresh baseline A/B2 and active A/B2 used Launch Services. The provider's actual
apply/PID/code/UUID/run and active-flow intervals were bound. Both active
requests reached the origin. Full tokens parsed and guest lookup succeeded,
but each full expected A/B signature requirement failed with−67050. Static
validation of the same formulas passes ownA/B and rejects both crosspins.
This narrows the gate;it does not establish the actual original-app identity.

Ownfilter removal/readback, QA6disable, six PID exits and listener cleanup
were verified. The new Quit menu worked;no post-quit AX reactivation occurred.
No new same-byte native replay or production proxy enable is justified.

### QA7 preparation

Expected-clause diagnostics now compile in a separate development candidate.
After both original full ownership checks reject, they report only fixed
labels and signed OSStatus values for the expected Apple anchor, Developer ID,
team, identifier and CDHash, plus full/integrity checks. No actual identity,
path, token or signing metadata is exported. A later diagnostic match never
revises the original verdict. The longest possible event is395bytes, below
the existing512-byte journal limit.

The incremental experimental build and two affected Swift replacement tests
passed;two Python packaging controls passed. The reviewed inactive6→7 recipe
retains the prior signature/hash and disabled-state checks. This is preparation,
not native evidence. QA6 approval is consumed;QA7 Apple submission and one
bounded native stage require their own concrete authorization.

## Remaining gates

1. QA7 distinguishes the clauses:guest integrity/Apple anchor succeed,but
   expected Developer ID/team/identifier/CDHash fail. Establish a supported
   original-app attribution path from source before another candidate.
   Do not substitute creating-process tokens, shared WebKit helpers or a team
   match for original-app ownership. Apple distinguishes the
   [source application](https://developer.apple.com/documentation/networkextension/nefilterflow/sourceappaudittoken)
   from the [creating process](https://developer.apple.com/documentation/networkextension/nefilterflow/sourceprocessaudittoken).
   QA6 and QA7 archives remain unchanged. No production runtime fix is claimed.
2. Resolve the observed attribution defect before another confinement matrix.
   Reuse baseline/sign/notary evidence only for matching inputs and epoch;
   the unchanged QA5 active matrix must not be replayed. Unknown attribution
   or any Direct invalidates acceptance.
3. Demonstrate full-token WebKit attribution, independent B, zero Direct,
   DNS/UDP/IPv6, provider death/revoke/disconnect/reconnect and ordinary traffic.
4. Integrate production dedicated hosts and authenticated kernel-peer IPC;
   fixed-upstream relay transport with remote DNS/TLS, no stored credentials.
5. Qualify persistence/migrations and the exact signed release candidate.

## QA7 diagnostic result — 18 October

The separately approved exact QA7 was accepted by Apple, stapled and passed
Gatekeeper. Its inactive6→7 replacement preserved the canonical container
inode and a copied rollback. Two baseline and two active A/B requests used
Launch Services;all reached the own origin. The applied provider was bound to
its actual executable hash, PID, Mach-O UUID, run and measured intervals.

For both measured flows, dynamic guest integrity and the generic Apple anchor
passed. Developer ID, the expected QA team, identifier and CDHash all failed
with−67050 against both A/B pins. Thus this is not merely a damaged signature:
the resolved guest does not satisfy the expected QA identity. Its actual
identity was not collected;the result alone does not prove which Apple code
or delegation path was responsible. Partial matches still grant no ownership.
Do not accept a shared Apple helper, weaken the requirement or replay QA7.

The ownfilter was removed/read back absent;QA7 is activated disabled, six own
PIDs and the own listeners are gone. The by-application Settings sheet showed
off while the kernel still reported enabled. Fresh Settings alone did not fix
that discrepancy. The by-category Network Extensions sheet displayed the
actual on switch;only QA was switched off there and kernel state verified.
Tailscale/OBS were unchanged. The first journal read omitted`--info`;its empty
capture is retained and only journal collection was corrected. No browser
replay occurred. A report wrapper's incorrect key was also fixed offline.

Next establish a supported original-app/profile attribution path from source
before proposing another native candidate. These diagnostics do not qualify
production WebKit proxying. [Minimized result](../../docs/evidence/webkit-owned-filter-native-development.json).

## Official basis

- [App proxy provider](https://developer.apple.com/documentation/networkextension/neappproxyprovider).
- [Deployment](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment).
- [App Groups entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups): macOS team-prefixed groups and `<group identifier>.<unique name>` Mach naming; actual OS acceptance still required.
- [Local network privacy, TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy): distinct executable UUIDs matter. WKWebView/app-proxy exemptions do not establish the cause of the earlier failed control; no TCC reset or global exception is justified.
- Installed SDK `NEAppProxyProvider.h`, `NEFlowMetaData.h`, `NEAppRule.h` and
  `SystemExtensions.h`; provider semantics do not promise every WK flow is
  captured or correctly attributed. The signature/profile guards are retained.
