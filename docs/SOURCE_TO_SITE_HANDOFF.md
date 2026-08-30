# NeAntik source-to-site handoff

This document is for the operator or AI that performs the separate Direct
binary release and AffPapa website publication after the source PR is merged.

## Current source state

- Branch prepared by this audit: `codex/neantik-unified-minimal-ux`.
- Source candidate: `0.3.22 (25)`. Public binary truth remains `0.3.21 (24)`
  until a new signed and notarized
  GitHub Release exists.
- `CHANGELOG.md`, `Info.plist` and README already identify the source candidate;
  no tag, GitHub Release, Developer ID signature, notarization, stapling or
  site deploy belongs to the source PR.
- The exact merge commit, not a mutable branch name, must become the release
  source input.

## User-visible changes to carry into release copy

- Compact `Вид` menu with deterministic sorting and route filters.
- Pinned profiles remain first in every sort mode.
- Search can match a safe displayed proxy type and endpoint, never credentials
  or Keychain data.
- Saving a profile preserves a compatible route filter and clears an
  incompatible one so the saved profile stays visible.
- Native 820 × 560 behavior, explicit VoiceOver removal labels and no new UI
  dependencies, images, background requests or Chromium runtime changes.

Do not claim universal anonymity, undetectability, CAPTCHA/ban bypass or an
observed Chromium HTTP/DNS route. The product intentionally makes none of
those claims.

## Separate Direct release sequence

1. Check out the exact merged commit in a clean worktree. Confirm no generated
   `.build`, `dist`, private evidence or secrets are tracked.
2. Confirm that candidate `0.3.22 (25)` is still the deliberate next
   version/build and that README and the `Direct 0.3.22 (25)` changelog section
   match the exact merged commit. Do not rewrite public download links yet.
3. Run the full source gates, explicit ARM64 release build and live manager plus
   browser-mode fingerprint integrations again.
4. Run `./scripts/neantik-affpapa-release doctor` before any release or site
   work. Stop on any failure.
5. Use `./Release-NeAntik.command` only for the one exact final candidate. It
   must complete fresh candidate-bound A -> B -> A evidence, Developer ID,
   Apple notarization, stapling, Gatekeeper and final ZIP/DMG verification.
6. Publish the immutable ZIP/DMG and required sidecars to GitHub Releases. Do
   not use GitHub's Code -> Download ZIP as a browser download.
7. Prepare the exact six-file website release directory documented in
   `ops/affpapa/README.md`, then publish only through:

   ```bash
   ./scripts/neantik-affpapa-release publish /absolute/path/to/release-dir
   ```

8. Never use raw SSH/SCP/SFTP/rsync or hand-edit the live server. Require the
   client's staging validation, atomic switch and live hosted-download check.
9. Re-download public artifacts, compare SHA-256, verify Gatekeeper and confirm
   the site still presents `0.3.21` if the new binary publication did not
   complete atomically.

## Stop rules

- No signed/notarized exact artifacts: development news may be published, but
  download links and the public version must remain `0.3.21 (24)`.
- Any mismatch between the merged commit, candidate manifest, evidence,
  notarization receipt, checksums, GitHub assets or AffPapa assets: stop and
  preserve the previous public release.
- Never place certificate identities, notary profiles, deploy keys, proxy
  credentials or raw fingerprint evidence in Git, prompts, logs or the site.
