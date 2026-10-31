# Original-app attribution: source and dynamic control

Status, 18 October 2026: unresolved for the measured WebKit flows. Production proxy
launch remains refused. This investigation is not a working network feature.

## What the new control proves

`IsolationQASelfPin` uses the same unchanged `SignedHostPin` as QA7. A separate
local executable was signed with the existing Developer ID, without any
entitlements. Under normal memory/thermal admission it obtained only its own
kernel token using public `task_info(TASK_AUDIT_TOKEN)`.

The full dynamic requirement passed, all seven expected-clause statuses were 0,
and full-token equality was preserved. Wrong identifier and wrong CDHash were
both refused. The process exited 0. No browser, network, extension, other
process, user profile or Keychain secret was inspected. No token or actual
guest identity was exported. Build-only preparation took 1.80 seconds.

This validates this use of the Security API in the own-process context. It
does not qualify the provider sandbox/delegated-flow context. QA7's two flows
still resolve to an integrity-valid Apple-anchored guest that fails the
expected QA identity; the actual guest identity was not collected.

## Primary source trace

Reviewed upstream WebKit commit
`d22fe75a1b10a54d034da33bf2174cff9814639b`:

- [`NetworkProcessCocoa.mm`](https://github.com/WebKit/WebKit/blob/d22fe75a1b10a54d034da33bf2174cff9814639b/Source/WebKit/NetworkProcess/cocoa/NetworkProcessCocoa.mm#L184)
  obtains source application audit data from its parent IPC connection, behind
  a build capability. The same file contains content-filter delegation.
- [`NetworkSessionCocoa.mm`](https://github.com/WebKit/WebKit/blob/d22fe75a1b10a54d034da33bf2174cff9814639b/Source/WebKit/NetworkProcess/cocoa/NetworkSessionCocoa.mm#L1197)
  assigns that data to session configuration. A nonempty source bundle
  override clears the token there.
- [`WebsiteDataStoreCocoa.mm`](https://github.com/WebKit/WebKit/blob/d22fe75a1b10a54d034da33bf2174cff9814639b/Source/WebKit/UIProcess/WebsiteData/Cocoa/WebsiteDataStoreCocoa.mm#L227)
  carries the source override from data-store configuration. Our QA host uses
  public nonpersistent configuration and does not set this override.
- [`PlatformUse.h`](https://github.com/WebKit/WebKit/blob/d22fe75a1b10a54d034da33bf2174cff9814639b/Source/WTF/wtf/PlatformUse.h#L236)
  gates this audit-data capability on macOS for Apple's internal WebKit build.
  This describes how WebKit is built; it does not mean our embedding app needs
  Apple's private SDK.

Installed system WebKit metadata is 22625.1.29.11.24; public SDK is macOS 27.0.
The reviewed upstream commit is not proven to match that system binary.
The trace therefore identifies a real forwarding path, not the cause of QA7.

## Rejected shortcuts

The installed public SDK documents that `NEAppRule.matchTools = nil` already
includes helper processes spawned by the matching app. Adding a helper list
would restrict that rule; it is not evidence of an attribution fix. The
source-app identifier/unique-ID and `NEFilterBrowserFlow` APIs are unavailable on
macOS. Do not call private equivalents or replace ownership with a shared
Apple helper, UID, team or creating-process token.

`Network/proxy_config.h` documents host endpoints for HTTP CONNECT and SOCKS5.
Its Swift initializer taking `NWEndpoint` does not establish support for a Unix
socket proxy. No Unix-socket browser experiment was launched. The existing
`allowFailover = false` and empty domain sets do not invalidate the already
observed literal/private-address bypasses.

## Next decision

Establish a supported, authenticated link between the original profile host
and each delegated flow before changing the provider or proposing a new
native candidate. Investigate the provider context and system forwarding
path; do not repeat QA7 or request broader grants to compensate for a missing
ownership proof. If the system boundary cannot supply that proof, select an
explicit different architecture rather than label this implementation ready.

## Additional supported APIs reviewed on 18 October 2026

The public macOS27 SDK and current Apple documentation distinguish three
different facts:

| API | What it identifies | Boundary |
|---|---|---|
| `NEFilterFlow.sourceAppAuditToken` | Source application reported for a content-filter flow | QA7's supplemental content-filter provider read this token; both signed QA identities failed their expected requirement. |
| `NEFilterFlow.sourceProcessAuditToken` | Process that actually created the connection | It may be a system process acting for an app. Switching to it does not establish the original profile owner. Available from macOS13. |
| `es_process_t.responsible_audit_token` | Process responsible for the process described by an Endpoint Security message | Valid only at message version4 or later. It can refer to the process itself when no responsible process exists or that process has exited. Not a guaranteed WebKit host link. |

Sources: [flow creator](https://developer.apple.com/documentation/networkextension/nefilterflow/sourceprocessaudittoken),
[responsible token](https://developer.apple.com/documentation/endpointsecurity/es_process_t/responsible_audit_token).
QA7 packaged both `NEAppProxyProvider` and the explicitly enabled supplemental
`NEFilterDataProvider`. The measured A/B Direct reaches and expected-clause rows
belong to the filter path: it read `NEFilterFlow.sourceAppAuditToken`, failed
the expected QA identity checks, then allowed the scoped flow while reporting
unknown ownership. The separate App Proxy class reads
`NEAppProxyFlow.metaData.sourceAppAuditToken` and returns `false` for every
captured flow, but the retained report does not establish that it captured the
measured requests. Do not attribute the filter's Direct result to App Proxy.
The test used system WebKit and did not test our app-owned Networking helper or
a transparent proxy. See the
[classification correction](../../docs/evidence/webkit-qa7-provider-classification-correction-20261020.json).

### A scoped alternative exists,with unresolved coverage

[`es_new_descendants_client`](https://developer.apple.com/documentation/endpointsecurity/es_new_descendants_client(_:_:))
is a macOS27 API for the caller's process subtree. It does not require root or
TCC approval,unlike the traditional system-wide client. It still requires the
Endpoint Security entitlement,[which Apple must approve](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.endpoint-security.client).
There is no authorized or proven ES capability in this investigation.

The installed SDK describes future fork/exec descendants;current Apple pages
also describe existing descendants. This difference is retained. A future test
must establish the client before launching its own hosts and may not depend on
existing-helper enumeration. Neither version proves that launchd-created
WebKit XPC services are visible or carry the expected responsible-host token.
The API also does not cover NeAntik's supported macOS14–26 range.

The declaration-only [fixture](APIChecks/attribution-declarations.m) typechecked
against SDK27 with a macOS14 target. Removing the27 availability guard produced
the expected compiler error. No executable was linked or run,no ES client was
created,and no entitlement,TCC setting,certificate or profile changed.
[Static result](../../docs/evidence/webkit-attribution-api-development.json).

### Decision before any new native candidate

Do not request Full Disk Access or a system-wide ES observer as a speculative
fix,and do not create QA8 by replacing one token property with another. The
next independent architecture gate is a supported flow-to-profile proof:

1. Establish which own host and process generation represents each profile.
   A shared manager identity alone cannot distinguish its WebKit profiles.
2. If evaluating scoped ES later,first obtain an explicitly approved QA
   entitlement and prove its descendant/XPC visibility using own hosts only.
   Verify message versions,full audit-token identity and existing code pins.
3. Establish the mapping before allowing any profile traffic;test missing,
   late,stale and lost-observer cases without blocking unrelated applications.
4. Only then consider provider integration and a new bounded network test.

An ES field,successful typecheck or modeled event cache is not that proof.
Production WebKit proxy remains refused;no root-wide monitoring path was added.

[QA7 result](../../docs/evidence/webkit-owned-filter-native-development.json)
and [self-control evidence](../../docs/evidence/webkit-selfpin-development.json).

### macOS 27 SDK confirmation (20 October 2026)

The current selected SDK headers reconfirm the boundary with exact local hashes:
`NEFilterFlow.h` SHA-256 `ce36c704ca2c983ffb22bec1ab417bf7ea2433d4bcca99b2bc231b7f739dd4c7`
and `NEFilterProviderConfiguration.h` SHA-256
`6cd55e64b14fca6da3cab305968b4654d1aab30d40d5fbea9f6fff01a25423af`.
`sourceAppIdentifier`, `sourceAppUniqueIdentifier`, and `NEFilterBrowserFlow`
are unavailable on macOS; `filterBrowsers` is explicitly unsupported there.
Current Apple web pages list these symbols without surfacing that platform
boundary in the short summaries, so use the SDK availability annotations. This
confirms the existing no-retry decision; no native test, entitlement, filter,
or profile change is warranted. [Receipt](../../docs/evidence/webkit-filter-browser-api-macos-check-20261020.json).

### App-proxy helper-matching research (20 October 2026)

The public macOS SDK documents a rule refinement QA7 did not exercise:
`NEAppRule.matchTools` can restrict an app rule to named helper processes.
QA7 used `matchTools = nil`, which includes the app and all its helpers. The current
WebKit namespace configure receipt identifies the app-owned Networking helper
as `app.neantik.desktop.webkit.Networking` (the executable suffix varies by
build). This makes a precise app-proxy rule for a dedicated profile host and
its signed Networking helper worth testing with an app-owned runtime. QA7's
App Proxy was packaged beside the supplemental content filter; the retained
evidence does not prove the app-proxy class captured the measured request, and
system WebKit does not prove helper-token attribution. Apple
also documents App Proxy configurations through
managed app-layer configuration profiles and macOS per-app rules for
MDM-managed apps. Ordinary self-service enrollment for NeAntik is unproven,
so this is a platform deployment gate, not an implementation detail.

Upstream Cocoa WebKit adds a process-scope constraint:
`NetworkProcessProxy::defaultNetworkProcess()` is a process-local static
singleton and `ensureDefaultNetworkProcess()` reuses it. Multiple
`WebsiteDataStore`s in one host process therefore share a NetworkProcess. The
planned one-profile-per-host boundary can isolate that helper instance only if
manager launch and store ownership enforce it.

Do not change the shipping rule or accept helper tokens yet. The remaining
proof is an exact signed runtime showing (1) app-proxy `matchTools` captures its
Networking helper, (2) the complete kernel flow token validates against that
helper's pinned Developer ID/CDHash, (3) an authenticated host lease maps that
instance to exactly one profile, and (4) unrelated tools, missing/revoked
leases, relay loss, DNS/IPv4/IPv6/UDP/WebSocket and restart fail closed. The
The app-proxy/system-WebKit attribution failure does not establish how a
custom app-owned Networking helper will appear to the provider. No custom
helper flow was tested. Per-App App Proxy is documented as MDM-only, so it is
not the ordinary-user product route.
See the [source review receipt](../../docs/evidence/webkit-app-proxy-matchtools-review-20261020.json).

### Transparent-proxy route for direct distribution (20 October 2026)

Apple's deployment matrix permits a macOS `NETransparentProxyProvider` packaged
as a system extension for Developer ID distribution. Unlike per-app App Proxy,
its configuration is not documented as MDM-only. Its network rules are global,
not per-app: they match network attributes rather than bundle IDs. A protected
flow must be identified from system-supplied flow metadata and a full audit
token; unrelated flows can pass through, but a protected flow with missing or
revoked authority must be claimed and explicitly closed. Returning `false` is a
direct path for this provider.

This route remains unproven for NeAntik. The app-owned WebKit Networking helper
has a distinct signed identifier, but no exact flow has shown that the
transparent provider reports that helper's token. If metadata is absent or
misattributed, returning `false` risks the known bypass; failing closed for all
unknown traffic would break unrelated applications. Transparent proxy settings
also do not configure DNS/proxy settings, and DNS matching has separate rule
constraints. A controlled test must establish exact helper attribution,
claim-and-close behavior, DNS, unrelated-app pass-through, IPv4/IPv6, UDP,
WebSocket, relay-loss handling, and recovery without altering global user
network settings. No provider was installed, configured or tested here. See
the [source review receipt](../../docs/evidence/webkit-transparent-proxy-candidate-20261020.json).
