#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#ifdef NEANTIK_DIRECT_WEBGL
#import <IOSurface/IOSurface.h>
extern const char *renderWebGLFrames(BOOL (^deliver)(IOSurfaceRef, uint64_t));
#endif
#import <fcntl.h>
#import <spawn.h>
#import <sys/mman.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

enum { side = 256, rowBytes = side * 4, frameBytes = rowBytes * side };
enum { inheritedMemory = 3, inheritedControl = 4 };

static id<MTLBuffer> mapBuffer(id<MTLDevice> device, int fd, bool producer)
{
    struct stat info;
    if (fstat(fd, &info) != 0) {
        perror("fstat");
        return nil;
    }
    if (info.st_uid != geteuid() || (info.st_mode & 0777) != 0600 || info.st_size != frameBytes) {
        fprintf(stderr, "shared memory metadata refused: owner match=%d mode=%o size=%lld\n",
                info.st_uid == geteuid(), info.st_mode & 0777, info.st_size);
        return nil;
    }
    int protection = PROT_READ | (producer ? PROT_WRITE : 0);
    void *memory = mmap(NULL, frameBytes, protection, MAP_SHARED, fd, 0);
    if (memory == MAP_FAILED) {
        perror("mmap");
        return nil;
    }
    id<MTLBuffer> buffer = [device newBufferWithBytesNoCopy:memory length:frameBytes
        options:MTLResourceStorageModeShared deallocator:^(void *pointer, NSUInteger length) {
            munmap(pointer, length);
        }];
    if (!buffer) {
        munmap(memory, frameBytes);
        fprintf(stderr, "%s Metal mapping refused\n", producer ? "producer" : "consumer");
    }
    return buffer;
}

#ifndef NEANTIK_DIRECT_WEBGL
static bool copyFrame(id<MTLCommandQueue> queue, id<MTLBuffer> source, id<MTLBuffer> destination)
{
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLBlitCommandEncoder> encoder = [command blitCommandEncoder];
    if (!source || !destination || !encoder)
        return false;
    [encoder copyFromBuffer:source sourceOffset:0 toBuffer:destination destinationOffset:0 size:frameBytes];
    [encoder endEncoding];
    [command commit];
    [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) {
        fputs("GPU copy failed\n", stderr);
        return false;
    }
    return true;
}

#endif

static bool exchangeByte(int fd, uint8_t sequence, bool sending)
{
    uint8_t value = sequence;
    ssize_t count;
    do {
        count = sending ? write(fd, &value, 1) : read(fd, &value, 1);
    } while (count < 0 && errno == EINTR);
    return count == 1 && value == sequence;
}

static bool produce(id<MTLDevice> device)
{
    id<MTLBuffer> mapped = mapBuffer(device, inheritedMemory, true);
    close(inheritedMemory);
    id<MTLCommandQueue> queue = [device newCommandQueue];
#ifdef NEANTIK_DIRECT_WEBGL
    if (!mapped || !queue)
        return false;
    const char *failure = renderWebGLFrames(^BOOL(IOSurfaceRef surface, uint64_t sequence) {
        if ((sequence != 1 && sequence != 2) || IOSurfaceGetWidth(surface) != side ||
            IOSurfaceGetHeight(surface) != side || IOSurfaceGetPixelFormat(surface) != 'BGRA')
            return NO;
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:side height:side mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor iosurface:surface plane:0];
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLBlitCommandEncoder> encoder = [command blitCommandEncoder];
        if (!texture || !encoder)
            return NO;
        [encoder copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(side, side, 1) toBuffer:mapped destinationOffset:0
           destinationBytesPerRow:rowBytes destinationBytesPerImage:frameBytes];
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        return command.status == MTLCommandBufferStatusCompleted &&
            exchangeByte(inheritedControl, sequence, true) &&
            exchangeByte(inheritedControl, sequence, false);
    });
    if (failure)
        fprintf(stderr, "WebGL renderer: %s\n", failure);
    return !failure;
#else
    id<MTLBuffer> source = [device newBufferWithLength:frameBytes options:MTLResourceStorageModeShared];
    if (!mapped || !source || !queue)
        return false;
    for (uint8_t sequence = 1; sequence <= 2; sequence++) {
        uint32_t *pixels = source.contents;
        uint32_t color = sequence == 1 ? 0xffff0000 : 0xff00ff00;
        for (size_t i = 0; i < side * side; i++)
            pixels[i] = color;
        if (!copyFrame(queue, source, mapped) || !exchangeByte(inheritedControl, sequence, true) ||
            !exchangeByte(inheritedControl, sequence, false))
            return false;
    }
    return true;
