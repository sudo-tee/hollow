/// Shared types, constants, and cache contexts for the FreeType renderer.
///
/// Contains the atlas/shader constants, vertex/uniform structs, glyph cache
/// entry types, shaping/prepared-run key types, HashMap contexts, and the
/// diagnostic enum `RasterMode`.  Everything in this module is a pure type or
/// constant — no logic — so it can be imported by every other renderer
/// submodule without creating circular dependencies.

const std = @import("std");
const c = @import("sokol_c");
const ghostty = @import("../term/ghostty.zig");

// ── Atlas constants ───────────────────────────────────────────────────────────

pub const ATLAS_W: u32 = 2048;
pub const ATLAS_H: u32 = 2048;
pub const ATLAS_BPP: u32 = 4; // RGBA8

// ── Custom glyph shader types ─────────────────────────────────────────────────
//
// Vertex layout (interleaved, stride = 20 bytes):
//   offset  0 — f32x2 position (screen-space pixels, Y-down)
//   offset  8 — f32x2 texcoord (normalised 0..1 atlas UVs)
//   offset 16 — u8x4  fg_rgba  (sRGB, non-premultiplied, normalised → [0,1])
//
// We emit 4 vertices per glyph quad (triangle-list: 6 indices via an index buffer).
//
// NOTE: must be `extern struct` (not `packed struct`) — packed structs in Zig
// do not guarantee C-ABI field ordering/padding for non-integer types like f32,
// which results in @sizeOf = 32 instead of the required 20. extern struct gives
// the correct stride-20 layout: 4×f32 (16 bytes) + 4×u8 (4 bytes) = 20 bytes.
pub const GlyphVertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    // sRGB u8 colour channels (non-premultiplied). The vertex shader linearises.
    r: u8,
    g: u8,
    b: u8,
    a: u8, // always 255 for opaque glyphs
};

// Vertex-shader uniform block (binding 0, std140).
// mat4 is 64 bytes, float2 is 8 bytes, uint is 4 bytes + 4 pad = 80 bytes total.
pub const VsParams = extern struct {
    mvp: [16]f32 align(16), // column-major orthographic projection
    atlas_size: [2]f32 align(8), // ATLAS_W, ATLAS_H (for potential future use)
    vs_use_linear_correction: u32 align(4),
    _pad: u32 = 0,
};

// Fragment-shader uniform block (binding 1, std140).
pub const FsParams = extern struct {
    bg_linear: [4]f32 align(16), // linear-premultiplied background colour
    fs_use_linear_correction: u32 align(4),
    _pad0: u32 = 0,
    _pad1: u32 = 0,
    _pad2: u32 = 0,
};

// Maximum glyph quads we buffer per draw pass.
// At 300 cols × 100 rows that's 30 000 glyphs × 4 verts = 120 000 vertices.
// A typical 80×24 terminal is ~1 920 glyphs.  256k gives comfortable headroom.
pub const MAX_GLYPH_VERTS: usize = 256 * 1024;
pub const GLYPH_VBUF_RING_LEN: usize = 8;
pub const KITTY_TEXTURE_CACHE_LEN: usize = 64;

// ── Raster mode ───────────────────────────────────────────────────────────────

pub const RasterMode = enum {
    terminal,
    ui,
};

// ── Glyph cache entry ─────────────────────────────────────────────────────────

pub const Glyph = struct {
    /// Atlas UV coordinates (0..1).
    s0: f32,
    t0: f32,
    s1: f32,
    t1: f32,
    /// Pixel dimensions of the bitmap.
    bw: i32,
    bh: i32,
    /// Bearing (offset from baseline to top-left of bitmap), in pixels.
    bear_x: i32,
    bear_y: i32,
    /// Horizontal advance, in pixels (26.6 fixed → pixels).
    advance_x: f32,
    /// True if this glyph is a color emoji bitmap (BGRA pixel data).
    color_emoji: bool,
};

pub const CachedStyleInfo = struct {
    style_id: u16,
    selected: bool,
    face_idx: u8,
    fg: ghostty.ColorRgb,
    bg: ghostty.ColorRgb,
    has_non_default_bg: bool,
    renders_background_without_text: bool,
    needs_decorations: bool,
    underline_color: ghostty.StyleColor,
    underline: i32,
    strikethrough: bool,
    overline: bool,
};

pub const STYLE_CACHE_SIZE = 1024;

// ── Cache key types ───────────────────────────────────────────────────────────

// Key: (glyph_index, face_index, raster mode)
pub const GlyphKey = struct {
    glyph_index: u32,
    face_index: u8,
    raster_mode: RasterMode,
};

pub const ShapeKey = struct {
    text: [128]u8,
    len: u8,
    face_idx: u8,
    ligatures: bool,
};

pub const KittyTextureKey = struct {
    image_id: u32,
    width: u32,
    height: u32,
    format: ghostty.KittyImageFormat,
    data_len: usize,
    data_ptr: usize,
};

pub const KittyTexture = struct {
    key: KittyTextureKey,
    image: c.sg_image,
    view: c.sg_view,

    pub fn deinit(self: *KittyTexture) void {
        c.sg_destroy_view(self.view);
        c.sg_destroy_image(self.image);
    }
};

// ── Shaping / prepared-run types ──────────────────────────────────────────────

pub const GlyphInstance = struct {
    glyph_id: u32,
    x_advance: f32,
    x_offset: f32,
    y_offset: f32,
};

