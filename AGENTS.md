# NeAntik agent instructions

- NeAntik uses Direct Distribution only. Never use App Store Connect or the
  Mac App Store.
- For Swift/UI iteration use `./Develop-NeAntik.command`; it is isolated from
  production profiles and release state. Use `./Release-NeAntik.command` only
  for one exact final candidate after local tests are green.
- Authorized publication scope is GitHub `AffPapa/neantik` and
  `https://browser.free` through its existing OpenAI Sites project. Follow the
  current Direct release preflight and Sites workflow for these channels.
- The user explicitly excluded `affpapa.org/neantik` on 2026-10-12 and updates
  it manually. Do not run its doctor, seek its deploy key, or publish there.
  Missing AffPapa credentials do not block GitHub or browser.free.
- The retained restricted AffPapa client below is legacy documentation for a
  future explicitly authorized AffPapa task, not the current release workflow.

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
