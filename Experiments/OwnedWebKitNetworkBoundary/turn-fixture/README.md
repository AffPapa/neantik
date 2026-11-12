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
