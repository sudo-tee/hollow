/// Free functions extracted from FtRenderer for glyph batching, direct glyph
/// emission, atlas quad staging, GPU upload/draw, raster/draw run flushing, and
/// the per-pass style cache.
///
/// Every function here was previously a method on FtRenderer; the receiver is
/// passed explicitly as `self: *FtRenderer`.  Calls between these helpers
/// remain `self.foo(...)` — FtRenderer keeps thin wrapper methods that forward
/// back into this module so existing call sites compile unchanged.
const std = @import("std");
const c = @import("sokol_c");
const ft = @import("ft_c");
const ghostty = @import("../term/ghostty.zig");

const ft_types = @import("ft_types.zig");
const FtRenderer = @import("ft_renderer.zig").FtRenderer;

const Glyph = ft_types.Glyph;
const GlyphVertex = ft_types.GlyphVertex;
const VsParams = ft_types.VsParams;
const FsParams = ft_types.FsParams;
const GlyphInstance = ft_types.GlyphInstance;
const PreparedGlyph = ft_types.PreparedGlyph;
const ShapeResult = ft_types.ShapeResult;
const PreparedRun = ft_types.PreparedRun;
const RasterMode = ft_types.RasterMode;
const CachedStyleInfo = ft_types.CachedStyleInfo;
const STYLE_CACHE_SIZE = ft_types.STYLE_CACHE_SIZE;
const ATLAS_W = ft_types.ATLAS_W;
const ATLAS_H = ft_types.ATLAS_H;
const MAX_GLYPH_VERTS = ft_types.MAX_GLYPH_VERTS;
const GLYPH_VBUF_RING_LEN = ft_types.GLYPH_VBUF_RING_LEN;

const color_math = @import("color_math.zig");
const text_util = @import("text_util.zig");

const utf8CodepointLen = text_util.utf8CodepointLen;
const colorsEqual = color_math.colorsEqual;

/// Shape and batch glyphs for one cell at (px, py).
pub fn batchGlyphs(self: *FtRenderer, px: f32, py: f32, utf8: []const u8, face_idx: u8, fg: ghostty.ColorRgb, raster_mode: RasterMode, clip_y0: f32, clip_y1: f32) void {
    const result = self.getOrShape(utf8, face_idx) orelse return;
    self.batchGlyphsShaped(px, py, result, fg, raster_mode, clip_y0, clip_y1);
}

pub fn batchGlyphsShaped(self: *FtRenderer, px: f32, py: f32, result: ShapeResult, fg: ghostty.ColorRgb, raster_mode: RasterMode, clip_y0: f32, clip_y1: f32) void {
    var x_offset: f32 = 0;
    for (result.glyphs) |glyph_inst| {
        const glyph = self.getOrRasterize(glyph_inst.glyph_id, result.raster_face_index, raster_mode) orelse continue;
        self.emitPreparedGlyph(px, py, &x_offset, glyph_inst, glyph, fg, clip_y0, clip_y1);
    }
}

pub fn batchPreparedGlyphs(self: *FtRenderer, px: f32, py: f32, glyphs: []const PreparedGlyph, fg: ghostty.ColorRgb, clip_y0: f32, clip_y1: f32) void {
    var x_offset: f32 = 0;
    for (glyphs) |prepared| {
        self.emitPreparedGlyph(px, py, &x_offset, prepared.inst, prepared.glyph, fg, clip_y0, clip_y1);
    }
}

pub inline fn emitPreparedGlyph(self: *FtRenderer, px: f32, py: f32, x_offset: *f32, glyph_inst: GlyphInstance, glyph: Glyph, fg: ghostty.ColorRgb, clip_y0: f32, clip_y1: f32) void {
    // Snap to integer pixels to prevent subpixel sampling artifacts.
    const gx = @round(px + x_offset.* + glyph_inst.x_offset + @as(f32, @floatFromInt(glyph.bear_x)));
    const gy = @round(py + self.ascender - glyph_inst.y_offset - @as(f32, @floatFromInt(glyph.bear_y)));

    const w = @as(f32, @floatFromInt(glyph.bw));
    const h = @as(f32, @floatFromInt(glyph.bh));
    if (w > 0 and h > 0) {
        self.emitGlyphQuad(gx, gy, w, h, glyph.s0, glyph.t0, glyph.s1, glyph.t1, fg, clip_y0, clip_y1, glyph.color_emoji);
    }

    x_offset.* += glyph_inst.x_advance;
}

