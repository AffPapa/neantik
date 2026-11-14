#include "WebKitFrameMemory.h"
#include <fcntl.h>
#include <sys/mman.h>

int neantik_frame_memory_create(const char *name)
{
    return shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
}

int neantik_frame_memory_open_readonly(const char *name)
{
    return shm_open(name, O_RDONLY);
}
