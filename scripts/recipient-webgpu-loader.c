#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 3) { fputs("usage: probe WEBGPU JSC\n", stderr); return 2; }
    char gpu[PATH_MAX], jsc[PATH_MAX];
    if (!realpath(argv[1], gpu) || !realpath(argv[2], jsc)) {
        perror("realpath"); return 3;
    }
    void *handle = dlopen(gpu, RTLD_NOW | RTLD_LOCAL);
    if (!handle) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 4; }
    int gpu_found = 0, jsc_found = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *name = _dyld_get_image_name(i);
        char resolved[PATH_MAX];
        if (name && realpath(name, resolved)) {
            if (!strcmp(resolved, gpu)) gpu_found = 1;
            if (!strcmp(resolved, jsc)) jsc_found = 1;
        }
    }
    printf("dlopen=success exact_webgpu_mapped=%d exact_jsc_mapped=%d\n", gpu_found, jsc_found);
    if (!gpu_found || !jsc_found) return 5;
    dlclose(handle);
    return 0;
}
