const std = @import("std");
const ft = @import("ft_c");
const fastmem = @import("../fastmem.zig");
const ghostty = @import("../term/ghostty.zig");

const ft_types = @import("ft_types.zig");
const FtRenderer = @import("ft_renderer.zig").FtRenderer;
const font_discovery = @import("font_discovery.zig");

const Glyph = ft_types.Glyph;
const GlyphKey = ft_types.GlyphKey;
const ShapeKey = ft_types.ShapeKey;
const ShapeResult = ft_types.ShapeResult;
const GlyphInstance = ft_types.GlyphInstance;
const PreparedGlyph = ft_types.PreparedGlyph;
const PreparedRun = ft_types.PreparedRun;
const PreparedKey = ft_types.PreparedKey;
const PreparedCacheEntry = ft_types.PreparedCacheEntry;
const RecentPreparedEntry = ft_types.RecentPreparedEntry;
const RasterMode = ft_types.RasterMode;
const ATLAS_W = ft_types.ATLAS_W;
const ATLAS_H = ft_types.ATLAS_H;
const ATLAS_BPP = ft_types.ATLAS_BPP;
const RECENT_PREPARED_CACHE_LEN = ft_types.RECENT_PREPARED_CACHE_LEN;

const fontLikelySupportsText = font_discovery.fontLikelySupportsText;

pub const SelectedShapeFont = struct {
    hb_font: ?*ft.hb_font_t,
    raster_face_index: u8,
};

pub fn recordShapedRun(self: *FtRenderer, utf8: []const u8, face_idx: u8, prepared_start: usize, prepared_len: usize) void {
    if (utf8.len == 0 or utf8.len > 128) return;
    var key: ShapeKey = undefined;
    key.len = @intCast(utf8.len);
    key.face_idx = face_idx;
    key.ligatures = self.ligatures;
    fastmem.copy(u8, key.text[0..utf8.len], utf8);
    self.shaped_runs.append(self.allocator, .{
        .fingerprint = preparedFingerprint(utf8, face_idx, self.ligatures, .terminal),
        .key = key,
        .prepared_start = prepared_start,
        .prepared_len = prepared_len,
    }) catch return;
}

pub fn getPreparedCache(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode) ?PreparedRun {
    if (utf8.len == 0 or utf8.len > 128) return null;
    const fingerprint = preparedFingerprint(utf8, face_idx, self.ligatures, raster_mode);
    if (self.getRecentPrepared(utf8, face_idx, raster_mode, fingerprint)) |glyphs| {
        return self.appendPreparedRun(glyphs);
    }
    const key = self.makePreparedKey(utf8, face_idx, raster_mode);
    const entry = self.prepared_cache.get(key) orelse return null;
    self.putRecentPrepared(key, fingerprint, entry.glyphs);
    return self.appendPreparedRun(entry.glyphs);
}

pub fn appendPreparedRun(self: *FtRenderer, glyphs: []const PreparedGlyph) ?PreparedRun {
    const prepared_start = self.prepared_glyphs.items.len;
    self.prepared_glyphs.appendSlice(self.allocator, glyphs) catch return null;
    return .{ .start = prepared_start, .glyphs = self.prepared_glyphs.items[prepared_start..][0..glyphs.len] };
}

pub fn putPreparedCache(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode, glyphs: []const PreparedGlyph) void {
    if (utf8.len == 0 or utf8.len > 128) return;
    const key = self.makePreparedKey(utf8, face_idx, raster_mode);
    const fingerprint = preparedFingerprint(utf8, face_idx, self.ligatures, raster_mode);
    if (self.prepared_cache.get(key)) |entry| {
        self.putRecentPrepared(key, fingerprint, entry.glyphs);
        return;
    }
    const owned = self.allocator.alloc(PreparedGlyph, glyphs.len) catch return;
    fastmem.copy(PreparedGlyph, owned, glyphs);
    self.prepared_cache.put(key, .{ .glyphs = owned }) catch {
        self.allocator.free(owned);
        return;
    };
    self.putRecentPrepared(key, fingerprint, owned);
}

pub fn makePreparedKey(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode) PreparedKey {
    var key: PreparedKey = undefined;
    key.len = @intCast(utf8.len);
    key.face_idx = face_idx;
    key.ligatures = self.ligatures;
    key.raster_mode = raster_mode;
    fastmem.copy(u8, key.text[0..utf8.len], utf8);
    return key;
}

