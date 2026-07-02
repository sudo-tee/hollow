/// Colour, contrast, cursor-style, and selection-bounds helpers shared by the
/// terminal render pass.
///
/// These are pure functions over `ghostty.ColorRgb` / `selection.Range` with no
/// dependency on the `FtRenderer` struct, so they can be unit-tested in
/// isolation and reused by future render paths.

const std = @import("std");

const ghostty = @import("../term/ghostty.zig");
const selection = @import("../selection.zig");
const App = @import("../app.zig").App;
const copy_mode = @import("../app/copy_mode.zig");
const Pane = @import("../pane.zig").Pane;

// ── sRGB / linear conversion ─────────────────────────────────────────────────

/// Convert a single sRGB channel value [0,1] to linear light.
/// IEC 61966-2-1 piecewise formula (same as the shader).
pub inline fn srgbToLinear(v: f32) f32 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

/// Convert an sRGB colour (channels in [0,1]) to a linear-premultiplied [4]f32
/// suitable for `FsParams.bg_linear`.  Alpha is always 1.0 (opaque).
pub inline fn srgbToLinearBg(r: f32, g: f32, b: f32) [4]f32 {
    return .{ srgbToLinear(r), srgbToLinear(g), srgbToLinear(b), 1.0 };
}

pub inline fn colorsEqual(a: ghostty.ColorRgb, b: ghostty.ColorRgb) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}

// ── Perceptual luminance / contrast ──────────────────────────────────────────

pub fn relativeLuminance(color: ghostty.ColorRgb) f32 {
    const r = srgbToLinear(@as(f32, @floatFromInt(color.r)) / 255.0);
    const g = srgbToLinear(@as(f32, @floatFromInt(color.g)) / 255.0);
    const b = srgbToLinear(@as(f32, @floatFromInt(color.b)) / 255.0);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

pub fn contrastRatio(a: ghostty.ColorRgb, b: ghostty.ColorRgb) f32 {
    const la = relativeLuminance(a);
    const lb = relativeLuminance(b);
    const lighter = @max(la, lb);
    const darker = @min(la, lb);
    return (lighter + 0.05) / (darker + 0.05);
}

pub fn contrastTextColor(bg: ghostty.ColorRgb) ghostty.ColorRgb {
    const white = ghostty.ColorRgb{ .r = 255, .g = 255, .b = 255 };
    const black = ghostty.ColorRgb{ .r = 0, .g = 0, .b = 0 };
    return if (contrastRatio(bg, white) >= contrastRatio(bg, black)) white else black;
}

pub fn effectiveCursorColor(cursor: ghostty.ColorRgb, bg: ghostty.ColorRgb) ghostty.ColorRgb {
    const min_contrast: f32 = 4.5;
    if (contrastRatio(cursor, bg) >= min_contrast) return cursor;
    return contrastTextColor(bg);
}

// ── Colour mixing ─────────────────────────────────────────────────────────────

pub fn lerpByte(a: u8, b: u8, t: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(@round(af + (bf - af) * t));
}

pub fn mixColor(a: ghostty.ColorRgb, b: ghostty.ColorRgb, t: f32) ghostty.ColorRgb {
    const clamped = std.math.clamp(t, 0.0, 1.0);
    return .{
        .r = lerpByte(a.r, b.r, clamped),
        .g = lerpByte(a.g, b.g, clamped),
        .b = lerpByte(a.b, b.b, clamped),
    };
}

// ── Cursor blink / style resolution ──────────────────────────────────────────

pub const CURSOR_BLINK_INTERVAL_MS: i128 = 600;

pub fn blinkVisibleNow(now_ns: i128) bool {
    const now_ms = @divFloor(now_ns, std.time.ns_per_ms);
    const blink_phase = @divFloor(now_ms, CURSOR_BLINK_INTERVAL_MS);
    return @mod(blink_phase, @as(i128, 2)) == 0;
}

pub fn effectiveCursorStyle(
    runtime: *ghostty.Runtime,
    render_state: ?*anyopaque,
    pane: ?*const Pane,
    app: *const App,
    is_focused: bool,
) ?ghostty.CursorVisualStyle {
    if (pane) |value| {
        if (copy_mode.copyModeActiveForPane(app, value)) return null;
    }
    if (runtime.cursorPos(render_state) == null) return null;
    if (runtime.cursorPasswordInput(render_state)) return .block;
    if (!runtime.cursorVisible(render_state)) return null;
    if (runtime.cursorBlinking(render_state) and !blinkVisibleNow(std.time.nanoTimestamp())) return null;
    if (!is_focused) return app.config.unfocused_pane.cursor;
    return runtime.cursorVisualStyle(render_state);
}

// ── Selection bounds ─────────────────────────────────────────────────────────

pub const RowSelectionBounds = struct {
    start_col: usize,
    end_col: usize,
};

pub inline fn rowSelectionBounds(range: selection.Range, row: usize) ?RowSelectionBounds {
    if (!selection.rowIntersects(range, row)) return null;
    if (range.block) {
        return .{ .start_col = range.start.col, .end_col = range.end.col };
    }
    if (range.start.row == range.end.row) {
        return .{ .start_col = range.start.col, .end_col = range.end.col };
    }
    if (row == range.start.row) {
        return .{ .start_col = range.start.col, .end_col = std.math.maxInt(usize) };
    }
    if (row == range.end.row) {
        return .{ .start_col = 0, .end_col = range.end.col };
    }
    return .{ .start_col = 0, .end_col = std.math.maxInt(usize) };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "srgbToLinear: black and white" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), srgbToLinear(0.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), srgbToLinear(1.0), 1e-6);
}

