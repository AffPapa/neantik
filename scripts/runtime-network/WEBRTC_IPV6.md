# Owned WebRTC IPv6 boundary

Adds only the missing loopback IPv6 scope of major item21. The existing eleven
IPv4 cases and their frozen evidence are unchanged.

`webrtc-stun6-fixture.mjs` binds a UDP6-only socket on the local loopback. It
encodes a128-bit XOR-MAPPED-ADDRESS using the cookie and transaction ID. Before
each browser, a real IPv6 canary verifies response family, mapping, transaction
and port; its traffic is kept separate from browser measurements.

```sh
node scripts/runtime-network/test-webrtc-stun6-fixture.mjs
node scripts/runtime-network/test-webrtc-ipv6-semantics.mjs
node scripts/runtime-network/run-webrtc-ipv6.mjs --app /absolute/runtime.app --binding /absolute/binding.json --output /absolute/new/output --case direct
```

Run `--case guarded` in a new output directory only after the direct control
succeeds. There is deliberately no default eleven-case matrix. The native runner
reuses the existing fixed-expression/default-realm CDP adapter and preference
checks. It verifies exact16Mach-O runtime hashes, code signature and fresh normal
resource admission; uses a temporary profile and mock Keychain; and records final
UDP counters only after actual browser exit. It changes no OS network settings.

`verify-webrtc-ipv6.mjs` additionally requires the direct browser to obtain a
server-reflexive ICE candidate. A canary or collector count alone is insufficient.
It compares unchanged producer pins, ordered session lifecycles and the guarded
zero-UDP/zero-reflexive result. Raw candidate strings and personal IPs are never
exported. The analyser can operate on retained receipts without another browser.

On the downloaded0.8.23 runtime, direct sent one UDP6 STUN request and obtained
one reflexive candidate; guarded sent zero, completed ICE and loaded through the
own HTTP proxy. Both exited normally with no own processes/profiles remaining.
[Result and limits](../../docs/evidence/webrtc-ipv6-0.8.23.json).

This is a raw-runtime loopback observation. It does not qualify manager/relay IPv6,
external interfaces, TURN, OS-managed policies, DNS, WebKit or global anonymity.
No application or runtime rebuild was required.

Protocol references: [RFC8489§14.2](https://www.rfc-editor.org/rfc/rfc8489#section-14.2),
[STUN URI syntax](https://www.rfc-editor.org/rfc/rfc7064#section-3.1).