pub fn getRecentPrepared(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode, fingerprint: u64) ?[]PreparedGlyph {
    const slot_idx: usize = @intCast(fingerprint & (RECENT_PREPARED_CACHE_LEN - 1));
    const recent = self.recent_prepared[slot_idx] orelse return null;
    if (recent.fingerprint != fingerprint) return null;
    if (recent.key.face_idx != face_idx or recent.key.ligatures != self.ligatures or recent.key.raster_mode != raster_mode or recent.key.len != utf8.len) return null;
    if (!std.mem.eql(u8, recent.key.text[0..utf8.len], utf8)) return null;
    return recent.glyphs;
}

pub fn putRecentPrepared(self: *FtRenderer, key: PreparedKey, fingerprint: u64, glyphs: []PreparedGlyph) void {
    const slot_idx: usize = @intCast(fingerprint & (RECENT_PREPARED_CACHE_LEN - 1));
    self.recent_prepared[slot_idx] = .{ .fingerprint = fingerprint, .key = key, .glyphs = glyphs };
}

pub fn preparedFingerprint(utf8: []const u8, face_idx: u8, ligatures: bool, raster_mode: RasterMode) u64 {
    var fingerprint: u64 = @as(u64, utf8.len) *% 0x9E3779B185EBCA87;
    fingerprint ^= (@as(u64, face_idx) << 48);
    fingerprint ^= (@as(u64, @intFromBool(ligatures)) << 40);
    fingerprint ^= (@as(u64, @intFromEnum(raster_mode)) << 32);
    if (utf8.len > 0) {
        fingerprint ^= @as(u64, utf8[0]) << 24;
        fingerprint ^= @as(u64, utf8[utf8.len - 1]) << 16;
        fingerprint ^= @as(u64, utf8[utf8.len / 2]) << 8;
        fingerprint ^= @as(u64, utf8[utf8.len / 4]);
    }
    return std.math.rotl(u64, fingerprint, 17) ^ 0xA0761D6478BD642F;
}

pub fn consumeShapedRun(self: *FtRenderer, utf8: []const u8, face_idx: u8) ?[]const PreparedGlyph {
    if (self.shaped_run_read_idx >= self.shaped_runs.items.len) return null;
    const entry = &self.shaped_runs.items[self.shaped_run_read_idx];
    const fingerprint = preparedFingerprint(utf8, face_idx, self.ligatures, .terminal);
    if (entry.fingerprint != fingerprint or
        entry.key.len != utf8.len or
        entry.key.face_idx != face_idx or
        entry.key.ligatures != self.ligatures or
        !std.mem.eql(u8, entry.key.text[0..utf8.len], utf8))
    {
        self.shaped_run_read_idx = self.shaped_runs.items.len;
        return null;
    }
    self.shaped_run_read_idx += 1;
    return self.prepared_glyphs.items[entry.prepared_start..][0..entry.prepared_len];
}

pub fn preRasterize(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode) void {
    const result = self.getOrShape(utf8, face_idx) orelse return;
    self.preRasterizeShaped(result, raster_mode);
}

pub fn preRasterizeShaped(self: *FtRenderer, result: ShapeResult, raster_mode: RasterMode) void {
    for (result.glyphs) |glyph_inst| {
        _ = self.getOrRasterize(glyph_inst.glyph_id, result.raster_face_index, raster_mode);
    }
}

pub fn prepareGlyphs(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode) ?PreparedRun {
    if (self.getPreparedCache(utf8, face_idx, raster_mode)) |prepared| return prepared;
    const result = self.getOrShape(utf8, face_idx) orelse return null;
    const prepared = self.prepareShapedGlyphs(result, raster_mode) orelse return null;
    self.putPreparedCache(utf8, face_idx, raster_mode, prepared.glyphs);
    return prepared;
}

pub fn prepareShapedGlyphs(self: *FtRenderer, result: ShapeResult, raster_mode: RasterMode) ?PreparedRun {
    const prepared_start = self.prepared_glyphs.items.len;
    self.prepared_glyphs.ensureUnusedCapacity(self.allocator, result.glyphs.len) catch return null;
    var prepared_len: usize = 0;
    for (result.glyphs) |glyph_inst| {
        const glyph = self.getOrRasterize(glyph_inst.glyph_id, result.raster_face_index, raster_mode) orelse continue;
        self.prepared_glyphs.appendAssumeCapacity(.{ .inst = glyph_inst, .glyph = glyph });
        prepared_len += 1;
    }
    self.prepared_glyphs.items.len = prepared_start + prepared_len;
    return .{ .start = prepared_start, .glyphs = self.prepared_glyphs.items[prepared_start..][0..prepared_len] };
}

