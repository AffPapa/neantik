#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <unistd.h>
#import <xpc/xpc.h>

enum { side = 256, stride = side * 4, byteCount = stride * side };

static bool verifyFrame(xpc_object_t frame, id<MTLDevice> device, id<MTLCommandQueue> queue, bool green)
{
    IOSurfaceRef surface = frame ? IOSurfaceLookupFromXPCObject(frame) : NULL;
    if (!surface)
        return false;
    size_t row = IOSurfaceGetBytesPerRow(surface);
    size_t allocation = IOSurfaceGetAllocSize(surface);
    bool layoutValid = IOSurfaceGetWidth(surface) == side && IOSurfaceGetHeight(surface) == side &&
        IOSurfaceGetPixelFormat(surface) == 'BGRA' && IOSurfaceGetBytesPerElement(surface) == 4 &&
        IOSurfaceGetPlaneCount(surface) == 0 && row == stride && allocation >= byteCount &&
        allocation <= 2 * byteCount;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:side height:side mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = layoutValid ? [device newTextureWithDescriptor:descriptor iosurface:surface plane:0] : nil;
    CFRelease(surface);
    if (!texture)
        return false;
    id<MTLBuffer> pixels = [device newBufferWithLength:byteCount options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLBlitCommandEncoder> encoder = [command blitCommandEncoder];
    if (!pixels || !encoder)
        return false;
    [encoder copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                  sourceSize:MTLSizeMake(side, side, 1) toBuffer:pixels destinationOffset:0
       destinationBytesPerRow:stride destinationBytesPerImage:byteCount];
    [encoder endEncoding];
    [command commit];
    [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted)
        return false;
    const uint8_t *center = (const uint8_t *)pixels.contents + stride * (side / 2) + 4 * (side / 2);
    printf("received via Metal: RGBA=%u,%u,%u,%u\n", center[2], center[1], center[0], center[3]);
    return center[0] == 0 && center[1] == (green ? 255 : 0) &&
        center[2] == (green ? 0 : 255) && center[3] == 255;
}

int main(void)
{
    @autoreleasepool {
        alarm(20);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (!queue) {
            fputs("consumer Metal command queue unavailable\n", stderr);
            return 2;
        }
        NSString *generation = NSUUID.UUID.UUIDString;
        xpc_connection_t connection = xpc_connection_create("app.neantik.qa.SurfaceControl", NULL);
        xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {});
        xpc_connection_activate(connection);
        xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(request, "generation", generation.UTF8String);
        xpc_object_t reply = xpc_connection_send_message_with_reply_sync(connection, request);
        if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
            fprintf(stderr, "renderer XPC reply unavailable: %s\n",
                    reply ? xpc_type_get_name(xpc_get_type(reply)) : "missing");
            return 1;
        }
        const char *returnedGeneration = xpc_dictionary_get_string(reply, "generation");
        const char *status = xpc_dictionary_get_string(reply, "status");
        pid_t peer = xpc_connection_get_pid(connection);
        if (!returnedGeneration || strcmp(returnedGeneration, generation.UTF8String) ||
            !status || strcmp(status, "rendered") || peer <= 1 || peer == getpid() ||
            xpc_dictionary_get_int64(reply, "rendererPID") != peer) {
            fprintf(stderr, "renderer admission failed: %s\n", status ?: "missing status");
            return 1;
        }
        if (!verifyFrame(xpc_dictionary_get_value(reply, "frame1"), device, queue, false) ||
            !verifyFrame(xpc_dictionary_get_value(reply, "frame2"), device, queue, true))
            return 1;
        xpc_connection_cancel(connection);
        puts("PASS: owned WebKit WebGL, separate XPC renderer, and Metal consumer");
        return 0;
    }
}
