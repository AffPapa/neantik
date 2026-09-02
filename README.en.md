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

Current published GitHub public-alpha release:

- NeAntik `0.3.23` build `26`;
- macOS 14 or newer, Apple Silicon only;
- Chromium `152.0.7977.64`, ARM64, Metal;
- ZIP: `NeAntik-0.3.23-arm64-notarized.zip`;
- DMG: `NeAntik-0.3.23-arm64-notarized.dmg`;
- SHA-256 sidecars are published with both GitHub Release assets.

The published `0.3.23 (26)` release adds a dedicated note editor,
semantically honest notices, clearer list actions, safe quick Direct profile
creation, and a command to reveal an already running browser window. It also
removes the unused telemetry, updater-manifest, and external Chrome/Cloak
selection prototypes: Direct launches only its exact embedded runtime. The
large `ContentView` is also split without changing behavior, and CI now scans
both the current tree and every reachable Git blob for recognized secret
formats. Exact merged commit
`fdc520391c58a76622936519ca38b382f629fc47` passed Developer ID signing,
notarization, stapling, Gatekeeper, re-download verification, and the immutable
GitHub gate.

Published `0.3.23 (26)` includes a local Readiness Center. It identifies the
exact `NeAntik.app` users should select in macOS permissions, rechecks the
runtime and shared data root without restarting, and copies only bounded,
redacted diagnostics.

Product website: <https://affpapa.org/neantik>. Its version, build, hashes, and
download links are synchronized with GitHub Release `v0.3.23`; GitHub serves
the files and AffPapa keeps no second binary copy.

Development preview `0.3.24 (27)` is going through the release gates. At a
normal window width, note and bulk-proxy drafts are protected from accidental
dismissal, create/edit mode is explicit, search syntax is visible, bulk
actions fit the minimum width, and proxy passwords have a temporary reveal
control that now expires after 15 seconds and when the app resigns active.
The source candidate also adds explicit safe duplication, a local shared-proxy
endpoint warning, profile dates, recently-modified ordering, and confirmed
ordinary-only Stop All. Profile-size scans and secret stdin writes are
cancellable, no idle session timer is created, and the embedded runtime is
re-inspected immediately before launch. Runtime, DevTools, proxy preflight and
the Direct release toolchain also have additional fail-closed checks. CI
includes SHA-pinned CodeQL for Swift and Python. Until a new ZIP and DMG are
published and re-downloaded successfully, `0.3.23 (26)` remains the public
download.

The latest source-only `0.3.24 (27)` pass also turns research across thirty
profile browsers into an [exact 100-item recommendation matrix](docs/ANTIDETECT_RECOMMENDATION_MATRIX_2026-09-02_V3.md)
and implements the twenty-five highest-value bounded changes without new
dependencies. Profile metadata is schema-versioned, Recovery is bounded, and
private metadata reads use stricter descriptor-first limits. Safe Quit can
stop ordinarily, leave browsers running, or cancel without automatic force
stop. Cause-specific empty states, exact bulk-import error navigation, visible
folder keyboard selection, result counts, proxy-test progress, consistent
row/inspector actions, VoiceOver actions, and narrow responsive controls make
the operator path clearer. This remains a source preview: the public ZIP, DMG,
website, and download links stay on `0.3.23 (26)` until a separate complete
Direct Distribution cycle.

The capabilities below are included in the published, signed, and notarized
`0.3.23 (26)` release.

## Quick start

1. Create a profile and give it a clear name.
2. Paste a proxy if needed; NeAntik parses it locally.
3. Click **Launch**. Cookies and site data stay inside that profile.

## What it does

- keeps cookies, local storage, and browser data in separate persistent
  profiles;
- searches profiles by name and tags, pins important profiles, archives
  inactive profiles without deleting data, and duplicates settings into a
  profile with a new UUID, fingerprint seed, and BrowserData; the proxy
  configuration is copied too;
- supports direct connections, authenticated HTTP/HTTPS through Chromium's
  native prompt, and SOCKS5 without credentials;
