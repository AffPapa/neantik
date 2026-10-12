#include "DirectUpdateBootstrapParent.h"
#include <spawn.h>
#include <sys/spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/poll.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <limits.h>

#define OWNER_FRAME_MAX (128U * 1024U)
struct NeAntikUpdateOwnerSession { pid_t pid; int input, output, errors, owned, reaped; };
static uint64_t owner_now(void) {
    struct timespec t; if (clock_gettime(CLOCK_MONOTONIC, &t)) return 0;
    return (uint64_t)t.tv_sec * 1000 + (uint64_t)t.tv_nsec / 1000000;
}
uint64_t neantik_update_pipe_deadline(uint32_t timeout_ms) {
    uint64_t now = owner_now();
    return now && timeout_ms && timeout_ms <= 300000 && now <= UINT64_MAX-timeout_ms ? now+timeout_ms : 0;
}
static void owner_close(int *fd) { if (*fd >= 0) { close(*fd); *fd = -1; } }
static void owner_close_pipes(NeAntikUpdateOwnerSession *s) {
    owner_close(&s->input); owner_close(&s->output); owner_close(&s->errors);
}
static int owner_pipe(int fds[2]) {
    if (pipe(fds)) return 0;
    if (fds[0] <= 2 || fds[1] <= 2) return 0;
    for (int n=0;n<2;n++) {
        int flags=fcntl(fds[n],F_GETFL);
        if (flags<0 || fcntl(fds[n],F_SETFL,flags|O_NONBLOCK)<0 || fcntl(fds[n],F_SETFD,FD_CLOEXEC)<0) return 0;
    }
    return 1;
}
static int owner_prepare_fd(int fd, int writing) {
    struct stat st;
    if (fd<0 || fstat(fd,&st) || !S_ISFIFO(st.st_mode) || st.st_uid!=geteuid()) return 0;
    int flags=fcntl(fd,F_GETFL), access=flags&O_ACCMODE;
    if (flags<0 || (writing ? access==O_RDONLY : access==O_WRONLY) || fcntl(fd,F_SETFL,flags|O_NONBLOCK)<0) return 0;
    return !writing || fcntl(fd,F_SETNOSIGPIPE,1)==0;
}
/* Exact reserved leader only. ECHILD relinquishes signal authority; it cannot
 * be represented as a successful reap. Never use waitpid(-1) here. */
