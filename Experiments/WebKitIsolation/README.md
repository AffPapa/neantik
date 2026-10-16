# WebKit isolation: development component

**Not installed, not enabled, not browser-qualified.** Shipping NeAntik still
refuses WebKit profiles with a proxy. This package is separate from the manager
and its release build; it does not save VPN preferences or install anything.

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
ledger tests were not repeated. There are 18 unique controls; the earlier
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
| Direct signing | 65 existing NeAntik/team profiles decoded; none grants app-proxy-systemextension or system-extension.install. Reuse existing certificate; obtain appropriate Developer ID profiles. |
| Packaging | Signed system extension and containing QA app/host not built. App extensions that require App Store distribution are excluded. |
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
