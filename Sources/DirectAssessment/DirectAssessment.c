#include "DirectAssessment.h"
#include <Security/Security.h>
#include <dlfcn.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <limits.h>
#include <unistd.h>
#include <errno.h>

/* Private SPI is deliberately optional. Missing symbols refuse observation;
 * there is no CLI, label, weak-policy or cached-verdict fallback. */
typedef CFTypeRef (*AssessmentCreate)(CFURLRef, uint64_t, CFDictionaryRef, CFErrorRef *);
typedef CFDictionaryRef (*AssessmentResult)(CFTypeRef, uint64_t, CFErrorRef *);
typedef Boolean (*TicketLookup)(CFDataRef, SecCSDigestAlgorithm, uint64_t, double *, CFErrorRef *);
extern char **environ;

uint64_t neantik_assessment_flags(void) {
    /* IgnoreActiveAssessments prevents joining an older weaker request.
     * Enforce must apply independently to both Create and CopyResult. */
    return (1ull<<28) | (1ull<<27) | (1ull<<26) | (1ull<<24) | (1ull<<22);
}
static int default_encoding(const char *entry) {
    const char *prefix="__CF_USER_TEXT_ENCODING=";
    if (strncmp(entry,prefix,strlen(prefix))) return 0;
    const char *value=entry+strlen(prefix);
    unsigned long fields[3];
    for (size_t field=0;field<3;field++) {
        const char *start=value;
        while ((*value>='0' && *value<='9') || (*value>='a' && *value<='f') ||
               (*value>='A' && *value<='F') || *value=='x' || *value=='X') value++;
        if (value==start || value-start>12 || (field<2 ? *value!=':' : *value!=0)) return 0;
        char *end=NULL; errno=0;
        fields[field]=strtoul(start,&end,0);
        if (errno || end!=value) return 0;
        if (field<2) value++;
    }
    return fields[0]==getuid() && fields[1]==0 && fields[2]==0;
}
int neantik_assessment_environment_admitted(char *const *environment) {
    if (!environment) return 0;
    /* CoreFoundation initializes this local encoding metadata before main,
     * even when exec receives the three-entry allowlist. It cannot select the
     * syspolicy service. Admit only this UID's exact default, never arbitrary
     * inherited text encodings or other environment additions. */
    for (size_t i=0; environment[i]; i++) {
        if (i>=4) return 0;
        const char *entry=environment[i];
        if (strcmp(entry,"PATH=/usr/bin:/bin:/usr/sbin:/sbin") &&
            strcmp(entry,"LANG=C") && strcmp(entry,"TMPDIR=/private/tmp") && !default_encoding(entry)) return 0;
        size_t key_length=(size_t)(strchr(entry,'=')-entry);
        for (size_t j=0;j<i;j++) {
            const char *previous=environment[j];
            if (!strncmp(entry,previous,key_length) && previous[key_length]=='=') return 0;
        }
    }
    return 1;
}
static CFStringRef symbol_string(const char *name) {
    CFStringRef *symbol=(CFStringRef *)dlsym(RTLD_DEFAULT,name);
    if (!symbol || !*symbol || CFGetTypeID(*symbol)!=CFStringGetTypeID()) return NULL;
    return *symbol;
}
int neantik_assessment_result_admitted(CFDictionaryRef result) {
    if (!result || CFGetTypeID(result)!=CFDictionaryGetTypeID() || CFDictionaryGetCount(result)>32) return 0;
    CFStringRef verdict=symbol_string("kSecAssessmentAssessmentVerdict");
    CFStringRef authority=symbol_string("kSecAssessmentAssessmentAuthority");
    if (!verdict || !authority || CFDictionaryGetValue(result,verdict)!=kCFBooleanTrue) return 0;
    CFTypeRef details=CFDictionaryGetValue(result,authority);
    if (!details || CFGetTypeID(details)!=CFDictionaryGetTypeID() || CFDictionaryGetCount(details)>32) return 0;
    if (CFDictionaryContainsKey(result,CFSTR("assessment:error")) ||
        CFDictionaryContainsKey(details,CFSTR("assessment:error"))) return 0;
    const char *reject[]={"kSecAssessmentAssessmentFromCache", "kSecAssessmentAssessmentWeakSignature",
        "kSecAssessmentAssessmentCodeSigningError", "kSecAssessmentAssessmentAuthorityOverride",
        "kSecAssessmentAssessmentAuthorityOriginalVerdict"};
    for (size_t i=0;i<sizeof(reject)/sizeof(*reject);i++) {
        CFStringRef key=symbol_string(reject[i]);
        if (!key || CFDictionaryContainsKey(result,key) || CFDictionaryContainsKey(details,key)) return 0;
    }
    /* Source text can be a custom local rule label, so neither it nor row IDs
     * are used to infer Developer ID/notarization. Those gates are independent. */
    return 1;
}
int neantik_assessment_ticket_admitted(int success, int error, double date, double now) {
    /* CFAbsoluteTime epoch 2001; date denotes ticket time, not network freshness.
     * This positive default-ticket observation requires an actual date. */
    return success==1 && error==0 && isfinite(now) && now>0 &&
        isfinite(date) && date>0 && date<=now+300;
}
int neantik_assessment_revocation_admitted(int success, int error, double date, double now) {
    /* ForceOnlineCheck completes a revocation lookup. Apple's adapter can
     * leave the initialized NaN untouched; that is absent metadata, not an
     * error or proof of a fresh remote response. Every CFError still refuses.
     * If a date is supplied, reject malformed/future metadata independently. */
    return success==1 && error==0 && isfinite(now) && now>0 &&
        (isnan(date) || neantik_assessment_ticket_admitted(1,0,date,now));
}
static int secured_hash(CFURLRef url, const uint8_t expected[20]) {
    SecStaticCodeRef code=NULL;
    SecRequirementRef requirement=NULL;
    CFDictionaryRef info=NULL;
    int result=0;
    /* The parent also enforces the exact app identifier/entitlements/profile.
     * This helper never treats another same-team app as an update candidate. */
    CFStringRef expression=CFSTR("anchor apple generic and certificate leaf[subject.OU] = \"H6VGU2M6JD\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists");
    if (SecRequirementCreateWithString(expression,0,&requirement)!=errSecSuccess || !requirement ||
        SecStaticCodeCreateWithPath(url,0,&code)!=errSecSuccess || !code ||
        SecStaticCodeCheckValidity(code,kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode,requirement)!=errSecSuccess ||
        SecCodeCopySigningInformation(code,kSecCSSigningInformation,&info)!=errSecSuccess || !info) goto done;
    CFTypeRef hash=CFDictionaryGetValue(info,kSecCodeInfoUnique);
    CFTypeRef algorithm=CFDictionaryGetValue(info,kSecCodeInfoDigestAlgorithm);
    int64_t value=0;
    if (!hash || CFGetTypeID(hash)!=CFDataGetTypeID() || CFDataGetLength(hash)!=20 ||
        !algorithm || CFGetTypeID(algorithm)!=CFNumberGetTypeID() || CFNumberIsFloatType(algorithm) ||
        !CFNumberGetValue(algorithm,kCFNumberSInt64Type,&value) || value!=kSecCodeSignatureHashSHA256) goto done;
    result=memcmp(CFDataGetBytePtr(hash),expected,20)==0 ? 1 : -1;
done:
    if (info) CFRelease(info);
    if (code) CFRelease(code);
    if (requirement) CFRelease(requirement);
    return result;
}
NeAntikAssessmentResult neantik_assessment_observe(const char *path,
    const uint8_t expected[20], uint32_t algorithm) {
    NeAntikAssessmentResult result={NEANTIK_ASSESSMENT_ENVIRONMENT,NAN,NAN};
    /* This guard does not sanitize an already initialized manager. Only the
     * standalone process is permitted to call this entry point. */
    if (!neantik_assessment_environment_admitted(environ)) return result;
    result.status=NEANTIK_ASSESSMENT_REQUEST;
    char canonical[PATH_MAX]; struct stat entry;
    if (!path || !expected || algorithm!=kSecCodeSignatureHashSHA256 ||
        strlen(path)>=PATH_MAX || !realpath(path,canonical) || strcmp(path,canonical) ||
        lstat(path,&entry) || !S_ISDIR(entry.st_mode) || entry.st_uid!=getuid()) return result;
    CFURLRef url=CFURLCreateFromFileSystemRepresentation(NULL,(const uint8_t *)path,strlen(path),true);
    CFDataRef hash=CFDataCreate(NULL,expected,20);
    CFTypeRef assessment=NULL;
    CFDictionaryRef verdict=NULL,context=NULL;
    CFErrorRef error=NULL;
    result.status=NEANTIK_ASSESSMENT_UNAVAILABLE;
    AssessmentCreate create=(AssessmentCreate)dlsym(RTLD_DEFAULT,"SecAssessmentCreate");
    AssessmentResult copy=(AssessmentResult)dlsym(RTLD_DEFAULT,"SecAssessmentCopyResult");
    TicketLookup lookup=(TicketLookup)dlsym(RTLD_DEFAULT,"SecAssessmentTicketLookup");
    CFStringRef operation=symbol_string("kSecAssessmentContextKeyOperation");
    CFStringRef execute=symbol_string("kSecAssessmentOperationTypeExecute");
    if (!url || !hash || !create || !copy || !lookup || !operation || !execute) goto done;
    int binding=secured_hash(url,expected);
    result.status=binding<0 ? NEANTIK_ASSESSMENT_HASH : NEANTIK_ASSESSMENT_SIGNATURE;
    if (binding!=1) goto done;
    const void *keys[]={operation}, *values[]={execute};
    context=CFDictionaryCreate(NULL,keys,values,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    result.status=NEANTIK_ASSESSMENT_DENIED;
    if (!context) goto done;
    assessment=create(url,neantik_assessment_flags(),context,&error);
    if (!assessment || error) goto done;
    verdict=copy(assessment,neantik_assessment_flags(),&error);
    if (error || !neantik_assessment_result_admitted(verdict)) goto done;
    result.gatekeeper_accepted=1;
    result.status=NEANTIK_ASSESSMENT_OFFLINE_TICKET;
    Boolean accepted=lookup(hash,kSecCodeSignatureHashSHA256,0,&result.offline_date,&error);
    if (!neantik_assessment_ticket_admitted(accepted,error!=NULL,result.offline_date,CFAbsoluteTimeGetCurrent())) goto done;
    result.offline_ticket_accepted=1;
    result.status=NEANTIK_ASSESSMENT_ONLINE_TICKET;
    accepted=lookup(hash,kSecCodeSignatureHashSHA256,1,&result.online_date,&error);
    result.online_lookup_success=accepted==1 && !error;
    result.online_date_admitted=neantik_assessment_revocation_admitted(1,0,result.online_date,CFAbsoluteTimeGetCurrent());
    if (!neantik_assessment_revocation_admitted(accepted,error!=NULL,result.online_date,CFAbsoluteTimeGetCurrent())) goto done;
    result.status=NEANTIK_ASSESSMENT_CHANGED;
    if (secured_hash(url,expected)!=1) goto done;
    result.status=NEANTIK_ASSESSMENT_OK;
done:
    result.system_error_code=error ? CFErrorGetCode(error) : 0;
    if (error) CFRelease(error);
    if (verdict) CFRelease(verdict);
    if (assessment) CFRelease(assessment);
    if (context) CFRelease(context);
    if (hash) CFRelease(hash);
    if (url) CFRelease(url);
    return result;
}
