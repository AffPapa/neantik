#include "DirectProvisioning.h"
#include <Security/Security.h>
#include <Security/CMSDecoder.h>
#include <dlfcn.h>
#include <string.h>

#define PROFILE_LIMIT (2u * 1024u * 1024u)
typedef struct { const uint8_t *cursor, *end; } DER;

/* A bounded envelope preflight, not a general ASN.1/cryptographic parser.
 * CMSDecoder validates the full signed structure after this no-decryption gate. */
static int item(DER *parent, uint8_t tag, DER *value) {
    if (parent->end - parent->cursor < 2 || *parent->cursor++ != tag) return 0;
    size_t length = *parent->cursor++;
    if (length & 0x80) {
        size_t count = length & 0x7f;
        if (!count || count > 4 || (size_t)(parent->end-parent->cursor) < count || !*parent->cursor) return 0;
        length = 0;
        for (size_t i=0; i<count; i++) length = (length<<8) | *parent->cursor++;
        if (length < 128) return 0;
    }
    if (length > (size_t)(parent->end-parent->cursor)) return 0;
    value->cursor=parent->cursor; value->end=parent->cursor+length;
    parent->cursor+=length;
    return 1;
}
static int oid(DER *parent, uint8_t last) {
    static const uint8_t prefix[]={0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x07};
    DER value;
    return item(parent,0x06,&value) && value.end-value.cursor==9 &&
        !memcmp(value.cursor,prefix,sizeof(prefix)) && value.cursor[8]==last;
}
int neantik_profile_signed_data_envelope(const uint8_t *bytes, size_t length) {
    if (!bytes || !length || length>PROFILE_LIMIT) return 0;
    DER input={bytes,bytes+length}, outer, wrapped, signed_data, version, digest, content, attached, payload, rest;
    if (!item(&input,0x30,&outer) || input.cursor!=input.end || !oid(&outer,2) ||
        !item(&outer,0xa0,&wrapped) || outer.cursor!=outer.end ||
        !item(&wrapped,0x30,&signed_data) || wrapped.cursor!=wrapped.end ||
        !item(&signed_data,0x02,&version) || version.cursor==version.end ||
        !item(&signed_data,0x31,&digest) || !item(&signed_data,0x30,&content) ||
        !oid(&content,1) || !item(&content,0xa0,&attached) || content.cursor!=content.end ||
        !item(&attached,0x04,&payload) || attached.cursor!=attached.end ||
        payload.cursor==payload.end) return 0;
    if (signed_data.cursor<signed_data.end && *signed_data.cursor==0xa0 && !item(&signed_data,0xa0,&rest)) return 0;
    if (signed_data.cursor<signed_data.end && *signed_data.cursor==0xa1 && !item(&signed_data,0xa1,&rest)) return 0;
    return item(&signed_data,0x31,&rest) && signed_data.cursor==signed_data.end;
}

CFDataRef neantik_profile_copy_authenticated_content(CFDataRef input, int *status) {
    *status=NEANTIK_PROFILE_FORMAT;
    if (!input || CFDataGetLength(input)<=0 || CFDataGetLength(input)>PROFILE_LIMIT) return NULL;
    /* Own immutable bytes across preflight, decoder and content authentication. */
    CFDataRef snapshot=CFDataCreateCopy(NULL,input);
    if (!snapshot) return NULL;
    if (!neantik_profile_signed_data_envelope(CFDataGetBytePtr(snapshot),(size_t)CFDataGetLength(snapshot))) {
        CFRelease(snapshot); return NULL;
    }
    CMSDecoderRef decoder=NULL;
    SecPolicyRef profile_policy=NULL, offline_policy=NULL;
    CFArrayRef policies=NULL;
    SecTrustRef trust=NULL;
    CFDataRef content=NULL, result=NULL;
    *status=NEANTIK_PROFILE_SIGNATURE;
    OSStatus code=CMSDecoderCreate(&decoder);
    if (code==errSecSuccess) code=CMSDecoderUpdateMessage(decoder,CFDataGetBytePtr(snapshot),(size_t)CFDataGetLength(snapshot));
    if (code==errSecSuccess) code=CMSDecoderFinalizeMessage(decoder);
    size_t count=0;
    if (code!=errSecSuccess || CMSDecoderGetNumSigners(decoder,&count)!=errSecSuccess || count!=1) goto done;
    typedef SecPolicyRef (*ProfilePolicy)(void);
    ProfilePolicy factory=(ProfilePolicy)dlsym(RTLD_DEFAULT,"SecPolicyCreateOSXProvisioningProfileSigning");
    profile_policy=factory ? factory() : NULL;
    *status=NEANTIK_PROFILE_POLICY_UNAVAILABLE;
    if (!profile_policy) goto done;
    CMSSignerStatus signer=kCMSSignerUnsigned;
    OSStatus ignored_certificate_result=errSecParam;
    /* With evaluateSecTrust=false, certificate-result output is undefined.
     * CMS signature validity and actual certificate trust are separate checks. */
    code=CMSDecoderCopySignerStatus(decoder,0,profile_policy,false,&signer,&trust,&ignored_certificate_result);
    *status=NEANTIK_PROFILE_SIGNATURE;
    if (code!=errSecSuccess || signer!=kCMSSignerValid || !trust) goto done;
    *status=NEANTIK_PROFILE_TRUST;
    /* Preserve the OSX profile policy's OCSP method explicitly. Offline trust
     * consults cached revocation replies on the platform's best-attempt basis;
     * it is not proof of fresh revocation status or authority to install. */
    offline_policy=SecPolicyCreateRevocation(kSecRevocationOCSPMethod | kSecRevocationNetworkAccessDisabled);
    if (!offline_policy) goto done;
    const void *values[]={profile_policy,offline_policy};
    policies=CFArrayCreate(NULL,values,2,&kCFTypeArrayCallBacks);
    if (!policies || SecTrustSetPolicies(trust,policies)!=errSecSuccess ||
        SecTrustSetNetworkFetchAllowed(trust,false)!=errSecSuccess ||
        !SecTrustEvaluateWithError(trust,NULL)) goto done;
    if (CMSDecoderCopyContent(decoder,&content)!=errSecSuccess || !content ||
        CFDataGetLength(content)<=0 || CFDataGetLength(content)>PROFILE_LIMIT) goto done;
    result=CFDataCreateCopy(NULL,content);
    if (result) *status=NEANTIK_PROFILE_OK;
done:
    if (content) CFRelease(content);
    if (trust) CFRelease(trust);
    if (policies) CFRelease(policies);
    if (offline_policy) CFRelease(offline_policy);
    if (profile_policy) CFRelease(profile_policy);
    if (decoder) CFRelease(decoder);
    CFRelease(snapshot);
    return result;
}
