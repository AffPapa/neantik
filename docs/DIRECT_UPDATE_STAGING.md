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
cancellation before returning. It distinguishes the legacy app-ID-only manager
and a provisioned manager with exactly three scoped claims. A present profile
must authenticate and match the actual Developer ID leaf; invalid provisioning
never downgrades to the legacy contract.

Scalar fields alone cannot construct a verified observation. Wrong-type
decoded entitlement dictionaries and opaque raw entitlements without a decoded
dictionary refuse, including for the otherwise empty framework policy.

Real 0.7.29 manager/runtime/framework Developer ID and certified timestamps,
the exact owned ZIP stage, a technically valid ad-hoc signature refusal and a
signed test-manifest version mismatch were exercised. Scalar-policy controls
are unit evidence; they do not replace those actual code-signature checks.
The result remains a signing observation. The separate fixed-runtime closure
observation below covers current exact bytes; notarization/Gatekeeper, lifecycle
admission and durable installation gates are still required. See Apple's
[signature validation API](https://developer.apple.com/documentation/security/secstaticcodecheckvalidity(_:_:_:))
and [certified timestamp definition](https://developer.apple.com/documentation/security/kseccodeinfotimestamp).

## Native provisioning observation

`DirectProvisioning` builds as a normal C target linked to Security.framework.
It runs no compiler/subprocess at application runtime and accesses no Keychain
credentials. A bounded definite-DER SignedData/attached-data preflight rejects
encrypted and detached envelopes before CMS finalization. Admission itself is
not authentication. CMS must have one valid signer and pass the exact macOS
provisioning-profile policy. That private Apple policy is loaded dynamically;
if unavailable on an OS, admission refuses rather than using generic X509.

The exact Apple policy and an explicit offline OCSP policy are evaluated with
issuer/revocation network fetching disabled. This checks cached revocation on
the platform's best-attempt basis; it does not prove a fresh non-revoked status.
No custom anchors, trust-store edits or permissive trust fallback are used.
Apple's [policy implementation](https://github.com/apple-oss-distributions/Security/blob/main/OSX/sec/Security/SecPolicy.c)
defines the profile markers/Apple anchor/OCSP and the revocation flags;
[revocation flag documentation](https://developer.apple.com/documentation/security/revocation-policy-constants)
distinguishes cached replies and a required positive response. This source
inspection is not cold-cache/revoked-certificate runtime qualification.

Authenticated plist grants must authorize macOS/all devices, current validity,
the fixed team, actual application ID and exact claimed Keychain group. The
actual Security.framework Developer ID leaf DER must occur in the profile's
DeveloperCertificates. Signed manager entitlements must have exactly the
three production claims; development/debug and extra groups refuse. The
profile is a bounded owned single-link regular file captured with descriptors,
including captured absence for legacy. Bytes/path identities, fresh secured
code fields/leaf and profile expiry are checked again after inspection.
Only one top-level macOS profile is admitted; mobile/nested profiles refuse.

Actual controls exercised the published 0.7.29 legacy and 0.7.30 provisioned
ZIPs, a wrong manifest version, authenticated profile/actual leaf mismatch,
wrong App ID, and damaged/removed profiles on disposable extracted app copies.
A legitimate iOS Apple CMS passes a deliberately generic X509 control but
fails the exact macOS policy. An owned self-signed foreign CMS, real encrypted
CMS, unsigned/detached/truncated envelopes and signed-data tampering refuse.
These are source/native-signature observations, not installation permission.
Optional actual fixtures are explicitly skipped unless selected by environment.

Cancellation prevents publishing a result after cancellation; the synchronous
Security call is not proven promptly interruptible. Profile expiry/custody must
be revalidated again immediately before a future installation commit.

## Fixed M156 runtime and evidence observation

`DirectUpdateRuntimeProvenance` admits only the previously qualified unchanged
signed `156.0.8078.12` payload. Trusted pins are compiled into the installed
manager; neither the ZIP nor a signed update manifest chooses a reference key,
source hash, policy, report schema or runtime hash. Future runtimes and changed
nested signatures/evidence refuse until a reviewed policy is shipped. This is
deliberately a narrow same-runtime update primitive, not a general Chromium
update channel.

The actual runtime closure includes its root, every directory mode, regular
file mode/size/SHA-256, resource/signature envelopes and exact symlink targets:
946 entries, 411,177,721 regular bytes, 16 thin ARM64 Mach-O files. The evidence
closure includes 114 entries and 49,527,984 regular bytes, including the full
reviewed source/patch projections. Evidence links refuse. All files are read
through owned no-follow descriptors with inode/size/time/mode/namespace checks;
late changes to previously hashed leaves are revalidated before returning.
Large evidence is streamed and hashed, not parsed or executed. Report capture
is bounded to 64 KiB, hashed against its compiled exact pin and then parsed from
those same captured bytes. Changed/duplicate JSON cannot pass that byte pin.
The schema separately requires the exact source-evidence mode, explicit absence
of a fresh whole-tree observation, source/report hashes and Metal declaration.
This does not prove actual Metal operations on the receiving Mac.

The closure transcript has domain `neantik-exact-runtime-closure-v1\0`, a
UInt32 big-endian length-prefixed UTF-8 scope and UInt32 entry count. Records
are sorted by raw UTF-8 bytes of admitted NFC relative paths. Each record has a
length-prefixed path, one kind byte (D/F/L), directory/file mode UInt32 (0777),
file size UInt64 and raw SHA-256 for files, or a length-prefixed exact target
for links. Root path is empty. Link mode is deliberately absent: `symlinkat`
does not restore archive permission bits. Link targets are never normalized.
Paths are NFC despite decomposed APFS enumeration, matching ZIP admission.
No UID, inode, timestamps, compression or CRC enter the reproducible digest;
they remain separate current-custody checks.

`scripts/verify-direct-update-runtime-pins.py` independently reproduces the
transcript and compares the already qualified reference app and packaged M156
source projections to the reviewed checkout. It never generates/replaces pins.
The Python/Swift golden includes an empty file, UTF-8 path and symlink. Actual
owned extraction of both exact published 0.7.29 and 0.7.30 ZIPs passed the native
signature/profile and fixed runtime/evidence gates with identical closure pins.
Synthetic negatives cover content/mode/namespace/link spelling, foreign Mach-O,
hardlink/ancestor/leaf races, a late earlier-leaf overwrite, limits and actual
Task cancellation. Unknown Chromium refuses before signature/report parsing.

All signing and runtime observations are bracketed by the extracted stage's
full seal. Separate custody scopes avoid re-entering its nonrecursive lock.
The asynchronous entry point keeps streaming work off the UI actor and fences
caller/worker cancellation. The returned observation has no decoded/public
constructor and grants no installation permission, source rebuild proof,
fresh certificate status, notarization/Gatekeeper result or perpetually valid
authority. A future install commit must acquire and recheck all required gates.

## Remaining installation gates

1. Exact app version/build/runtime provenance, Developer ID, deep signature,
   notarization and Gatekeeper verification of the staged app.
2. Exclusive app/browser/relay lifecycle admission and independent helper.
3. Durable two-slot installation journal, recovery at each commit boundary,
   retained rollback and authenticated first-launch acknowledgement.
4. Release key custody, signed hosting contract, interruption controls and
   actual signed/notarized A→B→A installation with isolated test data.

ZIP byte integrity alone never grants extraction or installation authority.

## Native system assessment helper

See [development contract and real SPI limitations](DIRECT_UPDATE_ASSESSMENT.md).
This helper is not packaged or enabled in public0.7.30. Its standalone result
does not authorize installation or establish parent stage custody.

## Filesystem transaction development slice

See [two-slot journal and recovery contract](DIRECT_UPDATE_FILESYSTEM_TRANSACTION.md).
The standalone primitive preserves both copies and has fresh-process crash
tests. Main NeAntik has no caller; this does not close installation authority,
authenticated first launch or final signed update qualification gates.
