// A separate research entrypoint. The base and TLS hosts remain unchanged.
#define main unusedBaseResearchMain
#import "TLSHost.m"
#undef main
#import <math.h>

@interface NetworkHost : OwnedHost <WKScriptMessageHandler>
@property NSString *observationCase;
@end

static BOOL boundedInteger(id value, NSInteger limit) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()
        && [value doubleValue] >= 0 && [value doubleValue] <= limit
        && floor([value doubleValue]) == [value doubleValue];
}

@implementation NetworkHost
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [super applicationDidFinishLaunching:notification];
    [self.webView.configuration.userContentController addScriptMessageHandler:self name:@"ownedNetworkResult"];
}
- (void)command:(NSDictionary *)command {
    if (![command[@"action"] isEqual:@"observe-rtc"]) { [super command:command]; return; }
    NSString *label = command[@"case"];
    id clear = command[@"clearProxy"];
    if (self.observationCase || ![label isKindOfClass:NSString.class] || label.length > 80 ||
        ![clear isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)clear) != CFBooleanGetTypeID() ||
        ![self.settings[@"urls"] containsObject:self.webView.URL.absoluteString] ||
        !boundedInteger(self.settings[@"stunPort"], 65535) || [self.settings[@"stunPort"] integerValue] == 0) {
        emit(@{@"event":@"refused", @"reason":@"observation-scope"}); return;
    }
    self.observationCase = label;
    // Intentional broken native configuration, only in this research target:
    // the runtime boundary must survive a missing proxy after page loading.
    if ([clear boolValue]) self.webView.configuration.websiteDataStore.proxyConfigurations = @[];
    NSString *path = [NSBundle.mainBundle pathForResource:@"network_observation" ofType:@"js"];
    NSString *script = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSDictionary *config = @{@"nonce":self.settings[@"nonce"],
        @"stunURL":[NSString stringWithFormat:@"stun:%@:%@", self.settings[@"stunHost"], self.settings[@"stunPort"]]};
    NSData *data = [NSJSONSerialization dataWithJSONObject:config options:0 error:nil];
    if (!script || !data) { emit(@{@"event":@"refused", @"reason":@"missing-owned-script"}); return; }
    NSString *invocation = [NSString stringWithFormat:@"%@(%@)", script,
        [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
    [self.webView evaluateJavaScript:invocation completionHandler:^(id value, NSError *error) {
        if (error) emit(@{@"event":@"refused", @"reason":@"fixed-observation-script-failed"});
    }];
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *body = [message.body isKindOfClass:NSDictionary.class] ? message.body : nil;
    NSURL *source = message.frameInfo.request.URL;
    NSSet *keys = [NSSet setWithArray:@[@"nonce",@"available",@"secureContext",@"offerCreated",@"gatheringComplete",
        @"timedOut",@"closed",@"candidates",@"errorCodes"]];
    BOOL valid = body && self.observationCase && message.webView == self.webView && message.frameInfo.mainFrame &&
        [message.name isEqual:@"ownedNetworkResult"] && [self.settings[@"urls"] containsObject:source.absoluteString] &&
        [[NSSet setWithArray:body.allKeys] isEqual:keys] && [body[@"nonce"] isEqual:self.settings[@"nonce"]];
    for (NSString *key in @[@"available",@"secureContext",@"offerCreated",@"gatheringComplete",@"timedOut",@"closed"]) {
        id value = body[key]; valid = valid && [value isKindOfClass:NSNumber.class] &&
            CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
    }
    NSDictionary *counts = [body[@"candidates"] isKindOfClass:NSDictionary.class] ? body[@"candidates"] : nil;
    valid = valid && counts && [[NSSet setWithArray:counts.allKeys] isEqual:[NSSet setWithArray:@[@"host",@"srflx",@"prflx",@"relay",@"other"]]];
    for (id value in counts.allValues) valid = valid && boundedInteger(value, 256);
    NSArray *codes = [body[@"errorCodes"] isKindOfClass:NSArray.class] ? body[@"errorCodes"] : nil;
    valid = valid && codes && codes.count <= 16;
    for (id value in codes) valid = valid && boundedInteger(value, 9999);
    if (!valid) { emit(@{@"event":@"refused", @"reason":@"observation-receipt-scope"}); return; }
    emit(@{@"event":@"network-observation", @"case":self.observationCase,
           @"result":body});
    self.observationCase = nil;
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"ownedNetworkResult"];
    return [super applicationShouldTerminate:sender];
}
@end

int main(void) {
    @autoreleasepool {
        char *line = NULL; size_t capacity = 0;
        ssize_t length = getline(&line, &capacity, stdin);
        if (length <= 0 || length > 16384) { free(line); return 64; }
        NSData *data = [NSData dataWithBytes:line length:(NSUInteger)length]; free(line);
        NSDictionary *settings = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![settings isKindOfClass:NSDictionary.class] || ![settings[@"urls"] isKindOfClass:NSArray.class] ||
            ![settings[@"framework"] isKindOfClass:NSString.class] || ![settings[@"role"] isKindOfClass:NSString.class] ||
            ![settings[@"nonce"] isKindOfClass:NSString.class]) return 64;
        [NSApplication sharedApplication];
        NetworkHost *delegate = [NetworkHost new]; delegate.settings = settings;
        NSApp.delegate = delegate; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp run];
    }
    return 0;
}
