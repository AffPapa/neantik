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

[QA7 result](../../docs/evidence/webkit-owned-filter-native-development.json)
and [self-control evidence](../../docs/evidence/webkit-selfpin-development.json).
