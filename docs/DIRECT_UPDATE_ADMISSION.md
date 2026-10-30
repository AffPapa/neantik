# Direct update candidate admission

Status: internal coordinator, not an enabled updater. The published v0.7.30
binary does not contain this subsequent source work. No download, quit, swap,
relaunch, first-launch acknowledgment or data migration is performed here.

## One candidate, one attempt

`DirectUpdateAdmissionCoordinator` owns the prepared archive and extracted
stage, runs the existing native checks sequentially, and publishes typed
progress. Actor reentrancy cannot submit another archive during an await.
After failure/cancellation/refusal the attempt cannot be reused. A caller must
not create unlimited attempts; product integration still needs storage quotas,
retention UI and explicit custody-checked cleanup. Deinit closes descriptors;
it does not recursively delete retained candidates or adopt abandoned trees.

1. Verify the signed manifest using the independently configured channel key,
   newer version/build and host OS before accessing archive/destination files.
2. Copy/hash the local archive into owned private storage; reverify expiry.
3. Inventory and safely extract into a separately sealed private stage.
4. Verify native Developer ID, exact product identities, hardened runtime,
   timestamp, nested/all architecture signatures and authenticated provisioning.
5. Measure the pinned unchanged runtime/evidence closure and report bytes.
6. Authenticate the installed-policy assessment helper, admit its suspended
   process, then observe the system gates under the candidate custody borrow.
7. Reverify the original signed manifest after final filesystem validation;
   require the same payload, archive hash/version/build and manager CDHash.
   Recheck current authenticated provisioning validity before publication.

All disk/crypto/Security work runs in awaited utility workers. Cancellation
drains the worker/helper before publishing the terminal state. Errors are not
converted into success. The coordinator exposes no file paths or profile data
in its progress enum and reads no user profiles or Keychain items.

## Reuse without accepting fabricated proof

`DirectUpdateStageSignature` has a file-private constructor used only after
native signature checks. It retains the actual sealed stage, not its path or
an `ObjectIdentifier` vulnerable to lifetime reuse. Runtime and assessment
accept the token only for that exact object and still validate filesystem
custody. A changed original and a different extracted app both refuse.

Provisioning validity is captured only after native CMS, grant and leaf
authentication. Its private creation/expiration interval is checked with the
current clock before and after slow work and at final publication. Filesystem
equality cannot turn an expired profile into valid policy. These scalar checks
avoid redundant deep verification while preserving the time boundary. A
future installation boundary must freshly verify required trust, custody and
policy; this observation is not a perpetual permission or revocation guarantee.

The helper request preserves the exact `/private/tmp` spelling. Foundation's
`standardizedFileURL` alias rewriting is not used to compare that spelling.
The parent checks lexical path syntax; the C helper independently requires
exact `realpath`, owner and directory checks before assessment. No quarantine,
Gatekeeper policy or system setting is changed.

## Refusal and remaining gates

`DirectUpdateAdmissionObservation` cannot be decoded from JSON and always has
`installAuthorized == false`, including when all observations succeeded. A
typed `.refused(status)` remains a refusal. A Codable archive/installation
receipt cannot be promoted to installation authority.

The exact public v0.7.30 ZIP composition test on the available macOS 27 beta
ARM64 host completes native protocol v2 admission. The earlier status **8**
was caused by requiring an online date that Apple's forced lookup need not
publish. An actual completed Boolean result without CFError is required;
the separate offline ticket date remains mandatory. An online date, when
supplied, must be finite, positive and non-future. No fresh remote response
or installation authority is inferred from either value. See
[DIRECT_UPDATE_ASSESSMENT.md](DIRECT_UPDATE_ASSESSMENT.md).

Product completion still requires a trusted pinned channel/helper, bounded
download/retention, a global admission and quit barrier, fresh manager/MCP/relay
process absence, an independent installation owner, restart, authenticated
first-launch readiness before data writes, failure recovery and exact signed
artifact/platform qualification. Current filesystem leases also deliberately
reject root-owned or insufficiently private installation parents; ordinary
`/Applications` privileged installation is not implemented.

