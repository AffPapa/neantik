# NeAntik source-to-site handoff

This document is for the operator or AI that performs the separate Direct
binary release and AffPapa website publication after the source PR is merged.

## Current source state

- Branch prepared by this audit: `codex/neantik-zero-config-workspace`.
- Public binary truth remains `0.3.19 (22)` until a new signed and notarized
  GitHub Release exists.
- `CHANGELOG.md` uses `Unreleased`; no version/build bump, tag, GitHub Release,
  Developer ID signature, notarization, stapling or site deploy belongs to the
  source-only PR.
- The exact merge commit, not a mutable branch name, must become the release
  source input.

## User-visible changes to carry into release copy

- One-window native profile workspace with a one-click first profile.
- One-level folders, colored tags, pin/archive/clone and searchable plaintext
  profile notes.
- Paste-first atomic bulk proxy import plus optional bounded proxy health
  checks and automatic fresh preparation before every proxied launch.
- Progressive environment details for route, fingerprint, WebRTC, QUIC/DNS
  and proxy-derived geolocation.
- More native macOS keyboard and VoiceOver behavior.
- Unified UTF-8 persistence limits, a 10,000-profile scale boundary and
  crash-recoverable pruning of stale proxy-health metadata.

Do not claim universal anonymity, undetectability, CAPTCHA/ban bypass or an
observed Chromium HTTP/DNS route. The product intentionally makes none of
those claims.

## Separate Direct release sequence

1. Check out the exact merged commit in a clean worktree. Confirm no generated
   `.build`, `dist`, private evidence or secrets are tracked.
2. Assign the next version/build deliberately and move the `Unreleased`
   changelog content to a `Direct VERSION (BUILD)` heading. Update the released
   README section only when the binary is actually published.
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
   the site still presents `0.3.19` if the new binary publication did not
   complete atomically.

## Stop rules

- No signed/notarized exact artifacts: development news may be published, but
  download links and the public version must remain `0.3.19 (22)`.
- Any mismatch between the merged commit, candidate manifest, evidence,
  notarization receipt, checksums, GitHub assets or AffPapa assets: stop and
  preserve the previous public release.
- Never place certificate identities, notary profiles, deploy keys, proxy
  credentials or raw fingerprint evidence in Git, prompts, logs or the site.