/// Fast path for a single codepoint in one of the primary 4 faces:
/// skip HarfBuzz shaping entirely when the face directly supports the glyph.
/// Printable ASCII / Latin-1 uses the dedicated cached table; other codepoints
/// still avoid shaping via direct FT_Get_Char_Index probing.
pub inline fn drawDirectGlyph(self: *FtRenderer, px: f32, py: f32, cp: u32, face_idx: u8, fg: ghostty.ColorRgb, clip_y0: f32, clip_y1: f32) bool {
    const glyph = self.directGlyph(cp, face_idx) orelse return false;

    const w = @as(f32, @floatFromInt(glyph.bw));
    const h = @as(f32, @floatFromInt(glyph.bh));
    if (w > 0 and h > 0) {
        // Snap to integer pixels to prevent subpixel sampling artifacts.
        const gx = @round(px + @as(f32, @floatFromInt(glyph.bear_x)));
        const gy = @round(py + self.ascender - @as(f32, @floatFromInt(glyph.bear_y)));
        self.emitGlyphQuad(gx, gy, w, h, glyph.s0, glyph.t0, glyph.s1, glyph.t1, fg, clip_y0, clip_y1, glyph.color_emoji);
    }
    return true;
}

pub inline fn batchDirectGlyphSgl(self: *FtRenderer, px: f32, py: f32, cp: u32, face_idx: u8, fg: ghostty.ColorRgb, raster_mode: RasterMode) bool {
    const glyph = self.directGlyphForMode(cp, face_idx, raster_mode) orelse return false;

    const w = @as(f32, @floatFromInt(glyph.bw));
    const h = @as(f32, @floatFromInt(glyph.bh));
    if (w > 0 and h > 0) {
        const gx = @round(px + @as(f32, @floatFromInt(glyph.bear_x)));
        const gy = @round(py + self.ascender - @as(f32, @floatFromInt(glyph.bear_y)));
        if (glyph.color_emoji) {
            c.sgl_c4b(255, 255, 255, 255);
        } else {
            c.sgl_c4b(fg.r, fg.g, fg.b, 255);
        }
        c.sgl_v2f_t2f(gx, gy, glyph.s0, glyph.t0);
        c.sgl_v2f_t2f(gx + w, gy, glyph.s1, glyph.t0);
        c.sgl_v2f_t2f(gx + w, gy + h, glyph.s1, glyph.t1);
        c.sgl_v2f_t2f(gx, gy + h, glyph.s0, glyph.t1);
    }
    return true;
}

pub inline fn directGlyph(self: *FtRenderer, cp: u32, face_idx: u8) ?Glyph {
    return self.directGlyphForMode(cp, face_idx, .terminal);
}

pub inline fn directGlyphForMode(self: *FtRenderer, cp: u32, face_idx: u8, raster_mode: RasterMode) ?Glyph {
    if (face_idx > 3 or cp == 0) return null;
    if (cp < 0x100) {
        // Skip C1 control range (0x7F–0x9F) — these are never printable.
        if (cp > 0x7E and cp < 0xA0) return null;
        if (raster_mode != .terminal) {
            const face = self.faceForRasterIndex(face_idx) orelse return null;
            const glyph_id = ft.FT_Get_Char_Index(face, cp);
            if (glyph_id == 0) return null;
            return self.getOrRasterize(glyph_id, face_idx, raster_mode);
        }
        const fi: usize = @intCast(face_idx);
        const glyph = self.ascii_glyphs[fi][cp] orelse blk: {
            const face = self.faceForRasterIndex(face_idx) orelse return null;
            const glyph_id = ft.FT_Get_Char_Index(face, cp);
            if (glyph_id == 0) {
                self.ascii_glyphs[fi][cp] = Glyph{ .s0 = 0, .t0 = 0, .s1 = 0, .t1 = 0, .bw = -1, .bh = 0, .bear_x = 0, .bear_y = 0, .advance_x = 0, .color_emoji = false };
                return null;
            }
            const g = self.getOrRasterize(glyph_id, face_idx, .terminal) orelse {
                self.ascii_glyphs[fi][cp] = Glyph{ .s0 = 0, .t0 = 0, .s1 = 0, .t1 = 0, .bw = 0, .bh = 0, .bear_x = 0, .bear_y = 0, .advance_x = 0, .color_emoji = false };
                break :blk self.ascii_glyphs[fi][cp].?;
            };
            self.ascii_glyphs[fi][cp] = g;
            break :blk g;
        };
        if (glyph.bw == -1) return null;
        return glyph;
    }

    const face = self.faceForRasterIndex(face_idx) orelse return null;
    const glyph_id = ft.FT_Get_Char_Index(face, cp);
    if (glyph_id == 0) return null;
    return self.getOrRasterize(glyph_id, face_idx, raster_mode);
}