#endif
}

#ifndef NEANTIK_DIRECT_WEBGL
static bool consume(id<MTLDevice> device, id<MTLBuffer> mapped, int control)
{
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLBuffer> readback = [device newBufferWithLength:frameBytes options:MTLResourceStorageModeShared];
    if (!readback || !queue)
        return false;
    for (uint8_t sequence = 1; sequence <= 2; sequence++) {
        if (!exchangeByte(control, sequence, false) || !copyFrame(queue, mapped, readback))
            return false;
        const uint32_t *pixels = readback.contents;
        uint32_t expected = sequence == 1 ? 0xffff0000 : 0xff00ff00;
        const size_t center = side / 2 * side + side / 2;
        if (pixels[center] != expected) {
            fprintf(stderr, "frame %u: expected 0x%08x, received 0x%08x\n",
                    sequence, expected, pixels[center]);
            return false;
        }
        printf("PASS: GPU shared frame %u, BGRA=0x%08x\n", sequence, expected);
        if (!exchangeByte(control, sequence, true))
            return false;
    }
    return true;
}

static int spawnProducer(const char *executable, int memory, int control, pid_t *pid)
{
    posix_spawn_file_actions_t actions;
    int result = posix_spawn_file_actions_init(&actions);
    if (result)
        return result;
    int memoryCopy = fcntl(memory, F_DUPFD_CLOEXEC, 8);
    int controlCopy = fcntl(control, F_DUPFD_CLOEXEC, 8);
    if (memoryCopy < 0 || controlCopy < 0)
        result = errno;
    if (!result)
        result = posix_spawn_file_actions_adddup2(&actions, memoryCopy, inheritedMemory);
    if (!result)
        result = posix_spawn_file_actions_adddup2(&actions, controlCopy, inheritedControl);
    char *const arguments[] = {(char *)executable, "--producer", NULL};
    char *const environment[] = {"PATH=/usr/bin:/bin", NULL};
    if (!result)
        result = posix_spawn(pid, executable, &actions, NULL, arguments, environment);
    if (controlCopy >= 0)
        close(controlCopy);
    if (memoryCopy >= 0)
        close(memoryCopy);
    posix_spawn_file_actions_destroy(&actions);
    return result;
}

#endif

int main(int argc, const char **argv)
{
    @autoreleasepool {
        alarm(20);
        signal(SIGPIPE, SIG_IGN);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            fputs("Metal unavailable\n", stderr);
            return 2;
        }
        if (argc == 2 && !strcmp(argv[1], "--producer"))
            return produce(device) ? 0 : 1;
#ifdef NEANTIK_DIRECT_WEBGL
        return 64;
#else
        if (argc != 1 && argc != 2)
            return 64;

        char name[32];
        snprintf(name, sizeof(name), "/neantik-frame-%08x", arc4random());
        int producer = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
        if (producer < 0) {
            perror("shm_open producer");
            return 2;
        }
        int consumer = shm_open(name, O_RDONLY, 0);
        int unlinked = shm_unlink(name);
        if (unlinked || consumer < 0 || fcntl(producer, F_SETFD, FD_CLOEXEC) < 0 ||
            fcntl(consumer, F_SETFD, FD_CLOEXEC) < 0 || ftruncate(producer, frameBytes) != 0) {
            perror("prepare shared memory");
            return 2;
        }
        id<MTLBuffer> mapped = mapBuffer(device, consumer, false);
        close(consumer);
        int channel[2];
        if (!mapped || socketpair(AF_UNIX, SOCK_STREAM, 0, channel) != 0)
            return 2;
        if (fcntl(channel[0], F_SETFD, FD_CLOEXEC) < 0 || fcntl(channel[1], F_SETFD, FD_CLOEXEC) < 0)
            return 2;
        pid_t pid;
        int launched = spawnProducer(argc == 2 ? argv[1] : argv[0], producer, channel[1], &pid);
        close(producer);
        close(channel[1]);
        if (launched) {
            fprintf(stderr, "spawn failed: %s\n", strerror(launched));
            return 2;
        }
        bool passed = consume(device, mapped, channel[0]);
        close(channel[0]);
        int status = 0;
        pid_t reaped = waitpid(pid, &status, 0);
        if (!passed || reaped != pid || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
            fputs("frame exchange or renderer exit failed\n", stderr);
            return 1;
        }
        puts("PASS: two GPU frames, consumption acknowledgements, direct child exit");
        return 0;
#endif
    }
}
