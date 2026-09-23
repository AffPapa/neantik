# NeAntik Chromium 153 security rebase

## Status

This document tracks the Chromium 153 source-port decision and release gates.
It does not authorize publication and does not treat an unsigned local build
candidate as a release artifact.

## Verified version boundary — 2026-09-21

The official Chrome Stable desktop update for macOS published on 17 September
2026 is Chromium/Chrome `153.0.8010.52/.53` and lists 16 security fixes:

- <https://chromereleases.googleblog.com/2026/09/stable-channel-update-for-desktop_0194356994.html>

The checked NeAntik security baseline therefore uses `153.0.8010.52` as the
minimum public version and records `.53` as the observed macOS companion build.
The major version `153` is correct, but a `153.0.8010.36` runtime is not
current against this security boundary.

The currently published NeAntik `v0.7.3` release uses Chromium
`153.0.8010.36`. Its release notes already disclose that the runtime is below
the `.52/.53` security boundary. This is a public-alpha limitation, not a
qualification for a new Direct release.

## Upstream source availability

The upstream pieces are not equally ready for a NeAntik source contract:

- ungoogled common has a public `153.0.8010.52-1` release;
- public ungoogled macOS packaging releases currently reach only
  `152.0.7977.82-1.1`, not a 153 macOS packaging tag;
- the upstream macOS 153 update discussion is still a work item, not evidence
  of a reviewed packaging commit.

References:

- <https://github.com/ungoogled-software/ungoogled-chromium/releases>
- <https://github.com/ungoogled-software/ungoogled-chromium-macos/releases>
- <https://github.com/ungoogled-software/ungoogled-chromium/issues/3949>

The project therefore selected an explicit NeAntik-owned macOS packaging port,
rather than inventing an official 153 macOS packaging release. The exact
decision, source commits, candidate hashes, and open gates are recorded in
`runtime/chromium-153-port-status.json`. The 152 packaging checkout remains a
reference input only; it is not silently relabeled as 153.

## Current NeAntik source state

The checked source-only contract still targets Chromium `152.0.7977.64`:

- `runtime/chromium-152-source-contract.json`;
- `runtime/chromium-152-rebase-plan.json`;
- `runtime/nevision-patches/series.json`;
- `runtime/fingerprint-chromium.lock.json`.

Those files are source provenance and patch evidence only. They must not be
changed to `153` by replacing version strings: the owned patchset must first be
ported and reviewed against the real Chromium 153 source and macOS packaging
inputs.

## Remaining source and release sequence

1. Reproduce the owned macOS packaging port from the pinned Chromium/common
   inputs and retain a clean source-input manifest with no rejection artifacts.
2. Create the 153 source contract and toolchain lock from those exact inputs,
   retaining the current 152 files as historical evidence.
3. Port every `releaseRequired` NeAntik patch group against the real 153 source
   tree with zero fuzz and record exact postimage hashes.
4. Re-run the source, patchset, launch-flag, WebRTC-policy, license, notices,
   privacy, and public-workflow verifiers.
5. Bind the candidate to runtime provenance, then run runtime, profile,
   network, privacy, GUI, signing, notarization, and live-release gates.

The first local ARM64/Metal candidate has compiled successfully from the
official `153.0.8010.52` source with the NeAntik port. Its executable is
ad-hoc/unsigned and is therefore not a public release. Source binding,
runtime evidence, signing, notarization, Gatekeeper, and live publication
remain separate gates.

## Fresh candidate audit — 2026-09-22

The clean ARM64/Metal build completed all `52,252` Ninja actions and reports
`NeAntik Browser 153.0.8010.52`. The path-free port verifier passed with the
candidate executable SHA-256
`46947069f9545a9b7a0b5b12ea9fff643c5b9c004d099ab45d9da120a017e7f0`, the
current build-arguments SHA-256
`89d09cc5e0958c7cdf0219935520c9aad48145c3fabc711a8be28cad85e54b85`, and
source-evidence SHA-256
`980866f6bade18ec5304956d3754c0ec8b49418e8815acf2bddeafbf4860b469`.

The 153 launch-flags and WebRTC policy checks pass. The existing reviewed
Chromium 152 patch-series verifier does not pass against the 153 tree:
several patch hunks no longer apply and multiple reviewed postimage hashes
are different. This is evidence that the patch series still requires a real
153 rebase; it is not permission to relabel the 152 contract.