pub fn getOrShape(self: *FtRenderer, utf8: []const u8, face_idx: u8) ?ShapeResult {
    if (utf8.len == 0 or utf8.len > 128) return null;

    var key: ShapeKey = undefined;
    key.len = @intCast(utf8.len);
    key.face_idx = face_idx;
    key.ligatures = self.ligatures;
    fastmem.copy(u8, key.text[0..utf8.len], utf8);

    if (self.shape_cache.get(key)) |res| return res;

    const selected = self.selectShapeFont(utf8, face_idx);
    const hb_font = selected.hb_font;

    const buf = self.hb_buf orelse return null;
    ft.hb_buffer_clear_contents(buf);
    ft.hb_buffer_add_utf8(buf, utf8.ptr, @intCast(utf8.len), 0, @intCast(utf8.len));
    ft.hb_buffer_guess_segment_properties(buf);
    const liga_feature = ft.hb_feature_t{
        .tag = featureTag(.{ 'l', 'i', 'g', 'a' }),
        .value = if (self.ligatures) 1 else 0,
        .start = 0,
        .end = std.math.maxInt(c_uint),
    };
    const clig_feature = ft.hb_feature_t{
        .tag = featureTag(.{ 'c', 'l', 'i', 'g' }),
        .value = if (self.ligatures) 1 else 0,
        .start = 0,
        .end = std.math.maxInt(c_uint),
    };
    const features = [_]ft.hb_feature_t{ liga_feature, clig_feature };
    ft.hb_shape(hb_font, buf, &features, features.len);

    var info_len: c_uint = 0;
    var pos_len: c_uint = 0;
    const infos = ft.hb_buffer_get_glyph_infos(buf, &info_len);
    const positions = ft.hb_buffer_get_glyph_positions(buf, &pos_len);
    if (infos == null or positions == null) return null;

    const glyphs = self.allocator.alloc(GlyphInstance, info_len) catch return null;
    var i: usize = 0;
    while (i < info_len) : (i += 1) {
        glyphs[i] = .{
            .glyph_id = infos[i].codepoint,
            .x_advance = @as(f32, @floatFromInt(positions[i].x_advance)) / 64.0,
            .x_offset = @as(f32, @floatFromInt(positions[i].x_offset)) / 64.0,
            .y_offset = @as(f32, @floatFromInt(positions[i].y_offset)) / 64.0,
        };
    }

    const res = ShapeResult{ .glyphs = glyphs, .raster_face_index = selected.raster_face_index };
    self.shape_cache.put(key, res) catch {
        self.allocator.free(glyphs);
        return null;
    };
    return res;
}

