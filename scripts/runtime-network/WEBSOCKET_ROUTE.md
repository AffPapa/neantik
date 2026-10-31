# WebSocket route and proxy failure

This fixture adds the missing WS/WSS part of major-plan19–20. It does not
repeat HTTP/DNS/WebRTC suites or qualify the manager, WebKit, other platforms,
global routing or a new release.

Two fresh headed sessions use the exact downloaded0.8.23 runtime. The first
intentionally bypasses the own proxy for the two destination ports. The second
uses one fixed HTTP proxy without a DIRECT fallback. Only the separate local
control-page port is bypassed in the protected session.

For each protocol, the page opens a real WebSocket and exchanges an original
nonce payload. The fixture binds each origin peer port to the actual accepted
proxy upstream socket;proxy arguments alone are not route evidence. It then
stops the proxy listener and destroys accepted/tunnel sockets. Existing
protected sockets must close abnormally;new requests must emit error/close
without an origin handshake. The same proxy port is restarted, and both
protocols must exchange the payload again. Direct controls stay open during
the proxy stop and continue to reach the origin.

TLS uses an original one-day certificate and an exact SPKI exception for that
certificate alone. The key lives only in the own temporary root and is deleted
after browser/server shutdown. No global trust store or OS network setting is
changed. This is not a normal-trust HTTPS-upstream test. Every browser uses
`--use-mock-keychain`, a private BrowserData directory, a narrow inherited
environment, an external DNS block and fresh normal memory/thermal admission.

```sh
node scripts/runtime-network/test-websocket-route.mjs
node scripts/runtime-network/test-websocket-fixture-close.mjs
node scripts/runtime-network/run-websocket-route.mjs /absolute/NeAntik\ Browser.app /absolute/binding.json /absolute/new/output bypass-control
node scripts/runtime-network/run-websocket-route.mjs /absolute/NeAntik\ Browser.app /absolute/binding.json /absolute/another/output protected
node scripts/runtime-network/analyze-websocket-route.mjs /absolute/binding.json /absolute/bypass-output /absolute/protected-output
```

The pipe accepts only fixed owned nonce pages;no arbitrary page script or
remote-debugging TCP listener is exposed. Source bytes/hashes are archived
before launch. Offline analysis verifies the source/runtime binding, actual
operations, route evidence, normal main exit, process/socket/listener drain,
root/key retirement and the sensitivity of the verifier.

## Observed result and retained failure

Direct control passed51checks with6actual Direct handshakes. The final
protected run passed47checks with4proxy handshakes,0Direct,2aborted live
tunnels,2refused new connections and2successful recoveries. Eighteen mutations
of the real protected capture are rejected;the real bypass capture is rejected
when relabeled as protected. Normal exit0 and full own cleanup were observed.

The first protected run completed the network operations but failed the
fixture cleanup gate:an upgraded origin socket could remain half-open after
TCP FIN, and server-close callbacks were recorded before all socket-close
handlers. Its FAIL is preserved. Two real own-socket controls reproduced and
verified the FIN/drain correction;only the affected protected browser run was
repeated. The initial passing Direct capture retains its original source;
offline analysis permits only this exact FIN/drain difference and rejects
other source drift. No failed receipt was rewritten.

[Minimized evidence](../../docs/evidence/websocket-route-0.8.23.json).

References:[Chromium proxy mapping](https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md),
[RFC6455](https://www.rfc-editor.org/rfc/rfc6455).
