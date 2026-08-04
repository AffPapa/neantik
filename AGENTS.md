# NeAntik agent instructions

- NeAntik uses Direct Distribution only. Never use App Store Connect or the
  Mac App Store.
- For Swift/UI iteration use `./Develop-NeAntik.command`; it is isolated from
  production profiles and release state. Use `./Release-NeAntik.command` only
  for one exact final candidate after local tests are green.
- Public release truth is GitHub `AffPapa/neantik` plus
  `https://affpapa.org/neantik`.
- Before release or site work run:

  ```bash
  ./scripts/neantik-affpapa-release doctor
  ```

- Do not use raw SSH, SCP, SFTP, rsync, or edit the live server directly.
  Both Codex and Claude must use the same least-privilege client:

  ```bash
  ./scripts/neantik-affpapa-release publish /absolute/path/to/release-dir
  ```

- A release directory must contain exactly the six files documented in
  `ops/affpapa/README.md`.
- `publish` validates locally, verifies notarized Apple artifacts, uploads only
  allowlisted files, validates staging, deploys atomically, and verifies live.
- The deploy key and pinned host key remain outside Git under
  `../.secrets/ssh/` relative to this checkout. Never print or copy the private
  key.
- The restricted server identity must not gain shell, PTY, SFTP/SCP, port
  forwarding, or permission to upload executable PHP/Blade files.
