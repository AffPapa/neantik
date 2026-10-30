/* Build-only macOS verifier. Never linked into or shipped with NeAntik.
 * CMS decoding alone does not authenticate a provisioning profile. Use Apple's
 * exact profile-signing policy; its private symbol must exist or we refuse.
 * No BasicX509 fallback, Keychain item access or certificate extraction to disk.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <Security/CMSDecoder.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LIMIT (2 * 1024 * 1024)
static int refuse(void) {
    fputs("Provisioning/signature trust refused.\n", stderr);
    return 65;
}
static int emit(CFDataRef bytes) {
    CFIndex length = CFDataGetLength(bytes);
    if (length <= 0 || length > LIMIT) return refuse();
    return fwrite(CFDataGetBytePtr(bytes), 1, (size_t)length, stdout) == (size_t)length ? 0 : 74;
}
static int profile(void) {
    unsigned char *bytes = malloc(LIMIT + 1);
    if (!bytes) return refuse();
    size_t length = fread(bytes, 1, LIMIT + 1, stdin);
    if (ferror(stdin) || length == 0 || length > LIMIT) { free(bytes); return refuse(); }
    CMSDecoderRef decoder = NULL;
    OSStatus result = CMSDecoderCreate(&decoder);
    if (result == errSecSuccess) result = CMSDecoderUpdateMessage(decoder, bytes, length);
    free(bytes);
    if (result == errSecSuccess) result = CMSDecoderFinalizeMessage(decoder);
    size_t count = 0;
    if (result == errSecSuccess) result = CMSDecoderGetNumSigners(decoder, &count);
    typedef SecPolicyRef (*ProfilePolicy)(void);
    ProfilePolicy makePolicy = (ProfilePolicy)dlsym(RTLD_DEFAULT, "SecPolicyCreateOSXProvisioningProfileSigning");
    SecPolicyRef policy = makePolicy ? makePolicy() : NULL;
    CMSSignerStatus signer = kCMSSignerUnsigned;
    OSStatus certificate = errSecParam;
    SecTrustRef trust = NULL;
    if (result == errSecSuccess && count == 1 && policy)
        result = CMSDecoderCopySignerStatus(decoder, 0, policy, true, &signer, &trust, &certificate);
    CFDataRef content = NULL;
    int exitCode = 65;
    if (result == errSecSuccess && count == 1 && policy && trust &&
        signer == kCMSSignerValid && certificate == errSecSuccess &&
        CMSDecoderCopyContent(decoder, &content) == errSecSuccess && content)
        exitCode = emit(content);
    else refuse();
    if (content) CFRelease(content);
    if (trust) CFRelease(trust);
    if (policy) CFRelease(policy);
    if (decoder) CFRelease(decoder);
    return exitCode;
}
static int app(const char *path, const char *identifier) {
    /* The caller admits only these two exact identifiers; repeat that boundary
     * before constructing a code requirement. No requirement text from argv. */
    if (strcmp(identifier, "app.neantik.desktop") && strcmp(identifier, "app.neantik.desktop.backup-qa"))
        return refuse();
    char requirementText[512];
    snprintf(requirementText, sizeof(requirementText),
        "anchor apple generic and identifier \"%s\" and certificate leaf[subject.OU] = \"H6VGU2M6JD\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists", identifier);
    CFStringRef text = CFStringCreateWithCString(NULL, requirementText, kCFStringEncodingUTF8);
    SecRequirementRef requirement = NULL;
    OSStatus result = SecRequirementCreateWithString(text, kSecCSDefaultFlags, &requirement);
    CFRelease(text);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), true);
    SecStaticCodeRef code = NULL;
    if (result == errSecSuccess && url) result = SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code);
    if (url) CFRelease(url);
    if (result == errSecSuccess)
        result = SecStaticCodeCheckValidity(code, kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode, requirement);
    CFDictionaryRef info = NULL;
    if (result == errSecSuccess) result = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info);
    int exitCode = 65;
    CFMutableDictionaryRef output = NULL;
    CFDataRef leaf = NULL, encoded = NULL;
    if (result == errSecSuccess && info) {
        CFArrayRef certificates = CFDictionaryGetValue(info, kSecCodeInfoCertificates);
        CFDictionaryRef entitlements = CFDictionaryGetValue(info, kSecCodeInfoEntitlementsDict);
        CFNumberRef flags = CFDictionaryGetValue(info, kSecCodeInfoFlags);
        uint32_t flagValue = 0;
        if (flags && CFGetTypeID(flags) == CFNumberGetTypeID()) CFNumberGetValue(flags, kCFNumberSInt32Type, &flagValue);
        if (certificates && CFGetTypeID(certificates) == CFArrayGetTypeID() && CFArrayGetCount(certificates) > 0 &&
            entitlements && CFGetTypeID(entitlements) == CFDictionaryGetTypeID() && (flagValue & kSecCodeSignatureRuntime)) {
            leaf = SecCertificateCopyData((SecCertificateRef)CFArrayGetValueAtIndex(certificates, 0));
            output = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFDictionarySetValue(output, CFSTR("entitlements"), entitlements);
            CFDictionarySetValue(output, CFSTR("certificate"), leaf);
            CFDictionarySetValue(output, CFSTR("hardenedRuntime"), kCFBooleanTrue);
            encoded = CFPropertyListCreateData(NULL, output, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
            if (encoded) exitCode = emit(encoded);
        }
    }
    if (exitCode != 0) refuse();
    if (encoded) CFRelease(encoded);
    if (output) CFRelease(output);
    if (leaf) CFRelease(leaf);
    if (info) CFRelease(info);
    if (code) CFRelease(code);
    if (requirement) CFRelease(requirement);
    return exitCode;
}
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "profile")) return profile();
    if (argc == 4 && !strcmp(argv[1], "app")) return app(argv[2], argv[3]);
    return refuse();
}
