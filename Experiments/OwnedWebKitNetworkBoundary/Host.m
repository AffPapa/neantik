// NeAntik research host. Never uses a default or persistent website data store.
// One JSON configuration arrives over stdin; only owned test URLs are accepted.
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <Network/Network.h>
#import <Network/proxy_config.h>

static void emit(NSDictionary *event) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout);
}

@interface OwnedHost : NSObject <NSApplicationDelegate, WKNavigationDelegate>
@property NSDictionary *settings;
@property WKWebView *webView;
@property NSWindow *window;
@property NSString *pendingCase;
@property NSMutableData *input;
@end

@implementation OwnedHost
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSString *loaded = [NSBundle bundleForClass:WKWebView.class].bundlePath;
    NSString *expected = self.settings[@"framework"];
    if (![loaded.stringByResolvingSymlinksInPath isEqual:expected.stringByResolvingSymlinksInPath]) {
        emit(@{@"event":@"refused", @"reason":@"unexpected-framework"});
        [NSApp terminate:nil]; return;
    }
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    if ([self.settings[@"proxy"] boolValue]) {
        const char *port = [self.settings[@"proxyPort"] stringValue].UTF8String;
        nw_endpoint_t endpoint = nw_endpoint_create_host("127.0.0.1", port);
        nw_proxy_config_t proxy = nw_proxy_config_create_http_connect(endpoint, nil);
        nw_proxy_config_set_failover_allowed(proxy, false);
        nw_proxy_config_set_username_and_password(proxy,
            [self.settings[@"username"] UTF8String], [self.settings[@"password"] UTF8String]);
        configuration.websiteDataStore.proxyConfigurations = @[proxy];
    }
    self.webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0,0,520,320) configuration:configuration];
    self.webView.navigationDelegate = self;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80,100,520,320)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.window.releasedWhenClosed = NO;
    self.window.title = [@"NeAntik · owned WebKit boundary · " stringByAppendingString:self.settings[@"role"]];
    self.window.contentView = self.webView;
    [self.window makeKeyAndOrderFront:nil];
    self.input = [NSMutableData data];
    __weak OwnedHost *weak = self;
    NSFileHandle.fileHandleWithStandardInput.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        dispatch_async(dispatch_get_main_queue(), ^{
            OwnedHost *host = weak;
            if (!host) return;
            if (!data.length) { [NSApp terminate:nil]; return; }
            [host.input appendData:data];
            if (host.input.length > 16384) { [NSApp terminate:nil]; return; }
            while (true) {
                NSRange newline = [host.input rangeOfData:[NSData dataWithBytes:"\n" length:1]
                    options:0 range:NSMakeRange(0,host.input.length)];
                if (newline.location == NSNotFound) break;
                NSData *line = [host.input subdataWithRange:NSMakeRange(0,newline.location)];
                [host.input replaceBytesInRange:NSMakeRange(0,newline.location+1) withBytes:NULL length:0];
                NSDictionary *command = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
                if ([command isKindOfClass:NSDictionary.class]) [host command:command];
            }
        });
    };
    emit(@{@"event":@"ready", @"visible":@(self.window.visible), @"ownFramework":@YES});
}
- (void)command:(NSDictionary *)command {
    if ([command[@"action"] isEqual:@"quit"]) { [NSApp terminate:nil]; return; }
    NSString *label = command[@"case"], *url = command[@"url"];
    if (self.pendingCase || ![label isKindOfClass:NSString.class] ||
        ![self.settings[@"urls"] containsObject:url]) {
        emit(@{@"event":@"refused", @"reason":@"command-scope"}); return;
    }
    self.pendingCase = label;
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:url]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:5];
    [self.webView loadRequest:request];
}
- (void)finish:(BOOL)success code:(NSInteger)code {
    if (!self.pendingCase) return;
    emit(@{@"event":@"navigation", @"case":self.pendingCase, @"success":@(success), @"code":@(code)});
    self.pendingCase = nil;
}
- (void)webView:(WKWebView *)view didFinishNavigation:(WKNavigation *)navigation {
    [view evaluateJavaScript:@"document.body.innerText" completionHandler:^(id value, NSError *error) {
        [self finish:(!error && [value isKindOfClass:NSString.class] &&
            [value isEqual:self.settings[@"marker"]]) code:error.code];
    }];
}
- (void)webView:(WKWebView *)view didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finish:NO code:error.code];
}
- (void)webView:(WKWebView *)view didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finish:NO code:error.code];
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    NSFileHandle.fileHandleWithStandardInput.readabilityHandler = nil;
    [self.webView stopLoading]; self.webView.navigationDelegate = nil;
    self.window.contentView = nil; [self.window close]; self.webView = nil;
    emit(@{@"event":@"closed", @"persistentStoresCreated":@0});
    return NSTerminateNow;
}
@end

int main(void) {
    @autoreleasepool {
        char *line = NULL; size_t capacity = 0;
        ssize_t count = getline(&line, &capacity, stdin);
        if (count <= 0 || count > 16384) { free(line); return 64; }
        NSData *data = [NSData dataWithBytes:line length:(NSUInteger)count]; free(line);
        NSDictionary *settings = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![settings isKindOfClass:NSDictionary.class] || ![settings[@"urls"] isKindOfClass:NSArray.class] ||
            ![settings[@"framework"] isKindOfClass:NSString.class] || ![settings[@"role"] isKindOfClass:NSString.class]) return 64;
        [NSApplication sharedApplication];
        OwnedHost *delegate = [OwnedHost new]; delegate.settings = settings;
        NSApp.delegate = delegate; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp run];
    }
    return 0;
}
