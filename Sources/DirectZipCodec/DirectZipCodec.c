#include "DirectZipCodec.h"
#include <zlib.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <string.h>

uint32_t neantik_zip_crc32(const void *bytes, size_t count) {
    if (count > UINT_MAX) return 0;
    return (uint32_t)crc32(0L, bytes, (uInt)count);
}

static int read_exact(int fd, unsigned char *bytes, size_t count, uint64_t offset) {
    size_t done = 0;
    while (done < count) {
        ssize_t n = pread(fd, bytes + done, count - done, (off_t)(offset + done));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NEANTIK_ZIP_IO;
        done += (size_t)n;
    }
    return NEANTIK_ZIP_OK;
}
static int write_exact(int fd, const unsigned char *bytes, size_t count, uint64_t offset,
                       neantik_zip_cancelled cancelled, void *context) {
    size_t done = 0;
    while (done < count) {
        if (cancelled && cancelled(context)) return NEANTIK_ZIP_CANCELLED;
        ssize_t n = pwrite(fd, bytes + done, count - done, (off_t)(offset + done));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NEANTIK_ZIP_IO;
        done += (size_t)n;
    }
    return NEANTIK_ZIP_OK;
}
int neantik_zip_decode_fd(int input, uint64_t offset, uint64_t compressed,
                         int output, uint64_t expanded, uint16_t method,
                         uint32_t expected_crc, neantik_zip_cancelled cancelled, void *context) {
    const uint64_t bound = UINT64_C(4) * 1024 * 1024 * 1024;
    if (input < 0 || output < 0 || offset > bound || compressed > bound - offset || expanded > bound)
        return NEANTIK_ZIP_LIMIT;
    if (method != 0 && method != 8) return NEANTIK_ZIP_INVALID;
    unsigned char in[65536], out[65536];
    uint64_t read_count = 0, written = 0;
    uLong crc = crc32(0L, Z_NULL, 0);
    int result = NEANTIK_ZIP_OK;
    if (method == 0) {
        if (compressed != expanded) return NEANTIK_ZIP_INVALID;
        while (read_count < compressed) {
            if (cancelled && cancelled(context)) return NEANTIK_ZIP_CANCELLED;
            size_t n = (size_t)((compressed - read_count < sizeof(in)) ? compressed - read_count : sizeof(in));
            if ((result = read_exact(input, in, n, offset + read_count))) return result;
            if ((result = write_exact(output, in, n, written, cancelled, context))) return result;
            crc = crc32(crc, in, (uInt)n); read_count += n; written += n;
        }
    } else {
        z_stream stream; memset(&stream, 0, sizeof(stream));
        /* ZIP contains raw RFC1951 deflate, without zlib/gzip framing. */
        if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return NEANTIK_ZIP_INVALID;
        for (;;) {
            if (cancelled && cancelled(context)) { result = NEANTIK_ZIP_CANCELLED; break; }
            if (stream.avail_in == 0 && read_count < compressed) {
                size_t n = (size_t)((compressed - read_count < sizeof(in)) ? compressed - read_count : sizeof(in));
                result = read_exact(input, in, n, offset + read_count);
                if (result) break;
                stream.next_in = in; stream.avail_in = (uInt)n; read_count += n;
            }
            stream.next_out = out; stream.avail_out = sizeof(out);
            uInt before = stream.avail_in;
            int status = inflate(&stream, Z_NO_FLUSH);
            size_t n = sizeof(out) - stream.avail_out;
            if ((uint64_t)n > expanded - written) { result = NEANTIK_ZIP_LIMIT; break; }
            if (n) {
                result = write_exact(output, out, n, written, cancelled, context);
                if (result) break;
                written += n; crc = crc32(crc, out, (uInt)n);
            }
            if (status == Z_STREAM_END) {
                if (stream.avail_in != 0 || read_count != compressed || written != expanded) result = NEANTIK_ZIP_INVALID;
                break;
            }
            if (status != Z_OK || (n == 0 && before == stream.avail_in)) { result = NEANTIK_ZIP_INVALID; break; }
        }
        inflateEnd(&stream);
        if (result) return result;
    }
    if (written != expanded) return NEANTIK_ZIP_INVALID;
    return (uint32_t)crc == expected_crc ? NEANTIK_ZIP_OK : NEANTIK_ZIP_CRC;
}
