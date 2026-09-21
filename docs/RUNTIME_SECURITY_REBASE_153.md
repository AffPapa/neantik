# NeAntik Chromium 153 security rebase

## Status

This is a source-only preparation document. It does not claim a Chromium 153
binary, does not modify the checked runtime lock, and does not authorize a
build or public release.

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

Until exact macOS packaging source is available, do not invent a 153 packaging
commit, reuse the 152 packaging layer, or treat the common release as a
shippable macOS runtime.

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

## Work that can proceed without a build

1. Resolve the official Chromium 153 source tag/commit and the matching
   ungoogled macOS/common packaging commits.
2. Create a new source contract and toolchain lock from those exact inputs,
   retaining the current 152 files as historical evidence until the new pair
   is independently verified.
3. Port every `releaseRequired` NeAntik patch group against the real 153 source
   tree with zero fuzz and record exact postimage hashes.
4. Re-run the source, patchset, launch-flag, WebRTC-policy, license, notices,
   privacy, and public-workflow verifiers.
5. Stop before runtime compilation, promotion, signing, notarization, upload,
   or live release work until the rebuild is explicitly permitted.

## Required post-permission gates

Only after explicit rebuild permission may the exact 153 candidate proceed
through ARM64/Metal build, runtime inspection, profile isolation, GUI A → B → A,
network reality, signing, notarization, stapling, Gatekeeper, GitHub asset
verification, AffPapa staging, live download checks, and rollback evidence.