/// Append one glyph quad (4 vertices) to the CPU staging buffer.
/// Called from batchGlyphs() and drawAsciiGlyph().  Does nothing when the
/// staging buffer is full (glyph is silently dropped rather than crashing).
///
/// clip_y0 / clip_y1: vertical row bounds [py, py+cell_h].  The quad is
/// clipped to this range and UV coordinates are adjusted proportionally.
/// This prevents glyph pixels from bleeding into adjacent rows' pixel space
/// in the offscreen render target, which would cause ghost accumulation on
/// partial (LOAD) re-renders when the adjacent row is hash-skipped.
pub inline fn emitGlyphQuad(
    self: *FtRenderer,
    gx: f32,
    gy: f32,
    w: f32,
    h: f32,
    s0: f32,
    t0: f32,
    s1: f32,
    t1: f32,
    fg: ghostty.ColorRgb,
    clip_y0: f32,
    clip_y1: f32,
    color_emoji: bool,
) void {
    if (self.glyph_verts_count + 4 > MAX_GLYPH_VERTS) return;

    const base = self.glyph_verts_count;
    const verts = self.glyph_verts_cpu;
    // For color emoji: vertex alpha = 0 signals the shader to output atlas RGBA
    // directly (fg colour is ignored — set to white as a safe fallback).
    // For grayscale: vertex alpha = 255, fg tints the glyph.
    const VFgColor = struct { r: u8, g: u8, b: u8, a: u8 };
    const vfg = if (color_emoji) VFgColor{ .r = 255, .g = 255, .b = 255, .a = 0 } else VFgColor{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };

    // Common case: the glyph quad is already fully contained within the row's
    // clip bounds, so avoid the extra clipping/interpolation math.
    if (gy >= clip_y0 and gy + h <= clip_y1) {
        verts[base + 0] = .{ .x = gx, .y = gy, .u = s0, .v = t0, .r = vfg.r, .g = vfg.g, .b = vfg.b, .a = vfg.a };
        verts[base + 1] = .{ .x = gx + w, .y = gy, .u = s1, .v = t0, .r = vfg.r, .g = vfg.g, .b = vfg.b, .a = vfg.a };
        verts[base + 2] = .{ .x = gx + w, .y = gy + h, .u = s1, .v = t1, .r = vfg.r, .g = vfg.g, .b = vfg.b, .a = vfg.a };
        verts[base + 3] = .{ .x = gx, .y = gy + h, .u = s0, .v = t1, .r = vfg.r, .g = vfg.g, .b = vfg.b, .a = vfg.a };
        self.glyph_verts_count += 4;
        return;
    }

    // Clip the quad vertically to [clip_y0, clip_y1] and adjust UVs.
    const bottom = gy + h;
    const clipped_top = @max(gy, clip_y0);
    const clipped_bot = @min(bottom, clip_y1);
    if (clipped_top >= clipped_bot) return; // fully outside, skip

    // Map clipped pixel positions back to UV space.
    // t spans [t0, t1] over [gy, gy+h]; interpolate linearly.
    const inv_h = if (h > 0.0) 1.0 / h else 0.0;
    const tc_top = t0 + (clipped_top - gy) * inv_h * (t1 - t0);
    const tc_bot = t0 + (clipped_bot - gy) * inv_h * (t1 - t0);

    verts[base + 0] = .{ .x = gx, .y = clipped_top, .u = s0, .v = tc_top, .r = vfg.r, .g = vfg.g, .b = vfg.b, .a = vfg.a };
    verts[base + 1] = .{ .x = gx + w, .y = clipped_top, .u = s1, .v = tc_top, .r = vfg.r, .g = vfg.g, .b = vfg.b, .a = vfg.a };
    verts[base + 2] = .{ .x = gx + w, .y = clipped_bot, .u = s1, .v = tc_bot, .r = vfg.r, .g = vfg.g, .b = vfg.b, .a = vfg.a };
    verts[base + 3] = .{ .x = gx, .y = clipped_bot, .u = s0, .v = tc_bot, .r = vfg.r, .g = vfg.g, .b = vfg.b, .a = vfg.a };
    self.glyph_verts_count += 4;
}

