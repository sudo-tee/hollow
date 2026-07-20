/// Synthesized terminal glyph generation (box-drawing, block elements, rounded arcs).
///
/// Contains:
///   - Codepoint predicates (isBoxDrawing, isQuadrant, isRoundedArc, …)
///   - Block-element rect decomposition (synthesizedTerminalRect + helpers)
///   - Direct sgl draw path for block/quadrant codepoints
///   - Atlas-backed box-drawing glyph rasterisation (ensureSynthesizedBoxGlyph,
///     ensureSynthesizedRoundedArcGlyph) — these are free functions taking
///     `*FtRenderer` so they can be called from the main struct via thin wrappers.
///
/// Pilot for the method-extraction pattern used by subsequent phases:
///   ft_renderer.zig defines `pub fn foo(self, ...) { return synth_glyphs.foo(self, ...); }`
const std = @import("std");
const c = @import("sokol_c");
const ghostty = @import("../term/ghostty.zig");

const ft_types = @import("ft_types.zig");
const FtRenderer = @import("ft_renderer.zig").FtRenderer;
const emitRect = @import("ft_renderer.zig").emitRect;
const box_draw = @import("box_draw.zig");
const firstRenderableCodepoint = @import("font_discovery.zig").firstRenderableCodepoint;

const Glyph = ft_types.Glyph;
const GlyphKey = ft_types.GlyphKey;
const ATLAS_W = ft_types.ATLAS_W;
const ATLAS_H = ft_types.ATLAS_H;
const ATLAS_BPP = ft_types.ATLAS_BPP;

/// Face index used for synthesized (CPU-drawn) glyphs in the glyph cache.
/// Chosen to not collide with real FreeType face indices (0..~250).
pub const SYNTHETIC_FACE: u8 = 250;

// ── Types ─────────────────────────────────────────────────────────────────────

pub const TerminalRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const SynthesizedResult = struct {
    r0: TerminalRect,
    r1: TerminalRect,
    count: u32,
};

// ── Codepoint predicates ──────────────────────────────────────────────────────

pub fn isSynthesizedTerminalCodepoint(cp: u32) bool {
    return isBoxDrawingCodepoint(cp) or isBlockElementCodepoint(cp) or isQuadrantCodepoint(cp) or isGeometricShapeCodepoint(cp) or synthesizedTerminalRect(1.0, 1.0, cp) != null;
}

pub fn isBoxDrawingCodepoint(cp: u32) bool {
    return cp >= 0x2500 and cp <= 0x257F;
}

pub fn isBlockElementCodepoint(cp: u32) bool {
    return cp >= 0x2580 and cp <= 0x259F;
}

pub fn isQuadrantCodepoint(cp: u32) bool {
    return cp >= 0x2596 and cp <= 0x259F;
}

pub fn isGeometricShapeCodepoint(cp: u32) bool {
    return switch (cp) {
        0x25E2...0x25E5, 0x25F8...0x25FA, 0x25FF => true,
        else => false,
    };
}

pub fn isRoundedArcCodepoint(cp: u32) bool {
    return switch (cp) {
        0x256D, 0x256E, 0x256F, 0x2570 => true,
        else => false,
    };
}

// ── Direct sgl draw path (block elements / quadrants) ─────────────────────────

pub fn drawSynthesizedTerminalUtf8(x: f32, y: f32, cell_w: f32, cell_h: f32, utf8: []const u8, color: ghostty.ColorRgb) bool {
    const cp = firstRenderableCodepoint(utf8) orelse return false;
    return drawSynthesizedTerminalCodepoint(x, y, cell_w, cell_h, cp, color);
}

pub fn drawSynthesizedTerminalCodepoint(x: f32, y: f32, cell_w: f32, cell_h: f32, cp: u32, color: ghostty.ColorRgb) bool {
    const result = synthesizedTerminalRect(cell_w, cell_h, cp) orelse return false;
    c.sgl_begin_quads();
    emitRect(x + result.r0.x, y + result.r0.y, result.r0.w, result.r0.h, color.r, color.g, color.b, 255);
    if (result.count > 1) {
        emitRect(x + result.r1.x, y + result.r1.y, result.r1.w, result.r1.h, color.r, color.g, color.b, 255);
    }
    c.sgl_end();
    return true;
}