test "srgbToLinear: linear region below 0.04045" {
    // Below the knee, sRGB is linear with slope 1/12.92.
    try std.testing.expectApproxEqAbs(@as(f32, 0.04 / 12.92), srgbToLinear(0.04), 1e-7);
}

test "srgbToLinearBg: alpha is always 1" {
    const out = srgbToLinearBg(0.5, 0.2, 0.7);
    try std.testing.expectEqual(@as(f32, 1.0), out[3]);
}

test "colorsEqual" {
    const a = ghostty.ColorRgb{ .r = 1, .g = 2, .b = 3 };
    try std.testing.expect(colorsEqual(a, a));
    try std.testing.expect(!colorsEqual(a, .{ .r = 0, .g = 2, .b = 3 }));
    try std.testing.expect(!colorsEqual(a, .{ .r = 1, .g = 0, .b = 3 }));
    try std.testing.expect(!colorsEqual(a, .{ .r = 1, .g = 2, .b = 0 }));
}

test "relativeLuminance: black is 0, white is 1" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), relativeLuminance(.{ .r = 0, .g = 0, .b = 0 }), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), relativeLuminance(.{ .r = 255, .g = 255, .b = 255 }), 1e-6);
}

test "relativeLuminance: green dominates" {
    // Pure green should be brighter than pure red, which is brighter than pure blue.
    const g = relativeLuminance(.{ .r = 0, .g = 255, .b = 0 });
    const r = relativeLuminance(.{ .r = 255, .g = 0, .b = 0 });
    const b = relativeLuminance(.{ .r = 0, .g = 0, .b = 255 });
    try std.testing.expect(g > r);
    try std.testing.expect(r > b);
}

test "contrastRatio: identical colours are 1" {
    const c = ghostty.ColorRgb{ .r = 128, .g = 64, .b = 200 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), contrastRatio(c, c), 1e-6);
}

test "contrastRatio: black vs white is 21" {
    const black = ghostty.ColorRgb{ .r = 0, .g = 0, .b = 0 };
    const white = ghostty.ColorRgb{ .r = 255, .g = 255, .b = 255 };
    try std.testing.expectApproxEqAbs(@as(f32, 21.0), contrastRatio(black, white), 0.01);
}

test "contrastTextColor: black bg → white text" {
    try std.testing.expectEqual(ghostty.ColorRgb{ .r = 255, .g = 255, .b = 255 }, contrastTextColor(.{ .r = 0, .g = 0, .b = 0 }));
    try std.testing.expectEqual(ghostty.ColorRgb{ .r = 0, .g = 0, .b = 0 }, contrastTextColor(.{ .r = 255, .g = 255, .b = 255 }));
}

test "effectiveCursorColor: high contrast passes through" {
    const cursor = ghostty.ColorRgb{ .r = 255, .g = 255, .b = 255 };
    const bg = ghostty.ColorRgb{ .r = 0, .g = 0, .b = 0 };
    try std.testing.expectEqual(cursor, effectiveCursorColor(cursor, bg));
}

test "effectiveCursorColor: low contrast is replaced" {
    // Cursor and bg both dark → should be flipped to a high-contrast colour.
    const cursor = ghostty.ColorRgb{ .r = 30, .g = 30, .b = 30 };
    const bg = ghostty.ColorRgb{ .r = 0, .g = 0, .b = 0 };
    const out = effectiveCursorColor(cursor, bg);
    try std.testing.expect(out.r == 255 or out.r == 0);
    try std.testing.expect(contrastRatio(out, bg) >= 4.5);
}

