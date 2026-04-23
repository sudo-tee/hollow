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
const App = @import("../app.zig").App;
const Config = @import("../config.zig").Config;
const ghostty = @import("../term/ghostty.zig");
const selection = @import("../selection.zig");
const fonts = @import("fonts");
const glyph_shader = @import("shaders/glyph_shader.zig");

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
    use_linear_correction: u32 align(4),
    _pad: u32 = 0,
};

// Fragment-shader uniform block (binding 1, std140).
const FsParams = extern struct {
    bg_linear: [4]f32 align(16), // linear-premultiplied background colour
    use_linear_correction: u32 align(4),
    _pad0: u32 = 0,
    _pad1: u32 = 0,
    _pad2: u32 = 0,
};

// Maximum glyph quads we buffer per draw pass.
// At 300 cols × 100 rows that's 30 000 glyphs × 4 verts = 120 000 vertices.
// A typical 80×24 terminal is ~1 920 glyphs.  256k gives comfortable headroom.
const MAX_GLYPH_VERTS: usize = 256 * 1024;
const GLYPH_VBUF_RING_LEN: usize = 8;

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
};

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

const GlyphInstance = struct {
    glyph_id: u32,
    x_advance: f32,
    x_offset: f32,
    y_offset: f32,
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

        const owned_key = try self.allocator.dupe(u8, normalized);
        errdefer self.allocator.free(owned_key);

        try self.families.append(self.allocator, try FontFamilyInfoBuilder.init(self.allocator, family_name, style_name));
        errdefer _ = self.families.pop();

        try self.normalized_map.put(self.allocator, owned_key, self.families.items.len - 1);
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
    fallback_faces: []ft.FT_Face,

    // HarfBuzz fonts (one per face)
    hb_regular: ?*ft.hb_font_t,
    hb_bold: ?*ft.hb_font_t,
    hb_italic: ?*ft.hb_font_t,
    hb_bold_italic: ?*ft.hb_font_t,
    hb_nerd: ?*ft.hb_font_t,
    hb_symbols_nerd: ?*ft.hb_font_t,
    hb_symbols: ?*ft.hb_font_t,
    fallback_hb_fonts: []?*ft.hb_font_t,

    // HarfBuzz buffer (reused each cell)
    hb_buf: ?*ft.hb_buffer_t,

    // Atlas texture (sokol, RGBA8)
    atlas_img: c.sg_image,
    atlas_view: c.sg_view,
    atlas_smp: c.sg_sampler,
    atlas_ui_smp: c.sg_sampler,
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
    glyph_cache: std.AutoHashMap(GlyphKey, Glyph),

    // Shaping cache
    shape_cache: std.AutoHashMap(ShapeKey, ShapeResult),

    // Metrics (all in physical pixels)
    cell_w: f32,
    cell_h: f32,
    ascender: f32,
    font_size_px: f32, // physical pixels = font_size * dpi_scale
    padding_x: f32,
    padding_y: f32,
    coverage_boost: f32,
    coverage_add: f32,
    smoothing: FtRendererConfig.Smoothing,
    hinting: FtRendererConfig.Hinting,
    ligatures: bool,
    embolden: f32,

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

    /// Diagnostic counters — set by the last renderToCache call, readable by caller.
    last_rows_rendered: usize = 0,
    last_rows_skipped: usize = 0,
    /// Sub-timing within renderToCache (nanoseconds).
    last_queue_ns: i128 = 0,
    last_gpu_ns: i128 = 0,
    /// Sub-timing within queueInViewport: pass1 (bg), pass2 (glyphs).
    last_pass1_ns: i128 = 0,
    last_pass2_ns: i128 = 0,
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
        shd_desc.attrs[1].glsl_name = "in_uv";
        shd_desc.attrs[1].hlsl_sem_name = "TEXCOORD";
        shd_desc.attrs[1].hlsl_sem_index = 1;
        shd_desc.attrs[2].glsl_name = "in_fg_rgba";
        shd_desc.attrs[2].hlsl_sem_name = "TEXCOORD";
        shd_desc.attrs[2].hlsl_sem_index = 2;

        // Vertex-shader uniform block (binding 0): mvp + atlas_size + flag.
        shd_desc.uniform_blocks[0].stage = c.SG_SHADERSTAGE_VERTEX;
        shd_desc.uniform_blocks[0].size = @sizeOf(VsParams);
        shd_desc.uniform_blocks[0].layout = c.SG_UNIFORMLAYOUT_STD140;
        shd_desc.uniform_blocks[0].hlsl_register_b_n = 0;
        shd_desc.uniform_blocks[0].glsl_uniforms[0].type = c.SG_UNIFORMTYPE_MAT4;
        shd_desc.uniform_blocks[0].glsl_uniforms[0].glsl_name = "vs_params.mvp";
        shd_desc.uniform_blocks[0].glsl_uniforms[1].type = c.SG_UNIFORMTYPE_FLOAT2;
        shd_desc.uniform_blocks[0].glsl_uniforms[1].glsl_name = "vs_params.atlas_size";
        shd_desc.uniform_blocks[0].glsl_uniforms[2].type = c.SG_UNIFORMTYPE_INT;
        shd_desc.uniform_blocks[0].glsl_uniforms[2].glsl_name = "vs_params.use_linear_correction";

        // Fragment-shader uniform block (binding 1): bg colour + flag.
        shd_desc.uniform_blocks[1].stage = c.SG_SHADERSTAGE_FRAGMENT;
        shd_desc.uniform_blocks[1].size = @sizeOf(FsParams);
        shd_desc.uniform_blocks[1].layout = c.SG_UNIFORMLAYOUT_STD140;
        shd_desc.uniform_blocks[1].hlsl_register_b_n = 1;
        shd_desc.uniform_blocks[1].glsl_uniforms[0].type = c.SG_UNIFORMTYPE_FLOAT4;
        shd_desc.uniform_blocks[1].glsl_uniforms[0].glsl_name = "fs_params.bg_linear";
        shd_desc.uniform_blocks[1].glsl_uniforms[1].type = c.SG_UNIFORMTYPE_INT;
        shd_desc.uniform_blocks[1].glsl_uniforms[1].glsl_name = "fs_params.use_linear_correction";

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
            .fallback_faces = fallback_faces,
            .hb_regular = hb_regular,
            .hb_bold = hb_bold,
            .hb_italic = hb_italic,
            .hb_bold_italic = hb_bold_italic,
            .hb_nerd = hb_nerd,
            .hb_symbols_nerd = hb_symbols_nerd,
            .hb_symbols = hb_symbols,
            .fallback_hb_fonts = fallback_hb_fonts,
            .hb_buf = hb_buf,
            .atlas_img = atlas_img,
            .atlas_view = atlas_view,
            .atlas_smp = atlas_smp,
            .atlas_ui_smp = atlas_ui_smp,
            .atlas_pip = atlas_pip,
            .atlas_data = atlas_data,
            .atlas_x = 1, // leave 1px gutter
            .atlas_y = 1,
            .atlas_row_h = 0,
            .atlas_dirty = false,
            .atlas_uploaded_this_frame = false,
            .atlas_epoch = 0,
            .glyph_cache = std.AutoHashMap(GlyphKey, Glyph).init(allocator),
            .shape_cache = std.AutoHashMap(ShapeKey, ShapeResult).init(allocator),
            .cell_w = cell_w,
            .cell_h = cell_h,
            .ascender = baseline_ascender,
            .font_size_px = font_size_px,
            .padding_x = cfg.padding_x * cfg.dpi_scale,
            .padding_y = cfg.padding_y * cfg.dpi_scale,
            .coverage_boost = cfg.coverage_boost,
            .coverage_add = cfg.coverage_add,
            .smoothing = cfg.smoothing,
            .hinting = cfg.hinting,
            .ligatures = cfg.ligatures,
            .embolden = cfg.embolden,
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
        var i: usize = 0;
        while (i < text.len) {
            const cp_len = utf8CodepointLen(text[i]);
            const end = @min(i + cp_len, text.len);
            self.preRasterize(text[i..end], 0, .ui);
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
        const result = self.getOrShape(utf8, face_idx) orelse return;

        c.sgl_c4b(fg.r, fg.g, fg.b, 255);

        var x_offset: f32 = 0;
        for (result.glyphs) |glyph_inst| {
            const glyph = self.getOrRasterize(glyph_inst.glyph_id, result.raster_face_index, raster_mode) orelse continue;

            // Snap to integer pixels to prevent subpixel sampling artifacts.
            const gx = @round(px + x_offset + glyph_inst.x_offset + @as(f32, @floatFromInt(glyph.bear_x)));
            const gy = @round(py + self.ascender - glyph_inst.y_offset - @as(f32, @floatFromInt(glyph.bear_y)));

            const w = @as(f32, @floatFromInt(glyph.bw));
            const h = @as(f32, @floatFromInt(glyph.bh));
            if (w > 0 and h > 0) {
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
        if (self.hb_symbols) |f| ft.hb_font_destroy(f);
        if (self.hb_symbols_nerd) |f| ft.hb_font_destroy(f);
        if (self.hb_nerd) |f| ft.hb_font_destroy(f);
        if (self.hb_bold_italic) |f| ft.hb_font_destroy(f);
        if (self.hb_italic) |f| ft.hb_font_destroy(f);
        if (self.hb_bold) |f| ft.hb_font_destroy(f);
        if (self.hb_regular) |f| ft.hb_font_destroy(f);
        _ = ft.FT_Done_Face(self.face_symbols);
        _ = ft.FT_Done_Face(self.face_symbols_nerd);
        _ = ft.FT_Done_Face(self.face_nerd);
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
        render_state: ?*anyopaque,
        row_iterator: *?*anyopaque,
        row_cells: *?*anyopaque,
        screen_w: f32,
        screen_h: f32,
    ) void {
        self.queueInViewport(runtime, cfg, render_state, row_iterator, row_cells, 0, 0, screen_w, screen_h, screen_w, screen_h, true, true, null, null, false, null, null, std.math.maxInt(usize));
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
        self.queueInViewport(runtime, cfg, render_state, row_iterator, row_cells, offset_x, offset_y, screen_w, screen_h, fb_w, fb_h, is_focused, force_full, null, null, false, selection_range, hovered_hyperlink, prev_cursor_row);
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
        const t_queue_start = std.time.nanoTimestamp();
        self.queueInViewport(
            runtime,
            cfg,
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
        const t_queue_end = std.time.nanoTimestamp();

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
        var pass = std.mem.zeroes(c.sg_pass);
        pass.attachments.colors[0] = cache.rt_att_view;
        if (force_full) {
            pass.action.colors[0].load_action = c.SG_LOADACTION_CLEAR;
            pass.action.colors[0].clear_value = .{ .r = clear_r, .g = clear_g, .b = clear_b, .a = 1.0 };
        } else {
            pass.action.colors[0].load_action = c.SG_LOADACTION_LOAD;
        }
        c.sg_begin_pass(&pass);

        // Flush the pane's sgl context into the offscreen pass.
        c.sgl_context_draw(cache.sgl_ctx);

        // Draw glyph quads through the custom gamma-correct pipeline.
        // Must happen after sgl_context_draw (avoids interleaving sgl and raw sg_*).
        // Vertices were already uploaded above via uploadGlyphVerts().
        self.drawGlyphQuads(pane_w, pane_h, true, srgbToLinearBg(clear_r, clear_g, clear_b));

        c.sg_end_pass();
        const t_gpu_end = std.time.nanoTimestamp();

        self.last_queue_ns = t_queue_end - t_queue_start;
        self.last_gpu_ns = t_gpu_end - t_queue_end;

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
        const render_colors = runtime.renderStateColors(render_state) orelse return;
        const default_bg = if (cfg.terminal_theme.enabled) cfg.terminal_theme.background else render_colors.background;
        const default_fg = if (cfg.terminal_theme.enabled) cfg.terminal_theme.foreground else render_colors.foreground;
        const palette = if (cfg.terminal_theme.enabled) &cfg.terminal_theme.palette else &render_colors.palette;
        const selection_bg = if (cfg.terminal_theme.enabled)
            (cfg.terminal_theme.selection_bg orelse mixColor(default_bg, default_fg, 0.35))
        else
            mixColor(default_bg, default_fg, 0.35);
        const selection_fg = if (cfg.terminal_theme.enabled)
            (cfg.terminal_theme.selection_fg orelse default_fg)
        else
            default_fg;

        c.sgl_defaults();
        // Set viewport and scissor to this pane's sub-rect.
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

        if (!self.logged_first_draw) {
            std.log.info("ft_renderer first draw: screen={d:.0}x{d:.0} cell={d:.1}x{d:.1}", .{
                pane_w, pane_h, self.cell_w, self.cell_h,
            });
        }

        const row_count = runtime.renderStateRows(render_state) orelse 0;
        const col_count = runtime.renderStateCols(render_state) orelse 0;
        // Only reallocate run_buf when the grid dimensions actually change.
        if (row_count != self.run_buf_rows or col_count != self.run_buf_cols) {
            const run_buf_needed = @max(@as(usize, 1), @as(usize, row_count) * @as(usize, col_count) * 4);
            if (run_buf_needed > self.run_buf.len) {
                if (self.run_buf.len > 0) self.allocator.free(self.run_buf);
                self.run_buf = self.allocator.alloc(u8, run_buf_needed) catch return;
            }
            self.run_buf_rows = row_count;
            self.run_buf_cols = col_count;
        }
        const run_buf = self.run_buf;

        // Per-row hash-skip bitset: tracks rows that matched their stored hash in Pass 1
        // and should be skipped in Pass 2 as well.
        // Stack-allocated: 512 bits = 64 bytes — negligible stack cost.
        const MAX_SKIP_ROWS = 512;
        var hash_skip_bits = [_]u64{0} ** (MAX_SKIP_ROWS / 64);
        const use_row_map = row_map_keys != null and row_map_vals != null;

        // Inline helpers for the skip bitset.
        const SkipSet = struct {
            fn set(bits: *[MAX_SKIP_ROWS / 64]u64, row: usize) void {
                if (row >= MAX_SKIP_ROWS) return;
                bits[row / 64] |= @as(u64, 1) << @intCast(row % 64);
            }
            fn get(bits: *const [MAX_SKIP_ROWS / 64]u64, row: usize) bool {
                if (row >= MAX_SKIP_ROWS) return false;
                return (bits[row / 64] >> @intCast(row % 64)) & 1 != 0;
            }
        };

        // Open-addressing map helpers (power-of-2 capacity, linear probe).
        // Key sentinel: 0 means empty slot.
        const MapLookup = struct {
            /// Look up `key` in the map.  Returns the index of the matching slot
            /// (key == key) or the first empty slot if not found.
            fn probe(keys: []u64, key: u64) usize {
                const cap = keys.len;
                const mask = cap - 1;
                var idx = @as(usize, @truncate(key)) & mask;
                var i: usize = 0;
                while (i < cap) : (i += 1) {
                    const k = keys[idx];
                    if (k == 0 or k == key) return idx;
                    idx = (idx + 1) & mask;
                }
                // Map full (should not happen at 2048 cap for ~200 rows) — return 0.
                return 0;
            }
        };

        // Cursor row — always render regardless of hash match, since the cursor
        // is overlaid on cells during Pass 2 and is not reflected in cell hashes.
        const cursor_row: usize = if (runtime.cursorPos(render_state)) |cp| cp.y else std.math.maxInt(usize);
        // ── Pass 1: Background & Rasterisation ──────────────────────────────
        // We must always probe/rasterize text for rows we are about to draw.
        // Even when the atlas is currently clean, a newly-seen glyph (for
        // example a Nerd Font prompt icon) needs to be added and uploaded
        // before pass 2 queues textured quads, otherwise it won't appear until
        // the next frame.
        //
        // In partial mode (!force_full), skip rows that are not dirty.
        const t_pass1_start = std.time.nanoTimestamp();
        if (runtime.populateRowIterator(render_state, row_iterator)) {
            var row_y: usize = 0;
            var quads_open = false;
            if (force_full) {
                c.sgl_begin_quads();
                quads_open = true;
                c.sgl_c4b(default_bg.r, default_bg.g, default_bg.b, 255);
                c.sgl_v2f(0.0, 0.0);
                c.sgl_v2f(pane_w, 0.0);
                c.sgl_v2f(pane_w, pane_h);
                c.sgl_v2f(0.0, pane_h);
            }
            while (runtime.nextRow(row_iterator.*)) : (row_y += 1) {
                // Per-row dirty skip (partial updates only).
                // Exception: prev_cursor_row must always be re-rendered to erase
                // any ghost cursor pixels left from the previous frame, even if
                // ghostty doesn't mark it dirty (text content unchanged, only the
                // cursor moved away).
                if (!force_full and !runtime.rowDirty(row_iterator.*) and row_y != prev_cursor_row) continue;

                // Row-hash optimisation: look up this row's GhosttyRow raw value in the
                // scroll-stable map.  If the stored content hash matches AND this is not
                // the cursor row (current or previous), the RT already has correct pixels
                // — skip both passes.  The cursor row is always rendered because the
                // cursor overlay is not reflected in cell content hashes.  The previous
                // cursor row is always rendered to clear any lingering cursor pixels.
                //
                // When force_full is true (atlas stale / resize) we must redraw the row
                // regardless of hash match (the RT was cleared and glyph UVs changed), but
                // we still WRITE the fresh hash into the map so the very next cursor-blink
                // frame (.true_value dirty) can skip rows that didn't change.
                if (use_row_map and row_y != cursor_row and row_y != prev_cursor_row) {
                    const row_raw = runtime.rowRaw(row_iterator.*);
                    if (row_raw != 0) {
                        const keys = row_map_keys.?;
                        const vals = row_map_vals.?;
                        const slot = MapLookup.probe(keys, row_raw);
                        if (runtime.rowHashCells(row_iterator.*, row_cells)) |new_hash| {
                            if (row_map_skip and new_hash != 0 and keys[slot] == row_raw and vals[slot] == new_hash) {
                                // Unchanged row — skip render, mark for Pass 2 skip too.
                                SkipSet.set(&hash_skip_bits, row_y);
                                continue;
                            }
                            // Hash changed (or new entry, or skip disabled): update map and render.
                            keys[slot] = row_raw;
                            vals[slot] = new_hash;
                        }
                        // Fall through to normal render below.
                    }
                }

                if (!runtime.populateRowCells(row_iterator.*, row_cells)) continue;
                const py = self.padding_y + @as(f32, @floatFromInt(row_y)) * self.cell_h;
                const row_has_selection = if (selection_range) |range|
                    selection.rowIntersects(range, row_y)
                else
                    false;

                // In partial mode we must first erase the old row pixels by
                // drawing a full-width background rectangle in the default bg
                // color, then overlay any per-cell custom backgrounds below.
                //
                // Start from x=0 (not padding_x) so that glyphs at column 0
                // with a negative bear_x that draw left of the text margin are
                // fully covered.  Without this, each partial re-render blends
                // new glyph coverage onto un-erased pixels from a prior frame,
                // causing anti-aliased edges to accumulate ("ghost glyphs").
                if (!force_full) {
                    if (!quads_open) {
                        c.sgl_begin_quads();
                        quads_open = true;
                    }
                    c.sgl_c4b(default_bg.r, default_bg.g, default_bg.b, 255);
                    c.sgl_v2f(0.0, py);
                    c.sgl_v2f(pane_w, py);
                    c.sgl_v2f(pane_w, py + self.cell_h);
                    c.sgl_v2f(0.0, py + self.cell_h);
                }

                var col_x: usize = 0;
                var run_start_col: usize = 0;
                var run_len: usize = 0;
                var run_face_idx: u8 = 0;
                var run_fg = default_fg;
                while (runtime.nextCell(row_cells.*)) : (col_x += 1) {
                    self.last_cells_visited += 1;
                    // Fetch the raw cell first: cheap pure read, enables fast-path checks.
                    const raw_cell = runtime.cellRaw(row_cells.*);
                    // Use pure bit-extraction functions (no C call) for content_tag,
                    // has_text, and codepoint — replaces the C ABI dispatch for these.
                    const content_tag = runtime.cellContentTagRaw(raw_cell);
                    const is_selected = if (selection_range) |range|
                        row_has_selection and selection.cellSelected(range, row_y, col_x)
                    else
                        false;

                    // Background: skip the cellBackground() C-ABI call for cells with
                    // no styling (default bg) and no bg-color content tag.
                    // bg_color_palette/rgb cells always need the call; styled cells may have
                    // a style-based bg; unstyled codepoint/grapheme cells always use default bg.
                    const is_bg_tag = content_tag == .bg_color_palette or content_tag == .bg_color_rgb;
                    if (is_selected) {
                        self.last_bg_rects += 1;
                        if (!quads_open) {
                            c.sgl_begin_quads();
                            quads_open = true;
                        }
                        const px = self.padding_x + @as(f32, @floatFromInt(col_x)) * self.cell_w;
                        c.sgl_c4b(selection_bg.r, selection_bg.g, selection_bg.b, 255);
                        c.sgl_v2f(px, py);
                        c.sgl_v2f(px + self.cell_w, py);
                        c.sgl_v2f(px + self.cell_w, py + self.cell_h);
                        c.sgl_v2f(px, py + self.cell_h);
                    } else if (is_bg_tag or runtime.cellStyleIdRaw(raw_cell) != 0) {
                        const bg: ghostty.ColorRgb = runtime.cellBackground(row_cells.*) orelse default_bg;
                        if (bg.r != default_bg.r or bg.g != default_bg.g or bg.b != default_bg.b) {
                            self.last_bg_rects += 1;
                            if (!quads_open) {
                                c.sgl_begin_quads();
                                quads_open = true;
                            }
                            const px = self.padding_x + @as(f32, @floatFromInt(col_x)) * self.cell_w;
                            c.sgl_c4b(bg.r, bg.g, bg.b, 255);
                            c.sgl_v2f(px, py);
                            c.sgl_v2f(px + self.cell_w, py);
                            c.sgl_v2f(px + self.cell_w, py + self.cell_h);
                            c.sgl_v2f(px, py + self.cell_h);
                        }
                    }

                    // Rasterisation / atlas population for any glyphs needed by
                    // rows we will draw this frame. raw_cell and content_tag
                    // were already fetched above.
                    //
                    // Optimisation: use cellStyleIdRaw() (direct bit extraction, no C call)
                    // instead of cellHasStyling() to fast-check for non-default style.
                    // Also: fg is UNUSED in Pass 1 (flushRasterRun ignores it), so skip
                    // resolveStyleColor() entirely — only face_idx is needed for rasterization.
                    const p1_sid = runtime.cellStyleIdRaw(raw_cell);
                    var face_idx: u8 = 0;
                    if (p1_sid != 0 and runtime.cellHasTextRaw(raw_cell)) {
                        if (runtime.cellStyle(row_cells.*)) |s| {
                            if (s.bold and s.italic) {
                                face_idx = 2;
                            } else if (s.bold) {
                                face_idx = 1;
                            } else if (s.italic) {
                                face_idx = 3;
                            }
                            // fg from cellStyle() is unused in Pass 1; skip resolveStyleColor().
                        }
                    }
                    // fg is only needed for ligature run grouping in Pass 1 (colorsEqual check).
                    // Since flushRasterRun ignores fg, use default_fg always — this is safe
                    // because ligature runs are re-grouped in Pass 2 with the correct fg.
                    const fg = default_fg;

                    switch (content_tag) {
                        .codepoint => {
                            const cp = runtime.cellCodepointRaw(raw_cell);
                            if (cp == 0) {
                                flushRasterRun(self, run_buf, &run_start_col, &run_len, face_idx, fg, py);
                                continue;
                            }
                            // Fast non-ligature path: avoid UTF-8 encoding for the common
                            // printable-ASCII case when the glyph is already cached.
                            if (!self.ligatures or !isLigatureCodepoint(cp)) {
                                flushRasterRun(self, run_buf, &run_start_col, &run_len, run_face_idx, run_fg, py);
                                // Fast-path: if the glyph is already in the ascii cache it is
                                // guaranteed to be in the atlas — skip preRasterize entirely.
                                const ascii_cached = (cp >= 0x21 and cp <= 0xFF and
                                    (cp <= 0x7E or cp >= 0xA0) and
                                    face_idx <= 3 and
                                    self.ascii_glyphs[@intCast(face_idx)][cp] != null);
                                if (!ascii_cached) {
                                    const glyph_len: usize = encodeUtf8(cp, &self.glyph_buf) catch 0;
                                    if (glyph_len == 0) continue;
                                    self.preRasterize(self.glyph_buf[0..glyph_len], face_idx, .terminal);
                                }
                                continue;
                            }
                            const glyph_len: usize = encodeUtf8(cp, &self.glyph_buf) catch 0;
                            if (glyph_len == 0) {
                                flushRasterRun(self, run_buf, &run_start_col, &run_len, face_idx, fg, py);
                                continue;
                            }
                            if (run_len + glyph_len > run_buf.len) {
                                flushRasterRun(self, run_buf, &run_start_col, &run_len, run_face_idx, run_fg, py);
                            }
                            if (run_len == 0) {
                                run_start_col = col_x;
                                run_face_idx = face_idx;
                                run_fg = fg;
                            }
                            if (run_len > 0 and (run_face_idx != face_idx or !colorsEqual(run_fg, fg))) {
                                flushRasterRun(self, run_buf, &run_start_col, &run_len, run_face_idx, run_fg, py);
                                run_start_col = col_x;
                                run_face_idx = face_idx;
                                run_fg = fg;
                            }
                            @memcpy(run_buf[run_len .. run_len + glyph_len], self.glyph_buf[0..glyph_len]);
                            run_len += glyph_len;
                        },
                        .codepoint_grapheme => {
                            // Multi-codepoint grapheme cluster — must use the graphemes buf API.
                            const grapheme_len = runtime.cellGraphemeLen(row_cells.*);
                            if (grapheme_len == 0) {
                                flushRasterRun(self, run_buf, &run_start_col, &run_len, face_idx, fg, py);
                                continue;
                            }
                            var cps: [16]u32 = [_]u32{0} ** 16;
                            runtime.cellGraphemes(row_cells.*, &cps);
                            var glyph_len: usize = 0;
                            for (cps[0..grapheme_len]) |cp| {
                                if (cp == 0) break;
                                glyph_len += encodeUtf8(cp, self.glyph_buf[glyph_len..]) catch break;
                            }
                            if (glyph_len == 0) {
                                flushRasterRun(self, run_buf, &run_start_col, &run_len, face_idx, fg, py);
                                continue;
                            }
                            if (!self.ligatures or !isLigatureCandidate(cps[0..grapheme_len])) {
                                flushRasterRun(self, run_buf, &run_start_col, &run_len, run_face_idx, run_fg, py);
                                self.preRasterize(self.glyph_buf[0..glyph_len], face_idx, .terminal);
                                continue;
                            }
                            if (run_len + glyph_len > run_buf.len) {
                                flushRasterRun(self, run_buf, &run_start_col, &run_len, run_face_idx, run_fg, py);
                            }
                            if (run_len == 0) {
                                run_start_col = col_x;
                                run_face_idx = face_idx;
                                run_fg = fg;
                            }
                            if (run_len > 0 and (run_face_idx != face_idx or !colorsEqual(run_fg, fg))) {
                                flushRasterRun(self, run_buf, &run_start_col, &run_len, run_face_idx, run_fg, py);
                                run_start_col = col_x;
                                run_face_idx = face_idx;
                                run_fg = fg;
                            }
                            @memcpy(run_buf[run_len .. run_len + glyph_len], self.glyph_buf[0..glyph_len]);
                            run_len += glyph_len;
                        },
                        else => {
                            // BG_COLOR_PALETTE / BG_COLOR_RGB: no text to rasterize.
                            flushRasterRun(self, run_buf, &run_start_col, &run_len, face_idx, fg, py);
                        },
                    }
                }
                if (run_len > 0) {
                    flushRasterRun(self, run_buf, &run_start_col, &run_len, run_face_idx, run_fg, py);
                }
            }
            if (quads_open) c.sgl_end();
        }

        if (self.atlas_dirty) {
            self.flushAtlas();
            self.atlas_dirty = false;
            self.last_atlas_flushed = true;
        }
        const t_pass2_start = std.time.nanoTimestamp();

        // ── Pass 2: Glyph draw pass ────────────────────────────────────────
        // In partial mode, skip clean rows; clear rowDirty on each dirty row
        // after rendering so the flag is reset for the next updateRenderState.
        if (runtime.populateRowIterator(render_state, row_iterator)) {
            var row_y: usize = 0;
            while (runtime.nextRow(row_iterator.*)) : (row_y += 1) {
                // Per-row dirty skip (partial updates only).
                // Exception: prev_cursor_row is always re-rendered to clear ghost
                // cursor pixels even when ghostty doesn't mark it dirty.
                const row_is_dirty = force_full or runtime.rowDirty(row_iterator.*) or row_y == prev_cursor_row;
                if (!row_is_dirty) {
                    self.last_rows_skipped += 1;
                    continue;
                }
                // Row-hash skip: this row had a matching hash in Pass 1 — RT already
                // has correct pixels, no need to redraw.  Do NOT skip if this is the
                // previous cursor row: the hash reflects text content, not the cursor
                // overlay, so the hash may match while ghost cursor pixels remain.
                if (SkipSet.get(&hash_skip_bits, row_y) and row_y != prev_cursor_row) {
                    self.last_rows_skipped += 1;
                    // Don't clear rowDirty here — ghostty will keep marking it dirty
                    // each frame; we rely on hash comparison to skip it.
                    continue;
                }
                self.last_rows_rendered += 1;

                if (!runtime.populateRowCells(row_iterator.*, row_cells)) {
                    // Still clear rowDirty even if cells couldn't be populated.
                    if (!force_full) runtime.clearRowDirty(row_iterator.*);
                    continue;
                }
                const py = self.padding_y + @as(f32, @floatFromInt(row_y)) * self.cell_h;
                const row_has_selection = if (selection_range) |range|
                    selection.rowIntersects(range, row_y)
                else
                    false;
                var col_x: usize = 0;
                var run_start_col: usize = 0;
                var run_len: usize = 0;
                var run_face_idx: u8 = 0;
                var run_fg = default_fg;
                while (runtime.nextCell(row_cells.*)) : (col_x += 1) {
                    // Fetch the raw cell first — pure u64 read, enables cheap
                    // has_text / has_styling checks before heavier calls.
                    const raw_cell = runtime.cellRaw(row_cells.*);
                    // Use pure bit-extraction functions (no C call) for content_tag.
                    const content_tag = runtime.cellContentTagRaw(raw_cell);

                    // Skip cellStyle() for cells with no text (blank/space cells
                    // can't be bold/italic and their fg color doesn't matter for
                    // rendering). For cells with text, only fetch style when the
                    // cell actually has non-default styling.
                    //
                    // Optimisation: use cellStyleIdRaw() + cellHasTextRaw() (direct bit extraction,
                    // no C calls) instead of cellHasStyling() + cellHasText() C ABI calls.
                    const p2_sid = runtime.cellStyleIdRaw(raw_cell);
                    var face_idx: u8 = 0;
                    var fg = default_fg;
                    if (p2_sid != 0 and runtime.cellHasTextRaw(raw_cell)) {
                        if (runtime.cellStyle(row_cells.*)) |s| {
                            if (s.bold and s.italic) {
                                face_idx = 2;
                            } else if (s.bold) {
                                face_idx = 1;
                            } else if (s.italic) {
                                face_idx = 3;
                            }
                            fg = ghostty.resolveStyleColor(s.fg_color, default_fg, palette);
                        }
                    }
                    if (selection_range) |range| {
                        if (row_has_selection and selection.cellSelected(range, row_y, col_x)) {
                            fg = selection_fg;
                        }
                    }

                    switch (content_tag) {
                        .codepoint => {
                            const cp = runtime.cellCodepointRaw(raw_cell);
                            if (cp == 0) {
                                flushDrawRun(self, run_buf, &run_start_col, &run_len, run_face_idx, run_fg, py);
                                continue;
                            }
                            // Fast non-ligature path: avoid UTF-8 encoding before the ASCII
                            // glyph fast-path. In the steady-state benchmark this removes one
                            // encode call from almost every visible cell.
                            if (!self.ligatures or !isLigatureCodepoint(cp)) {
                                flushDrawRun(self, run_buf, &run_start_col, &run_len, run_face_idx, run_fg, py);
                                const px = self.padding_x + @as(f32, @floatFromInt(col_x)) * self.cell_w;
                                // Fast ASCII path: skip HarfBuzz shaping for printable ASCII.
                                self.last_glyph_runs += 1;
                                if (!self.drawAsciiGlyph(px, py, cp, face_idx, fg, py, py + self.cell_h)) {
                                    const glyph_len: usize = encodeUtf8(cp, &self.glyph_buf) catch 0;
                                    if (glyph_len == 0) continue;
                                    self.batchGlyphs(px, py, self.glyph_buf[0..glyph_len], face_idx, fg, .terminal, py, py + self.cell_h);
                                }
                                continue;
                            }
                            const glyph_len: usize = encodeUtf8(cp, &self.glyph_buf) catch 0;
                            if (glyph_len == 0) {
                                flushDrawRun(self, run_buf, &run_start_col, &run_len, run_face_idx, run_fg, py);
                                continue;
                            }
                            if (run_len + glyph_len > run_buf.len) {
                                flushDrawRun(self, run_buf, &run_start_col, &run_len, run_face_idx, run_fg, py);
                            }
                            if (run_len == 0) {
                                run_start_col = col_x;
                                run_face_idx = face_idx;
                                run_fg = fg;
                            }
                            if (run_len > 0 and (run_face_idx != face_idx or !colorsEqual(run_fg, fg))) {
                                flushDrawRun(self, run_buf, &run_start_col, &run_len, run_face_idx, run_fg, py);
                                run_start_col = col_x;
                                run_face_idx = face_idx;
                                run_fg = fg;
                            }
                            @memcpy(run_buf[run_len .. run_len + glyph_len], self.glyph_buf[0..glyph_len]);
                            run_len += glyph_len;
                        },
                        .codepoint_grapheme => {
                            // Multi-codepoint grapheme cluster.
                            const grapheme_len = runtime.cellGraphemeLen(row_cells.*);
                            if (grapheme_len == 0) {
                                flushDrawRun(self, run_buf, &run_start_col, &run_len, run_face_idx, run_fg, py);
                                continue;
                            }
                            var cps: [16]u32 = [_]u32{0} ** 16;
                            runtime.cellGraphemes(row_cells.*, &cps);
                            var glyph_len: usize = 0;
                            for (cps[0..grapheme_len]) |cp| {
                                if (cp == 0) break;
                                glyph_len += encodeUtf8(cp, self.glyph_buf[glyph_len..]) catch break;
                            }
                            if (glyph_len == 0) {
                                flushDrawRun(self, run_buf, &run_start_col, &run_len, run_face_idx, run_fg, py);
                                continue;
                            }
                            if (!self.ligatures or !isLigatureCandidate(cps[0..grapheme_len])) {
                                flushDrawRun(self, run_buf, &run_start_col, &run_len, run_face_idx, run_fg, py);
                                const px = self.padding_x + @as(f32, @floatFromInt(col_x)) * self.cell_w;
                                self.last_glyph_runs += 1;
                                self.batchGlyphs(px, py, self.glyph_buf[0..glyph_len], face_idx, fg, .terminal, py, py + self.cell_h);
                                continue;
                            }
                            if (run_len + glyph_len > run_buf.len) {
                                flushDrawRun(self, run_buf, &run_start_col, &run_len, run_face_idx, run_fg, py);
                            }
                            if (run_len == 0) {
                                run_start_col = col_x;
                                run_face_idx = face_idx;
                                run_fg = fg;
                            }
                            if (run_len > 0 and (run_face_idx != face_idx or !colorsEqual(run_fg, fg))) {
                                flushDrawRun(self, run_buf, &run_start_col, &run_len, run_face_idx, run_fg, py);
                                run_start_col = col_x;
                                run_face_idx = face_idx;
                                run_fg = fg;
                            }
                            @memcpy(run_buf[run_len .. run_len + glyph_len], self.glyph_buf[0..glyph_len]);
                            run_len += glyph_len;
                        },
                        else => {
                            // BG_COLOR_PALETTE / BG_COLOR_RGB: no text.
                            flushDrawRun(self, run_buf, &run_start_col, &run_len, run_face_idx, run_fg, py);
                        },
                    }
                }
                if (run_len > 0) {
                    flushDrawRun(self, run_buf, &run_start_col, &run_len, run_face_idx, run_fg, py);
                }

                // ── Decorations (underline / undercurl / strikethrough / overline) ──
                // Drawn after glyphs so they appear on top.
                // We batch all decoration rects for this row into one sgl quad batch.
                if (runtime.populateRowCells(row_iterator.*, row_cells)) {
                    var dec_col_x: usize = 0;
                    var dec_quads_open = false;
                    while (runtime.nextCell(row_cells.*)) : (dec_col_x += 1) {
                        const raw_cell2 = runtime.cellRaw(row_cells.*);
                        const hovered_link_visual = if (hovered_hyperlink) |hovered|
                            hovered.row == row_y and dec_col_x >= hovered.start_col and dec_col_x < hovered.end_col
                        else
                            false;
                        const style_id = runtime.cellStyleIdRaw(raw_cell2);
                        if (style_id == 0 and !hovered_link_visual) continue;
                        const s_opt = runtime.cellStyle(row_cells.*);
                        if (style_id != 0 and s_opt == null) continue;
                        const s = s_opt orelse ghostty.Style{
                            .size = @sizeOf(ghostty.Style),
                            .fg_color = .{ .tag = .none, .value = .{ ._padding = 0 } },
                            .bg_color = .{ .tag = .none, .value = .{ ._padding = 0 } },
                            .underline_color = .{ .tag = .none, .value = .{ ._padding = 0 } },
                            .bold = false,
                            .italic = false,
                            .faint = false,
                            .blink = false,
                            .inverse = false,
                            .invisible = false,
                            .strikethrough = false,
                            .overline = false,
                            .underline = 0,
                        };

                        const has_decoration = s.underline != 0 or s.strikethrough or s.overline or hovered_link_visual;
                        if (!has_decoration) continue;

                        if (!dec_quads_open) {
                            c.sgl_load_default_pipeline();
                            c.sgl_begin_quads();
                            dec_quads_open = true;
                        }

                        const dec_px = self.padding_x + @as(f32, @floatFromInt(dec_col_x)) * self.cell_w;
                        const dec_selected = if (selection_range) |range|
                            selection.cellSelected(range, row_y, dec_col_x)
                        else
                            false;
                        const dec_fg = if (dec_selected)
                            selection_fg
                        else
                            ghostty.resolveStyleColor(s.fg_color, default_fg, palette);
                        const dec_color = ghostty.resolveStyleColor(s.underline_color, dec_fg, palette);
                        // Use underline_color if set, otherwise fall back to fg.
                        const ul_r = dec_color.r;
                        const ul_g = dec_color.g;
                        const ul_b = dec_color.b;

                        // Underline position: 1px above cell bottom, thickness 1px.
                        const ul_thickness: f32 = 1.0;
                        const ul_y = py + self.cell_h - ul_thickness - 1.0;

                        const effective_underline: i32 = if (hovered_link_visual and s.underline == 0) 1 else s.underline;

                        switch (effective_underline) {
                            0 => {}, // GHOSTTY_SGR_UNDERLINE_NONE
                            1 => { // SINGLE
                                emitRect(dec_px, ul_y, self.cell_w, ul_thickness, ul_r, ul_g, ul_b, 255);
                            },
                            2 => { // DOUBLE
                                emitRect(dec_px, ul_y - 2.0, self.cell_w, ul_thickness, ul_r, ul_g, ul_b, 255);
                                emitRect(dec_px, ul_y, self.cell_w, ul_thickness, ul_r, ul_g, ul_b, 255);
                            },
                            3 => { // CURLY (undercurl)
                                // Approximate a sine wave with 8 segments per cell.
                                const n_segs: usize = 8;
                                const seg_w = self.cell_w / @as(f32, @floatFromInt(n_segs));
                                const amp: f32 = 1.0; // amplitude in pixels
                                const base_y = ul_y + amp; // center of wave
                                var seg: usize = 0;
                                while (seg < n_segs) : (seg += 1) {
                                    const t = @as(f32, @floatFromInt(seg)) / @as(f32, @floatFromInt(n_segs));
                                    const t1 = @as(f32, @floatFromInt(seg + 1)) / @as(f32, @floatFromInt(n_segs));
                                    const sx0 = dec_px + t * self.cell_w;
                                    const sy0 = base_y - amp * @sin(t * std.math.tau);
                                    const sy1 = base_y - amp * @sin(t1 * std.math.tau);
                                    const seg_h = @abs(sy1 - sy0) + ul_thickness;
                                    const seg_y = @min(sy0, sy1);
                                    emitRect(sx0, seg_y, seg_w, seg_h, ul_r, ul_g, ul_b, 255);
                                }
                            },
                            4 => { // DOTTED
                                var dot_x = dec_px;
                                const dot_w: f32 = 1.0;
                                const gap: f32 = 2.0;
                                while (dot_x + dot_w <= dec_px + self.cell_w) : (dot_x += dot_w + gap) {
                                    emitRect(dot_x, ul_y, dot_w, ul_thickness, ul_r, ul_g, ul_b, 255);
                                }
                            },
                            5 => { // DASHED
                                var dash_x = dec_px;
                                const dash_w: f32 = 4.0;
                                const dash_gap: f32 = 2.0;
                                while (dash_x + dash_w <= dec_px + self.cell_w) : (dash_x += dash_w + dash_gap) {
                                    emitRect(dash_x, ul_y, dash_w, ul_thickness, ul_r, ul_g, ul_b, 255);
                                }
                            },
                            else => {
                                // Unknown underline style — fall back to single.
                                emitRect(dec_px, ul_y, self.cell_w, ul_thickness, ul_r, ul_g, ul_b, 255);
                            },
                        }

                        if (s.strikethrough) {
                            const st_y = py + self.cell_h * 0.5 - 0.5;
                            emitRect(dec_px, st_y, self.cell_w, ul_thickness, dec_fg.r, dec_fg.g, dec_fg.b, 255);
                        }

                        if (s.overline) {
                            emitRect(dec_px, py, self.cell_w, ul_thickness, dec_fg.r, dec_fg.g, dec_fg.b, 255);
                        }
                    }
                    if (dec_quads_open) c.sgl_end();
                }

                // Clear per-row dirty flag after rendering this row.
                if (!force_full) runtime.clearRowDirty(row_iterator.*);
            }
        }

        // ── Cursor overlay ─────────────────────────────────────────────────
        if (is_focused and runtime.cursorVisible(render_state)) {
            if (runtime.cursorPos(render_state)) |pos| {
                const cx = self.padding_x + @as(f32, @floatFromInt(pos.x)) * self.cell_w;
                const cy = self.padding_y + @as(f32, @floatFromInt(pos.y)) * self.cell_h;
                // Reset to default pipeline so cursor quads are not rendered
                // through the atlas texture-blend pipeline (which would make
                // them invisible by multiplying vertex colour by the texture).
                c.sgl_load_default_pipeline();
                // Fall back to white when no explicit cursor color is configured.
                const cursor_color: ghostty.ColorRgb = if (cfg.terminal_theme.enabled)
                    (cfg.terminal_theme.cursor orelse .{ .r = 220, .g = 220, .b = 220 })
                else if (render_colors.cursor_has_value)
                    render_colors.cursor
                else
                    .{ .r = 220, .g = 220, .b = 220 };
                drawCursor(cx, cy, self.cell_w, self.cell_h, cursor_color, runtime.cursorVisualStyle(render_state));
            }
        }

        if (!self.logged_first_draw) self.logged_first_draw = true;
        if (self.frame_count <= 3) {
            std.log.info("ft_renderer queueInViewport done: frame={d} glyph_verts={d} rows_rendered={d} bg_rects={d}", .{
                self.frame_count, self.glyph_verts_count, self.last_rows_rendered, self.last_bg_rects,
            });
        }
        const t_pass2_end = std.time.nanoTimestamp();
        self.last_pass1_ns = t_pass2_start - t_pass1_start;
        self.last_pass2_ns = t_pass2_end - t_pass2_start;
    }

    /// Pre-rasterize glyphs for a cell to ensure they are in the atlas.
    fn preRasterize(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode) void {
        const result = self.getOrShape(utf8, face_idx) orelse return;
        for (result.glyphs) |glyph_inst| {
            _ = self.getOrRasterize(glyph_inst.glyph_id, result.raster_face_index, raster_mode);
        }
    }

    /// Shape and batch glyphs for one cell at (px, py).
    fn batchGlyphs(self: *FtRenderer, px: f32, py: f32, utf8: []const u8, face_idx: u8, fg: ghostty.ColorRgb, raster_mode: RasterMode, clip_y0: f32, clip_y1: f32) void {
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
                self.emitGlyphQuad(gx, gy, w, h, glyph.s0, glyph.t0, glyph.s1, glyph.t1, fg, clip_y0, clip_y1);
            }

            x_offset += glyph_inst.x_advance;
        }
    }

    /// Fast path for printable ASCII (0x21–0x7E) and Latin-1 supplement (0xA0–0xFF):
    /// skip HarfBuzz shaping entirely.
    /// On the first call per (cp, face_idx), resolves the glyph via FT_Get_Char_Index
    /// and getOrRasterize, then caches the full Glyph struct in ascii_glyphs.
    /// On subsequent calls (the steady-state hot path) it is a single array lookup —
    /// no hashmap, no C-ABI call.  Returns true if the glyph was drawn (or is
    /// blank/invisible); false if the caller should fall back to batchGlyphs.
    inline fn drawAsciiGlyph(self: *FtRenderer, px: f32, py: f32, cp: u32, face_idx: u8, fg: ghostty.ColorRgb, clip_y0: f32, clip_y1: f32) bool {
        if (cp < 0x21 or cp > 0xFF or face_idx > 3) return false;
        // Skip C1 control range (0x7F–0x9F) — these are never printable.
        if (cp > 0x7E and cp < 0xA0) return false;

        const fi: usize = @intCast(face_idx);
        const glyph: Glyph = self.ascii_glyphs[fi][cp] orelse blk: {
            // Not yet cached — resolve glyph_id via FT_Get_Char_Index then rasterize.
            const face = switch (face_idx) {
                0 => self.face_regular,
                1 => self.face_bold,
                2 => self.face_bold_italic,
                3 => self.face_italic,
                else => return false,
            };
            const glyph_id = ft.FT_Get_Char_Index(face, cp);
            if (glyph_id == 0) {
                // Face has no glyph for this codepoint; cache a zero sentinel and fall back.
                self.ascii_glyphs[fi][cp] = Glyph{ .s0 = 0, .t0 = 0, .s1 = 0, .t1 = 0, .bw = -1, .bh = 0, .bear_x = 0, .bear_y = 0, .advance_x = 0 };
                return false;
            }
            const g = self.getOrRasterize(glyph_id, face_idx, .terminal) orelse {
                self.ascii_glyphs[fi][cp] = Glyph{ .s0 = 0, .t0 = 0, .s1 = 0, .t1 = 0, .bw = 0, .bh = 0, .bear_x = 0, .bear_y = 0, .advance_x = 0 };
                break :blk self.ascii_glyphs[fi][cp].?;
            };
            self.ascii_glyphs[fi][cp] = g;
            break :blk g;
        };
        // bw == -1 sentinel means the face has no glyph for this codepoint.
        if (glyph.bw == -1) return false;

        const w = @as(f32, @floatFromInt(glyph.bw));
        const h = @as(f32, @floatFromInt(glyph.bh));
        if (w > 0 and h > 0) {
            // Snap to integer pixels to prevent subpixel sampling artifacts.
            const gx = @round(px + @as(f32, @floatFromInt(glyph.bear_x)));
            const gy = @round(py + self.ascender - @as(f32, @floatFromInt(glyph.bear_y)));
            self.emitGlyphQuad(gx, gy, w, h, glyph.s0, glyph.t0, glyph.s1, glyph.t1, fg, clip_y0, clip_y1);
        }
        return true;
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
    ) void {
        if (self.glyph_verts_count + 4 > MAX_GLYPH_VERTS) return;

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

        const base = self.glyph_verts_count;
        const verts = self.glyph_verts_cpu;
        verts[base + 0] = .{ .x = gx, .y = clipped_top, .u = s0, .v = tc_top, .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
        verts[base + 1] = .{ .x = gx + w, .y = clipped_top, .u = s1, .v = tc_top, .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
        verts[base + 2] = .{ .x = gx + w, .y = clipped_bot, .u = s1, .v = tc_bot, .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
        verts[base + 3] = .{ .x = gx, .y = clipped_bot, .u = s0, .v = tc_bot, .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
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
            .use_linear_correction = if (self.use_linear_correction) 1 else 0,
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
            .use_linear_correction = if (self.use_linear_correction) 1 else 0,
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

    fn flushRasterRun(self: *FtRenderer, run_buf: []u8, run_start_col: *usize, run_len: *usize, face_idx: u8, fg: ghostty.ColorRgb, py: f32) void {
        _ = fg;
        _ = py;
        if (run_len.* == 0) return;
        self.preRasterize(run_buf[0..run_len.*], face_idx, .terminal);
        run_start_col.* = 0;
        run_len.* = 0;
    }

    fn flushDrawRun(self: *FtRenderer, run_buf: []u8, run_start_col: *usize, run_len: *usize, face_idx: u8, fg: ghostty.ColorRgb, py: f32) void {
        if (run_len.* == 0) return;
        self.last_glyph_runs += 1;
        const px = self.padding_x + @as(f32, @floatFromInt(run_start_col.*)) * self.cell_w;
        self.batchGlyphs(px, py, run_buf[0..run_len.*], face_idx, fg, .terminal, py, py + self.cell_h);
        run_start_col.* = 0;
        run_len.* = 0;
    }

    fn getOrShape(self: *FtRenderer, utf8: []const u8, face_idx: u8) ?ShapeResult {
        if (utf8.len == 0 or utf8.len > 128) return null;

        var key = ShapeKey{ .text = [_]u8{0} ** 128, .len = @intCast(utf8.len), .face_idx = face_idx, .ligatures = self.ligatures };
        @memcpy(key.text[0..utf8.len], utf8);

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
        if (ft.FT_Load_Glyph(primary_face, glyph_id, load_flags) != 0 or glyph_id == 0) {
            self.glyph_cache.put(key, Glyph{ .s0 = 0, .t0 = 0, .s1 = 0, .t1 = 0, .bw = 0, .bh = 0, .bear_x = 0, .bear_y = 0, .advance_x = 0 }) catch {};
            return null;
        }

        const slot = primary_face.*.glyph;
        if (self.embolden > 0.0 and slot.*.format == ft.FT_GLYPH_FORMAT_OUTLINE) {
            const strength: ft.FT_Pos = @intFromFloat(self.embolden * 64.0);
            _ = ft.FT_Outline_Embolden(&slot.*.outline, strength);
        }
        if (ft.FT_Render_Glyph(slot, if (use_subpixel) ft.FT_RENDER_MODE_LCD else ft.FT_RENDER_MODE_NORMAL) != 0) {
            if (ft.FT_Render_Glyph(slot, ft.FT_RENDER_MODE_NORMAL) != 0) {
                self.glyph_cache.put(key, Glyph{ .s0 = 0, .t0 = 0, .s1 = 0, .t1 = 0, .bw = 0, .bh = 0, .bear_x = 0, .bear_y = 0, .advance_x = 0 }) catch {};
                return null;
            }
        }
        const bmp = &slot.*.bitmap;

        // Only handle grey bitmaps (FT_PIXEL_MODE_GRAY).
        // Space characters and some glyphs produce zero-size bitmaps — cache them
        // with zero dimensions so we still get the correct advance.
        const is_gray = bmp.*.pixel_mode == ft.FT_PIXEL_MODE_GRAY;
        const is_lcd = bmp.*.pixel_mode == ft.FT_PIXEL_MODE_LCD;
        if ((!is_gray and !is_lcd) or bmp.*.width == 0 or bmp.*.rows == 0) {
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
                if (is_lcd) {
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
        if (fontLikelySupportsText(self.face_symbols_nerd, utf8)) {
            return .{ .hb_font = self.hb_symbols_nerd, .raster_face_index = @intCast(bundled_base) };
        }
        if (fontLikelySupportsText(self.face_symbols, utf8)) {
            return .{ .hb_font = self.hb_symbols, .raster_face_index = @intCast(bundled_base + 1) };
        }
        if (fontLikelySupportsText(self.face_nerd, utf8)) {
            return .{ .hb_font = self.hb_nerd, .raster_face_index = @intCast(bundled_base + 2) };
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
                if (fallback_index == self.fallback_faces.len) break :blk self.face_symbols_nerd;
                if (fallback_index == self.fallback_faces.len + 1) break :blk self.face_symbols;
                if (fallback_index == self.fallback_faces.len + 2) break :blk self.face_nerd;
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
                if (fallback_index == self.fallback_hb_fonts.len) break :blk self.hb_symbols_nerd;
                if (fallback_index == self.fallback_hb_fonts.len + 1) break :blk self.hb_symbols;
                if (fallback_index == self.fallback_hb_fonts.len + 2) break :blk self.hb_nerd;
                break :blk null;
            },
        };
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

fn colorsEqual(a: ghostty.ColorRgb, b: ghostty.ColorRgb) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}

fn mixColor(a: ghostty.ColorRgb, b: ghostty.ColorRgb, t: f32) ghostty.ColorRgb {
    const clamped = std.math.clamp(t, 0.0, 1.0);
    return .{
        .r = lerpByte(a.r, b.r, clamped),
        .g = lerpByte(a.g, b.g, clamped),
        .b = lerpByte(a.b, b.b, clamped),
    };
}

fn lerpByte(a: u8, b: u8, t: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(@round(af + (bf - af) * t));
}

fn isLigatureCandidate(cps: []const u32) bool {
    if (cps.len == 0) return false;
    for (cps) |cp| {
        if (cp == 0) break;
        if (!isLigatureCodepoint(cp)) return false;
    }
    return true;
}

fn isLigatureCodepoint(cp: u32) bool {
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

    const family_z = try allocator.dupeZ(u8, name);
    defer allocator.free(family_z);

    var match: dwrite.HollowDWriteFontMatch = std.mem.zeroes(dwrite.HollowDWriteFontMatch);
    const result = dwrite.hollow_dwrite_match_font(
        family_z.ptr,
        if (style == .bold or style == .bold_italic) 1 else 0,
        if (style == .italic or style == .bold_italic) 1 else 0,
        &match,
    );
    if (result == 0) return error.FontNotFound;

    const path_len = std.mem.indexOfScalar(u8, &match.path, 0) orelse match.path.len;
    if (path_len == 0) return error.FontNotFound;

    return .{
        .path = try allocator.dupe(u8, match.path[0..path_len]),
        .face_index = @intCast(match.face_index),
        .score = 1,
    };
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
        .block => emitRect(x, y, w, h, color.r, color.g, color.b, 180),
        .block_hollow => {
            const t: f32 = 1.5;
            emitRect(x, y, w, t, color.r, color.g, color.b, 220);
            emitRect(x, y + h - t, w, t, color.r, color.g, color.b, 220);
            emitRect(x, y, t, h, color.r, color.g, color.b, 220);
            emitRect(x + w - t, y, t, h, color.r, color.g, color.b, 220);
        },
        .bar => emitRect(x, y, 2.0, h, color.r, color.g, color.b, 220),
        .underline => emitRect(x, y + h - 2.0, w, 2.0, color.r, color.g, color.b, 220),
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