/// Upload accumulated glyph vertices to the GPU vertex buffer.
///
/// MUST be called OUTSIDE any active sg_pass (before sg_begin_pass).
/// sg_update_buffer is not allowed inside a pass on D3D11.
///
/// Returns the number of vertices that were uploaded (0 = nothing to draw).
/// The CPU staging buffer is NOT cleared here — call drawGlyphQuads() inside
/// the subsequent pass to issue the actual draw, which clears the count.
pub fn uploadGlyphVerts(self: *FtRenderer) usize {
    const n_verts = self.glyph_verts_count;
    self.uploaded_glyph_verts = n_verts;
    if (n_verts == 0) return 0;
    var upd = std.mem.zeroes(c.sg_range);
    upd.ptr = self.glyph_verts_cpu.ptr;
    upd.size = n_verts * @sizeOf(GlyphVertex);
    const buf = self.glyph_vbufs[self.glyph_vbuf_index];
    self.glyph_vbuf_index = (self.glyph_vbuf_index + 1) % GLYPH_VBUF_RING_LEN;
    self.uploaded_glyph_vbuf = buf;
    c.sg_update_buffer(buf, &upd);
    return n_verts;
}

/// Issue the glyph draw call for vertices previously uploaded by uploadGlyphVerts().
///
/// MUST be called INSIDE an active sg_pass, after sgl_context_draw (or sgl_draw).
/// Resets glyph_verts_count to 0.
///
/// `pane_w` / `pane_h` are the render target dimensions (for the ortho MVP).
/// `offscreen` = true when rendering into a pane's RGBA8 offscreen RT;
///              = false when rendering into the swapchain pass.
pub fn drawGlyphQuads(self: *FtRenderer, pane_w: f32, pane_h: f32, offscreen: bool, bg_linear: [4]f32) void {
    const n_verts = self.uploaded_glyph_verts;
    defer {
        self.glyph_verts_count = 0;
        self.uploaded_glyph_verts = 0;
    }
    if (n_verts == 0) return;

    if (self.frame_count <= 3) {
        std.log.info("ft_renderer drawGlyphQuads: frame={d} n_verts={d} offscreen={} pane={d:.0}x{d:.0}", .{
            self.frame_count, n_verts, offscreen, pane_w, pane_h,
        });
        if (n_verts >= 4) {
            const v0 = self.glyph_verts_cpu[0];
            std.log.info("  v[0]: x={d:.1} y={d:.1} u={d:.4} v={d:.4} rgba=({d},{d},{d},{d})", .{
                v0.x, v0.y, v0.u, v0.v, v0.r, v0.g, v0.b, v0.a,
            });
        }
    }

    const n_quads = n_verts / 4;
    const n_indices = n_quads * 6;

    // Column-major orthographic projection (pixel coords, Y-down):
    //   x: [0, pane_w]  →  [-1, +1]
    //   y: [0, pane_h]  →  [+1, -1]  (Y flipped for Y-down pixel space)
    const sx = 2.0 / pane_w;
    const sy = -2.0 / pane_h;
    const mvp = [16]f32{
        sx,   0.0, 0.0, 0.0,
        0.0,  sy,  0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        -1.0, 1.0, 0.0, 1.0,
    };

    const vs_params = VsParams{
        .mvp = mvp,
        .atlas_size = .{ @as(f32, ATLAS_W), @as(f32, ATLAS_H) },
        .vs_use_linear_correction = if (self.use_linear_correction) 1 else 0,
        ._pad = 0,
    };

    c.sg_apply_pipeline(if (offscreen) self.glyph_pip_offscreen else self.glyph_pip);

    var bindings = std.mem.zeroes(c.sg_bindings);
    bindings.vertex_buffers[0] = self.uploaded_glyph_vbuf;
    bindings.index_buffer = self.glyph_ibuf;
    bindings.views[0] = self.atlas_view;
    bindings.samplers[0] = self.atlas_smp;
    c.sg_apply_bindings(&bindings);

    var vs_range = std.mem.zeroes(c.sg_range);
    vs_range.ptr = &vs_params;
    vs_range.size = @sizeOf(VsParams);
    c.sg_apply_uniforms(0, &vs_range);

    // FsParams: bg_linear is the terminal background colour in linear space.
    // Callers convert from sRGB before passing.  Zero alpha falls back gracefully.
    const fs_params = FsParams{
        .bg_linear = bg_linear,
        .fs_use_linear_correction = if (self.use_linear_correction) 1 else 0,
        ._pad0 = 0,
        ._pad1 = 0,
        ._pad2 = 0,
    };
    var fs_range = std.mem.zeroes(c.sg_range);
    fs_range.ptr = &fs_params;
    fs_range.size = @sizeOf(FsParams);
    c.sg_apply_uniforms(1, &fs_range);

    c.sg_draw(0, @intCast(n_indices), 1);
}

