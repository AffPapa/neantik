#ifndef NEANTIK_DIRECT_ZIP_CODEC_H
#define NEANTIK_DIRECT_ZIP_CODEC_H
#include <stdint.h>
#include <stddef.h>
enum { NEANTIK_ZIP_OK = 0, NEANTIK_ZIP_INVALID = 1, NEANTIK_ZIP_IO = 2,
       NEANTIK_ZIP_CANCELLED = 3, NEANTIK_ZIP_CRC = 4, NEANTIK_ZIP_LIMIT = 5 };
typedef int (*neantik_zip_cancelled)(void *context);
/* No paths, allocation sized by archive data, subprocesses, or FD ownership.
 * Positional I/O; stored/raw deflate only; exact bounds and CRC required. */
int neantik_zip_decode_fd(int input, uint64_t offset, uint64_t compressed,
                         int output, uint64_t expanded, uint16_t method,
                         uint32_t crc, neantik_zip_cancelled cancelled, void *context);
uint32_t neantik_zip_crc32(const void *bytes, size_t count);
#endif