// ── Block-element rect decomposition ──────────────────────────────────────────

pub fn synthesizedTerminalRect(cell_w: f32, cell_h: f32, cp: u32) ?SynthesizedResult {
    if (cell_w <= 0.0 or cell_h <= 0.0) return null;

    const eighth_w = @max(1.0, @round(cell_w / 8.0));
    const quarter_w = @max(1.0, @round(cell_w / 4.0));
    const half_w = @max(1.0, @round(cell_w / 2.0));
    const eighth_h = @max(1.0, @round(cell_h / 8.0));
    const quarter_h = @max(1.0, @round(cell_h / 4.0));
    const half_h = @max(1.0, @round(cell_h / 2.0));

    return switch (cp) {
        0x2580 => single(topRect(cell_w, cell_h, half_h)),
        0x2581 => single(bottomRect(cell_w, cell_h, eighth_h)),
        0x2582 => single(bottomRect(cell_w, cell_h, quarter_h)),
        0x2583 => single(bottomRect(cell_w, cell_h, 3.0 * eighth_h)),
        0x2584 => single(bottomRect(cell_w, cell_h, half_h)),
        0x2585 => single(bottomRect(cell_w, cell_h, 5.0 * eighth_h)),
        0x2586 => single(bottomRect(cell_w, cell_h, 6.0 * eighth_h)),
        0x2587 => single(bottomRect(cell_w, cell_h, 7.0 * eighth_h)),
        0x2588 => single(.{ .x = 0.0, .y = 0.0, .w = cell_w, .h = cell_h }),
        0x2589 => single(leftRect(cell_w, cell_h, 7.0 * eighth_w)),
        0x258A => single(leftRect(cell_w, cell_h, 6.0 * eighth_w)),
        0x258B => single(leftRect(cell_w, cell_h, 5.0 * eighth_w)),
        0x258C => single(leftRect(cell_w, cell_h, half_w)),
        0x258D => single(leftRect(cell_w, cell_h, 3.0 * eighth_w)),
        0x258E => single(leftRect(cell_w, cell_h, quarter_w)),
        0x258F => single(leftRect(cell_w, cell_h, eighth_w)),
        0x2590 => single(rightRect(cell_w, cell_h, half_w)),
        0x2594 => single(topRect(cell_w, cell_h, eighth_h)),
        0x2595 => single(rightRect(cell_w, cell_h, eighth_w)),

        else => null,
    };
}

fn single(r: TerminalRect) SynthesizedResult {
    return .{ .r0 = r, .r1 = undefined, .count = 1 };
}

fn two(r0: TerminalRect, r1: TerminalRect) SynthesizedResult {
    return .{ .r0 = r0, .r1 = r1, .count = 2 };
}

fn topRect(cell_w: f32, cell_h: f32, desired_h: f32) TerminalRect {
    const h = @min(cell_h, @max(1.0, desired_h));
    return .{ .x = 0.0, .y = 0.0, .w = cell_w, .h = h };
}

fn bottomRect(cell_w: f32, cell_h: f32, desired_h: f32) TerminalRect {
    const h = @min(cell_h, @max(1.0, desired_h));
    return .{ .x = 0.0, .y = cell_h - h, .w = cell_w, .h = h };
}

fn leftRect(cell_w: f32, cell_h: f32, desired_w: f32) TerminalRect {
    const w = @min(cell_w, @max(1.0, desired_w));
    return .{ .x = 0.0, .y = 0.0, .w = w, .h = cell_h };
}

fn rightRect(cell_w: f32, cell_h: f32, desired_w: f32) TerminalRect {
    const w = @min(cell_w, @max(1.0, desired_w));
    return .{ .x = cell_w - w, .y = 0.0, .w = w, .h = cell_h };
}

// ── Atlas-backed box-drawing glyph rasterisation ──────────────────────────────
//
// These functions take `*FtRenderer` so they can access the atlas, glyph cache,
// and cell metrics.  In ft_renderer.zig they are wrapped as one-line methods:
//   fn ensureSynthesizedBoxGlyph(self, cp) ?Glyph { return synth_glyphs.ensureSynthesizedBoxGlyph(self, cp); }