- locally parses a proxy list and creates up to 100 separate profiles without
  automatic network requests; a failed import does not save profiles, and any
  unfinished password cleanup is marked for retry on the next launch;
- keeps proxy passwords in macOS Keychain;
- launches Chromium with a minimal system-environment allowlist instead of
  inheriting proxy variables, TLS key logs, or Terminal tokens;
- prevents a second launch of the same profile;
- provides deterministic per-profile browser-surface isolation in the bundled
  patched Chromium runtime; newly created profiles are distributed with the
  system CSPRNG across four reviewed Apple Silicon cohorts, while existing
  profiles are never rotated automatically;
- includes a protected release-only A → B → A audit for stability and
  separation without exposing it in the normal user flow;
- contains no product telemetry client or telemetry configuration.

## New in published 0.3.23 (26)

- The exact signed and notarized release adds a dedicated note editor, honest
  notice states, clearer secondary list actions, safe Quick Create, a command
  to reveal an already running window, local row density, and one fixed native
  shortcut reference.
- Direct no longer contains the dormant telemetry, update-manifest, or
  external Chrome/Cloak selection prototypes; it launches only the declared
  embedded runtime.
- `ContentView` request and cache state now has a narrower owner, while CI
  separately scans the current tree and every reachable Git object for known
  secret formats without printing matched values.

## New in published 0.3.22 (25)

- The profile list is the primary workspace, with adaptive rows, an optional
  inspector, explicit multi-selection and conflict-safe batch undo.
- Search supports `tag:`, `folder:`, `proxy:`, and `status:` tokens. Bulk
  import accepts bounded local TXT/CSV files without following symlinks.
- Launch preflight has explicit runtime, storage, proxy, consistency, and
  process stages. Running, closing, unresponsive, and completed profiles have
  distinct presentation and Force Stop remains separately confirmed.
- The Readiness Center, on-demand profile storage measurement and deterministic
  source/startup/resource/installed-size budgets keep the app auditable.

See the current [project map](docs/PROJECT_MAP.md) and the dated
[20-product UX research](docs/COMPETITOR_UX_RESEARCH_2026-09-01.md).

## New in published 0.3.21 (24)

- The optional profile note is expanded during creation, and an empty profile
  detail always offers **Add note…**.
- A launch failure without system detail points to safe environment
  diagnostics and official-DMG reinstall without deleting profile data.
- Chromium local symbols are removed only from the temporary unsigned copy by
  the compatible Xcode Apple `strip` before Developer ID signing. Locales,
  licenses, notices, SwiftShader, crashpad, and security evidence remain.

For authenticated HTTP/HTTPS proxies, separate buttons copy the username and
password into Chromium's native prompt. The password remains in macOS
Keychain and never enters the browser command line. Copied values carry the
transient/concealed pasteboard hints and an unchanged clipboard is cleared
after 60 seconds; another app can still read it during that interval.

## Security and scope

NeAntik is intended for privacy, separated work sessions, development, and QA.
It does not claim complete anonymity or undetectability. It is not designed to
bypass CAPTCHAs, bans, anti-fraud systems, or third-party platform rules.

Version `0.3.23` is published for public-alpha profile isolation. Strict
production fingerprint coherence across every browser and network surface
remains incomplete and is tracked as a limitation.

The bundled privacy-oriented Chromium is built without Google Safe Browsing.
NeAntik does not send browsing history to Google, but it is not a replacement
for dedicated phishing, malicious-site, or unsafe-download protection. Do not
trust an unknown link merely because it is opened in an isolated profile.

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
./Develop-NeAntik.command
```

`Develop-NeAntik.command` is the fast loop for UI and Swift changes. It creates
an APFS clone of the embedded Chromium once, then rebuilds only the manager and
opens an isolated `NeAntik Dev.app`. Development profiles and proxy credentials
are separate from the production app. Use
`./Develop-NeAntik.command --no-open` for a build-only check.

Run `Release-NeAntik.command` only for the final exact candidate; that path
performs the expensive release gates, A → B → A check, Developer ID signing,
Apple notarization, and ZIP/DMG packaging.

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
