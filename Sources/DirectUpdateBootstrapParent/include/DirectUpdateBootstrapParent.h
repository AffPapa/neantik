#ifndef NEANTIK_UPDATE_BOOTSTRAP_PARENT_H
#define NEANTIK_UPDATE_BOOTSTRAP_PARENT_H
#include <sys/types.h>
#include <stddef.h>
#include <stdint.h>
enum { NUB_COMPLETE=0, NUB_REQUEST=1, NUB_SPAWN=2, NUB_ADMISSION=3,
       NUB_CANCELLED=4, NUB_TIMEOUT=5, NUB_OUTPUT=6, NUB_INPUT=7, NUB_WAIT=8, NUB_IO=9,
       NUB_EOF=10, NUB_FRAME=11 };
typedef int (*NeAntikBootstrapAdmit)(pid_t, void *);
typedef int (*NeAntikBootstrapReady)(pid_t, const uint8_t *, size_t, void *);
typedef int (*NeAntikBootstrapCancel)(void *);
typedef struct { int status, reaped, continued, handed_off; pid_t process_id; } NeAntikBootstrapResult;
/* Exact bounded stdin/stdout protocol; fixed argv/environment, suspended live
 * admission, owned process group. Ready runs while the candidate is alive and
 * blocked before profile access. Returning 1 must mean durable ACK + released
 * lifecycle fences. Success hands the child to normal application lifetime;
 * the separate one-shot owner then exits (no shared waitpid(-1) reaper).
 * Cancellation before handoff kills/reaps the exact reserved child/group.
 * Call on a utility worker. Synchronous trust callbacks are not preemptible. */
NeAntikBootstrapResult neantik_update_bootstrap_run(const char *candidate,
    const uint8_t request[192], uint32_t timeout_ms,
    NeAntikBootstrapAdmit admit, NeAntikBootstrapReady ready,
    NeAntikBootstrapCancel cancel, void *context);

/* Separate interactive owner transport, not filesystem/install authority.
 * All session calls run serially on one utility worker. Cancellation callback
 * alone may be read concurrently. Begin authenticates the suspended child
 * before SIGCONT; only fixed argv and a clean environment are supplied.
 * A failed begin may return a session if bounded child cleanup is incomplete.
 * The caller must retain it and retry abort; never free an owned live child. */
typedef struct NeAntikUpdateOwnerSession NeAntikUpdateOwnerSession;
typedef struct { int status, reaped, escalated; pid_t process_id; } NeAntikOwnerCleanup;
int neantik_update_owner_begin(const char *helper, uint32_t timeout_ms,
    NeAntikBootstrapAdmit admit, NeAntikBootstrapCancel cancel, void *context,
    NeAntikUpdateOwnerSession **session);
pid_t neantik_update_owner_pid(const NeAntikUpdateOwnerSession *session);
/* An absolute monotonic deadline. Zero means invalid duration/clock. */
uint64_t neantik_update_pipe_deadline(uint32_t timeout_ms);
/* Close the manager transport by replacing standard IO with /dev/null.
 * Descriptors 0..2 must remain reserved before bootstrap private pipes open.
 * Fixed OS device only; no caller path, inherited output or credentials. */
int neantik_update_owner_detach_standard_io(void);
/* Four-byte big-endian length followed by 1..128KiB. The body gets a separate
 * bounded budget starting at the first header byte, capped by the absolute
 * phase deadline: slow header/body bytes cannot reset either deadline. These
 * primitives require same-UID FIFO descriptors; EOF with partial data fails.
 * Raw fd variants are for the authenticated owner's stdin/stdout only. */
int neantik_update_pipe_read_frame(int fd, uint8_t *buffer, size_t capacity,
    size_t *received, uint64_t deadline, uint32_t frame_timeout_ms,
    NeAntikBootstrapCancel cancel, void *context);
int neantik_update_pipe_write_frame(int fd, const uint8_t *bytes, size_t count,
    uint64_t deadline, NeAntikBootstrapCancel cancel, void *context);
int neantik_update_pipe_expect_eof(int fd, uint64_t deadline,
    NeAntikBootstrapCancel cancel, void *context);
int neantik_update_owner_read_frame(NeAntikUpdateOwnerSession *session,
    uint8_t *buffer, size_t capacity, size_t *received, uint64_t deadline,
    uint32_t frame_timeout_ms, NeAntikBootstrapCancel cancel, void *context);
/* Cooperative client cancellation stops only before the first header byte.
 * Once a frame starts, finish it under the existing short frame deadline, so
 * a subsequent Cancelled response cannot be parsed from a discarded tail. */
int neantik_update_owner_read_frame_boundary(NeAntikUpdateOwnerSession *session,
    uint8_t *buffer, size_t capacity, size_t *received, uint64_t deadline,
    uint32_t frame_timeout_ms, NeAntikBootstrapCancel cancel, void *context);
int neantik_update_owner_write_frame(NeAntikUpdateOwnerSession *session,
    const uint8_t *bytes, size_t count, uint64_t deadline,
    NeAntikBootstrapCancel cancel, void *context);
/* Abort signals/reaps only this exact unreaped child, never a process group.
 * reaped proves leader exit only. escalated does NOT prove descendant cleanup.
 * No signals after reap, ECHILD or handoff. Dispose refuses a still-owned child.
 * Handoff closes pipes and relinquishes lifetime, but does not free session;
 * dispose is the sole deallocator. Only an authenticated
 * Accepted response plus explicit consent may authorize its caller to do so.
 * Neither Accepted nor EOF authorizes an app swap: stopped authority does. */
NeAntikOwnerCleanup neantik_update_owner_abort(NeAntikUpdateOwnerSession *session,
    uint32_t timeout_ms);
int neantik_update_owner_handoff(NeAntikUpdateOwnerSession *session);
int neantik_update_owner_dispose(NeAntikUpdateOwnerSession *session);
#endif
