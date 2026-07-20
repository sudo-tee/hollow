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
const CopyModeSnapshotLine = @import("../app/copy_mode.zig").CopyModeSnapshotLine;
const SearchHighlight = @import("../app/copy_mode.zig").SearchHighlight;
const Config = @import("../config.zig").Config;
const ghostty = @import("../term/ghostty.zig");
const Pane = @import("../pane.zig").Pane;
const selection = @import("../selection.zig");
const fonts = @import("fonts");
const glyph_shader = @import("shaders/glyph_shader.zig");

const color_math = @import("color_math.zig");
const text_util = @import("text_util.zig");
const font_config = @import("font_config.zig");
const font_discovery = @import("font_discovery.zig");
const ft_types = @import("ft_types.zig");
const pane_cache_mod = @import("pane_cache.zig");
const synth_glyphs = @import("synth_glyphs.zig");
const kitty_graphics = @import("kitty_graphics.zig");
const atlas_mod = @import("atlas.zig");
const shaping = @import("shaping.zig");
const glyph_batch = @import("glyph_batch.zig");
const terminal_render = @import("terminal_render.zig");

const srgbToLinear = color_math.srgbToLinear;
const srgbToLinearBg = color_math.srgbToLinearBg;
const colorsEqual = color_math.colorsEqual;
const relativeLuminance = color_math.relativeLuminance;
const contrastRatio = color_math.contrastRatio;
const contrastTextColor = color_math.contrastTextColor;
const effectiveCursorColor = color_math.effectiveCursorColor;
const lerpByte = color_math.lerpByte;
const mixColor = color_math.mixColor;
const CURSOR_BLINK_INTERVAL_MS = color_math.CURSOR_BLINK_INTERVAL_MS;
const blinkVisibleNow = color_math.blinkVisibleNow;
const effectiveCursorStyle = color_math.effectiveCursorStyle;
const RowSelectionBounds = color_math.RowSelectionBounds;
const rowSelectionBounds = color_math.rowSelectionBounds;
const encodeUtf8 = text_util.encodeUtf8;
const utf8CodepointLen = text_util.utf8CodepointLen;

// Internal aliases so remaining code in this file compiles unchanged.
const FtRendererConfig = font_config.FtRendererConfig;

// Internal aliases used by remaining code in this file.
const RequestedFontStyle = font_config.RequestedFontStyle;
const FontDiscoveryMatch = font_config.FontDiscoveryMatch;
const loadConfiguredFace = font_discovery.loadConfiguredFace;
const loadFace = font_discovery.loadFace;
const discoverEmojiFont = font_discovery.discoverEmojiFont;
const loadFaceFromSpec = font_discovery.loadFaceFromSpec;
const fontLikelySupportsText = font_discovery.fontLikelySupportsText;
const firstRenderableCodepoint = font_discovery.firstRenderableCodepoint;

// Internal alias so remaining code in this file compiles unchanged.
const PaneCache = pane_cache_mod.PaneCache;

// Aliases for shared renderer types from ft_types — keeps existing call sites
// (e.g. `Glyph`, `GlyphKey`, `RasterMode`) compiling unchanged.
const ATLAS_W = ft_types.ATLAS_W;
const ATLAS_H = ft_types.ATLAS_H;
const ATLAS_BPP = ft_types.ATLAS_BPP;
const GlyphVertex = ft_types.GlyphVertex;
const VsParams = ft_types.VsParams;
const FsParams = ft_types.FsParams;
const MAX_GLYPH_VERTS = ft_types.MAX_GLYPH_VERTS;
const GLYPH_VBUF_RING_LEN = ft_types.GLYPH_VBUF_RING_LEN;
const KITTY_TEXTURE_CACHE_LEN = ft_types.KITTY_TEXTURE_CACHE_LEN;
const RasterMode = ft_types.RasterMode;
const Glyph = ft_types.Glyph;
const CachedStyleInfo = ft_types.CachedStyleInfo;
const STYLE_CACHE_SIZE = ft_types.STYLE_CACHE_SIZE;
const GlyphKey = ft_types.GlyphKey;
const ShapeKey = ft_types.ShapeKey;
const KittyTextureKey = ft_types.KittyTextureKey;
const KittyTexture = ft_types.KittyTexture;
const GlyphInstance = ft_types.GlyphInstance;
const PreparedGlyph = ft_types.PreparedGlyph;
const ShapedRunEntry = ft_types.ShapedRunEntry;
const PreparedRun = ft_types.PreparedRun;
const PreparedKey = ft_types.PreparedKey;
const PreparedCacheEntry = ft_types.PreparedCacheEntry;
const RecentPreparedEntry = ft_types.RecentPreparedEntry;
const RECENT_PREPARED_CACHE_LEN = ft_types.RECENT_PREPARED_CACHE_LEN;
const ShapeResult = ft_types.ShapeResult;
const GlyphCacheContext = ft_types.GlyphCacheContext;
const ShapeCacheContext = ft_types.ShapeCacheContext;
const PreparedCacheContext = ft_types.PreparedCacheContext;

