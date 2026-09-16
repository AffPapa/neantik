# CPA.RIP checker review — 2026-09-15

## Scope

CPA.RIP tested NeAntik 0.5.3 (33), while this review targets the 0.6.4 (46)
source and Chromium 152.0.7977.82. A result from Whoer, PixelScan, Iphey, or
another opaque checker is treated as a regression lead. It is not accepted as
proof that a profile is secure or unsafe without a reproduced invariant.

Article: <https://cpa.rip/services/neantik/>

## Reproduced findings

The fresh local browser-mode A → B → A audit of the previously packaged 0.6.3
runtime found stable repeated Canvas, OfflineAudio, WebGL pixel, ClientRects,
main/worker WebGL shader, User-Agent, Client Hints, locale, timezone, hardware,
and device-tuple values. Profile A remained stable and profile B remained
distinct.

The one reproduced strict context failure was:

```text
css_screen_match = width:0|height:0|resolution:1
```

`screen.width` and `screen.height` used the immutable profile device tuple,
while CSS `device-width` and `device-height` still used host display geometry.
The runtime now routes both APIs through the same reviewed profile tuple.

## Changes

- CSS device geometry and the Screen API use one profile tuple.
- Canvas readback and encoded output use one deterministic transform domain.
- OfflineAudio preserves exact digital silence.
- Release evidence includes allowlisted strict-failure identifiers without
  measured values, profile metadata, URLs, addresses, endpoints, or secrets.
- Extension inspection reads Chromium's actual `Default/Extensions` path.
- UI wording uses “Настроено” until network behavior has been measured.

## Profile separation

Every profile has its own UUID, identity seed, `Profiles/<uuid>/BrowserData`
directory, cookies, cache, storage, tabs, extensions, process lease, and exact
`--user-data-dir`. Launch policy rejects an unsafe data path and prevents two
managers from opening the same profile concurrently.

## What the checker screenshots do not prove

Chromium intentionally reduces the legacy User-Agent to a value such as
`Chrome/152.0.0.0`; the real major/full version is exposed through User-Agent
Client Hints. Replacing the reduced value with a fabricated full version would
create another inconsistency. The release audit therefore verifies UA and
Client Hints together against the exact embedded runtime.

A green or red third-party score can change independently of NeAntik. Release
qualification instead requires an exact signed binary, stable repeated reads,
main/worker agreement, A → B → A separation, CSS/Screen agreement, controlled
WebRTC behavior for the declared route, and immutable executable/framework
hashes. Effective public HTTP and DNS egress still requires an explicit network
observation and is never inferred from launch flags.

## Primary references

- Chromium User-Agent reduction and Client Hints:
  <https://chromium.googlesource.com/chromium/src/+/main/docs/user_agent/README.md>
- Chromium user-data directory contract:
  <https://chromium.googlesource.com/chromium/src/+/HEAD/docs/user_data_dir.md>
- Chromium WebRTC IP handling policy:
  <https://chromium.googlesource.com/chromium/src/+/a5b78cff0b05cf466a7fc35c8fddfb1dc56c2bd9/content/public/common/webrtc_ip_handling_policy.h>
- W3C fingerprinting guidance:
  <https://www.w3.org/TR/fingerprinting-guidance/>
- PixelScan checker changelog, including false-positive fixes:
  <https://pixelscan.net/changelog>
