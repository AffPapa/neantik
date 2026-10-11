#include "DirectUpdateBootstrapParent.h"
#include <spawn.h>
#include <sys/spawn.h>
#include <sys/wait.h>
#include <sys/poll.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <string.h>
#include <limits.h>

static uint64_t monotonic_ms(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC,&t)) return 0;
    return (uint64_t)t.tv_sec*1000+(uint64_t)t.tv_nsec/1000000;
}
static void close_fd(int *fd) { if (*fd>=0) { close(*fd); *fd=-1; } }
static int private_pipe(int pair[2]) {
    if (pipe(pair)) return 0;
    if (pair[0]<=2 || pair[1]<=2) return 0;
    for (int n=0;n<2;n++) {
        if (fcntl(pair[n],F_SETFD,FD_CLOEXEC)<0) return 0;
        int flags=fcntl(pair[n],F_GETFL);
        if (flags<0 || fcntl(pair[n],F_SETFL,flags|O_NONBLOCK)<0) return 0;
    }
    return 1;
}
static int spawn_action(int result) { return result==0; }

NeAntikBootstrapResult neantik_update_bootstrap_run(const char *helper,
    const uint8_t request[192],uint32_t timeout_ms,
    NeAntikBootstrapAdmit admit,NeAntikBootstrapReady ready,
    NeAntikBootstrapCancel cancel,void *context) {
    NeAntikBootstrapResult result={0}; result.status=NUB_REQUEST;
    const size_t request_bytes=192;
    uint8_t output[128]; size_t output_bytes=0;
    int in[2]={-1,-1},out[2]={-1,-1},err[2]={-1,-1},child_status=0;
    int actions_ready=0,attributes_ready=0,owned=0;
    posix_spawn_file_actions_t actions; posix_spawnattr_t attributes;
    if (!helper || helper[0]!='/' || strnlen(helper,PATH_MAX)>=PATH_MAX || !request ||
        !timeout_ms || timeout_ms>60000 || !admit || !ready || !cancel) goto done;
    struct sigaction child_signal;
    if (sigaction(SIGCHLD,NULL,&child_signal) || child_signal.sa_handler==SIG_IGN || (child_signal.sa_flags&SA_NOCLDWAIT)) goto done;
    uint64_t now=monotonic_ms(); if (!now) { result.status=NUB_IO; goto done; }
    uint64_t deadline=now+timeout_ms;
    if (cancel(context)) { result.status=NUB_CANCELLED; goto done; }
    result.status=NUB_IO;
    if (!private_pipe(in) || !private_pipe(out) || !private_pipe(err) || fcntl(in[1],F_SETNOSIGPIPE,1)) goto done;
    // Child endpoints are blocking; parent's endpoints stay nonblocking.
    int child_fds[3]={in[0],out[1],err[1]};
    for (int n=0;n<3;n++) {
        int flags=fcntl(child_fds[n],F_GETFL);
        if (flags<0 || fcntl(child_fds[n],F_SETFL,flags&~O_NONBLOCK)<0) goto done;
    }
    if (posix_spawn_file_actions_init(&actions)) goto done; actions_ready=1;
    if (posix_spawnattr_init(&attributes)) goto done; attributes_ready=1;
    for (int n=0;n<3;n++) if (!spawn_action(posix_spawn_file_actions_adddup2(&actions,child_fds[n],n))) goto done;
    if (!spawn_action(posix_spawn_file_actions_addchdir_np(&actions,"/private/tmp"))) goto done;
    sigset_t empty,defaults; sigemptyset(&empty); sigemptyset(&defaults);
    sigaddset(&defaults,SIGALRM); sigaddset(&defaults,SIGPIPE); sigaddset(&defaults,SIGTERM);
    sigaddset(&defaults,SIGINT); sigaddset(&defaults,SIGHUP);
    if (posix_spawnattr_setsigmask(&attributes,&empty) || posix_spawnattr_setsigdefault(&attributes,&defaults) ||
        posix_spawnattr_setpgroup(&attributes,0) || posix_spawnattr_setflags(&attributes,
        POSIX_SPAWN_START_SUSPENDED|POSIX_SPAWN_CLOEXEC_DEFAULT|POSIX_SPAWN_SETSIGMASK|POSIX_SPAWN_SETSIGDEF|POSIX_SPAWN_SETPGROUP)) goto done;
    char *argv[]={(char *)helper,"--neantik-update-bootstrap-v1",NULL};
    char *environment[]={"PATH=/usr/bin:/bin:/usr/sbin:/sbin","LANG=C","TMPDIR=/private/tmp",NULL};
    result.status=NUB_SPAWN;
    if (posix_spawn(&result.process_id,helper,&actions,&attributes,argv,environment)) goto done;
    owned=1; close_fd(&in[0]); close_fd(&out[1]); close_fd(&err[1]);
    if (cancel(context)) { result.status=NUB_CANCELLED; goto done; }
    result.status=NUB_ADMISSION;
    if (admit(result.process_id,context)!=1) goto done;
    if (cancel(context)) { result.status=NUB_CANCELLED; goto done; }
    if (!(now=monotonic_ms()) || now>=deadline) { result.status=NUB_TIMEOUT; goto done; }
    if (kill(result.process_id,SIGCONT)) goto done;
    result.continued=1; size_t input_offset=0;
    // Never reap until all output endpoints close. If a controlled broken
    // guest leaves a descendant holding them, timeout kills our still-owned
    // process group before reaping the reserved leader PID. No later signals.
    while (input_offset<request_bytes || out[0]>=0 || err[0]>=0) {
        if (cancel(context)) { result.status=NUB_CANCELLED; goto done; }
        now=monotonic_ms(); if (!now || now>=deadline) { result.status=NUB_TIMEOUT; goto done; }
        struct pollfd fds[3]={{input_offset<request_bytes ? in[1]:-1,POLLOUT,0},{out[0],POLLIN,0},{err[0],POLLIN,0}};
        int ready=poll(fds,3,(int)((deadline-now)<20 ? deadline-now:20));
        if (ready<0 && errno==EINTR) continue;
        if (ready<0) { result.status=NUB_IO; goto done; }
        for (int n=1;n<3;n++) {
            int *fd=n==1 ? &out[0]:&err[0];
            if (*fd<0 || !(fds[n].revents&(POLLIN|POLLHUP|POLLERR))) continue;
            uint8_t buffer[256]; ssize_t got=read(*fd,buffer,sizeof(buffer));
            if (got<0 && (errno==EINTR || errno==EAGAIN)) continue;
            if (got<0) { result.status=NUB_IO; goto done; }
            if (!got) { close_fd(fd); continue; }
            if (n==2 || (size_t)got>sizeof(output)-output_bytes) { result.status=NUB_OUTPUT; goto done; }
            memcpy(output+output_bytes,buffer,(size_t)got); output_bytes+=(size_t)got;
        }
        if (input_offset<request_bytes && (fds[0].revents&(POLLOUT|POLLHUP|POLLERR))) {
            ssize_t sent=write(in[1],request+input_offset,request_bytes-input_offset);
            if (sent<0 && (errno==EINTR || errno==EAGAIN)) continue;
            if (sent<=0) { result.status=NUB_INPUT; goto done; }
            input_offset+=(size_t)sent;
            // Keep private stdin open: candidate waits for authenticated continue.
        }
        for (int n=0;n<3;n++) if (fds[n].revents&POLLNVAL) { result.status=NUB_IO; goto done; }
    }
    // Exact complete reply + EOF; a live child remains blocked on private stdin.
    // No ACK from partial output, a crashed child or a descendant holding IO.
    if (output_bytes!=sizeof(output)) { result.status=NUB_OUTPUT; goto done; }
    if (cancel(context)) { result.status=NUB_CANCELLED; goto done; }
    if (!(now=monotonic_ms()) || now>=deadline) { result.status=NUB_TIMEOUT; goto done; }
    pid_t observed;
    do { observed=waitpid(result.process_id,&child_status,WNOHANG); } while (observed<0 && errno==EINTR);
    if (observed!=0) {
        result.status=NUB_WAIT;
        // A reaped child (or lost wait ownership) is no longer signal authority.
        owned=0; result.reaped=observed==result.process_id; goto done;
    }
    result.status=NUB_ADMISSION;
    if (ready(result.process_id,output,output_bytes,context)!=1) goto done;
    // Ready may have published a durable ACK. From now on cancellation cannot
    // undo that decision. Any send failure still leaves ACK recovery to owner.
    uint8_t command[36]; memcpy(command,"NUC1",4); memcpy(command+4,request+4,32);
    size_t offset=0;
    while (offset<sizeof(command)) {
        now=monotonic_ms(); if (!now || now>=deadline) { result.status=NUB_TIMEOUT; goto done; }
        ssize_t sent=write(in[1],command+offset,sizeof(command)-offset);
        if (sent<0 && (errno==EINTR || errno==EAGAIN)) { (void)poll(NULL,0,10); continue; }
        if (sent<=0) { result.status=NUB_INPUT; goto done; }
        offset+=(size_t)sent;
    }
    close_fd(&in[1]);
    // Success transfers lifetime custody; the one-shot owner exits. It must not
    // signal or reap this application after returning a handed-off result.
    owned=0; result.handed_off=1; result.status=NUB_COMPLETE;
done:
    close_fd(&in[0]); close_fd(&in[1]); close_fd(&out[0]); close_fd(&out[1]); close_fd(&err[0]); close_fd(&err[1]);
    if (owned) {
        // The leader is still this parent's unreaped child, including zombies.
        // Its PID/group cannot be reassigned before the following exact wait.
        (void)kill(-result.process_id,SIGKILL); (void)kill(result.process_id,SIGKILL);
        pid_t got; do { got=waitpid(result.process_id,&child_status,0); } while (got<0 && errno==EINTR);
        result.reaped=got==result.process_id;
    }
    if (actions_ready) posix_spawn_file_actions_destroy(&actions);
    if (attributes_ready) posix_spawnattr_destroy(&attributes);
    return result;
}
