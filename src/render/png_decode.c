#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#define STBI_NO_LINEAR
#define STBI_NO_HDR
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

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
) {
    (void)userdata;
    if (!allocator || !data || data_len == 0 || !out) return false;

    int width = 0;
    int height = 0;
    int channels = 0;
    stbi_uc* decoded = stbi_load_from_memory(data, (int)data_len, &width, &height, &channels, 4);
    if (!decoded || width <= 0 || height <= 0) {
        if (decoded) stbi_image_free(decoded);
        return false;
    }

    const size_t out_len = (size_t)width * (size_t)height * 4u;
    uint8_t* pixels = ghostty_alloc(allocator, out_len);
    if (!pixels) {
        stbi_image_free(decoded);
        return false;
    }

    for (size_t i = 0; i < out_len; i++) pixels[i] = decoded[i];
    stbi_image_free(decoded);

    out->width = (uint32_t)width;
    out->height = (uint32_t)height;
    out->data = pixels;
    out->data_len = out_len;
    return true;
}

bool hollow_decode_png_bytes(
    const uint8_t* data,
    size_t data_len,
    uint32_t* out_width,
    uint32_t* out_height,
    uint8_t** out_pixels,
    size_t* out_len
) {
    if (!data || data_len == 0 || !out_width || !out_height || !out_pixels || !out_len) return false;

    int width = 0;
    int height = 0;
    int channels = 0;
    stbi_uc* decoded = stbi_load_from_memory(data, (int)data_len, &width, &height, &channels, 4);
    if (!decoded || width <= 0 || height <= 0) {
        if (decoded) stbi_image_free(decoded);
        return false;
    }

    *out_width = (uint32_t)width;
    *out_height = (uint32_t)height;
    *out_pixels = decoded;
    *out_len = (size_t)width * (size_t)height * 4u;
    return true;
}

void hollow_decode_png_bytes_free(uint8_t* pixels) {
    if (pixels) stbi_image_free(pixels);
}
