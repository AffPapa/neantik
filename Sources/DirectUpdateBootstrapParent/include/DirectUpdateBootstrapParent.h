#ifndef NEANTIK_UPDATE_BOOTSTRAP_PARENT_H
#define NEANTIK_UPDATE_BOOTSTRAP_PARENT_H
#include <sys/types.h>
#include <stddef.h>
#include <stdint.h>
enum { NUB_COMPLETE=0, NUB_REQUEST=1, NUB_SPAWN=2, NUB_ADMISSION=3,
       NUB_CANCELLED=4, NUB_TIMEOUT=5, NUB_OUTPUT=6, NUB_INPUT=7, NUB_WAIT=8, NUB_IO=9 };
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
#endif
