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
ARM64 host reached system refusal **8**: Gatekeeper and offline ticket accepted,
the required complete online-ticket/date condition not accepted. This is not
an enabled updater or a shipping-candidate qualification. The gate is preserved
without CLI/label fallback or claims that a lookup necessarily fetched a fresh
remote response. The current private system API policy remains unresolved.

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