static int owner_alive(NeAntikUpdateOwnerSession *s) {
    if (!s || !s->owned) return NUB_WAIT;
    int status; pid_t got;
    do { got=waitpid(s->pid,&status,WNOHANG); } while (got<0 && errno==EINTR);
    if (!got) return NUB_COMPLETE;
    if (got==s->pid || (got<0 && errno==ECHILD)) {
        s->owned=0; s->reaped=got==s->pid;
    }
    return NUB_WAIT;
}
static int owner_stderr(NeAntikUpdateOwnerSession *s) {
    if (!s || s->errors<0) return NUB_COMPLETE;
    uint8_t byte; ssize_t got=read(s->errors,&byte,1);
    if (got>0) return NUB_OUTPUT;
    if (!got) { owner_close(&s->errors); return NUB_COMPLETE; }
    return errno==EAGAIN || errno==EINTR ? NUB_COMPLETE : NUB_IO;
}
static int owner_check(uint64_t deadline, NeAntikBootstrapCancel cancel, void *context, NeAntikUpdateOwnerSession *s) {
    if (!cancel || !deadline) return NUB_REQUEST;
    if (cancel(context)) return NUB_CANCELLED;
    uint64_t now=owner_now(); if (!now || now>=deadline) return NUB_TIMEOUT;
    if (deadline-now>300000) return NUB_REQUEST;
    if (s) { int status=owner_alive(s); if (status) return status; return owner_stderr(s); }
    return NUB_COMPLETE;
}
static int owner_poll(int fd, short events, uint64_t deadline, NeAntikBootstrapCancel cancel, void *context, NeAntikUpdateOwnerSession *s) {
    int status=owner_check(deadline,cancel,context,s); if (status) return status;
    uint64_t now=owner_now(); if (!now || now>=deadline) return NUB_TIMEOUT;
    struct pollfd fds[2]={{fd,events,0},{s ? s->errors:-1,POLLIN,0}};
    int ready=poll(fds,2,(int)((deadline-now)<20 ? deadline-now:20));
    if (ready<0) return errno==EINTR ? NUB_COMPLETE:NUB_IO;
    if ((fds[0].revents|fds[1].revents)&POLLNVAL) return NUB_IO;
    return s ? owner_stderr(s):NUB_COMPLETE;
}
static int owner_uncancelled(void *context) { (void)context; return 0; }
int neantik_update_owner_detach_standard_io(void) {
    int fd=open("/dev/null",O_RDWR|O_NOFOLLOW|O_CLOEXEC);
    if (fd<0) return 0;
    struct stat st;
    if (fstat(fd,&st) || !S_ISCHR(st.st_mode)) { close(fd); return 0; }
    for (int target=0;target<3;target++) {
        if (dup2(fd,target)<0 || fcntl(target,F_SETFD,0)<0) {
            if (fd>2) close(fd);
            return 0;
        }
    }
    if (fd>2) close(fd);
    return 1;
}
static int owner_read(int fd, uint8_t *buffer, size_t capacity, size_t *received,
    uint64_t deadline, uint32_t frame_ms, NeAntikBootstrapCancel cancel, void *context, NeAntikUpdateOwnerSession *s, int boundary) {
    if (received) *received=0;
    if (!buffer || !received || !capacity || capacity>OWNER_FRAME_MAX || !deadline || !cancel ||
        !frame_ms || frame_ms>10000 || !owner_prepare_fd(fd,0)) return NUB_REQUEST;
    uint8_t header[4]; size_t header_bytes=0, length=0, offset=0;
    uint64_t body_deadline=deadline;
    while (header_bytes<4 || offset<length) {
        NeAntikBootstrapCancel current_cancel = boundary && header_bytes ? owner_uncancelled:cancel;
        int status=owner_check(body_deadline,current_cancel,context,s); if (status) return status;
        size_t count=header_bytes<4 ? 4-header_bytes:length-offset;
        ssize_t got=read(fd,header_bytes<4 ? header+header_bytes:buffer+offset,count);
        if (got<0 && (errno==EINTR || errno==EAGAIN)) {
            status=owner_poll(fd,POLLIN,body_deadline,current_cancel,context,s); if (status) return status; continue;
        }
        if (got<0) return NUB_IO;
        if (!got) return !header_bytes ? NUB_EOF:NUB_OUTPUT;
        if (!header_bytes) {
            uint64_t now=owner_now(); if (!now || now>UINT64_MAX-frame_ms) return NUB_TIMEOUT;
            uint64_t bounded=now+frame_ms; if (bounded<body_deadline) body_deadline=bounded;
        }
        if (header_bytes<4) {
            header_bytes+=(size_t)got;
            if (header_bytes==4) {
                length=((size_t)header[0]<<24)|((size_t)header[1]<<16)|((size_t)header[2]<<8)|header[3];
                if (!length || length>capacity || length>OWNER_FRAME_MAX) return NUB_FRAME;
            }
        } else offset+=(size_t)got;
    }
    int status=owner_check(body_deadline,boundary ? owner_uncancelled:cancel,context,s); if (status) return status;
    *received=offset; return NUB_COMPLETE;
}
static int owner_write(int fd, const uint8_t *bytes, size_t count, uint64_t deadline,
    NeAntikBootstrapCancel cancel, void *context, NeAntikUpdateOwnerSession *s) {
    if (!bytes || !count || count>OWNER_FRAME_MAX || !deadline || !cancel || !owner_prepare_fd(fd,1)) return NUB_REQUEST;
    uint8_t header[4]={(uint8_t)(count>>24),(uint8_t)(count>>16),(uint8_t)(count>>8),(uint8_t)count};
    size_t offset=0;
    while (offset<count+4) {
        int status=owner_check(deadline,cancel,context,s); if (status) return status;
        ssize_t sent=write(fd,offset<4 ? header+offset:bytes+offset-4,offset<4 ? 4-offset:count+4-offset);
        if (sent<0 && (errno==EINTR || errno==EAGAIN)) {
            status=owner_poll(fd,POLLOUT,deadline,cancel,context,s); if (status) return status; continue;
        }
        if (sent<=0) return NUB_INPUT;
        offset+=(size_t)sent;
    }
    return owner_check(deadline,cancel,context,s);
}
int neantik_update_pipe_read_frame(int fd,uint8_t *buffer,size_t capacity,size_t *received,uint64_t deadline,
    uint32_t frame_ms,NeAntikBootstrapCancel cancel,void *context) { return owner_read(fd,buffer,capacity,received,deadline,frame_ms,cancel,context,NULL,0); }