The durable Chromium 153 patch-matrix gate classifies six release-required
groups as exact reverse-apply matches and five as `rebase-required`:
`profile-seed-contract`, `deterministic-webgl-pixels`,
`timezone-locale-network-context`, `minimal-apple-device-tuple`, and
`private-runtime-config-environment`. The matrix therefore reports
`releaseReady: false`; its evidence is classification only and cannot qualify
signing, notarization, or publication.

The runtime gate also remains closed because the built framework contains the
intentional `apple-device-tuple` marker from the current tuple patch. The
release verifier treats that marker as forbidden, so the implementation and
the release policy need reconciliation before a signed candidate can be
accepted. The bundle is linker/ad-hoc signed only. Current Keychain evidence
has zero Developer ID identities and no `neantik-notary` profile.

The source replay gate was then run from a clean worktree at the pinned
official Chromium commit. The tracked NeAntik/ungoogled diff applied with
`git apply --check` and the same 26 untracked source inputs were restored;
both the tracked-diff SHA-256
`c603f87f734fd2e6d4a8d1b16f095b1e80c1dfe0d7f23f55009b453b1b2462c3` and the
untracked-inventory SHA-256
`74554692a27105c0f7c95c9b7491b34fe33e27f475fffda440a66ae56236d090` match the
built source tree. This proves source-input replay, but not a second binary,
runtime qualification, signing, notarization, or release readiness.

As a diagnostic smoke, the temporary ad-hoc-signed bundle was launched through
the normal macOS `open -W -n` app path and remained alive for more than 90
seconds; it was then stopped explicitly. Directly executing the nested binary
outside the app-launch path aborts in macOS LaunchServices and is not treated
as a Chromium runtime failure. This smoke is not GUI A → B → A evidence and
does not qualify the candidate for signing or publication.

## Canonical 153 tuple overlay candidate — 2026-09-23

The previously forbidden tuple marker was not removed by a textual workaround.
Instead, the current Chromium 153 source was rebuilt with a reviewed, exact
owned overlay that adds the NeAntik Apple tuple header and binds the supported
profile surfaces to that single tuple source. The overlay is recorded as
`runtime/nevision-patches/patches/canonical-apple-device-tuples-153.patch`
with SHA-256
`93dd686b8b8e67cc6398da28c926e309d0fd20fa464d41345561f06242464ce1`.

`scripts/apply-owned-runtime-device-tuples-153.py` verifies the official
Chromium commit/tree, the `153.0.8010.52` version file, the patch hash, and
eight exact postimage hashes. The script was replayed against the official
153 checkout and then checked again after application. Its unit tests,
Python compilation, `git diff --check`, and the open-source tree verifier all
pass. This is source-integrity evidence, not a claim of anti-fraud bypass.

The canonical overlay candidate compiled incrementally with `30/30` Ninja
actions and passed the static runtime verifier with `16` ARM64 Mach-O files,
Metal GPU mode, verified fingerprint protocol strings, and a verified
ad-hoc signature. The candidate report remains `releaseReady: false`; the
fresh executable SHA-256 is
`9365e2015f9d0f604ed6b5268647540319cb0d5a870586df44f7c862021bc899b`.

The first direct app-path smoke for this exact signed copy was not a GUI pass:
LaunchServices returned `kLSNoExecutableErr` and direct process execution was
blocked by the host with `operation not permitted`. At that point GUI A → B →
A, profile isolation, real network-route behavior, Developer ID signing,
notarization, Gatekeeper, and publication remained open gates. A later
user-context GUI pass is recorded below; the candidate is still not a release
artifact because signing and publication gates remain open.

## Runtime lifecycle recheck — 2026-09-23

The production audit coordinator was hardened in commit `330fe64`: after
`Browser.close`, it now gives Chromium up to five seconds to exit naturally
before using the existing SIGTERM fallback. This prevents the coordinator
from interrupting Chromium's own helper-process cleanup after the previous
200 ms websocket grace period. The change preserves the fail-closed lease and
BrowserData checks; it does not force-delete a profile directory.

The full Swift package suite passed after the change: `576` tests in `61`
suites, including browser-process lifecycle, profile isolation, privacy, and
fingerprint policy tests. The system-built audit CLI also compiled and was
able to launch the `153.0.8010.52` candidate. A normal macOS GUI smoke opened
the candidate window, but the first direct coordinator attempt still ended
with `Chromium не завершился после проверки отпечатка`; its bounded fallback
logged `browser_exit reason=2 status=15`. This was a lifecycle/runtime
qualification failure for the direct host context, not a successful production
fingerprint report. A later user-context pass is recorded below. The candidate
remains unsigned and release-ineligible.