test "lerpByte: endpoints" {
    try std.testing.expectEqual(@as(u8, 0), lerpByte(0, 255, 0.0));
    try std.testing.expectEqual(@as(u8, 255), lerpByte(0, 255, 1.0));
    try std.testing.expectEqual(@as(u8, 100), lerpByte(100, 200, 0.0));
}

test "lerpByte: midpoint rounds" {
    // 0 + (255 - 0) * 0.5 = 127.5 → rounds to 128.
    try std.testing.expectEqual(@as(u8, 128), lerpByte(0, 255, 0.5));
}

test "mixColor: endpoints" {
    const a = ghostty.ColorRgb{ .r = 10, .g = 20, .b = 30 };
    const b = ghostty.ColorRgb{ .r = 100, .g = 200, .b = 255 };
    try std.testing.expectEqual(a, mixColor(a, b, 0.0));
    try std.testing.expectEqual(b, mixColor(a, b, 1.0));
}

test "mixColor: clamps out-of-range t" {
    const a = ghostty.ColorRgb{ .r = 0, .g = 0, .b = 0 };
    const b = ghostty.ColorRgb{ .r = 255, .g = 255, .b = 255 };
    try std.testing.expectEqual(a, mixColor(a, b, -1.0));
    try std.testing.expectEqual(b, mixColor(a, b, 2.0));
}

test "blinkVisibleNow: alternates at interval" {
    const ms = std.time.ns_per_ms;
    // At phase 0 (0ms, 1200ms...) blink is visible.
    try std.testing.expect(blinkVisibleNow(0));
    try std.testing.expect(blinkVisibleNow(599 * ms));
    try std.testing.expect(blinkVisibleNow(1200 * ms));
    // At phase 1 (600ms .. 1199ms) blink is hidden.
    try std.testing.expect(!blinkVisibleNow(600 * ms));
    try std.testing.expect(!blinkVisibleNow(601 * ms));
    try std.testing.expect(!blinkVisibleNow(1199 * ms));
}

test "rowSelectionBounds: single-row range" {
    const range = selection.Range{
        .start = .{ .row = 5, .col = 2 },
        .end = .{ .row = 5, .col = 10 },
        .block = false,
    };
    const b = rowSelectionBounds(range, 5).?;
    try std.testing.expectEqual(@as(usize, 2), b.start_col);
    try std.testing.expectEqual(@as(usize, 10), b.end_col);
    try std.testing.expectEqual(@as(?RowSelectionBounds, null), rowSelectionBounds(range, 4));
    try std.testing.expectEqual(@as(?RowSelectionBounds, null), rowSelectionBounds(range, 6));
}

test "rowSelectionBounds: multi-row range, start row" {
    const range = selection.Range{
        .start = .{ .row = 3, .col = 7 },
        .end = .{ .row = 7, .col = 4 },
        .block = false,
    };
    const b = rowSelectionBounds(range, 3).?;
    try std.testing.expectEqual(@as(usize, 7), b.start_col);
    try std.testing.expectEqual(std.math.maxInt(usize), b.end_col);
}

test "rowSelectionBounds: multi-row range, end row" {
    const range = selection.Range{
        .start = .{ .row = 3, .col = 7 },
        .end = .{ .row = 7, .col = 4 },
        .block = false,
    };
    const b = rowSelectionBounds(range, 7).?;
    try std.testing.expectEqual(@as(usize, 0), b.start_col);
    try std.testing.expectEqual(@as(usize, 4), b.end_col);
}

test "rowSelectionBounds: middle row is full-width" {
    const range = selection.Range{
        .start = .{ .row = 3, .col = 7 },
        .end = .{ .row = 7, .col = 4 },
        .block = false,
    };
    const b = rowSelectionBounds(range, 5).?;
    try std.testing.expectEqual(@as(usize, 0), b.start_col);
    try std.testing.expectEqual(std.math.maxInt(usize), b.end_col);
}

test "rowSelectionBounds: block selection uses explicit cols" {
    const range = selection.Range{
        .start = .{ .row = 3, .col = 5 },
        .end = .{ .row = 7, .col = 15 },
        .block = true,
    };
    const b = rowSelectionBounds(range, 5).?;
    try std.testing.expectEqual(@as(usize, 5), b.start_col);
    try std.testing.expectEqual(@as(usize, 15), b.end_col);
}