pub fn getOrRasterize(self: *FtRenderer, glyph_id: u32, raster_face_index: u8, raster_mode: RasterMode) ?Glyph {
    const key = GlyphKey{ .glyph_index = glyph_id, .face_index = raster_face_index, .raster_mode = raster_mode };
    if (self.glyph_cache.get(key)) |g| return g;

    const primary_face = self.faceForRasterIndex(raster_face_index) orelse return null;

    const use_subpixel = self.smoothing == .subpixel and raster_mode == .terminal;
    const load_flags = self.loadFlagsForRasterMode(use_subpixel);
    const is_emoji = self.face_emoji != null and raster_face_index == self.emoji_face_index;
    const load_flags_actual: ft.FT_Int32 = if (is_emoji) @intCast(load_flags | ft.FT_LOAD_COLOR) else @intCast(load_flags);
    if (ft.FT_Load_Glyph(primary_face, glyph_id, load_flags_actual) != 0 or glyph_id == 0) {
        const miss = Glyph{ .s0 = 0, .t0 = 0, .s1 = 0, .t1 = 0, .bw = 0, .bh = 0, .bear_x = 0, .bear_y = 0, .advance_x = 0, .color_emoji = false };
        self.glyph_cache.put(key, miss) catch {};
        return null;
    }

    const slot = primary_face.*.glyph;
    const embolden = self.emboldenForRasterFace(raster_face_index);
    if (embolden > 0.0 and slot.*.format == ft.FT_GLYPH_FORMAT_OUTLINE) {
        const strength: ft.FT_Pos = @intFromFloat(embolden * 64.0);
        _ = ft.FT_Outline_Embolden(&slot.*.outline, strength);
    }
    if (ft.FT_Render_Glyph(slot, if (use_subpixel) ft.FT_RENDER_MODE_LCD else ft.FT_RENDER_MODE_NORMAL) != 0) {
        if (ft.FT_Render_Glyph(slot, ft.FT_RENDER_MODE_NORMAL) != 0) {
            const miss = Glyph{ .s0 = 0, .t0 = 0, .s1 = 0, .t1 = 0, .bw = 0, .bh = 0, .bear_x = 0, .bear_y = 0, .advance_x = 0, .color_emoji = false };
            self.glyph_cache.put(key, miss) catch {};
            return null;
        }
    }
    const bmp = &slot.*.bitmap;

    // Handle grey, LCD, and BGRA (color emoji) bitmaps.
    // Space characters and some glyphs produce zero-size bitmaps — cache them
    // with zero dimensions so we still get the correct advance.
    const is_gray = bmp.*.pixel_mode == ft.FT_PIXEL_MODE_GRAY;
    const is_lcd = bmp.*.pixel_mode == ft.FT_PIXEL_MODE_LCD;
    const is_bgra = bmp.*.pixel_mode == ft.FT_PIXEL_MODE_BGRA;
    if ((!is_gray and !is_lcd and !is_bgra) or bmp.*.width == 0 or bmp.*.rows == 0) {
        const g = Glyph{
            .s0 = 0,
            .t0 = 0,
            .s1 = 0,
            .t1 = 0,
            .bw = 0,
            .bh = 0,
            .bear_x = slot.*.bitmap_left,
            .bear_y = slot.*.bitmap_top,
            .advance_x = @as(f32, @floatFromInt(slot.*.advance.x)) / 64.0,
            .color_emoji = false,
        };
        self.glyph_cache.put(key, g) catch {};
        return g;
    }

    const bw: u32 = if (is_lcd) @divFloor(bmp.*.width, 3) else bmp.*.width;
    const bh = bmp.*.rows;
    // pitch can be negative for bottom-up bitmaps; stride is always |pitch|.
    const stride: u32 = @intCast(@abs(bmp.*.pitch));

    // Pack into atlas (with 1px gutter between glyphs)
    if (self.atlas_x + bw + 1 >= ATLAS_W) {
        self.atlas_x = 1;
        self.atlas_y += self.atlas_row_h + 1;
        self.atlas_row_h = 0;
    }
    if (self.atlas_y + bh >= ATLAS_H) {
        std.log.warn("ft_renderer: glyph atlas full!", .{});
        return null;
    }

    // Blit FreeType grey bitmap into atlas as RGBA (coverage in all channels).
    // For color emoji (BGRA), convert to premultiplied RGBA.
    var row: u32 = 0;
    while (row < bh) : (row += 1) {
        // For positive pitch: rows go top-to-bottom.
        // For negative pitch: buffer points to last row; rows go bottom-to-top.
        const src_row_idx: u32 = if (bmp.*.pitch >= 0) row else (bh - 1 - row);
        const src_ptr = bmp.*.buffer + @as(usize, src_row_idx) * @as(usize, stride);
        const dst_base = (self.atlas_y + row) * ATLAS_W * ATLAS_BPP + self.atlas_x * ATLAS_BPP;

        var col: u32 = 0;
        while (col < bw) : (col += 1) {
            const dst = dst_base + col * ATLAS_BPP;
            if (is_bgra) {
                // BGRA → premultiplied RGBA
                const b = src_ptr[col * 4 + 0];
                const g = src_ptr[col * 4 + 1];
                const r = src_ptr[col * 4 + 2];
                const a = src_ptr[col * 4 + 3];
                if (a == 0) {
                    self.atlas_data[dst + 0] = 0;
                    self.atlas_data[dst + 1] = 0;
                    self.atlas_data[dst + 2] = 0;
                    self.atlas_data[dst + 3] = 0;
                } else if (a == 255) {
                    self.atlas_data[dst + 0] = r;
                    self.atlas_data[dst + 1] = g;
                    self.atlas_data[dst + 2] = b;
                    self.atlas_data[dst + 3] = 255;
                } else {
                    // Premultiply: out = src * (a/255)
                    const fa = @as(f32, @floatFromInt(a)) / 255.0;
                    self.atlas_data[dst + 0] = @intFromFloat(@as(f32, @floatFromInt(r)) * fa);
                    self.atlas_data[dst + 1] = @intFromFloat(@as(f32, @floatFromInt(g)) * fa);
                    self.atlas_data[dst + 2] = @intFromFloat(@as(f32, @floatFromInt(b)) * fa);
                    self.atlas_data[dst + 3] = a;
                }
            } else if (is_lcd) {
                const r = self.boostCoverage(src_ptr[col * 3]);
                const g = self.boostCoverage(src_ptr[col * 3 + 1]);
                const b = self.boostCoverage(src_ptr[col * 3 + 2]);
                self.atlas_data[dst + 0] = r;
                self.atlas_data[dst + 1] = g;
                self.atlas_data[dst + 2] = b;
                self.atlas_data[dst + 3] = @max(r, @max(g, b));
            } else {
                const cov = self.boostCoverage(src_ptr[col]);
                self.atlas_data[dst + 0] = cov;
                self.atlas_data[dst + 1] = cov;
                self.atlas_data[dst + 2] = cov;
                self.atlas_data[dst + 3] = cov;
            }
        }
    }
    self.atlas_dirty = true;
    if (bh > self.atlas_row_h) self.atlas_row_h = bh;

    const s0 = @as(f32, @floatFromInt(self.atlas_x)) / @as(f32, @floatFromInt(ATLAS_W));
    const t0 = @as(f32, @floatFromInt(self.atlas_y)) / @as(f32, @floatFromInt(ATLAS_H));
    const s1 = @as(f32, @floatFromInt(self.atlas_x + bw)) / @as(f32, @floatFromInt(ATLAS_W));
    const t1 = @as(f32, @floatFromInt(self.atlas_y + bh)) / @as(f32, @floatFromInt(ATLAS_H));

    self.atlas_x += bw + 1;

    const g = Glyph{
        .s0 = s0,
        .t0 = t0,
        .s1 = s1,
        .t1 = t1,
        .bw = @intCast(bw),
        .bh = @intCast(bh),
        .bear_x = slot.*.bitmap_left,
        .bear_y = slot.*.bitmap_top,
        .advance_x = @as(f32, @floatFromInt(slot.*.advance.x)) / 64.0,
        .color_emoji = is_bgra,
    };
    self.glyph_cache.put(key, g) catch {};
    return g;
}