pub fn discardGlyphQuads(self: *FtRenderer) void {
    self.glyph_verts_count = 0;
    self.uploaded_glyph_verts = 0;
}

/// Convenience wrapper: upload + draw in one call.
/// Use ONLY when you can guarantee the upload happens before the pass begins.
/// In cached-RT mode, use uploadGlyphVerts()/drawGlyphQuads() separately.
pub fn flushGlyphQuads(self: *FtRenderer, pane_w: f32, pane_h: f32, offscreen: bool, bg_linear: [4]f32) void {
    _ = self.uploadGlyphVerts();
    self.drawGlyphQuads(pane_w, pane_h, offscreen, bg_linear);
}

pub inline fn flushRasterRun(self: *FtRenderer, run_buf: []u8, run_start_col: *usize, run_len: *usize, face_idx: u8, fg: ghostty.ColorRgb, py: f32) void {
    _ = fg;
    _ = py;
    if (run_len.* == 0) return;
    const run = run_buf[0..run_len.*];
    if (self.prepareGlyphs(run, face_idx, .terminal)) |prepared| {
        self.recordShapedRun(run, face_idx, prepared.start, prepared.glyphs.len);
    } else {
        self.preRasterize(run, face_idx, .terminal);
    }
    run_start_col.* = 0;
    run_len.* = 0;
}

pub inline fn flushDrawRun(self: *FtRenderer, run_buf: []u8, run_start_col: *usize, run_len: *usize, face_idx: u8, fg: ghostty.ColorRgb, py: f32) void {
    if (run_len.* == 0) return;
    self.last_glyph_runs += 1;
    const px = self.padding_x + @as(f32, @floatFromInt(run_start_col.*)) * self.cell_w;
    const run = run_buf[0..run_len.*];
    if (self.consumeShapedRun(run, face_idx)) |prepared| {
        self.batchPreparedGlyphs(px, py, prepared, fg, py, py + self.cell_h);
    } else {
        self.batchGlyphs(px, py, run, face_idx, fg, .terminal, py, py + self.cell_h);
    }
    run_start_col.* = 0;
    run_len.* = 0;
}

pub inline fn styleCacheReset(self: *FtRenderer) void {
    @memset(&self.style_cache, null);
}

pub inline fn resolveCachedStyle(self: *FtRenderer, runtime: *ghostty.Runtime, row_cells: ?*anyopaque, style_id: u16, selected: bool, default_fg: ghostty.ColorRgb, default_bg: ghostty.ColorRgb, selection_fg: ghostty.ColorRgb, palette: *const [256]ghostty.ColorRgb) ?*const CachedStyleInfo {
    const slot = self.styleCacheSlot(style_id, selected);
    if (self.style_cache[slot]) |*cached| {
        if (cached.style_id == style_id and cached.selected == selected) return cached;
    }

    var s: ghostty.Style = undefined;
    if (!runtime.cellStyleInto(row_cells, &s)) return null;
    const resolved_fg = ghostty.resolveStyleColor(s.fg_color, default_fg, palette);
    const resolved_bg = if (s.bg_color.tag != .none)
        ghostty.resolveStyleColor(s.bg_color, default_bg, palette)
    else
        default_bg;
    const effective_fg = if (selected)
        selection_fg
    else if (s.inverse)
        resolved_bg
    else
        resolved_fg;
    const effective_bg = if (s.inverse) resolved_fg else resolved_bg;
    const info = CachedStyleInfo{
        .style_id = style_id,
        .selected = selected,
        .face_idx = if (s.bold and s.italic) 2 else if (s.bold) 1 else if (s.italic) 3 else 0,
        .fg = effective_fg,
        .bg = effective_bg,
        .has_non_default_bg = !selected and !colorsEqual(effective_bg, default_bg),
        .renders_background_without_text = s.inverse or s.invisible,
        .needs_decorations = s.underline != 0 or s.strikethrough or s.overline,
        .underline_color = s.underline_color,
        .underline = s.underline,
        .strikethrough = s.strikethrough,
        .overline = s.overline,
    };
    self.style_cache[slot] = info;
    return &self.style_cache[slot].?;
}

