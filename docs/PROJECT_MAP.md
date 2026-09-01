# NeAntik project map

Current source map: 2026-09-02. This document is the current routing source for
product and code work. The older v4 documents remain dated design records.

## Release truth and boundary

- Latest immutable GitHub release: `v0.3.23`, version/build `0.3.23 (26)`.
- Current source candidate: `0.3.24 (27)`; it is not a public binary release
  until the exact merged commit passes the complete Direct gate.
- Exact released source commit:
  `fdc520391c58a76622936519ca38b382f629fc47`.
- Runtime: Chromium `152.0.7977.64`, ARM64, Metal.
- GitHub assets: notarized ZIP and DMG with SHA-256 sidecars; all four assets
  were re-downloaded and their hashes were verified before publication.
- A later source commit is not a release. A new binary needs a new
  version/build, exact merged commit, Developer ID, notarization, stapling,
  Gatekeeper, immutable assets and re-downloaded SHA-256 evidence.
- The public website is synchronized read-only from GitHub release metadata.
  Its page and `release.json` show `0.3.23 (26)` and link directly to the exact
  GitHub assets; AffPapa keeps no second binary copy. The legacy restricted
  wrapper remains fail-closed without its dedicated deploy key and was not
  bypassed with another key or manual server access.

## Product contract

The frequent path is deliberately short:

> find or create a profile -> confirm route and state -> launch or stop

NeAntik is a native, local, Apple-Silicon-only manager. Profiles, organization
and browser data remain local. Proxy passwords remain in Keychain. The product
does not add cloud accounts, teams, RPA, proxy sales, telemetry, a writable
network API, arbitrary low-level fingerprint sliders or secret export.
The Direct manager contains no telemetry client, update-manifest prototype or
external runtime preference: it launches only its declared embedded runtime,
and updates remain immutable manual GitHub releases.

## Source ownership

| Surface | Owner files | Contract |
| --- | --- | --- |
| App shell and orchestration | `ContentView.swift`, `ContentViewState.swift`, `NeAntikApp.swift` | Compose state and commands; keep request/cache state out of the view body and do not invent domain policy there |
| Keyboard and local UI preferences | `ProfileCommands.swift`, `NeAntikShortcutCatalog.swift`, `WorkspacePreferenceStore.swift`, `NeAntikSettingsView.swift` | Fixed menu-backed shortcuts, modal-safe focused commands and density-only local persistence; no global hooks or hidden destructive shortcuts |
| Workspace rows and inspector | `ProfileWorkspaceViews.swift`, `ProfileRowPresentation.swift`, `ProfileBatchActions.swift` | List-first, 820x560 minimum, text plus symbol, contextual actions and directly visible note editing |
| Query and organization | `ProfileListProjection.swift`, `WorkspaceQueryState.swift`, `ProfileTagEditor.swift` | Linear deterministic projection; no network or secret search |
| Profiles and persistence | `Models.swift`, `ProfileStore.swift`, `AppPaths.swift` | Bounded validated metadata, atomic writes, safe local filesystem handling |
| Profile editing | `ProfileEditorView.swift`, `ProfileNoteEditorView.swift`, `ProfileEditorProcessPolicy.swift` | Simple fields first; notes use a dedicated editor; browser/proxy edits respect running-state rules |
| Process lifecycle | `BrowserProcessManager.swift`, `BrowserProcessInventory.swift`, `BrowserProcessLifecyclePresentation.swift`, `RunningProfilesStrip.swift` | Exact ownership, fail-closed reconciliation, explicit Closing and confirmed Force Stop |
| Runtime and launch | `BrowserLaunchBuilder.swift`, `BrowserLaunchStagedPreflight.swift`, `BrowserRuntime*.swift` | Embedded signed ARM64 runtime, staged fail-closed launch, no credential CLI arguments |
| Proxy | `ProxyTester.swift`, `ProxyHealth*.swift`, `BulkProxyImport.swift`, `ProxyImportParser.swift` | Local parsing, bounded concurrency, fresh preparation before proxied launch |
| Fingerprint evidence | `FingerprintAudit*.swift`, `FingerprintEvidence*.swift`, `SecureEnclaveFingerprintEvidenceSigner.swift` | Release-only strict evidence is separate from ordinary diagnostics |
| Readiness and notices | `WorkspaceReadiness*.swift`, `UserNotice.swift` | Redacted, actionable, semantically honest local diagnostics |
| Release operations | `Release-NeAntik.command`, `scripts/prepare-direct-*.sh`, `scripts/verify-direct-provisioning-profile.py`, `scripts/verify-active-gui-session-unlocked.py`, `scripts/notarize_direct_transaction.py`, `scripts/neantik-affpapa-release` | Exact candidate only; auto-select one profile-authorized certificate or fail; require an unlocked GUI session for Secure Enclave enrollment; optional explicit notary Keychain must be owner-only; GitHub doctor is server-free, site publish is explicit; never App Store Connect |
| CI and repository security | `.github/workflows/ci.yml`, `.github/workflows/codeql.yml`, `.github/dependabot.yml`, `scripts/audit-git-history-secrets.py` | SHA-pinned Actions, least privilege, Swift/Python CodeQL, dependency updates and separate current-tree/history/GitHub secret gates |

