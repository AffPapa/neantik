#include "DirectAssessmentParent.h"
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <limits.h>
#include <sys/stat.h>
/* Test executable only; no update or installation access. Behaviour selected
 * by a bounded stdin fixture request, never by shell/arguments/environment. */
static int admit(pid_t pid,void *context) { return 1; }
static int cancel(void *context) { return 0; }
int main(int argc,char **argv) {
#ifndef DEBUG
    return 99;
#else
    if (argc!=1 || !argv[0] || !strstr(argv[0],"/private/tmp/neantik-assessment-parent-")) return 98;
    char input[PATH_MAX+33]; size_t n=0;
    for (;;) { ssize_t got=read(0,input+n,sizeof(input)-1-n); if (got<0) return 97; if (!got) break; n+=(size_t)got; if(n>=sizeof(input)-1) return 96; }
    input[n]=0;
    int native_request=n>32 && !memcmp(input,"NAA2",4);
    if (native_request) {
        char *last=strrchr(input+32,'/');
        if (last && !strcmp(last+1,"hang")) strcpy(input,"hang");
    }
    /* Full EOF required before any output. */
    if (!strcmp(input,"hang")) {
        if (native_request) {
            char marker[PATH_MAX]; strncpy(marker,argv[0],sizeof(marker)); marker[sizeof(marker)-1]=0;
            char *leaf=strrchr(marker,'/'); if (!leaf) return 91; *leaf=0;
            leaf=strrchr(marker,'/'); if (!leaf) return 90; *leaf=0;
            if (strlen(marker)+7>=sizeof(marker)) return 89; strcat(marker,"/ready");
            int fd=open(marker,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0600); if(fd<0) return 88; close(fd);
        }
        if (write(1,"READY",5)!=5) return 88;
        if (!native_request) {
            char marker[PATH_MAX]; strncpy(marker,argv[0],sizeof(marker)); marker[sizeof(marker)-1]=0;
            char *leaf=strrchr(marker,'/'); if (!leaf) return 91; *leaf=0;
            if (strlen(marker)+7>=sizeof(marker)) return 89; strcat(marker,"/ready");
            int fd=open(marker,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0600); if(fd<0) return 88; close(fd);
        }
        signal(SIGTERM,SIG_IGN); for (;;) pause(); }
    if (!strcmp(input,"closed-stdio")) { close(0); close(1); close(2); for (;;) pause(); }
    if (!strcmp(input,"descendant")) { pid_t child=fork(); if (!child) { for (;;) pause(); } char b[64]; int len=snprintf(b,sizeof(b),"%d",child); write(1,b,(size_t)len); return 0; }
    if (!strcmp(input,"autoreap-ignore") || !strcmp(input,"autoreap-no-wait")) {
        struct sigaction action; memset(&action,0,sizeof(action)); sigemptyset(&action.sa_mask);
        action.sa_handler=!strcmp(input,"autoreap-ignore") ? SIG_IGN : SIG_DFL;
        action.sa_flags=!strcmp(input,"autoreap-no-wait") ? SA_NOCLDWAIT : 0;
        if (sigaction(SIGCHLD,&action,NULL)) return 93;
        uint8_t body[2]={'o','k'};
        NeAntikAssessmentParentResult result=neantik_assessment_parent_run(argv[0],body,2,100,admit,cancel,NULL);
        if (result.status!=NAP_REQUEST || result.process_id!=0 || result.continued || result.reaped) return 92;
    }
    if (!strcmp(input,"stderr")) { write(2,"fixture",7); return 0; }
    if (!strcmp(input,"flood")) { char b[256]; memset(b,'x',sizeof(b)); for(int i=0;i<8;i++) write(1,b,sizeof(b)); return 0; }
    if (!strcmp(input,"abnormal")) { raise(SIGKILL); return 0; }
    if (!strcmp(input,"environment")) {
        if (getenv("HOME") || getenv("DYLD_INSERT_LIBRARIES") || getenv("NEANTIK_ASSESSMENT_TEST_SECRET") || !getenv("LANG") || strcmp(getenv("LANG"),"C")) return 95;
    }
    if (!strncmp(input,"descriptor:",11)) { int fd=atoi(input+11); if (fd>2 && fcntl(fd,F_GETFD)>=0) return 94; }
    if (!strcmp(input,"malformed")) { write(1,"{}\n",3); return 0; }
    const char *reply="{\"schema\":2,\"status\":5,\"gatekeeperAccepted\":false,\"offlineTicketAccepted\":false,\"onlineRevocationCheckCompleted\":false,\"onlineDateAdmitted\":false,\"systemErrorCode\":0,\"installAuthorized\":false}\n";
    write(1,reply,strlen(reply)); return 1;
#endif
}
