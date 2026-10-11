#include "DirectUpdateBootstrapParent.h"
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <signal.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static int never_cancel(void *unused) { (void)unused; return 0; }
static int raw_write(const unsigned char *bytes, size_t count) {
    for (size_t offset=0;offset<count;) {
        ssize_t sent=write(1,bytes+offset,count-offset);
        if (sent<0 && errno==EINTR) continue;
        if (sent<=0) return 0;
        offset+=(size_t)sent;
    }
    return 1;
}
int main(int argc,char **argv) {
    if (argc!=2 || strcmp(argv[1],"--neantik-update-owner-v1")) return 64;
    const char *mode=strrchr(argv[0],'/'); mode=mode ? mode+1:argv[0];
    if (!strcmp(mode,"hang-kill")) signal(SIGTERM,SIG_IGN);
    char marker[4096]; if (strlen(argv[0])+9>=sizeof(marker)) return 65;
    snprintf(marker,sizeof(marker),"%s.started",argv[0]);
    int fd=open(marker,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0600);
    if (fd<0) return 65; close(fd);
    if (!strcmp(mode,"hang-kill")) { for (;;) pause(); }
    if (!strcmp(mode,"hang")) { for (;;) pause(); }
    if (!strcmp(mode,"abnormal")) return 13;
    if (!strcmp(mode,"stderr")) { (void)write(2,"untrusted-output",16); for (;;) pause(); }
    if (!strcmp(mode,"closed")) { close(0); close(1); close(2); for (;;) pause(); }
    if (!strcmp(mode,"environment")) {
        if (getenv("NEANTIK_OWNER_TEST_SECRET") || getenv("DYLD_INSERT_LIBRARIES") || getenv("HOME") ||
            !getenv("LANG") || strcmp(getenv("LANG"),"C") || !getenv("TMPDIR") || strcmp(getenv("TMPDIR"),"/private/tmp")) return 14;
        char directory[4096]; if (!getcwd(directory,sizeof(directory)) || strcmp(directory,"/private/tmp")) return 15;
    }
    unsigned char bytes[128*1024]; size_t count=0;
    if (neantik_update_pipe_read_frame(0,bytes,sizeof(bytes),&count,neantik_update_pipe_deadline(3000),1000,never_cancel,NULL)) return 16;
    if (!strcmp(mode,"descendant")) {
        pid_t descendant=fork(); if (descendant<0) return 23;
        if (!descendant) {
            usleep(500000); char done[4096]; snprintf(done,sizeof(done),"%s.descendant-done",argv[0]);
            int finished=open(done,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0600); if (finished>=0) close(finished);
            _exit(0);
        }
        unsigned char child[4]={(unsigned char)(descendant>>24),(unsigned char)(descendant>>16),(unsigned char)(descendant>>8),(unsigned char)descendant};
        if (neantik_update_pipe_write_frame(1,child,4,neantik_update_pipe_deadline(1000),never_cancel,NULL)) return 24;
        for (;;) pause();
    }
    if (!strcmp(mode,"descriptor")) {
        if (count!=1 || bytes[0]<=2 || fcntl(bytes[0],F_GETFD)!=-1 || errno!=EBADF) return 17;
    }
    if (!strcmp(mode,"zero") || !strcmp(mode,"oversize")) {
        unsigned char header[4]={0,2,0,1}; if (!strcmp(mode,"zero")) memset(header,0,sizeof(header));
        if (!raw_write(header,4)) return 18; for (;;) pause();
    }
    if (!strcmp(mode,"partial-header")) { unsigned char header[2]={0,0}; raw_write(header,2); close(1); for (;;) pause(); }
    if (!strcmp(mode,"partial-body")) { unsigned char part[6]={0,0,0,4,1,2}; raw_write(part,6); close(1); for (;;) pause(); }
    if (!strcmp(mode,"drip-header") || !strcmp(mode,"drip-body")) {
        unsigned char header[4]={0,0,0,4};
        if (!strcmp(mode,"drip-header")) { for (int n=0;n<4;n++) { raw_write(header+n,1); usleep(80000); } }
        else { raw_write(header,4); for (int n=0;n<4;n++) { raw_write(header+3,1); usleep(80000); } }
        for (;;) pause();
    }
    if (!strcmp(mode,"idle-delay")) usleep(200000);
    if (neantik_update_pipe_write_frame(1,bytes,count,neantik_update_pipe_deadline(1000),never_cancel,NULL)) return 19;
    if (neantik_update_pipe_read_frame(0,bytes,sizeof(bytes),&count,neantik_update_pipe_deadline(3000),1000,never_cancel,NULL)) return 20;
    if (neantik_update_pipe_write_frame(1,bytes,count,neantik_update_pipe_deadline(1000),never_cancel,NULL)) return 21;
    if (neantik_update_pipe_expect_eof(0,neantik_update_pipe_deadline(3000),never_cancel,NULL)) return 22;
    return 0;
}
