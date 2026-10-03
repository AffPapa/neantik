# Manager recovery and same-Mac backup gate

Scope: manager-only improvements, 3 October 2026. This is a design, not a shipped session-backup capability.

## G: deletion recovery

Current deletion is an existing transaction: verified process absence, deletion tombstone, directory moved to macOS Trash, metadata commit, credential-cleanup authorization/marker, Keychain password deletion, retry after restart. Keep this ordering. Moving a trashed directory back does not recreate metadata or already-deleted credentials.

This slice keeps physical deletion irreversible in the manager and explicitly warns about Keychain password removal. Archive remains the reversible choice. No credential-retention period, Undo delete, automatic Trash scan or hidden secret copy is introduced.

Future recovery requires a separate consented retention contract, bounded quota/expiry and explicit accounting for credentials that cannot be recovered. Acceptance: interrupted deletion/recovery at each phase, external Trash emptying, missing secrets, duplicate identity, stale process lease, cross-manager attempts and rollback failure all produce one unambiguous state. Do not claim recovery of deleted secrets.

## H: encrypted local backup

Deferred: metadata snapshots and configuration exports intentionally create independent identities and omit BrowserData. They cannot satisfy same-profile restore. A complete encrypted backup would add a sensitive archive and a durable two-phase recovery protocol; this is outside the safe A–F slice.

Proposed contract:

1. Acquire the existing profile operation guard; verify stopped main process and helpers, inspect BrowserData locks, fail closed if inspection is unknown. Reserve against launch until checkpoint completes.
2. Preflight explicit quota, estimated size and free space for staging plus rollback. Enumerate regular files with bounded count/bytes; reject symlinks/hardlink aliases, traversal and unknown storage layouts.
3. Write an authenticated encrypted archive to private staging, binding schema, same profile UUID/identity, exact runtime storage contract, inventory, lengths and hashes. No global login.keychain, private keys or third-party upload. Cancel deletes sensitive staging.
4. Restore only the same stopped profile on the same Mac. Reject authentication failures, unsupported schema/runtime storage contracts, altered inventory, wrong UUID, oversized entries and escaping paths before changing live data.
5. Validate staged content; atomically exchange profile directory with retained rollback. A fsynced durable transaction record resolves every interrupted phase after restart. Publish UI only after complete commit; failure preserves the previous usable profile.
6. Prove exact-runtime synthetic persistent cookie, session-cookie semantics, localStorage and IndexedDB across clean stop, manager restart, controlled browser crash and backup/restore. Establish compatibility with existing same-Mac Chromium storage encryption without exporting OS secrets.

Required fault matrix: cancellation, ENOSPC, EACCES, corrupt archive/tag/manifest, missing key, each durable write/rename boundary, process starts mid-checkpoint, second manager, interruption between filesystem commit and UI publication, rollback failure and restart. A passing archive round-trip alone is insufficient. Cross-Mac portability is excluded.

## Observed session semantics

The exact M154 .93 localhost fixture (3 October) retains persistent cookies, localStorage and IndexedDB across graceful close/relaunch, manager reconciliation while browser is running, and a subsequent controlled browser crash. Session cookies expire after a clean browser shutdown under the existing startup policy. This is not a promise of full authenticated-session restoration. The fixture exposed loss of freshly buffered cookie/localStorage values when manager Stop used SIGTERM; manager-only graceful quit addresses that separate defect. Abrupt crashes may still discard writes not yet committed by Chromium.
