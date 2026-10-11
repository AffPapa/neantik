# Direct update archive custody

Development implementation; automatic installation is not enabled.

`DirectUpdateStageStorage` admits the signed manifest before file effects,
copies one local regular archive into an owned `0700` directory, synchronizes
it, makes the archive `0400`, and verifies the hash of the copied bytes.
The release key comes from the pinned channel configuration, never from the
manifest. The production update channel remains disabled.

`PreparedUpdateArchive` cannot be decoded from a receipt. Borrowing its path
rechecks directory/file identities, privacy permissions and the exact entry
set. A returned URL is not permanent authority: later extraction and trust
stages must validate custody before and after their operations. Same-user
processes can change file permissions; read-only mode is not immutability.

Cancellation, signature/expiry, version, minimum OS, bounds, changed source,
changed stage and simulated disk/permission/sync faults are checked. Failure
cleanup and explicit discard retire the captured namespace with no-overwrite
rename, then inspect the object actually moved. Unexpected objects are
retained rather than traversed/deleted. A failure can therefore leave a stage
for later recovery; deinitialization only closes descriptors. Retirement
narrows namespace races but is not a boundary against arbitrary same-UID
processes continuously rewriting private randomized retirement names.

## Evidence

`DirectUpdateStageStorageTests` covers storage faults, two actual Task
cancellation boundaries, source/stage tampering, symlinks/hardlinks, private
permission changes, and deterministic replacements at directory/archive
retirement. The opt-in `NEANTIK_UPDATE_STAGE_PUBLIC_ARCHIVE` test accepts only
the exact published 0.7.29 ZIP SHA-256 and size. It signs an ephemeral test
manifest with a separately pinned test key, copies those actual bytes, checks
the receipt and discards the owned stage. This is filesystem/hash evidence;
it does not establish a production update signing channel or app trust.

## Remaining installation gates

1. Bounded ZIP inventory and extraction, including macOS metadata and safe
   framework symlinks; traversal, duplicate/case collisions and limits refuse.
2. Exact app version/build/runtime provenance, Developer ID, deep signature,
   notarization and Gatekeeper verification of the staged app.
3. Exclusive app/browser/relay lifecycle admission and independent helper.
4. Durable two-slot installation journal, recovery at each commit boundary,
   retained rollback and authenticated first-launch acknowledgement.
5. Release key custody, signed hosting contract, interruption controls and
   actual signed/notarized A→B→A installation with isolated test data.

ZIP byte integrity alone never grants extraction or installation authority.
