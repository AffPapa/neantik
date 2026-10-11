# Direct update archive custody

Development implementation; automatic installation is not enabled.

`DirectUpdateStageStorage` admits the signed manifest before file effects,
copies one local regular archive into an owned `0700` directory, synchronizes
it, makes the archive `0400`, and verifies the hash of the copied bytes.
The release key comes from the pinned channel configuration, never from the
manifest. The production update channel remains disabled.

`PreparedUpdateArchive` cannot be decoded from a receipt. Borrowing its captured
file descriptor and path
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

## Bounded ZIP extraction

`DirectUpdateZIPInventory` accepts the current Direct ZIP32 package contract,
not arbitrary ZIP imports: one `NeAntik.app` root, explicit parent directories,
UTF-8 normalized paths, stored/raw-deflate entries and Unix regular files,
directories or bounded framework symlinks. It limits compressed bytes to 4 GiB,
expanded bytes to 8 GiB, the central directory to 32 MiB, entries to 50,000,
paths to 1,024 bytes and depth to 32. ZIP64, encrypted entries, special files,
privilege bits, traversal, duplicate/case-folded ancestry collisions and
contradictory local/central records refuse before destination creation.

The system zlib decoder reads and writes bounded 64 KiB chunks, checks exact
compressed/expanded lengths and CRC, and observes Task cancellation before
writes. Extraction borrows the captured archive descriptor instead of
reopening a mutable pathname. Writers walk only captured directories with
`O_NOFOLLOW`; links are created last. Symlink validation expands each link
before processing subsequent `..`, matching filesystem resolution.

`ExtractedUpdateApp` holds a separate private owned tree. Sealing checks the
exact entry set and identities captured after each completed write. Changed
or unknown files are retained on failure rather than adopted or deleted.
Discard retires the outer directory before removing only listed captured
entries. As with archive custody, this is not a security boundary against an
arbitrary same-UID process continuously rewriting private names.

Original safe file/directory modes and framework link targets are preserved;
archive xattrs, ownership changes and extra-field metadata are not adopted.
This does not establish notarization or quarantine/Gatekeeper policy.

`DirectUpdateZIPTests` includes real stored/deflated output and framework
links, malformed records, CRC/truncation/size controls, symlink graph and
filesystem escape controls, faults, file/permission/namespace tampering,
actual cancellation inside deflate and at seal, and a 500-file inventory.
The opt-in `NEANTIK_UPDATE_ZIP_PUBLIC_ARCHIVE` test additionally extracts the
exact published 0.7.29 ZIP (1,085 entries, 488,206,443 expanded bytes), compares
the manager hash and runs `codesign --verify --deep --strict`. These are actual
archive/signature-preservation checks; they are not a staged Developer ID,
notarization or installer qualification. The ZIP contract follows the
[PKWARE ZIP specification](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)
and uses the [system zlib raw-deflate API](https://zlib.net/manual.html).

## Remaining installation gates

1. Exact app version/build/runtime provenance, Developer ID, deep signature,
   notarization and Gatekeeper verification of the staged app.
2. Exclusive app/browser/relay lifecycle admission and independent helper.
3. Durable two-slot installation journal, recovery at each commit boundary,
   retained rollback and authenticated first-launch acknowledgement.
4. Release key custody, signed hosting contract, interruption controls and
   actual signed/notarized A→B→A installation with isolated test data.

ZIP byte integrity alone never grants extraction or installation authority.