pub fn loadFlagsForRasterMode(self: *const FtRenderer, use_subpixel: bool) c_int {
    var flags: c_int = ft.FT_LOAD_DEFAULT;
    switch (self.hinting) {
        .none => {
            flags |= ft.FT_LOAD_NO_HINTING;
            flags |= ft.FT_LOAD_NO_AUTOHINT;
        },
        .light => {
            flags |= if (use_subpixel) ft.FT_LOAD_TARGET_LCD else ft.FT_LOAD_TARGET_LIGHT;
        },
        .normal => {
            flags |= if (use_subpixel) ft.FT_LOAD_TARGET_LCD else ft.FT_LOAD_TARGET_NORMAL;
        },
    }
    return flags;
}

pub fn selectShapeFont(self: *FtRenderer, utf8: []const u8, face_idx: u8) SelectedShapeFont {
    const primary_face = self.faceForRasterIndex(face_idx) orelse self.face_regular;
    const primary_hb = self.hbFontForRasterIndex(face_idx) orelse self.hb_regular;
    if (fontLikelySupportsText(primary_face, utf8)) {
        return .{ .hb_font = primary_hb, .raster_face_index = face_idx };
    }

    var i: usize = 0;
    while (i < self.fallback_faces.len) : (i += 1) {
        if (fontLikelySupportsText(self.fallback_faces[i], utf8)) {
            return .{ .hb_font = self.fallback_hb_fonts[i], .raster_face_index = @intCast(4 + i) };
        }
    }

    const bundled_base = 4 + self.fallback_faces.len;
    if (fontLikelySupportsText(self.face_cjk, utf8)) {
        return .{ .hb_font = self.hb_cjk, .raster_face_index = @intCast(bundled_base) };
    }
    if (fontLikelySupportsText(self.face_symbols_nerd, utf8)) {
        return .{ .hb_font = self.hb_symbols_nerd, .raster_face_index = @intCast(bundled_base + 1) };
    }
    if (fontLikelySupportsText(self.face_symbols, utf8)) {
        return .{ .hb_font = self.hb_symbols, .raster_face_index = @intCast(bundled_base + 2) };
    }
    if (fontLikelySupportsText(self.face_nerd, utf8)) {
        return .{ .hb_font = self.hb_nerd, .raster_face_index = @intCast(bundled_base + 3) };
    }
    if (self.face_emoji) |emoji_face| {
        if (fontLikelySupportsText(emoji_face, utf8)) {
            return .{ .hb_font = self.hb_emoji, .raster_face_index = self.emoji_face_index };
        }
    }

    return .{ .hb_font = primary_hb, .raster_face_index = face_idx };
}

