# Direct update system assessment — development status

`NeAntikUpdateAssessment` is a standalone, one-request observation helper. It
is not embedded in the published 0.7.30 application, is not connected to the
manager UI and cannot install or launch an update. The automatic updater stays
disabled. No App Store distribution is involved.

## Boundary

The future parent must first validate the manifest, archive, exact product
Developer ID/entitlements/provisioning and complete pinned runtime provenance.
It must authenticate the packaged helper, hold exclusive lifecycle ownership,
and bracket the entire child run with the owned stage's custody validation.
The helper's own repeated signature/hash observation does not detect swapping
an identical signed app into the same pathname. An independent helper reply
is not an installation capability.

The parent must start a fresh process with only fixed PATH, LANG=C and canonical
TMPDIR=/private/tmp. No inherited `SYSPOLICYNAME`, DYLD variables, credentials,
proxy settings or HOME are forwarded. CoreFoundation may add its current-UID
default text-encoding metadata before main; only the bounded numeric current
UID/zero/zero tuple is admitted. No other environment additions are allowed.
There is no global mutation of the running manager's environment.

## Fixed protocol and checks

- Stdin: `NAA1`, 20-byte expected canonical CodeDirectory hash, big-endian
  original digest algorithm and path length (UInt32), canonical app path, EOF.
  Path length is below PATH_MAX, with no embedded NUL or extra request bytes.
  Only the current SHA256 CodeDirectory algorithm2 is admitted. A 20-byte
  hash is not evidence for the distinct truncated-algorithm enum3.
- The child checks same-team Apple Developer ID, strict nested/all-architecture
  validity and a freshly secured matching hash/algorithm before and after the
  system calls. The parent supplies the exact product identity gate separately.
- Execute assessment requests IgnoreCache, NoCache, Enforce, IgnoreAllowlist and
  IgnoreActiveAssessments. The same flags, including Enforce, reach both Create
  and CopyResult. Override/cache/weak/error markers or malformed scalar types
  refuse, even alongside a misleading “Notarized Developer ID” rule label.
- Offline and forced-online ticket lookups bind the same canonical hash and
  original algorithm. Date outputs start as NaN. Full success requires true,
  no CFError and a finite, positive, nonfuture CFAbsoluteTime date for each.
  That date denotes ticket time, not response freshness.
- Missing private SPI, errors, missing dates and unsupported formats refuse.
  There is no CLI, weaker-policy or label-based fallback. No policy editing,
  quarantine removal, trust-store editing or Keychain credential operations.
- Fixed bounded JSON contains no paths, raw error userInfo, labels or inherited
  environment values. Failure stages expose only booleans and a numeric system
  error code. `installAuthorized` is always false; success additionally states
  `freshRemoteResponseProven:false`.
- The child restores/unblocks SIGALRM and uses a180-second deadline. The
  parent additionally bounds output, implements cancellation and reaps its
  exact owned child. There is no persistent service or arbitrary shell/JS.

## Current real observations and limitation

On macOS27 beta ARM64, the signed isolated helper observed the immutable
published .29/.30 apps. System Execute assessment and offline ticket acceptance
succeeded. The forced-online lookup returned true without CFError but provided
no date. The strict complete observation therefore refused (status8); this is
not reported as a successful updater gate or a failed public app launch.

Negative controls cover a wrong hash, wrong algorithm, a policy-service
environment override, malformed/truncated/trailing requests, an unnotarized
same-team signed QA app and inherited ignored/blocked SIGALRM. These are
read-only system observations; they may consult/populate system ticket caches.
No apps were executed or installed and no Gatekeeper policy was changed.

Published 0.7.30's signing, notarization, stapling, Gatekeeper and fresh hosted
launch checks are separate release evidence. This private SPI limitation does
not invalidate those checks. Do not retry identical online-date lookups or
declare remote freshness: the public Apple wrapper exposes no such provenance.

## Primary-source basis

Apple API definitions and implementation were studied; no Apple implementation
was copied into this product:

- [SecAssessment declarations and flags](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_codesigning/lib/SecAssessment.h)
- [CopyResult's independent bypass handling](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_codesigning/lib/SecAssessment.cpp)
- [XPC initialization and ticket/date handling](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_codesigning/lib/xpcengine.cpp)
- [Active assessment sharing](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_codesigning/lib/evaluationmanager.cpp)
- [Canonical code hash and algorithm](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_codesigning/lib/notarization.cpp)
- [Apple's default text-encoding environment format](https://github.com/apple-oss-distributions/webdavfs/blob/main/WebDAVPlugin/WebDAV_Mount.c)

## Parent process protocol — implemented, not yet shipped

`DirectAssessmentParent` now brackets the child run with an owned extracted
stage or prepared slot borrow. Operation errors are captured inside that borrow;
the filesystem postcondition runs before an error is returned. Cancellation is
latched onto the utility worker instead of leaving a detached child behind.
A reply remains an observation with `installAuthorized:false`.

The installed helper must have release-selected SHA256 **and** canonical CDHash,
fixed Developer ID identifier/team, hardened runtime, certified timestamp,
SHA256 CodeDirectory, thin ARM64 executable and no entitlements. The release
pins must come from qualified installed release inputs, never update JSON/MCP.
Retained nofollow descriptors, inode/file identity, permissions, flags, ACLs
and full hash are rechecked. Executable owner permission is required. The QA
factory accepts only a separate QA identity and a marked private temporary root.

The process starts suspended with fixed argv, environment, working directory,
stdio and signal defaults. Before SIGCONT the parent checks current UID, parent
PID, kernel generation, live Developer ID identity and exact CDHash twice, plus
helper file custody. This secures the loaded guest rather than treating a
filesystem signature check as proof of executing code. Other same-team code
with the same identifier does not qualify.

Stdin is bounded binary protocol ending in real EOF. stdout is at most1024
bytes; any stderr refuses and is never retained as an error message. Strict
versioned scalar reply grammar rejects duplicate/escaped/extra keys, nesting,
numeric booleans, inconsistent stages, unexpected exits and invalid dates.
The worker polls cancellation/deadline while writing and draining concurrently.
On failure it kills its still-owned child process group and reaps the exact
leader before returning; it never signals after reaping. Descendant pipe holders
and a child that closes stdio and hangs are negative controls.

The caller must be the sole wait owner of this PID; no unrelated `wait(-1)`
reaper or concurrent SIGCHLD policy changes are supported. SIGCHLD ignore or
SA_NOCLDWAIT refuses spawn without changing global signal state. Synchronous
Security.framework admission, posix_spawn and final kernel wait cannot guarantee
an absolute wall-clock bound under a kernel/framework stall. This is not a
persistent service, arbitrary command runner or installed-app installer.

Local real-process controls and separately signed QA admission are development
evidence. Published0.7.30 contains neither this parent protocol nor the helper;
no public updater capability is claimed. Trust hosting, supported ticket policy,
installed lifecycle ownership and exact signed install/rollback/ack qualification
remain required before enabling automatic installation.

## Remaining gates

An explicit supported system-ticket policy still needs resolution; no silent
downgrade is allowed. Final packaged helper admission on the exact installed release, production
lifecycle integration of the implemented custody/cancellation/output controls,
durable atomic install/rollback/first-launch ack,
trusted updater key hosting and exact installed candidate checks remain open.
