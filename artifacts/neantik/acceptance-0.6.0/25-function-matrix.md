# NeAntik 0.6 acceptance matrix

Audited 2026-09-12 against the current source tree and SwiftUI entry points.

| # | Function | Status | Evidence / gap |
|---:|---|---|---|
| 1 | Profile creation wizard | PARTIAL | `ProfileCreationWizard` + tests; primary UI still opens `ProfileEditorView`, so the reduced purpose-first flow is not yet the default. |
| 2 | Identity Contract | PASS (surface) | `IdentityContract` derives the environment tuple and the inspector now shows language, timezone, WebRTC and device tuple; launch enforcement still reports only readiness issues. |
| 3 | Readiness center | PARTIAL | `ProfileReadinessReport` is now visible in the profile inspector; proxy/runtime live remediation remains outside this panel. |
| 4 | Proxy preflight | PASS | Existing coordinator/tester launch gate. |
| 5 | Stability history | PASS | Per-profile bounded history with drift flags and a compact inspector surface explaining proxy, cookies, tabs and fingerprint changes. |
| 6 | Crash recovery | PASS | Existing recovery and tab restoration flow. |
| 7 | Atomic snapshots | PASS | Snapshot is captured before launch; inspector lists recent snapshots and restores atomically with rollback. |
| 8 | Concurrent-open lock | PASS | Existing profile lock/process guard. |
| 9 | Chromium compatibility | PARTIAL | Checker exists; update/rollback flow not wired. |
| 10 | Extension risk surface | PASS | Bounded local manifest scanner and inspector inventory broad host/sensitive permissions without exposing manifest contents. |
| 11 | Encrypted local backup | PASS (export) | AES-GCM/HKDF archive export is wired to the inspector; proxy credentials stay in Keychain. Encrypted archive import UI remains a follow-up. |
| 12 | Privacy-safe diagnostics | PARTIAL | Privacy-safe primitives exist; no dedicated export package flow. |
| 13 | Command palette | PASS | SwiftUI palette with search, Enter/Escape, menu entry and ⌘⇧P shortcut. |
| 14 | Semantic search | PASS | Catalog search uses the bounded `ProfileSearchQuery` document covering names, notes, tags, routes and folders; ranking behavior is covered by tests. |
| 15 | Automatic folders/tags | PARTIAL | Suggestions model/tests; not automatically applied in catalog. |
| 16 | Clone preview | PASS | Preview sheet lists cookies, tabs, startup tabs, proxy, fingerprint and extensions before cloning. |
| 17 | Clean launch | PASS | Profile action calls `launch(profile, purpose: .clean)` and uses an isolated temporary data directory. |
| 18 | Startup tabs | PASS | Persisted on `BrowserProfile`; launch builder opens them in order and disables stale-session restore. |
| 19 | Reopen last profile | PASS | Existing shortcut/recent-profile flow. |
| 20 | Activity log | PARTIAL | Bounded local store + launch integration + tests; compact history UI remains. |
| 21 | Memory saving | PASS | Policy selects inactive profiles under pressure and BrowserProcessManager applies reversible suspend/resume only to manager-owned processes; cycle is tested. |
| 22 | Human-readable errors | PASS | Existing typed launch/proxy/storage error copy. |
| 23 | Cookie drag-and-drop | PARTIAL | Dropzone, file picker, validation and preview are live; applying into Chromium encrypted DB remains gated on authenticated browser protocol. |
| 24 | On-demand fingerprint check | PASS | Existing fingerprint audit flow. |
| 25 | Runtime version check | PASS | Existing startup/runtime preflight. |

## Release decision

Do not claim all 25 are complete. Current code is suitable for a staged engineering build, but a new public binary requires wiring the PARTIAL/MISSING items above and then repeating signing, notarization, Gatekeeper, GitHub, and site verification.
