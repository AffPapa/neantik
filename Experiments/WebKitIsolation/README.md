# WebKit isolation: development component

**Not installed, not enabled, not browser-qualified.** Shipping NeAntik still
refuses WebKit profiles with a proxy. This package is separate from the manager
and its release build; its build and preparation scripts do not save VPN preferences or install anything. The optional QA controller exposes those operations only through explicit buttons in a separately authorized native stage.

## Chosen boundary

A dedicated signed profile-host process owns one WebKit profile. A macOS
**app proxy system extension** intercepts that host's flows at the OS boundary.
It uses `NEAppProxyProvider`, not `NETransparentProxyProvider`: the latter can
send rejected flows directly. A full kernel audit token plus an exact live
Developer ID/CDHash check selects an already enrolled profile session. The
shared NeAntik manager, an Apple PID, a team ID, and a UID are insufficient.

```
dedicated profile host -> kernel per-app rule -> app proxy provider
                                                | unknown/UDP/revoked: refuse
                                                v
                                 authenticated fixed-proxy tunnel
```

`WKWebsiteDataStore.proxyConfigurations` is not the enforcement boundary.
The prior HTTP/default/exact/SOCKS results are retained; this work does not
repeat them or weaken their criteria.

## Implemented

- `IsolationCore`: bounded ownership, generation/session replay refusal,
  monotonic short leases, exact-token matching, flow admission limits,
  active-flow cancellation on revoke/expiry, and independent profile lifetimes.
- `SignedHostPin`: dynamic `SecCode` lookup by the entire kernel audit token;
  exact Developer ID requirement including identifier, team and CDHash.
- `IsolatedTCPFlowRouter`: real `NEAppProxyTCPFlow` callback adapter, credential-
  free metadata, connect-by-name destination preservation, backpressure,
  half-close, bounded writes, lease checks, native I/O cancellation and drain.
- `FailClosedAppProxyProvider`: missing bootstrap refuses startup; missing or
  unknown ownership/UDP refuses flows. No Direct dialer or fallback branch.
- `NEAppRule` recipe for a dedicated host only; no domain/tool exclusions.
  Constructing a rule does not prove that macOS installed or applied it.

The data plane is an injected `IsolatedProxyTunnel` interface. A real proxy
connector is **not integrated** yet. Its contract requires fixed upstream,
remote DNS, TLS trust validation where applicable, bounded connect/read/write
and cancellation. Its factory must be inert: cancellation is attached before
`establish` starts networking. Credentials must be authorized again when they
are written, not only when the stream object is created. A test connector is not network isolation.

## Checks performed

One scoped build compiled all three NetworkExtension adapter files and ran
12 pure model tests in 6.811 seconds, jobs2/serial. Source review then found
lifecycle/callback races: six focused controls passed in 1.827 seconds after
the fixes, including a deliberately broken callback order. The unchanged 12
ledger tests were not repeated. Seven additional fixture controls passed in 1.306 seconds: strict literal IP parsing (including the former DNS-label bypass), run/scheme/credential scope, pending launch vs cleanup, and stale callbacks. There are 25 unique pure controls; the earlier
five-control lifecycle run is a subset, not five extra tests.

Controls include unknown
owners, PID-incarnation changes, UDP denial, revocation vs independent B,
expiry, heartbeat/session replay, stale generations, flow capacity, clock
rollback, reentrant cancellation and concurrent acquire/revoke.

These tests do not execute NetworkExtension, WebKit, a signed helper or any
network socket. The new package is not yet wired into ordinary CI. The final
test compile retains two Swift Testing callback-macro Sendable warnings and
SwiftPM's native-build deprecation warning; they are not kernel results. They do not establish kernel routing or a working product.

## Remaining integration gates

| Gate | Current status / acceptance |
|---|---|
| Direct signing | Initial65 profiles lacked the grants. Two explicitly approved QA App IDs/profiles are now issued and authenticated by the exact macOS CMS policy; signed-content mutation controls refuse. Same certificate as release135; no new certificate. |
| Packaging | Four fresh QA bundles are now Developer ID signed with exact claims/certificate and strict nested-code verification. Apple notarization and installation are pending. App extensions that require App Store distribution are excluded. |
| OS rule installation | No preferences saved. Verify supported ordinary-Mac setup and reject a design requiring unmanaged users to enroll in MDM. |
| Dedicated host | Existing UI still runs WebKit in the manager. Extract host and authenticated lifecycle/data IPC without changing profile identity. |
| Control authority | No IPC listener exists here. Obtain peer audit tokens from the kernel, validate manager and host separately, bind enrollment to approved profile/scope/revision. Never accept tokens declared by a client. |
| Flow attribution | Real WebKit flow must match that enrolled host token. If macOS attributes it only to a shared Apple process, deny it; do not broaden trust. |
| Proxy connector | Integrate existing reviewed relay transport through a shared module or authenticated control/data channel. Do not duplicate parsers or put credentials in stored VPN configuration. |
| DNS/UDP | TCP connect-by-name carries hostname. UDP is refused by adapter policy, but actual DNS/UDP interception and absence of external DNS are not measured. |
| Kernel failures | Own endpoints must prove zero Direct for local/private/public IPv4/IPv6, provider death/revoke/disconnect/reconnect, startup races, worker/subresource/redirect/WebSocket traffic. Confirm independent B remains usable. |
| Product release | Only after exact signed candidate, persistent-store/lifecycle qualification, migration and Direct release gates. `proxy:false` remains unchanged until then. |