const isSynthesizedTerminalCodepoint = synth_glyphs.isSynthesizedTerminalCodepoint;
const drawSynthesizedTerminalUtf8 = synth_glyphs.drawSynthesizedTerminalUtf8;
const drawSynthesizedTerminalCodepoint = synth_glyphs.drawSynthesizedTerminalCodepoint;

extern fn hollow_decode_png_bytes(
    data: [*]const u8,
    data_len: usize,
    out_width: *u32,
    out_height: *u32,
    out_pixels: *?[*]u8,
    out_len: *usize,
) callconv(.c) bool;

extern fn hollow_decode_png_bytes_free(pixels: ?[*]u8) callconv(.c) void;

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
    /// Monotonically increasing counter incremented on every atlas upload.
    /// Informational: appends do NOT move existing glyph UVs, so pane caches
    /// that were rendered before an append keep their cached pixels valid and
    /// do NOT need a full redraw. Callers that only care whether cached pixels
    /// became stale should compare `atlas_reset_epoch` instead.
    atlas_append_epoch: u64,
    /// Monotonically increasing counter incremented ONLY on the destructive
    /// eviction in resetAtlasIfNeeded(). When this differs from a pane cache's
    /// saved `last_atlas_reset_epoch`, every previously placed glyph has had
    /// its UV moved (the atlas was zeroed and glyphs were re-rasterised into
    /// new positions) and the pane must do a full redraw so its cached RT
    /// pixels use the new UVs. Appends do NOT bump this counter.
    atlas_reset_epoch: u64,

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
        const emoji_face_index: u8 = @intCast(4 + fallback_faces.len + 1);

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
            .atlas_append_epoch = 0,
            .atlas_reset_epoch = 0,
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
        glyph_batch.batchGlyphsSgl(self, px, py, utf8, face_idx, fg, raster_mode);
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

        // OpenGL render-target textures use a bottom-left origin, while D3D11
        // uses top-left. Flip V only for the GL cache blit so terminal rows
        // retain Ghostty's top-to-bottom order on Linux.
        const v_top: f32 = if (builtin.os.tag == .linux) 1.0 else 0.0;
        const v_bottom: f32 = 1.0 - v_top;

        // Draw a quad covering [ox, oy] → [ox+pw, oy+ph]. Vertex colour white
        // (1,1,1,1) so the texture is sampled as-is.
        c.sgl_begin_quads();
        c.sgl_c4b(255, 255, 255, 255);
        c.sgl_v2f_t2f(ox, oy, 0.0, v_top);
        c.sgl_v2f_t2f(ox + pw, oy, 1.0, v_top);
        c.sgl_v2f_t2f(ox + pw, oy + ph, 1.0, v_bottom);
        c.sgl_v2f_t2f(ox, oy + ph, 0.0, v_bottom);
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
        kitty_graphics.queueKittyLayerInPane(self, runtime, terminal, layer, ox, oy, pw, ph, fb_w, fb_h);
    }

    /// Queue geometry for one pane into its viewport sub-rect.
    /// See terminal_render.zig for the implementation.
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
        prev_cursor_row: usize,
    ) void {
        terminal_render.queueInViewport(self, runtime, cfg, app, pane, terminal, render_state, row_iterator, row_cells, offset_x, offset_y, pane_w, pane_h, fb_w, fb_h, is_focused, force_full, row_map_keys, row_map_vals, row_map_skip, selection_range, hovered_hyperlink, prev_cursor_row);
    }

    // ── Shaping wrappers (implementations in shaping.zig) ──────────────────────

    const SelectedShapeFont = shaping.SelectedShapeFont;

    pub fn preRasterize(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode) void {
        shaping.preRasterize(self, utf8, face_idx, raster_mode);
    }
    pub fn preRasterizeShaped(self: *FtRenderer, result: ShapeResult, raster_mode: RasterMode) void {
        shaping.preRasterizeShaped(self, result, raster_mode);
    }
    pub fn prepareGlyphs(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode) ?PreparedRun {
        return shaping.prepareGlyphs(self, utf8, face_idx, raster_mode);
    }
    pub fn prepareShapedGlyphs(self: *FtRenderer, result: ShapeResult, raster_mode: RasterMode) ?PreparedRun {
        return shaping.prepareShapedGlyphs(self, result, raster_mode);
    }
    pub fn getOrShape(self: *FtRenderer, utf8: []const u8, face_idx: u8) ?ShapeResult {
        return shaping.getOrShape(self, utf8, face_idx);
    }
    pub fn getOrRasterize(self: *FtRenderer, glyph_id: u32, raster_face_index: u8, raster_mode: RasterMode) ?Glyph {
        return shaping.getOrRasterize(self, glyph_id, raster_face_index, raster_mode);
    }
    pub fn loadFlagsForRasterMode(self: *const FtRenderer, use_subpixel: bool) c_int {
        return shaping.loadFlagsForRasterMode(self, use_subpixel);
    }
    pub fn selectShapeFont(self: *FtRenderer, utf8: []const u8, face_idx: u8) SelectedShapeFont {
        return shaping.selectShapeFont(self, utf8, face_idx);
    }
    pub fn faceForRasterIndex(self: *FtRenderer, raster_face_index: u8) ?ft.FT_Face {
        return shaping.faceForRasterIndex(self, raster_face_index);
    }
    pub fn hbFontForRasterIndex(self: *FtRenderer, raster_face_index: u8) ?*ft.hb_font_t {
        return shaping.hbFontForRasterIndex(self, raster_face_index);
    }
    pub fn emboldenForRasterFace(self: *const FtRenderer, raster_face_index: u8) f32 {
        return shaping.emboldenForRasterFace(self, raster_face_index);
    }
    pub fn recordShapedRun(self: *FtRenderer, utf8: []const u8, face_idx: u8, prepared_start: usize, prepared_len: usize) void {
        shaping.recordShapedRun(self, utf8, face_idx, prepared_start, prepared_len);
    }
    pub fn getPreparedCache(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode) ?PreparedRun {
        return shaping.getPreparedCache(self, utf8, face_idx, raster_mode);
    }
    pub fn appendPreparedRun(self: *FtRenderer, glyphs: []const PreparedGlyph) ?PreparedRun {
        return shaping.appendPreparedRun(self, glyphs);
    }
    pub fn putPreparedCache(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode, glyphs: []const PreparedGlyph) void {
        shaping.putPreparedCache(self, utf8, face_idx, raster_mode, glyphs);
    }
    pub fn makePreparedKey(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode) PreparedKey {
        return shaping.makePreparedKey(self, utf8, face_idx, raster_mode);
    }
    pub fn getRecentPrepared(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode, fingerprint: u64) ?[]PreparedGlyph {
        return shaping.getRecentPrepared(self, utf8, face_idx, raster_mode, fingerprint);
    }
    pub fn putRecentPrepared(self: *FtRenderer, key: PreparedKey, fingerprint: u64, glyphs: []PreparedGlyph) void {
        shaping.putRecentPrepared(self, key, fingerprint, glyphs);
    }
    pub fn preparedFingerprint(utf8: []const u8, face_idx: u8, ligatures: bool, raster_mode: RasterMode) u64 {
        return shaping.preparedFingerprint(utf8, face_idx, ligatures, raster_mode);
    }
    pub fn consumeShapedRun(self: *FtRenderer, utf8: []const u8, face_idx: u8) ?[]const PreparedGlyph {
        return shaping.consumeShapedRun(self, utf8, face_idx);
    }

    // ── Glyph batch wrappers (implementations in glyph_batch.zig) ─────────────

    pub fn batchGlyphs(self: *FtRenderer, px: f32, py: f32, utf8: []const u8, face_idx: u8, fg: ghostty.ColorRgb, raster_mode: RasterMode, clip_y0: f32, clip_y1: f32) void {
        glyph_batch.batchGlyphs(self, px, py, utf8, face_idx, fg, raster_mode, clip_y0, clip_y1);
    }
    pub fn batchGlyphsShaped(self: *FtRenderer, px: f32, py: f32, result: ShapeResult, fg: ghostty.ColorRgb, raster_mode: RasterMode, clip_y0: f32, clip_y1: f32) void {
        glyph_batch.batchGlyphsShaped(self, px, py, result, fg, raster_mode, clip_y0, clip_y1);
    }
    pub fn batchPreparedGlyphs(self: *FtRenderer, px: f32, py: f32, glyphs: []const PreparedGlyph, fg: ghostty.ColorRgb, clip_y0: f32, clip_y1: f32) void {
        glyph_batch.batchPreparedGlyphs(self, px, py, glyphs, fg, clip_y0, clip_y1);
    }
    pub inline fn emitPreparedGlyph(self: *FtRenderer, px: f32, py: f32, x_offset: *f32, glyph_inst: GlyphInstance, glyph: Glyph, fg: ghostty.ColorRgb, clip_y0: f32, clip_y1: f32) void {
        glyph_batch.emitPreparedGlyph(self, px, py, x_offset, glyph_inst, glyph, fg, clip_y0, clip_y1);
    }
    pub inline fn drawDirectGlyph(self: *FtRenderer, px: f32, py: f32, cp: u32, face_idx: u8, fg: ghostty.ColorRgb, clip_y0: f32, clip_y1: f32) bool {
        return glyph_batch.drawDirectGlyph(self, px, py, cp, face_idx, fg, clip_y0, clip_y1);
    }
    pub inline fn batchDirectGlyphSgl(self: *FtRenderer, px: f32, py: f32, cp: u32, face_idx: u8, fg: ghostty.ColorRgb, raster_mode: RasterMode) bool {
        return glyph_batch.batchDirectGlyphSgl(self, px, py, cp, face_idx, fg, raster_mode);
    }
    pub inline fn directGlyph(self: *FtRenderer, cp: u32, face_idx: u8) ?Glyph {
        return glyph_batch.directGlyph(self, cp, face_idx);
    }
    pub inline fn directGlyphForMode(self: *FtRenderer, cp: u32, face_idx: u8, raster_mode: RasterMode) ?Glyph {
        return glyph_batch.directGlyphForMode(self, cp, face_idx, raster_mode);
    }
    pub inline fn emitGlyphQuad(self: *FtRenderer, gx: f32, gy: f32, w: f32, h: f32, s0: f32, t0: f32, s1: f32, t1: f32, fg: ghostty.ColorRgb, clip_y0: f32, clip_y1: f32, color_emoji: bool) void {
        glyph_batch.emitGlyphQuad(self, gx, gy, w, h, s0, t0, s1, t1, fg, clip_y0, clip_y1, color_emoji);
    }
    pub fn uploadGlyphVerts(self: *FtRenderer) usize {
        return glyph_batch.uploadGlyphVerts(self);
    }
    pub fn drawGlyphQuads(self: *FtRenderer, pane_w: f32, pane_h: f32, offscreen: bool, bg_linear: [4]f32) void {
        glyph_batch.drawGlyphQuads(self, pane_w, pane_h, offscreen, bg_linear);
    }
    pub fn discardGlyphQuads(self: *FtRenderer) void {
        glyph_batch.discardGlyphQuads(self);
    }
    pub fn flushGlyphQuads(self: *FtRenderer, pane_w: f32, pane_h: f32, offscreen: bool, bg_linear: [4]f32) void {
        glyph_batch.flushGlyphQuads(self, pane_w, pane_h, offscreen, bg_linear);
    }
    pub inline fn flushRasterRun(self: *FtRenderer, run_buf: []u8, run_start_col: *usize, run_len: *usize, face_idx: u8, fg: ghostty.ColorRgb, py: f32) void {
        glyph_batch.flushRasterRun(self, run_buf, run_start_col, run_len, face_idx, fg, py);
    }
    pub inline fn flushDrawRun(self: *FtRenderer, run_buf: []u8, run_start_col: *usize, run_len: *usize, face_idx: u8, fg: ghostty.ColorRgb, py: f32) void {
        glyph_batch.flushDrawRun(self, run_buf, run_start_col, run_len, face_idx, fg, py);
    }
    pub inline fn styleCacheReset(self: *FtRenderer) void {
        glyph_batch.styleCacheReset(self);
    }
    pub inline fn resolveCachedStyle(self: *FtRenderer, runtime: *ghostty.Runtime, row_cells: ?*anyopaque, style_id: u16, selected: bool, default_fg: ghostty.ColorRgb, default_bg: ghostty.ColorRgb, selection_fg: ghostty.ColorRgb, palette: *const [256]ghostty.ColorRgb) ?*const CachedStyleInfo {
        return glyph_batch.resolveCachedStyle(self, runtime, row_cells, style_id, selected, default_fg, default_bg, selection_fg, palette);
    }
    pub inline fn styleCacheSlot(self: *FtRenderer, style_id: u16, selected: bool) usize {
        return glyph_batch.styleCacheSlot(self, style_id, selected);
    }
    pub inline fn isAsciiFastPathCandidate(cp: u32, face_idx: u8) bool {
        return glyph_batch.isAsciiFastPathCandidate(cp, face_idx);
    }

    /// Call once at the start of each frame to allow atlas upload for that frame.
    pub fn beginFrame(self: *FtRenderer) void {
        atlas_mod.beginFrame(self);
    }

    /// Upload atlas to GPU if it has been modified and not yet uploaded this frame.
    pub fn flushAtlasIfDirty(self: *FtRenderer) void {
        atlas_mod.flushAtlasIfDirty(self);
    }

    pub fn flushAtlas(self: *FtRenderer) void {
        atlas_mod.flushAtlas(self);
    }

    pub fn resetAtlasIfNeeded(self: *FtRenderer) void {
        atlas_mod.resetAtlasIfNeeded(self);
    }

    pub fn boostCoverage(self: *const FtRenderer, cov: u8) u8 {
        if (cov == 0 or cov == 255) return cov;
        const boosted = @as(f32, @floatFromInt(cov)) * self.coverage_boost + self.coverage_add;
        return @intFromFloat(@min(255.0, boosted));
    }

    // ── Synthesized glyph wrappers (implementations in synth_glyphs.zig) ──────

    pub fn ensureSynthesizedBoxGlyph(self: *FtRenderer, cp: u32) ?Glyph {
        return synth_glyphs.ensureSynthesizedBoxGlyph(self, cp);
    }

    fn ensureSynthesizedRoundedArcGlyph(self: *FtRenderer, cp: u32) ?Glyph {
        return synth_glyphs.ensureSynthesizedRoundedArcGlyph(self, cp);
    }

    pub fn drawSynthesizedBoxGlyph(
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

    pub fn drawSynthesizedBoxUtf8(
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

const featureTag = shaping.featureTag;

/// Re-exported from terminal_render.zig (synth_glyphs.zig imports via this path).
pub const emitRect = terminal_render.emitRect;