pub inline fn styleCacheSlot(self: *FtRenderer, style_id: u16, selected: bool) usize {
    _ = self;
    const key: u32 = (@as(u32, style_id) << 1) | @intFromBool(selected);
    return key & (STYLE_CACHE_SIZE - 1);
}

/// Shape and batch glyphs for one cell at (px, py) using sokol_gl vertex
/// emission (sgl_v2f_t2f).  Must be called between sgl_begin_quads /
/// sgl_end.  Used exclusively by drawLabelFace for the tab bar / UI text
/// so that it does NOT touch glyph_verts_cpu (which is for the custom
/// gamma-correct pipeline only).
pub fn batchGlyphsSgl(self: *FtRenderer, px: f32, py: f32, utf8: []const u8, face_idx: u8, fg: ghostty.ColorRgb, raster_mode: RasterMode) void {
    if (utf8.len > 0 and utf8.len <= 4) {
        const cp_len = utf8CodepointLen(utf8[0]);
        if (cp_len == utf8.len) {
            const cp = std.unicode.utf8Decode(utf8) catch 0;
            if (cp != 0 and isAsciiFastPathCandidate(cp, face_idx)) {
                if (self.batchDirectGlyphSgl(px, py, cp, face_idx, fg, raster_mode)) return;
            }
        }
    }

    const result = self.getOrShape(utf8, face_idx) orelse return;

    var x_offset: f32 = 0;
    for (result.glyphs) |glyph_inst| {
        const glyph = self.getOrRasterize(glyph_inst.glyph_id, result.raster_face_index, raster_mode) orelse continue;

        // Snap to integer pixels to prevent subpixel sampling artifacts.
        const gx = @round(px + x_offset + glyph_inst.x_offset + @as(f32, @floatFromInt(glyph.bear_x)));
        const gy = @round(py + self.ascender - glyph_inst.y_offset - @as(f32, @floatFromInt(glyph.bear_y)));

        const w = @as(f32, @floatFromInt(glyph.bw));
        const h = @as(f32, @floatFromInt(glyph.bh));
        if (w > 0 and h > 0) {
            // Color emoji: use white foreground so atlas RGBA shows through.
            // Grayscale: use the specified foreground colour.
            if (glyph.color_emoji) {
                c.sgl_c4b(255, 255, 255, 255);
            } else {
                c.sgl_c4b(fg.r, fg.g, fg.b, 255);
            }
            // Emit quad as two triangles via sokol_gl.
            c.sgl_v2f_t2f(gx, gy, glyph.s0, glyph.t0);
            c.sgl_v2f_t2f(gx + w, gy, glyph.s1, glyph.t0);
            c.sgl_v2f_t2f(gx + w, gy + h, glyph.s1, glyph.t1);
            c.sgl_v2f_t2f(gx, gy + h, glyph.s0, glyph.t1);
        }

        x_offset += glyph_inst.x_advance;
    }
}

pub inline fn isAsciiFastPathCandidate(cp: u32, face_idx: u8) bool {
    if (cp < 0x21 or cp > 0xFF or face_idx > 3) return false;
    if (cp > 0x7E and cp < 0xA0) return false;
    return true;
}

test "isAsciiFastPathCandidate: printable ASCII in faces 0-3" {
    try std.testing.expect(isAsciiFastPathCandidate('A', 0));
    try std.testing.expect(isAsciiFastPathCandidate('A', 3));
    try std.testing.expect(!isAsciiFastPathCandidate('A', 4)); // face > 3
    try std.testing.expect(!isAsciiFastPathCandidate(0x20, 0)); // space (0x20 < 0x21)
    try std.testing.expect(!isAsciiFastPathCandidate(0x7F, 0)); // DEL
    try std.testing.expect(!isAsciiFastPathCandidate(0x9F, 0)); // C1 control
    try std.testing.expect(isAsciiFastPathCandidate(0xFF, 0)); // Latin-1 supplement
}

test "isAsciiFastPathCandidate: rejects face indices > 3" {
    try std.testing.expect(!isAsciiFastPathCandidate('A', 5));
    try std.testing.expect(!isAsciiFastPathCandidate('A', 255));
}