A provider timer reaps expired leases, including idle streams. Provider stop
waits for the adapter's tasks. Connector cancellation and callback completion
still require actual integration checks; a model cannot prove those effects.
App rules must remain installed while a host is alive. Removing them is not a
safe substitute for revoking a session. OS rule behavior when the provider
crashes or is disabled is an explicit gate, not an assumption.

## Official source basis

- [App proxy provider](https://developer.apple.com/documentation/networkextension/neappproxyprovider): flow and high-level DNS/hostname behavior.
- Installed SDK `NEAppProxyProvider.h`, `handleNewFlow`: false terminates an app-proxy flow; transparent-provider false instead uses the unproxied stack.
- Installed SDK `NEFlowMetaData.h`: source-app audit token; not a promise that WebKit attributes every flow to the dedicated host.
- [TN3134 deployment](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment): Developer ID deployment uses a system extension, with required entitlements and user approval.
- [VPN routing](https://developer.apple.com/documentation/networkextension/routing-your-vpn-network-traffic): app rules, routing scope and disconnected-state semantics require actual configuration qualification.

The first implementation deliberately stops before installation. Existing
signed archives, system network settings, certificates, real profiles, cookies
and Keychain are unchanged.

## Prepared kernel probe (not executed)

Three QA executables now compile. `prepare-qa.py` assembles four fresh unsigned
bundles from a matching source/build/binary receipt: controller, dedicated
nonpersistent WebKit Host A, independent Host B and a deny-only system extension.
No process is launched by preparation; no setting, certificate or account is
changed. Existing output, failed-build receipts and symlink receipts refuse
assembly; the old output remained byte-identical in three negative controls.

The controller has no WebKit view. Its app rule targets only the exact signed
Host A and refuses non-source-application routing, global network inclusion,
domain exceptions or a stale host hash. Configuration is reread before use.
Installation, preference save, starting/stopping the provider, and cleanup are
separate visible buttons; none runs on app launch. Replacement of an existing
system extension is refused. Cleanup refuses live QA Hosts and targets only
this QA configuration/extension. A shared operation fence blocks launching while
preferences/extension requests are pending, counts unfinished host launches, and
rechecks host absence immediately before each mutation. Late operation callbacks
cannot unlock a newer operation. Counter observations do not hold that fence:
a dead provider cannot block cleanup. These guards are compiled and their pure
state transitions tested; the controller UI is not native-tested.

Host A/B start blank and use nonpersistent stores. Navigation is restricted to
explicit loopback/private HTTP endpoints with this preparation's QA run path.
This navigation restriction is a fixture constraint, **not** the network
firewall or proof that subresources cannot bypass a proxy.

The first new native stage must establish actual app-rule capture, full-token
attribution and disconnected/provider-stop behavior with own origin counters,
including independent B. The deny provider forwards nothing. Its counters
alone cannot prove absence of Direct, DNS or UDP. A PASS there would establish
an architecture gate, not a working authenticated proxy data plane.

Current bundle names/IDs are confined to `app.neantik.desktop.network-qa`,
its `.proxy`, `.profilehost` and `.control` descendants. Only the container
and `.proxy` need the two new restricted Developer ID profiles. Existing
Developer ID signing certificate is retained. Do not launch unsigned bundles,
disable Gatekeeper, use ad-hoc entitlement workarounds or install this probe
before explicit QA-install consent and fresh native admission.


The source review's two QA defects (DNS labels treated as IP octets and launch/
cleanup overlap) are fixed. A first scope-test compile failed because Swift
Testing expands mutating struct calls on immutable macro temporaries; the
harness now evaluates those calls before assertions. Original failure receipts
are retained. No native or release test was replayed for these source changes.
The final controller-only build passed in 1.596 seconds after making absent
provider observations nonblocking. The seven controls were not rerun for that
observation-only change.

After exact approval, the two QA App IDs and Developer ID profiles were issued.
Both profiles authenticate with Apple's exact macOS provisioning signing policy;
two altered signed payloads refuse. The selected portal certificate's public
DER matches the exact leaf of release135. Four fresh QA bundles are now signed
with the same certificate, hardened runtime and exact restricted claims, with
strict nested verification. No Keychain groups or production identity were added.

The private Apple submission ZIP contains only14 allowlisted files and is609958
bytes. Its SHA256 is `e59014677ac6493e72528e1e498dbe824b8b56f35337664cd64cc45fb7343fa9`.
It has not been notarized, installed or launched. Automatic review rejected the
Apple submission before execution because the two-ID/profile approval did not
cover that exact code upload. A separate scoped notarization/installed-QA request
is pending. No submission workaround, new certificate or app rebuild was used.
These signing results do not establish kernel capture or a working proxy.


## First installed attempt: packaging refusal, corrected recipe

The first exact QA ZIP received Apple Accepted, was stapled and passed
Gatekeeper. One controller launch and one extension activation were attempted.
`sysextd` refused category validation: the network extension itself lacked
`NSSystemExtensionUsageDescription` (the container already had it). This is a
packaging defect, not a proxy failure or missing account/certificate permission.
Other DEXT/Endpoint Security category-probe messages do not justify new rights.

Host A/B were not opened and no app rule was saved. Own origins stopped,
the controller exited and no QA extension remained. Zero A requests in that
state is not network-isolation PASS. The installed QA copy was retired intact;
the original accepted ZIP and its receipts remain immutable.

The preparation recipe now requires a bounded nonempty purpose string on both
container and provider. Three pure metadata controls passed, including refusal
of the actual old provider Info.plist. New internal QA build2 changes only
purpose/version/run metadata: all four compiled executables and both entitlement
templates before signing are byte-identical to build1. No Swift/Chromium build
or old25 controls were repeated. This corrected QA still needs its own exact
signing/notarization/install acceptance; shipping WebKit proxy remains disabled.