pub fn faceForRasterIndex(self: *FtRenderer, raster_face_index: u8) ?ft.FT_Face {
    return switch (raster_face_index) {
        0 => self.face_regular,
        1 => self.face_bold,
        2 => self.face_bold_italic,
        3 => self.face_italic,
        else => blk: {
            const fallback_index = raster_face_index - 4;
            if (fallback_index < self.fallback_faces.len) break :blk self.fallback_faces[fallback_index];
            if (fallback_index == self.fallback_faces.len) break :blk self.face_cjk;
            if (fallback_index == self.fallback_faces.len + 1) break :blk self.face_symbols_nerd;
            if (fallback_index == self.fallback_faces.len + 2) break :blk self.face_symbols;
            if (fallback_index == self.fallback_faces.len + 3) break :blk self.face_nerd;
            if (self.face_emoji) |f| {
                if (fallback_index == self.fallback_faces.len + 4) break :blk f;
            }
            break :blk null;
        },
    };
}

pub fn hbFontForRasterIndex(self: *FtRenderer, raster_face_index: u8) ?*ft.hb_font_t {
    return switch (raster_face_index) {
        0 => self.hb_regular,
        1 => self.hb_bold,
        2 => self.hb_bold_italic,
        3 => self.hb_italic,
        else => blk: {
            const fallback_index = raster_face_index - 4;
            if (fallback_index < self.fallback_hb_fonts.len) break :blk self.fallback_hb_fonts[fallback_index];
            if (fallback_index == self.fallback_hb_fonts.len) break :blk self.hb_cjk;
            if (fallback_index == self.fallback_hb_fonts.len + 1) break :blk self.hb_symbols_nerd;
            if (fallback_index == self.fallback_hb_fonts.len + 2) break :blk self.hb_symbols;
            if (fallback_index == self.fallback_hb_fonts.len + 3) break :blk self.hb_nerd;
            if (self.hb_emoji) |f| {
                if (fallback_index == self.fallback_hb_fonts.len + 4) break :blk f;
            }
            break :blk null;
        },
    };
}

pub fn emboldenForRasterFace(self: *const FtRenderer, raster_face_index: u8) f32 {
    return switch (raster_face_index) {
        0 => self.regular_embolden orelse self.embolden,
        1 => self.bold_embolden orelse self.embolden,
        2 => self.bold_italic_embolden orelse self.embolden,
        3 => self.italic_embolden orelse self.embolden,
        else => self.embolden,
    };
}

pub fn featureTag(tag: [4]u8) u32 {
    return (@as(u32, tag[0]) << 24) |
        (@as(u32, tag[1]) << 16) |
        (@as(u32, tag[2]) << 8) |
        @as(u32, tag[3]);
}

test "featureTag: encodes 4-byte tag as big-endian u32" {
    try std.testing.expectEqual(@as(u32, 0x6C696761), featureTag(.{ 'l', 'i', 'g', 'a' }));
    try std.testing.expectEqual(@as(u32, 0x636C6967), featureTag(.{ 'c', 'l', 'i', 'g' }));
}

test "preparedFingerprint: different inputs produce different fingerprints" {
    const a = preparedFingerprint("abc", 0, true, .terminal);
    const b = preparedFingerprint("abc", 1, true, .terminal);
    const c = preparedFingerprint("abc", 0, false, .terminal);
    const d = preparedFingerprint("xyz", 0, true, .terminal);
    const e = preparedFingerprint("abc", 0, true, .ui);
    try std.testing.expect(a != b); // different face
    try std.testing.expect(a != c); // different ligatures
    try std.testing.expect(a != d); // different text
    try std.testing.expect(a != e); // different raster mode
}
