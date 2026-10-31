// Research-only TLS endpoint trust. No Keychain or system trust modifications.
// The QA root is explicit, scoped to this process and its exact owned URLs.
#import "Host.m"
#import <Security/Security.h>

@interface OwnedHost (OwnedTLS)
@end
@implementation OwnedHost (OwnedTLS)
- (void)webView:(WKWebView *)view didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion {
    if (![challenge.protectionSpace.authenticationMethod isEqual:NSURLAuthenticationMethodServerTrust]) {
        completion(NSURLSessionAuthChallengePerformDefaultHandling, nil); return;
    }
    BOOL allowed = NO;
    for (NSString *value in self.settings[@"urls"]) {
        NSURL *url = [NSURL URLWithString:value];
        if ([url.scheme isEqual:@"https"] && [url.host isEqual:challenge.protectionSpace.host] &&
            url.port.integerValue == challenge.protectionSpace.port) allowed = YES;
    }
    NSData *rootData = [[NSData alloc] initWithBase64EncodedString:self.settings[@"qaRootDER"] options:0];
    SecCertificateRef root = rootData ? SecCertificateCreateWithData(NULL, (__bridge CFDataRef)rootData) : NULL;
    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    BOOL valid = NO;
    if (allowed && root && trust) {
        // Preserve real SSL hostname checking and chain/signature validation.
        // Only our ephemeral fixture CA is trusted, never the global anchors.
        SecPolicyRef policy = SecPolicyCreateSSL(true, (__bridge CFStringRef)challenge.protectionSpace.host);
        NSArray *anchors = @[(__bridge id)root];
        OSStatus status = SecTrustSetPolicies(trust, policy);
        if (status == errSecSuccess) status = SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)anchors);
        if (status == errSecSuccess) status = SecTrustSetAnchorCertificatesOnly(trust, true);
        if (status == errSecSuccess) status = SecTrustSetNetworkFetchAllowed(trust, false);
        valid = status == errSecSuccess && SecTrustEvaluateWithError(trust, NULL);
        CFRelease(policy);
    }
    if (root) CFRelease(root);
    emit(@{@"event":@"tls-validation", @"success":@(valid)});
    completion(valid ? NSURLSessionAuthChallengeUseCredential : NSURLSessionAuthChallengeCancelAuthenticationChallenge,
               valid ? [NSURLCredential credentialForTrust:trust] : nil);
}
@end
