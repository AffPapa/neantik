# HTTPS authenticated relay — shared production selection

HTTP, HTTPS and SOCKS5 authentication now use the same UI/MCP relay selector.
TLS uses the default macOS certificate policy before credentials are enqueued.
There is no plaintext or Direct retry on trust/authentication failure.

Qualification is composed: actual OS-default TLS/application I/O against the
owned browser.free origin, authenticated CONNECT/private-anchor controls and
headed Chromium through the normal manager selector. This is not a claim of
end-to-end authenticated CONNECT against a public OS-trusted HTTPS proxy.

## Implemented and actually tested

The transport keeps Network's default `.tls` parameters in Release. DEBUG has
an explicit owned-fixture initializer: certificate input is bounded to4KiB,
endpoint name is exactly `localhost`, and Security evaluates the complete TLS
chain, hostname and date against the supplied fixture anchor. Network trust
discovery is disabled for that fixture. No unconditional acceptance, changed
verification date, environment/preference trust hook or production override.

Nine local socket scenarios passed:

- root/intermediate/leaf with correct SAN, authenticated CONNECT carrying the
  remote destination domain,512KiB payload, bounded128KiB buffer and TLS EOF;
- wrong SAN, expired certificate, foreign CA and a fresh missing intermediate;
- plaintext upstream and the same private chain without the test trust hook;
- cancellation during TLS handshake, with no credential writes;
- truncated TLS/RST distinguished from a clean EOF.

The failed trust controls observed zero credential writes and no decoded auth
application bytes. Three malformed/oversized input cases also passed.
Sixteen existing HTTP/SOCKS/default-TLS socket scenarios passed after the shared
initializer change. A separate Release compilation passed and its symbol table
contains no `ProxyRelayTLSQualification` type. This is compilation evidence,
not a signed/notarized runtime qualification.

## Signed owner and headed Chromium fixture controls

A separate Developer ID signed DEBUG manager (`app.neantik.desktop.relay-qualification`)
now carries the bounded public CA certificate over its authenticated private bootstrap
pipe. Only its exact qualification invocation creates this in-memory context. The
receiver checks its QA identity; protocol must be HTTPS and upstream name exactly
`localhost`. The shared Release path retains Network's normal certificate policy.
No anchor is saved in profile metadata, browser preferences, argv or Keychain.

The owned signed fixture verified:

- Chromium HTTP navigation through the authenticated TLS CONNECT relay, with
  the destination domain passed to upstream;
- manager exit, fresh browser request, restart adoption and duplicate refusal;
- upstream drop: actual Chromium request error selected the expected relay,
  with no response headers and no Direct sentinel hit; a headed Direct control
  independently proved the sentinel responds;
- wrong TLS name: two actual connection attempts, zero decoded authentication
  bytes, and actual Chromium request error through the expected relay;
- cancellation of the real launch Task after Bound, before Commit: zero upstream
  connection/authentication and no published running session;
- two HTTPS profile streams with distinct upstreams/credentials,17 seconds idle
  after manager EOF, refusal of a foreign signed browser, and stop A while B
  continued. Owned groups/listeners were drained.

The test CA is never installed in system trust and its temporary private keys are
removed. These are synthetic preflight/private-anchor qualification controls, not
production OS-default trusted-upstream or notarized-release evidence. The bundled
Chromium payload remained unchanged at156.0.8078.12.

## Current measured scope and remaining limits

The fresh normal-selector headed fixture passed an HTTPS destination, independent
request/job/SOCKS/TLS NetLog binding, remote-domain CONNECT, manager adoption,
duplicate refusal, active upstream interruption and native PID/generation-bound
close. Both HTTP and HTTPS failures selected the relay, with no Direct sentinel
hit. This is bounded session evidence; it is not a universal continuous DNS/route
verdict. A default-OS-trusted authenticated CONNECT end-to-end run is unmeasured.

The actual OS-default constructor carried HTTP application I/O with no private
anchor and no credentials. Cancellation rejected the next write. The local
certificate/authentication controls remain independent negative tests.

See releases/v0.7.32.md for the exact signed/published candidate status. Before
that report passes its gates, these source/QA results are not publication evidence.
Synthetic fixtures never use customer credentials, profiles or Keychain items.
