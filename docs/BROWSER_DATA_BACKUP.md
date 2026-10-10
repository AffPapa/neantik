# BrowserData backup: development status

This operation is under development for the major candidate. It is not enabled
as a published GUI or MCP capability. Configuration export and metadata snapshots
remain separate operations and do not contain BrowserData.

## Implemented and tested core

- Closed-profile export into a versioned AES-GCM authenticated archive with a
  bounded manifest, per-file hashes, authenticated footer and strict EOF.
- Password verification and safe private extraction before replacing live data.
- Same-profile restore preserves identity, proxy and organization; only the
  metadata revision and update time change.
- A private, bounded, immutable journal pins the original and reconstructed
  directory inodes, metadata images, hashes and runtime compatibility context.
- Both metadata documents are fenced before the directory swap. Pending previous
  is written first. A durable irreversible decision precedes readable next data.
- Recovery before the decision restores BrowserData first, then original main
  and original previous. Recovery after the decision can only roll forward.
- Every publication admits pinned metadata objects and bytes. Unknown edits,
  replaced inodes, corrupt journals and unsupported contexts are preserved and
  block ordinary profile operations.
- Finalized journals and displaced BrowserData are retained privately. Automatic
  retention cleanup and a user-facing rollback operation are not yet implemented.

## Actual runtime evidence

The signed research Chromium 156.0.8078.12 was launched headed four times on
an own temporary profile. Cookies, LocalStorage and IndexedDB were written,
exported, changed, restored atomically and read again from the same BrowserData.
An interrupted publication was recovered in a fresh manager test process,
preserving the changed values. Successful restore returned the original values.
Revision advanced; identity and proxy did not change.
The test used Chromium's mock Keychain and never used a real account.

This does not demonstrate cross-Mac migration of OS-encrypted secrets, saved
passwords, a completed GUI workflow, or qualification of a
notarized final application. Those acceptance gates remain open.

The actual three-tab session was also exported, changed, rolled back and
restored. Existing restored targets were activated and their execution contexts,
documents and own-fixture nonces observed. No replacement navigation, reload or
target creation was used to prove the result. This research test explicitly used
`--restore-last-session`; automatic tab restoration by the normal manager remains
an independent product gate. The report oracle rejects 44 broken controls.

## Required integration boundaries

The filesystem worker is not process authority. Its caller must retain a verified
stopped-profile process lease and then acquire the metadata guard, in that order.
Recovery must verify the live and retained directories after a crash. Ordinary
Store, import, launch, cached refresh, directory creation and stdio reads refuse
while an active journal exists; they must never auto-repair pending metadata.

Two pending documents protect reviewed readers with mandatory persisted launch
validation. Earlier already-running managers with cached launch snapshots can
bypass that fence after a crash releases flock. They must be proven closed before
restore is exposed to users. The pending format alone is not a guarantee for all
historical versions.

## Product service integration (development)

The service now binds export, restore and pending recovery to a borrowed
stopped-profile process lease. It refuses another known same-user NeAntik/NeVision
GUI or stdio manager, unknown process inspection, stale revision and mismatched
profile/staging scope. Multiple windows of the same PID remain supported.

Compatibility uses the current disk-decoded identity, fresh runtime version,
architecture, signature and payload hashes. Runtime and local scope are checked
again at durable mutation boundaries. Changes preserve the active journal and
require fresh recovery; they never silently remove the fence or select rollback
after an irreversible decision.

The dedicated scope backend is immutable, non-synchronizing and device-only.
Only export can create it; restore cannot regenerate a missing/corrupt key.
Concurrent creation reads the persisted winner. Signed-manager access to the
Data Protection Keychain still requires its own real qualification before GUI
enablement. Unit and runtime fixtures use injected memory/private fixture stores
and do not prove that production Keychain gate.

The export/restore and startup recovery sheets are currently available only to
explicit disposable DEBUG fixtures with a development opt-in. The types also
compile in Release; their production UI entry points are disabled. Startup recovery authenticates the existing journal and obtains fresh
authority; it does not rely on selecting a profile from pending metadata. GUI
and keyboard verification remain open because the native CUA pipe failed.

Apple API references: [Data Protection Keychain](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain),
[device-only accessibility](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly).
