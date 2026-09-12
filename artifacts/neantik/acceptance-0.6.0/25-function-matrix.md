# NeAntik 0.6.1 acceptance matrix

Audited 2026-09-12 against the current source tree and SwiftUI entry points.

| # | Function | Status | Evidence / gap |
|---:|---|---|---|
| 1 | Profile creation wizard | PARTIAL | `ProfileCreationWizard` + tests; the editor remains the primary creation surface, so the reduced purpose-first flow is not yet the default. |
| 2 | Identity Contract | PASS (surface) | `IdentityContract` derives the environment tuple and the inspector now shows language, timezone, WebRTC and device tuple; launch enforcement still reports only readiness issues. |
| 3 | Readiness center | PASS | `ProfileReadinessReport` is visible in the inspector and real launch gate blocks actionable proxy/runtime problems with human-readable reasons. |
| 4 | Proxy preflight | PASS | Existing coordinator/tester launch gate. |
| 5 | Stability history | PASS | Per-profile bounded history with drift flags and a compact inspector surface explaining proxy, cookies, tabs and fingerprint changes. |
| 6 | Crash recovery | PASS | Existing recovery and tab restoration flow. |
| 7 | Atomic snapshots | PASS | Snapshot is captured before launch; inspector lists recent snapshots and restores atomically with rollback. |
| 8 | Concurrent-open lock | PASS | Existing profile lock/process guard. |
| 9 | Chromium compatibility | PARTIAL | Compatibility decision and atomic snapshot rollback primitives exist; automatic runtime update orchestration remains outside the current release flow. |
| 10 | Extension risk surface | PASS | Bounded local manifest scanner and inspector inventory broad host/sensitive permissions without exposing manifest contents. |
| 11 | Encrypted local backup | PASS (export) | AES-GCM/HKDF archive export is wired to the inspector; proxy credentials stay in Keychain. Encrypted archive import UI remains a follow-up. |
| 12 | Privacy-safe diagnostics | PASS | Dedicated JSON export is wired to readiness UI and test-verified to exclude paths, profile data, proxy values, cookies and secrets. |
| 13 | Command palette | PASS | SwiftUI palette with search, Enter/Escape, menu entry and ⌘⇧P shortcut. |
| 14 | Semantic search | PASS | Catalog search uses the bounded `ProfileSearchQuery` document covering names, notes, tags, routes and folders; ranking behavior is covered by tests. |
| 15 | Automatic folders/tags | PASS | Local smart collections for proxy/tag/launch state are shown in the catalog and reuse the existing search DSL without mutating profiles. |
| 16 | Clone preview | PASS | Preview sheet lists cookies, tabs, startup tabs, proxy, fingerprint and extensions before cloning. |
| 17 | Clean launch | PASS | Profile action calls `launch(profile, purpose: .clean)` and uses an isolated temporary data directory. |
| 18 | Startup tabs | PASS | Persisted on `BrowserProfile`; launch builder opens them in order and disables stale-session restore. |
| 19 | Reopen last profile | PASS | Existing shortcut/recent-profile flow. |
| 20 | Activity log | PASS | Bounded local journal is integrated with launch events and shown as a compact recent-events inspector section. |
| 21 | Memory saving | PASS | Policy selects inactive profiles under pressure and BrowserProcessManager applies reversible suspend/resume only to manager-owned processes; cycle is tested. |
| 22 | Human-readable errors | PASS | Existing typed launch/proxy/storage error copy. |
| 23 | Cookie drag-and-drop | PARTIAL | Dropzone, file picker, validation and preview are live; applying into Chromium encrypted DB remains gated on authenticated browser protocol. |
| 24 | On-demand fingerprint check | PASS | Existing fingerprint audit flow. |
| 25 | Runtime version check | PASS | Existing startup/runtime preflight. |

## Release decision

All implemented items are now wired and test-covered. Remaining release caveats are explicit: the purpose-first wizard is not yet the default editor, Chromium update orchestration is still manual, and cookie import stages validated data without writing Chromium's encrypted database. Public release still requires a valid Developer ID certificate, notarization, Gatekeeper, GitHub asset publication and hosted site verification.
