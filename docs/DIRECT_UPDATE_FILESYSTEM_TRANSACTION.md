# Direct updater filesystem transaction — development contract

`DirectInstallFilesystem` is a filesystem primitive linked to the development
manager's owned ZIP stage through `prepareInstallSlot`. There is no production
installer/UI caller. It is not included in public0.7.30 and does not enable
automatic updates or authorize installation.

## Inputs and boundaries

- Existing, user-owned install parent with exact0700 permissions, no extended
  ACL or flags. All ancestors are opened without following links. The operation
  never changes the parent's permissions or ownership.
- Existing `NeAntik.app` and `.neantik-next-<lowercase UUID>.app` slots on that
  parent's filesystem. Root-owned `/Applications` and ordinary0755 parents
  refuse before creating a lock. Privileged installation needs a separate design.
- Candidate receipt SHA256 supplied by the future trusted caller. This hash is
  a binding, not a signature or permission grant.
- Caller must establish lifecycle authority for every manager, MCP process,
  browser and relay, and signature/provisioning/runtime/system trust. ZIP stage
  transfer now establishes filesystem custody and durable slot bytes only.
- Operations are synchronous; future callers must run them on a cancellable
  utility worker. There is no UI/MainActor integration here.

`flock` excludes cooperating installers. Captured parent, lock, journal and
both trees detect changes. This is not protection against an arbitrary process
with the same user's full filesystem access.

## Protocol

1. Acquire and validate the persistent parent lock. Never unlink that lock.
2. Capture both tree roots, complete namespaces, file hashes and inode custody.
3. Write an exclusive bounded canonical journal; sync file and directory.
4. Publish the active journal with exclusive rename, sync the install parent.
5. Recheck authority, custody and the journal-only namespace. Atomically exchange
   the two app names with `RENAME_SWAP`, sync the common parent. Retain original.
6. Await authenticated first-launch readiness. A pending receipt binds the
   transaction UUID, journal hash, candidate receipt and candidate root inode.
7. After caller validation, write/sync a bounded ACK, publish its commit name
   and sync the journal. Recheck authority immediately before publication.
8. Finalize the journal with exclusive rename and parent sync. Both app trees
   and finalized journal remain; no recursive deletion or automatic pruning.

Visible ACK publication is the decision boundary. Cancellation after that
publication does not select rollback. Before it, recovery restores original;
partial unpublished ACK bytes remain diagnostic data and never commit.

Recovery reacquires the original lock lineage and stopped-process authority.
It accepts exactly two recorded inode/content orientations. Repeated rollback
never blindly swaps a second time. Unknown files, objects, namespace, ACK or
authority retain the active fence and both copies. Preparations interrupted
before publication remain private orphans and block a new transaction until
explicit inspection; they are never adopted or removed by prefix matching.

## Tree and record limits

Each tree: at most6000 entries, depth32, UTF8/NFC paths1024bytes,
regular-file content1GiB, current owner, same device, no group/world write,
special bits, flags or extended ACL; single links for files/symlinks. Symlinks
are recorded rather than traversed. Their complete captured graph must resolve
inside the tree, expanding a link before processing following `..`; missing
targets, non-directory ancestors, cycles and >32 expansions refuse.

Journal:4MiB, schema1, canonical JSON plus checksum, captured journal inode.
ACK:2048bytes, exact bound receipt. Neither record checksum is authentication.
Root rename legitimately changes root ctime; descendant identities, content,
modes, exact link targets and namespace must still match. A second metadata
walk detects late writes to earlier entries during streaming hashing.

## Verification and remaining gates

The DEBUG-only `NeAntikInstallFilesystemFixture` is test support, never a
shipping installer. Release execution refuses. It operates only on marked
synthetic roots in `/private/tmp`, has a30second alarm and exits abruptly at
named syscall boundaries. Tests exercise actual fresh processes, filesystem
operations, repeated recovery, concurrent locks, cancellation, authority loss,
changed parent/lock/slots/journal, ACL/flags, symlink graphs and resource limits.
Injected EIO errors are simulated syscall-boundary failures; process crashes
are not power-loss qualification.

Final-source targeted tests, the integrated full suite, Release compilation and
privacy audits are recorded in the task delivery report. Filesystem fixtures
do not qualify signed app installation, migration or user-data rollback.

Still required: authenticated helper/launch protocol, packaged helper custody,
full process admission, trusted update manifest hosting, real signed/notarized A→B→A installation and
exact final candidate/public-byte gates. The independently observed native
online ticket-date refusal remains a trust blocker; no bypass is introduced.

## Extracted-stage transfer

`ExtractedUpdateApp.prepareInstallSlot` is a one-shot operation under the owning
stage lock, separate from `withValidatedApp`'s borrow. It synchronizes captured
files/directories and writes a bounded canonical transfer intent before the
same-volume, descriptor-relative `RENAME_EXCL`. The intent binds source parent,
install parent/lock, candidate UUID, full app tree and archive-integrity receipt
hash. It is a checksum/custody record, not install trust.

Immediately after successful rename, the extraction stage becomes transferred,
before any cancellation, throwing hook or synchronization. Its later borrow,
repeat transfer and discard refuse. Both source and destination parent names
are synchronized. Failure preserves the transferred candidate and records;
there is no copy fallback, rename-back, recursive cleanup or automatic adoption.
Source namespaces must be exactly `NeAntik.app` before transfer and empty after.

The non-Codable `PreparedInstallSlot` has no delete API. It brackets inspection
with captured inode/tree/record validation. Typed `begin(preparedSlot:)` binds
the transfer record in the installation journal and consumes the handle
immediately on visible active-journal publication. After swap the candidate
pathname contains the old app; the former handle still refuses all access.
Reentrant borrow/transfer/transaction calls return `busy`, rather than hanging.

Fresh-process `inspect` classifies exact source, exact candidate or journal
custody without issuing an installation token. Incomplete/unknown records fence
new preparation. Intact finalized journals with exact ACK/rollback decisions
allow historical transfer records to remain while a subsequent update proceeds;
records and rollback app slots are not pruned. History decision validation does
not assert that an earlier installed app remains the currently active app.

Tests include abrupt process exits before/after intent publication, rename and
both parent syncs; real Task cancellation; simulated EIO; substitution, namespace
and content changes; token consumption at an interrupted activation; two fresh
process updates with retained history; old stage discard refusal. The optional
public ZIP transfer test checks the exact archive hash, authenticated Developer
ID/profile before/after transfer, unchanged manager bytes and runtime closure.
It does not execute/install that app or resolve native online-ticket admission.
