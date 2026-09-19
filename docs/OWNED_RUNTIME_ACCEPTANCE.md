# Owned runtime acceptance probe

Run only after the selected runtime and matching ChromeDriver have finished
building and the runtime is executable under macOS signing policy. Do not probe
a changing build output and call it evidence for the eventual release.

```sh
python3 scripts/probe-owned-runtime-webdriver.py \
  --headed \
  --runtime-app '/absolute/path/to/NeAntik Browser.app' \
  --driver '/absolute/path/to/chromedriver' \
  --expected-version 153.0.8010.36
```

The runner creates private synthetic profiles under `/private/tmp`, a loopback
HTTP origin and a loopback-only driver. It never accepts an existing user-data
directory. No external detector, proxy account or personal profile is required.
The printed evidence directory retains diagnostic files for inspection; do not
publish raw driver logs. Report hashes, boolean outcomes and scope instead.

## Evidence produced

- Every created WebDriver session must report the exact requested browser version.
- Main executable, framework executable and ChromeDriver hashes are checked
  before and after the full run.
- Separate A/B browser sessions test cookies, localStorage, IndexedDB,
  Cache Storage and service-worker registration. Each observation is also
  repeated after page reload. A returns after B without losing its markers.
- The direct loopback control must reach the local origin. A held non-listening
  loopback HTTP proxy must yield the expected proxy error without reaching it.
- `compatibility-results.json` records secure-context and Permissions API query
  behavior, MediaDevices API presence, a synthetic canvas video track and its
  shutdown, offline audio rendering, Worker messaging and a same-origin iframe.
  No camera/microphone capture or permission grant is requested. API presence
  does not establish real-device media capture, permission-prompt UX or WPT
  conformance. Additional checks download a fixed loopback attachment into the
  fresh private directory and compare its exact bytes, and execute an owned
  unpacked Manifest V3 content script restricted to 127.0.0.1. This does not
  qualify Chrome Web Store installation, extension updates or every extension API.
- `storage-results.json` and `route-results.json` identify the execution mode
  and runtime/driver hashes. A nonzero runner exit invalidates overall acceptance,
  even if an intermediate result file exists.

`--smoke-only` checks startup/title/shutdown, not isolation or route safety.
Headless and headed are separate modes; one does not qualify the other.

## Remaining acceptance gates

This probe does not qualify DNS routing, WebRTC/STUN, QUIC, TLS, fingerprint
coherence, manager launch flags, concurrent manager locking, crash recovery,
extension/media/permission compatibility, or automatic cleanup after a failed
driver shutdown. Inspect remaining owned test processes after an abnormal exit;
never kill arbitrary browsers to clean up a test. Repeat required probes against
the exact final packaged runtime and bind their hashes to release evidence.

WebDriver changes the environment. This is an automated control, not a claim
about ordinary manual browsing or third-party anti-fraud outcomes. Signing,
notarization, archive privacy, published bytes and rollback are separate gates.

## Complementary manager-owned WebRTC gate

The application already has a separate loopback STUN observer in
`FingerprintAuditLoopbackSTUNServer.swift`. `FingerprintAudit.capture` creates
an ephemeral audit reservation and launches through `BrowserProcessManager`;
its report records the local STUN request count. Use the existing signed GUI
fingerprint evidence workflow for that gate rather than treating this WebDriver
runner as equivalent manager evidence.

The release assessment requires a reachable direct STUN control and no STUN
requests in the corresponding proxied observation. A zero count without a
working positive control is not evidence of protection. The `network_route`
field is selected from profile configuration; it is not an independently
measured external egress route. Loopback STUN evidence does not qualify DNS,
QUIC, external egress, or arbitrary proxy implementations.

`verify-chromium-webrtc-policy.py` checks the source-level preference wiring
only. Neither that script nor the existence of the GUI observer constitutes
successful runtime acceptance: run the signed GUI workflow against the final
packaged candidate and retain its version/hash-bound evidence separately.
