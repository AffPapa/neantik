# HTTPS authenticated relay — qualification in progress

The production relay supports authenticated HTTP/SOCKS5. The HTTPS relay
selector is still disabled pending owner/session and headed-browser gates.
Existing HTTPS proxy launch behavior is unchanged.

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

## Required before product enablement

1. Carry the bounded public fixture anchor through authenticated DEBUG owner
   bootstrap only, with exact QA identity and loopback restrictions.
2. Exercise ordinary manager launch, Chromium HTTP/HTTPS route, remote DNS,
   manager EOF/restart, revocation, cancellation and concurrent session cleanup.
3. Obtain independently observed OS-default trusted HTTPS upstream evidence.
   Private-anchor controls do not establish that result.
4. Enable the shared production selector only after those gates, then qualify
   the exact signed candidate and freshly downloaded published bytes.

No browser-route, final release or production HTTPS relay claim follows from
the transport tests alone. Synthetic fixtures never use customer credentials,
profiles, Keychain items or external endpoints.
