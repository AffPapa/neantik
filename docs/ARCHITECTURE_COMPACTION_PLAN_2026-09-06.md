# Large architecture compaction

User approved a substantial rewrite after release0.3.24. The working baseline
is f282424438d9b057823d56060ed1edfe85c8a08a:37889ownproduction Swift lines.
The preceding baseline was37924. Target30% must not be manufactured by moving
code out of Sources, deleting safeguards/tests, minifying or counting Chromium.

Three independent read-only audits selected the following first wave. Estimates
are hypotheses, not shipped savings. Test730/76suites baseline passed before edits.

| Slice | Owner | Required invariants |
| --- | --- | --- |
| Process lifecycle records and observation ownership | BrowserProcessManager | PID/birth/lease identity, generations, managed/external/recovery distinction, ordinary/force stop, stale completion |
| Shared profile actions and one editor draft | ProfileCommands, ContentView, ProfileEditorView | Local menu shortcuts, modal guards, contextual profile identity, Keychain keepExisting, dirty/import/focus state |
| Shared secure descriptor operations | AppPaths, ProxyHealth, FingerprintEvidenceRecoveryStore | No-follow, close-on-exec, EINTR, file identity/link count/mode, anchored openat, caller-specific errors |

Subsequent audit-backed candidates: typed recoverable document transactions,
canonical evidence JSON parser, native disclosure grouping, typed workspace
sheet routing and observation projections. These are not automatically accepted:
each needs behavior proof and measured net reduction including its new helpers.

After each wave: targeted regression tests, complete Swift/Python/source gates,
ARM64 build and isolated Dev UI/process checks. Never run concurrent compilers
against a changing source tree. Test additions must remain enabled in CI shards.
Revisit source/complexity metrics before taking the next wave; state migration,
privacy and evidence equivalence take precedence over the line target.

After verified implementation, assign next version/build, update changelog/map,
merge after checks and release one exact merged candidate through the normal
Direct gates. Existing0.3.24 ZIP/DMG remain immutable throughout development.
