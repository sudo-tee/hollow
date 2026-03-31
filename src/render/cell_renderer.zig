/// Cell renderer: draws colored backgrounds and font glyphs using sokol_gl + sokol_fontstash.
/// Fonts are embedded at compile time so the exe is self-contained.
const std = @import("std");
const c = @import("sokol_c");
const ghostty = @import("../term/ghostty.zig");
const Config = @import("../config.zig").Config;
const fonts = @import("fonts");

// Embedded font data — compiled into the exe via the fonts module.
const font_regular_data = fonts.regular;
const font_bold_data = fonts.bold;
const font_italic_data = fonts.italic;
const font_bold_italic_data = fonts.bold_italic;
const font_nerd_data = fonts.nerd;

pub const CellRendererConfig = struct {
    font_size: f32 = 16.0,
    dpi_scale: f32 = 1.0,
    padding_x: f32 = 4.0,
    padding_y: f32 = 4.0,
};

pub const CellRenderer = struct {
    fons: *c.FONScontext,
    font_regular: c_int,
    font_bold: c_int,
    font_italic: c_int,
    font_bold_italic: c_int,
    cell_w: f32,
    cell_h: f32,
    font_size: f32,
    dpi_scale: f32,
    padding_x: f32,
    padding_y: f32,
    /// Scratch buffer for building UTF-8 strings per cell.
    glyph_buf: [32]u8 = [_]u8{0} ** 32,
    logged_first_draw: bool = false,

    pub fn init(cfg: CellRendererConfig) CellRenderer {
        // Create a fontstash context with a 2048×2048 atlas.
        const fons = c.sfons_create(&.{
            .width = 2048,
            .height = 2048,
        }) orelse @panic("sfons_create failed");

        // Add fonts. fonsAddFontMem does NOT free the data (last arg=0).
        const reg = c.fonsAddFontMem(fons, "regular", @constCast(font_regular_data.ptr), @intCast(font_regular_data.len), 0);
        const bold = c.fonsAddFontMem(fons, "bold", @constCast(font_bold_data.ptr), @intCast(font_bold_data.len), 0);
        const italic = c.fonsAddFontMem(fons, "italic", @constCast(font_italic_data.ptr), @intCast(font_italic_data.len), 0);
        const bold_italic = c.fonsAddFontMem(fons, "bold_italic", @constCast(font_bold_italic_data.ptr), @intCast(font_bold_italic_data.len), 0);
        const nerd = c.fonsAddFontMem(fons, "nerd", @constCast(font_nerd_data.ptr), @intCast(font_nerd_data.len), 0);

        // Register Nerd Font as a fallback for all faces so box-drawing,
        // powerline, and icon glyphs are covered.
        _ = c.fonsAddFallbackFont(fons, reg, nerd);
        _ = c.fonsAddFallbackFont(fons, bold, nerd);
        _ = c.fonsAddFallbackFont(fons, italic, nerd);
        _ = c.fonsAddFallbackFont(fons, bold_italic, nerd);

        // Physical font size = logical size * DPI scale.
        // fontstash/stb_truetype treats size as pixels, so we must pass
        // physical pixels to get glyphs that are font_size logical pixels tall.
        const physical_size = cfg.font_size * cfg.dpi_scale;

        // Measure cell dimensions from the regular font at the physical size.
        c.fonsClearState(fons);
        c.fonsSetFont(fons, reg);
        c.fonsSetSize(fons, physical_size);
        var ascender: f32 = 0;
        var descender: f32 = 0;
        var line_height: f32 = 0;
        c.fonsVertMetrics(fons, &ascender, &descender, &line_height);

        // Cell height = line_height (includes leading). Cell width = advance of 'M'.
        const cell_h = line_height;
        var bounds: [4]f32 = [_]f32{0} ** 4;
        _ = c.fonsTextBounds(fons, 0, 0, "M", null, &bounds);
        const cell_w = bounds[2]; // right bound of 'M' starting at x=0

        std.log.info("cell_renderer: font_size={d:.1} dpi_scale={d:.2} physical_size={d:.1} cell={d:.1}x{d:.1} ascender={d:.1}", .{ cfg.font_size, cfg.dpi_scale, physical_size, cell_w, cell_h, ascender });

        return .{
            .fons = fons,
            .font_regular = reg,
            .font_bold = bold,
            .font_italic = italic,
            .font_bold_italic = bold_italic,
            .cell_w = cell_w,
            .cell_h = cell_h,
            .font_size = physical_size,
            .dpi_scale = cfg.dpi_scale,
            .padding_x = cfg.padding_x * cfg.dpi_scale,
            .padding_y = cfg.padding_y * cfg.dpi_scale,
        };
    }

    pub fn deinit(self: *CellRenderer) void {
        c.sfons_destroy(self.fons);
    }

    /// Called once per frame. Draws all cells from the ghostty render state.
    pub fn draw(
        self: *CellRenderer,
        runtime: *ghostty.Runtime,
        render_state: ?*anyopaque,
        row_iterator: ?*anyopaque,
        row_cells: ?*anyopaque,
        screen_w: f32,
        screen_h: f32,
    ) void {
        // Get terminal colors (bg, fg, palette).
        const colors = runtime.renderStateColors(render_state) orelse return;
        const default_bg = colors.background;
        const default_fg = colors.foreground;

        // Setup sokol_gl for 2-D pixel-space projection.
        // sgl_draw() must be called ONCE per frame — all drawing happens before it.
        c.sgl_defaults();
        c.sgl_matrix_mode_projection();
        c.sgl_load_identity();
        c.sgl_ortho(0.0, screen_w, screen_h, 0.0, -1.0, 1.0);

        if (!self.logged_first_draw) {
            std.log.info("cell_renderer first draw: screen={d:.0}x{d:.0} bg=#{x:0>2}{x:0>2}{x:0>2} fg=#{x:0>2}{x:0>2}{x:0>2}", .{
                screen_w,     screen_h,
                default_bg.r, default_bg.g,
                default_bg.b, default_fg.r,
                default_fg.g, default_fg.b,
            });
        }

        // --- Background pass: draw one colored quad per cell ---
        if (!runtime.populateRowIterator(render_state, row_iterator)) {
            std.log.warn("cell_renderer: populateRowIterator failed on bg pass", .{});
            c.sgl_draw();
            return;
        }

        var row_y: usize = 0;
        while (runtime.nextRow(row_iterator)) : (row_y += 1) {
            if (!runtime.populateRowCells(row_iterator, row_cells)) continue;
            const py = self.padding_y + @as(f32, @floatFromInt(row_y)) * self.cell_h;

            var col_x: usize = 0;
            while (runtime.nextCell(row_cells)) : (col_x += 1) {
                const px = self.padding_x + @as(f32, @floatFromInt(col_x)) * self.cell_w;

                // Resolved background color (accounts for inverse, palette, etc.)
                const bg = runtime.cellBackground(row_cells) orelse default_bg;
                drawRect(px, py, self.cell_w, self.cell_h, bg.r, bg.g, bg.b, 255);
            }
        }
        if (row_y == 0) {
            if (!self.logged_first_draw) {
                std.log.warn("cell_renderer: bg pass iterated 0 rows (iterator empty after populateRowIterator)", .{});
            }
        }
        if (!self.logged_first_draw) {
            std.log.info("cell_renderer: bg pass rows_drawn={d}", .{row_y});
            self.logged_first_draw = true;
        }

        // --- Foreground pass: draw glyphs (via fontstash / sgl internally) ---
        if (!runtime.populateRowIterator(render_state, row_iterator)) {
            c.sgl_draw();
            return;
        }

        var text_row_y: usize = 0;
        while (runtime.nextRow(row_iterator)) : (text_row_y += 1) {
            if (!runtime.populateRowCells(row_iterator, row_cells)) continue;
            // Baseline = top-of-cell + ascender (fontstash draws from baseline).
            const py = self.padding_y + @as(f32, @floatFromInt(text_row_y)) * self.cell_h;

            var col_x: usize = 0;
            while (runtime.nextCell(row_cells)) : (col_x += 1) {
                const px = self.padding_x + @as(f32, @floatFromInt(col_x)) * self.cell_w;

                const grapheme_len = runtime.cellGraphemeLen(row_cells);
                if (grapheme_len == 0) continue;

                var cps: [16]u32 = [_]u32{0} ** 16;
                runtime.cellGraphemes(row_cells, &cps);

                // Build UTF-8 string for the cell's codepoints.
                var glyph_len: usize = 0;
                for (cps[0..grapheme_len]) |cp| {
                    if (cp == 0) break;
                    glyph_len += encodeUtf8(cp, self.glyph_buf[glyph_len..]) catch break;
                }
                if (glyph_len == 0) continue;
                self.glyph_buf[glyph_len] = 0; // null terminate

                // Resolved fg color.
                const fg = runtime.cellForeground(row_cells) orelse default_fg;

                // Choose font face based on style.
                const style = runtime.cellStyle(row_cells);
                const face = if (style) |s| blk: {
                    if (s.bold and s.italic) break :blk self.font_bold_italic;
                    if (s.bold) break :blk self.font_bold;
                    if (s.italic) break :blk self.font_italic;
                    break :blk self.font_regular;
                } else self.font_regular;

                // Draw glyph via fontstash (renders into its atlas, queued via sgl).
                c.fonsClearState(self.fons);
                c.fonsSetFont(self.fons, face);
                c.fonsSetSize(self.fons, self.font_size);
                c.fonsSetColor(self.fons, c.sfons_rgba(fg.r, fg.g, fg.b, 255));
                c.fonsSetAlign(self.fons, c.FONS_ALIGN_LEFT | c.FONS_ALIGN_TOP);
                _ = c.fonsDrawText(self.fons, px, py, &self.glyph_buf, null);
            }
        }

        // sfons_flush submits atlas texture updates and queues the glyph quads via sgl.
        c.sfons_flush(self.fons);

        // --- Cursor overlay ---
        if (runtime.cursorVisible(render_state)) {
            if (runtime.cursorPos(render_state)) |pos| {
                const cx = self.padding_x + @as(f32, @floatFromInt(pos.x)) * self.cell_w;
                const cy = self.padding_y + @as(f32, @floatFromInt(pos.y)) * self.cell_h;
                const cursor_color = colors.cursor;
                drawCursor(cx, cy, self.cell_w, self.cell_h, cursor_color, runtime.cursorVisualStyle(render_state));
            }
        }

        // Submit ALL accumulated sgl draw commands in one call.
        c.sgl_draw();
    }
};

