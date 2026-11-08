#include "QEQHardware.h"
#include "LZ4/lz4.h"
#include <zlib.h>
int qeq_lz4_compress(const void *input, int size, void *output, int capacity) {
    if (!input || !output || size < 1 || capacity < 1) return 0;
    return LZ4_compress_default(input, output, size, capacity);
}
int qeq_lz4_decompress(const void *input, int size, void *output, int capacity) {
    if (!input || !output || size < 1 || capacity < 1) return -1;
    return LZ4_decompress_safe(input, output, size, capacity);
}
uint32_t qeq_display_crc32(const void *input, size_t size, uint32_t seed) {
    if (!size) return seed;
    return (uint32_t)crc32(seed, input, (uInt)size);
}
