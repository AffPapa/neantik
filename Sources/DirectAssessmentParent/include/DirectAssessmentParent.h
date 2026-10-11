#ifndef NEANTIK_ASSESSMENT_PARENT_H
#define NEANTIK_ASSESSMENT_PARENT_H
#include <sys/types.h>
#include <stddef.h>
#include <stdint.h>
enum {
    NAP_COMPLETE=0, NAP_REQUEST=1, NAP_SPAWN=2, NAP_ADMISSION=3,
    NAP_CANCELLED=4, NAP_TIMEOUT=5, NAP_OUTPUT=6, NAP_INPUT=7, NAP_WAIT=8, NAP_IO=9
};
typedef struct {
    int status, exit_code, exited_normally, reaped, continued;
    pid_t process_id;
    size_t output_bytes;
    uint8_t output[1024];
} NeAntikAssessmentParentResult;
typedef int (*NeAntikParentAdmit)(pid_t,void *);
typedef int (*NeAntikParentCancel)(void *);
/* One path-selected guest starts suspended. admit must authenticate that live
 * guest and revalidate owned helper custody before returning1. No shell/argv,
 * inherited environment, global signal changes or installed-app mutation.
 * Parent must be the sole wait owner of this child; no external wait(-1)
 * reaper or concurrent SIGCHLD policy changes. Auto-reap policy refuses spawn.
 * Call on a utility worker. Admission callback is synchronous/non-preemptible;
 * no claim of bounding a stalled Security.framework call is made here. */
NeAntikAssessmentParentResult neantik_assessment_parent_run(const char *helper,
    const uint8_t *request,size_t request_bytes,uint32_t timeout_ms,
    NeAntikParentAdmit admit,NeAntikParentCancel cancel,void *context);
#endif
