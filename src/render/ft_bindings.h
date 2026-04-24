// C header for translate-c: exposes FreeType and HarfBuzz to Zig.
// Include order matters: ft2build.h first, then freetype headers, then hb.
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_BITMAP_H
#include FT_OUTLINE_H
#include FT_SIZES_H
#include FT_LCD_FILTER_H
#include FT_SYNTHESIS_H

#include <hb.h>
#include <hb-ft.h>
