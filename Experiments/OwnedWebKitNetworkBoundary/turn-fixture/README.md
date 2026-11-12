# Loopback TURN control

This development fixture accepts authenticated TURN over TCP on an ephemeral
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
traffic by exposing a relay address. The fixture currently covers TCP to TURN.
TURN/TLS needs a separate certificate and endpoint trust check.

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
`--turn-test-binary <physical binary path>`. After recording A1, send
`{"action":"arm-turn-B1"}` before starting B. The fixture serves the TURN
probe to B, routes the exact authority only through proxy B, and restores the
ordinary page before A2. Send the existing stop command after A2 to close the
listeners and record the server's final allocation count in
`turn-fixture-results.json`. The fixture requires two CONNECTs, one successful
nonce report and exactly two allocations. Use the signed launcher and separate
runtime route evidence to associate these observations with the selected
candidate and detect direct-network bypass.
