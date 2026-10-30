#include <DirectAssessment.h>
#include <unistd.h>
#include <stdio.h>
#include <math.h>
#include <string.h>
#include <limits.h>
#include <errno.h>
#include <signal.h>

/* One request per fresh process. No shell, app launch, installation, policy
 * editing, credentials, arbitrary context/flags or persistent service. */
static int read_exact(void *buffer, size_t count) {
    size_t offset=0;
    while (offset<count) {
        ssize_t got=read(STDIN_FILENO,(char *)buffer+offset,count-offset);
        if (got<0 && errno==EINTR) continue;
        if (got<=0) return 0;
        offset+=(size_t)got;
    }
    return 1;
}
static uint32_t big32(const uint8_t *value) {
    return (uint32_t)value[0]<<24 | (uint32_t)value[1]<<16 | (uint32_t)value[2]<<8 | value[3];
}
int main(int argc, char **argv) {
    (void)argv;
    /* Also bounds incomplete stdin and non-cancellable private Security calls.
     * Parent timeout/cancellation must reap this exact owned process. */
    NeAntikAssessmentResult result={NEANTIK_ASSESSMENT_REQUEST,NAN,NAN};
    /* Ignored/blocked signals survive exec; restore this owned process's alarm
     * semantics without changing its parent's signal handling. */
    struct sigaction action={0}; action.sa_handler=SIG_DFL;
    sigemptyset(&action.sa_mask);
    sigset_t unblock; sigemptyset(&unblock); sigaddset(&unblock,SIGALRM);
    if (sigaction(SIGALRM,&action,NULL) || sigprocmask(SIG_UNBLOCK,&unblock,NULL)) goto reply;
    alarm(180);
    uint8_t header[32]; char path[PATH_MAX], trailing;
    if (argc!=1 || !read_exact(header,sizeof(header)) || memcmp(header,"NAA2",4)) goto reply;
    uint32_t length=big32(header+28);
    if (!length || length>=sizeof(path) || !read_exact(path,length) || memchr(path,0,length)) goto reply;
    path[length]=0;
    if (read(STDIN_FILENO,&trailing,1)!=0) goto reply;
    result=neantik_assessment_observe(path,header+4,big32(header+24));
reply:
    if (result.status==NEANTIK_ASSESSMENT_OK) {
        printf("{\"schema\":2,\"status\":0,\"offlineTicketDate\":%.6f,\"onlineTicketDate\":",result.offline_date);
        if (isnan(result.online_date)) fputs("null",stdout);
        else printf("%.6f",result.online_date);
        fputs(",\"onlineRevocationCheckCompleted\":true,\"freshRemoteResponseProven\":false,\"installAuthorized\":false}\n",stdout);
    } else {
        /* No raw errors, paths, labels or environment values reach logs. */
        printf("{\"schema\":2,\"status\":%d,\"gatekeeperAccepted\":%s,\"offlineTicketAccepted\":%s,\"onlineRevocationCheckCompleted\":%s,\"onlineDateAdmitted\":%s,\"systemErrorCode\":%lld,\"installAuthorized\":false}\n",
            result.status,result.gatekeeper_accepted ? "true":"false",result.offline_ticket_accepted ? "true":"false",
            result.online_lookup_success ? "true":"false",result.online_date_admitted ? "true":"false",(long long)result.system_error_code);
    }
    return result.status==NEANTIK_ASSESSMENT_OK ? 0 : 1;
}
