#ifndef HOLLOW_TEXT_WIDTH_H
#define HOLLOW_TEXT_WIDTH_H
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct HollowTextGrapheme {
    size_t bytes;
    uint8_t width;
    bool valid;
} HollowTextGrapheme;

/* Ghostty mode-2027 grapheme semantics. Invalid UTF-8 consumes one byte as U+FFFD.
 * Empty input returns zero bytes. No Unicode tables are duplicated here. */
HollowTextGrapheme hollow_text_next_grapheme(const char *text, size_t len);
size_t hollow_text_width(const char *text, size_t len);
#endif
