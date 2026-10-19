# BrowserData backup: capability and qualification

The published [Direct 0.8.14 (126)](../releases/v0.8.14.json) enables Chromium
BrowserData backup through its signed capability and matching macOS Developer
ID profile. Its downloaded Info.plist has `NeAntikBrowserDataBackupEnabled=true`;
that selection is not, by itself, evidence of a restore operation. The operation
targets a stopped profile and is not exposed through MCP. Configuration export
and metadata snapshots remain separate and do not contain BrowserData.

Earlier default packaging, including 0.7.34, left creation disabled. The
0.7.35/98 qualification candidate was an intermediate development step, not the
current public download. Missing explicit selection is still refused before
compilation or metadata replacement; legacy defaults do not silently gain access.

The archive contains BrowserData only. Restore preserves the profile's settings,
proxy, folder and identity. Compatibility requires the original profile, Mac,
local Keychain and exact runtime hashes. Cross-Mac encrypted-secret portability
is not supported. The previous release remains available for rollback.

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

Matching-profile Developer ID QA now also passes the actual GUI export,
wrong-password refusal, restore and keyboard workflow. Wrong passwords preserve
BrowserData and metadata; restore returns the original fixture and increments
its metadata revision. The save panel proposes one `.nabackup` extension.

These QA operations do not demonstrate cross-Mac migration of OS-encrypted
secrets or operation against production Keychain records. The exact final
bundle's signing/profile/notarization and downloaded launch gates passed
separately; they do not replace the isolated data-operation evidence.

The actual three-tab session was also exported, changed, rolled back and
restored. Existing restored targets were activated and their execution contexts,
documents and own-fixture nonces observed. No replacement navigation, reload or
target creation was used to prove the result. This research test explicitly used
`--restore-last-session`; automatic tab restoration by the normal manager remains
an independent product gate. The report oracle rejects 44 broken controls.

A newer control reproduced that `--new-window` plus a start URL does not reopen
saved tabs, even with Chromium's continue-session preference. Independent cloned
session controls pass with `--restore-last-session` and no explicit URL. Combining
restoration with an explicit URL accumulated extra tabs on repeat; that negative
receipt is retained.

Profiles now have an explicit startup mode. Legacy documents default to
`startPage`; `restoreSession` uses the start URL on the first launch and restores
without an extra URL thereafter. Matching signed QA uses arguments returned by
the compiled product builder: export -> changed tabs/data -> wrong-password and
tamper refusal -> restore -> repeated launch passes for live documents of every
saved tab plus cookies, LocalStorage and IndexedDB. Four headed launches and nine
scope/service phases passed; the owned key and browser processes were cleaned up.
Evidence: `signed-backup-startup-tabs-v6.json`. This is signed QA evidence, not
qualification of the final notarized product or of every other Mac.

## Required integration boundaries

A new actual downloaded135 manager Stop/reopen pair preserved synthetic cookie,
LocalStorage,strict-IDB and CacheStorage values without rewriting them;the new
session's SessionStorage was empty. Both main exits were normal/status0 and
own cleanup/temporary-authority retirement passed. Its intended beforeunload
timeout was not established:the browser exited before pending collection and
trusted/sticky activation had not been measured. The [retained INCOMPLETE and
future guard](evidence/manager-close-data-development.json) do not close timeout,
crash,WebKit or backup-restore qualification.

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

## Product service integration

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
Concurrent creation reads the persisted winner. A separate matching-profile
Developer ID QA application has qualified real Data Protection Keychain lifecycle,
full service restore and crash recovery with synthetic data. Production startup
does not create a key. Mock tests do not replace exact notarized candidate gates
or establish cross-Mac portability.

The export/restore and startup recovery sheets are enabled in disposable DEBUG
fixtures or an explicitly opted-in production Direct bundle. The latter requires
an authenticated matching macOS Developer ID profile, the existing pinned
certificate, exact signed application/team/Keychain claims and a signed capability.
Default packaging retains the legacy disabled state; there is no ad-hoc fallback.
All packaging entry points authenticate and recheck the actual signed profile.

Matching QA GUI export, wrong-password refusal, restore, Return/Escape and a
single save extension have passed. Actual isolated classic proxy Keychain
migration, rollback reads and cleanup pass between legacy and provisioned claims
with an unchanged application basename. Production services and real credentials
were not used. Renaming an installed application is not qualified by that test.
Startup recovery authenticates the existing journal and obtains fresh authority;
it does not rely on selecting a profile from pending metadata. The private native
packaging proof remains separate from the final notarized and published release.
The historical ZIP/DMG hosted gates, downloaded launch and metadata MCP checks
are in the [0.7.30 release record](../releases/v0.7.30.json). Current release
identity and delivery checks are in the 0.8.14 record above; neither delivery
record replaces the separate data-operation evidence.

### Recovery choice binding in development

Both recovery views now pass the confirmed manifest and retained-stage path to
the service. The service rereads the active journal and refuses a different
profile or transaction before obtaining mutation authority. A profile-specific
sheet cannot offer recovery of another profile or an unverified journal; it
directs the user to startup recovery instead. The full serial Swift unit suite
passed locally (summary: 1,553 tests in 180 suites; 68 explicit skips), including
wrong-profile/stale-stage refusal with unchanged pending metadata and successful
matching recovery. Native sheet/candidate gates remain before a later release.
The archive format, metadata schema, Keychain scope and profile identity are unchanged.

Apple API references: [Data Protection Keychain](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain),
[device-only accessibility](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly).

## WebKit: full backup remains unavailable

The settings export and saved tab list are not a backup of website data. Use
archive to hide a profile reversibly; WebKit data deletion is irreversible.
The full encrypted BrowserData operation continues to accept Chromium only.

Since [0.8.24](../releases/v0.8.24.json), the service rejects a direct WebKit export/restore call
before Chromium inspection, compatibility-scope access or archive work. The
authoritative metadata/revision check runs under the existing stopped-profile
and metadata guards; the later context guard remains. The prior export ordering
created a scope in the synthetic backend before refusing. Four new refusal
cases reproduce that bug; the corrected service and related storage/transaction
controls passed 50 Swift tests and 35 Python contracts. Metadata, identity, sibling
profiles and saved tab addresses stay unchanged. Existing admission still takes
its guard files: this is not a claim of zero filesystem activity. This correction is delivered in 0.8.24. The private service branch is covered by
source controls; the signed headed release baseline is a separate check.
[Source controls](evidence/webkit-backup-admission-development.json) and
[release scope](evidence/webkit-backup-admission-0.8.24.json).

macOS26 introduced public `fetchData(of:)` and `restoreData(_:)` methods. That
does not establish a full snapshot: the [pinned official implementation](https://github.com/WebKit/WebKit/blob/19ede6f35b64a7cd7ec397b64561ac09876156b4/Source/WebKit/UIProcess/API/Cocoa/WKWebsiteDataStore.mm#L605)
accepts LocalStorage only and rejects other requested types. Combining this with
the cookie API and saved URLs would still omit IndexedDB, service workers,
CacheStorage and OPFS, without a demonstrated whole-store atomic restore.

[Source/SDK evidence and return gate](evidence/webkit-backup-api-20261015.json)
are recorded separately from native proof. The installed system binary was not
tested for this operation. Do not remove the Chromium-only guard or copy private
WebKit directories to present a partial export as full backup. Supporting
macOS26-only export must not silently raise the application's macOS14 minimum.
