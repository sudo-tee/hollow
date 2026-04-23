#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HollowDWriteFontMatch {
    uint32_t face_index;
    char path[1024];
} HollowDWriteFontMatch;

typedef int (*HollowDWriteFontFamilyCallback)(const char *family_utf8, void *ctx);
typedef int (*HollowDWriteFontFaceCallback)(const char *family_utf8, const char *style_utf8, void *ctx);

int hollow_dwrite_match_font(const char *family_utf8, int want_bold, int want_italic, HollowDWriteFontMatch *out_match);
int hollow_dwrite_list_font_families(HollowDWriteFontFamilyCallback callback, void *ctx);
int hollow_dwrite_list_font_faces(HollowDWriteFontFaceCallback callback, void *ctx);

#ifdef __cplusplus
}
#endif
