#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <xpc/xpc.h>
#import <unistd.h>

static const char *serviceID = "app.neantik.qa.SurfaceControl";
static const size_t side = 64;
static const uint32_t pixelFormat = 'BGRA';

#ifdef NEANTIK_SURFACE_SERVICE
static void receive(xpc_object_t message)
{
    if (xpc_get_type(message) != XPC_TYPE_DICTIONARY)
        return;
    const char *generation = xpc_dictionary_get_string(message, "generation");
    uint64_t sequence = xpc_dictionary_get_uint64(message, "sequence");
    if (!generation || strlen(generation) != 36 || (sequence != 1 && sequence != 2))
        return;

    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)@{
        (__bridge NSString *)kIOSurfaceWidth: @(side),
        (__bridge NSString *)kIOSurfaceHeight: @(side),
        (__bridge NSString *)kIOSurfaceBytesPerElement: @4,
        (__bridge NSString *)kIOSurfacePixelFormat: @(pixelFormat)
    });
    if (!surface || IOSurfaceLock(surface, 0, NULL) != kIOReturnSuccess)
        abort();
    uint8_t *base = IOSurfaceGetBaseAddress(surface);
    for (size_t y = 0; y < side; y++) {
        uint8_t *row = base + y * IOSurfaceGetBytesPerRow(surface);
        for (size_t x = 0; x < side; x++) {
            row[x * 4] = 0;
            row[x * 4 + 1] = sequence == 2 ? 255 : 0;
            row[x * 4 + 2] = sequence == 1 ? 255 : 0;
            row[x * 4 + 3] = 255;
        }
    }
    IOSurfaceUnlock(surface, 0, NULL);
    xpc_object_t reply = xpc_dictionary_create_reply(message);
    xpc_dictionary_set_string(reply, "generation", generation);
    xpc_dictionary_set_uint64(reply, "sequence", sequence);
    xpc_dictionary_set_int64(reply, "servicePID", getpid());
    xpc_dictionary_set_value(reply, "surface", IOSurfaceCreateXPCObject(surface));
    xpc_connection_send_message(xpc_dictionary_get_remote_connection(message), reply);
    CFRelease(surface);
}

static void connectPeer(xpc_connection_t peer)
{
    xpc_connection_set_event_handler(peer, ^(xpc_object_t message) { receive(message); });
    xpc_connection_activate(peer);
}

int main(void)
{
    xpc_main(connectPeer);
}
#else
static bool verifySurface(xpc_object_t reply, pid_t peerPID, const char *generation, uint64_t sequence)
{
    if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY)
        return false;
    const char *replyGeneration = xpc_dictionary_get_string(reply, "generation");
    if (!replyGeneration || strcmp(replyGeneration, generation) ||
        xpc_dictionary_get_uint64(reply, "sequence") != sequence ||
        peerPID <= 1 || peerPID == getpid() ||
        xpc_dictionary_get_int64(reply, "servicePID") != peerPID)
        return false;
    xpc_object_t handle = xpc_dictionary_get_value(reply, "surface");
    IOSurfaceRef surface = handle ? IOSurfaceLookupFromXPCObject(handle) : NULL;
    if (!surface)
        return false;
    bool valid = false;
    size_t stride = IOSurfaceGetBytesPerRow(surface);
    size_t allocation = IOSurfaceGetAllocSize(surface);
    if (IOSurfaceGetWidth(surface) == side && IOSurfaceGetHeight(surface) == side &&
        IOSurfaceGetPixelFormat(surface) == pixelFormat && IOSurfaceGetBytesPerElement(surface) == 4 &&
        IOSurfaceGetPlaneCount(surface) == 0 && allocation <= 64 * 1024 &&
        stride >= side * 4 && stride <= allocation / side &&
        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) == kIOReturnSuccess) {
        const uint8_t *center = IOSurfaceGetBaseAddress(surface);
        center += side / 2 * IOSurfaceGetBytesPerRow(surface) + side / 2 * 4;
        valid = center[0] == 0 && center[1] == (sequence == 2 ? 255 : 0) &&
            center[2] == (sequence == 1 ? 255 : 0) && center[3] == 255;
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    }
    CFRelease(surface);
    return valid;
}

int main(void)
{
    @autoreleasepool {
        alarm(8);
        NSString *token = NSUUID.UUID.UUIDString;
        const char *generation = token.UTF8String;
        xpc_connection_t connection = xpc_connection_create(serviceID, NULL);
        xpc_connection_set_event_handler(connection, ^(xpc_object_t _) {});
        xpc_connection_activate(connection);
        for (uint64_t sequence = 1; sequence <= 2; sequence++) {
            xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
            xpc_dictionary_set_string(request, "generation", generation);
            xpc_dictionary_set_uint64(request, "sequence", sequence);
            xpc_object_t reply = xpc_connection_send_message_with_reply_sync(connection, request);
            if (!verifySurface(reply, xpc_connection_get_pid(connection), generation, sequence)) {
                fprintf(stderr, "surface verification refused at sequence %llu\n", sequence);
                return 1;
            }
            printf("PASS: separate XPC process and exact IOSurface pixels, sequence %llu\n", sequence);
        }
        xpc_connection_cancel(connection);
    }
    return 0;
}
#endif
