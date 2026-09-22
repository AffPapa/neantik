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

## Required post-permission gates

Only after explicit rebuild permission may the exact 153 candidate proceed
through ARM64/Metal build, runtime inspection, profile isolation, GUI A → B → A,
network reality, signing, notarization, stapling, Gatekeeper, GitHub asset
verification, AffPapa staging, live download checks, and rollback evidence.
