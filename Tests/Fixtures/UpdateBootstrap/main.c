#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <string.h>
#include <stdlib.h>
#include <CommonCrypto/CommonDigest.h>
/* Controlled transport fixture only. No signature/readiness/install authority. */
static int exact(int fd, void *buffer,size_t count) {
    size_t offset=0;
    while (offset<count) { ssize_t n=read(fd,(char *)buffer+offset,count-offset); if(n<=0)return 0;offset+=(size_t)n; }
    return 1;
}
int main(int argc,char **argv) {
#ifndef DEBUG
    return 99;
#else
    if(argc!=2 || strcmp(argv[1],"--neantik-update-bootstrap-v1") || !strstr(argv[0],"/private/tmp/neantik-bootstrap-parent-")) return 98;
    const char *name=strrchr(argv[0],'/');if(!name)return 97;name++;
    uint8_t request[192];if(!exact(0,request,sizeof(request)))return 96;
    if(!strcmp(name,"hang")){for(;;)pause();}
    if(!strcmp(name,"abnormal")){raise(SIGKILL);return 95;}
    if(!strcmp(name,"stderr")){write(2,"x",1);return 94;}
    if(!strcmp(name,"flood")){uint8_t many[256]={0};write(1,many,sizeof(many));return 93;}
    if(!strcmp(name,"short")){write(1,"NUR1",4);return 92;}
    if(!strcmp(name,"environment")) {
        if(getenv("HOME") || getenv("DYLD_INSERT_LIBRARIES") || getenv("NEANTIK_BOOTSTRAP_TEST_SECRET") ||
           !getenv("LANG") || strcmp(getenv("LANG"),"C")) return 91;
    }
    if(!strcmp(name,"descriptor") && (request[4]<=2 || fcntl(request[4],F_GETFD)>=0))return 89;
    uint8_t reply[128];memcpy(reply,"NUR1",4);memcpy(reply+4,request+4,32);
    CC_SHA256(request,sizeof(request),reply+36);memcpy(reply+68,request+132,60);
    if(!strcmp(name,"wrong"))reply[36]^=1;
    write(1,reply,sizeof(reply));
    if(!strcmp(name,"descendant")){pid_t child=fork();if(!child){for(;;)pause();}return 0;}
    close(1);close(2);
    if(!strcmp(name,"closed-hang")){for(;;)pause();}
    uint8_t command[36],extra;
    if(!exact(0,command,sizeof(command)) || memcmp(command,"NUC1",4) || memcmp(command+4,request+4,32) || read(0,&extra,1)!=0)return 90;
    return 0;
#endif
}
