/// FreeType + HarfBuzz glyph renderer.
///
/// Pipeline:
///   FT_Face  →  HarfBuzz shape  →  FT_Load_Glyph / FT_Render_Glyph
///   →  grey bitmap  →  sokol RGBA8 texture atlas  →  sokol_gl textured quads
///
/// One atlas texture (ATLAS_W × ATLAS_H, RGBA8) is shared for all
/// faces and sizes. Glyphs are packed left-to-right, row-by-row. The atlas is
/// never evicted — it is large enough for a full session at one font size.
///
/// The FreeType grey bitmap (FT_PIXEL_MODE_GRAY) produces coverage values 0–255.
/// We store coverage in all four RGBA channels so sokol_gl's built-in shader,
/// which multiplies vertex colour by sampled RGBA, produces the correct tinted
/// result: vertex_rgb × coverage, alpha = coverage.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("sokol_c");
const ft = @import("ft_c");
const fastmem = @import("../fastmem.zig");
const App = @import("../app.zig").App;
const box_draw = @import("box_draw.zig");
const CopyModeSnapshotLine = @import("../app.zig").CopyModeSnapshotLine;
const SearchHighlight = @import("../app.zig").SearchHighlight;
const Config = @import("../config.zig").Config;
const ghostty = @import("../term/ghostty.zig");
const Pane = @import("../pane.zig").Pane;
const selection = @import("../selection.zig");
const fonts = @import("fonts");
const glyph_shader = @import("shaders/glyph_shader.zig");

extern fn hollow_decode_png_bytes(
    data: [*]const u8,
    data_len: usize,
    out_width: *u32,
    out_height: *u32,
    out_pixels: *?[*]u8,
    out_len: *usize,
) callconv(.c) bool;

extern fn hollow_decode_png_bytes_free(pixels: ?[*]u8) callconv(.c) void;

const dwrite = if (builtin.os.tag == .windows) struct {
    const HollowDWriteFontMatch = extern struct {
        face_index: u32,
        path: [1024]u8,
    };

    const HollowDWriteFontFamilyCallback = *const fn (family_utf8: [*:0]const u8, ctx: ?*anyopaque) callconv(.c) c_int;
    const HollowDWriteFontFaceCallback = *const fn (family_utf8: [*:0]const u8, style_utf8: [*:0]const u8, ctx: ?*anyopaque) callconv(.c) c_int;

    extern fn hollow_dwrite_match_font(family_utf8: [*:0]const u8, want_bold: c_int, want_italic: c_int, out_match: *HollowDWriteFontMatch) c_int;
    extern fn hollow_dwrite_list_font_families(callback: HollowDWriteFontFamilyCallback, ctx: ?*anyopaque) c_int;
    extern fn hollow_dwrite_list_font_faces(callback: HollowDWriteFontFaceCallback, ctx: ?*anyopaque) c_int;
} else struct {};

