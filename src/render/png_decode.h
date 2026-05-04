#ifndef HOLLOW_PNG_DECODE_H
#define HOLLOW_PNG_DECODE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <ghostty/vt.h>

bool hollow_decode_png(
    void* userdata,
    const GhosttyAllocator* allocator,
    const uint8_t* data,
    size_t data_len,
    GhosttySysImage* out
);

bool hollow_decode_png_bytes(
    const uint8_t* data,
    size_t data_len,
    uint32_t* out_width,
    uint32_t* out_height,
    uint8_t** out_pixels,
    size_t* out_len
);

void hollow_decode_png_bytes_free(uint8_t* pixels);

#endif