## User-context GUI fingerprint gate — 2026-09-23

The exact `153.0.8010.52` candidate was launched through the normal macOS
user context and completed the production A → B → A audit. The owner-only
schema-7 report was kept outside the repository at
`/private/tmp/neantik-runtime-audit-153-user-report.json`; its SHA-256 is
`d50afdee844a9488105ea83b919bc5cedaf81a8d83ea26b84e95e8603b371bd7`.

After verifier commit `7e3a5c2`, the strict report check with
`--require-production` and an exact candidate runtime lock passed with
`qualified: true`, `productionQualified: true`, and no issues. The report
bound to runtime `153.0.8010.52`, the candidate executable hash
`9365e2015f9d0f604ed6b5268647540319cb0d5a870586df44f7c862021bc899b`, and
the matching framework hash recorded by the canonical runtime gate.

The report proves profile isolation and repeatability for A → B → A, stable
changes across all four critical fingerprint surfaces, and stable WebGL/Metal
availability. WebRTC evidence is limited to the configured-route control and
sanitized candidate summary; no HTTP exit-IP claim is made. Media and
permissions diagnostics were accepted only in privacy-safe aggregate form,
without device IDs or raw values.

This closes the user-context GUI, lifecycle, provenance, privacy, and profile
isolation gates for the candidate. Developer ID signing, notarization,
stapling, Gatekeeper, GitHub publication, live download/install, and rollback
remain open because the required credentials are not present on this Mac.

## Historical packaging chain reconciliation — 2026-09-22

The previously published `v0.7.3` ZIP was inspected as a historical rollback
artifact. It contains the earlier Chromium `153.0.8010.36` source contract,
the historical `series-153.json`, and the consolidated
`chromium-153-owned-port.patch`. That is the packaging chain remembered from
the earlier build, but it is bound to `.36` and its review explicitly stopped
at source-patch qualification; it did not prove a current `.52` binary,
Developer ID signature, notarization, or publication.

The historical consolidated patch was checked against a clean official
`153.0.8010.52` worktree. It does not apply cleanly: the current tree lacks
the historical `components/ungoogled/BUILD.gn` input until the owned input
layer is restored, and several Blink/WebGL/canvas/image-encoder contexts no
longer match. This confirms that the old chain is valuable provenance and
review input, not a releasable `.52` port. Reusing it requires a source-level
rebase, exact postimage review, and a fresh binary binding.

The local signing search was also repeated. The available keychain search
returns zero valid code-signing identities, and the targeted lookup for a
`Developer ID Application` certificate and the `neantik-notary` generic
password does not produce a usable credential. The old Team ID found
inside the published rollback artifact (`H6VGU2M6JD`) proves historical
signing metadata only; it does not recover the private key or the notary
credentials. The current candidate therefore remains intentionally unsigned
and unpublished until the credentials are restored into this Mac's keychain.

The local shell history independently confirms that `neantik-notary` was used
by earlier release attempts with Team ID `H6VGU2M6JD`, and that the historical
NeAntik signing fingerprint was selected by the release wrapper. The history
contains no usable notary secret: the profile setup was interactive and no
credential value is retained in the repository evidence. A history entry is
therefore provenance that the profile once existed, not a recoverable keychain
profile or authorization to guess/reuse another product's credential.

## Public rollback baseline — 2026-09-22

The current public GitHub Direct release `v0.7.3` was checked read-only before
any new publication. The ZIP asset hash is
`c380a1a4f998f96758380287b0725d7013ebcb33cfed36ee5ba0ccaf058b916b` and the
DMG asset hash is
`b86e6834135db1593fbc37fab09e56d7b24fa6043287500eb387472f1e2b6264`; both
match the GitHub release API. The DMG mounts read-only and its app metadata
reports Team ID `H6VGU2M6JD` and a stapled ticket. The published baseline
contains Chromium `153.0.8010.36`, not the new `153.0.8010.52` candidate.

On this host's macOS 27 beta, `codesign --verify`, `spctl`, and `stapler
validate` return signature/internal errors for the downloaded baseline even
though its embedded signature metadata and ticket are present. This local
Gatekeeper result is therefore inconclusive and is not reused as evidence for
the new candidate.

## Required post-permission gates

With rebuild permission now present, the remaining gates are the release
checks: Developer ID signing, notarization, stapling, Gatekeeper, GitHub asset
verification, AffPapa staging, live download checks, and rollback evidence.
Network evidence remains intentionally scoped to configured-route/WebRTC
controls; no direct HTTP exit-IP proof is claimed.