pub const PreparedGlyph = struct {
    inst: GlyphInstance,
    glyph: Glyph,
};

pub const ShapedRunEntry = struct {
    fingerprint: u64,
    key: ShapeKey,
    prepared_start: usize,
    prepared_len: usize,
};

pub const PreparedRun = struct {
    start: usize,
    glyphs: []PreparedGlyph,
};

pub const PreparedKey = struct {
    text: [128]u8,
    len: u8,
    face_idx: u8,
    ligatures: bool,
    raster_mode: RasterMode,
};

pub const PreparedCacheEntry = struct {
    glyphs: []PreparedGlyph,
};

pub const RecentPreparedEntry = struct {
    fingerprint: u64,
    key: PreparedKey,
    glyphs: []PreparedGlyph,
};

pub const RECENT_PREPARED_CACHE_LEN: usize = 128;

pub const ShapeResult = struct {
    glyphs: []const GlyphInstance,
    raster_face_index: u8,
};

// ── HashMap contexts ──────────────────────────────────────────────────────────

pub const GlyphCacheContext = struct {
    pub fn hash(_: @This(), key: GlyphKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.glyph_index));
        hasher.update(std.mem.asBytes(&key.face_index));
        const mode: u8 = @intFromEnum(key.raster_mode);
        hasher.update(std.mem.asBytes(&mode));
        return hasher.final();
    }

    pub fn eql(_: @This(), a: GlyphKey, b: GlyphKey) bool {
        return a.glyph_index == b.glyph_index and
            a.face_index == b.face_index and
            a.raster_mode == b.raster_mode;
    }
};

pub const ShapeCacheContext = struct {
    pub fn hash(_: @This(), key: ShapeKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.text[0..key.len]);
        hasher.update(std.mem.asBytes(&key.len));
        hasher.update(std.mem.asBytes(&key.face_idx));
        const liga: u8 = @intFromBool(key.ligatures);
        hasher.update(std.mem.asBytes(&liga));
        return hasher.final();
    }

    pub fn eql(_: @This(), a: ShapeKey, b: ShapeKey) bool {
        return a.len == b.len and
            a.face_idx == b.face_idx and
            a.ligatures == b.ligatures and
            std.mem.eql(u8, a.text[0..a.len], b.text[0..b.len]);
    }
};

pub const PreparedCacheContext = struct {
    pub fn hash(_: @This(), key: PreparedKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.text[0..key.len]);
        hasher.update(std.mem.asBytes(&key.len));
        hasher.update(std.mem.asBytes(&key.face_idx));
        const liga: u8 = @intFromBool(key.ligatures);
        hasher.update(std.mem.asBytes(&liga));
        const mode: u8 = @intFromEnum(key.raster_mode);
        hasher.update(std.mem.asBytes(&mode));
        return hasher.final();
    }

    pub fn eql(_: @This(), a: PreparedKey, b: PreparedKey) bool {
        return a.len == b.len and
            a.face_idx == b.face_idx and
            a.ligatures == b.ligatures and
            a.raster_mode == b.raster_mode and
            std.mem.eql(u8, a.text[0..a.len], b.text[0..b.len]);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "GlyphVertex stride is 20 bytes" {
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(GlyphVertex));
}

test "VsParams size is 80 bytes (std140)" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(VsParams));
}

test "FsParams size is 32 bytes (std140)" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(FsParams));
}

test "GlyphKey hash: different raster modes produce different hashes" {
    const ctx = GlyphCacheContext{};
    const a = GlyphKey{ .glyph_index = 42, .face_index = 0, .raster_mode = .terminal };
    const b = GlyphKey{ .glyph_index = 42, .face_index = 0, .raster_mode = .ui };
    try std.testing.expect(ctx.hash(a) != ctx.hash(b));
}

test "GlyphKey eql: same fields are equal" {
    const ctx = GlyphCacheContext{};
    const a = GlyphKey{ .glyph_index = 1, .face_index = 2, .raster_mode = .terminal };
    const b = GlyphKey{ .glyph_index = 1, .face_index = 2, .raster_mode = .terminal };
    try std.testing.expect(ctx.eql(a, b));
}

test "ShapeKey eql: different text is not equal" {
    const ctx = ShapeCacheContext{};
    var a: ShapeKey = std.mem.zeroes(ShapeKey);
    a.len = 3;
    @memcpy(a.text[0..3], "abc");
    a.face_idx = 0;
    a.ligatures = true;
    var b: ShapeKey = std.mem.zeroes(ShapeKey);
    b.len = 3;
    @memcpy(b.text[0..3], "xyz");
    b.face_idx = 0;
    b.ligatures = true;
    try std.testing.expect(!ctx.eql(a, b));
}

test "PreparedKey eql: different raster mode is not equal" {
    const ctx = PreparedCacheContext{};
    var a: PreparedKey = std.mem.zeroes(PreparedKey);
    a.len = 1;
    a.text[0] = 'A';
    a.face_idx = 0;
    a.ligatures = false;
    a.raster_mode = .terminal;
    var b: PreparedKey = std.mem.zeroes(PreparedKey);
    b.len = 1;
    b.text[0] = 'A';
    b.face_idx = 0;
    b.ligatures = false;
    b.raster_mode = .ui;
    try std.testing.expect(!ctx.eql(a, b));
}