int neantik_update_pipe_write_frame(int fd,const uint8_t *bytes,size_t count,uint64_t deadline,
    NeAntikBootstrapCancel cancel,void *context) { return owner_write(fd,bytes,count,deadline,cancel,context,NULL); }
int neantik_update_pipe_expect_eof(int fd,uint64_t deadline,NeAntikBootstrapCancel cancel,void *context) {
    if (!deadline || !cancel || !owner_prepare_fd(fd,0)) return NUB_REQUEST;
    while (1) {
        int status=owner_check(deadline,cancel,context,NULL); if (status) return status;
        uint8_t byte; ssize_t got=read(fd,&byte,1);
        if (!got) return NUB_COMPLETE;
        if (got>0) return NUB_OUTPUT;
        if (errno!=EINTR && errno!=EAGAIN) return NUB_IO;
        status=owner_poll(fd,POLLIN,deadline,cancel,context,NULL); if (status) return status;
    }
}
int neantik_update_owner_read_frame(NeAntikUpdateOwnerSession *s,uint8_t *buffer,size_t capacity,size_t *received,
    uint64_t deadline,uint32_t frame_ms,NeAntikBootstrapCancel cancel,void *context) {
    return s ? owner_read(s->output,buffer,capacity,received,deadline,frame_ms,cancel,context,s,0):NUB_REQUEST;
}
int neantik_update_owner_read_frame_boundary(NeAntikUpdateOwnerSession *s,uint8_t *buffer,size_t capacity,size_t *received,
    uint64_t deadline,uint32_t frame_ms,NeAntikBootstrapCancel cancel,void *context) {
    return s ? owner_read(s->output,buffer,capacity,received,deadline,frame_ms,cancel,context,s,1):NUB_REQUEST;
}
int neantik_update_owner_write_frame(NeAntikUpdateOwnerSession *s,const uint8_t *bytes,size_t count,
    uint64_t deadline,NeAntikBootstrapCancel cancel,void *context) {
    return s ? owner_write(s->input,bytes,count,deadline,cancel,context,s):NUB_REQUEST;
}
pid_t neantik_update_owner_pid(const NeAntikUpdateOwnerSession *s) { return s ? s->pid:0; }
NeAntikOwnerCleanup neantik_update_owner_abort(NeAntikUpdateOwnerSession *s,uint32_t timeout_ms) {
    NeAntikOwnerCleanup result={NUB_REQUEST,0,0,s ? s->pid:0};
    if (!s || !timeout_ms || timeout_ms>5000) return result;
    owner_close_pipes(s);
    if (!s->owned) { result.status=s->reaped ? NUB_COMPLETE:NUB_WAIT; result.reaped=s->reaped; return result; }
    if (owner_alive(s)) { result.status=s->reaped ? NUB_COMPLETE:NUB_WAIT; result.reaped=s->reaped; return result; }
    uint64_t start=owner_now(); if (!start) { result.status=NUB_IO; return result; }
    uint64_t deadline=start+timeout_ms, grace=start+timeout_ms/2;
    // Signals are issued only while we still own the exact unreaped child.
    (void)kill(s->pid,SIGTERM);
    while (s->owned) {
        if (owner_alive(s)) break;
        uint64_t now=owner_now(); if (!now || now>=deadline) { result.status=NUB_TIMEOUT; return result; }
        if (!result.escalated && now>=grace) { result.escalated=1; (void)kill(s->pid,SIGKILL); }
        (void)poll(NULL,0,10);
    }
    result.status=s->reaped ? NUB_COMPLETE:NUB_WAIT; result.reaped=s->reaped; return result;
}
int neantik_update_owner_handoff(NeAntikUpdateOwnerSession *s) {
    if (!s) return NUB_REQUEST;
    int status=owner_alive(s); if (status) return status;
    status=owner_stderr(s); if (status) return status;
    owner_close_pipes(s); s->owned=0; return NUB_COMPLETE;
}
int neantik_update_owner_dispose(NeAntikUpdateOwnerSession *s) {
    if (!s) return NUB_COMPLETE;
    if (s->owned) return NUB_WAIT;
    owner_close_pipes(s); free(s); return NUB_COMPLETE;
}
int neantik_update_owner_begin(const char *helper,uint32_t timeout_ms,NeAntikBootstrapAdmit admit,
    NeAntikBootstrapCancel cancel,void *context,NeAntikUpdateOwnerSession **session) {
    if (session) *session=NULL;
    uint64_t deadline=neantik_update_pipe_deadline(timeout_ms);
    struct sigaction child_signal;
    if (!session || !helper || helper[0]!='/' || strnlen(helper,PATH_MAX)>=PATH_MAX || !admit || !cancel ||
        !deadline || timeout_ms>60000 || sigaction(SIGCHLD,NULL,&child_signal) || child_signal.sa_handler==SIG_IGN || (child_signal.sa_flags&SA_NOCLDWAIT)) return NUB_REQUEST;
    int status=owner_check(deadline,cancel,context,NULL); if (status) return status;
    NeAntikUpdateOwnerSession *s=calloc(1,sizeof(*s)); if (!s) return NUB_IO;
    s->input=s->output=s->errors=-1;
    int in[2]={-1,-1},out[2]={-1,-1},err[2]={-1,-1},actions_ready=0,attr_ready=0;
    posix_spawn_file_actions_t actions; posix_spawnattr_t attr;
    status=NUB_IO;
    if (!owner_pipe(in) || !owner_pipe(out) || !owner_pipe(err) || fcntl(in[1],F_SETNOSIGPIPE,1)) goto done;
    int child_fds[3]={in[0],out[1],err[1]};
    for (int n=0;n<3;n++) { int flags=fcntl(child_fds[n],F_GETFL); if (flags<0 || fcntl(child_fds[n],F_SETFL,flags&~O_NONBLOCK)<0) goto done; }
    if (posix_spawn_file_actions_init(&actions)) goto done; actions_ready=1;
    if (posix_spawnattr_init(&attr)) goto done; attr_ready=1;
    for (int n=0;n<3;n++) if (posix_spawn_file_actions_adddup2(&actions,child_fds[n],n)) goto done;
    if (posix_spawn_file_actions_addchdir_np(&actions,"/private/tmp")) goto done;
    sigset_t empty,defaults; sigemptyset(&empty); sigemptyset(&defaults);
    sigaddset(&defaults,SIGALRM); sigaddset(&defaults,SIGPIPE); sigaddset(&defaults,SIGTERM); sigaddset(&defaults,SIGINT); sigaddset(&defaults,SIGHUP);
    if (posix_spawnattr_setsigmask(&attr,&empty) || posix_spawnattr_setsigdefault(&attr,&defaults) || posix_spawnattr_setpgroup(&attr,0) ||
        posix_spawnattr_setflags(&attr,POSIX_SPAWN_START_SUSPENDED|POSIX_SPAWN_CLOEXEC_DEFAULT|POSIX_SPAWN_SETSIGMASK|POSIX_SPAWN_SETSIGDEF|POSIX_SPAWN_SETPGROUP)) goto done;
    char *argv[]={(char *)helper,"--neantik-update-owner-v1",NULL};
    char *environment[]={"PATH=/usr/bin:/bin:/usr/sbin:/sbin","LANG=C","TMPDIR=/private/tmp",NULL};
    status=NUB_SPAWN;
    if (posix_spawn(&s->pid,helper,&actions,&attr,argv,environment)) goto done;
    s->owned=1; s->input=in[1]; in[1]=-1; s->output=out[0]; out[0]=-1; s->errors=err[0]; err[0]=-1;
    owner_close(&in[0]); owner_close(&out[1]); owner_close(&err[1]);
    status=owner_check(deadline,cancel,context,s); if (status) goto done;
    status=NUB_ADMISSION; if (admit(s->pid,context)!=1) goto done;
    status=owner_check(deadline,cancel,context,s); if (status) goto done;
    status=NUB_ADMISSION; if (kill(s->pid,SIGCONT)) goto done;
    status=NUB_COMPLETE;
done:
    for (int n=0;n<2;n++) { owner_close(&in[n]); owner_close(&out[n]); owner_close(&err[n]); }
    if (actions_ready) posix_spawn_file_actions_destroy(&actions);
    if (attr_ready) posix_spawnattr_destroy(&attr);
    if (status!=NUB_COMPLETE) {
        if (s->owned) (void)neantik_update_owner_abort(s,1000);
        if (!s->owned) { (void)neantik_update_owner_dispose(s); return status; }
    }
    *session=s; return status;
}