pub fn ensureSynthesizedBoxGlyph(self: *FtRenderer, cp: u32) ?Glyph {
    if (!isBoxDrawingCodepoint(cp) and !isBlockElementCodepoint(cp) and !isQuadrantCodepoint(cp) and !isGeometricShapeCodepoint(cp)) return null;
    if (isRoundedArcCodepoint(cp)) return ensureSynthesizedRoundedArcGlyph(self, cp);

    const bw: u32 = @intFromFloat(@ceil(self.cell_w));
    const bh: u32 = @intFromFloat(@ceil(self.cell_h));
    if (bw < 2 or bh < 2) return null;

    const key = GlyphKey{ .glyph_index = cp, .face_index = SYNTHETIC_FACE, .raster_mode = .terminal };
    if (self.glyph_cache.get(key)) |g| return g;

    const box_thickness: u32 = @max(1, @as(u32, @intFromFloat(@round(@min(self.cell_w, self.cell_h) / 12.0))));
    const metrics: box_draw.Metrics = .{
        .cell_width = bw,
        .cell_height = bh,
        .box_thickness = box_thickness,
    };
    const buf = self.allocator.alloc(u8, bw * bh) catch return null;
    defer self.allocator.free(buf);
    @memset(buf, 0);

    var canvas: box_draw.SimpleCanvas = .{
        .buf = buf,
        .width = bw,
        .height = bh,
    };
    box_draw.draw(cp, metrics, &canvas);

    if (self.atlas_x + bw + 1 >= ATLAS_W) {
        self.atlas_x = 1;
        self.atlas_y += self.atlas_row_h + 1;
        self.atlas_row_h = 0;
    }
    if (self.atlas_y + bh >= ATLAS_H) {
        std.log.warn("ft_renderer: glyph atlas full (box glyph)!", .{});
        return null;
    }

    var row: u32 = 0;
    while (row < bh) : (row += 1) {
        const dst_base = (self.atlas_y + row) * ATLAS_W * ATLAS_BPP + self.atlas_x * ATLAS_BPP;
        var col: u32 = 0;
        while (col < bw) : (col += 1) {
            const cov = self.boostCoverage(buf[row * bw + col]);
            const dst = dst_base + col * ATLAS_BPP;
            self.atlas_data[dst + 0] = cov;
            self.atlas_data[dst + 1] = cov;
            self.atlas_data[dst + 2] = cov;
            self.atlas_data[dst + 3] = cov;
        }
    }
    self.markAtlasDirty(self.atlas_x, self.atlas_y, bw, bh);

    if (bh > self.atlas_row_h) self.atlas_row_h = bh;

    const s0 = @as(f32, @floatFromInt(self.atlas_x)) / @as(f32, @floatFromInt(ATLAS_W));
    const t0 = @as(f32, @floatFromInt(self.atlas_y)) / @as(f32, @floatFromInt(ATLAS_H));
    const s1 = @as(f32, @floatFromInt(self.atlas_x + bw)) / @as(f32, @floatFromInt(ATLAS_W));
    const t1 = @as(f32, @floatFromInt(self.atlas_y + bh)) / @as(f32, @floatFromInt(ATLAS_H));

    self.atlas_x += bw + 1;

    const g = Glyph{ .s0 = s0, .t0 = t0, .s1 = s1, .t1 = t1, .bw = @intCast(bw), .bh = @intCast(bh), .bear_x = 0, .bear_y = @intFromFloat(@ceil(self.ascender)), .advance_x = self.cell_w, .color_emoji = false };
    self.glyph_cache.put(key, g) catch {};
    return g;
}

