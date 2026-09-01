# NeAntik source-to-public handoff

Status: reconciled 2026-09-01.

## Current fact

- GitHub release `v0.3.22`, version/build `0.3.22 (25)`, is published and
  immutable.
- Its exact source commit is
  `160c4e71cb1aee76d940bc2d07ad64ed014bf54f`.
- The signed and notarized ZIP/DMG in that release are historical immutable
  artifacts. Do not replace, retag or rebuild them under the same version.
- A source-only PR after that commit is not a new binary release.
- Website state is a separate live transaction. Never infer it from this file
  or from GitHub alone; verify it live before a future publish.

## Next release handoff

0. Generate the external Developer ID provisioning profile with the exact
   certificate selected by `NEANTIK_SIGNING_IDENTITY`; the local gate must
   confirm that `DeveloperCertificates` binding before any expensive build.
1. Assign a version and build newer than `0.3.22 (25)`.
2. Move `CHANGELOG.md` from Unreleased to `Direct VERSION (BUILD)` and update
   both READMEs before building.
3. Merge the source PR after all checks and use its exact merge SHA, never a
   mutable branch name.
4. Run full source, Swift, Python, ARM64 and live-manager/browser gates plus:

   ```bash
   ./scripts/neantik-affpapa-release doctor
   ```

5. Run `./Release-NeAntik.command` once for the exact candidate. Require fresh
   A -> B -> A evidence, Developer ID, notarization, stapling, Gatekeeper,
   final ZIP/DMG and SHA-256.
6. Publish immutable GitHub assets, re-download them and compare SHA-256 and
   Gatekeeper results.
7. If website publication is explicitly authorized, run the separate
   `site-doctor`, prepare exactly the six files from `ops/affpapa/README.md`
   and use only:

   ```bash
   ./scripts/neantik-affpapa-release site-doctor
   ./scripts/neantik-affpapa-release publish /absolute/path/to/release-dir
   ```

8. Never use SSH, SCP, SFTP, rsync or manual server edits.

## Stop rule

At any mismatch between source SHA, candidate manifest, evidence,
notarization, checksums, GitHub assets, site assets, visible version or download
links, stop and leave the previous verified public state unchanged. Never put
certificate identities, notary profiles, deploy keys, proxy credentials or
raw fingerprint evidence in Git, prompts, logs or public files.
