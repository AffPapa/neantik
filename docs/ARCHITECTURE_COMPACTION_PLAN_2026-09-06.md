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

## Measured checkpoint

Waves 1 and 2 are committed as `08ba140` and `d29f44e`. Together they remove
493 physical own-production Swift lines, including all new helper files.
Wave 2 passed 742 Swift tests in 76 suites, 684 Python tests (one skip), source
budgets and isolated Dev UI checks. Both live manager and fingerprint gates
passed on runtime 152.0.7977.82 outside the filesystem sandbox. These are local
engineering checks, not a signed-candidate publication receipt.

Wave 3 consolidates window-local operation claims and report projections and
repairs the note disclosure's accessible status. Typed sheet routing remains a
separate follow-up to avoid concurrent edits to ContentView. Measured savings
are much smaller than the 30% target; generic factories that obscure distinct
security policies and deleting tests to meet a numerical target are rejected.
