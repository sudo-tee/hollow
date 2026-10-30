#include "text_width.h"
#include <ghostty/vt/unicode.h>
#include <stdlib.h>
#include <string.h>

static size_t decode(const unsigned char *s, size_t len, uint32_t *cp, bool *valid) {
    unsigned char first = s[0];
    if (first < 0x80) { *cp = first; return 1; }
    size_t n = first >= 0xc2 && first <= 0xdf ? 2 :
        first >= 0xe0 && first <= 0xef ? 3 : first >= 0xf0 && first <= 0xf4 ? 4 : 0;
    if (!n || n > len) goto invalid;
    uint32_t value = first & (0x7f >> n);
    for (size_t i = 1; i < n; ++i) {
        if ((s[i] & 0xc0) != 0x80) goto invalid;
        value = (value << 6) | (s[i] & 0x3f);
    }
    if ((n == 2 && value < 0x80) || (n == 3 && value < 0x800) ||
        (n == 4 && value < 0x10000) || value > 0x10ffff ||
        (value >= 0xd800 && value <= 0xdfff)) goto invalid;
    *cp = value;
    return n;
invalid:
    *cp = 0xfffd;
    *valid = false;
    return 1;
}

HollowTextGrapheme hollow_text_next_grapheme(const char *text, size_t len) {
    if (!len) return (HollowTextGrapheme){0, 0, true};
    const unsigned char *s = (const unsigned char *)text;
    /* Common UI labels remain allocation-free and avoid Unicode lookup. */
    if (s[0] >= 0x20 && s[0] <= 0x7e &&
        (len == 1 || (s[1] >= 0x20 && s[1] <= 0x7e)))
        return (HollowTextGrapheme){1, 1, true};
    uint32_t local_cps[32], *cps = local_cps;
    size_t local_ends[32], *ends = local_ends;
    bool local_valid[32], *valid = local_valid;
    size_t capacity = 32, limit = 2, count = 0, offset = 0, consumed = 0;
    uint8_t width = 0;
    for (;;) {
        while (count < limit && offset < len) {
            valid[count] = true;
            offset += decode(s + offset, len - offset, &cps[count], &valid[count]);
            ends[count++] = offset;
        }
        consumed = ghostty_unicode_grapheme_width(cps, count, &width);
        if (consumed < count || offset == len) break;
        if (limit < capacity) { limit *= 2; continue; }
        /* The first cluster can be arbitrarily long; never split at a fixed cap. */
        if (capacity > SIZE_MAX / 2 / sizeof(size_t)) goto oom;
        size_t next = capacity * 2;
        uint32_t *new_cps = malloc(next * sizeof(*cps));
        size_t *new_ends = malloc(next * sizeof(*ends));
        bool *new_valid = malloc(next * sizeof(*valid));
        if (!new_cps || !new_ends || !new_valid) {
            free(new_cps); free(new_ends); free(new_valid);
            goto oom;
        }
        memcpy(new_cps, cps, count * sizeof(*cps));
        memcpy(new_ends, ends, count * sizeof(*ends));
        memcpy(new_valid, valid, count * sizeof(*valid));
        if (cps != local_cps) { free(cps); free(ends); free(valid); }
        cps = new_cps; ends = new_ends; valid = new_valid; capacity = next; limit = next;
    }
    bool well_formed = true;
    for (size_t i = 0; i < consumed; ++i) well_formed = well_formed && valid[i];
    HollowTextGrapheme result = {ends[consumed - 1], width, well_formed};
    if (cps != local_cps) { free(cps); free(ends); free(valid); }
    return result;
oom:
    if (cps != local_cps) { free(cps); free(ends); free(valid); }
    /* Allocation failure: visible replacement, guaranteed forward progress. */
    return (HollowTextGrapheme){1, 1, false};
}

size_t hollow_text_width(const char *text, size_t len) {
    size_t offset = 0, width = 0;
    while (offset < len) {
        HollowTextGrapheme cluster = hollow_text_next_grapheme(text + offset, len - offset);
        offset += cluster.bytes;
        width += cluster.width;
    }
    return width;
}