## Regression coverage

`DirectUpdateAdmissionTests` uses actual signed synthetic manifests, actual
archive copying and extraction: disabled channel before file access, unrelated
key, mismatched digest, non-ZIP and unsigned layout, reentrant submission,
actual Task cancellation and cancelled entry. No substituted signature/runtime
or helper verifier can manufacture passing admission.

The opt-in `NEANTIK_UPDATE_ADMISSION_PUBLIC_ARCHIVE` test uses exact hosted
v0.7.30 bytes with an independently signed QA helper selected through
`NEANTIK_ASSESSMENT_PARENT_QA_ROOT` and `NEANTIK_ASSESSMENT_PARENT_QA_HASH`.
It composes all gates and checks a different stage, modified original and
the real authenticated profile at a future date. The local channel signing
key is synthetic; this is not verification of a deployed update feed.
The `canonicalPrivateTemporaryPathIsNotRewrittenByFoundation` test checks
request framing/path retention and malformed hash, scheme and traversal
controls. No actual app is installed or run by these tests.

## Cooperative lifecycle follow-up

Packaged manager/MCP/relay process participation and new-work admission are now implemented as a separate development slice. See [DIRECT_UPDATE_LIFECYCLE.md](DIRECT_UPDATE_LIFECYCLE.md) for actual controls and limits. This does not turn candidate admission into install authority, enable the updater, or close legacy-process, owner, trust, recovery and authenticated first-launch gates.

## Shared core and one-shot stage transfer

`Sources/DirectUpdateCore` shares the existing native admission primitives with
the independent `NeAntikUpdateOwner` executable. Package access preserves
private/file-private capability constructors. The core has no SwiftUI, AppKit,
ProfileStore, Keychain or browser credential dependencies. The shared bounded
filesystem limits are checked against the existing encrypted backup framing.

`prepareInstallSlot` requires the coordinator's actual retained `.observed`
stage and original signed manifest. It changes state before suspension,
rechecks expiry/profile validity throughout the source validation callbacks
and after transfer, and consumes the stage immediately at visible rename.
Failure or cancellation is terminal. A partial transfer retains its record
and candidate; no second call adopts it. The returned filesystem token is
not installation or process authority.

The independently signed DEBUG QA owner inspects native code/runtime/system
gates and transfers an owned stage in a private synthetic installation parent.
It checks its actual live Developer ID code and empty entitlements first.
Its fixture key/policy cannot exist in Release, which rejects all invocations
with exit 64. The subsequent development driver now joins this retained-slot
interface to filesystem transactions and authenticated readiness. Its current
signed QA installation uses a separate synthetic receipt, not this shipping
manifest admission chain. See the lifecycle follow-up below. The shipping
updater remains disabled.

Real accepted-stage controls cover expiry before transfer/before rename/after
visible transfer, changed custody, Task cancellation before transfer/at final
return, disk-full faults on either side of rename and duplicate consumption.
The independent QA executable additionally refuses unsigned owner code, an
unrelated manifest key, expired manifest, unsafe root permissions, wrong QA
marker and mismatched archive bytes.

## Real transaction driver follow-up

`DirectUpdateInstallDriver` retains the install lease and stopped-process
authority, rechecks both trees and candidate code at every bootstrap custody
boundary, and commits only inside authenticated live-child readiness. Failure
recovery runs in an uncancelled utility task. The exact finalized transaction
receipt distinguishes a late completion error from absence of an active
journal; an unrelated receipt or missing history cannot manufacture success.
The post-ACK continuation has its own bounded IO budget, separate from launch.

DEBUG QA controls are restricted to explicit marked private roots, the same
Developer ID certificate and disposable development credential storage. They
do not activate the Release installer, supply a trusted shipping feed, or
qualify privileged installation in `/Applications`.
