#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_NO_STDIO
#define STBI_NO_LINEAR
#define STBI_NO_HDR
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <ghostty/vt.h>

/* stb_image also decodes JPEG for background images; terminal image
   protocols only accept PNG. */
static bool is_png(const uint8_t* data, size_t data_len) {
    static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    if (data_len < sizeof(sig)) return false;
    for (size_t i = 0; i < sizeof(sig); i++) {
        if (data[i] != sig[i]) return false;
    }
    return true;
}

static bool decode_rgba(
    const uint8_t* data,
    size_t data_len,
    uint32_t* out_width,
    uint32_t* out_height,
    uint8_t** out_pixels,
    size_t* out_len
) {
    if (!data || data_len == 0 || data_len > INT32_MAX || !out_width || !out_height || !out_pixels || !out_len) return false;

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

bool hollow_decode_png(
    void* userdata,
    const GhosttyAllocator* allocator,
    const uint8_t* data,
    size_t data_len,
    GhosttySysImage* out
) {
    (void)userdata;
    if (!allocator || !out || !is_png(data, data_len)) return false;

    uint32_t width = 0;
    uint32_t height = 0;
    uint8_t* decoded = NULL;
    size_t out_len = 0;
    if (!decode_rgba(data, data_len, &width, &height, &decoded, &out_len)) return false;

    uint8_t* pixels = ghostty_alloc(allocator, out_len);
    if (!pixels) {
        stbi_image_free(decoded);
        return false;
    }

    for (size_t i = 0; i < out_len; i++) pixels[i] = decoded[i];
    stbi_image_free(decoded);

    out->width = width;
    out->height = height;
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
    if (!is_png(data, data_len)) return false;
    return decode_rgba(data, data_len, out_width, out_height, out_pixels, out_len);
}

bool hollow_decode_image_bytes(
    const uint8_t* data,
    size_t data_len,
    uint32_t* out_width,
    uint32_t* out_height,
    uint8_t** out_pixels,
    size_t* out_len
) {
    return decode_rgba(data, data_len, out_width, out_height, out_pixels, out_len);
}

void hollow_decode_png_bytes_free(uint8_t* pixels) {
    if (pixels) stbi_image_free(pixels);
}
