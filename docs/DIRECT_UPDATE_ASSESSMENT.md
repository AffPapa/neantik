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
- The child restores/unblocks SIGALRM and uses a180-second deadline. The future
  parent must additionally bound output, implement cancellation and reap its
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

## Remaining gates

An explicit supported system-ticket policy still needs resolution; no silent
downgrade is allowed. Authenticated packaged helper admission, parent custody/
cancellation/output controls, durable atomic install/rollback/first-launch ack,
trusted updater key hosting and exact installed candidate checks remain open.
