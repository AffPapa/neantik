# Cooperative installation lifecycle

Development implementation. Automatic updates remain disabled; this mechanism does not authorize installation. The immutable public 0.7.30 app predates this mechanism.

## What participates

A packaged NeAntik process resolves its actual kernel executable path, canonicalizes the containing app and retains one participant lease before dispatching GUI, MCP, relay or QA modes. Neither argv, MCP requests nor the profile root selects this scope. Unbundled SwiftPM executables are not installation targets.

The namespace is `/private/tmp/neantik-update-lifecycle-<uid>/<SHA256(canonical installation pathname)>/`. Symlink and macOS temporary-directory aliases share a scope; distinct installations do not. An atomic app replacement retains the pathname scope. The namespace and empty guard files must never be removed or repaired by ordinary cleanup. They contain no credentials or profile data.

Every process gets independent descriptors with CLOEXEC. Closing a window does not release the process lease; a relay that outlives the GUI retains its own lease. Exiting or a kernel process termination closes the descriptors. No arbitrary process is signalled by this mechanism.

## Lock ordering

1. Entrant takes nonblocking exclusive `admission.guard`.
2. Entrant takes shared `participants.guard`, validates custody and checks pending installation records.
3. Entrant releases admission, retaining participant SH until process exit.
4. An independent external owner takes admission EX and retains it while participants drain.
5. The owner polls nonblocking participants EX; false means participants still live. True means only cooperative quiescence.

A losing simultaneous entrant can receive busy and retry intentionally. The owner must not itself hold SH or attempt an SH-to-EX conversion. Startup checks are performed while admission is held.

Parent and namespace directories require current UID ownership, 0700, no extended ACL or flags. Guard files require 0600, regular empty single-link files, matching FD/named inode, no ACL or flags. Exclusive creation falls back to opening the existing name only on EEXIST. On this Mac cold concurrent O_CREAT opens reproduced ENOENT; the tests preserve the first failure and the correction. Other errors remain refusals.

Custody is revalidated before each new-work check and before returning a participant fence. Parent, directory or guard replacement makes an existing participant refuse new work. This is cooperation among one UID, not protection from a malicious same-UID writer. A recreated namespace can have independent locks, so fresh authenticated process inventory remains mandatory.

## New work and pending recovery

Manager browser admission and real MCP management-engine calls briefly acquire admission before admitting new work. A pending intent returns `update_pending` to MCP. Existing operations are not forcibly cancelled; SH prevents the owner from claiming cooperative quiescence while those processes remain alive. MCP discovery and shutdown/EOF remain available.

Normal startup of the canonical NeAntik.app target refuses active or preparing filesystem transaction records before initializing profile storage. Unknown records are retained. It does not adopt, migrate, erase or recover them. Completed history is not confused with an active transaction. Unrelated names in the install parent are ignored.

GUI startup refusals show an explicit alert; CLI/control modes return temporary failure with fixed safe text. A browser launch refusal uses the existing launch-error UI.

## Actual checks

- Separate processes: concurrent cold entrants (only legitimate busy may retry), two participants, owner waits, new entrant refuses, new work refuses, participant exit/crash, owner exit/crash and recovery of admission.
- Actual exec of the same fixture proves participant descriptors do not survive exec.
- Negative controls: guard/namespace/parent replacement, symlink, hardlink, nonempty file, mode and ACL changes; unknown pending startup records.
- Canonical alias, separate installation and atomic pathname replacement scope controls.
- Dev.app: creation/edit/save of one synthetic profile, headed Chromium about:blank start/stop, keyboard navigation, help window with the main window closed, full app exit.
- Real MCP process: 18 tools, work before/after intent, `update_pending` while held, a new MCP process refuses before creating its data root, EOF exit. A spoofed argv does not change its scope.

These are local Dev/process tests, not qualification of a new signed published release.

## Remaining installation gates

- Global quit/drain and fresh conservative inventory of legacy managers, MCP, relay, Chromium and helpers. Legacy releases and Chromium do not hold these participant leases.
- Independently authenticated updater owner and exact candidate trust capability.
- Explicit authenticated first-launch handoff: the candidate cannot enter normally while admission EX remains held. Do not casually drop the fence to admit arbitrary competing processes.
- Durable pending recovery and authenticated first-launch ACK before profile migration, including owner/candidate interruption and rollback.
- Signed/notarized exact candidate and hosted-byte qualification, with existing immutable rollback.

Never use a quiet fence alone as permission to swap an app or report a working atomic updater.