pub fn ensureSynthesizedRoundedArcGlyph(self: *FtRenderer, cp: u32) ?Glyph {
    const bd_lw = @max(1.0, @round(self.cell_w / 12.0));
    const bw: u32 = @intFromFloat(@ceil(self.cell_w));
    const bh: u32 = @intFromFloat(@ceil(self.cell_h));
    if (bw < 2 or bh < 2) return null;

    const key = GlyphKey{ .glyph_index = cp, .face_index = SYNTHETIC_FACE, .raster_mode = .terminal };
    if (self.glyph_cache.get(key)) |g| return g;

    const cw_f = self.cell_w;
    const ch_f = self.cell_h;
    const cx = cw_f / 2.0;
    const cy = ch_f / 2.0;
    const half_lw = bd_lw / 2.0;
    const segs: usize = @max(4, @min(32, @divFloor(bw, 2)));

    var pts: [64]struct { x: f32, y: f32 } = undefined;
    var npts: usize = 0;

    switch (cp) {
        0x256D => {
            const y1 = cy + cy / 2.0;
            const x2 = cx + cx / 2.0;
            pts[npts] = .{ .x = cx, .y = ch_f };
            npts += 1;
            pts[npts] = .{ .x = cx, .y = y1 };
            npts += 1;
            var i: usize = 1;
            while (i < segs) : (i += 1) {
                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs));
                const omt = 1.0 - t;
                const bx = omt * omt * cx + 2.0 * omt * t * cx + t * t * x2;
                const by = omt * omt * y1 + 2.0 * omt * t * cy + t * t * cy;
                pts[npts] = .{ .x = bx, .y = by };
                npts += 1;
            }
            pts[npts] = .{ .x = x2, .y = cy };
            npts += 1;
            pts[npts] = .{ .x = cw_f, .y = cy };
            npts += 1;
        },
        0x256E => {
            const y1 = cy + cy / 2.0;
            const x2 = cx - cx / 2.0;
            pts[npts] = .{ .x = cx, .y = ch_f };
            npts += 1;
            pts[npts] = .{ .x = cx, .y = y1 };
            npts += 1;
            var i: usize = 1;
            while (i < segs) : (i += 1) {
                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs));
                const omt = 1.0 - t;
                pts[npts] = .{ .x = omt * omt * cx + 2.0 * omt * t * cx + t * t * x2, .y = omt * omt * y1 + 2.0 * omt * t * cy + t * t * cy };
                npts += 1;
            }
            pts[npts] = .{ .x = x2, .y = cy };
            npts += 1;
            pts[npts] = .{ .x = 0.0, .y = cy };
            npts += 1;
        },
        0x256F => {
            const y1 = cy - cy / 2.0;
            const x2 = cx - cx / 2.0;
            pts[npts] = .{ .x = cx, .y = 0.0 };
            npts += 1;
            pts[npts] = .{ .x = cx, .y = y1 };
            npts += 1;
            var i: usize = 1;
            while (i < segs) : (i += 1) {
                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs));
                const omt = 1.0 - t;
                pts[npts] = .{ .x = omt * omt * cx + 2.0 * omt * t * cx + t * t * x2, .y = omt * omt * y1 + 2.0 * omt * t * cy + t * t * cy };
                npts += 1;
            }
            pts[npts] = .{ .x = x2, .y = cy };
            npts += 1;
            pts[npts] = .{ .x = 0.0, .y = cy };
            npts += 1;
        },
        0x2570 => {
            const y1 = cy - cy / 2.0;
            const x2 = cx + cx / 2.0;
            pts[npts] = .{ .x = cx, .y = 0.0 };
            npts += 1;
            pts[npts] = .{ .x = cx, .y = y1 };
            npts += 1;
            var i: usize = 1;
            while (i < segs) : (i += 1) {
                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs));
                const omt = 1.0 - t;
                pts[npts] = .{ .x = omt * omt * cx + 2.0 * omt * t * cx + t * t * x2, .y = omt * omt * y1 + 2.0 * omt * t * cy + t * t * cy };
                npts += 1;
            }
            pts[npts] = .{ .x = x2, .y = cy };
            npts += 1;
            pts[npts] = .{ .x = cw_f, .y = cy };
            npts += 1;
        },
        else => return null,
    }

    var buf: [2048]u8 = undefined;
    if (bw * bh > buf.len) return null;
    @memset(buf[0 .. bw * bh], 0);

    var py: u32 = 0;
    while (py < bh) : (py += 1) {
        var px: u32 = 0;
        while (px < bw) : (px += 1) {
            const fx = @as(f32, @floatFromInt(px)) + 0.5;
            const fy = @as(f32, @floatFromInt(py)) + 0.5;

            var min_dist: f32 = 1e6;
            var si: usize = 0;
            while (si + 1 < npts) : (si += 1) {
                const ax = pts[si].x;
                const ay = pts[si].y;
                const bx = pts[si + 1].x;
                const by = pts[si + 1].y;

                const dx = bx - ax;
                const dy = by - ay;
                const len2 = dx * dx + dy * dy;
                if (len2 < 0.0001) {
                    const d = (fx - ax) * (fx - ax) + (fy - ay) * (fy - ay);
                    if (d < min_dist) min_dist = d;
                    continue;
                }
                const t = ((fx - ax) * dx + (fy - ay) * dy) / len2;
                const clamped_t = @max(0.0, @min(1.0, t));
                const near_x = ax + clamped_t * dx;
                const near_y = ay + clamped_t * dy;
                const d = (fx - near_x) * (fx - near_x) + (fy - near_y) * (fy - near_y);
                if (d < min_dist) min_dist = d;
            }

            const dist = @sqrt(min_dist);
            var alpha: u8 = 0;
            if (dist <= half_lw - 0.5) {
                alpha = 255;
            } else if (dist < half_lw + 0.5) {
                const a_val = @round(255.0 * ((half_lw + 0.5) - dist) / 1.0);
                alpha = @intFromFloat(@min(a_val, @as(f32, 255.0)));
            }
            buf[py * bw + px] = alpha;
        }
    }

    if (self.atlas_x + bw + 1 >= ATLAS_W) {
        self.atlas_x = 1;
        self.atlas_y += self.atlas_row_h + 1;
        self.atlas_row_h = 0;
    }
    if (self.atlas_y + bh >= ATLAS_H) {
        std.log.warn("ft_renderer: glyph atlas full (arc glyph)!", .{});
        return null;
    }

    var row: u32 = 0;
    while (row < bh) : (row += 1) {
        const dst_base = (self.atlas_y + row) * ATLAS_W * ATLAS_BPP + self.atlas_x * ATLAS_BPP;
        var col: u32 = 0;
        while (col < bw) : (col += 1) {
            const cov = self.boostCoverage(buf[row * bw + col]);
            const dst = dst_base + col * ATLAS_BPP;
            self.atlas_data[dst + 0] = cov;
            self.atlas_data[dst + 1] = cov;
            self.atlas_data[dst + 2] = cov;
            self.atlas_data[dst + 3] = cov;
        }
    }
    self.markAtlasDirty(self.atlas_x, self.atlas_y, bw, bh);

    if (bh > self.atlas_row_h) self.atlas_row_h = bh;

    const s0 = @as(f32, @floatFromInt(self.atlas_x)) / @as(f32, @floatFromInt(ATLAS_W));
    const t0 = @as(f32, @floatFromInt(self.atlas_y)) / @as(f32, @floatFromInt(ATLAS_H));
    const s1 = @as(f32, @floatFromInt(self.atlas_x + bw)) / @as(f32, @floatFromInt(ATLAS_W));
    const t1 = @as(f32, @floatFromInt(self.atlas_y + bh)) / @as(f32, @floatFromInt(ATLAS_H));

    self.atlas_x += bw + 1;

    const g = Glyph{ .s0 = s0, .t0 = t0, .s1 = s1, .t1 = t1, .bw = @intCast(bw), .bh = @intCast(bh), .bear_x = 0, .bear_y = @intFromFloat(@ceil(self.ascender)), .advance_x = cw_f, .color_emoji = false };
    self.glyph_cache.put(key, g) catch {};
    return g;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "isBoxDrawingCodepoint: U+2500–U+257F" {
    try std.testing.expect(isBoxDrawingCodepoint(0x2500));
    try std.testing.expect(isBoxDrawingCodepoint(0x257F));
    try std.testing.expect(!isBoxDrawingCodepoint(0x24FF));
    try std.testing.expect(!isBoxDrawingCodepoint(0x2580));
}