// ── Atlas constants ───────────────────────────────────────────────────────────
const ATLAS_W: u32 = 2048;
const ATLAS_H: u32 = 2048;
const ATLAS_BPP: u32 = 4; // RGBA8

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
const GlyphVertex = extern struct {
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
const VsParams = extern struct {
    mvp: [16]f32 align(16), // column-major orthographic projection
    atlas_size: [2]f32 align(8), // ATLAS_W, ATLAS_H (for potential future use)
    vs_use_linear_correction: u32 align(4),
    _pad: u32 = 0,
};

// Fragment-shader uniform block (binding 1, std140).
const FsParams = extern struct {
    bg_linear: [4]f32 align(16), // linear-premultiplied background colour
    fs_use_linear_correction: u32 align(4),
    _pad0: u32 = 0,
    _pad1: u32 = 0,
    _pad2: u32 = 0,
};

// Maximum glyph quads we buffer per draw pass.
// At 300 cols × 100 rows that's 30 000 glyphs × 4 verts = 120 000 vertices.
// A typical 80×24 terminal is ~1 920 glyphs.  256k gives comfortable headroom.
const MAX_GLYPH_VERTS: usize = 256 * 1024;
const GLYPH_VBUF_RING_LEN: usize = 8;
const KITTY_TEXTURE_CACHE_LEN: usize = 64;

// ── Glyph cache entry ─────────────────────────────────────────────────────────
const Glyph = struct {
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

const CachedStyleInfo = struct {
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

const STYLE_CACHE_SIZE = 1024;

const RasterMode = enum {
    terminal,
    ui,
};

// Key: (glyph_index, face_index, raster mode)
const GlyphKey = struct {
    glyph_index: u32,
    face_index: u8,
    raster_mode: RasterMode,
};

// ── Shaping cache ─────────────────────────────────────────────────────────────
const ShapeKey = struct {
    text: [128]u8,
    len: u8,
    face_idx: u8,
    ligatures: bool,
};

const KittyTextureKey = struct {
    image_id: u32,
    width: u32,
    height: u32,
    format: ghostty.KittyImageFormat,
    data_len: usize,
    data_ptr: usize,
};

const KittyTexture = struct {
    key: KittyTextureKey,
    image: c.sg_image,
    view: c.sg_view,

    fn deinit(self: *KittyTexture) void {
        c.sg_destroy_view(self.view);
        c.sg_destroy_image(self.image);
    }
};

const GlyphCacheContext = struct {
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

const ShapeCacheContext = struct {
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

const GlyphInstance = struct {
    glyph_id: u32,
    x_advance: f32,
    x_offset: f32,
    y_offset: f32,
};

const PreparedGlyph = struct {
    inst: GlyphInstance,
    glyph: Glyph,
};

const ShapedRunEntry = struct {
    fingerprint: u64,
    key: ShapeKey,
    prepared_start: usize,
    prepared_len: usize,
};

const PreparedRun = struct {
    start: usize,
    glyphs: []PreparedGlyph,
};

const PreparedKey = struct {
    text: [128]u8,
    len: u8,
    face_idx: u8,
    ligatures: bool,
    raster_mode: RasterMode,
};

const PreparedCacheEntry = struct {
    glyphs: []PreparedGlyph,
};

const RecentPreparedEntry = struct {
    fingerprint: u64,
    key: PreparedKey,
    glyphs: []PreparedGlyph,
};

const RECENT_PREPARED_CACHE_LEN: usize = 128;

const PreparedCacheContext = struct {
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

// ── Per-pane render-to-texture cache ─────────────────────────────────────────
//
// Each pane gets one `PaneCache` that holds:
//   - An offscreen RGBA8 render-target image (same pixel size as the pane).
//   - Two views: one color-attachment view (used as the pass attachment) and
//     one texture view (used to sample the result in the blit pass).
//   - A dedicated sgl_context so that pane draw commands are isolated from the
//     main context (tab bar, borders, etc.).
//   - A context-specific atlas pipeline that matches the offscreen color format.
//
// Workflow per frame:
//   1. If dirty (or first frame / size changed): begin offscreen pass on this
//      pane's RT, set sgl context, call queueInViewport, sgl_context_draw,
//      end offscreen pass.
//   2. Regardless: in the main swapchain pass, blit the RT texture as a
//      textured quad at the pane's viewport position (one quad per pane).
//
// This means clean frames (no terminal changes, no cursor movement) skip all
// cell iteration entirely and just submit 2 triangles per pane.
pub const PaneCache = struct {
    rt_img: c.sg_image,
    rt_att_view: c.sg_view,
    rt_tex_view: c.sg_view,
    rt_smp: c.sg_sampler,
    sgl_ctx: c.sgl_context,
    atlas_pip: c.sgl_pipeline,
    blit_smp: c.sg_sampler, // nearest-neighbour sampler for blit
    width: u32,
    height: u32,

    /// Allocate GPU resources for a `w × h` pane render target.
    pub fn init(w: u32, h: u32) PaneCache {
        var img_desc = std.mem.zeroes(c.sg_image_desc);
        img_desc.width = @intCast(w);
        img_desc.height = @intCast(h);
        img_desc.pixel_format = c.SG_PIXELFORMAT_RGBA8;
        img_desc.usage.color_attachment = true;
        img_desc.label = "pane-rt";
        const rt_img = c.sg_make_image(&img_desc);

        var att_desc = std.mem.zeroes(c.sg_view_desc);
        att_desc.color_attachment.image = rt_img;
        const rt_att_view = c.sg_make_view(&att_desc);

        var tex_desc = std.mem.zeroes(c.sg_view_desc);
        tex_desc.texture.image = rt_img;
        const rt_tex_view = c.sg_make_view(&tex_desc);

        // Sampler for sampling the RT as a texture — kept for possible future
        // use (e.g. scaled HiDPI blit). Not used in the standard blit path.
        var smp_desc = std.mem.zeroes(c.sg_sampler_desc);
        smp_desc.min_filter = c.SG_FILTER_LINEAR;
        smp_desc.mag_filter = c.SG_FILTER_LINEAR;
        smp_desc.label = "pane-rt-smp";
        const rt_smp = c.sg_make_sampler(&smp_desc);

        // Nearest-neighbour sampler for the blit quad (pixel-exact 1:1 copy).
        // Pane RTs are sized in physical pixels and are always blitted at 1:1
        // to the swapchain, so NEAREST is always correct here.
        var blit_smp_desc = std.mem.zeroes(c.sg_sampler_desc);
        blit_smp_desc.min_filter = c.SG_FILTER_NEAREST;
        blit_smp_desc.mag_filter = c.SG_FILTER_NEAREST;
        blit_smp_desc.label = "pane-blit-smp";
        const blit_smp = c.sg_make_sampler(&blit_smp_desc);

        var ctx_desc = std.mem.zeroes(c.sgl_context_desc_t);
        ctx_desc.max_vertices = 1 << 18;
        ctx_desc.max_commands = 1 << 16;
        ctx_desc.color_format = c.SG_PIXELFORMAT_RGBA8;
        ctx_desc.depth_format = c.SG_PIXELFORMAT_NONE;
        ctx_desc.sample_count = 1;
        const sgl_ctx = c.sgl_make_context(&ctx_desc);

        c.sgl_set_context(sgl_ctx);
        var pip_desc = std.mem.zeroes(c.sg_pipeline_desc);
        pip_desc.colors[0].blend.enabled = true;
        pip_desc.colors[0].blend.src_factor_rgb = c.SG_BLENDFACTOR_ONE;
        pip_desc.colors[0].blend.dst_factor_rgb = c.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        pip_desc.colors[0].blend.src_factor_alpha = c.SG_BLENDFACTOR_ONE;
        pip_desc.colors[0].blend.dst_factor_alpha = c.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        const atlas_pip = c.sgl_context_make_pipeline(sgl_ctx, &pip_desc);
        c.sgl_set_context(c.sgl_default_context());

        return .{
            .rt_img = rt_img,
            .rt_att_view = rt_att_view,
            .rt_tex_view = rt_tex_view,
            .rt_smp = rt_smp,
            .blit_smp = blit_smp,
            .sgl_ctx = sgl_ctx,
            .atlas_pip = atlas_pip,
            .width = w,
            .height = h,
        };
    }

    pub fn clear(self: *PaneCache) void {
        var pass = std.mem.zeroes(c.sg_pass);
        pass.attachments.colors[0] = self.rt_att_view;
        pass.action.colors[0].load_action = c.SG_LOADACTION_CLEAR;
        pass.action.colors[0].clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };
        c.sg_begin_pass(&pass);
        c.sg_end_pass();
    }

    /// Destroy all GPU resources held by this cache.
    pub fn deinit(self: *PaneCache) void {
        c.sgl_destroy_pipeline(self.atlas_pip);
        c.sgl_destroy_context(self.sgl_ctx);
        c.sg_destroy_sampler(self.blit_smp);
        c.sg_destroy_sampler(self.rt_smp);
        c.sg_destroy_view(self.rt_tex_view);
        c.sg_destroy_view(self.rt_att_view);
        c.sg_destroy_image(self.rt_img);
    }

    /// Returns true if the cached RT is the wrong size and must be recreated.
    pub fn needsResize(self: *const PaneCache, w: u32, h: u32) bool {
        return self.width != w or self.height != h;
    }
};

const ShapeResult = struct {
    glyphs: []const GlyphInstance,
    raster_face_index: u8,
};

pub const FtRendererConfig = struct {
    pub const Smoothing = enum {
        grayscale,
        subpixel,
    };

    pub const Hinting = enum {
        none,
        light,
        normal,
    };

    font_size: f32 = 18.0,
    dpi_scale: f32 = 1.0,
    line_height: f32 = 1.0,
    padding_x: f32 = 0.0,
    padding_y: f32 = 0.0,
    coverage_boost: f32 = 1.0,
    coverage_add: f32 = 0.0,
    smoothing: Smoothing = .grayscale,
    hinting: Hinting = .normal,
    ligatures: bool = true,
    embolden: f32 = 0.0,
    regular_embolden: ?f32 = null,
    bold_embolden: ?f32 = null,
    italic_embolden: ?f32 = null,
    bold_italic_embolden: ?f32 = null,
    /// Enable perceptual luminance-based alpha correction (Ghostty-style).
    /// Produces gamma-correct text blending without requiring an sRGB framebuffer.
    /// Disabled by default — simple fg*coverage matches WezTerm on dark backgrounds.
    use_linear_correction: bool = false,
    family: ?[]const u8 = null,
    regular_path: ?[]const u8 = null,
    bold_path: ?[]const u8 = null,
    italic_path: ?[]const u8 = null,
    bold_italic_path: ?[]const u8 = null,
    fallback_paths: []const []const u8 = &.{},
};

const RequestedFontStyle = enum {
    regular,
    bold,
    italic,
    bold_italic,
};

const FontDiscoveryMatch = struct {
    path: []u8,
    face_index: c_long,
    score: i32,
};

pub const FontFaceInfo = struct {
    style: []u8,
};

pub const FontFamilyInfo = struct {
    family: []u8,
    styles: []FontFaceInfo,

    pub fn deinit(self: *FontFamilyInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.family);
        for (self.styles) |style| allocator.free(style.style);
        allocator.free(self.styles);
        self.* = undefined;
    }
};

const SeenFontFamilies = struct {
    allocator: std.mem.Allocator,
    names: std.ArrayListUnmanaged([]u8) = .empty,
    normalized: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(self: *SeenFontFamilies) void {
        for (self.names.items) |name| self.allocator.free(name);
        self.names.deinit(self.allocator);
        var it = self.normalized.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.normalized.deinit(self.allocator);
    }

    fn add(self: *SeenFontFamilies, name: []const u8) !void {
        if (name.len == 0) return;

        var normalized_buf: [256]u8 = undefined;
        const normalized_name = normalizeFontToken(&normalized_buf, name);
        if (normalized_name.len == 0) return;
        if (self.normalized.contains(normalized_name)) return;

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_key = try self.allocator.dupe(u8, normalized_name);
        errdefer self.allocator.free(owned_key);

        try self.names.append(self.allocator, owned_name);
        errdefer _ = self.names.pop();
        try self.normalized.put(self.allocator, owned_key, {});
    }
};

const SeenFontFamilyDetails = struct {
    allocator: std.mem.Allocator,
    families: std.ArrayListUnmanaged(FontFamilyInfoBuilder) = .empty,
    normalized_map: std.StringHashMapUnmanaged(usize) = .empty,

    fn deinit(self: *SeenFontFamilyDetails) void {
        for (self.families.items) |*family| family.deinit(self.allocator);
        self.families.deinit(self.allocator);
        var it = self.normalized_map.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.normalized_map.deinit(self.allocator);
    }

    fn add(self: *SeenFontFamilyDetails, family_name: []const u8, style_name: []const u8) !void {
        if (family_name.len == 0) return;

        var normalized_buf: [256]u8 = undefined;
        const normalized = normalizeFontToken(&normalized_buf, family_name);
        if (normalized.len == 0) return;

        if (self.normalized_map.get(normalized)) |index| {
            try self.families.items[index].addStyle(self.allocator, style_name);
            return;
        }
    }

    fn toOwnedSlice(self: *SeenFontFamilyDetails, allocator: std.mem.Allocator) ![]FontFamilyInfo {
        std.mem.sort(FontFamilyInfoBuilder, self.families.items, {}, struct {
            fn lessThan(_: void, a: FontFamilyInfoBuilder, b: FontFamilyInfoBuilder) bool {
                return std.ascii.lessThanIgnoreCase(a.family, b.family);
            }
        }.lessThan);

        const result = try allocator.alloc(FontFamilyInfo, self.families.items.len);
        for (self.families.items, 0..) |*family, i| result[i] = try family.toOwnedInfo(allocator);
        return result;
    }
};

const FontFamilyInfoBuilder = struct {
    family: []u8,
    styles: std.ArrayListUnmanaged([]u8) = .empty,
    normalized_styles: std.StringHashMapUnmanaged(void) = .empty,

    fn init(allocator: std.mem.Allocator, family_name: []const u8, style_name: []const u8) !FontFamilyInfoBuilder {
        var builder = FontFamilyInfoBuilder{ .family = try allocator.dupe(u8, family_name) };
        errdefer allocator.free(builder.family);
        try builder.addStyle(allocator, style_name);
        return builder;
    }

    fn deinit(self: *FontFamilyInfoBuilder, allocator: std.mem.Allocator) void {
        allocator.free(self.family);
        for (self.styles.items) |style| allocator.free(style);
        self.styles.deinit(allocator);
        var it = self.normalized_styles.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.normalized_styles.deinit(allocator);
    }

    fn addStyle(self: *FontFamilyInfoBuilder, allocator: std.mem.Allocator, style_name: []const u8) !void {
        const style = if (style_name.len == 0) "Regular" else style_name;

        var normalized_buf: [256]u8 = undefined;
        const normalized = normalizeFontToken(&normalized_buf, style);
        if (normalized.len == 0) return;
        if (self.normalized_styles.contains(normalized)) return;

        const owned_style = try allocator.dupe(u8, style);
        errdefer allocator.free(owned_style);
        const owned_key = try allocator.dupe(u8, normalized);
        errdefer allocator.free(owned_key);

        try self.styles.append(allocator, owned_style);
        errdefer _ = self.styles.pop();
        try self.normalized_styles.put(allocator, owned_key, {});
    }

    fn toOwnedInfo(self: *FontFamilyInfoBuilder, allocator: std.mem.Allocator) !FontFamilyInfo {
        std.mem.sort([]u8, self.styles.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.ascii.lessThanIgnoreCase(a, b);
            }
        }.lessThan);

        const family = try allocator.dupe(u8, self.family);
        errdefer allocator.free(family);
        const styles = try allocator.alloc(FontFaceInfo, self.styles.items.len);
        errdefer allocator.free(styles);
        for (self.styles.items, 0..) |style, i| {
            styles[i] = .{ .style = try allocator.dupe(u8, style) };
        }
        return .{ .family = family, .styles = styles };
    }
};

pub const FtRenderer = struct {
    allocator: std.mem.Allocator,

    // FreeType state
    ft_lib: ft.FT_Library,
    face_regular: ft.FT_Face,
    face_bold: ft.FT_Face,
    face_italic: ft.FT_Face,
    face_bold_italic: ft.FT_Face,
    face_nerd: ft.FT_Face,
    face_symbols_nerd: ft.FT_Face,
    face_symbols: ft.FT_Face,
    face_cjk: ft.FT_Face,
    face_emoji: ft.FT_Face,
    fallback_faces: []ft.FT_Face,

    // HarfBuzz fonts (one per face)
    hb_regular: ?*ft.hb_font_t,
    hb_bold: ?*ft.hb_font_t,
    hb_italic: ?*ft.hb_font_t,
    hb_bold_italic: ?*ft.hb_font_t,
    hb_nerd: ?*ft.hb_font_t,
    hb_symbols_nerd: ?*ft.hb_font_t,
    hb_symbols: ?*ft.hb_font_t,
    hb_cjk: ?*ft.hb_font_t,
    hb_emoji: ?*ft.hb_font_t,
    emoji_face_index: u8,
    fallback_hb_fonts: []?*ft.hb_font_t,

    // HarfBuzz buffer (reused each cell)
    hb_buf: ?*ft.hb_buffer_t,

    // Atlas texture (sokol, RGBA8)
    atlas_img: c.sg_image,
    atlas_view: c.sg_view,
    atlas_smp: c.sg_sampler,
    atlas_ui_smp: c.sg_sampler,
    kitty_image_smp: c.sg_sampler,
    atlas_pip: c.sgl_pipeline,
    atlas_data: []u8, // CPU-side atlas, ATLAS_W * ATLAS_H * 4 bytes

    // Custom glyph pipeline (raw sg_pipeline, gamma-correct shader).
    glyph_shd: c.sg_shader,
    glyph_pip: c.sg_pipeline, // swapchain color format
    glyph_pip_offscreen: c.sg_pipeline, // RGBA8 offscreen format

    swapchain_color_format: c.sg_pixel_format,
    // Stream vertex buffer for glyph quads.
    // Uploaded once per pass from glyph_verts_cpu.
    glyph_vbufs: [GLYPH_VBUF_RING_LEN]c.sg_buffer,
    glyph_vbuf_index: usize,
    uploaded_glyph_vbuf: c.sg_buffer,
    uploaded_glyph_verts: usize,
    // Stream index buffer: pre-built quad indices (0,1,2, 0,2,3, 6,7,8, ...).
    glyph_ibuf: c.sg_buffer,
    // CPU-side glyph vertex staging array.
    glyph_verts_cpu: []GlyphVertex,
    glyph_verts_count: usize,
    // Linear correction feature flag (true = on by default).
    use_linear_correction: bool,

    // Atlas packing state
    atlas_x: u32,
    atlas_y: u32,
    atlas_row_h: u32,
    atlas_dirty: bool,
    /// Guards against calling sg_update_image more than once per frame.
    /// Reset by beginFrame(); set true by the first flushAtlas() each frame.
    atlas_uploaded_this_frame: bool,
    /// Monotonically increasing counter: incremented each time the atlas is
    /// uploaded to the GPU.  Callers can compare a saved epoch against this
    /// value to know whether the atlas changed since their last render — if
    /// their saved epoch < atlas_epoch the pane must do a full redraw so the
    /// new glyph bitmaps are visible.  Never reset to zero (only wraps at u64 max).
    atlas_epoch: u64,

    // Glyph cache
    glyph_cache: std.HashMap(GlyphKey, Glyph, GlyphCacheContext, std.hash_map.default_max_load_percentage),

    // Shaping cache
    shape_cache: std.HashMap(ShapeKey, ShapeResult, ShapeCacheContext, std.hash_map.default_max_load_percentage),

    // Prepared run cache
    prepared_cache: std.HashMap(PreparedKey, PreparedCacheEntry, PreparedCacheContext, std.hash_map.default_max_load_percentage),
    recent_prepared: [RECENT_PREPARED_CACHE_LEN]?RecentPreparedEntry = [_]?RecentPreparedEntry{null} ** RECENT_PREPARED_CACHE_LEN,
    kitty_textures: [KITTY_TEXTURE_CACHE_LEN]?KittyTexture = [_]?KittyTexture{null} ** KITTY_TEXTURE_CACHE_LEN,

    // Metrics (all in physical pixels)
    cell_w: f32,
    cell_h: f32,
    ascender: f32,
    font_size_px: f32, // physical pixels = font_size * dpi_scale
    dpi_scale: f32,
    padding_x: f32,
    padding_y: f32,
    coverage_boost: f32,
    coverage_add: f32,
    smoothing: FtRendererConfig.Smoothing,
    hinting: FtRendererConfig.Hinting,
    ligatures: bool,
    embolden: f32,
    regular_embolden: ?f32,
    bold_embolden: ?f32,
    italic_embolden: ?f32,
    bold_italic_embolden: ?f32,

    glyph_buf: [32]u8 = [_]u8{0} ** 32,
    logged_first_draw: bool = false,
    logged_first_content: bool = false,

    /// Fast ASCII/Latin-1 glyph cache: ascii_glyphs[face_idx][codepoint]
    /// Stores the final Glyph (atlas UVs + bearing) for printable ASCII U+0021–U+007E
    /// and Latin-1 supplement U+00A0–U+00FF on faces 0-3, bypassing both HarfBuzz
    /// shaping and the glyph_cache hashmap on warm frames.
    /// null = not yet populated.  Atlas UVs are stable once placed, so entries
    /// never need invalidation (except on atlas eviction via resetAtlasIfNeeded).
    ascii_glyphs: [4][256]?Glyph = [_][256]?Glyph{[_]?Glyph{null} ** 256} ** 4,

    /// Reusable ligature run buffer — avoids a heap alloc+free every frame.
    /// Grown on demand via realloc; never shrunk.
    run_buf: []u8 = &.{},
    /// Grid dimensions for which run_buf was last sized.
    /// When rows/cols are unchanged we skip the recompute entirely.
    run_buf_rows: usize = 0,
    run_buf_cols: usize = 0,
    /// Reused prepared glyph pool for pass1/pass2 shaped-run replay.
    prepared_glyphs: std.ArrayListUnmanaged(PreparedGlyph) = .empty,
    shaped_runs: std.ArrayListUnmanaged(ShapedRunEntry) = .empty,
    shaped_run_read_idx: usize = 0,
    style_cache: [STYLE_CACHE_SIZE]?CachedStyleInfo = [_]?CachedStyleInfo{null} ** STYLE_CACHE_SIZE,
    render_colors_scratch: ghostty.RenderStateColors = undefined,
    offscreen_pass_scratch: c.sg_pass = std.mem.zeroes(c.sg_pass),

    /// Diagnostic counters — set by the last renderToCache call, readable by caller.
    last_rows_rendered: usize = 0,
    last_rows_skipped: usize = 0,
    /// Sub-timing within renderToCache (nanoseconds).
    last_queue_ns: i128 = 0,
    last_gpu_ns: i128 = 0,
    /// Sub-timing within queueInViewport: pass1 (bg), pass2 (glyphs).
    last_pass1_ns: i128 = 0,
    last_pass2_ns: i128 = 0,
    last_pass2_glyph_ns: i128 = 0,
    last_pass2_decoration_ns: i128 = 0,
    /// Per-call cell/glyph/bg-rect diagnostic counters (set by queueInViewport).
    last_cells_visited: usize = 0,
    last_glyph_runs: usize = 0,
    last_bg_rects: usize = 0,
    /// Set to true when an atlas upload happened during this renderToCache call.
    last_atlas_flushed: bool = false,
    /// Incremented every renderToCache call.  Used to trigger periodic atlas
    /// eviction when the atlas becomes ≥90% full (see resetAtlasIfNeeded).
    frame_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, cfg: FtRendererConfig) !FtRenderer {
        const font_size_px = cfg.font_size * cfg.dpi_scale;

        // ── FreeType init ──────────────────────────────────────────────────
        var ft_lib: ft.FT_Library = null;
        if (ft.FT_Init_FreeType(&ft_lib) != 0) return error.FtInitFailed;
        errdefer _ = ft.FT_Done_FreeType(ft_lib);
        if (cfg.smoothing == .subpixel) {
            _ = ft.FT_Library_SetLcdFilter(ft_lib, ft.FT_LCD_FILTER_LIGHT);
        }

        const face_regular = try loadConfiguredFace(allocator, ft_lib, cfg.family, cfg.regular_path, .regular, fonts.regular, font_size_px);
        errdefer _ = ft.FT_Done_Face(face_regular);
        const face_bold = try loadConfiguredFace(allocator, ft_lib, cfg.family, cfg.bold_path, .bold, fonts.bold, font_size_px);
        errdefer _ = ft.FT_Done_Face(face_bold);
        const face_italic = try loadConfiguredFace(allocator, ft_lib, cfg.family, cfg.italic_path, .italic, fonts.italic, font_size_px);
        errdefer _ = ft.FT_Done_Face(face_italic);
        const face_bold_italic = try loadConfiguredFace(allocator, ft_lib, cfg.family, cfg.bold_italic_path, .bold_italic, fonts.bold_italic, font_size_px);
        errdefer _ = ft.FT_Done_Face(face_bold_italic);
        const face_nerd = try loadFace(ft_lib, fonts.nerd, font_size_px);
        errdefer _ = ft.FT_Done_Face(face_nerd);
        const face_symbols_nerd = try loadFace(ft_lib, fonts.symbols_nerd, font_size_px);
        errdefer _ = ft.FT_Done_Face(face_symbols_nerd);
        const face_symbols = try loadFace(ft_lib, fonts.symbols, font_size_px);
        errdefer _ = ft.FT_Done_Face(face_symbols);
        const face_cjk = try loadFace(ft_lib, fonts.cjk, font_size_px);
        errdefer _ = ft.FT_Done_Face(face_cjk);

        const face_emoji = discoverEmojiFont(allocator, ft_lib, font_size_px) orelse null;
        errdefer {
            if (face_emoji) |f| _ = ft.FT_Done_Face(f);
        }

        const fallback_faces = try allocator.alloc(ft.FT_Face, cfg.fallback_paths.len);
        errdefer allocator.free(fallback_faces);
        var loaded_fallback_faces: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < loaded_fallback_faces) : (i += 1) _ = ft.FT_Done_Face(fallback_faces[i]);
        }
        for (cfg.fallback_paths, 0..) |path, i| {
            fallback_faces[i] = try loadFaceFromSpec(allocator, ft_lib, path, .regular, font_size_px);
            loaded_fallback_faces += 1;
        }

        // ── HarfBuzz fonts ─────────────────────────────────────────────────
        const hb_regular = ft.hb_ft_font_create_referenced(face_regular);
        const hb_bold = ft.hb_ft_font_create_referenced(face_bold);
        const hb_italic = ft.hb_ft_font_create_referenced(face_italic);
        const hb_bold_italic = ft.hb_ft_font_create_referenced(face_bold_italic);
        const hb_nerd = ft.hb_ft_font_create_referenced(face_nerd);
        const hb_symbols_nerd = ft.hb_ft_font_create_referenced(face_symbols_nerd);
        const hb_symbols = ft.hb_ft_font_create_referenced(face_symbols);
        const hb_cjk = ft.hb_ft_font_create_referenced(face_cjk);
        const hb_emoji = if (face_emoji) |f| ft.hb_ft_font_create_referenced(f) else null;
        const fallback_hb_fonts = try allocator.alloc(?*ft.hb_font_t, fallback_faces.len);
        errdefer allocator.free(fallback_hb_fonts);
        var loaded_fallback_hb: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < loaded_fallback_hb) : (i += 1) {
                if (fallback_hb_fonts[i]) |font| ft.hb_font_destroy(font);
            }
        }
        for (fallback_faces, 0..) |face, i| {
            fallback_hb_fonts[i] = ft.hb_ft_font_create_referenced(face);
            loaded_fallback_hb += 1;
        }
        const hb_buf = ft.hb_buffer_create();

        // ── Cell metrics (from regular face) ──────────────────────────────
        const metrics = &face_regular.*.size.*.metrics;
        // FreeType metrics are in 26.6 fixed-point.
        const ascender = @as(f32, @floatFromInt(metrics.ascender)) / 64.0;
        const descender = @as(f32, @floatFromInt(metrics.descender)) / 64.0;
        const base_cell_h = ascender - descender; // positive height
        const line_height = if (std.math.isFinite(cfg.line_height) and cfg.line_height > 0.0) cfg.line_height else 1.0;
        const cell_h = @ceil(base_cell_h * line_height);
        const baseline_ascender = ascender + (cell_h - base_cell_h) * 0.5;
        // Advance of 'M' for cell width.
        // Using ceil here tends to overestimate the cell for fonts with
        // fractional advances, which shows up as extra horizontal breathing room
        // across the entire terminal (very noticeable in editors like nvim).
        // Round to the nearest pixel instead so the reported grid width tracks
        // the actual font metrics more closely without biasing wide.
        var raw_cell_w: f32 = font_size_px * 0.6; // fallback
        if (ft.FT_Load_Char(face_regular, 'M', ft.FT_LOAD_NO_BITMAP) == 0) {
            raw_cell_w = @as(f32, @floatFromInt(face_regular.*.glyph.*.advance.x)) / 64.0;
        }
        const cell_w = @max(@as(f32, 1.0), @round(raw_cell_w));

        std.log.info("ft_renderer: font_size={d:.1} dpi={d:.2} line_height={d:.2} cell={d:.1}x{d:.1} asc={d:.1}", .{
            cfg.font_size, cfg.dpi_scale, line_height, cell_w, cell_h, baseline_ascender,
        });

        // ── Atlas texture ──────────────────────────────────────────────────
        const atlas_data = try allocator.alloc(u8, ATLAS_W * ATLAS_H * ATLAS_BPP);
        @memset(atlas_data, 0);

        var img_desc = std.mem.zeroes(c.sg_image_desc);
        img_desc.width = @intCast(ATLAS_W);
        img_desc.height = @intCast(ATLAS_H);
        img_desc.pixel_format = c.SG_PIXELFORMAT_RGBA8;
        img_desc.usage.dynamic_update = true;
        img_desc.label = "ft-atlas";
        const atlas_img = c.sg_make_image(&img_desc);

        var smp_desc = std.mem.zeroes(c.sg_sampler_desc);
        smp_desc.min_filter = c.SG_FILTER_NEAREST;
        smp_desc.mag_filter = c.SG_FILTER_NEAREST;
        smp_desc.label = "ft-atlas-sampler";
        const atlas_smp = c.sg_make_sampler(&smp_desc);

        var ui_smp_desc = std.mem.zeroes(c.sg_sampler_desc);
        ui_smp_desc.min_filter = c.SG_FILTER_NEAREST;
        ui_smp_desc.mag_filter = c.SG_FILTER_NEAREST;
        ui_smp_desc.label = "ft-atlas-ui-sampler";
        const atlas_ui_smp = c.sg_make_sampler(&ui_smp_desc);

        var kitty_smp_desc = std.mem.zeroes(c.sg_sampler_desc);
        kitty_smp_desc.min_filter = c.SG_FILTER_LINEAR;
        kitty_smp_desc.mag_filter = c.SG_FILTER_LINEAR;
        kitty_smp_desc.label = "kitty-image-sampler";
        const kitty_image_smp = c.sg_make_sampler(&kitty_smp_desc);

        // Create a view over the atlas image (required by sgl_texture in this sokol version).
        var view_desc = std.mem.zeroes(c.sg_view_desc);
        view_desc.texture.image = atlas_img;
        const atlas_view = c.sg_make_view(&view_desc);

        // Pipeline: alpha-blend using the coverage stored in the alpha channel.
        // sokol_gl's built-in shader multiplies vertex colour by sampled RGBA.
        // We store grey coverage in all 4 channels, so:
        //   out_rgb  = vertex_rgb * sampled_r   (= vertex_rgb * coverage)
        //   out_alpha = sampled_a               (= coverage)
        var pip_desc = std.mem.zeroes(c.sg_pipeline_desc);
        pip_desc.colors[0].blend.enabled = true;
        pip_desc.colors[0].blend.src_factor_rgb = c.SG_BLENDFACTOR_ONE;
        pip_desc.colors[0].blend.dst_factor_rgb = c.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        pip_desc.colors[0].blend.src_factor_alpha = c.SG_BLENDFACTOR_ONE;
        pip_desc.colors[0].blend.dst_factor_alpha = c.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        const atlas_pip = c.sgl_make_pipeline(&pip_desc);

        // ── Custom glyph shader pipeline ──────────────────────────────────
        // Uses a gamma-correct (perceptual luminance) fragment shader.
        // Vertex layout: f32x2 pos, f32x2 uv, u8x4 fg_rgba (stride=20).
        const shader_src = comptime glyph_shader.backendSources(glyph_shader.native_backend);

        var shd_desc = std.mem.zeroes(c.sg_shader_desc);
        shd_desc.vertex_func.source = shader_src.vs.ptr;
        shd_desc.fragment_func.source = shader_src.fs.ptr;

        // HLSL D3D11: semantic names for vertex attributes.
        // GLSL: location indices match layout(location=N) in the shader.
        shd_desc.attrs[0].glsl_name = "in_pos";
        shd_desc.attrs[0].hlsl_sem_name = "TEXCOORD";
        shd_desc.attrs[0].hlsl_sem_index = 0;
        shd_desc.attrs[0].base_type = c.SG_SHADERATTRBASETYPE_FLOAT;
        shd_desc.attrs[1].glsl_name = "in_uv";
        shd_desc.attrs[1].hlsl_sem_name = "TEXCOORD";
        shd_desc.attrs[1].hlsl_sem_index = 1;
        shd_desc.attrs[1].base_type = c.SG_SHADERATTRBASETYPE_FLOAT;
        shd_desc.attrs[2].glsl_name = "in_fg_rgba";
        shd_desc.attrs[2].hlsl_sem_name = "TEXCOORD";
        shd_desc.attrs[2].hlsl_sem_index = 2;
        shd_desc.attrs[2].base_type = c.SG_SHADERATTRBASETYPE_FLOAT;

        // Vertex-shader uniform block (binding 0): mvp + atlas_size + flag.
        shd_desc.uniform_blocks[0].stage = c.SG_SHADERSTAGE_VERTEX;
        shd_desc.uniform_blocks[0].size = @sizeOf(VsParams);
        shd_desc.uniform_blocks[0].layout = c.SG_UNIFORMLAYOUT_STD140;
        shd_desc.uniform_blocks[0].hlsl_register_b_n = 0;
        shd_desc.uniform_blocks[0].glsl_uniforms[0].type = c.SG_UNIFORMTYPE_FLOAT4;
        shd_desc.uniform_blocks[0].glsl_uniforms[0].array_count = 5;
        shd_desc.uniform_blocks[0].glsl_uniforms[0].glsl_name = "vs_params";

        // Fragment-shader uniform block (binding 1): bg colour + flag.
        shd_desc.uniform_blocks[1].stage = c.SG_SHADERSTAGE_FRAGMENT;
        shd_desc.uniform_blocks[1].size = @sizeOf(FsParams);
        shd_desc.uniform_blocks[1].layout = c.SG_UNIFORMLAYOUT_STD140;
        shd_desc.uniform_blocks[1].hlsl_register_b_n = 1;
        shd_desc.uniform_blocks[1].glsl_uniforms[0].type = c.SG_UNIFORMTYPE_FLOAT4;
        shd_desc.uniform_blocks[1].glsl_uniforms[0].array_count = 2;
        shd_desc.uniform_blocks[1].glsl_uniforms[0].glsl_name = "fs_params";

        // Atlas texture (view slot 0, fragment stage).
        shd_desc.views[0].texture.stage = c.SG_SHADERSTAGE_FRAGMENT;
        shd_desc.views[0].texture.image_type = c.SG_IMAGETYPE_2D;
        shd_desc.views[0].texture.sample_type = c.SG_IMAGESAMPLETYPE_FLOAT;
        shd_desc.views[0].texture.hlsl_register_t_n = 0;

        // Sampler (slot 0, fragment stage).
        shd_desc.samplers[0].stage = c.SG_SHADERSTAGE_FRAGMENT;
        shd_desc.samplers[0].sampler_type = c.SG_SAMPLERTYPE_NONFILTERING;
        shd_desc.samplers[0].hlsl_register_s_n = 0;

        // Texture-sampler pair (tells sokol the GLSL sampler name).
        shd_desc.texture_sampler_pairs[0].stage = c.SG_SHADERSTAGE_FRAGMENT;
        shd_desc.texture_sampler_pairs[0].view_slot = 0;
        shd_desc.texture_sampler_pairs[0].sampler_slot = 0;
        shd_desc.texture_sampler_pairs[0].glsl_name = "atlas";

        shd_desc.label = "glyph-shader";
        const glyph_shd = c.sg_make_shader(&shd_desc);
        {
            const shd_state = c.sg_query_shader_state(glyph_shd);
            if (shd_state != c.SG_RESOURCESTATE_VALID) {
                std.log.err("ft_renderer: glyph shader creation FAILED (state={d}) — check HLSL/GLSL syntax and uniform block layout", .{shd_state});
            } else {
                std.log.info("ft_renderer: glyph shader OK (state={d})", .{shd_state});
            }
        }

        const swapchain = c.sglue_swapchain();
        const swapchain_color_format = if (swapchain.color_format != c.SG_PIXELFORMAT_NONE) swapchain.color_format else c.sglue_environment().defaults.color_format;

        // Glyph render pipeline — swapchain pass.
        var gpip_desc = std.mem.zeroes(c.sg_pipeline_desc);
        gpip_desc.shader = glyph_shd;
        // Vertex layout: stride 20 bytes.
        gpip_desc.layout.buffers[0].stride = @sizeOf(GlyphVertex);
        gpip_desc.layout.attrs[0].format = c.SG_VERTEXFORMAT_FLOAT2; // pos
        gpip_desc.layout.attrs[1].format = c.SG_VERTEXFORMAT_FLOAT2; // uv
        gpip_desc.layout.attrs[1].offset = 8;
        gpip_desc.layout.attrs[2].format = c.SG_VERTEXFORMAT_UBYTE4N; // fg_rgba (normalised)
        gpip_desc.layout.attrs[2].offset = 16;
        gpip_desc.primitive_type = c.SG_PRIMITIVETYPE_TRIANGLES;
        gpip_desc.index_type = c.SG_INDEXTYPE_UINT32;
        gpip_desc.colors[0].blend.enabled = true;
        gpip_desc.colors[0].blend.src_factor_rgb = c.SG_BLENDFACTOR_ONE;
        gpip_desc.colors[0].blend.dst_factor_rgb = c.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        gpip_desc.colors[0].blend.src_factor_alpha = c.SG_BLENDFACTOR_ONE;
        gpip_desc.colors[0].blend.dst_factor_alpha = c.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        gpip_desc.colors[0].pixel_format = swapchain_color_format;
        gpip_desc.depth.pixel_format = c.SG_PIXELFORMAT_NONE;
        gpip_desc.label = "glyph-pipeline";
        const glyph_pip = c.sg_make_pipeline(&gpip_desc);
        {
            const pip_state = c.sg_query_pipeline_state(glyph_pip);
            if (pip_state != c.SG_RESOURCESTATE_VALID) {
                std.log.err("ft_renderer: glyph_pip (swapchain) creation FAILED (state={d})", .{pip_state});
            } else {
                std.log.info("ft_renderer: glyph_pip (swapchain) OK", .{});
            }
        }

        // Offscreen variant: same as above but with explicit RGBA8 color format
        // to match the per-pane RT (prevents sokol validation error when the
        // swapchain uses a different pixel format, e.g. BGRA8 on D3D11).
        gpip_desc.colors[0].pixel_format = c.SG_PIXELFORMAT_RGBA8;
        gpip_desc.label = "glyph-pipeline-offscreen";
        const glyph_pip_offscreen = c.sg_make_pipeline(&gpip_desc);
        {
            const pip_state = c.sg_query_pipeline_state(glyph_pip_offscreen);
            if (pip_state != c.SG_RESOURCESTATE_VALID) {
                std.log.err("ft_renderer: glyph_pip_offscreen creation FAILED (state={d})", .{pip_state});
            } else {
                std.log.info("ft_renderer: glyph_pip_offscreen OK", .{});
            }
        }

        // Stream vertex buffer (capacity MAX_GLYPH_VERTS vertices).
        var vbuf_desc = std.mem.zeroes(c.sg_buffer_desc);
        vbuf_desc.size = MAX_GLYPH_VERTS * @sizeOf(GlyphVertex);
        vbuf_desc.usage.vertex_buffer = true;
        vbuf_desc.usage.stream_update = true;
        vbuf_desc.label = "glyph-verts";
        var glyph_vbufs: [GLYPH_VBUF_RING_LEN]c.sg_buffer = undefined;
        for (0..GLYPH_VBUF_RING_LEN) |i| {
            vbuf_desc.label = switch (i) {
                0 => "glyph-verts-0",
                1 => "glyph-verts-1",
                2 => "glyph-verts-2",
                3 => "glyph-verts-3",
                4 => "glyph-verts-4",
                5 => "glyph-verts-5",
                6 => "glyph-verts-6",
                else => "glyph-verts-7",
            };
            glyph_vbufs[i] = c.sg_make_buffer(&vbuf_desc);
        }

        // Static index buffer: 6 indices per quad (0,1,2, 0,2,3), pre-built
        // for the maximum number of quads we ever draw in one call.
        const max_quads = MAX_GLYPH_VERTS / 4;
        const ibuf_data = try allocator.alloc(u32, max_quads * 6);
        defer allocator.free(ibuf_data);
        {
            var qi: usize = 0;
            while (qi < max_quads) : (qi += 1) {
                const base: u32 = @intCast(qi * 4);
                ibuf_data[qi * 6 + 0] = base + 0;
                ibuf_data[qi * 6 + 1] = base + 1;
                ibuf_data[qi * 6 + 2] = base + 2;
                ibuf_data[qi * 6 + 3] = base + 0;
                ibuf_data[qi * 6 + 4] = base + 2;
                ibuf_data[qi * 6 + 5] = base + 3;
            }
        }
        var ibuf_desc = std.mem.zeroes(c.sg_buffer_desc);
        ibuf_desc.data.ptr = ibuf_data.ptr;
        ibuf_desc.data.size = ibuf_data.len * @sizeOf(u32);
        ibuf_desc.usage.index_buffer = true;
        ibuf_desc.label = "glyph-indices";
        const glyph_ibuf = c.sg_make_buffer(&ibuf_desc);

        // CPU vertex staging array.
        const glyph_verts_cpu = try allocator.alloc(GlyphVertex, MAX_GLYPH_VERTS);
        errdefer allocator.free(glyph_verts_cpu);

        // Emoji face index: after all bundled fonts.
        const emoji_face_index: u8 = @intCast(4 + fallback_faces.len + 4);

        return .{
            .allocator = allocator,
            .ft_lib = ft_lib,
            .face_regular = face_regular,
            .face_bold = face_bold,
            .face_italic = face_italic,
            .face_bold_italic = face_bold_italic,
            .face_nerd = face_nerd,
            .face_symbols_nerd = face_symbols_nerd,
            .face_symbols = face_symbols,
            .face_cjk = face_cjk,
            .face_emoji = face_emoji,
            .fallback_faces = fallback_faces,
            .hb_regular = hb_regular,
            .hb_bold = hb_bold,
            .hb_italic = hb_italic,
            .hb_bold_italic = hb_bold_italic,
            .hb_nerd = hb_nerd,
            .hb_symbols_nerd = hb_symbols_nerd,
            .hb_symbols = hb_symbols,
            .hb_cjk = hb_cjk,
            .hb_emoji = hb_emoji,
            .emoji_face_index = emoji_face_index,
            .fallback_hb_fonts = fallback_hb_fonts,
            .hb_buf = hb_buf,
            .atlas_img = atlas_img,
            .atlas_view = atlas_view,
            .atlas_smp = atlas_smp,
            .atlas_ui_smp = atlas_ui_smp,
            .kitty_image_smp = kitty_image_smp,
            .atlas_pip = atlas_pip,
            .atlas_data = atlas_data,
            .atlas_x = 1, // leave 1px gutter
            .atlas_y = 1,
            .atlas_row_h = 0,
            .atlas_dirty = false,
            .atlas_uploaded_this_frame = false,
            .atlas_epoch = 0,
            .glyph_cache = std.HashMap(GlyphKey, Glyph, GlyphCacheContext, std.hash_map.default_max_load_percentage).initContext(allocator, .{}),
            .shape_cache = std.HashMap(ShapeKey, ShapeResult, ShapeCacheContext, std.hash_map.default_max_load_percentage).initContext(allocator, .{}),
            .prepared_cache = std.HashMap(PreparedKey, PreparedCacheEntry, PreparedCacheContext, std.hash_map.default_max_load_percentage).initContext(allocator, .{}),
            .cell_w = cell_w,
            .cell_h = cell_h,
            .ascender = baseline_ascender,
            .font_size_px = font_size_px,
            .dpi_scale = cfg.dpi_scale,
            .padding_x = cfg.padding_x * cfg.dpi_scale,
            .padding_y = cfg.padding_y * cfg.dpi_scale,
            .coverage_boost = cfg.coverage_boost,
            .coverage_add = cfg.coverage_add,
            .smoothing = cfg.smoothing,
            .hinting = cfg.hinting,
            .ligatures = cfg.ligatures,
            .embolden = cfg.embolden,
            .regular_embolden = cfg.regular_embolden,
            .bold_embolden = cfg.bold_embolden,
            .italic_embolden = cfg.italic_embolden,
            .bold_italic_embolden = cfg.bold_italic_embolden,
            .glyph_shd = glyph_shd,
            .glyph_pip = glyph_pip,
            .glyph_pip_offscreen = glyph_pip_offscreen,
            .swapchain_color_format = swapchain_color_format,
            .glyph_vbufs = glyph_vbufs,
            .glyph_vbuf_index = 0,
            .uploaded_glyph_vbuf = glyph_vbufs[0],
            .uploaded_glyph_verts = 0,
            .glyph_ibuf = glyph_ibuf,
            .glyph_verts_cpu = glyph_verts_cpu,
            .glyph_verts_count = 0,
            .use_linear_correction = cfg.use_linear_correction,
        };
    }

    /// Rasterize all printable ASCII characters across all four base faces so
    /// that the atlas is fully populated before any frame is rendered.  This
    /// prevents mid-session atlas uploads (which transfer the full 16 MB
    /// texture) from spiking frame times during normal editing.
    pub fn warmupAtlas(self: *FtRenderer) void {
        var utf8: [4]u8 = undefined;
        // Printable ASCII (U+0020–U+007E)
        var cp: u32 = 0x20;
        while (cp <= 0x7E) : (cp += 1) {
            const len = encodeUtf8(cp, &utf8) catch continue;
            // Rasterize in regular, bold, italic, bold-italic faces.
            var fi: u8 = 0;
            while (fi < 4) : (fi += 1) {
                self.preRasterize(utf8[0..len], fi, .terminal);
            }
        }
        // Latin-1 supplement (U+00A0–U+00FF): accented chars, symbols, common
        // non-ASCII used in shells and terminals (arrows, degrees, etc.).
        cp = 0xA0;
        while (cp <= 0xFF) : (cp += 1) {
            const len = encodeUtf8(cp, &utf8) catch continue;
            var fi: u8 = 0;
            while (fi < 4) : (fi += 1) {
                self.preRasterize(utf8[0..len], fi, .terminal);
            }
        }
        std.log.info("ft_renderer: atlas warmup done ({d} glyphs cached)", .{self.glyph_cache.count()});
    }

    /// Pre-rasterize all glyphs in a UTF-8 string into the atlas without drawing.
    /// Call this before the sg_begin_pass / flushAtlas cycle so the atlas upload
    /// is not duplicated later when drawLabel is called.
    pub fn preRasterizeLabel(self: *FtRenderer, text: []const u8) void {
        self.preRasterizeLabelFace(text, 0);
    }

    pub fn preRasterizeLabelFace(self: *FtRenderer, text: []const u8, face_idx: u8) void {
        var i: usize = 0;
        while (i < text.len) {
            const cp_len = utf8CodepointLen(text[i]);
            const end = @min(i + cp_len, text.len);
            self.preRasterize(text[i..end], face_idx, .ui);
            i = end;
        }
    }

    /// Draw a UTF-8 string at absolute pixel position (x, y) using the atlas pipeline.
    /// Must be called with the full-framebuffer projection already set up by the caller
    /// (sgl_defaults + sgl_viewport full-fb + sgl_ortho(0, w, h, 0, -1, 1)).
    /// The atlas must already be flushed before calling this (call preRasterizeLabel
    /// before the frame's flushAtlas, then drawLabel during the draw phase).
    /// Advances x by cell_w per UTF-8 codepoint.
    pub fn drawLabel(self: *FtRenderer, x: f32, y: f32, text: []const u8, r: u8, g: u8, b: u8) void {
        self.drawLabelFace(x, y, text, r, g, b, 0);
    }

    pub fn drawLabelFace(self: *FtRenderer, x: f32, y: f32, text: []const u8, r: u8, g: u8, b: u8, face_idx: u8) void {
        if (text.len == 0) return;

        // Draw quads using the atlas pipeline (atlas must already be flushed).
        // IMPORTANT: must use the sgl path (sgl_v2f_t2f), NOT emitGlyphQuad.
        // drawLabelFace is called during the swapchain pass AFTER uploadGlyphVerts()
        // has already run — any verts written to glyph_verts_cpu here would not be
        // uploaded and would corrupt the next frame's glyph draw.
        c.sgl_load_pipeline(self.atlas_pip);
        c.sgl_enable_texture();
        c.sgl_texture(self.atlas_view, self.atlas_ui_smp);
        c.sgl_begin_quads();

        const fg = ghostty.ColorRgb{ .r = r, .g = g, .b = b };
        var px = @round(x);
        const py = @round(y);
        var i: usize = 0;
        while (i < text.len) {
            const cp_len = utf8CodepointLen(text[i]);
            const end = @min(i + cp_len, text.len);
            self.batchGlyphsSgl(px, py, text[i..end], face_idx, fg, .ui);
            px += self.cell_w;
            i = end;
        }

        c.sgl_end();
        c.sgl_disable_texture();
    }

    /// Shape and batch glyphs for one cell at (px, py) using sokol_gl vertex
    /// emission (sgl_v2f_t2f).  Must be called between sgl_begin_quads /
    /// sgl_end.  Used exclusively by drawLabelFace for the tab bar / UI text
    /// so that it does NOT touch glyph_verts_cpu (which is for the custom
    /// gamma-correct pipeline only).
    fn batchGlyphsSgl(self: *FtRenderer, px: f32, py: f32, utf8: []const u8, face_idx: u8, fg: ghostty.ColorRgb, raster_mode: RasterMode) void {
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

    pub fn deinit(self: *FtRenderer) void {
        if (self.run_buf.len > 0) self.allocator.free(self.run_buf);
        for (&self.kitty_textures) |*slot| {
            if (slot.*) |*tex| tex.deinit();
            slot.* = null;
        }
        self.prepared_glyphs.deinit(self.allocator);
        self.shaped_runs.deinit(self.allocator);
        var prepared_it = self.prepared_cache.valueIterator();
        while (prepared_it.next()) |val| {
            self.allocator.free(val.glyphs);
        }
        self.prepared_cache.deinit();
        var it = self.shape_cache.valueIterator();
        while (it.next()) |val| {
            self.allocator.free(val.glyphs);
        }
        self.shape_cache.deinit();
        self.glyph_cache.deinit();
        self.allocator.free(self.atlas_data);
        c.sg_destroy_view(self.atlas_view);
        c.sg_destroy_image(self.atlas_img);
        c.sg_destroy_sampler(self.atlas_smp);
        c.sg_destroy_sampler(self.atlas_ui_smp);
        c.sg_destroy_sampler(self.kitty_image_smp);
        // Custom glyph pipeline resources.
        self.allocator.free(self.glyph_verts_cpu);
        c.sg_destroy_buffer(self.glyph_ibuf);
        for (self.glyph_vbufs) |buf| c.sg_destroy_buffer(buf);
        c.sg_destroy_pipeline(self.glyph_pip_offscreen);
        c.sg_destroy_pipeline(self.glyph_pip);
        c.sg_destroy_shader(self.glyph_shd);
        if (self.hb_buf) |buf| ft.hb_buffer_destroy(buf);
        for (self.fallback_hb_fonts) |maybe_font| {
            if (maybe_font) |font| ft.hb_font_destroy(font);
        }
        self.allocator.free(self.fallback_hb_fonts);
        if (self.hb_emoji) |f| ft.hb_font_destroy(f);
        if (self.hb_cjk) |f| ft.hb_font_destroy(f);
        if (self.hb_symbols) |f| ft.hb_font_destroy(f);
        if (self.hb_symbols_nerd) |f| ft.hb_font_destroy(f);
        if (self.hb_nerd) |f| ft.hb_font_destroy(f);
        if (self.hb_bold_italic) |f| ft.hb_font_destroy(f);
        if (self.hb_italic) |f| ft.hb_font_destroy(f);
        if (self.hb_bold) |f| ft.hb_font_destroy(f);
        if (self.hb_regular) |f| ft.hb_font_destroy(f);
        _ = ft.FT_Done_Face(self.face_cjk);
        _ = ft.FT_Done_Face(self.face_symbols);
        _ = ft.FT_Done_Face(self.face_symbols_nerd);
        _ = ft.FT_Done_Face(self.face_nerd);
        if (self.face_emoji) |f| _ = ft.FT_Done_Face(f);
        for (self.fallback_faces) |face| _ = ft.FT_Done_Face(face);
        self.allocator.free(self.fallback_faces);
        _ = ft.FT_Done_Face(self.face_bold_italic);
        _ = ft.FT_Done_Face(self.face_italic);
        _ = ft.FT_Done_Face(self.face_bold);
        _ = ft.FT_Done_Face(self.face_regular);
        _ = ft.FT_Done_FreeType(self.ft_lib);
    }

    /// Main draw call — called once per frame inside sg_begin_pass/sg_end_pass.
    pub fn draw(
        self: *FtRenderer,
        runtime: *ghostty.Runtime,
        cfg: *const Config,
        app: *const App,
        terminal: ?*anyopaque,
        render_state: ?*anyopaque,
        row_iterator: *?*anyopaque,
        row_cells: *?*anyopaque,
        screen_w: f32,
        screen_h: f32,
    ) void {
        self.queueInViewport(runtime, cfg, app, null, terminal, render_state, row_iterator, row_cells, 0, 0, screen_w, screen_h, screen_w, screen_h, true, true, null, null, false, null, null, std.math.maxInt(usize));
        // Note: sgl_draw() and flushGlyphQuads() are called by the caller
        // (sokol_runtime) after all draw calls, still inside the active sg_pass.
    }

    /// Direct draw for single-pane mode — skips the offscreen render target
    /// and renders straight to the current swapchain pass.
    /// Must be called inside an active sg_pass (swapchain pass).
    pub fn drawDirect(
        self: *FtRenderer,
        runtime: *ghostty.Runtime,
        cfg: *const Config,
        app: *const App,
        pane: *const Pane,
        terminal: ?*anyopaque,
        render_state: ?*anyopaque,
        row_iterator: *?*anyopaque,
        row_cells: *?*anyopaque,
        offset_x: f32,
        offset_y: f32,
        screen_w: f32,
        screen_h: f32,
        fb_w: f32,
        fb_h: f32,
        is_focused: bool,
        force_full: bool,
        selection_range: ?selection.Range,
        hovered_hyperlink: ?App.HoveredHyperlink,
        prev_cursor_row: usize,
    ) void {
        // Reset per-call diagnostic counters.
        self.last_rows_rendered = 0;
        self.last_rows_skipped = 0;
        self.last_cells_visited = 0;
        self.last_glyph_runs = 0;
        self.last_bg_rects = 0;
        self.last_atlas_flushed = false;
        // Queue to default context and draw immediately (no row hash optimisation
        // for direct mode — it's a fallback path anyway).
        self.queueInViewport(runtime, cfg, app, pane, terminal, render_state, row_iterator, row_cells, offset_x, offset_y, screen_w, screen_h, fb_w, fb_h, is_focused, force_full, null, null, false, selection_range, hovered_hyperlink, prev_cursor_row);
        // Note: sgl_draw() and flushGlyphQuads() are called by sokol_runtime
        // after this returns, still inside the active swapchain sg_pass.
    }

    /// Render terminal content for one pane into its `PaneCache` render target.
    /// Must be called OUTSIDE any active sg_pass (before the swapchain pass begins).
    /// After this call the RT texture is up-to-date and can be blitted.
    ///
    /// `clear_rgb` is the terminal background colour so the offscreen clear
    /// matches the terminal theme rather than black.
    ///
    /// `row_hashes` is an optional per-row hash array (length ≥ row_count) used
    /// to skip re-rendering rows whose content is unchanged from the previous frame.
    /// When non-null and `row_map_skip` is true, each row is pre-scanned cheaply
    /// before full cell iteration; unchanged rows are skipped in both passes.
    /// The array is updated in-place after rendering (new hashes stored).
    /// Pass null to disable row-hash optimisation (equivalent to old behaviour).
    ///
    /// `cursor_row` is the row index of the cursor (0-based).  The cursor row is
    /// always re-rendered even if its hash matches (cursor blink / visibility changes).
    pub fn renderToCache(
        self: *FtRenderer,
        cache: *PaneCache,
        runtime: *ghostty.Runtime,
        cfg: *const Config,
        app: *const App,
        pane: *const Pane,
        terminal: ?*anyopaque,
        render_state: ?*anyopaque,
        row_iterator: *?*anyopaque,
        row_cells: *?*anyopaque,
        pane_w: f32,
        pane_h: f32,
        is_focused: bool,
        clear_r: f32,
        clear_g: f32,
        clear_b: f32,
        force_full: bool,
        row_map_keys: ?[]u64,
        row_map_vals: ?[]u64,
        row_map_skip: bool,
        selection_range: ?selection.Range,
        hovered_hyperlink: ?App.HoveredHyperlink,
        /// Cursor row from the previous rendered frame; used to erase ghost
        /// cursor pixels when the cursor moves and ghostty doesn't mark the old
        /// row dirty.  Pass std.math.maxInt(usize) on first frame or force_full.
        prev_cursor_row: usize,
    ) void {
        // Reset per-call diagnostic counters.
        self.last_rows_rendered = 0;
        self.last_rows_skipped = 0;
        self.last_cells_visited = 0;
        self.last_glyph_runs = 0;
        self.last_bg_rects = 0;
        self.last_atlas_flushed = false;
        self.frame_count += 1;

        // Evict atlas if it is ≥90% full to prevent the "atlas full" hard stop.
        self.resetAtlasIfNeeded();

        // Switch to this pane's sgl_context so draw commands go into its
        // own vertex / command buffers (isolated from the main context).
        c.sgl_set_context(cache.sgl_ctx);

        // Temporarily swap in the context-specific atlas pipeline so that
        // queueInViewport uses the right one.
        const saved_pip = self.atlas_pip;
        self.atlas_pip = cache.atlas_pip;

        // Queue all terminal geometry into the pane context.
        // offset_x/y = 0 because the RT origin is the pane's top-left.
        const t_queue_start = if (cfg.debug_overlay) std.time.nanoTimestamp() else 0;
        self.queueInViewport(
            runtime,
            cfg,
            app,
            pane,
            terminal,
            render_state,
            row_iterator,
            row_cells,
            0.0,
            0.0,
            pane_w,
            pane_h,
            pane_w,
            pane_h,
            is_focused,
            force_full,
            row_map_keys,
            row_map_vals,
            row_map_skip,
            selection_range,
            hovered_hyperlink,
            if (force_full) std.math.maxInt(usize) else prev_cursor_row,
        );
        const t_queue_end = if (cfg.debug_overlay) std.time.nanoTimestamp() else 0;

        // Restore atlas pipeline and default context.
        self.atlas_pip = saved_pip;

        // Upload glyph vertices to GPU BEFORE beginning the pass.
        // sg_update_buffer must not be called inside an active sg_pass on D3D11.
        const n_uploaded = self.uploadGlyphVerts();
        if (self.frame_count <= 3) {
            std.log.info("ft_renderer renderToCache: frame={d} clear=({d:.3},{d:.3},{d:.3}) force_full={} n_uploaded={d}", .{
                self.frame_count, clear_r, clear_g, clear_b, force_full, n_uploaded,
            });
        }

        // Begin the offscreen pass targeting this pane's RT.
        // - force_full → CLEAR: need a fresh background (resize, scroll, etc.)
        // - partial     → LOAD: keep existing pixel content; only dirty rows were redrawn.
        self.offscreen_pass_scratch = std.mem.zeroes(c.sg_pass);
        self.offscreen_pass_scratch.attachments.colors[0] = cache.rt_att_view;
        if (force_full) {
            self.offscreen_pass_scratch.action.colors[0].load_action = c.SG_LOADACTION_CLEAR;
            self.offscreen_pass_scratch.action.colors[0].clear_value = .{ .r = clear_r, .g = clear_g, .b = clear_b, .a = 1.0 };
        } else {
            self.offscreen_pass_scratch.action.colors[0].load_action = c.SG_LOADACTION_LOAD;
        }
        c.sg_begin_pass(&self.offscreen_pass_scratch);

        // Flush the pane's sgl context into the offscreen pass.
        c.sgl_context_draw(cache.sgl_ctx);

        // Draw glyph quads through the custom gamma-correct pipeline.
        // Must happen after sgl_context_draw (avoids interleaving sgl and raw sg_*).
        // Vertices were already uploaded above via uploadGlyphVerts().
        self.drawGlyphQuads(pane_w, pane_h, true, srgbToLinearBg(clear_r, clear_g, clear_b));
        c.sg_end_pass();
        const t_gpu_end = if (cfg.debug_overlay) std.time.nanoTimestamp() else 0;

        if (cfg.debug_overlay) {
            self.last_queue_ns = t_queue_end - t_queue_start;
            self.last_gpu_ns = t_gpu_end - t_queue_end;
        }

        // Restore default context for subsequent draw calls (tab bar, etc.).
        c.sgl_set_context(c.sgl_default_context());
    }

    /// Blit a pane's cached RT texture as a textured quad into the current
    /// (swapchain) pass.  Must be called inside an active sg_pass.
    /// Uses the default sgl_context.
    ///
    /// `fb_w` / `fb_h` are the full framebuffer dimensions (for the ortho
    /// projection); `ox`/`oy`/`pw`/`ph` are the pane's pixel rect.
    pub fn blitCache(
        self: *FtRenderer,
        cache: *PaneCache,
        ox: f32,
        oy: f32,
        pw: f32,
        ph: f32,
        fb_w: f32,
        fb_h: f32,
    ) void {
        c.sgl_defaults();
        c.sgl_viewport(0, 0, @intFromFloat(fb_w), @intFromFloat(fb_h), true);
        c.sgl_scissor_rect(0, 0, @intFromFloat(fb_w), @intFromFloat(fb_h), true);
        c.sgl_load_pipeline(self.atlas_pip);
        c.sgl_enable_texture();
        c.sgl_texture(cache.rt_tex_view, cache.blit_smp);
        c.sgl_matrix_mode_projection();
        c.sgl_load_identity();
        c.sgl_ortho(0.0, fb_w, fb_h, 0.0, -1.0, 1.0);

        // Draw a quad covering [ox, oy] → [ox+pw, oy+ph] with UV [0,0]→[1,1].
        // Vertex colour white (1,1,1,1) so the texture is sampled as-is.
        c.sgl_begin_quads();
        c.sgl_c4b(255, 255, 255, 255);
        c.sgl_v2f_t2f(ox, oy, 0.0, 0.0);
        c.sgl_v2f_t2f(ox + pw, oy, 1.0, 0.0);
        c.sgl_v2f_t2f(ox + pw, oy + ph, 1.0, 1.0);
        c.sgl_v2f_t2f(ox, oy + ph, 0.0, 1.0);
        c.sgl_end();
        c.sgl_disable_texture();
    }

    pub fn queueKittyLayerInPane(
        self: *FtRenderer,
        runtime: *ghostty.Runtime,
        terminal: ?*anyopaque,
        layer: ghostty.KittyPlacementLayer,
        ox: f32,
        oy: f32,
        pw: f32,
        ph: f32,
        fb_w: f32,
        fb_h: f32,
    ) void {
        const term = terminal orelse return;
        const graphics = runtime.terminalKittyGraphics(term) orelse return;
        const iterator = runtime.createKittyPlacementIterator() catch return;
        defer runtime.freeKittyPlacementIterator(iterator);
        if (!runtime.populateKittyPlacementIterator(graphics, iterator)) return;
        if (!runtime.setKittyPlacementLayer(iterator, layer)) return;

        c.sgl_defaults();
        c.sgl_viewport(0, 0, @intFromFloat(fb_w), @intFromFloat(fb_h), true);
        c.sgl_scissor_rect(@intFromFloat(ox), @intFromFloat(oy), @intFromFloat(pw), @intFromFloat(ph), true);
        c.sgl_matrix_mode_projection();
        c.sgl_load_identity();
        c.sgl_ortho(0.0, fb_w, fb_h, 0.0, -1.0, 1.0);

        while (runtime.nextKittyPlacement(iterator)) {
            var is_virtual = false;
            if (!runtime.kittyPlacementData(iterator, .is_virtual, &is_virtual) or is_virtual) continue;

            var image_id: u32 = 0;
            if (!runtime.kittyPlacementData(iterator, .image_id, &image_id)) continue;
            const image = runtime.kittyGraphicsImage(graphics, image_id) orelse continue;
            const render_info = runtime.kittyPlacementRenderInfo(iterator, image, term) orelse continue;
            if (!render_info.viewport_visible or render_info.pixel_width == 0 or render_info.pixel_height == 0) continue;

            const tex = getOrCreateKittyTexture(self, runtime, image_id, image) orelse continue;

            var x = self.padding_x + @as(f32, @floatFromInt(render_info.viewport_col)) * self.cell_w;
            var y = self.padding_y + @as(f32, @floatFromInt(render_info.viewport_row)) * self.cell_h;
            var w = @as(f32, @floatFromInt(render_info.pixel_width));
            var h = @as(f32, @floatFromInt(render_info.pixel_height));
            var uv0_x = @as(f32, @floatFromInt(render_info.source_x)) / @as(f32, @floatFromInt(tex.key.width));
            var uv0_y = @as(f32, @floatFromInt(render_info.source_y)) / @as(f32, @floatFromInt(tex.key.height));
            var uv1_x = @as(f32, @floatFromInt(render_info.source_x + render_info.source_width)) / @as(f32, @floatFromInt(tex.key.width));
            var uv1_y = @as(f32, @floatFromInt(render_info.source_y + render_info.source_height)) / @as(f32, @floatFromInt(tex.key.height));
            if (!clipTexturedQuad(&x, &y, &w, &h, &uv0_x, &uv0_y, &uv1_x, &uv1_y, pw, ph)) continue;

            x += ox;
            y += oy;

            c.sgl_load_default_pipeline();
            c.sgl_enable_texture();
            c.sgl_texture(tex.view, self.kitty_image_smp);
            c.sgl_begin_quads();
            c.sgl_c4b(255, 255, 255, 255);
            c.sgl_v2f_t2f(x, y, uv0_x, uv0_y);
            c.sgl_v2f_t2f(x + w, y, uv1_x, uv0_y);
            c.sgl_v2f_t2f(x + w, y + h, uv1_x, uv1_y);
            c.sgl_v2f_t2f(x, y + h, uv0_x, uv1_y);
            c.sgl_end();
            c.sgl_disable_texture();
        }
    }

    /// Queue geometry for one pane into its viewport sub-rect.
    /// Does NOT call sgl_draw() — the caller must call sgl_draw() exactly once
    /// per frame after all queueInViewport() calls are done.
    /// `is_focused` controls whether the cursor is drawn for this pane.
    /// `force_full` = true → draw every row (used on full-dirty / resize / atlas change).
    /// `force_full` = false → skip rows whose ghostty row-dirty flag is clear,
    ///   and clear the row-dirty flag after rendering each dirty row.
    /// `row_hashes` — optional per-row content hash array (see renderToCache for details).
    ///   When non-null and `row_map_skip` is true, rows with matching hashes are skipped.
    /// `cursor_row` — row index of the cursor; always rendered even if hash matches.
    pub fn queueInViewport(
        self: *FtRenderer,
        runtime: *ghostty.Runtime,
        cfg: *const Config,
        app: *const App,
        pane: ?*const Pane,
        terminal: ?*anyopaque,
        render_state: ?*anyopaque,
        row_iterator: *?*anyopaque,
        row_cells: *?*anyopaque,
        offset_x: f32,
        offset_y: f32,
        pane_w: f32,
        pane_h: f32,
        fb_w: f32,
        fb_h: f32,
        is_focused: bool,
        force_full: bool,
        row_map_keys: ?[]u64,
        row_map_vals: ?[]u64,
        row_map_skip: bool,
        selection_range: ?selection.Range,
        hovered_hyperlink: ?App.HoveredHyperlink,
        /// Row index of the cursor in the *previous* frame.  When the cursor has
        /// moved away from this row ghostty may not mark it dirty (the text
        /// content is unchanged) so old block-cursor pixels linger.  Passing the
        /// previous cursor row forces a re-render of that row to erase them.
        /// Pass std.math.maxInt(usize) to disable (e.g. first frame, force_full).
        prev_cursor_row: usize,
    ) void {
        _ = fb_w;
        _ = fb_h;
        _ = terminal;
        const render_colors = if (cfg.terminal_theme.enabled) null else blk: {
            if (!runtime.renderStateColorsInto(render_state, &self.render_colors_scratch)) return;
            break :blk &self.render_colors_scratch;
        };
        const default_bg = if (cfg.terminal_theme.enabled) cfg.terminal_theme.background else render_colors.?.background;
        const default_fg = if (cfg.terminal_theme.enabled) cfg.terminal_theme.foreground else render_colors.?.foreground;
        const raw_cursor_color: ghostty.ColorRgb = if (cfg.terminal_theme.enabled)
            (cfg.terminal_theme.cursor orelse .{ .r = 220, .g = 220, .b = 220 })
        else if (render_colors.?.cursor_has_value)
            render_colors.?.cursor
        else
            .{ .r = 220, .g = 220, .b = 220 };
        const cursor_style = effectiveCursorStyle(runtime, render_state, pane, app, is_focused);
        const cursor_wide = runtime.cursorWideTail(render_state);
        const cursor_bg = effectiveCursorColor(raw_cursor_color, default_bg);
        const selection_bg = if (cfg.terminal_theme.enabled)
            (cfg.terminal_theme.selection_bg orelse mixColor(default_bg, default_fg, 0.35))
        else
            mixColor(default_bg, default_fg, 0.35);
        const search_bg = mixColor(default_bg, default_fg, 0.18);
        const search_active_bg = mixColor(default_bg, default_fg, 0.42);
        const queue = QueueContext{
            .cfg = cfg,
            .pane = pane,
            .render_state = render_state,
            .row_iterator = row_iterator,
            .row_cells = row_cells,
            .row_count = @intCast(runtime.renderStateRows(render_state) orelse 0),
            .col_count = @intCast(runtime.renderStateCols(render_state) orelse 0),
            .force_full = force_full,
            .app = app,
            .selection_range = selection_range,
            .hovered_hyperlink = hovered_hyperlink,
            .prev_cursor_row = prev_cursor_row,
            .cursor_row = if (runtime.cursorPos(render_state)) |cp| @intCast(cp.y) else std.math.maxInt(usize),
            .cursor_col = if (runtime.cursorPos(render_state)) |cp| @intCast(cp.x) else std.math.maxInt(usize),
            .cursor_style = cursor_style,
            .cursor_wide = cursor_wide,
            .hovered_row = if (hovered_hyperlink) |hovered| hovered.row else std.math.maxInt(usize),
            .row_map_keys = row_map_keys,
            .row_map_vals = row_map_vals,
            .row_map_skip = row_map_skip,
            .colors = .{
                .default_bg = default_bg,
                .default_fg = default_fg,
                .cursor_bg = cursor_bg,
                .cursor_fg = if (cfg.terminal_theme.enabled)
                    (cfg.terminal_theme.cursor_fg orelse contrastTextColor(cursor_bg))
                else
                    contrastTextColor(cursor_bg),
                .selection_bg = selection_bg,
                .selection_fg = if (cfg.terminal_theme.enabled)
                    (cfg.terminal_theme.selection_fg orelse default_fg)
                else
                    default_fg,
                .search_bg = search_bg,
                .search_active_bg = search_active_bg,
                .palette = if (cfg.terminal_theme.enabled) &cfg.terminal_theme.palette else &render_colors.?.palette,
            },
        };

        self.setupViewport(offset_x, offset_y, pane_w, pane_h);

        if (!self.logged_first_draw) {
            std.log.info("ft_renderer first draw: screen={d:.0}x{d:.0} cell={d:.1}x{d:.1}", .{
                pane_w, pane_h, self.cell_w, self.cell_h,
            });
        }

        if (!self.ensureRunBufferCapacity(queue.row_count, queue.col_count)) return;
        const run_buf = self.run_buf;
        self.resetQueueState();

        var hash_skip_bits: HashSkipBits = [_]u64{0} ** HASH_SKIP_WORDS;

        // ── Pass 1: Background & Rasterisation ──────────────────────────────
        // We must always probe/rasterize text for rows we are about to draw.
        // Even when the atlas is currently clean, a newly-seen glyph (for
        // example a Nerd Font prompt icon) needs to be added and uploaded
        // before pass 2 queues textured quads, otherwise it won't appear until
        // the next frame.
        //
        // In partial mode (!force_full), skip rows that are not dirty.
        const t_pass1_start = if (cfg.debug_overlay) std.time.nanoTimestamp() else 0;
        self.queueBackgroundAndRasterPass(runtime, &queue, pane_w, pane_h, &hash_skip_bits, run_buf);

        if (self.atlas_dirty) {
            self.flushAtlas();
            self.atlas_dirty = false;
            self.last_atlas_flushed = true;
        }
        const t_pass2_start = if (cfg.debug_overlay) std.time.nanoTimestamp() else 0;
        var pass2_glyph_ns: i128 = 0;
        var pass2_decoration_ns: i128 = 0;

        // ── Pass 2: Glyph draw pass ────────────────────────────────────────
        // In partial mode, skip clean rows; clear rowDirty on each dirty row
        // after rendering so the flag is reset for the next updateRenderState.
        const pass2_stats = self.queueGlyphPass(runtime, &queue, &hash_skip_bits, run_buf);
        pass2_glyph_ns = pass2_stats.glyph_ns;
        pass2_decoration_ns = pass2_stats.decoration_ns;

        if (!self.logged_first_draw) self.logged_first_draw = true;
        if (self.frame_count <= 3) {
            std.log.info("ft_renderer queueInViewport done: frame={d} glyph_verts={d} rows_rendered={d} bg_rects={d}", .{
                self.frame_count, self.glyph_verts_count, self.last_rows_rendered, self.last_bg_rects,
            });
        }
        const t_pass2_end = if (cfg.debug_overlay) std.time.nanoTimestamp() else 0;

        if (cfg.debug_overlay) {
            self.last_pass1_ns = t_pass2_start - t_pass1_start;
            self.last_pass2_ns = t_pass2_end - t_pass2_start;
        }

        self.last_pass2_glyph_ns = pass2_glyph_ns;
        self.last_pass2_decoration_ns = pass2_decoration_ns;
    }

    fn queueCopyModeSnapshot(
        self: *FtRenderer,
        cfg: *const Config,
        app: *const App,
        pane: *const Pane,
        offset_x: f32,
        offset_y: f32,
        pane_w: f32,
        pane_h: f32,
    ) void {
        const default_bg = if (cfg.terminal_theme.enabled) cfg.terminal_theme.background else ghostty.ColorRgb{ .r = 0, .g = 0, .b = 0 };
        const default_fg = if (cfg.terminal_theme.enabled) cfg.terminal_theme.foreground else ghostty.ColorRgb{ .r = 220, .g = 220, .b = 220 };
        const selection_bg = if (cfg.terminal_theme.enabled)
            (cfg.terminal_theme.selection_bg orelse mixColor(default_bg, default_fg, 0.35))
        else
            mixColor(default_bg, default_fg, 0.35);
        const selection_fg = if (cfg.terminal_theme.enabled)
            (cfg.terminal_theme.selection_fg orelse default_fg)
        else
            default_fg;
        const search_bg = mixColor(default_bg, default_fg, 0.18);
        const search_active_bg = mixColor(default_bg, default_fg, 0.42);
        const selection_range = app.copyModeSelectionRange(pane);

        self.setupViewport(offset_x, offset_y, pane_w, pane_h);
        self.resetQueueState();
        if (!self.ensureRunBufferCapacity(@max(@as(usize, 1), @as(usize, pane.rows)), @max(@as(usize, 1), @as(usize, pane.cols)))) return;
        const run_buf = self.run_buf;

        c.sgl_load_default_pipeline();
        c.sgl_begin_quads();
        emitRect(0.0, 0.0, pane_w, pane_h, default_bg.r, default_bg.g, default_bg.b, 255);

        const visible_rows = @max(@as(usize, 1), @as(usize, pane.rows));
        var row: usize = 0;
        while (row < visible_rows) : (row += 1) {
            const row_info = self.makeCopyModeSnapshotRowInfo(app, pane, selection_range, row, visible_rows);
            const line = app.copyModeSnapshotLineForRow(pane, row);
            self.queueCopyModeSnapshotRowBackground(line, row_info, default_bg, cfg, selection_bg, search_bg, search_active_bg, selection_fg);
        }
        c.sgl_end();

        row = 0;
        while (row < visible_rows) : (row += 1) {
            const line = app.copyModeSnapshotLineForRow(pane, row) orelse continue;
            const row_info = self.makeCopyModeSnapshotRowInfo(app, pane, selection_range, row, visible_rows);
            self.queueCopyModeSnapshotRowText(line, row_info, cfg, default_fg, selection_fg, run_buf, .raster);
        }

        if (self.atlas_dirty) {
            self.flushAtlas();
            self.atlas_dirty = false;
            self.last_atlas_flushed = true;
        }

        row = 0;
        while (row < visible_rows) : (row += 1) {
            const line = app.copyModeSnapshotLineForRow(pane, row) orelse continue;
            const row_info = self.makeCopyModeSnapshotRowInfo(app, pane, selection_range, row, visible_rows);
            self.queueCopyModeSnapshotRowText(line, row_info, cfg, default_fg, selection_fg, run_buf, .draw);
        }
    }

    fn makeCopyModeSnapshotRowInfo(
        self: *FtRenderer,
        app: *const App,
        pane: *const Pane,
        selection_range: ?selection.Range,
        row: usize,
        visible_rows: usize,
    ) RowRenderInfo {
        const row_y_px = if (builtin.os.tag == .linux and visible_rows > 0)
            @as(f32, @floatFromInt((visible_rows - 1) - row)) * self.cell_h
        else
            @as(f32, @floatFromInt(row)) * self.cell_h;
        return .{
            .row_y = row,
            .py = self.padding_y + row_y_px,
            .selection = if (selection_range) |range| rowSelectionBounds(range, row) else null,
            .search_highlight = app.searchHighlightForRow(pane, row),
            .cursor_col = app.copyModeCursorColForRow(pane, row),
        };
    }

    fn queueCopyModeSnapshotRowBackground(
        self: *FtRenderer,
        line: ?CopyModeSnapshotLine,
        row: RowRenderInfo,
        default_bg: ghostty.ColorRgb,
        cfg: *const Config,
        selection_bg: ghostty.ColorRgb,
        search_bg: ghostty.ColorRgb,
        search_active_bg: ghostty.ColorRgb,
        selection_fg: ghostty.ColorRgb,
    ) void {
        if (line) |snapshot| {
            for (snapshot.cells, 0..) |cell, col| {
                const bg = if (cell.bg_style.tag != .none)
                    ghostty.resolveStyleColor(cell.bg_style, default_bg, &cfg.terminal_theme.palette)
                else
                    cell.bg orelse continue;
                const x = self.padding_x + @as(f32, @floatFromInt(col)) * self.cell_w;
                emitRect(x, row.py, self.cell_w, self.cell_h, bg.r, bg.g, bg.b, 255);
            }
        }
        if (row.selection) |bounds| {
            const start_x = self.padding_x + @as(f32, @floatFromInt(bounds.start_col)) * self.cell_w;
            const end_x = self.padding_x + @as(f32, @floatFromInt(bounds.end_col + 1)) * self.cell_w;
            emitRect(start_x, row.py, @max(0.0, end_x - start_x), self.cell_h, selection_bg.r, selection_bg.g, selection_bg.b, 255);
        }
        if (row.search_highlight) |highlight| {
            const bg = if (highlight.active) search_active_bg else search_bg;
            const start_x = self.padding_x + @as(f32, @floatFromInt(highlight.start_col)) * self.cell_w;
            const end_x = self.padding_x + @as(f32, @floatFromInt(highlight.end_col)) * self.cell_w;
            emitRect(start_x, row.py, @max(0.0, end_x - start_x), self.cell_h, bg.r, bg.g, bg.b, 255);
        }
        if (row.cursor_col) |cursor_col| {
            const cursor_x = self.padding_x + @as(f32, @floatFromInt(cursor_col)) * self.cell_w;
            emitRect(cursor_x, row.py, self.cell_w, self.cell_h, selection_fg.r, selection_fg.g, selection_fg.b, 96);
        }
    }

    fn queueCopyModeSnapshotRowText(
        self: *FtRenderer,
        line: CopyModeSnapshotLine,
        row: RowRenderInfo,
        cfg: *const Config,
        default_fg: ghostty.ColorRgb,
        selection_fg: ghostty.ColorRgb,
        run_buf: []u8,
        mode: GlyphRunMode,
    ) void {
        var run = GlyphRunState{ .fg = default_fg };
        for (line.cells, 0..) |cell, col| {
            if (col >= line.cols) break;
            const resolved_fg = if (cell.fg_style.tag != .none)
                ghostty.resolveStyleColor(cell.fg_style, default_fg, &cfg.terminal_theme.palette)
            else
                default_fg;
            const fg = if (isSelectedCell(row.selection, col)) selection_fg else resolved_fg;
            if (cell.text.len == 0 or (cell.text.len == 1 and cell.text[0] == ' ')) {
                self.flushQueuedRun(mode, run_buf, &run, row.py);
                continue;
            }
            if (mode == .draw) {
                const px = self.columnPixelX(col, line.cols);
                if (self.drawSynthesizedBoxUtf8(px, row.py, cell.text, fg, row.py, row.py + self.cell_h) or
                    drawSynthesizedTerminalUtf8(px, row.py, self.cell_w, self.cell_h, cell.text, fg))
                {
                    self.flushQueuedRun(mode, run_buf, &run, row.py);
                    continue;
                }
            }
            self.appendQueuedRun(mode, run_buf, cell.text, col, cell.face_idx, fg, &run, row.py);
        }
        self.flushQueuedRun(mode, run_buf, &run, row.py);
    }

    const HASH_SKIP_MAX_ROWS = 512;
    const HASH_SKIP_WORDS = HASH_SKIP_MAX_ROWS / 64;
    const HashSkipBits = [HASH_SKIP_WORDS]u64;

    const QueueColors = struct {
        default_bg: ghostty.ColorRgb,
        default_fg: ghostty.ColorRgb,
        cursor_bg: ghostty.ColorRgb,
        cursor_fg: ghostty.ColorRgb,
        selection_bg: ghostty.ColorRgb,
        selection_fg: ghostty.ColorRgb,
        search_bg: ghostty.ColorRgb,
        search_active_bg: ghostty.ColorRgb,
        palette: *const [256]ghostty.ColorRgb,
    };

    const QueueContext = struct {
        cfg: *const Config,
        app: *const App,
        pane: ?*const Pane,
        render_state: ?*anyopaque,
        row_iterator: *?*anyopaque,
        row_cells: *?*anyopaque,
        row_count: usize,
        col_count: usize,
        force_full: bool,
        selection_range: ?selection.Range,
        hovered_hyperlink: ?App.HoveredHyperlink,
        prev_cursor_row: usize,
        cursor_row: usize,
        cursor_col: usize,
        cursor_style: ?ghostty.CursorVisualStyle,
        cursor_wide: bool,
        hovered_row: usize,
        row_map_keys: ?[]u64,
        row_map_vals: ?[]u64,
        row_map_skip: bool,
        colors: QueueColors,

        inline fn useRowMap(self: @This()) bool {
            return self.row_map_keys != null and self.row_map_vals != null;
        }

        inline fn helpersReady(self: @This()) bool {
            return self.render_state != null and self.row_iterator.* != null and self.row_cells.* != null;
        }
    };

    const RowRenderInfo = struct {
        row_y: usize,
        py: f32,
        selection: ?RowSelectionBounds,
        search_highlight: ?SearchHighlight,
        cursor_col: ?usize,
        cursor_wide: bool,
    };

    const CellTextStyle = struct {
        face_idx: u8,
        fg: ghostty.ColorRgb,
        needs_decorations: bool = false,
    };

    const GlyphRunMode = enum {
        raster,
        draw,
    };

    const GlyphRunState = struct {
        start_col: usize = 0,
        len: usize = 0,
        face_idx: u8 = 0,
        fg: ghostty.ColorRgb,
    };

    const Pass2Stats = struct {
        glyph_ns: i128 = 0,
        decoration_ns: i128 = 0,
    };

    fn setupViewport(self: *FtRenderer, offset_x: f32, offset_y: f32, pane_w: f32, pane_h: f32) void {
        _ = self;
        c.sgl_defaults();
        c.sgl_viewport(
            @as(c_int, @intFromFloat(offset_x)),
            @as(c_int, @intFromFloat(offset_y)),
            @as(c_int, @intFromFloat(pane_w)),
            @as(c_int, @intFromFloat(pane_h)),
            true,
        );
        c.sgl_scissor_rect(
            @as(c_int, @intFromFloat(offset_x)),
            @as(c_int, @intFromFloat(offset_y)),
            @as(c_int, @intFromFloat(pane_w)),
            @as(c_int, @intFromFloat(pane_h)),
            true,
        );
        c.sgl_matrix_mode_projection();
        c.sgl_load_identity();
        c.sgl_ortho(0.0, pane_w, pane_h, 0.0, -1.0, 1.0);
    }

    fn ensureRunBufferCapacity(self: *FtRenderer, row_count: usize, col_count: usize) bool {
        if (row_count != self.run_buf_rows or col_count != self.run_buf_cols) {
            const run_buf_needed = @max(@as(usize, 1), row_count * col_count * 4);
            if (run_buf_needed > self.run_buf.len) {
                if (self.run_buf.len > 0) self.allocator.free(self.run_buf);
                self.run_buf = self.allocator.alloc(u8, run_buf_needed) catch return false;
            }
            self.run_buf_rows = row_count;
            self.run_buf_cols = col_count;
        }
        return true;
    }

    fn resetQueueState(self: *FtRenderer) void {
        self.prepared_glyphs.clearRetainingCapacity();
        self.shaped_runs.clearRetainingCapacity();
        self.shaped_run_read_idx = 0;
        self.styleCacheReset();
    }

    fn queueBackgroundAndRasterPass(
        self: *FtRenderer,
        runtime: *ghostty.Runtime,
        queue: *const QueueContext,
        pane_w: f32,
        pane_h: f32,
        hash_skip_bits: *HashSkipBits,
        run_buf: []u8,
    ) void {
        if (!queue.helpersReady()) return;
        if (!runtime.populateRowIterator(queue.render_state, queue.row_iterator)) return;

        var row_y: usize = 0;
        var quads_open = false;
        if (queue.force_full) {
            c.sgl_begin_quads();
            quads_open = true;
            c.sgl_c4b(queue.colors.default_bg.r, queue.colors.default_bg.g, queue.colors.default_bg.b, 255);
            c.sgl_v2f(0.0, 0.0);
            c.sgl_v2f(pane_w, 0.0);
            c.sgl_v2f(pane_w, pane_h);
            c.sgl_v2f(0.0, pane_h);
        }
        while (runtime.nextRow(queue.row_iterator.*)) : (row_y += 1) {
            if (!queue.force_full and !runtime.rowDirty(queue.row_iterator.*) and row_y != queue.prev_cursor_row and row_y != queue.cursor_row) continue;
            if (self.shouldSkipRowByHash(runtime, queue, row_y, hash_skip_bits)) continue;

            const row = self.makeRowRenderInfo(queue, row_y);
            self.queueBackgroundAndRasterRow(runtime, queue, row, pane_w, &quads_open, run_buf);
        }
        if (quads_open) c.sgl_end();
    }

    fn queueBackgroundAndRasterRow(
        self: *FtRenderer,
        runtime: *ghostty.Runtime,
        queue: *const QueueContext,
        row: RowRenderInfo,
        pane_w: f32,
        quads_open: *bool,
        run_buf: []u8,
    ) void {
        if (!queue.helpersReady()) return;
        if (!runtime.populateRowCells(queue.row_iterator.*, queue.row_cells)) return;

        if (!queue.force_full) {
            if (!quads_open.*) {
                c.sgl_begin_quads();
                quads_open.* = true;
            }
            c.sgl_c4b(queue.colors.default_bg.r, queue.colors.default_bg.g, queue.colors.default_bg.b, 255);
            c.sgl_v2f(0.0, row.py);
            c.sgl_v2f(pane_w, row.py);
            c.sgl_v2f(pane_w, row.py + self.cell_h);
            c.sgl_v2f(0.0, row.py + self.cell_h);
        }

        var col_x: usize = 0;
        var col_px = self.padding_x;
        var run = GlyphRunState{ .fg = queue.colors.default_fg };
        const has_selection = row.selection != null;
        var last_style_id: u16 = 0;
        var last_style_selected = false;
        var last_style_valid = false;
        var last_style_info: CachedStyleInfo = undefined;
        while (runtime.nextCell(queue.row_cells.*)) : ({
            col_x += 1;
            col_px += self.cell_w;
        }) {
            self.last_cells_visited += 1;
            const raw_cell = runtime.cellRaw(queue.row_cells.*);
            const content_tag = runtime.cellContentTagRaw(raw_cell);
            const style_id = runtime.cellStyleIdRaw(raw_cell);
            const is_selected = has_selection and isSelectedCell(row.selection, col_x);
            const cached_style = if (style_id != 0) blk: {
                if (last_style_valid and last_style_id == style_id and last_style_selected == is_selected) {
                    break :blk &last_style_info;
                }
                const info = self.resolveCachedStyle(runtime, queue.row_cells.*, style_id, is_selected, queue.colors.default_fg, queue.colors.default_bg, queue.colors.selection_fg, queue.colors.palette) orelse break :blk null;
                last_style_info = info.*;
                last_style_id = style_id;
                last_style_selected = is_selected;
                last_style_valid = true;
                break :blk &last_style_info;
            } else null;
            const has_search_highlight = if (row.search_highlight) |highlight|
                col_x >= highlight.start_col and col_x < highlight.end_col
            else
                false;
            const has_cursor = if (row.cursor_col) |cursor_col| col_x == cursor_col else false;
            const has_block_cursor = has_cursor and (queue.cursor_style == .block or (queue.cursor_style == null and queue.pane != null and queue.app.copyModeActiveForPane(queue.pane.?)));
            const style_needs_background = if (style_id != 0)
                if (cached_style) |style|
                    style.has_non_default_bg or style.renders_background_without_text
                else
                    true
            else
                false;
            const needs_background = if (is_selected or has_search_highlight or has_cursor)
                true
            else if (content_tag == .bg_color_palette or content_tag == .bg_color_rgb)
                true
            else if (style_needs_background)
                true
            else
                false;
            if (needs_background) {
                self.queueCellBackground(runtime, queue, row, content_tag, style_id, cached_style, is_selected, col_px, row.py, quads_open);
            }

            switch (content_tag) {
                .codepoint => {
                    const cp = runtime.cellCodepointRaw(raw_cell);
                    if (cp == 0) {
                        self.flushQueuedRun(.raster, run_buf, &run, row.py);
                        continue;
                    }
                    const cursor_fg = if (has_block_cursor and !(queue.cfg.terminal_theme.enabled and queue.cfg.terminal_theme.cursor_fg != null))
                        runtime.cellBackground(queue.row_cells.*) orelse queue.colors.cursor_fg
                    else
                        queue.colors.cursor_fg;
                    const text_style = if (style_id == 0)
                        CellTextStyle{
                            .face_idx = 0,
                            .fg = if (is_selected)
                                queue.colors.selection_fg
                            else if (has_block_cursor)
                                cursor_fg
                            else
                                queue.colors.default_fg,
                        }
                    else if (cached_style) |info|
                        CellTextStyle{
                            .face_idx = info.face_idx,
                            .fg = if (has_block_cursor) cursor_fg else info.fg,
                            .needs_decorations = info.needs_decorations,
                        }
                    else {
                        self.flushQueuedRun(.raster, run_buf, &run, row.py);
                        continue;
                    };
                    const glyph_utf8 = self.encodeCodepointUtf8(cp);
                    if (glyph_utf8.len == 0) {
                        self.flushQueuedRun(.raster, run_buf, &run, row.py);
                        continue;
                    }
                    if (!self.ligatures or !isLigatureCodepoint(cp)) {
                        self.flushQueuedRun(.raster, run_buf, &run, row.py);
                        if (isSynthesizedTerminalCodepoint(cp)) {
                            continue;
                        }
                        if (self.directGlyph(cp, text_style.face_idx) == null) {
                            if (self.prepareGlyphs(glyph_utf8, text_style.face_idx, .terminal)) |prepared| {
                                self.recordShapedRun(glyph_utf8, text_style.face_idx, prepared.start, prepared.glyphs.len);
                            }
                        }
                        continue;
                    }
                    self.appendQueuedRun(.raster, run_buf, glyph_utf8, col_x, text_style.face_idx, text_style.fg, &run, row.py);
                },
                .codepoint_grapheme => {
                    var cps: [16]u32 = [_]u32{0} ** 16;
                    const grapheme_len = @min(runtime.cellGraphemeLen(queue.row_cells.*), cps.len);
                    const glyph_utf8 = self.encodeCurrentCellGraphemeUtf8(runtime, queue.row_cells.*, &cps) orelse {
                        self.flushQueuedRun(.raster, run_buf, &run, row.py);
                        continue;
                    };
                    const cursor_fg = if (has_block_cursor and !(queue.cfg.terminal_theme.enabled and queue.cfg.terminal_theme.cursor_fg != null))
                        runtime.cellBackground(queue.row_cells.*) orelse queue.colors.cursor_fg
                    else
                        queue.colors.cursor_fg;
                    const text_style = if (style_id == 0)
                        CellTextStyle{
                            .face_idx = 0,
                            .fg = if (is_selected)
                                queue.colors.selection_fg
                            else if (has_block_cursor)
                                cursor_fg
                            else
                                queue.colors.default_fg,
                        }
                    else if (cached_style) |info|
                        CellTextStyle{
                            .face_idx = info.face_idx,
                            .fg = if (has_block_cursor) cursor_fg else info.fg,
                            .needs_decorations = info.needs_decorations,
                        }
                    else {
                        self.flushQueuedRun(.raster, run_buf, &run, row.py);
                        continue;
                    };
                    if (!self.ligatures or !isLigatureCandidate(cps[0..grapheme_len])) {
                        self.flushQueuedRun(.raster, run_buf, &run, row.py);
                        if (firstRenderableCodepoint(glyph_utf8)) |cp| {
                            if (isSynthesizedTerminalCodepoint(cp)) continue;
                        }
                        if (self.prepareGlyphs(glyph_utf8, text_style.face_idx, .terminal)) |prepared| {
                            self.recordShapedRun(glyph_utf8, text_style.face_idx, prepared.start, prepared.glyphs.len);
                        }
                        continue;
                    }
                    self.appendQueuedRun(.raster, run_buf, glyph_utf8, col_x, text_style.face_idx, text_style.fg, &run, row.py);
                },
                else => self.flushQueuedRun(.raster, run_buf, &run, row.py),
            }
        }
        self.flushQueuedRun(.raster, run_buf, &run, row.py);
    }

    fn queueGlyphPass(
        self: *FtRenderer,
        runtime: *ghostty.Runtime,
        queue: *const QueueContext,
        hash_skip_bits: *const HashSkipBits,
        run_buf: []u8,
    ) Pass2Stats {
        var stats = Pass2Stats{};
        if (!queue.helpersReady()) return stats;
        if (!runtime.populateRowIterator(queue.render_state, queue.row_iterator)) return stats;

        var row_y: usize = 0;
        while (runtime.nextRow(queue.row_iterator.*)) : (row_y += 1) {
            const row_is_dirty = queue.force_full or runtime.rowDirty(queue.row_iterator.*) or row_y == queue.prev_cursor_row or row_y == queue.cursor_row;
            if (!row_is_dirty) {
                self.last_rows_skipped += 1;
                continue;
            }
            if (skipSetGet(hash_skip_bits, row_y) and row_y != queue.prev_cursor_row and row_y != queue.cursor_row) {
                self.last_rows_skipped += 1;
                continue;
            }

            self.last_rows_rendered += 1;
            if (!runtime.populateRowCells(queue.row_iterator.*, queue.row_cells)) {
                if (!queue.force_full) runtime.clearRowDirty(queue.row_iterator.*);
                continue;
            }

            const row = self.makeRowRenderInfo(queue, row_y);
            self.queueGlyphRow(runtime, queue, row, run_buf, &stats);
            self.queueCursorShapeRow(queue, row, run_buf);
            if (!queue.force_full) runtime.clearRowDirty(queue.row_iterator.*);
        }

        return stats;
    }

    fn queueGlyphRow(
        self: *FtRenderer,
        runtime: *ghostty.Runtime,
        queue: *const QueueContext,
        row: RowRenderInfo,
        run_buf: []u8,
        stats: *Pass2Stats,
    ) void {
        const row_glyph_start_ns = if (queue.cfg.debug_overlay) std.time.nanoTimestamp() else 0;
        var row_needs_decorations = queue.hovered_row == row.row_y;
        var col_x: usize = 0;
        var col_px = self.padding_x;
        var run = GlyphRunState{ .fg = queue.colors.default_fg };
        const has_selection = row.selection != null;
        var last_style_id: u16 = 0;
        var last_style_selected = false;
        var last_style_valid = false;
        var last_style_info: CachedStyleInfo = undefined;
        while (runtime.nextCell(queue.row_cells.*)) : ({
            col_x += 1;
            col_px += self.cell_w;
        }) {
            const raw_cell = runtime.cellRaw(queue.row_cells.*);
            const content_tag = runtime.cellContentTagRaw(raw_cell);
            const style_id = runtime.cellStyleIdRaw(raw_cell);
            const is_selected = has_selection and isSelectedCell(row.selection, col_x);
            const cached_style = if (style_id != 0) blk: {
                if (last_style_valid and last_style_id == style_id and last_style_selected == is_selected) {
                    break :blk &last_style_info;
                }
                const info = self.resolveCachedStyle(runtime, queue.row_cells.*, style_id, is_selected, queue.colors.default_fg, queue.colors.default_bg, queue.colors.selection_fg, queue.colors.palette) orelse break :blk null;
                last_style_info = info.*;
                last_style_id = style_id;
                last_style_selected = is_selected;
                last_style_valid = true;
                break :blk &last_style_info;
            } else null;
            const has_cursor = if (row.cursor_col) |cursor_col| col_x == cursor_col else false;
            const has_block_cursor = has_cursor and (queue.cursor_style == .block or (queue.cursor_style == null and queue.pane != null and queue.app.copyModeActiveForPane(queue.pane.?)));

            switch (content_tag) {
                .codepoint => {
                    const cp = runtime.cellCodepointRaw(raw_cell);
                    if (cp == 0) {
                        self.flushQueuedRun(.draw, run_buf, &run, row.py);
                        continue;
                    }
                    const cursor_fg = if (has_block_cursor and !(queue.cfg.terminal_theme.enabled and queue.cfg.terminal_theme.cursor_fg != null))
                        runtime.cellBackground(queue.row_cells.*) orelse queue.colors.cursor_fg
                    else
                        queue.colors.cursor_fg;
                    const text_style = if (style_id == 0)
                        CellTextStyle{
                            .face_idx = 0,
                            .fg = if (is_selected)
                                queue.colors.selection_fg
                            else if (has_block_cursor)
                                cursor_fg
                            else
                                queue.colors.default_fg,
                        }
                    else if (cached_style) |info|
                        CellTextStyle{
                            .face_idx = info.face_idx,
                            .fg = if (has_block_cursor) cursor_fg else info.fg,
                            .needs_decorations = info.needs_decorations,
                        }
                    else {
                        self.flushQueuedRun(.draw, run_buf, &run, row.py);
                        continue;
                    };
                    if (text_style.needs_decorations) row_needs_decorations = true;
                    if (!self.ligatures or !isLigatureCodepoint(cp)) {
                        self.flushQueuedRun(.draw, run_buf, &run, row.py);
                        self.last_glyph_runs += 1;
                        if (self.drawSynthesizedBoxGlyph(col_px, row.py, cp, text_style.fg, row.py, row.py + self.cell_h)) {
                            continue;
                        }
                        if (drawSynthesizedTerminalCodepoint(col_px, row.py, self.cell_w, self.cell_h, cp, text_style.fg)) {
                            continue;
                        }
                        if (!self.drawDirectGlyph(col_px, row.py, cp, text_style.face_idx, text_style.fg, row.py, row.py + self.cell_h)) {
                            const glyph_utf8 = self.encodeCodepointUtf8(cp);
                            if (glyph_utf8.len == 0) continue;
                            if (self.consumeShapedRun(glyph_utf8, text_style.face_idx)) |prepared| {
                                self.batchPreparedGlyphs(col_px, row.py, prepared, text_style.fg, row.py, row.py + self.cell_h);
                            } else {
                                self.batchGlyphs(col_px, row.py, glyph_utf8, text_style.face_idx, text_style.fg, .terminal, row.py, row.py + self.cell_h);
                            }
                        }
                        continue;
                    }
                    self.appendQueuedRun(.draw, run_buf, self.encodeCodepointUtf8(cp), col_x, text_style.face_idx, text_style.fg, &run, row.py);
                },
                .codepoint_grapheme => {
                    var cps: [16]u32 = [_]u32{0} ** 16;
                    const grapheme_len = @min(runtime.cellGraphemeLen(queue.row_cells.*), cps.len);
                    const glyph_utf8 = self.encodeCurrentCellGraphemeUtf8(runtime, queue.row_cells.*, &cps) orelse {
                        self.flushQueuedRun(.draw, run_buf, &run, row.py);
                        continue;
                    };
                    const cursor_fg = if (has_block_cursor and !(queue.cfg.terminal_theme.enabled and queue.cfg.terminal_theme.cursor_fg != null))
                        runtime.cellBackground(queue.row_cells.*) orelse queue.colors.cursor_fg
                    else
                        queue.colors.cursor_fg;
                    const text_style = if (style_id == 0)
                        CellTextStyle{
                            .face_idx = 0,
                            .fg = if (is_selected)
                                queue.colors.selection_fg
                            else if (has_block_cursor)
                                cursor_fg
                            else
                                queue.colors.default_fg,
                        }
                    else if (cached_style) |info|
                        CellTextStyle{
                            .face_idx = info.face_idx,
                            .fg = if (has_block_cursor) cursor_fg else info.fg,
                            .needs_decorations = info.needs_decorations,
                        }
                    else {
                        self.flushQueuedRun(.draw, run_buf, &run, row.py);
                        continue;
                    };
                    if (text_style.needs_decorations) row_needs_decorations = true;
                    if (!self.ligatures or !isLigatureCandidate(cps[0..grapheme_len])) {
                        self.flushQueuedRun(.draw, run_buf, &run, row.py);
                        const px = self.columnPixelX(col_x, queue.col_count);
                        self.last_glyph_runs += 1;
                        if (self.drawSynthesizedBoxUtf8(px, row.py, glyph_utf8, text_style.fg, row.py, row.py + self.cell_h)) {
                            continue;
                        }
                        if (drawSynthesizedTerminalUtf8(px, row.py, self.cell_w, self.cell_h, glyph_utf8, text_style.fg)) {
                            continue;
                        }
                        if (self.consumeShapedRun(glyph_utf8, text_style.face_idx)) |prepared| {
                            self.batchPreparedGlyphs(px, row.py, prepared, text_style.fg, row.py, row.py + self.cell_h);
                        } else {
                            self.batchGlyphs(px, row.py, glyph_utf8, text_style.face_idx, text_style.fg, .terminal, row.py, row.py + self.cell_h);
                        }
                        continue;
                    }
                    self.appendQueuedRun(.draw, run_buf, glyph_utf8, col_x, text_style.face_idx, text_style.fg, &run, row.py);
                },
                else => self.flushQueuedRun(.draw, run_buf, &run, row.py),
            }
        }
        self.flushQueuedRun(.draw, run_buf, &run, row.py);
        if (queue.cfg.debug_overlay) stats.glyph_ns += std.time.nanoTimestamp() - row_glyph_start_ns;

        const row_decoration_start_ns = if (queue.cfg.debug_overlay) std.time.nanoTimestamp() else 0;
        if (row_needs_decorations) self.drawRowDecorations(runtime, queue, row);
        if (queue.cfg.debug_overlay) stats.decoration_ns += std.time.nanoTimestamp() - row_decoration_start_ns;
    }

    fn queueCursorShapeRow(self: *FtRenderer, queue: *const QueueContext, row: RowRenderInfo, run_buf: []u8) void {
        _ = run_buf;
        const cursor_style = queue.cursor_style orelse return;
        if (cursor_style == .block) return;
        const cursor_col = row.cursor_col orelse return;

        const cursor_width = if (row.cursor_wide and cursor_style != .bar) self.cell_w * 2.0 else self.cell_w;
        const px = self.columnPixelX(cursor_col, queue.col_count);
        c.sgl_load_default_pipeline();
        drawCursor(px, row.py, cursor_width, self.cell_h, queue.colors.cursor_bg, cursor_style);
    }

    fn drawRowDecorations(
        self: *FtRenderer,
        runtime: *ghostty.Runtime,
        queue: *const QueueContext,
        row: RowRenderInfo,
    ) void {
        if (!queue.helpersReady()) return;
        if (!runtime.populateRowCells(queue.row_iterator.*, queue.row_cells)) return;

        var dec_col_x: usize = 0;
        var dec_px = self.padding_x;
        var dec_quads_open = false;
        var last_style_id: u16 = 0;
        var last_style_selected = false;
        var last_style_valid = false;
        var last_style_info: CachedStyleInfo = undefined;
        while (runtime.nextCell(queue.row_cells.*)) : ({
            dec_col_x += 1;
            dec_px += self.cell_w;
        }) {
            const raw_cell = runtime.cellRaw(queue.row_cells.*);
            const hovered_link_visual = if (queue.hovered_hyperlink) |hovered|
                hovered.row == row.row_y and dec_col_x >= hovered.start_col and dec_col_x < hovered.end_col
            else
                false;
            const style_id = runtime.cellStyleIdRaw(raw_cell);
            if (style_id == 0 and !hovered_link_visual) continue;

            const is_selected = isSelectedCell(row.selection, dec_col_x);
            const cached_style = if (style_id != 0) blk: {
                if (last_style_valid and last_style_id == style_id and last_style_selected == is_selected) {
                    break :blk &last_style_info;
                }
                const info = self.resolveCachedStyle(runtime, queue.row_cells.*, style_id, is_selected, queue.colors.default_fg, queue.colors.default_bg, queue.colors.selection_fg, queue.colors.palette) orelse break :blk null;
                last_style_info = info.*;
                last_style_id = style_id;
                last_style_selected = is_selected;
                last_style_valid = true;
                break :blk &last_style_info;
            } else null;
            if (style_id != 0 and cached_style == null) continue;

            const underline = if (cached_style) |info| info.underline else 0;
            const strikethrough = if (cached_style) |info| info.strikethrough else false;
            const overline = if (cached_style) |info| info.overline else false;
            if (underline == 0 and !strikethrough and !overline and !hovered_link_visual) continue;

            if (!dec_quads_open) {
                c.sgl_load_default_pipeline();
                c.sgl_begin_quads();
                dec_quads_open = true;
            }

            const dec_fg = if (cached_style) |info| info.fg else queue.colors.selection_fg;
            const dec_color = ghostty.resolveStyleColor(
                if (cached_style) |info| info.underline_color else .{ .tag = .none, .value = .{ ._padding = 0 } },
                dec_fg,
                queue.colors.palette,
            );
            const effective_underline: i32 = if (hovered_link_visual and underline == 0) 1 else underline;
            self.emitUnderlineDecoration(dec_px, row.py, effective_underline, dec_color.r, dec_color.g, dec_color.b);

            if (strikethrough) {
                const thickness: f32 = 1.0;
                const st_y = row.py + self.cell_h * 0.5 - 0.5;
                emitRect(dec_px, st_y, self.cell_w, thickness, dec_fg.r, dec_fg.g, dec_fg.b, 255);
            }

            if (overline) {
                emitRect(dec_px, row.py, self.cell_w, 1.0, dec_fg.r, dec_fg.g, dec_fg.b, 255);
            }
        }
        if (dec_quads_open) c.sgl_end();
    }

    fn emitUnderlineDecoration(self: *FtRenderer, x: f32, y: f32, underline: i32, r: u8, g: u8, b: u8) void {
        const thickness: f32 = 1.0;
        const ul_y = y + self.cell_h - thickness - 1.0;
        switch (underline) {
            0 => {},
            1 => emitRect(x, ul_y, self.cell_w, thickness, r, g, b, 255),
            2 => {
                emitRect(x, ul_y - 2.0, self.cell_w, thickness, r, g, b, 255);
                emitRect(x, ul_y, self.cell_w, thickness, r, g, b, 255);
            },
            3 => {
                const n_segs: usize = 8;
                const seg_w = self.cell_w / @as(f32, @floatFromInt(n_segs));
                const amp: f32 = 1.0;
                const base_y = ul_y + amp;
                var seg: usize = 0;
                while (seg < n_segs) : (seg += 1) {
                    const t = @as(f32, @floatFromInt(seg)) / @as(f32, @floatFromInt(n_segs));
                    const t1 = @as(f32, @floatFromInt(seg + 1)) / @as(f32, @floatFromInt(n_segs));
                    const sx0 = x + t * self.cell_w;
                    const sy0 = base_y - amp * @sin(t * std.math.tau);
                    const sy1 = base_y - amp * @sin(t1 * std.math.tau);
                    const seg_h = @abs(sy1 - sy0) + thickness;
                    const seg_y = @min(sy0, sy1);
                    emitRect(sx0, seg_y, seg_w, seg_h, r, g, b, 255);
                }
            },
            4 => {
                var dot_x = x;
                const dot_w: f32 = 1.0;
                const gap: f32 = 2.0;
                while (dot_x + dot_w <= x + self.cell_w) : (dot_x += dot_w + gap) {
                    emitRect(dot_x, ul_y, dot_w, thickness, r, g, b, 255);
                }
            },
            5 => {
                var dash_x = x;
                const dash_w: f32 = 4.0;
                const dash_gap: f32 = 2.0;
                while (dash_x + dash_w <= x + self.cell_w) : (dash_x += dash_w + dash_gap) {
                    emitRect(dash_x, ul_y, dash_w, thickness, r, g, b, 255);
                }
            },
            else => emitRect(x, ul_y, self.cell_w, thickness, r, g, b, 255),
        }
    }

    fn shouldSkipRowByHash(
        self: *FtRenderer,
        runtime: *ghostty.Runtime,
        queue: *const QueueContext,
        row_y: usize,
        hash_skip_bits: *HashSkipBits,
    ) bool {
        _ = self;
        if (!queue.useRowMap() or row_y == queue.cursor_row or row_y == queue.prev_cursor_row) return false;

        const row_raw = runtime.rowRaw(queue.row_iterator.*);
        if (row_raw == 0) return false;

        const keys = queue.row_map_keys.?;
        const vals = queue.row_map_vals.?;
        const slot = rowMapProbe(keys, row_raw);
        if (runtime.rowHashCells(queue.row_iterator.*, queue.row_cells)) |new_hash| {
            if (queue.row_map_skip and new_hash != 0 and keys[slot] == row_raw and vals[slot] == new_hash) {
                skipSetSet(hash_skip_bits, row_y);
                return true;
            }
            keys[slot] = row_raw;
            vals[slot] = new_hash;
        }
        return false;
    }

    fn queueCellBackground(
        self: *FtRenderer,
        runtime: *ghostty.Runtime,
        queue: *const QueueContext,
        row: RowRenderInfo,
        content_tag: ghostty.CellContentTag,
        style_id: u16,
        cached_style: ?*const CachedStyleInfo,
        is_selected: bool,
        col_px: f32,
        py: f32,
        quads_open: *bool,
    ) void {
        const is_bg_tag = content_tag == .bg_color_palette or content_tag == .bg_color_rgb;
        if (is_selected) {
            self.last_bg_rects += 1;
            self.openQuadBatch(quads_open);
            c.sgl_c4b(queue.colors.selection_bg.r, queue.colors.selection_bg.g, queue.colors.selection_bg.b, 255);
            c.sgl_v2f(col_px, py);
            c.sgl_v2f(col_px + self.cell_w, py);
            c.sgl_v2f(col_px + self.cell_w, py + self.cell_h);
            c.sgl_v2f(col_px, py + self.cell_h);
            return;
        }

        if (row.search_highlight) |highlight| {
            if (highlight.start_col <= highlight.end_col and col_px >= self.padding_x + @as(f32, @floatFromInt(highlight.start_col)) * self.cell_w and col_px < self.padding_x + @as(f32, @floatFromInt(highlight.end_col)) * self.cell_w) {
                const bg = if (highlight.active) queue.colors.search_active_bg else queue.colors.search_bg;
                self.last_bg_rects += 1;
                self.openQuadBatch(quads_open);
                c.sgl_c4b(bg.r, bg.g, bg.b, 255);
                c.sgl_v2f(col_px, py);
                c.sgl_v2f(col_px + self.cell_w, py);
                c.sgl_v2f(col_px + self.cell_w, py + self.cell_h);
                c.sgl_v2f(col_px, py + self.cell_h);
                return;
            }
        }

        if (queue.cursor_style == .block or (queue.cursor_style == null and queue.pane != null and queue.app.copyModeActiveForPane(queue.pane.?))) {
            if (row.cursor_col) |cursor_col| {
                const cursor_end = cursor_col + (if (row.cursor_wide) @as(usize, 2) else 1);
                if (col_px >= self.padding_x + @as(f32, @floatFromInt(cursor_col)) * self.cell_w and col_px < self.padding_x + @as(f32, @floatFromInt(cursor_end)) * self.cell_w) {
                    const cursor_bg = if (queue.cfg.terminal_theme.enabled and queue.cfg.terminal_theme.cursor != null)
                        queue.colors.cursor_bg
                    else
                        runtime.cellForeground(queue.row_cells.*) orelse queue.colors.cursor_bg;
                    self.last_bg_rects += 1;
                    self.openQuadBatch(quads_open);
                    c.sgl_c4b(cursor_bg.r, cursor_bg.g, cursor_bg.b, 255);
                    c.sgl_v2f(col_px, py);
                    c.sgl_v2f(col_px + self.cell_w, py);
                    c.sgl_v2f(col_px + self.cell_w, py + self.cell_h);
                    c.sgl_v2f(col_px, py + self.cell_h);
                    return;
                }
            }
        }

        if (!is_bg_tag and style_id == 0) return;
        const bg: ghostty.ColorRgb = if (!is_bg_tag and style_id != 0)
            if (cached_style) |style|
                style.bg
            else if (self.resolveCachedStyle(runtime, queue.row_cells.*, style_id, is_selected, queue.colors.default_fg, queue.colors.default_bg, queue.colors.selection_fg, queue.colors.palette)) |style|
                style.bg
            else
                runtime.cellBackground(queue.row_cells.*) orelse queue.colors.default_bg
        else
            runtime.cellBackground(queue.row_cells.*) orelse queue.colors.default_bg;
        if (colorsEqual(bg, queue.colors.default_bg)) return;

        self.last_bg_rects += 1;
        self.openQuadBatch(quads_open);
        c.sgl_c4b(bg.r, bg.g, bg.b, 255);
        c.sgl_v2f(col_px, py);
        c.sgl_v2f(col_px + self.cell_w, py);
        c.sgl_v2f(col_px + self.cell_w, py + self.cell_h);
        c.sgl_v2f(col_px, py + self.cell_h);
    }

    inline fn resolveCellTextStyle(
        self: *FtRenderer,
        runtime: *ghostty.Runtime,
        queue: *const QueueContext,
        style_id: u16,
        is_selected: bool,
    ) ?CellTextStyle {
        if (style_id == 0) {
            return .{
                .face_idx = 0,
                .fg = if (is_selected) queue.colors.selection_fg else queue.colors.default_fg,
            };
        }

        var resolved = CellTextStyle{ .face_idx = 0, .fg = queue.colors.default_fg };
        {
            const info = self.resolveCachedStyle(runtime, queue.row_cells.*, style_id, is_selected, queue.colors.default_fg, queue.colors.default_bg, queue.colors.selection_fg, queue.colors.palette) orelse return null;
            resolved.face_idx = info.face_idx;
            resolved.fg = info.fg;
            resolved.needs_decorations = info.needs_decorations;
        }
        return resolved;
    }

    fn makeRowRenderInfo(self: *FtRenderer, queue: *const QueueContext, row_y: usize) RowRenderInfo {
        const row_y_px = if (builtin.os.tag == .linux and queue.row_count > 0)
            @as(f32, @floatFromInt((queue.row_count - 1) - row_y)) * self.cell_h
        else
            @as(f32, @floatFromInt(row_y)) * self.cell_h;
        return .{
            .row_y = row_y,
            .py = self.padding_y + row_y_px,
            .selection = if (queue.selection_range) |range| rowSelectionBounds(range, row_y) else null,
            .search_highlight = if (queue.pane) |pane| queue.app.searchHighlightForRow(pane, row_y) else null,
            .cursor_col = if (queue.pane) |pane|
                queue.app.copyModeCursorColForRow(pane, row_y) orelse
                    if (!queue.app.copyModeActiveForPane(pane) and row_y == queue.cursor_row)
                        queue.cursor_col -| @intFromBool(queue.cursor_wide)
                    else
                        null
            else if (row_y == queue.cursor_row)
                queue.cursor_col -| @intFromBool(queue.cursor_wide)
            else
                null,
            .cursor_wide = row_y == queue.cursor_row and queue.cursor_wide,
        };
    }

    fn encodeCodepointUtf8(self: *FtRenderer, cp: u32) []const u8 {
        const glyph_len: usize = encodeUtf8(cp, &self.glyph_buf) catch 0;
        return self.glyph_buf[0..glyph_len];
    }

    fn encodeCurrentCellGraphemeUtf8(self: *FtRenderer, runtime: *ghostty.Runtime, row_cells: ?*anyopaque, cps: *[16]u32) ?[]const u8 {
        const grapheme_len = @min(runtime.cellGraphemeLen(row_cells), cps.len);
        if (grapheme_len == 0) return null;

        cps.* = [_]u32{0} ** 16;
        runtime.cellGraphemes(row_cells, cps);
        var glyph_len: usize = 0;
        for (cps[0..grapheme_len]) |cp| {
            if (cp == 0) break;
            glyph_len += encodeUtf8(cp, self.glyph_buf[glyph_len..]) catch break;
        }
        if (glyph_len == 0) return null;
        return self.glyph_buf[0..glyph_len];
    }

    inline fn appendQueuedRun(
        self: *FtRenderer,
        mode: GlyphRunMode,
        run_buf: []u8,
        utf8: []const u8,
        col_x: usize,
        face_idx: u8,
        fg: ghostty.ColorRgb,
        run: *GlyphRunState,
        py: f32,
    ) void {
        if (utf8.len == 0) {
            self.flushQueuedRun(mode, run_buf, run, py);
            return;
        }

        const next_len = run.len + utf8.len;
        const same_style = run.face_idx == face_idx and colorsEqual(run.fg, fg);
        if (run.len != 0 and same_style and next_len <= run_buf.len) {
            copyUtf8Inline(run_buf[run.len..next_len], utf8);
            run.len = next_len;
            return;
        }

        if (next_len > run_buf.len) self.flushQueuedRun(mode, run_buf, run, py);
        if (run.len > 0 and !same_style) {
            self.flushQueuedRun(mode, run_buf, run, py);
        }
        if (run.len == 0) {
            run.start_col = col_x;
            run.face_idx = face_idx;
            run.fg = fg;
        }
        copyUtf8Inline(run_buf[run.len .. run.len + utf8.len], utf8);
        run.len += utf8.len;
    }

    inline fn copyUtf8Inline(dst: []u8, src: []const u8) void {
        switch (src.len) {
            0 => {},
            1 => dst[0] = src[0],
            2 => {
                dst[0] = src[0];
                dst[1] = src[1];
            },
            3 => {
                dst[0] = src[0];
                dst[1] = src[1];
                dst[2] = src[2];
            },
            4 => {
                dst[0] = src[0];
                dst[1] = src[1];
                dst[2] = src[2];
                dst[3] = src[3];
            },
            else => fastmem.copy(u8, dst, src),
        }
    }

    inline fn flushQueuedRun(self: *FtRenderer, mode: GlyphRunMode, run_buf: []u8, run: *GlyphRunState, py: f32) void {
        switch (mode) {
            .raster => flushRasterRun(self, run_buf, &run.start_col, &run.len, run.face_idx, run.fg, py),
            .draw => flushDrawRun(self, run_buf, &run.start_col, &run.len, run.face_idx, run.fg, py),
        }
    }

    fn columnPixelX(self: *FtRenderer, col_x: usize, col_count: usize) f32 {
        const col_x_px = if (builtin.os.tag == .linux and col_count > 0)
            @as(f32, @floatFromInt((col_count - 1) - col_x)) * self.cell_w
        else
            @as(f32, @floatFromInt(col_x)) * self.cell_w;
        return self.padding_x + col_x_px;
    }

    inline fn openQuadBatch(self: *FtRenderer, quads_open: *bool) void {
        _ = self;
        if (quads_open.*) return;
        c.sgl_begin_quads();
        quads_open.* = true;
    }

    inline fn isSelectedCell(row_selection: ?RowSelectionBounds, col_x: usize) bool {
        return if (row_selection) |selection_bounds|
            col_x >= selection_bounds.start_col and col_x <= selection_bounds.end_col
        else
            false;
    }

    inline fn skipSetSet(bits: *HashSkipBits, row: usize) void {
        if (row >= HASH_SKIP_MAX_ROWS) return;
        bits[row / 64] |= @as(u64, 1) << @intCast(row % 64);
    }

    inline fn skipSetGet(bits: *const HashSkipBits, row: usize) bool {
        if (row >= HASH_SKIP_MAX_ROWS) return false;
        return (bits[row / 64] >> @intCast(row % 64)) & 1 != 0;
    }

    fn rowMapProbe(keys: []u64, key: u64) usize {
        const cap = keys.len;
        const mask = cap - 1;
        var idx = @as(usize, @truncate(key)) & mask;
        var i: usize = 0;
        while (i < cap) : (i += 1) {
            const existing = keys[idx];
            if (existing == 0 or existing == key) return idx;
            idx = (idx + 1) & mask;
        }
        return 0;
    }

    /// Pre-rasterize glyphs for a cell to ensure they are in the atlas.
    fn preRasterize(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode) void {
        const result = self.getOrShape(utf8, face_idx) orelse return;
        self.preRasterizeShaped(result, raster_mode);
    }

    fn preRasterizeShaped(self: *FtRenderer, result: ShapeResult, raster_mode: RasterMode) void {
        for (result.glyphs) |glyph_inst| {
            _ = self.getOrRasterize(glyph_inst.glyph_id, result.raster_face_index, raster_mode);
        }
    }

    fn prepareGlyphs(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode) ?PreparedRun {
        if (self.getPreparedCache(utf8, face_idx, raster_mode)) |prepared| return prepared;
        const result = self.getOrShape(utf8, face_idx) orelse return null;
        const prepared = self.prepareShapedGlyphs(result, raster_mode) orelse return null;
        self.putPreparedCache(utf8, face_idx, raster_mode, prepared.glyphs);
        return prepared;
    }

    fn prepareShapedGlyphs(self: *FtRenderer, result: ShapeResult, raster_mode: RasterMode) ?PreparedRun {
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

    /// Shape and batch glyphs for one cell at (px, py).
    fn batchGlyphs(self: *FtRenderer, px: f32, py: f32, utf8: []const u8, face_idx: u8, fg: ghostty.ColorRgb, raster_mode: RasterMode, clip_y0: f32, clip_y1: f32) void {
        const result = self.getOrShape(utf8, face_idx) orelse return;
        self.batchGlyphsShaped(px, py, result, fg, raster_mode, clip_y0, clip_y1);
    }

    fn batchGlyphsShaped(self: *FtRenderer, px: f32, py: f32, result: ShapeResult, fg: ghostty.ColorRgb, raster_mode: RasterMode, clip_y0: f32, clip_y1: f32) void {
        var x_offset: f32 = 0;
        for (result.glyphs) |glyph_inst| {
            const glyph = self.getOrRasterize(glyph_inst.glyph_id, result.raster_face_index, raster_mode) orelse continue;
            self.emitPreparedGlyph(px, py, &x_offset, glyph_inst, glyph, fg, clip_y0, clip_y1);
        }
    }

    fn batchPreparedGlyphs(self: *FtRenderer, px: f32, py: f32, glyphs: []const PreparedGlyph, fg: ghostty.ColorRgb, clip_y0: f32, clip_y1: f32) void {
        var x_offset: f32 = 0;
        for (glyphs) |prepared| {
            self.emitPreparedGlyph(px, py, &x_offset, prepared.inst, prepared.glyph, fg, clip_y0, clip_y1);
        }
    }

    inline fn emitPreparedGlyph(self: *FtRenderer, px: f32, py: f32, x_offset: *f32, glyph_inst: GlyphInstance, glyph: Glyph, fg: ghostty.ColorRgb, clip_y0: f32, clip_y1: f32) void {
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
    inline fn drawDirectGlyph(self: *FtRenderer, px: f32, py: f32, cp: u32, face_idx: u8, fg: ghostty.ColorRgb, clip_y0: f32, clip_y1: f32) bool {
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

    inline fn batchDirectGlyphSgl(self: *FtRenderer, px: f32, py: f32, cp: u32, face_idx: u8, fg: ghostty.ColorRgb, raster_mode: RasterMode) bool {
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

    inline fn directGlyph(self: *FtRenderer, cp: u32, face_idx: u8) ?Glyph {
        return self.directGlyphForMode(cp, face_idx, .terminal);
    }

    inline fn directGlyphForMode(self: *FtRenderer, cp: u32, face_idx: u8, raster_mode: RasterMode) ?Glyph {
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
    inline fn emitGlyphQuad(
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
            0.0,  0.0, 1.0, 0.0,
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

    inline fn flushRasterRun(self: *FtRenderer, run_buf: []u8, run_start_col: *usize, run_len: *usize, face_idx: u8, fg: ghostty.ColorRgb, py: f32) void {
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

    inline fn flushDrawRun(self: *FtRenderer, run_buf: []u8, run_start_col: *usize, run_len: *usize, face_idx: u8, fg: ghostty.ColorRgb, py: f32) void {
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

    fn recordShapedRun(self: *FtRenderer, utf8: []const u8, face_idx: u8, prepared_start: usize, prepared_len: usize) void {
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

    fn getPreparedCache(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode) ?PreparedRun {
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

    fn appendPreparedRun(self: *FtRenderer, glyphs: []const PreparedGlyph) ?PreparedRun {
        const prepared_start = self.prepared_glyphs.items.len;
        self.prepared_glyphs.appendSlice(self.allocator, glyphs) catch return null;
        return .{ .start = prepared_start, .glyphs = self.prepared_glyphs.items[prepared_start..][0..glyphs.len] };
    }

    inline fn styleCacheReset(self: *FtRenderer) void {
        @memset(&self.style_cache, null);
    }

    inline fn resolveCachedStyle(self: *FtRenderer, runtime: *ghostty.Runtime, row_cells: ?*anyopaque, style_id: u16, selected: bool, default_fg: ghostty.ColorRgb, default_bg: ghostty.ColorRgb, selection_fg: ghostty.ColorRgb, palette: *const [256]ghostty.ColorRgb) ?*const CachedStyleInfo {
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

    inline fn styleCacheSlot(self: *FtRenderer, style_id: u16, selected: bool) usize {
        _ = self;
        const key: u32 = (@as(u32, style_id) << 1) | @intFromBool(selected);
        return key & (STYLE_CACHE_SIZE - 1);
    }

    fn putPreparedCache(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode, glyphs: []const PreparedGlyph) void {
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

    fn makePreparedKey(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode) PreparedKey {
        var key: PreparedKey = undefined;
        key.len = @intCast(utf8.len);
        key.face_idx = face_idx;
        key.ligatures = self.ligatures;
        key.raster_mode = raster_mode;
        fastmem.copy(u8, key.text[0..utf8.len], utf8);
        return key;
    }

    fn getRecentPrepared(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode, fingerprint: u64) ?[]PreparedGlyph {
        const slot_idx: usize = @intCast(fingerprint & (RECENT_PREPARED_CACHE_LEN - 1));
        const recent = self.recent_prepared[slot_idx] orelse return null;
        if (recent.fingerprint != fingerprint) return null;
        if (recent.key.face_idx != face_idx or recent.key.ligatures != self.ligatures or recent.key.raster_mode != raster_mode or recent.key.len != utf8.len) return null;
        if (!std.mem.eql(u8, recent.key.text[0..utf8.len], utf8)) return null;
        return recent.glyphs;
    }

    fn putRecentPrepared(self: *FtRenderer, key: PreparedKey, fingerprint: u64, glyphs: []PreparedGlyph) void {
        const slot_idx: usize = @intCast(fingerprint & (RECENT_PREPARED_CACHE_LEN - 1));
        self.recent_prepared[slot_idx] = .{ .fingerprint = fingerprint, .key = key, .glyphs = glyphs };
    }

    fn preparedFingerprint(utf8: []const u8, face_idx: u8, ligatures: bool, raster_mode: RasterMode) u64 {
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

    fn consumeShapedRun(self: *FtRenderer, utf8: []const u8, face_idx: u8) ?[]const PreparedGlyph {
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

    inline fn isAsciiFastPathCandidate(cp: u32, face_idx: u8) bool {
        if (cp < 0x21 or cp > 0xFF or face_idx > 3) return false;
        if (cp > 0x7E and cp < 0xA0) return false;
        return true;
    }

    fn getOrShape(self: *FtRenderer, utf8: []const u8, face_idx: u8) ?ShapeResult {
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

    /// Returns a cached Glyph, rasterizing it into the atlas if needed.
    fn getOrRasterize(self: *FtRenderer, glyph_id: u32, raster_face_index: u8, raster_mode: RasterMode) ?Glyph {
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
        self.atlas_uploaded_this_frame = false;
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

    /// Call once at the start of each frame to allow atlas upload for that frame.
    pub fn beginFrame(self: *FtRenderer) void {
        self.atlas_uploaded_this_frame = false;
        self.uploaded_glyph_verts = 0;
    }

    /// Upload atlas to GPU if it has been modified and not yet uploaded this frame.
    /// Safe to call multiple times per frame — only the first call uploads.
    pub fn flushAtlasIfDirty(self: *FtRenderer) void {
        if (self.atlas_dirty) {
            self.flushAtlas();
            self.atlas_dirty = false;
        }
    }

    pub fn flushAtlas(self: *FtRenderer) void {
        if (self.atlas_uploaded_this_frame) return;
        // sg_update_image requires the size to cover the entire image — partial
        // uploads are not supported by Sokol and cause a validation crash.
        var upd = std.mem.zeroes(c.sg_image_data);
        upd.mip_levels[0].ptr = self.atlas_data.ptr;
        upd.mip_levels[0].size = ATLAS_W * ATLAS_H * ATLAS_BPP;
        c.sg_update_image(self.atlas_img, &upd);
        self.atlas_uploaded_this_frame = true;
        // Advance the epoch so per-pane callers can detect atlas changes since
        // their last render and trigger a full redraw only when necessary.
        self.atlas_epoch +%= 1;
    }

    /// Evict the glyph atlas and all caches when the atlas is ≥90% full.
    /// This prevents the "atlas full" hard stop and keeps memory bounded.
    /// All glyphs will be re-rasterized on demand over the next few frames.
    fn resetAtlasIfNeeded(self: *FtRenderer) void {
        // 90% of atlas rows filled.
        if (self.atlas_y < (ATLAS_H * 9) / 10) return;
        std.log.info("ft_renderer: atlas ≥90% full at row {d}/{d}, evicting (frame {d})", .{
            self.atlas_y, ATLAS_H, self.frame_count,
        });
        // Clear CPU atlas buffer.
        @memset(self.atlas_data, 0);
        // Reset packing cursor.
        self.atlas_x = 1;
        self.atlas_y = 1;
        self.atlas_row_h = 0;
        self.atlas_dirty = true;
        self.atlas_uploaded_this_frame = false;
        // Evict glyph and shape caches so entries pointing to old atlas UVs
        // are not used.
        self.glyph_cache.clearRetainingCapacity();
        self.shape_cache.clearRetainingCapacity();
        var prepared_it = self.prepared_cache.valueIterator();
        while (prepared_it.next()) |val| {
            self.allocator.free(val.glyphs);
        }
        self.prepared_cache.clearRetainingCapacity();
        self.recent_prepared = [_]?RecentPreparedEntry{null} ** RECENT_PREPARED_CACHE_LEN;
        // Clear ASCII/Latin-1 fast-path cache (UVs are now stale).
        self.ascii_glyphs = [_][256]?Glyph{[_]?Glyph{null} ** 256} ** 4;
    }

    fn boostCoverage(self: *const FtRenderer, cov: u8) u8 {
        if (cov == 0 or cov == 255) return cov;
        const boosted = @as(f32, @floatFromInt(cov)) * self.coverage_boost + self.coverage_add;
        return @intFromFloat(@min(255.0, boosted));
    }

    fn loadFlagsForRasterMode(self: *const FtRenderer, use_subpixel: bool) c_int {
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

    const SelectedShapeFont = struct {
        hb_font: ?*ft.hb_font_t,
        raster_face_index: u8,
    };

    fn selectShapeFont(self: *FtRenderer, utf8: []const u8, face_idx: u8) SelectedShapeFont {
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

    fn faceForRasterIndex(self: *FtRenderer, raster_face_index: u8) ?ft.FT_Face {
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

    fn hbFontForRasterIndex(self: *FtRenderer, raster_face_index: u8) ?*ft.hb_font_t {
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

    fn emboldenForRasterFace(self: *const FtRenderer, raster_face_index: u8) f32 {
        return switch (raster_face_index) {
            0 => self.regular_embolden orelse self.embolden,
            1 => self.bold_embolden orelse self.embolden,
            2 => self.bold_italic_embolden orelse self.embolden,
            3 => self.italic_embolden orelse self.embolden,
            else => self.embolden,
        };
    }

    const SYNTHETIC_FACE: u8 = 250;

    /// Render a box-drawing character (U+2500-U+257F) to the atlas
    /// and return a cached Glyph. Returns null on OOM / atlas-full.
    fn ensureSynthesizedBoxGlyph(self: *FtRenderer, cp: u32) ?Glyph {
        if (!isBoxDrawingCodepoint(cp)) return null;
        if (isRoundedArcCodepoint(cp)) return self.ensureSynthesizedRoundedArcGlyph(cp);

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

        // Pack into atlas (same logic as getOrRasterize).
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
        self.atlas_dirty = true;
        self.atlas_uploaded_this_frame = false;
        if (bh > self.atlas_row_h) self.atlas_row_h = bh;

        const s0 = @as(f32, @floatFromInt(self.atlas_x)) / @as(f32, @floatFromInt(ATLAS_W));
        const t0 = @as(f32, @floatFromInt(self.atlas_y)) / @as(f32, @floatFromInt(ATLAS_H));
        const s1 = @as(f32, @floatFromInt(self.atlas_x + bw)) / @as(f32, @floatFromInt(ATLAS_W));
        const t1 = @as(f32, @floatFromInt(self.atlas_y + bh)) / @as(f32, @floatFromInt(ATLAS_H));

        self.atlas_x += bw + 1;

        const g = Glyph{
            .s0 = s0, .t0 = t0, .s1 = s1, .t1 = t1,
            .bw = @intCast(bw), .bh = @intCast(bh),
            .bear_x = 0, .bear_y = @intFromFloat(@ceil(self.ascender)),
            .advance_x = self.cell_w,
            .color_emoji = false,
        };
        self.glyph_cache.put(key, g) catch {};
        return g;
    }

    fn ensureSynthesizedRoundedArcGlyph(self: *FtRenderer, cp: u32) ?Glyph {
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
                pts[npts] = .{ .x = cx, .y = ch_f }; npts += 1;
                pts[npts] = .{ .x = cx, .y = y1 }; npts += 1;
                var i: usize = 1;
                while (i < segs) : (i += 1) {
                    const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs));
                    const omt = 1.0 - t;
                    const bx = omt * omt * cx + 2.0 * omt * t * cx + t * t * x2;
                    const by = omt * omt * y1 + 2.0 * omt * t * cy + t * t * cy;
                    pts[npts] = .{ .x = bx, .y = by }; npts += 1;
                }
                pts[npts] = .{ .x = x2, .y = cy }; npts += 1;
                pts[npts] = .{ .x = cw_f, .y = cy }; npts += 1;
            },
            0x256E => {
                const y1 = cy + cy / 2.0;
                const x2 = cx - cx / 2.0;
                pts[npts] = .{ .x = cx, .y = ch_f }; npts += 1;
                pts[npts] = .{ .x = cx, .y = y1 }; npts += 1;
                var i: usize = 1;
                while (i < segs) : (i += 1) {
                    const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs));
                    const omt = 1.0 - t;
                    pts[npts] = .{ .x = omt * omt * cx + 2.0 * omt * t * cx + t * t * x2, .y = omt * omt * y1 + 2.0 * omt * t * cy + t * t * cy }; npts += 1;
                }
                pts[npts] = .{ .x = x2, .y = cy }; npts += 1;
                pts[npts] = .{ .x = 0.0, .y = cy }; npts += 1;
            },
            0x256F => {
                const y1 = cy - cy / 2.0;
                const x2 = cx - cx / 2.0;
                pts[npts] = .{ .x = cx, .y = 0.0 }; npts += 1;
                pts[npts] = .{ .x = cx, .y = y1 }; npts += 1;
                var i: usize = 1;
                while (i < segs) : (i += 1) {
                    const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs));
                    const omt = 1.0 - t;
                    pts[npts] = .{ .x = omt * omt * cx + 2.0 * omt * t * cx + t * t * x2, .y = omt * omt * y1 + 2.0 * omt * t * cy + t * t * cy }; npts += 1;
                }
                pts[npts] = .{ .x = x2, .y = cy }; npts += 1;
                pts[npts] = .{ .x = 0.0, .y = cy }; npts += 1;
            },
            0x2570 => {
                const y1 = cy - cy / 2.0;
                const x2 = cx + cx / 2.0;
                pts[npts] = .{ .x = cx, .y = 0.0 }; npts += 1;
                pts[npts] = .{ .x = cx, .y = y1 }; npts += 1;
                var i: usize = 1;
                while (i < segs) : (i += 1) {
                    const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs));
                    const omt = 1.0 - t;
                    pts[npts] = .{ .x = omt * omt * cx + 2.0 * omt * t * cx + t * t * x2, .y = omt * omt * y1 + 2.0 * omt * t * cy + t * t * cy }; npts += 1;
                }
                pts[npts] = .{ .x = x2, .y = cy }; npts += 1;
                pts[npts] = .{ .x = cw_f, .y = cy }; npts += 1;
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
        self.atlas_dirty = true;
        self.atlas_uploaded_this_frame = false;
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
            .bear_x = 0,
            .bear_y = @intFromFloat(@ceil(self.ascender)),
            .advance_x = cw_f,
            .color_emoji = false,
        };
        self.glyph_cache.put(key, g) catch {};
        return g;
    }

    /// Draw a box-drawing character (U+2500-U+257F) from the atlas glyph cache.
    fn drawSynthesizedBoxGlyph(
        self: *FtRenderer,
        px: f32,
        py: f32,
        cp: u32,
        fg: ghostty.ColorRgb,
        clip_y0: f32,
        clip_y1: f32,
    ) bool {
        const glyph = self.ensureSynthesizedBoxGlyph(cp) orelse return false;
        const w = @as(f32, @floatFromInt(glyph.bw));
        const h = @as(f32, @floatFromInt(glyph.bh));
        if (w <= 0 or h <= 0) return false;
        const gx = @round(px);
        const gy = @round(py);
        self.emitGlyphQuad(gx, gy, w, h, glyph.s0, glyph.t0, glyph.s1, glyph.t1, fg, clip_y0, clip_y1, false);
        return true;
    }

    fn drawSynthesizedBoxUtf8(
        self: *FtRenderer,
        px: f32,
        py: f32,
        utf8: []const u8,
        fg: ghostty.ColorRgb,
        clip_y0: f32,
        clip_y1: f32,
    ) bool {
        const cp = firstRenderableCodepoint(utf8) orelse return false;
        return self.drawSynthesizedBoxGlyph(px, py, cp, fg, clip_y0, clip_y1);
    }
};

fn featureTag(tag: [4]u8) u32 {
    return (@as(u32, tag[0]) << 24) |
        (@as(u32, tag[1]) << 16) |
        (@as(u32, tag[2]) << 8) |
        @as(u32, tag[3]);
}

/// Convert a single sRGB channel value [0,1] to linear light.
/// IEC 61966-2-1 piecewise formula (same as the shader).
inline fn srgbToLinear(v: f32) f32 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

/// Convert an sRGB colour (channels in [0,1]) to a linear-premultiplied [4]f32
/// suitable for FsParams.bg_linear.  Alpha is always 1.0 (opaque).
inline fn srgbToLinearBg(r: f32, g: f32, b: f32) [4]f32 {
    return .{ srgbToLinear(r), srgbToLinear(g), srgbToLinear(b), 1.0 };
}

inline fn colorsEqual(a: ghostty.ColorRgb, b: ghostty.ColorRgb) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}

const CURSOR_BLINK_INTERVAL_MS: i128 = 600;

fn blinkVisibleNow(now_ns: i128) bool {
    const now_ms = @divFloor(now_ns, std.time.ns_per_ms);
    const blink_phase = @divFloor(now_ms, CURSOR_BLINK_INTERVAL_MS);
    return @mod(blink_phase, @as(i128, 2)) == 0;
}

fn effectiveCursorStyle(
    runtime: *ghostty.Runtime,
    render_state: ?*anyopaque,
    pane: ?*const Pane,
    app: *const App,
    is_focused: bool,
) ?ghostty.CursorVisualStyle {
    if (pane) |value| {
        if (app.copyModeActiveForPane(value)) return null;
    }
    if (runtime.cursorPos(render_state) == null) return null;
    if (runtime.cursorPasswordInput(render_state)) return .block;
    if (!runtime.cursorVisible(render_state)) return null;
    if (runtime.cursorBlinking(render_state) and !blinkVisibleNow(std.time.nanoTimestamp())) return null;
    if (!is_focused) return app.config.unfocused_pane.cursor;
    return runtime.cursorVisualStyle(render_state);
}

fn contrastTextColor(bg: ghostty.ColorRgb) ghostty.ColorRgb {
    const white = ghostty.ColorRgb{ .r = 255, .g = 255, .b = 255 };
    const black = ghostty.ColorRgb{ .r = 0, .g = 0, .b = 0 };
    return if (contrastRatio(bg, white) >= contrastRatio(bg, black)) white else black;
}

fn effectiveCursorColor(cursor: ghostty.ColorRgb, bg: ghostty.ColorRgb) ghostty.ColorRgb {
    const min_contrast: f32 = 4.5;
    if (contrastRatio(cursor, bg) >= min_contrast) return cursor;
    return contrastTextColor(bg);
}

fn contrastRatio(a: ghostty.ColorRgb, b: ghostty.ColorRgb) f32 {
    const la = relativeLuminance(a);
    const lb = relativeLuminance(b);
    const lighter = @max(la, lb);
    const darker = @min(la, lb);
    return (lighter + 0.05) / (darker + 0.05);
}

fn relativeLuminance(color: ghostty.ColorRgb) f32 {
    const r = srgbToLinear(@as(f32, @floatFromInt(color.r)) / 255.0);
    const g = srgbToLinear(@as(f32, @floatFromInt(color.g)) / 255.0);
    const b = srgbToLinear(@as(f32, @floatFromInt(color.b)) / 255.0);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

const RowSelectionBounds = struct {
    start_col: usize,
    end_col: usize,
};

inline fn rowSelectionBounds(range: selection.Range, row: usize) ?RowSelectionBounds {
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

fn mixColor(a: ghostty.ColorRgb, b: ghostty.ColorRgb, t: f32) ghostty.ColorRgb {
    const clamped = std.math.clamp(t, 0.0, 1.0);
    return .{
        .r = lerpByte(a.r, b.r, clamped),
        .g = lerpByte(a.g, b.g, clamped),
        .b = lerpByte(a.b, b.b, clamped),
    };
}

fn expandKittyPixels(allocator: std.mem.Allocator, format: ghostty.KittyImageFormat, pixels: []const u8, width: u32, height: u32) ?[]u8 {
    const pixel_count = @as(usize, width) * @as(usize, height);
    const out_len = pixel_count * 4;

    if (format == .png) {
        var decoded_width: u32 = 0;
        var decoded_height: u32 = 0;
        var decoded_ptr: ?[*]u8 = null;
        var decoded_len: usize = 0;
        if (!hollow_decode_png_bytes(pixels.ptr, pixels.len, &decoded_width, &decoded_height, &decoded_ptr, &decoded_len)) return null;
        defer hollow_decode_png_bytes_free(decoded_ptr);
        if (decoded_ptr == null or decoded_width != width or decoded_height != height or decoded_len != out_len) return null;
        return allocator.dupe(u8, decoded_ptr.?[0..decoded_len]) catch null;
    }

    var out = allocator.alloc(u8, out_len) catch return null;
    errdefer allocator.free(out);

    switch (format) {
        .rgba => {
            if (pixels.len != out_len) return null;
            fastmem.copy(u8, out, pixels);
        },
        .rgb => {
            if (pixels.len != pixel_count * 3) return null;
            var src_idx: usize = 0;
            var dst_idx: usize = 0;
            while (dst_idx < out_len) : (dst_idx += 4) {
                out[dst_idx + 0] = pixels[src_idx + 0];
                out[dst_idx + 1] = pixels[src_idx + 1];
                out[dst_idx + 2] = pixels[src_idx + 2];
                out[dst_idx + 3] = 255;
                src_idx += 3;
            }
        },
        .gray => {
            if (pixels.len != pixel_count) return null;
            for (pixels, 0..) |value, idx| {
                const dst_idx = idx * 4;
                out[dst_idx + 0] = value;
                out[dst_idx + 1] = value;
                out[dst_idx + 2] = value;
                out[dst_idx + 3] = 255;
            }
        },
        .gray_alpha => {
            if (pixels.len != pixel_count * 2) return null;
            var src_idx: usize = 0;
            var dst_idx: usize = 0;
            while (dst_idx < out_len) : (dst_idx += 4) {
                const value = pixels[src_idx + 0];
                out[dst_idx + 0] = value;
                out[dst_idx + 1] = value;
                out[dst_idx + 2] = value;
                out[dst_idx + 3] = pixels[src_idx + 1];
                src_idx += 2;
            }
        },
        .png => unreachable,
    }

    return out;
}

fn drawKittyLayer(self: *FtRenderer, runtime: *ghostty.Runtime, terminal: ?*anyopaque, layer: ghostty.KittyPlacementLayer, pane_w: f32, pane_h: f32) void {
    const term = terminal orelse return;
    const graphics = runtime.terminalKittyGraphics(term) orelse return;
    const iterator = runtime.createKittyPlacementIterator() catch return;
    defer runtime.freeKittyPlacementIterator(iterator);
    if (!runtime.populateKittyPlacementIterator(graphics, iterator)) return;
    if (!runtime.setKittyPlacementLayer(iterator, layer)) return;

    while (runtime.nextKittyPlacement(iterator)) {
        var is_virtual = false;
        if (!runtime.kittyPlacementData(iterator, .is_virtual, &is_virtual) or is_virtual) continue;

        var image_id: u32 = 0;
        if (!runtime.kittyPlacementData(iterator, .image_id, &image_id)) continue;
        const image = runtime.kittyGraphicsImage(graphics, image_id) orelse continue;
        const render_info = runtime.kittyPlacementRenderInfo(iterator, image, term) orelse continue;
        if (!render_info.viewport_visible or render_info.pixel_width == 0 or render_info.pixel_height == 0) continue;

        const tex = getOrCreateKittyTexture(self, runtime, image_id, image) orelse continue;

        var x = self.padding_x + @as(f32, @floatFromInt(render_info.viewport_col)) * self.cell_w;
        var y = self.padding_y + @as(f32, @floatFromInt(render_info.viewport_row)) * self.cell_h;
        var w = @as(f32, @floatFromInt(render_info.pixel_width));
        var h = @as(f32, @floatFromInt(render_info.pixel_height));
        var uv0_x = @as(f32, @floatFromInt(render_info.source_x)) / @as(f32, @floatFromInt(tex.key.width));
        var uv0_y = @as(f32, @floatFromInt(render_info.source_y)) / @as(f32, @floatFromInt(tex.key.height));
        var uv1_x = @as(f32, @floatFromInt(render_info.source_x + render_info.source_width)) / @as(f32, @floatFromInt(tex.key.width));
        var uv1_y = @as(f32, @floatFromInt(render_info.source_y + render_info.source_height)) / @as(f32, @floatFromInt(tex.key.height));
        if (!clipTexturedQuad(&x, &y, &w, &h, &uv0_x, &uv0_y, &uv1_x, &uv1_y, pane_w, pane_h)) continue;

        c.sgl_load_default_pipeline();
        c.sgl_enable_texture();
        c.sgl_texture(tex.view, self.atlas_ui_smp);
        c.sgl_begin_quads();
        c.sgl_c4b(255, 255, 255, 255);
        c.sgl_v2f_t2f(x, y, uv0_x, uv0_y);
        c.sgl_v2f_t2f(x + w, y, uv1_x, uv0_y);
        c.sgl_v2f_t2f(x + w, y + h, uv1_x, uv1_y);
        c.sgl_v2f_t2f(x, y + h, uv0_x, uv1_y);
        c.sgl_end();
        c.sgl_disable_texture();
    }
}

fn getOrCreateKittyTexture(self: *FtRenderer, runtime: *ghostty.Runtime, image_id: u32, image: ?*const anyopaque) ?*KittyTexture {
    var width: u32 = 0;
    var height: u32 = 0;
    var format: ghostty.KittyImageFormat = .rgba;
    var data_ptr: ?[*]const u8 = null;
    var data_len: usize = 0;
    if (!runtime.kittyImageData(image, .width, &width) or width == 0) return null;
    if (!runtime.kittyImageData(image, .height, &height) or height == 0) return null;
    if (!runtime.kittyImageData(image, .format, &format)) return null;
    if (!runtime.kittyImageData(image, .data_ptr, @ptrCast(&data_ptr)) or data_ptr == null) return null;
    if (!runtime.kittyImageData(image, .data_len, &data_len) or data_len == 0) return null;

    const key = KittyTextureKey{
        .image_id = image_id,
        .width = width,
        .height = height,
        .format = format,
        .data_len = data_len,
        .data_ptr = @intFromPtr(data_ptr.?),
    };

    var free_slot: ?usize = null;
    for (&self.kitty_textures, 0..) |*slot, i| {
        if (slot.*) |*tex| {
            if (std.meta.eql(tex.key, key)) return tex;
        } else if (free_slot == null) {
            free_slot = i;
        }
    }

    const pixels = data_ptr.?[0..data_len];
    const rgba_pixels = expandKittyPixels(self.allocator, format, pixels, width, height) orelse return null;
    defer self.allocator.free(rgba_pixels);

    const slot_idx = free_slot orelse 0;
    if (self.kitty_textures[slot_idx]) |*old| old.deinit();

    var img_desc = std.mem.zeroes(c.sg_image_desc);
    img_desc.width = @intCast(width);
    img_desc.height = @intCast(height);
    img_desc.pixel_format = c.SG_PIXELFORMAT_RGBA8;
    img_desc.data.mip_levels[0].ptr = rgba_pixels.ptr;
    img_desc.data.mip_levels[0].size = rgba_pixels.len;
    img_desc.label = "kitty-image";
    const sg_img = c.sg_make_image(&img_desc);

    var view_desc = std.mem.zeroes(c.sg_view_desc);
    view_desc.texture.image = sg_img;
    const view = c.sg_make_view(&view_desc);

    self.kitty_textures[slot_idx] = KittyTexture{
        .key = key,
        .image = sg_img,
        .view = view,
    };
    return &self.kitty_textures[slot_idx].?;
}

fn clipTexturedQuad(
    x: *f32,
    y: *f32,
    w: *f32,
    h: *f32,
    uv0_x: *f32,
    uv0_y: *f32,
    uv1_x: *f32,
    uv1_y: *f32,
    pane_w: f32,
    pane_h: f32,
) bool {
    if (w.* <= 0 or h.* <= 0) return false;
    const x_end = x.* + w.*;
    const y_end = y.* + h.*;
    if (x_end <= 0 or y_end <= 0 or x.* >= pane_w or y.* >= pane_h) return false;

    if (x.* < 0) {
        const t = (-x.*) / w.*;
        uv0_x.* = std.math.lerp(uv0_x.*, uv1_x.*, t);
        w.* += x.*;
        x.* = 0;
    }
    if (y.* < 0) {
        const t = (-y.*) / h.*;
        uv0_y.* = std.math.lerp(uv0_y.*, uv1_y.*, t);
        h.* += y.*;
        y.* = 0;
    }
    if (x.* + w.* > pane_w) {
        const t = (pane_w - x.*) / w.*;
        uv1_x.* = std.math.lerp(uv0_x.*, uv1_x.*, t);
        w.* = pane_w - x.*;
    }
    if (y.* + h.* > pane_h) {
        const t = (pane_h - y.*) / h.*;
        uv1_y.* = std.math.lerp(uv0_y.*, uv1_y.*, t);
        h.* = pane_h - y.*;
    }
    return w.* > 0 and h.* > 0;
}

fn lerpByte(a: u8, b: u8, t: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(@round(af + (bf - af) * t));
}

inline fn isLigatureCandidate(cps: []const u32) bool {
    if (cps.len == 0) return false;
    for (cps) |cp| {
        if (cp == 0) break;
        if (!isLigatureCodepoint(cp)) return false;
    }
    return true;
}

inline fn isLigatureCodepoint(cp: u32) bool {
    return switch (cp) {
        '!', '#', '$', '%', '&', '*', '+', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '\\', '^', '|', '~' => true,
        else => false,
    };
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn loadFace(lib: ft.FT_Library, data: []const u8, size_px: f32) !ft.FT_Face {
    var face: ft.FT_Face = null;
    const err = ft.FT_New_Memory_Face(
        lib,
        data.ptr,
        @intCast(data.len),
        0,
        &face,
    );
    if (err != 0 or face == null) return error.FtLoadFaceFailed;
    // Set pixel size: width=0 means "same as height"
    const px: c_uint = @intFromFloat(@round(size_px));
    if (ft.FT_Set_Pixel_Sizes(face, 0, px) != 0) return error.FtSetSizeFailed;
    return face;
}

fn discoverEmojiFont(allocator: std.mem.Allocator, lib: ft.FT_Library, size_px: f32) ?ft.FT_Face {
    const known_emoji_names = [_][]const u8{
        "Noto Color Emoji",
        "Segoe UI Emoji",
        "Apple Color Emoji",
        "EmojiOne Color",
        "JoyPixels",
    };
    for (known_emoji_names) |name| {
        if (discoverSystemFont(allocator, lib, name, .regular)) |match| {
            defer allocator.free(match.path);
            if (loadFaceFromPathIndex(allocator, lib, match.path, match.face_index, size_px)) |face| {
                return face;
            } else |_| continue;
        } else |_| continue;
    }
    // Fallback: look for NotoColorEmoji.ttf in common paths
    const fallback_paths = [_][]const u8{
        "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
        "/usr/local/share/fonts/NotoColorEmoji.ttf",
    };
    for (fallback_paths) |path| {
        if (loadFaceFromPath(allocator, lib, path, size_px)) |face| {
            return face;
        } else |_| continue;
    }
    return null;
}

fn loadConfiguredFace(
    allocator: std.mem.Allocator,
    lib: ft.FT_Library,
    family: ?[]const u8,
    spec: ?[]const u8,
    style: RequestedFontStyle,
    embedded: []const u8,
    size_px: f32,
) !ft.FT_Face {
    if (spec) |value| {
        return loadFaceFromSpec(allocator, lib, value, style, size_px) catch loadFace(lib, embedded, size_px);
    }
    if (family) |value| {
        return loadFaceByName(allocator, lib, value, style, size_px) catch loadFace(lib, embedded, size_px);
    }
    return loadFace(lib, embedded, size_px);
}

fn loadFaceFromPath(allocator: std.mem.Allocator, lib: ft.FT_Library, path: []const u8, size_px: f32) !ft.FT_Face {
    return loadFaceFromPathIndex(allocator, lib, path, 0, size_px);
}

fn loadFaceFromPathIndex(allocator: std.mem.Allocator, lib: ft.FT_Library, path: []const u8, face_index: c_long, size_px: f32) !ft.FT_Face {
    const zpath = try allocator.dupeZ(u8, path);
    defer allocator.free(zpath);

    var face: ft.FT_Face = null;
    const err = ft.FT_New_Face(lib, zpath.ptr, face_index, &face);
    if (err != 0 or face == null) return error.FtLoadFaceFailed;
    errdefer _ = ft.FT_Done_Face(face);

    const px: c_uint = @intFromFloat(@round(size_px));
    if (ft.FT_Set_Pixel_Sizes(face, 0, px) != 0) return error.FtSetSizeFailed;
    return face;
}

fn loadFaceFromSpec(allocator: std.mem.Allocator, lib: ft.FT_Library, spec: []const u8, style: RequestedFontStyle, size_px: f32) !ft.FT_Face {
    return loadFaceFromPath(allocator, lib, spec, size_px) catch loadFaceByName(allocator, lib, spec, style, size_px);
}

fn loadFaceByName(allocator: std.mem.Allocator, lib: ft.FT_Library, name: []const u8, style: RequestedFontStyle, size_px: f32) !ft.FT_Face {
    const match = try discoverSystemFont(allocator, lib, name, style);
    defer allocator.free(match.path);
    return loadFaceFromPathIndex(allocator, lib, match.path, match.face_index, size_px);
}

fn discoverSystemFont(allocator: std.mem.Allocator, lib: ft.FT_Library, name: []const u8, style: RequestedFontStyle) !FontDiscoveryMatch {
    if (builtin.os.tag == .windows) {
        return discoverWindowsFontWithDirectWrite(allocator, name, style);
    }

    var best: ?FontDiscoveryMatch = null;
    errdefer if (best) |match| allocator.free(match.path);

    switch (builtin.os.tag) {
        .windows => unreachable,
        .macos => {
            try searchFontDir(allocator, lib, "/System/Library/Fonts", name, style, &best);
            try searchFontDir(allocator, lib, "/Library/Fonts", name, style, &best);
            if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
                defer allocator.free(home);
                const user_fonts = try std.fs.path.join(allocator, &.{ home, "Library", "Fonts" });
                defer allocator.free(user_fonts);
                try searchFontDir(allocator, lib, user_fonts, name, style, &best);
            } else |_| {}
        },
        else => {
            try searchFontDir(allocator, lib, "/usr/share/fonts", name, style, &best);
            try searchFontDir(allocator, lib, "/usr/local/share/fonts", name, style, &best);
            if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
                defer allocator.free(home);
                const local_share_fonts = try std.fs.path.join(allocator, &.{ home, ".local", "share", "fonts" });
                defer allocator.free(local_share_fonts);
                try searchFontDir(allocator, lib, local_share_fonts, name, style, &best);
                const dot_fonts = try std.fs.path.join(allocator, &.{ home, ".fonts" });
                defer allocator.free(dot_fonts);
                try searchFontDir(allocator, lib, dot_fonts, name, style, &best);
            } else |_| {}
        },
    }

    return best orelse error.FontNotFound;
}

pub fn listAvailableFontFamilies(allocator: std.mem.Allocator) ![][]u8 {
    const detailed = try listAvailableFontsDetailed(allocator);
    defer {
        for (detailed) |*family| family.deinit(allocator);
        allocator.free(detailed);
    }

    const result = try allocator.alloc([]u8, detailed.len);
    errdefer allocator.free(result);
    for (detailed, 0..) |family, i| result[i] = try allocator.dupe(u8, family.family);
    return result;
}

pub fn listAvailableFontsDetailed(allocator: std.mem.Allocator) ![]FontFamilyInfo {
    var seen = SeenFontFamilyDetails{ .allocator = allocator };
    errdefer seen.deinit();

    if (builtin.os.tag == .windows) {
        try collectWindowsFontFaces(&seen);
    } else {
        var ft_lib: ft.FT_Library = null;
        if (ft.FT_Init_FreeType(&ft_lib) != 0) return error.FtInitFailed;
        defer _ = ft.FT_Done_FreeType(ft_lib);

        switch (builtin.os.tag) {
            .macos => {
                try collectFontFaceDetailsFromDir(allocator, ft_lib, "/System/Library/Fonts", &seen);
                try collectFontFaceDetailsFromDir(allocator, ft_lib, "/Library/Fonts", &seen);
                if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
                    defer allocator.free(home);
                    const user_fonts = try std.fs.path.join(allocator, &.{ home, "Library", "Fonts" });
                    defer allocator.free(user_fonts);
                    try collectFontFaceDetailsFromDir(allocator, ft_lib, user_fonts, &seen);
                } else |_| {}
            },
            else => {
                try collectFontFaceDetailsFromDir(allocator, ft_lib, "/usr/share/fonts", &seen);
                try collectFontFaceDetailsFromDir(allocator, ft_lib, "/usr/local/share/fonts", &seen);
                if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
                    defer allocator.free(home);
                    const local_share_fonts = try std.fs.path.join(allocator, &.{ home, ".local", "share", "fonts" });
                    defer allocator.free(local_share_fonts);
                    try collectFontFaceDetailsFromDir(allocator, ft_lib, local_share_fonts, &seen);
                    const dot_fonts = try std.fs.path.join(allocator, &.{ home, ".fonts" });
                    defer allocator.free(dot_fonts);
                    try collectFontFaceDetailsFromDir(allocator, ft_lib, dot_fonts, &seen);
                } else |_| {}
            },
        }
    }

    return try seen.toOwnedSlice(allocator);
}

fn discoverWindowsFontWithDirectWrite(allocator: std.mem.Allocator, name: []const u8, style: RequestedFontStyle) !FontDiscoveryMatch {
    if (builtin.os.tag != .windows) return error.FontNotFound;

    if (try matchWindowsFontWithDirectWrite(allocator, name, style)) |match| {
        if (isPlausibleWindowsFontPath(match.path)) {
            return match;
        }
        allocator.free(match.path);
    }

    if (try discoverWindowsFontFromFilesystem(allocator, name, style)) |match| {
        return match;
    }

    const resolved_name = try resolveWindowsFontFamilyAlias(allocator, name) orelse return error.FontNotFound;
    defer allocator.free(resolved_name);

    if (try matchWindowsFontWithDirectWrite(allocator, resolved_name, style)) |match| {
        if (isPlausibleWindowsFontPath(match.path)) {
            return match;
        }
        allocator.free(match.path);
    }

    return try discoverWindowsFontFromFilesystem(allocator, resolved_name, style) orelse error.FontNotFound;
}

fn discoverWindowsFontFromFilesystem(allocator: std.mem.Allocator, name: []const u8, style: RequestedFontStyle) !?FontDiscoveryMatch {
    if (builtin.os.tag != .windows) return null;

    var ft_lib: ft.FT_Library = null;
    if (ft.FT_Init_FreeType(&ft_lib) != 0) return error.FtInitFailed;
    defer _ = ft.FT_Done_FreeType(ft_lib);

    var best: ?FontDiscoveryMatch = null;
    errdefer if (best) |match| allocator.free(match.path);
    try searchFontDir(allocator, ft_lib, "C:\\Windows\\Fonts", name, style, &best);

    if (std.process.getEnvVarOwned(allocator, "LOCALAPPDATA")) |local_app_data| {
        defer allocator.free(local_app_data);
        const user_fonts = try std.fs.path.join(allocator, &.{ local_app_data, "Microsoft", "Windows", "Fonts" });
        defer allocator.free(user_fonts);
        try searchFontDir(allocator, ft_lib, user_fonts, name, style, &best);
    } else |_| {}

    return best;
}

fn matchWindowsFontWithDirectWrite(allocator: std.mem.Allocator, name: []const u8, style: RequestedFontStyle) !?FontDiscoveryMatch {
    if (builtin.os.tag != .windows) return null;

    const family_z = try allocator.dupeZ(u8, name);
    defer allocator.free(family_z);

    var match: dwrite.HollowDWriteFontMatch = std.mem.zeroes(dwrite.HollowDWriteFontMatch);
    const result = dwrite.hollow_dwrite_match_font(
        family_z.ptr,
        if (style == .bold or style == .bold_italic) 1 else 0,
        if (style == .italic or style == .bold_italic) 1 else 0,
        &match,
    );
    if (result == 0) return null;

    const path_len = std.mem.indexOfScalar(u8, &match.path, 0) orelse match.path.len;
    if (path_len == 0) return null;

    return .{
        .path = try allocator.dupe(u8, match.path[0..path_len]),
        .face_index = @intCast(match.face_index),
        .score = 1,
    };
}

fn resolveWindowsFontFamilyAlias(allocator: std.mem.Allocator, requested: []const u8) !?[]u8 {
    if (builtin.os.tag != .windows) return null;

    var seen = SeenFontFamilies{ .allocator = allocator };
    defer seen.deinit();
    try collectWindowsFontFamilies(&seen);

    var best_name: ?[]const u8 = null;
    var best_score: i32 = std.math.minInt(i32);
    for (seen.names.items) |family_name| {
        const score = scoreWindowsFontFamilyName(requested, family_name);
        if (score > best_score) {
            best_score = score;
            best_name = family_name;
        }
    }

    if (best_name == null or best_score == std.math.minInt(i32)) return null;
    return try allocator.dupe(u8, best_name.?);
}

fn scoreWindowsFontFamilyName(requested: []const u8, candidate: []const u8) i32 {
    var requested_buf: [256]u8 = undefined;
    const requested_normalized = normalizeFontToken(&requested_buf, requested);
    if (requested_normalized.len == 0) return std.math.minInt(i32);

    var candidate_buf: [256]u8 = undefined;
    const candidate_normalized = normalizeFontToken(&candidate_buf, candidate);
    if (candidate_normalized.len == 0) return std.math.minInt(i32);

    if (std.mem.eql(u8, requested_normalized, candidate_normalized)) return 1000;

    var score: i32 = std.math.minInt(i32);
    if (containsToken(candidate_normalized, requested_normalized)) {
        score = 820;
    } else if (containsToken(requested_normalized, candidate_normalized)) {
        score = 760;
    } else {
        return std.math.minInt(i32);
    }

    const prefix_len = sharedPrefixLen(requested_normalized, candidate_normalized);
    const len_delta: usize = if (candidate_normalized.len > requested_normalized.len)
        candidate_normalized.len - requested_normalized.len
    else
        requested_normalized.len - candidate_normalized.len;
    score += @as(i32, @intCast(prefix_len * 4));
    score -= @as(i32, @intCast(@min(len_delta, 64)));
    return score;
}

fn sharedPrefixLen(a: []const u8, b: []const u8) usize {
    const max_len = @min(a.len, b.len);
    var index: usize = 0;
    while (index < max_len and a[index] == b[index]) : (index += 1) {}
    return index;
}

fn isPlausibleWindowsFontPath(path: []const u8) bool {
    if (path.len < 7) return false;
    if (!std.unicode.utf8ValidateSlice(path)) return false;
    const has_drive = std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
    const has_unc = std.mem.startsWith(u8, path, "\\\\");
    if (!has_drive and !has_unc) return false;
    if (!isFontFile(path)) return false;
    return true;
}

fn collectWindowsFontFamilies(seen: *SeenFontFamilies) !void {
    if (builtin.os.tag != .windows) return;

    const CallbackState = struct {
        seen: *SeenFontFamilies,
        failed: ?anyerror = null,
    };

    const callback = struct {
        fn run(family_utf8: [*:0]const u8, ctx: ?*anyopaque) callconv(.c) c_int {
            const state: *CallbackState = @ptrCast(@alignCast(ctx orelse return 0));
            const family = std.mem.span(family_utf8);
            state.seen.add(family) catch |err| {
                state.failed = err;
                return 0;
            };
            return 1;
        }
    }.run;

    var state = CallbackState{ .seen = seen };
    const ok = dwrite.hollow_dwrite_list_font_families(callback, &state);
    if (state.failed) |err| return err;
    if (ok == 0) return error.FontEnumerationFailed;
}

fn collectWindowsFontFaces(seen: *SeenFontFamilyDetails) !void {
    if (builtin.os.tag != .windows) return;

    const CallbackState = struct {
        seen: *SeenFontFamilyDetails,
        failed: ?anyerror = null,
    };

    const callback = struct {
        fn run(family_utf8: [*:0]const u8, style_utf8: [*:0]const u8, ctx: ?*anyopaque) callconv(.c) c_int {
            const state: *CallbackState = @ptrCast(@alignCast(ctx orelse return 0));
            state.seen.add(std.mem.span(family_utf8), std.mem.span(style_utf8)) catch |err| {
                state.failed = err;
                return 0;
            };
            return 1;
        }
    }.run;

    var state = CallbackState{ .seen = seen };
    const ok = dwrite.hollow_dwrite_list_font_faces(callback, &state);
    if (state.failed) |err| return err;
    if (ok == 0) return error.FontEnumerationFailed;
}

fn searchFontDir(
    allocator: std.mem.Allocator,
    lib: ft.FT_Library,
    root_path: []const u8,
    name: []const u8,
    style: RequestedFontStyle,
    best: *?FontDiscoveryMatch,
) !void {
    var dir = std.fs.openDirAbsolute(root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                const child_path = try std.fs.path.join(allocator, &.{ root_path, entry.name });
                defer allocator.free(child_path);
                try searchFontDir(allocator, lib, child_path, name, style, best);
            },
            .file, .sym_link => {
                if (!isFontFile(entry.name)) continue;

                const file_path = try std.fs.path.join(allocator, &.{ root_path, entry.name });
                defer allocator.free(file_path);

                if (try scoreFontFile(allocator, lib, file_path, name, style)) |candidate| {
                    if (best.*) |*current| {
                        if (candidate.score <= current.score) {
                            allocator.free(candidate.path);
                            continue;
                        }
                        allocator.free(current.path);
                    }
                    best.* = candidate;
                }
            },
            else => {},
        }
    }
}

fn collectFontFamiliesFromDir(
    allocator: std.mem.Allocator,
    lib: ft.FT_Library,
    root_path: []const u8,
    seen: *SeenFontFamilies,
) !void {
    var dir = std.fs.openDirAbsolute(root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                const child_path = try std.fs.path.join(allocator, &.{ root_path, entry.name });
                defer allocator.free(child_path);
                try collectFontFamiliesFromDir(allocator, lib, child_path, seen);
            },
            .file, .sym_link => {
                if (!isFontFile(entry.name)) continue;

                const file_path = try std.fs.path.join(allocator, &.{ root_path, entry.name });
                defer allocator.free(file_path);
                try collectFontFamiliesFromFile(allocator, lib, file_path, seen);
            },
            else => {},
        }
    }
}

fn collectFontFaceDetailsFromDir(
    allocator: std.mem.Allocator,
    lib: ft.FT_Library,
    root_path: []const u8,
    seen: *SeenFontFamilyDetails,
) !void {
    var dir = std.fs.openDirAbsolute(root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                const child_path = try std.fs.path.join(allocator, &.{ root_path, entry.name });
                defer allocator.free(child_path);
                try collectFontFaceDetailsFromDir(allocator, lib, child_path, seen);
            },
            .file, .sym_link => {
                if (!isFontFile(entry.name)) continue;

                const file_path = try std.fs.path.join(allocator, &.{ root_path, entry.name });
                defer allocator.free(file_path);
                try collectFontFaceDetailsFromFile(allocator, lib, file_path, seen);
            },
            else => {},
        }
    }
}

fn collectFontFaceDetailsFromFile(
    allocator: std.mem.Allocator,
    lib: ft.FT_Library,
    file_path: []const u8,
    seen: *SeenFontFamilyDetails,
) !void {
    const zpath = try allocator.dupeZ(u8, file_path);
    defer allocator.free(zpath);

    var probe_face: ft.FT_Face = null;
    const probe_err = ft.FT_New_Face(lib, zpath.ptr, 0, &probe_face);
    if (probe_err != 0 or probe_face == null) return;
    const face_count: usize = @intCast(@max(probe_face.*.num_faces, 1));
    _ = ft.FT_Done_Face(probe_face);

    var face_index: usize = 0;
    while (face_index < face_count) : (face_index += 1) {
        var face: ft.FT_Face = null;
        const err = ft.FT_New_Face(lib, zpath.ptr, @intCast(face_index), &face);
        if (err != 0 or face == null) continue;
        defer _ = ft.FT_Done_Face(face);

        const family = faceFamilyName(face);
        const style = faceStyleName(face);
        if (family.len > 0) try seen.add(family, style);
    }
}

fn collectFontFamiliesFromFile(allocator: std.mem.Allocator, lib: ft.FT_Library, file_path: []const u8, seen: *SeenFontFamilies) !void {
    const zpath = try allocator.dupeZ(u8, file_path);
    defer allocator.free(zpath);

    var probe_face: ft.FT_Face = null;
    const probe_err = ft.FT_New_Face(lib, zpath.ptr, 0, &probe_face);
    if (probe_err != 0 or probe_face == null) return;
    const face_count: usize = @intCast(@max(probe_face.*.num_faces, 1));
    _ = ft.FT_Done_Face(probe_face);

    var face_index: usize = 0;
    while (face_index < face_count) : (face_index += 1) {
        var face: ft.FT_Face = null;
        const err = ft.FT_New_Face(lib, zpath.ptr, @intCast(face_index), &face);
        if (err != 0 or face == null) continue;
        defer _ = ft.FT_Done_Face(face);

        const family = faceFamilyName(face);
        if (family.len > 0) try seen.add(family);
    }
}

fn scoreFontFile(
    allocator: std.mem.Allocator,
    lib: ft.FT_Library,
    file_path: []const u8,
    name: []const u8,
    style: RequestedFontStyle,
) !?FontDiscoveryMatch {
    const zpath = try allocator.dupeZ(u8, file_path);
    defer allocator.free(zpath);

    var probe_face: ft.FT_Face = null;
    const probe_err = ft.FT_New_Face(lib, zpath.ptr, 0, &probe_face);
    if (probe_err != 0 or probe_face == null) return null;
    const face_count: usize = @intCast(@max(probe_face.*.num_faces, 1));
    _ = ft.FT_Done_Face(probe_face);

    var best_score: i32 = std.math.minInt(i32);
    var best_index: c_long = 0;
    var face_index: usize = 0;
    while (face_index < face_count) : (face_index += 1) {
        var face: ft.FT_Face = null;
        const err = ft.FT_New_Face(lib, zpath.ptr, @intCast(face_index), &face);
        if (err != 0 or face == null) continue;
        defer _ = ft.FT_Done_Face(face);

        const score = scoreDiscoveredFace(face, file_path, name, style);
        if (score > best_score) {
            best_score = score;
            best_index = @intCast(face_index);
        }
    }

    if (best_score == std.math.minInt(i32)) return null;
    return .{
        .path = try allocator.dupe(u8, file_path),
        .face_index = best_index,
        .score = best_score,
    };
}

fn scoreDiscoveredFace(face: ft.FT_Face, file_path: []const u8, name: []const u8, style: RequestedFontStyle) i32 {
    var wanted_buf: [256]u8 = undefined;
    const wanted = normalizeFontToken(&wanted_buf, name);
    if (wanted.len == 0) return std.math.minInt(i32);

    var family_buf: [256]u8 = undefined;
    const family = normalizeFontToken(&family_buf, faceFamilyName(face));

    var style_buf: [256]u8 = undefined;
    const style_name = normalizeFontToken(&style_buf, faceStyleName(face));

    var basename_buf: [256]u8 = undefined;
    const basename = normalizeFontToken(&basename_buf, std.fs.path.stem(std.fs.path.basename(file_path)));

    const family_match = family.len > 0 and std.mem.eql(u8, family, wanted);
    const basename_match = basename.len > 0 and std.mem.eql(u8, basename, wanted);
    const loose_match = (family.len > 0 and (containsToken(family, wanted) or containsToken(wanted, family))) or
        (basename.len > 0 and (containsToken(basename, wanted) or containsToken(wanted, basename)));

    if (!family_match and !basename_match and !loose_match) return std.math.minInt(i32);

    var score: i32 = 0;
    if (family_match) score += 1000;
    if (basename_match) score += 900;
    if (!family_match and !basename_match and loose_match) score += 700;
    if ((face.*.face_flags & ft.FT_FACE_FLAG_SCALABLE) != 0) score += 25;
    score += styleMatchScore(face, style_name, style);
    return score;
}

fn styleMatchScore(face: ft.FT_Face, style_name: []const u8, style: RequestedFontStyle) i32 {
    const bold = faceIsBold(face, style_name);
    const italic = faceIsItalic(face, style_name);

    return switch (style) {
        .regular => 220 - boolPenalty(bold) - boolPenalty(italic) + regularNameBonus(style_name),
        .bold => 170 + boolBonus(bold) - boolPenalty(italic),
        .italic => 170 - boolPenalty(bold) + boolBonus(italic),
        .bold_italic => 120 + boolBonus(bold) + boolBonus(italic),
    };
}

fn boolBonus(value: bool) i32 {
    return if (value) 60 else -80;
}

fn boolPenalty(value: bool) i32 {
    return if (value) 80 else 0;
}

fn regularNameBonus(style_name: []const u8) i32 {
    if (style_name.len == 0) return 0;
    if (containsToken(style_name, "regular") or containsToken(style_name, "book") or containsToken(style_name, "roman")) return 20;
    return 0;
}

fn faceIsBold(face: ft.FT_Face, style_name: []const u8) bool {
    return (face.*.style_flags & ft.FT_STYLE_FLAG_BOLD) != 0 or containsToken(style_name, "bold") or containsToken(style_name, "semibold") or containsToken(style_name, "demibold");
}

fn faceIsItalic(face: ft.FT_Face, style_name: []const u8) bool {
    return (face.*.style_flags & ft.FT_STYLE_FLAG_ITALIC) != 0 or containsToken(style_name, "italic") or containsToken(style_name, "oblique");
}

fn faceFamilyName(face: ft.FT_Face) []const u8 {
    if (face.*.family_name) |ptr| return std.mem.span(ptr);
    return "";
}

fn faceStyleName(face: ft.FT_Face) []const u8 {
    if (face.*.style_name) |ptr| return std.mem.span(ptr);
    return "";
}

fn containsToken(haystack: []const u8, needle: []const u8) bool {
    return needle.len > 0 and std.mem.indexOf(u8, haystack, needle) != null;
}

test "windows font family alias scoring prefers closest superset" {
    try std.testing.expect(scoreWindowsFontFamilyName("Yu Gothic U", "Yu Gothic UI") > scoreWindowsFontFamilyName("Yu Gothic U", "Yu Gothic"));
}

test "windows font family alias scoring rejects unrelated families" {
    try std.testing.expectEqual(std.math.minInt(i32), scoreWindowsFontFamilyName("Yu Gothic U", "Consolas"));
}

fn normalizeFontToken(buf: []u8, input: []const u8) []const u8 {
    var len: usize = 0;
    for (input) |ch| {
        if (!std.ascii.isAlphanumeric(ch)) continue;
        if (len == buf.len) break;
        buf[len] = std.ascii.toLower(ch);
        len += 1;
    }
    return buf[0..len];
}

fn isFontFile(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".ttf") or
        std.ascii.eqlIgnoreCase(ext, ".otf") or
        std.ascii.eqlIgnoreCase(ext, ".ttc") or
        std.ascii.eqlIgnoreCase(ext, ".otc");
}

fn fontLikelySupportsText(face: ft.FT_Face, utf8: []const u8) bool {
    const cp = firstRenderableCodepoint(utf8) orelse return true;
    return ft.FT_Get_Char_Index(face, cp) != 0;
}

fn firstRenderableCodepoint(utf8: []const u8) ?u32 {
    var view = std.unicode.Utf8View.init(utf8) catch return null;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        if (isIgnorableCodepoint(cp)) continue;
        return cp;
    }
    return null;
}

const TerminalRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

const SynthesizedResult = struct {
    r0: TerminalRect,
    r1: TerminalRect,
    count: u32,
};

fn isSynthesizedTerminalCodepoint(cp: u32) bool {
    return isBoxDrawingCodepoint(cp) or synthesizedTerminalRect(1.0, 1.0, cp) != null;
}

fn isBoxDrawingCodepoint(cp: u32) bool {
    return cp >= 0x2500 and cp <= 0x257F;
}

fn isRoundedArcCodepoint(cp: u32) bool {
    return switch (cp) {
        0x256D, 0x256E, 0x256F, 0x2570 => true,
        else => false,
    };
}

fn drawSynthesizedTerminalUtf8(x: f32, y: f32, cell_w: f32, cell_h: f32, utf8: []const u8, color: ghostty.ColorRgb) bool {
    const cp = firstRenderableCodepoint(utf8) orelse return false;
    return drawSynthesizedTerminalCodepoint(x, y, cell_w, cell_h, cp, color);
}

fn drawSynthesizedTerminalCodepoint(x: f32, y: f32, cell_w: f32, cell_h: f32, cp: u32, color: ghostty.ColorRgb) bool {
    const result = synthesizedTerminalRect(cell_w, cell_h, cp) orelse return false;
    c.sgl_begin_quads();
    emitRect(x + result.r0.x, y + result.r0.y, result.r0.w, result.r0.h, color.r, color.g, color.b, 255);
    if (result.count > 1) {
        emitRect(x + result.r1.x, y + result.r1.y, result.r1.w, result.r1.h, color.r, color.g, color.b, 255);
    }
    c.sgl_end();
    return true;
}

fn synthesizedTerminalRect(cell_w: f32, cell_h: f32, cp: u32) ?SynthesizedResult {
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

/// Helper: wrap a single rect as a SynthesizedResult.
fn single(r: TerminalRect) SynthesizedResult {
    return .{ .r0 = r, .r1 = undefined, .count = 1 };
}

/// Helper: wrap two rects as a SynthesizedResult.
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

fn isIgnorableCodepoint(cp: u32) bool {
    return switch (cp) {
        0x200C, 0x200D, 0xFE0E, 0xFE0F => true,
        0x0300...0x036F => true,
        else => false,
    };
}

/// Emit a single filled rectangle quad into an already-open sgl_begin_quads batch.
/// Caller must have called sgl_begin_quads() before and sgl_end() after.
inline fn emitRect(x: f32, y: f32, w: f32, h: f32, r: u8, g: u8, b: u8, a: u8) void {
    const rf = @as(f32, @floatFromInt(r)) / 255.0;
    const gf = @as(f32, @floatFromInt(g)) / 255.0;
    const bf = @as(f32, @floatFromInt(b)) / 255.0;
    const af = @as(f32, @floatFromInt(a)) / 255.0;
    c.sgl_c4f(rf, gf, bf, af);
    c.sgl_v2f(x, y);
    c.sgl_v2f(x + w, y);
    c.sgl_v2f(x + w, y + h);
    c.sgl_v2f(x, y + h);
}

/// Draw the cursor shape using a single sgl_begin_quads/sgl_end batch.
/// All cursor styles (block, hollow, bar, underline) emit between 1 and 4
/// quads — batched into one draw call instead of one call per rect.
fn drawCursor(x: f32, y: f32, w: f32, h: f32, color: ghostty.ColorRgb, style: ghostty.CursorVisualStyle) void {
    c.sgl_begin_quads();
    switch (style) {
        .block => emitRect(x, y, w, h, color.r, color.g, color.b, 255),
        .block_hollow => {
            const t: f32 = 2.0;
            emitRect(x, y, w, t, color.r, color.g, color.b, 255);
            emitRect(x, y + h - t, w, t, color.r, color.g, color.b, 255);
            emitRect(x, y, t, h, color.r, color.g, color.b, 255);
            emitRect(x + w - t, y, t, h, color.r, color.g, color.b, 255);
        },
        .bar => {
            const bar_w = @min(@as(f32, 3.0), @max(@as(f32, 2.0), @floor(w * 0.16)));
            emitRect(x, y, bar_w, h, color.r, color.g, color.b, 255);
        },
        .underline => emitRect(x, y + h - 4.0, w, 4.0, color.r, color.g, color.b, 255),
    }
    c.sgl_end();
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

/// Return the byte length of the UTF-8 sequence starting with `first_byte`.
fn utf8CodepointLen(first_byte: u8) usize {
    if (first_byte < 0x80) return 1;
    if (first_byte < 0xE0) return 2;
    if (first_byte < 0xF0) return 3;
    return 4;
}
