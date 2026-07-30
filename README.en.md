# NeAntik

NeAntik is an open-source, local-first browser profile manager for Apple
Silicon Macs. The manager is native SwiftUI and launches an embedded,
source-pinned Chromium runtime. It does not require Electron, an account, a
separately installed Chrome, or telemetry.

[Русская версия](README.md)

## Download

Download the signed and notarized application from
[GitHub Releases](https://github.com/AffPapa/neantik/releases).
Do not use GitHub's **Code → Download ZIP** button when you want the app: that
archive contains source code, not `NeAntik.app`.

Current release:

- NeAntik `0.3.12` build `15`;
- macOS 14 or newer, Apple Silicon only;
- Chromium `150.0.7871.186`, ARM64, Metal;
- archive: `NeAntik-0.3.12-arm64-notarized.zip`;
- SHA-256:
  `b8a791056a8857339e1a52e48a81181f49525d2737cf985886b0b1aa05b8fc73`.

Product website: <https://affpapa.org/neantik>.

The same release is mirrored at <https://cpa.tg/neantik/>.

## What it does

- keeps cookies, local storage, and browser data in separate persistent
  profiles;
- supports direct connections, authenticated HTTP/HTTPS through Chromium's
  native prompt, and SOCKS5 without credentials;
- keeps proxy passwords in macOS Keychain;
- prevents a second launch of the same profile;
- provides deterministic per-profile browser-surface isolation in the bundled
  patched Chromium runtime; newly created profiles are distributed with the
  system CSPRNG across four reviewed Apple Silicon cohorts, while existing
  profiles are never rotated automatically;
- includes an A → B → A audit for stability and separation;
- keeps Direct telemetry disabled.

For authenticated HTTP/HTTPS proxies, separate buttons copy the username and
password into Chromium's native prompt. The password remains in macOS
Keychain and never enters the browser command line. Copied values carry the
transient/concealed pasteboard hints and an unchanged clipboard is cleared
after 60 seconds; another app can still read it during that interval.

## Security and scope

NeAntik is intended for privacy, separated work sessions, development, and QA.
It does not claim complete anonymity or undetectability. It is not designed to
bypass CAPTCHAs, bans, anti-fraud systems, or third-party platform rules.

Version `0.3.12` is qualified for public-alpha profile isolation. Strict
production fingerprint coherence across every browser and network surface
remains incomplete and is tracked as a limitation.

The four cohorts are a reviewed product policy, not market-share evidence or
an anonymity guarantee. A stable profile fingerprint intentionally links
repeat visits within that profile; cookies, accounts, proxies, locale,
behavior, and other signals can also link sessions. The current policy narrows
the hardware tuple set; it does not make Canvas, Audio, WebGL, or ClientRects
identical across different users.

## Source layout

- `Sources/NeAntik` — native SwiftUI manager;
- `Tests/NeAntikTests` — manager, profile, proxy, runtime, and privacy tests;
- `runtime` — Chromium source lock, patch manifest, patches, and third-party
  licenses;
- `scripts` — build, verification, signing, and Direct release gates;
- `docs` — architecture, privacy, runtime, and distribution documentation;
- `releases` — public binary metadata and checksums, not the binary itself.

The full Chromium checkout and build output are intentionally not committed.
The runtime is reconstructed from the pinned upstream Chromium source plus the
checked-in patchset. See [Building from source](docs/BUILDING.md).

## Build the manager

```bash
./scripts/verify-native-swift-tests.sh
swift run NeAntik
```

Packaging a complete Direct application additionally requires a built Chromium
runtime. Apple Developer ID signing and notarization use credentials in the
builder's Keychain and are never stored in this repository.

Direct releases use two phases: prepare and sign one exact `NeAntik.app` with
an immutable full-bundle manifest, then bind a fresh GUI A → B → A audit to
that candidate. Notarization never rebuilds or re-signs it. The
`public-alpha` and strict `production` qualification channels are explicit and
cannot be substituted for one another.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md) before
opening a pull request or reporting a vulnerability.

The synthetic
[fingerprint conformance corpus](docs/PUBLIC_FINGERPRINT_CONFORMANCE.md)
reuses the release verifier without publishing user profiles, seeds, proxy
configuration, or real audit reports.

NeAntik-owned source files are licensed under MPL-2.0. Chromium-derived files
retain their upstream licenses and notices. The NeAntik name and logo are
subject to [TRADEMARKS.md](TRADEMARKS.md).