test "isQuadrantCodepoint: U+2596–U+259F" {
    try std.testing.expect(isQuadrantCodepoint(0x2596));
    try std.testing.expect(isQuadrantCodepoint(0x259F));
    try std.testing.expect(!isQuadrantCodepoint(0x2595));
    try std.testing.expect(!isQuadrantCodepoint(0x25A0));
}

test "isRoundedArcCodepoint: four arc corners" {
    try std.testing.expect(isRoundedArcCodepoint(0x256D));
    try std.testing.expect(isRoundedArcCodepoint(0x256E));
    try std.testing.expect(isRoundedArcCodepoint(0x256F));
    try std.testing.expect(isRoundedArcCodepoint(0x2570));
    try std.testing.expect(!isRoundedArcCodepoint(0x256C));
}

test "synthesizedTerminalRect: full block U+2588" {
    const result = synthesizedTerminalRect(10.0, 20.0, 0x2588).?;
    try std.testing.expectEqual(@as(f32, 0.0), result.r0.x);
    try std.testing.expectEqual(@as(f32, 0.0), result.r0.y);
    try std.testing.expectEqual(@as(f32, 10.0), result.r0.w);
    try std.testing.expectEqual(@as(f32, 20.0), result.r0.h);
    try std.testing.expectEqual(@as(u32, 1), result.count);
}

