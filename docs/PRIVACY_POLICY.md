# NeAntik privacy policy

Effective date: July 29, 2026

NeAntik is a local browser-profile application for Apple Silicon Macs. It has
no NeAntik account, cloud synchronization, advertising SDK, cross-app
tracking, or enabled product telemetry.

## Data stored on the Mac

NeAntik stores profile names, start pages, non-secret proxy configuration,
runtime preference, fingerprint seeds, and local audit reports on the Mac.
Each profile has a separate persistent browser-data directory. Proxy passwords
are stored in macOS Keychain rather than profile metadata.

Deleting a profile moves its browser data to the macOS Trash and removes its
NeAntik metadata and associated Keychain secret. Legacy NeVision storage and
Keychain identifiers are migrated conservatively so an update does not hide or
destroy existing profiles.

## Telemetry

The Direct release does not send product telemetry:

- the telemetry endpoint is empty;
- no telemetry consent switch is exposed;
- no stable installation identifier is created;
- the privacy manifest declares no collected data.

NeAntik does not receive browsing history, sites, URLs, cookies, website data,
profile names or IDs, start pages, proxy hosts or credentials, exit IPs,
fingerprint seeds or audit results, Apple ID, email, serial numbers,
keystrokes, clipboard contents, or local file paths.

Future telemetry cannot be enabled until a separately reviewed server,
privacy-preserving contract, public policy, consent UI, retention policy, and
release gate are complete. It must be optional and off by default.

## Network activity

When you browse a website, that website receives ordinary browser requests. A
user-selected proxy handles that profile's traffic and may have its own privacy
policy. Chromium, macOS security services, DNS/network providers, and Apple
notarization or update infrastructure may process requests under their own
terms. They are not NeAntik telemetry.

The proxy test contacts the configured proxy and a documented egress-IP
endpoint. Credentials are supplied to the local `curl` process through an
in-memory stdin configuration rather than command-line arguments.

## Security reports

Use GitHub private vulnerability reporting for security issues. Remove personal
data, URLs, cookies, profile names, proxy information, and fingerprint seeds
from diagnostic material. Never send Apple credentials, certificate private
keys, Keychain exports, or real proxy passwords.

General non-sensitive bugs may be reported through GitHub Issues.
