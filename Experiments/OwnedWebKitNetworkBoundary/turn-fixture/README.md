# Loopback TURN control

This development fixture accepts authenticated TURN over TCP or TLS on an ephemeral
`127.0.0.1` port. Relay endpoints are UDP on the same loopback address. The
server refuses permission for other peer addresses and does not implement the
TCP relay allocation or outbound TCP dial from RFC 6062.

Use Go 1.24 or later. The fixture uses Pion TURN v5.1.3 under MIT, pinned with
the module checksums in `go.sum`. See the [tagged source](https://github.com/pion/turn/tree/v5.1.3)
and [license](https://github.com/pion/turn/blob/v5.1.3/LICENSE).

```sh
go mod verify
go test -mod=readonly -p 1 ./...
qa_root=$(mktemp -d /private/tmp/neantik-turn-control.XXXXXX)
go build -mod=readonly -p 1 -o "$qa_root/turn-control" .
"$qa_root/turn-control" -ready-file "$qa_root/ready.json"
```

Start the binary with `-ready-file` pointing to a new file inside a disposable
directory with mode 0700. Wait for the stdout event `{"status":"ready"}` before
reading the handoff. Only the owner can read the synthetic credential. Stop
the fixture with SIGTERM. It removes the handoff and emits the allocation
count. Keep the handoff and credential out of receipts.

The control test rejects a wrong credential and a non-loopback peer. It also
allocates two distinct relay sockets and delivers a random nonce between them.
To qualify a browser profile, additionally correlate its CONNECT at the
assigned broker with the fixture's allocation count, the browser DataChannel
nonce and the direct-route canaries. A browser candidate does not prove TURN
traffic by exposing a relay address.

For a separate TURN/TLS run, pass `-tls-cert chain.pem -tls-key leaf.key`.
Both files must be mode 0600 in the owner-only ready-file directory.
The PEM chain starts with the server certificate followed by its intermediates.
The local Go test verifies a complete chain, wrong hostname, missing
intermediate and a nonce through authenticated TLS allocations. The Python
wire test uses an explicit per-client test CA to verify TLS and a STUN Binding
response through the existing CONNECT tunnel. It also checks invalid trust,
wrong hostname and broker outage.

On macOS, run the native trust control separately from the browser. It uses
Network.framework, a fresh fixture anchor for each connection, and disables
network fetching during trust evaluation. It checks a STUN Binding response
over the valid connection and explicit trust rejection for wrong hostname and
missing intermediate. An HTTP listener serves the missing intermediate and
counts requests after an independent positive control.

```sh
qa_root=$(mktemp -d /private/tmp/neantik-turn-native-tls.XXXXXX)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -module-cache-path "$qa_root/modules" -o "$qa_root/trust-probe" NativeTLSTrustProbe.swift
NEANTIK_NATIVE_TURN_TLS_PROBE="$qa_root/trust-probe" go test -mod=readonly -p 1 ./...
```

This control establishes macOS trust behavior on loopback. The WebKit
NetworkProcess, the broker route and the browser DataChannel nonce require
separate browser evidence. The A/B/A controller supports plain TURN and private TURNS. Pass
`--turn-tls-certificate-case complete` for the positive TURNS control, or
select `wrong-host` or `missing-intermediate` for an isolated rejection run.

`browser-probe.js` is a function expression for the owned synthetic HTTPS
document. Pass its TURN URL and credentials in memory. The probe reports a
fixed status after a bidirectional DataChannel nonce and selected relay
candidate pairs on both peers. SDP, ICE addresses and credentials stay out of
the result. Its status still needs correlation with the server and broker
counters for the same run. Run `node --test browser-probe.test.mjs` to check
the probe logic with simulated peer connections.

The existing CONNECT test proxy accepts a `TurnTCPFixture` child for exactly
`turn-neantik.invalid:<port>`. HTTPS destinations still use the fixture DNS
validator. The TURN authority maps to the live child's loopback listener and
has a separate successful CONNECT counter. From the parent directory, set
`NEANTIK_TURN_TEST_BINARY` to the physical path of the binary built above and
run `python3 -B -m unittest test_tls_fixture` for the wire control. It verifies
that a STUN Binding exchange reaches the real TURN listener through the
authorized tunnel. Browser TURN allocation and DataChannel qualification are
separate observations.

For the private A/B/A browser fixture, run
`scripts/runtime-network/prepare-webkit-ab-isolation-qa.py` with its blank
template, `--private-successor-dev --peer-control --peer-stun-port <port>` and
`--turn-test-binary <physical binary path>`. After sealing the candidate, send
`{"action":"bind-candidate","receipt":"<absolute stage.json>","sha256":"<archive SHA-256>"}`.
The private fixture checks the archive, seed and HTTPS trust scope. Start the
same archive with the signed Swift launcher before recording A1. After A1 send
`{"action":"arm-turn-B1"}` before starting B. The fixture serves the TURN
probe to B, routes the exact authority only through proxy B, and restores the
ordinary page before A2. Send the existing stop command after A2 to close the
listeners and record the server's final allocation count in
`turn-fixture-results.json`. Each successful TURN phase requires two CONNECTs, one successful nonce
report and two allocations. A complete TURNS lifecycle includes B1 and B3
successes with the B2 outage between them. The resulting observations include
the archive SHA-256. Use the signed launcher and runtime route evidence to
verify process identity and detect direct-network bypass.

Require the controller's final `fixture-stopped` verdict after all listeners
drain. For a controller already running from an earlier revision, compare the
final counts with the last recorded phase: the origin page and state counts,
origin request trace and both authorized proxy counters must have no additional
activity. An earlier phase PASS does not include the shutdown interval.
