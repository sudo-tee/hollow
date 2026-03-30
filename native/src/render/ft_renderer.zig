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
const c = @import("sokol_c");
const ft = @import("ft_c");
const ghostty = @import("../term/ghostty.zig");
const fonts = @import("fonts");

// ── Atlas constants ───────────────────────────────────────────────────────────
const ATLAS_W: u32 = 2048;
const ATLAS_H: u32 = 2048;
const ATLAS_BPP: u32 = 4; // RGBA8

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
    padding_x: f32 = 0.0,
    padding_y: f32 = 0.0,
    coverage_boost: f32 = 1.12,
    coverage_add: f32 = 6.0,
    smoothing: Smoothing = .grayscale,
    hinting: Hinting = .normal,
    ligatures: bool = true,
    embolden: f32 = 0.0,
    regular_path: ?[]const u8 = null,
    bold_path: ?[]const u8 = null,
    italic_path: ?[]const u8 = null,
    bold_italic_path: ?[]const u8 = null,
    fallback_paths: []const []const u8 = &.{},
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

    // Atlas packing state
    atlas_x: u32,
    atlas_y: u32,
    atlas_row_h: u32,
    atlas_dirty: bool,
    /// Guards against calling sg_update_image more than once per frame.
    /// Reset by beginFrame(); set true by the first flushAtlas() each frame.
    atlas_uploaded_this_frame: bool,

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

    pub fn init(allocator: std.mem.Allocator, cfg: FtRendererConfig) !FtRenderer {
        const font_size_px = cfg.font_size * cfg.dpi_scale;

        // ── FreeType init ──────────────────────────────────────────────────
        var ft_lib: ft.FT_Library = null;
        if (ft.FT_Init_FreeType(&ft_lib) != 0) return error.FtInitFailed;
        errdefer _ = ft.FT_Done_FreeType(ft_lib);
        if (cfg.smoothing == .subpixel) {
            _ = ft.FT_Library_SetLcdFilter(ft_lib, ft.FT_LCD_FILTER_LIGHT);
        }

        const face_regular = try loadConfiguredFace(allocator, ft_lib, cfg.regular_path, fonts.regular, font_size_px);
        errdefer _ = ft.FT_Done_Face(face_regular);
        const face_bold = try loadConfiguredFace(allocator, ft_lib, cfg.bold_path, fonts.bold, font_size_px);
        errdefer _ = ft.FT_Done_Face(face_bold);
        const face_italic = try loadConfiguredFace(allocator, ft_lib, cfg.italic_path, fonts.italic, font_size_px);
        errdefer _ = ft.FT_Done_Face(face_italic);
        const face_bold_italic = try loadConfiguredFace(allocator, ft_lib, cfg.bold_italic_path, fonts.bold_italic, font_size_px);
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
            fallback_faces[i] = try loadFaceFromPath(allocator, ft_lib, path, font_size_px);
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
        const cell_h = ascender - descender; // positive height
        // Advance of 'M' for cell width
        var cell_w: f32 = font_size_px * 0.6; // fallback
        if (ft.FT_Load_Char(face_regular, 'M', ft.FT_LOAD_NO_BITMAP) == 0) {
            cell_w = @as(f32, @floatFromInt(face_regular.*.glyph.*.advance.x)) / 64.0;
        }

        std.log.info("ft_renderer: font_size={d:.1} dpi={d:.2} cell={d:.1}x{d:.1} asc={d:.1}", .{
            cfg.font_size, cfg.dpi_scale, cell_w, cell_h, ascender,
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
        smp_desc.min_filter = c.SG_FILTER_LINEAR;
        smp_desc.mag_filter = c.SG_FILTER_LINEAR;
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
            .glyph_cache = std.AutoHashMap(GlyphKey, Glyph).init(allocator),
            .shape_cache = std.AutoHashMap(ShapeKey, ShapeResult).init(allocator),
            .cell_w = cell_w,
            .cell_h = cell_h,
            .ascender = ascender,
            .font_size_px = font_size_px,
            .padding_x = cfg.padding_x * cfg.dpi_scale,
            .padding_y = cfg.padding_y * cfg.dpi_scale,
            .coverage_boost = cfg.coverage_boost,
            .coverage_add = cfg.coverage_add,
            .smoothing = cfg.smoothing,
            .hinting = cfg.hinting,
            .ligatures = cfg.ligatures,
            .embolden = cfg.embolden,
        };
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
        c.sgl_load_pipeline(self.atlas_pip);
        c.sgl_enable_texture();
        c.sgl_texture(self.atlas_view, self.atlas_ui_smp);
        c.sgl_begin_quads();

        const fg = @import("../term/ghostty.zig").ColorRgb{ .r = r, .g = g, .b = b };
        var px = @round(x);
        const py = @round(y);
        var i: usize = 0;
        while (i < text.len) {
            const cp_len = utf8CodepointLen(text[i]);
            const end = @min(i + cp_len, text.len);
            self.batchGlyphs(px, py, text[i..end], face_idx, fg, .ui);
            px += self.cell_w;
            i = end;
        }

        c.sgl_end();
        c.sgl_disable_texture();
    }

    pub fn deinit(self: *FtRenderer) void {
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
        render_state: ?*anyopaque,
        row_iterator: *?*anyopaque,
        row_cells: *?*anyopaque,
        screen_w: f32,
        screen_h: f32,
    ) void {
        self.queueInViewport(runtime, render_state, row_iterator, row_cells, 0, 0, screen_w, screen_h, screen_w, screen_h, true);
        c.sgl_draw();
    }

    /// Queue geometry for one pane into its viewport sub-rect.
    /// Does NOT call sgl_draw() — the caller must call sgl_draw() exactly once
    /// per frame after all queueInViewport() calls are done.
    /// `is_focused` controls whether the cursor is drawn for this pane.
    pub fn queueInViewport(
        self: *FtRenderer,
        runtime: *ghostty.Runtime,
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
    ) void {
        _ = fb_w;
        _ = fb_h;
        const colors = runtime.renderStateColors(render_state) orelse return;
        const default_bg = colors.background;
        const default_fg = colors.foreground;

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
        const run_buf_len = @max(@as(usize, 1), @as(usize, row_count) * @as(usize, col_count) * 4);
        const run_buf = self.allocator.alloc(u8, run_buf_len) catch return;
        defer self.allocator.free(run_buf);

        // ── Pass 1: Background & Rasterisation ──────────────────────────────
        if (runtime.populateRowIterator(render_state, row_iterator)) {
            var row_y: usize = 0;
            var quads_open = false;
            while (runtime.nextRow(row_iterator.*)) : (row_y += 1) {
                if (!runtime.populateRowCells(row_iterator.*, row_cells)) continue;
                const py = self.padding_y + @as(f32, @floatFromInt(row_y)) * self.cell_h;
                var col_x: usize = 0;
                var run_start_col: usize = 0;
                var run_len: usize = 0;
                var run_face_idx: u8 = 0;
                var run_fg = default_fg;
                while (runtime.nextCell(row_cells.*)) : (col_x += 1) {
                    // Background
                    const bg = runtime.cellBackground(row_cells.*) orelse default_bg;
                    if (bg.r != default_bg.r or bg.g != default_bg.g or bg.b != default_bg.b) {
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

                    // Rasterisation
                    const grapheme_len = runtime.cellGraphemeLen(row_cells.*);
                    const fg = runtime.cellForeground(row_cells.*) orelse default_fg;
                    const style = runtime.cellStyle(row_cells.*);
                    const face_idx: u8 = if (style) |s| blk: {
                        if (s.bold and s.italic) break :blk 2;
                        if (s.bold) break :blk 1;
                        if (s.italic) break :blk 3;
                        break :blk 0;
                    } else 0;

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
        }

        // ── Pass 2: Glyph draw pass ────────────────────────────────────────
        if (runtime.populateRowIterator(render_state, row_iterator)) {
            c.sgl_load_pipeline(self.atlas_pip);
            c.sgl_enable_texture();
            c.sgl_texture(self.atlas_view, self.atlas_smp);
            c.sgl_begin_quads();

            var row_y: usize = 0;
            while (runtime.nextRow(row_iterator.*)) : (row_y += 1) {
                if (!runtime.populateRowCells(row_iterator.*, row_cells)) continue;
                const py = self.padding_y + @as(f32, @floatFromInt(row_y)) * self.cell_h;
                var col_x: usize = 0;
                var run_start_col: usize = 0;
                var run_len: usize = 0;
                var run_face_idx: u8 = 0;
                var run_fg = default_fg;
                while (runtime.nextCell(row_cells.*)) : (col_x += 1) {
                    const grapheme_len = runtime.cellGraphemeLen(row_cells.*);
                    const fg = runtime.cellForeground(row_cells.*) orelse default_fg;
                    const style = runtime.cellStyle(row_cells.*);
                    const face_idx: u8 = if (style) |s| blk: {
                        if (s.bold and s.italic) break :blk 2;
                        if (s.bold) break :blk 1;
                        if (s.italic) break :blk 3;
                        break :blk 0;
                    } else 0;

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
                        self.batchGlyphs(px, py, self.glyph_buf[0..glyph_len], face_idx, fg, .terminal);
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
                }
                if (run_len > 0) {
                    flushDrawRun(self, run_buf, &run_start_col, &run_len, run_face_idx, run_fg, py);
                }
            }
            c.sgl_end();
            c.sgl_disable_texture();
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
                const cursor_color: ghostty.ColorRgb = if (colors.cursor_has_value)
                    colors.cursor
                else
                    .{ .r = 220, .g = 220, .b = 220 };
                drawCursor(cx, cy, self.cell_w, self.cell_h, cursor_color, runtime.cursorVisualStyle(render_state));
            }
        }

        if (!self.logged_first_draw) self.logged_first_draw = true;
    }

    /// Pre-rasterize glyphs for a cell to ensure they are in the atlas.
    fn preRasterize(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode) void {
        const result = self.getOrShape(utf8, face_idx) orelse return;
        for (result.glyphs) |glyph_inst| {
            _ = self.getOrRasterize(glyph_inst.glyph_id, result.raster_face_index, raster_mode);
        }
    }

    /// Shape and batch glyphs for one cell at (px, py).
    fn batchGlyphs(self: *FtRenderer, px: f32, py: f32, utf8: []const u8, face_idx: u8, fg: ghostty.ColorRgb, raster_mode: RasterMode) void {
        const result = self.getOrShape(utf8, face_idx) orelse return;

        var x_offset: f32 = 0;
        for (result.glyphs) |glyph_inst| {
            const glyph = self.getOrRasterize(glyph_inst.glyph_id, result.raster_face_index, raster_mode) orelse continue;

            const gx = px + x_offset + glyph_inst.x_offset + @as(f32, @floatFromInt(glyph.bear_x));
            const gy = py + self.ascender - glyph_inst.y_offset - @as(f32, @floatFromInt(glyph.bear_y));

            const w = @as(f32, @floatFromInt(glyph.bw));
            const h = @as(f32, @floatFromInt(glyph.bh));
            if (w > 0 and h > 0) {
                c.sgl_c4b(fg.r, fg.g, fg.b, 255);
                c.sgl_v2f_t2f(gx, gy, glyph.s0, glyph.t0);
                c.sgl_v2f_t2f(gx + w, gy, glyph.s1, glyph.t0);
                c.sgl_v2f_t2f(gx + w, gy + h, glyph.s1, glyph.t1);
                c.sgl_v2f_t2f(gx, gy + h, glyph.s0, glyph.t1);
            }

            x_offset += glyph_inst.x_advance;
        }
    }

    fn preRasterizeRun(self: *FtRenderer, utf8: []const u8, face_idx: u8, raster_mode: RasterMode) void {
        const result = self.getOrShape(utf8, face_idx) orelse return;
        for (result.glyphs) |glyph_inst| {
            _ = self.getOrRasterize(glyph_inst.glyph_id, result.raster_face_index, raster_mode);
        }
    }

    fn batchGlyphRun(self: *FtRenderer, px: f32, py: f32, utf8: []const u8, face_idx: u8, fg: ghostty.ColorRgb, raster_mode: RasterMode) void {
        const result = self.getOrShape(utf8, face_idx) orelse return;

        var pen_x: f32 = 0;
        for (result.glyphs) |glyph_inst| {
            const glyph = self.getOrRasterize(glyph_inst.glyph_id, result.raster_face_index, raster_mode) orelse continue;
            const gx = px + pen_x + glyph_inst.x_offset + @as(f32, @floatFromInt(glyph.bear_x));
            const gy = py + self.ascender - glyph_inst.y_offset - @as(f32, @floatFromInt(glyph.bear_y));

            const w = @as(f32, @floatFromInt(glyph.bw));
            const h = @as(f32, @floatFromInt(glyph.bh));
            if (w > 0 and h > 0) {
                c.sgl_c4b(fg.r, fg.g, fg.b, 255);
                c.sgl_v2f_t2f(gx, gy, glyph.s0, glyph.t0);
                c.sgl_v2f_t2f(gx + w, gy, glyph.s1, glyph.t0);
                c.sgl_v2f_t2f(gx + w, gy + h, glyph.s1, glyph.t1);
                c.sgl_v2f_t2f(gx, gy + h, glyph.s0, glyph.t1);
            }

            pen_x += glyph_inst.x_advance;
        }
    }

    fn flushRasterRun(self: *FtRenderer, run_buf: []u8, run_start_col: *usize, run_len: *usize, face_idx: u8, fg: ghostty.ColorRgb, py: f32) void {
        _ = fg;
        _ = py;
        if (run_len.* == 0) return;
        self.preRasterizeRun(run_buf[0..run_len.*], face_idx, .terminal);
        run_start_col.* = 0;
        run_len.* = 0;
    }

    fn flushDrawRun(self: *FtRenderer, run_buf: []u8, run_start_col: *usize, run_len: *usize, face_idx: u8, fg: ghostty.ColorRgb, py: f32) void {
        if (run_len.* == 0) return;
        const px = self.padding_x + @as(f32, @floatFromInt(run_start_col.*)) * self.cell_w;
        self.batchGlyphRun(px, py, run_buf[0..run_len.*], face_idx, fg, .terminal);
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
    }

    /// Upload atlas to GPU if it has been modified and not yet uploaded this frame.
    /// Safe to call multiple times per frame — only the first call uploads.
    pub fn flushAtlasIfDirty(self: *FtRenderer) void {
        if (self.atlas_dirty) {
            self.flushAtlas();
            self.atlas_dirty = false;
        }
    }

    fn flushAtlas(self: *FtRenderer) void {
        if (self.atlas_uploaded_this_frame) return;
        var upd = std.mem.zeroes(c.sg_image_data);
        upd.mip_levels[0].ptr = self.atlas_data.ptr;
        upd.mip_levels[0].size = ATLAS_W * ATLAS_H * ATLAS_BPP;
        c.sg_update_image(self.atlas_img, &upd);
        self.atlas_uploaded_this_frame = true;
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
                flags |= ft.FT_LOAD_FORCE_AUTOHINT;
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

fn colorsEqual(a: ghostty.ColorRgb, b: ghostty.ColorRgb) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
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

fn loadConfiguredFace(allocator: std.mem.Allocator, lib: ft.FT_Library, path: ?[]const u8, embedded: []const u8, size_px: f32) !ft.FT_Face {
    if (path) |p| {
        return loadFaceFromPath(allocator, lib, p, size_px) catch loadFace(lib, embedded, size_px);
    }
    return loadFace(lib, embedded, size_px);
}

fn loadFaceFromPath(allocator: std.mem.Allocator, lib: ft.FT_Library, path: []const u8, size_px: f32) !ft.FT_Face {
    const zpath = try allocator.dupeZ(u8, path);
    defer allocator.free(zpath);

    var face: ft.FT_Face = null;
    const err = ft.FT_New_Face(lib, zpath.ptr, 0, &face);
    if (err != 0 or face == null) return error.FtLoadFaceFailed;
    errdefer _ = ft.FT_Done_Face(face);

    const px: c_uint = @intFromFloat(@round(size_px));
    if (ft.FT_Set_Pixel_Sizes(face, 0, px) != 0) return error.FtSetSizeFailed;
    return face;
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

fn drawGlyphQuad(
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    s0: f32,
    t0: f32,
    s1: f32,
    t1: f32,
    view: c.sg_view,
    smp: c.sg_sampler,
    pip: c.sgl_pipeline,
    r: u8,
    g: u8,
    b: u8,
) void {
    const rf = @as(f32, @floatFromInt(r)) / 255.0;
    const gf = @as(f32, @floatFromInt(g)) / 255.0;
    const bf = @as(f32, @floatFromInt(b)) / 255.0;

    c.sgl_load_pipeline(pip);
    c.sgl_enable_texture();
    c.sgl_texture(view, smp);
    c.sgl_begin_quads();
    c.sgl_c4f(rf, gf, bf, 1.0);
    c.sgl_v2f_t2f(x, y, s0, t0);
    c.sgl_v2f_t2f(x + w, y, s1, t0);
    c.sgl_v2f_t2f(x + w, y + h, s1, t1);
    c.sgl_v2f_t2f(x, y + h, s0, t1);
    c.sgl_end();
    c.sgl_disable_texture();
}

fn drawCursor(x: f32, y: f32, w: f32, h: f32, color: ghostty.ColorRgb, style: ghostty.CursorVisualStyle) void {
    switch (style) {
        .block => drawRect(x, y, w, h, color.r, color.g, color.b, 180),
        .block_hollow => {
            const t: f32 = 1.5;
            drawRect(x, y, w, t, color.r, color.g, color.b, 220);
            drawRect(x, y + h - t, w, t, color.r, color.g, color.b, 220);
            drawRect(x, y, t, h, color.r, color.g, color.b, 220);
            drawRect(x + w - t, y, t, h, color.r, color.g, color.b, 220);
        },
        .bar => drawRect(x, y, 2.0, h, color.r, color.g, color.b, 220),
        .underline => drawRect(x, y + h - 2.0, w, 2.0, color.r, color.g, color.b, 220),
    }
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
