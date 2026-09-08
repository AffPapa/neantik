# NeAntik source-to-public handoff

Status: reconciled 2026-09-08. GitHub-only release operation; the owner maintains
the AffPapa page separately. Historical filename retained for existing links.

## Current fact

- GitHub release `v0.3.25`, version/build `0.3.25 (28)`, is published and
  immutable.
- Its exact source commit is
  `b0afa5731b64a6b18e3b039c5fcaaefe18758757`.
- The signed and notarized ZIP/DMG in that release are historical immutable
  artifacts. Do not replace, retag or rebuild them under the same version.
- A source-only PR after that commit is not a new binary release.
- Website state is a separate live transaction. Never infer it from this file
  or from GitHub alone; verify it live before a future publish.

## Next release handoff

0. Validate the existing external Developer ID provisioning profile with the exact
   certificate selected by `NEANTIK_SIGNING_IDENTITY`; the local gate must
   confirm that `DeveloperCertificates` binding before any expensive build.
   A profile name containing an older version does not require regeneration;
   verify its expiry, app/team entitlements and certificate binding instead.
1. Assign a version and build newer than `0.3.25 (28)`; current source candidate
   is `0.4.0 (29)`.
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
6. Upload exact assets to a draft GitHub release, download and compare SHA-256
   and Gatekeeper results before making it public. Re-download after publication
   and recheck the public assets. Never replace assets under an existing version.
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
