#include "QEQHardware.h"
#include "LZ4/lz4.h"
#include "LZ4/lz4hc.h"
#include <zlib.h>
int qeq_lz4_compress(const void *input, int size, void *output, int capacity) {
    if (!input || !output || size < 1 || capacity < 1) return 0;
    return LZ4_compress_default(input, output, size, capacity);
}
int qeq_lz4_decompress(const void *input, int size, void *output, int capacity) {
    if (!input || !output || size < 1 || capacity < 1) return -1;
    return LZ4_decompress_safe(input, output, size, capacity);
}
void *qeq_lz4_encoder_create(void) { return LZ4_createStreamHC(); }
void qeq_lz4_encoder_destroy(void *encoder) { LZ4_freeStreamHC(encoder); }
int qeq_lz4_compress_bound(int size) { return LZ4_compressBound(size); }
int qeq_lz4_encoder_compress(void *encoder, const void *input, int size, void *output, int capacity) {
    if (!encoder) return qeq_lz4_compress(input, size, output, capacity);
    if (!input || !output || size < 1 || capacity < 1) return 0;
    // Keep allocation off the tile path. Reset history for every independent wire block.
    LZ4_resetStreamHC_fast(encoder, 9);
    return LZ4_compress_HC_continue(encoder, input, output, size, capacity);
}
uint32_t qeq_display_crc32(const void *input, size_t size, uint32_t seed) {
    if (!size) return seed;
    return (uint32_t)crc32(seed, input, (uInt)size);
}
