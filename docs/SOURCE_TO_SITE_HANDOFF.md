# NeAntik Direct source-to-site handoff

Reviewed against the public GitHub Release and `browser.free/api/release` on
25 September 2026. This document records the current release boundary; it does
not make newer local manager changes a public release candidate.

## Public release baseline

- GitHub's latest release is immutable `v0.7.11`, build `74`, bound to source
  commit `fa3b03cbe122840ea308d2ecf19004a1128a1a06`.
- ZIP SHA-256:
  `141ffacec0fb601a9e20fa722b348bc6eed444132efee9c72ab582b5645d3576`.
- DMG SHA-256:
  `fa0489a57b790f51f3d8eea0fa2b4d816bf9a123559f9fd0da71e0ddab6521f4`.
- The last recorded API response reports `published-runtime-gated`,
  `canDownload=false`, and no download URL. Chromium `153.0.8010.52` is below
  the minimum `154.0.8037.58`. A fresh recheck in this pass could not reach
  browser.free (DNS/network failure); web fetch could not reach the site or
  GitHub API, and `gh auth status` reports invalid configured tokens. Treat
  this saved response as historical until live access works again.
- Release `v0.7.10` remains available as the recorded rollback.

## Local manager changes after 0.7.11

Subsequent source work improves off-main-actor profile import and recovery,
snapshot-restore progress, and clearer BrowserData scan-limit status. Tests
cover transaction recovery, entry/byte caps, and fail-closed symlink behavior.
The implementation checkpoints are `66c590b` and `29b4325`; neither is
represented by the 0.7.11 source binding or binary. Pin the final clean Git HEAD
before creating any future exact candidate.
App-issued speech announcements were removed; keyboard actions and native
macOS control metadata remain. The current local HEAD additionally hides the
main SwiftUI accessibility subtree plus sheets and popovers per owner request.
An earlier limited local Dev.app session recorded: `Cmd+N` opened the profile
editor; Tab moved from Name through Folder and Tag to Cancel and Create; Escape
cancelled without saving; `Cmd+Shift+N` opened the folder editor, Tab reached
Cancel, and Escape cancelled; `Cmd+F` focused profile search. The workspace
still showed zero profiles afterward. VoiceOver itself was not launched. This
record is not bound to an exact source hash. A later repeat attempt on
25 September did not reach the UI after a Development-data format warning; the
warning was dismissed without changing or recovering that data. Treat the
earlier check as historical and repeat keyboard smoke on a usable Dev.app and
the exact release candidate. Native macOS menu/titlebar and system-alert
behavior remains OS-controlled. These local changes are not present in the
public 0.7.11 binary or its release evidence.

The retained local candidate is not a package of the current source: its
embedded runtime is `153.0.8010.52`, differs from the repository runtime lock
`152.0.7977.64`, lacks the embedded source contract, and falls below the
minimum security baseline. Do not package or publish it as a newer release.
The current default-shell read-only 13-gate preflight passes 5 and blocks 8:
channel, version/build floor, runtime-lock match, embedded source provenance,
security baseline, GUI channel, and two signing/notary environment values. The
unset shell variables do not prove that Keychain identity or notary profile are
absent. The preflight does not sign, notarize, upload, or approve the retained
app.

## Next Direct release gates

The fresh M154 compatibility experiment is recorded in
`runtime/chromium-154-ungoogled-common-replay.json`: 61/109 pinned M153
common patches applied to official M154 source, 48 failed, and only 6/11
NeAntik runtime groups still pass a context check. This is not a build or
candidate. First pin and review the M154 common/macOS packaging port and
rebase the failed patches; keep all current public assets unchanged until the
runtime gates pass.

Follow-up execution used the exact official macOS Stable source tag
`154.0.8037.58`, commit `a654841425914cbb703a2931e07b70a83aedbafd`, with pinned
DEPS and hooks in a disposable `/private/tmp` build root. GN generated 35,105
targets. A four-job diagnostic `chrome` compile reached 11,815/14,159 actions,
then failed because patch replay removed `safe_browsing::ThreatDOMDetails`
while M154 still calls it from `chrome_content_renderer_client.cc:670`. An
earlier temporary compile fix restored a blocklist setter but left its request
URL empty; that was only a compile probe and has no runtime or privacy proof.
The product repo still contains no M154 source contract, qualified patchset,
runtime lock, or candidate. An attempted temporary edit to remove the renderer
hook was rejected by automatic review as weakening Safe Browsing; no bypass was
used. The intended NeAntik privacy build setting and security tradeoff now need
an explicit owner decision before this code path is ported. No public artifact
or product source/runtime contract changed by the probe.

1. Resolve Chromium source, patch, toolchain, and runtime-lock differences in
   the runtime workstream. Verify source provenance, patch survival, build,
   isolation, and runtime behavior before preparing a candidate.
2. Start from one clean exact source commit and create a candidate with a
   deliberate version/build increment.
3. Bind source, runtime hashes, manager tests, isolation evidence, and package
   manifest to that commit. Run Developer ID signing, Apple notarization,
   stapling, Gatekeeper, and fresh local artifact verification.
4. Upload ZIP/DMG and checksum sidecars to GitHub Releases; verify uploaded
   bytes against candidate hashes.
5. Update browser.free only after artifact gates pass; verify the live page and
   `/api/release` agree on version, build, archive, and SHA-256.
6. Confirm `v0.7.10` remains available as rollback and test the public download
   path before declaring the release complete.

NeAntik is Direct Distribution only; do not use Mac App Store or App Store
Connect. Never publish a stale candidate to bypass a failed runtime gate. Keep
certificates, notary credentials, proxy secrets, cookies, raw network evidence,
and private fingerprint data out of Git and public release metadata.