/// Draw a filled rectangle with sokol_gl.
fn drawRect(x: f32, y: f32, w: f32, h: f32, r: u8, g: u8, b: u8, a: u8) void {
    const rf = @as(f32, @floatFromInt(r)) / 255.0;
    const gf = @as(f32, @floatFromInt(g)) / 255.0;
    const bf = @as(f32, @floatFromInt(b)) / 255.0;
    const af = @as(f32, @floatFromInt(a)) / 255.0;
    c.sgl_begin_quads();
    c.sgl_c4f(rf, gf, bf, af);
    c.sgl_v2f(x, y);
    c.sgl_v2f(x + w, y);
    c.sgl_v2f(x + w, y + h);
    c.sgl_v2f(x, y + h);
    c.sgl_end();
}

fn drawCursor(x: f32, y: f32, w: f32, h: f32, color: ghostty.ColorRgb, style: ghostty.CursorVisualStyle) void {
    const r = color.r;
    const g = color.g;
    const b = color.b;
    switch (style) {
        .block => drawRect(x, y, w, h, r, g, b, 180),
        .block_hollow => drawRectOutline(x, y, w, h, r, g, b),
        .bar => drawRect(x, y, 2.0, h, r, g, b, 220),
        .underline => drawRect(x, y + h - 2.0, w, 2.0, r, g, b, 220),
    }
}

fn drawRectOutline(x: f32, y: f32, w: f32, h: f32, r: u8, g: u8, b: u8) void {
    const t: f32 = 1.5;
    drawRect(x, y, w, t, r, g, b, 220); // top
    drawRect(x, y + h - t, w, t, r, g, b, 220); // bottom
    drawRect(x, y, t, h, r, g, b, 220); // left
    drawRect(x + w - t, y, t, h, r, g, b, 220); // right
}

fn encodeUtf8(cp: u32, buf: []u8) error{BufferTooSmall}!usize {
    if (cp < 0x80) {
        if (buf.len < 1) return error.BufferTooSmall;
        buf[0] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        if (buf.len < 2) return error.BufferTooSmall;
        buf[0] = @intCast(0xC0 | (cp >> 6));
        buf[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        if (buf.len < 3) return error.BufferTooSmall;
        buf[0] = @intCast(0xE0 | (cp >> 12));
        buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
    if (buf.len < 4) return error.BufferTooSmall;
    buf[0] = @intCast(0xF0 | (cp >> 18));
    buf[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
    buf[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
    buf[3] = @intCast(0x80 | (cp & 0x3F));
    return 4;
}
