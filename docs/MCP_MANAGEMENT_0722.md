# MCP management candidate 0.7.22 / 85

This manager-only slice retains qualified Chromium 154.0.8037.98 and the existing fingerprint/provenance contract. No Chromium source, patches, build configuration or launch policy was changed.

## Implemented

- 16 tools including stable paginated reads, profile get/create/update/duplicate, proxy settings/check, folder/project organization, move, normal start/status and session-owned graceful stop.
- Explicit management permission in stdio args and copied JSON/TOML, server-side enforcement, initialization handshake, bounded serial queue, cancellation and EOF handling.
- UUID selection, decimal-string profile revisions, organization revisions checked inside the canonical lock; no stale overwrites.
- Canonical Keychain transaction compensation and stopped-profile ownership guard for configuration changes. Secret input never appears in tool results.
- Shared GUI/MCP proxy observation commit; fresh context preparation before proxy launch; manual check does not rewrite identity; no direct fallback.
- GUI change detection and off-MainActor parsing; drafts retain their original revision and refuse stale save. Import/refresh admission now scopes to the canonical workspace rather than blocking unrelated workspaces.
- Read mode uses strict current metadata and never repairs a corrupt primary or presents missing profiles metadata as a trustworthy empty workspace.
- Searchable in-app help, permission selector, FAQ, docs and matching browser.free guide.

## Verification

731 Swift tests in 82 suites; 29 public-artifact privacy tests; 27 site tests.
Actual Dev stdio, 16-tool discovery, create/edit/proxy/duplicate/folders, real normal Chromium launch, running-edit denial, observed graceful stop and reconnect persistence passed.

Synthetic loopback fixture confirmed cookie/localStorage/IndexedDB persistence and separation of two profiles. Browser survives EOF; new session observes externalManualOnly, refuses unowned stop and observes manual graceful close.

Stalled synthetic proxy probe cancellation returned in <5 seconds; EOF exited in <5 seconds; profile metadata unchanged and no browser launched. No real proxy account was needed for this slice.

Actual GUI config initialized the real server and created a visible profile. Open manager refreshed external changes without restart; external rename appeared while a different unsaved editor draft stayed intact. Stale save showed the revision-conflict error. Keyboard Tab/Escape/Return and unsaved-change confirmation exercised on synthetic data.

Counts are source/Dev acceptance. Developer ID, notarization, stapling, Gatekeeper, payload provenance and hosted-byte checks are separate release gates, recorded in release artifacts and the task delivery report. Third-party AI-client behavior is not inferred from a configuration example.

## Boundaries and next backlog

- Current management changes stopped profiles; running/uncertain ownership is fail-closed.
- Stop covers the owning live MCP session; cross-session graceful IPC needs a separate authenticated ownership design. No unsafe SIGTERM workaround.
- Keychain + metadata compensate thrown errors; a durable cross-resource intent journal and process-kill injection are needed before promising crash atomicity.
- Create/duplicate have no automatic idempotent retry. Bulk atomic metadata edits need their own bounded transaction contract.
- Projects are folders, without nested hierarchy. Future template/saved-view tools should reuse ManagerLibrary revisions.
- No profile deletion, BrowserData/cookie extraction, full backup, arbitrary JS/shell/flags or DOM automation. Browser automation requires a separate explicit capability/consent design.
- Authenticated SOCKS5 remains unsupported by the existing Chromium; use supported HTTP proxy or unauthenticated SOCKS5.
- ChatGPT/Grok web need a separate bridge; local stdio is not a hosted MCP endpoint.
- AI clients may retain/send entered credentials and configured URLs; NeAntik returns no proxy credentials but configured startURL is deliberately part of profile_get. Avoid URL secrets.