## Current capability state

### Delivered

- one list-first workspace with adaptive compact/wide rows and optional inspector;
- folders, color tags, notes, pin/archive and deterministic structured search;
- Running, Attention and Never launched computed views with counts;
- contextual multi-selection, atomic folder/tag/pin/archive changes and Undo;
- Direct/HTTP/HTTPS/SOCKS5-without-credentials routes, Keychain passwords,
  bulk import and bounded bulk checks;
- fresh proxy preparation before launch and route/environment diagnostics;
- staged launch preflight, one-profile ownership, crash reconciliation,
  bounded concurrent launches, Closing/Force Stop/completed states;
- on-demand profile storage measurement, readiness center and redacted copy;
- cold/warm manager measurements, source/installed-size budgets and responsive
  light/dark render gates.

### Delivered in 0.3.23

- gives readiness and proxy results distinct success/info/warning/failure
  semantics instead of styling every message as success;
- collapses permission help so actual readiness rows remain above the fold;
- keeps Start/Stop on the left in compact and wide rows;
- simplifies the visible search prompt and names secondary list actions;
- edits notes in a dedicated small sheet without opening fingerprint/proxy
  configuration;
- makes Force Stop a visible destructive text action while retaining the
  separate confirmation.
- disables focused workspace/profile commands under every modal, removes the
  batch Undo shortcut that conflicted with text editing, and centralizes fixed
  Start/Stop, inspector, edit and note shortcuts in the native menu;
- adds the native Settings window for one justified persistent preference —
  row density — plus the shared shortcut reference. Shortcuts are deliberately
  fixed and local to the active app.
- keeps the primary Create button on the full editor while its disclosure menu
  can create and open a permanent Direct profile with a readable unique name,
  fresh session and fresh identity;
- exposes the existing process-safe window focus operation from the selected
  profile menu and `Shift-Command-Return`, without changing Stop or Force Stop.
- removes the dormant telemetry client, offline update-manifest prototype and
  historical external Chrome/Cloak selector; absence-based privacy and release
  gates now reject their source files and configuration keys.
- moves ContentView-only request, presentation and list-cache state into a
  separate side-effect-free owner, then lowers the main view budget to
  3,800 lines and 145,000 bytes;
- adds a redacted audit of every reachable Git blob and historical filename to
  the existing current-tree and GitHub secret-scanning gates.

### Prepared in source for 0.3.24

- removes the rotating hard-coded signing-certificate SHA-1 from the release
  launcher and selects exactly one installed Developer ID Application identity
  authorized by the external provisioning profile;
- compares profile, installed-identity and signed-app leaf certificates by
  SHA-256; the SHA-1 text emitted by macOS remains only an opaque identity
  selector and is never computed by NeAntik;
- accepts an optional owner-only `NEANTIK_NOTARY_KEYCHAIN` path in both ZIP and
  DMG notarization paths, without changing the normal login-Keychain default;
- rejects a locked or indeterminate active macOS session before costly release
  work and rechecks immediately before Secure Enclave enrollment;
- makes add/edit note a visible row action in the wide profile table while
  preserving the dedicated editor, keyboard command and compact action menu.

### Deferred with an explicit boundary

- P1: real human keyboard/VoiceOver acceptance pass on a signed candidate;
- P1: human acceptance of Quick Create naming and the running-window focus
  command on a signed candidate;
- P1: continue splitting `BrowserProcessManager` and `FingerprintAudit` only
  when a pure policy/presentation slice is independently testable; do not
  raise source budgets;
- P2: local safe templates, config-only import/export, bounded activity history
  or differential runtime updates only after their own privacy/threat model;
- rejected: cloud/team/billing, automation marketplace, proxy marketplace,
  mobile farms, dashboard/column builders and numerical anonymity scores.

## Verification map

| Change | Minimum gate |
| --- | --- |
| Pure presentation/copy | affected Swift suite, responsive render suite, source/privacy contracts |
| Profile/store/query | targeted suite, all Swift shards, Python contracts, ARM64 release build |
| Process/proxy/runtime | targeted race/integration tests, all shards, live manager/browser gate |
| Fingerprint/release | exact signed candidate, fresh A->B->A, notarization, stapling, Gatekeeper |
| Public release/site | immutable upload, six-file publish transaction when authorized, re-download and SHA-256/live verification |

## Research routing

- Current zero-base security, UX and release matrix with fifteen role prompts:
  [0.3.24 audit plan](NEANTIK_0324_ZERO_BASE_AUDIT_PLAN.md).
- Current 20-product comparison:
  [Competitor UX research](COMPETITOR_UX_RESEARCH_2026-09-01.md).
- Historical 75-candidate design record:
  [NeAntik v4 workspace](NEANTIK_V4_WORKSPACE.md).
- Historical 100-point release/readiness plan:
  [NeAntik v4 readiness plan](NEANTIK_V4_READINESS_PLAN.md).
- Product and non-goals: [Product](PRODUCT.md) and [Roadmap](ROADMAP.md).
- Release boundary: [Distribution](DISTRIBUTION.md).
