# NeAntik agent instructions

- Direct Distribution only: GitHub `AffPapa/neantik` and browser.free via the
  existing Sites project. Preserve Developer ID, notarization, stapling,
  Gatekeeper, immutable assets and rollback. Never use App Store Connect.
- AffPapa is excluded by the user. Only after new explicit authorization read
  `ops/affpapa/README.md` and use its restricted client. Never use raw SSH,
  SCP/SFTP/rsync or direct server edits; missing AffPapa keys do not block us.
- Swift iteration: `./Develop-NeAntik.command` with disposable fixtures;
  targeted tests: `python3 -B scripts/test-manager-fast.py --suite NameTests`
  (repeat suites). Use the project's developer-dir resolver, local caches,
  jobs2 and serial tests. Do not change inputs of a running build.
- Python contracts: set `PYTHONDONTWRITEBYTECODE=1` as well as `python3 -B`;
  `-B` alone does not protect subprocess imports. Preserve and quarantine only
  diagnosed own-generated source bytecode; never clean shared build caches.
- Substantive manager/workflow changes use
  `.agents/skills/neantik-development/SKILL.md`; the read-only check planner
  explains selection. Unknown/shared inputs require full regression. Small
  prose fixes need relevant diff/claim/link review. Planning is never PASS.
- Read one CURRENT linked by the parent `docs/PROJECT_CONTEXT_INDEX.md`.
  Historical receipts answer specific questions. App/runtime/Site/hosted
  evidence are separate; repeat a gate only for changed inputs or a failure.
- Finish authorized local work to its acceptance gate. Diagnose two identical
  failures before retrying. Preserve real profiles, BrowserData and Keychain;
  QA uses owned synthetic roots and mock Keychain where required. Never put
  credentials/private traces in output, source, prompts or public artifacts.
- System Extensions: never repair `/Library/SystemExtensions` permissions or
  files. Use the framework/Finder lifecycle and the actual registered container;
  keep its file identity at the canonical path until deactivation completes.
  Preserve rollback by copying. Treat a required reboot as an external gate.
