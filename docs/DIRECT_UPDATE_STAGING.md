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
The opt-in `NEANTIK_UPDATE_STAGE_PUBLIC_ARCHIVE` test additionally extracts the
exact published 0.7.29 ZIP (1,085 entries, 488,206,443 expanded bytes), compares
the manager hash and runs `codesign --verify --deep --strict`. These are actual
archive/signature-preservation checks; they are not a staged Developer ID,
notarization or installer qualification. The ZIP contract follows the
[PKWARE ZIP specification](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)
and uses the [system zlib raw-deflate API](https://zlib.net/manual.html).

## Native signing observation

`DirectUpdateCodeSignature` applies fixed Apple-anchored Developer ID
requirements for team `H6VGU2M6JD` and the manager/runtime/framework identifiers.
It uses strict, nested-code and all-architecture validity flags, then inspects
Security.framework's secured Info.plist and signed entitlements. It requires
hardened runtime and the TSA-certified `kSecCodeInfoTimestamp`; the
signer-supplied `kSecCodeInfoTime` is insufficient. A fresh code object is
checked again after inspection. Current executable format is explicitly thin
64-bit ARM64; universal or future formats refuse pending a separate contract.

The stage adapter checks all regular Info.plist entries (1 MiB each), resource
envelopes (8 MiB each) and an aggregate metadata budget (32 MiB) before Security
parsing. The actual 0.7.29 ZIP has 22 such entries totaling 532,876 bytes.
It checks owner-executable modes, explicitly verifies the runtime under `Resources`, and
matches manager version/build and Chromium version to the admitted manifest.
The asynchronous entry point uses a utility worker and checks caller/worker
cancellation before returning. It currently accepts only the existing
unprovisioned manager entitlement contract. Provisioned backup packages require
the separate authenticated CMS/profile policy and are not admitted by this
slice.

Scalar fields alone cannot construct a verified observation. Wrong-type
decoded entitlement dictionaries and opaque raw entitlements without a decoded
dictionary refuse, including for the otherwise empty framework policy.

Real 0.7.29 manager/runtime/framework Developer ID and certified timestamps,
the exact owned ZIP stage, a technically valid ad-hoc signature refusal and a
signed test-manifest version mismatch were exercised. Scalar-policy controls
are unit evidence; they do not replace those actual code-signature checks.
The result remains a signing observation: full runtime payload provenance,
notarization/Gatekeeper, lifecycle admission and durable installation gates are
still required. See Apple's
[signature validation API](https://developer.apple.com/documentation/security/secstaticcodecheckvalidity(_:_:_:))
and [certified timestamp definition](https://developer.apple.com/documentation/security/kseccodeinfotimestamp).

## Remaining installation gates

1. Exact app version/build/runtime provenance, Developer ID, deep signature,
   notarization and Gatekeeper verification of the staged app.
2. Exclusive app/browser/relay lifecycle admission and independent helper.
3. Durable two-slot installation journal, recovery at each commit boundary,
   retained rollback and authenticated first-launch acknowledgement.
4. Release key custody, signed hosting contract, interruption controls and
   actual signed/notarized A→B→A installation with isolated test data.

ZIP byte integrity alone never grants extraction or installation authority.