test "synthesizedTerminalRect: top half U+2580" {
    const result = synthesizedTerminalRect(10.0, 20.0, 0x2580).?;
    try std.testing.expectEqual(@as(f32, 10.0), result.r0.w);
    try std.testing.expectEqual(@as(f32, 10.0), result.r0.h); // half of 20
    try std.testing.expectEqual(@as(f32, 0.0), result.r0.y); // top
}

test "synthesizedTerminalRect: bottom half U+2584" {
    const result = synthesizedTerminalRect(10.0, 20.0, 0x2584).?;
    try std.testing.expectEqual(@as(f32, 10.0), result.r0.w);
    try std.testing.expectEqual(@as(f32, 10.0), result.r0.h);
    try std.testing.expectEqual(@as(f32, 10.0), result.r0.y); // starts at half height
}

test "synthesizedTerminalRect: unknown codepoint returns null" {
    try std.testing.expectEqual(@as(?SynthesizedResult, null), synthesizedTerminalRect(10.0, 20.0, 0x4000));
}

test "synthesizedTerminalRect: zero-size cell returns null" {
    try std.testing.expectEqual(@as(?SynthesizedResult, null), synthesizedTerminalRect(0.0, 20.0, 0x2588));
    try std.testing.expectEqual(@as(?SynthesizedResult, null), synthesizedTerminalRect(10.0, 0.0, 0x2588));
}

test "topRect: clamps to cell height" {
    const r = topRect(10.0, 20.0, 100.0);
    try std.testing.expectEqual(@as(f32, 20.0), r.h); // clamped to cell_h
    try std.testing.expectEqual(@as(f32, 10.0), r.w);
}

test "bottomRect: positioned at bottom" {
    const r = bottomRect(10.0, 20.0, 5.0);
    try std.testing.expectEqual(@as(f32, 15.0), r.y); // 20 - 5
    try std.testing.expectEqual(@as(f32, 5.0), r.h);
}

test "leftRect: positioned at left" {
    const r = leftRect(10.0, 20.0, 3.0);
    try std.testing.expectEqual(@as(f32, 0.0), r.x);
    try std.testing.expectEqual(@as(f32, 3.0), r.w);
    try std.testing.expectEqual(@as(f32, 20.0), r.h);
}

test "rightRect: positioned at right" {
    const r = rightRect(10.0, 20.0, 3.0);
    try std.testing.expectEqual(@as(f32, 7.0), r.x); // 10 - 3
    try std.testing.expectEqual(@as(f32, 3.0), r.w);
}

test "isGeometricShapeCodepoint: triangles" {
    try std.testing.expect(isGeometricShapeCodepoint(0x25E2));
    try std.testing.expect(isGeometricShapeCodepoint(0x25E5));
    try std.testing.expect(isGeometricShapeCodepoint(0x25F8));
    try std.testing.expect(isGeometricShapeCodepoint(0x25FF));
    try std.testing.expect(!isGeometricShapeCodepoint(0x25E1));
    try std.testing.expect(!isGeometricShapeCodepoint(0x25F7));
}

test "isSynthesizedTerminalCodepoint: covers boxes, blocks, quadrants, and geometric shapes" {
    try std.testing.expect(isSynthesizedTerminalCodepoint(0x2500)); // box drawing
    try std.testing.expect(isSynthesizedTerminalCodepoint(0x2588)); // full block
    try std.testing.expect(isSynthesizedTerminalCodepoint(0x2596)); // quadrant
    try std.testing.expect(isSynthesizedTerminalCodepoint(0x25E2)); // geometric triangle
    try std.testing.expect(!isSynthesizedTerminalCodepoint(0x2440)); // unrelated
}
