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

## Required post-permission gates

Only after explicit rebuild permission may the exact 153 candidate proceed
through ARM64/Metal build, runtime inspection, profile isolation, GUI A → B → A,
network reality, signing, notarization, stapling, Gatekeeper, GitHub asset
verification, AffPapa staging, live download checks, and rollback evidence.
