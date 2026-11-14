#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <WebKit/WebKit.h>
#include <mach-o/dyld.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <xpc/xpc.h>
#import <unistd.h>

enum { width = 256, height = 256, bytesPerPixel = 4 };

static IOSurfaceRef renderFrame(CALayer *layer, id<MTLDevice> device, id<MTLCommandQueue> queue)
{
    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)@{
        (__bridge NSString *)kIOSurfaceWidth: @(width),
        (__bridge NSString *)kIOSurfaceHeight: @(height),
        (__bridge NSString *)kIOSurfaceBytesPerElement: @(bytesPerPixel),
        (__bridge NSString *)kIOSurfaceBytesPerRow: @(width * bytesPerPixel),
        (__bridge NSString *)kIOSurfacePixelFormat: @((uint32_t)'BGRA'),
    });
    if (!surface)
        return NULL;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor iosurface:surface plane:0];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CARenderer *renderer = texture ? [CARenderer rendererWithMTLTexture:texture options:@{
        kCARendererMetalCommandQueue: queue, kCARendererColorSpace: (__bridge id)colorSpace
    }] : nil;
    CGColorSpaceRelease(colorSpace);
    if (renderer) {
        renderer.layer = layer;
        renderer.bounds = CGRectMake(0, 0, width, height);
        [CATransaction flush];
        [renderer beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
        [renderer addUpdateRect:renderer.bounds];
        [renderer render];
        [renderer endFrame];
        id<MTLCommandBuffer> barrier = [queue commandBuffer];
        [barrier commit];
        [barrier waitUntilCompleted];
        if (barrier.status == MTLCommandBufferStatusCompleted)
            return surface;
    }
    CFRelease(surface);
    return NULL;
}

static BOOL isolated(void)
{
    unsigned owned = 0;
    unsigned system = 0;
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *path = _dyld_get_image_name(index);
        if (!path || !strstr(path, "/WebKit.framework/Versions/A/WebKit"))
            continue;
        if (!strncmp(path, "/System/", 8))
            system++;
        else
            owned++;
    }
    printf("webkit owned=%u system=%u\n", owned, system);
    return owned == 1 && system == 0;
}

@interface Page : NSObject<WKNavigationDelegate>
@property BOOL loaded;
@property BOOL failed;
@end

@implementation Page
- (void)webView:(WKWebView *)view didFinishNavigation:(WKNavigation *)navigation
{
    self.loaded = view != nil && navigation != nil;
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)view
{
    self.failed = view != nil;
}
@end

static void pump(BOOL (^condition)(void), NSTimeInterval timeout)
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

static BOOL paint(WKWebView *view, BOOL expectGreen)
{
    __block BOOL done = NO;
    __block BOOL accepted = NO;
    NSString *script = expectGreen ? @"paint(0,1)" : @"paint(1,0)";
    [view evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        accepted = !error && [result isEqual:@YES];
        done = YES;
    }];
    pump(^BOOL { return done; }, 3);
    return accepted;
}

static CALayer *hostingLayer(WKWebView *view)
{
    CALayer *candidate = nil;
    for (NSView *subview in view.subviews) {
        if (!subview.layer.sublayers.count)
            continue;
        if (candidate)
            return nil;
        candidate = subview.layer;
    }
    return candidate;
}

const char *renderWebGLFrames(BOOL (^deliver)(IOSurfaceRef, uint64_t))
{
    if (!NSThread.isMainThread)
        return "renderer-requires-main-thread";
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!queue)
        return "metal-queue-unavailable";
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    WKWebView *view = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, width, height)
                                       configuration:configuration];
    Page *page = [Page new];
    view.navigationDelegate = page;
    [view loadHTMLString:@"<!doctype html><style>body{margin:0;background:#135}canvas{display:block}</style>"
         "<canvas width=256 height=256></canvas><script>"
         "const gl=document.querySelector('canvas').getContext('webgl',{preserveDrawingBuffer:true});"
         "function paint(r,g){if(!gl)return false;gl.clearColor(r,g,0,1);"
         "gl.clear(gl.COLOR_BUFFER_BIT);gl.finish();return true;}paint(1,0);</script>"
              baseURL:nil];
    pump(^BOOL { return page.loaded || page.failed; }, 6);
    if (page.failed || !page.loaded || !isolated() || !paint(view, NO))
        return "webkit-navigation-or-identity";
    pump(^BOOL { return hostingLayer(view) != nil; }, 2);
    CALayer *layer = hostingLayer(view);
    if (!layer)
        return "compositing-layer-missing";
    for (uint64_t sequence = 1; sequence <= 2; sequence++) {
        if (sequence == 2 && !paint(view, YES))
            return "webgl-repaint-refused";
        pump(^BOOL { return page.failed; }, 0.3);
        if (page.failed)
            return "web-content-process-exited";
        IOSurfaceRef surface = renderFrame(layer, device, queue);
        if (!surface)
            return "metal-render-failed";
        BOOL delivered = deliver(surface, sequence);
        CFRelease(surface);
        if (!delivered)
            return "surface-delivery-failed";
    }
    return isolated() ? NULL : "webkit-image-changed";
}

#ifndef NEANTIK_DIRECT_WEBGL
static void connectPeer(xpc_connection_t peer)
{
    __block BOOL consumed = NO;
    xpc_connection_set_event_handler(peer, ^(xpc_object_t request) {
        if (consumed || xpc_get_type(request) != XPC_TYPE_DICTIONARY)
            return;
        const char *generation = xpc_dictionary_get_string(request, "generation");
        if (!generation || strlen(generation) != 36)
            return;
        xpc_object_t reply = xpc_dictionary_create_reply(request);
        if (!reply)
            return;
        consumed = YES;
        xpc_dictionary_set_string(reply, "generation", generation);
        xpc_dictionary_set_int64(reply, "rendererPID", getpid());
        CFRunLoopRef mainLoop = CFRunLoopGetMain();
        CFRunLoopPerformBlock(mainLoop, kCFRunLoopDefaultMode, ^{
            const char *failure = renderWebGLFrames(^BOOL(IOSurfaceRef surface, uint64_t sequence) {
                xpc_object_t frame = IOSurfaceCreateXPCObject(surface);
                if (!frame)
                    return NO;
                xpc_dictionary_set_value(reply, sequence == 1 ? "frame1" : "frame2", frame);
                return YES;
            });
            xpc_dictionary_set_string(reply, "status", failure ?: "rendered");
            xpc_connection_send_message(peer, reply);
        });
        CFRunLoopWakeUp(mainLoop);
    });
    xpc_connection_activate(peer);
}

int main(void)
{
    xpc_main(connectPeer);
}
#endif
