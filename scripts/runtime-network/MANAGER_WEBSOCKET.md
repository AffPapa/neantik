# Manager and authenticated relay: WebSocket integration

The bounded headed manager/relay WS observation passed on downloaded0.8.23.
[Measured result and limits](../../docs/evidence/manager-websocket-0.8.23.json).
This does not complete browser/global network qualification. The raw-runtime
WS/WSS pair is retained separately in [WEBSOCKET_ROUTE.md](WEBSOCKET_ROUTE.md).

This new mode uses an ordinary headed manager page, the real profile lease and
the authenticated local relay. It does not use CDP or change browser flags.
Only synthetic profiles, public dummy proxy credentials and the existing audit
manager's memory-only password backend are used.

The fixed page opens one WS connection and exchanges an original nonce payload.
The fixture then cuts both sockets of that WS tunnel and returns502 to new
WS CONNECT requests. The separate HTTP control page remains reachable. A new
connection must fail without a WebSocket handshake at the origin. Restoring
the same proxy endpoint must allow an echo in the same browser/relay session.
The second, independent Direct profile must continue to echo during that fault.

This is a **WS-specific CONNECT failure**, not physical listener loss. The
existing physical-TCP scenario covers a separate listener failure. WSS success
is still open: the manager has no test-SPKI override, so a normally trusted
owned endpoint is needed. Do not weaken TLS validation to make this test pass.

```sh
python3 -B scripts/runtime-network/manager-route-fixture.py \
  --app /absolute/NeAntik.app --candidate-manifest /absolute/new/candidate-manifest.json \
  --output /absolute/new/receipts --duration 900 --manager-websocket
```

After fresh resource admission and isolated enrollment, configure only
`QA route proxy` through the owned audit window. Capture `before-launch`, start
that profile and wait for its normal page to finish. Capture `proxy-success`.
Start `QA route direct`, wait for its completion, capture `direct-control`.

```sh
python3 -B scripts/runtime-network/collect-manager-websocket.py \
  --state /absolute/receipts/private-state.json --phase before-launch
```

The collector accepts `before-launch`, `proxy-success`, `direct-control` and
`cleanup`. Actual accepted origin peer ports are linked to proxy upstream
sockets; each proxy-facing client is bound to the live signed relay process.
Direct sockets are bound to the actual signed browser/helper chain. The offline
analyzer rejects another profile, generation, configuration, runtime, route,
missing echo, incomplete page, missing normal exit or unsettled cleanup.

Stop both profiles through the owned manager, then Quit. After fixture shutdown,
capture `cleanup` and retire only this temporary QA authority through the
existing narrow operation. Analyze the same immutable receipts:

```sh
python3 -B scripts/runtime-network/analyze-manager-websocket.py \
  --receipts /absolute/receipts --release /absolute/repo/releases/v0.8.23.json
```

Socket tests and modeled negative controls only qualify the harness. They do
not establish manager behavior, WSS, WebKit, global networking or release gates.

The actual manager observation adds five origin handshakes:two through the
authenticated relay and three independent Direct controls. Protected mid-session
cut, new connection refusal and same-session recovery passed. Both browser main
processes exited normally/status0;the fixture exited0, servers/processes drained,
and its temporary authority was retired. Seventeen mutations of the actual
capture were refused without rerunning browsers. The first CLI analysis used a
private-only reader on the public release JSON;that retained harness failure was
fixed offline, without changing native acceptance. Synthetic private data/logs
remain retained as evidence. No product binary was rebuilt or released.
