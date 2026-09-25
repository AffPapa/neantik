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
- The API reports `published-runtime-gated`, `canDownload=false`, and no
  download URL. Chromium `153.0.8010.52` is below the minimum
  `154.0.8037.58`.
- Release `v0.7.10` remains available as the recorded rollback.

## Local manager changes after 0.7.11

Subsequent source work improves off-main-actor profile import and recovery,
snapshot-restore progress, and clearer BrowserData scan-limit status. Tests
cover transaction recovery, entry/byte caps, and fail-closed symlink behavior.
The implementation checkpoints are `66c590b` and `29b4325`; neither is
represented by the 0.7.11 source binding or binary. Pin the final clean Git HEAD
before creating any future exact candidate.
App-issued speech announcements were removed; keyboard actions and native
macOS control metadata remain. These changes are not present in the public
0.7.11 binary or its release evidence.

The retained local candidate is not a package of the current source: its
embedded runtime is `153.0.8010.52`, differs from the repository runtime lock
`152.0.7977.64`, lacks the embedded source contract, and falls below the
minimum security baseline. Do not package or publish it as a newer release.

## Next Direct release gates

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
