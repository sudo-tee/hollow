const std = @import("std");
const builtin = @import("builtin");
const c = @import("sokol_c");
const App = @import("../app.zig").App;
const ghostty = @import("../term/ghostty.zig");
const bar = @import("../ui/bar.zig");
const LayoutLeaf = @import("../mux.zig").LayoutLeaf;
const MAX_LAYOUT_LEAVES = @import("../mux.zig").MAX_LAYOUT_LEAVES;
const FtRenderer = @import("ft_renderer.zig").FtRenderer;
const FtRendererConfig = @import("ft_renderer.zig").FtRendererConfig;
const PaneCache = @import("ft_renderer.zig").PaneCache;
const Pane = @import("../pane.zig").Pane;

var g_app: ?*App = null;
var g_title_buf: [256]u8 = [_]u8{0} ** 256;
var g_renderer_ready = false;
var g_logged_first_frame = false;
var g_frame_index: usize = 0;
var g_logged_first_key = false;
var g_logged_first_char = false;
var g_logged_first_mouse = false;
var g_logged_first_scroll = false;
var g_ft_renderer: ?FtRenderer = null;
var g_gui_ready_fired = false;
var g_last_frame_time_ns: i128 = 0;
var g_last_perf_sample_ns: i128 = 0;
var g_perf_accum_frame_ns: i128 = 0;
var g_perf_accum_frames: usize = 0;
var g_perf_fps: f32 = 0;
var g_perf_frame_ms: f32 = 0;
// Rolling max frame time: max delta seen across the current perf sample window.
var g_perf_window_max_frame_ns: i128 = 0;
// Worst-case frame time (ms) over the last completed sample window.
var g_perf_max_frame_ms: f32 = 0;

// Per-phase timing accumulators (logged every 2 seconds).
var g_phase_accum_tick_ns: i128 = 0;
var g_phase_accum_offscreen_ns: i128 = 0;
var g_phase_accum_swapchain_ns: i128 = 0;
var g_phase_accum_dirty_frames: usize = 0;
var g_phase_accum_clean_frames: usize = 0;
var g_phase_sample_frames: usize = 0;
var g_phase_last_log_ns: i128 = 0;
// Row-level dirty counters (reset every log interval).
var g_phase_accum_rows_rendered: usize = 0;
var g_phase_accum_rows_skipped: usize = 0;
// Sub-offscreen split: CPU cell-iteration vs GPU flush.
var g_phase_accum_queue_ns: i128 = 0;
var g_phase_accum_gpu_ns: i128 = 0;
// Sub-queue split: pass1 (bg quads) vs pass2 (glyph draw).
var g_phase_accum_pass1_ns: i128 = 0;
var g_phase_accum_pass2_ns: i128 = 0;
// Cell/glyph/bg-rect diagnostic counters (reset every log interval).
var g_phase_accum_cells_visited: usize = 0;
var g_phase_accum_glyph_runs: usize = 0;
var g_phase_accum_bg_rects: usize = 0;
var g_phase_accum_atlas_flushes: usize = 0;
// Render-mode counter: how many frames used direct render vs cache/blit this window.
var g_phase_accum_direct_frames: usize = 0;
var g_phase_accum_cached_frames: usize = 0;

// Last-frame timing breakdown (ms) for the debug overlay — updated every frame.
var g_last_frame_tick_ms: f32 = 0;
var g_last_frame_offscreen_ms: f32 = 0;
var g_last_frame_queue_ms: f32 = 0;
var g_last_frame_gpu_ms: f32 = 0;
var g_last_frame_swap_ms: f32 = 0;
// Frame-local queue/gpu accumulators, reset at frame start, captured at offscreen end.
var g_frame_queue_ns: i128 = 0;
var g_frame_gpu_ns: i128 = 0;

// Per-pane render-to-texture caches.
// Keyed by pane pointer (stable for the lifetime of the pane).
// MAX_LAYOUT_LEAVES is the max concurrent panes we ever render.
const MAX_PANE_CACHES = 32;
/// Open-addressing hash map capacity for per-row content caching.
/// Keys are GhosttyRow raw values (u64); values are cell-content hashes (u64).
/// Must be a power of 2.  2048 slots at 2×8 bytes = 32 KB per pane — fine.
const ROW_MAP_CAP = 2048;
const ROW_MAP_MASK = ROW_MAP_CAP - 1;
const ROW_MAP_EMPTY: u64 = 0; // sentinel: slot is unoccupied
const PaneCacheEntry = struct {
    pane: *const Pane,
    cache: PaneCache,
    /// The atlas_epoch value at the time this pane was last rendered to its RT.
    /// When renderer.atlas_epoch > last_atlas_epoch, the atlas changed since the
    /// last render and the pane must do a full redraw (force_full = true) to pick
    /// up the new glyph bitmaps even if the pane's own content is unchanged.
    last_atlas_epoch: u64 = 0,
    /// Open-addressing hash map: GhosttyRow raw value → cell-content hash.
    /// Scroll-stable: the same row's raw value is invariant across screen shifts,
    /// so hashes survive scrolling and only rows with genuinely changed content
    /// are re-rendered.
    /// Slot is empty when key == ROW_MAP_EMPTY (0).
    row_map_keys: [ROW_MAP_CAP]u64 = [_]u64{ROW_MAP_EMPTY} ** ROW_MAP_CAP,
    row_map_vals: [ROW_MAP_CAP]u64 = [_]u64{0} ** ROW_MAP_CAP,
    /// Cursor row from the *previous* rendered frame (0-based).
    /// Used to force-clear old cursor pixels when the cursor moves to a new row
    /// and ghostty does not mark the old cursor row as dirty (content unchanged).
    /// Initialised to maxInt(usize) so it matches no row on the first frame.
    prev_cursor_row: usize = std.math.maxInt(usize),
};
var g_pane_caches: [MAX_PANE_CACHES]?PaneCacheEntry = [_]?PaneCacheEntry{null} ** MAX_PANE_CACHES;

/// Find or create a PaneCacheEntry for the given pane at the given pixel dimensions.
/// If the existing cache is the wrong size it is destroyed and recreated.
fn getOrCreatePaneCacheEntry(pane: *const Pane, w: u32, h: u32) ?*PaneCacheEntry {
    if (w == 0 or h == 0) return null;
    // Search for an existing entry.
    var free_slot: usize = MAX_PANE_CACHES;
    for (&g_pane_caches, 0..) |*slot, i| {
        if (slot.*) |*entry| {
            if (entry.pane == pane) {
                if (entry.cache.needsResize(w, h)) {
                    entry.cache.deinit();
                    entry.cache = PaneCache.init(w, h);
                    entry.last_atlas_epoch = 0; // size changed — force full redraw next frame
                }
                return entry;
            }
        } else {
            if (free_slot == MAX_PANE_CACHES) free_slot = i;
        }
    }
    // Not found — allocate a new slot.
    if (free_slot == MAX_PANE_CACHES) {
        std.log.warn("sokol_runtime: pane cache table full ({d} entries)", .{MAX_PANE_CACHES});
        return null;
    }
    g_pane_caches[free_slot] = .{
        .pane = pane,
        .cache = PaneCache.init(w, h),
        .last_atlas_epoch = 0,
    };
    return &g_pane_caches[free_slot].?;
}

/// Convenience wrapper returning only the PaneCache (for blit-only callers).
fn getOrCreatePaneCache(pane: *const Pane, w: u32, h: u32) ?*PaneCache {
    const entry = getOrCreatePaneCacheEntry(pane, w, h) orelse return null;
    return &entry.cache;
}

/// Release the cache entry for a pane that has been destroyed.
fn releasePaneCache(pane: *const Pane) void {
    for (&g_pane_caches) |*slot| {
        if (slot.*) |*entry| {
            if (entry.pane == pane) {
                entry.cache.deinit();
                slot.* = null;
                return;
            }
        }
    }
}

const CustomTabLayout = struct {
    x: f32,
    width: f32,
    title: []const u8,
    fg: ?ghostty.ColorRgb = null,
    bg: ?ghostty.ColorRgb = null,
    bold: bool = false,
};

fn utf8CodepointLen(first_byte: u8) usize {
    if (first_byte < 0x80) return 1;
    if (first_byte < 0xE0) return 2;
    if (first_byte < 0xF0) return 3;
    return 4;
}

fn takeCodepoints(text: []const u8, count: usize) []const u8 {
    var used_bytes: usize = 0;
    var used_codepoints: usize = 0;
    while (used_bytes < text.len and used_codepoints < count) {
        const cp_len = utf8CodepointLen(text[used_bytes]);
        if (used_bytes + cp_len > text.len) break;
        used_bytes += cp_len;
        used_codepoints += 1;
    }
    return text[0..used_bytes];
}

fn countCodepoints(text: []const u8) usize {
    var used_bytes: usize = 0;
    var used_codepoints: usize = 0;
    while (used_bytes < text.len) {
        const cp_len = utf8CodepointLen(text[used_bytes]);
        if (used_bytes + cp_len > text.len) break;
        used_bytes += cp_len;
        used_codepoints += 1;
    }
    return used_codepoints;
}

fn fitTabLabel(text: []const u8, max_chars: usize, out_buf: []u8) []const u8 {
    const ellipsis = "...";
    if (max_chars == 0) return "";

    const full = takeCodepoints(text, max_chars);
    if (full.len == text.len) return full;

    if (max_chars <= ellipsis.len) {
        const n = @min(max_chars, out_buf.len);
        @memcpy(out_buf[0..n], ellipsis[0..n]);
        return out_buf[0..n];
    }

    const prefix = takeCodepoints(text, max_chars - ellipsis.len);
    const total = prefix.len + ellipsis.len;
    if (total > out_buf.len) {
        return takeCodepoints(text, max_chars);
    }

    @memcpy(out_buf[0..prefix.len], prefix);
    @memcpy(out_buf[prefix.len..total], ellipsis);
    return out_buf[0..total];
}

fn computeCustomTabLayouts(app: *App, renderer: *FtRenderer, start_x: f32, max_right: f32, layouts: []CustomTabLayout, title_storage: []u8) []CustomTabLayout {
    const tab_count = @min(app.tabCount(), layouts.len);
    if (tab_count == 0 or max_right <= start_x or title_storage.len == 0) return layouts[0..0];

    var temp_title_buf: [256]u8 = undefined;
    const available_width = max_right - start_x;
    if (available_width <= 0) return layouts[0..0];

    var text_used: usize = 0;
    var cursor_x = start_x;
    var layout_count: usize = 0;
    for (0..tab_count) |ti| {
        if (cursor_x >= max_right) break;
        const seg = app.topBarTitleSegment(ti, false, &temp_title_buf);
        const title = seg.text;
        const x = cursor_x;
        const desired_width = @max(renderer.cell_w, @as(f32, @floatFromInt(countCodepoints(title))) * renderer.cell_w);
        const width = @min(desired_width, max_right - x);
        if (width <= 0) break;
        const remaining_storage = title_storage.len - text_used;
        if (remaining_storage == 0) break;
        const copy_len = @min(title.len, remaining_storage);
        @memcpy(title_storage[text_used .. text_used + copy_len], title[0..copy_len]);
        const stored_title = title_storage[text_used .. text_used + copy_len];

        layouts[layout_count] = .{
            .x = x,
            .width = width,
            .title = stored_title,
            .fg = seg.fg,
            .bg = seg.bg,
            .bold = seg.bold,
        };
        text_used += copy_len;
        cursor_x += width;
        layout_count += 1;
    }

    return layouts[0..layout_count];
}

fn drawStatusSegments(renderer: *FtRenderer, x: f32, y: f32, bar_h: f32, segments: []const bar.Segment) f32 {
    var cursor_x = x;
    for (segments) |seg| {
        if (seg.text.len == 0) continue;
        const seg_w = @as(f32, @floatFromInt(countCodepoints(seg.text))) * renderer.cell_w;
        if (seg.bg) |bg| {
            drawBorderRect(cursor_x, 0.0, seg_w, bar_h, bg.r, bg.g, bg.b, 255);
        }
        const fg = seg.fg orelse ghostty.ColorRgb{ .r = 220, .g = 220, .b = 220 };
        renderer.drawLabelFace(cursor_x, y, seg.text, fg.r, fg.g, fg.b, if (seg.bold) 1 else 0);
        c.sgl_load_default_pipeline();
        cursor_x += seg_w;
    }
    return cursor_x;
}

fn drawSingleSegment(renderer: *FtRenderer, x: f32, y: f32, bar_h: f32, segment: bar.Segment, default_fg: ghostty.ColorRgb, default_bg: ?ghostty.ColorRgb) f32 {
    if (segment.text.len == 0) return x;
    const seg_w = @as(f32, @floatFromInt(countCodepoints(segment.text))) * renderer.cell_w;
    if (segment.bg orelse default_bg) |bg| {
        drawBorderRect(x, 0.0, seg_w, bar_h, bg.r, bg.g, bg.b, 255);
    }
    const fg = segment.fg orelse default_fg;
    renderer.drawLabelFace(x, y, segment.text, fg.r, fg.g, fg.b, if (segment.bold) 1 else 0);
    c.sgl_load_default_pipeline();
    return x + seg_w;
}

fn framebufferSize() struct { width: f32, height: f32 } {
    return .{
        .width = c.sapp_widthf(),
        .height = c.sapp_heightf(),
    };
}

fn windowSizeToPixels(width: f32, height: f32) struct { width: u32, height: u32 } {
    return .{
        .width = @max(1, @as(u32, @intFromFloat(width))),
        .height = @max(1, @as(u32, @intFromFloat(height))),
    };
}

pub fn run(app: *App) !void {
    g_app = app;
    g_renderer_ready = false;
    g_logged_first_frame = false;
    g_frame_index = 0;
    g_logged_first_key = false;
    g_logged_first_char = false;
    g_logged_first_mouse = false;
    g_logged_first_scroll = false;
    g_ft_renderer = null;
    g_gui_ready_fired = false;
    g_last_frame_time_ns = 0;
    g_last_perf_sample_ns = 0;
    g_perf_accum_frame_ns = 0;
    g_perf_accum_frames = 0;
    g_perf_fps = 0;
    g_perf_frame_ms = 0;
    g_perf_window_max_frame_ns = 0;
    g_perf_max_frame_ms = 0;

    var desc = std.mem.zeroes(c.sapp_desc);
    desc.user_data = app;
    desc.init_userdata_cb = initCb;
    desc.frame_userdata_cb = frameCb;
    desc.cleanup_userdata_cb = cleanupCb;
    desc.event_userdata_cb = eventCb;
    desc.width = @intCast(app.config.window_width);
    desc.height = @intCast(app.config.window_height);
    desc.high_dpi = true;
    desc.enable_clipboard = true;
    desc.window_title = titleCString(app.config.windowTitle());
    desc.no_vsync = !app.config.vsync;
    std.log.info("sokol: vsync={s}", .{if (app.config.vsync) "on" else "off"});
    std.log.info("sokol: renderer_single_pane_direct={s} (default=false, false=cached RT path)", .{
        if (app.config.renderer_single_pane_direct) "true" else "false",
    });
    std.log.info("sokol: scroll_multiplier={d:.2}", .{app.config.scroll_multiplier});

    c.sapp_run(&desc);
}

fn initCb(user_data: ?*anyopaque) callconv(.c) void {
    const app = appFromUserData(user_data) orelse return;
    std.log.info("sokol init callback", .{});

    var sg_desc = std.mem.zeroes(c.sg_desc);
    sg_desc.environment = c.sglue_environment();
    c.sg_setup(&sg_desc);

    // sokol_gl is required by sokol_fontstash for glyph rendering.
    var sgl_desc = std.mem.zeroes(c.sgl_desc_t);
    sgl_desc.max_vertices = 1 << 20;
    sgl_desc.max_commands = 1 << 18;
    c.sgl_setup(&sgl_desc);

    // Query DPI scale after sg_setup so the GPU context is ready.
    // On a 2× HiDPI display this returns 2.0; on a 1× display it returns 1.0.
    const dpi_scale = c.sapp_dpi_scale();
    std.log.info("sokol dpi_scale={d:.2} font_size={d:.1}", .{ dpi_scale, app.config.fonts.size });

    g_ft_renderer = FtRenderer.init(std.heap.page_allocator, .{
        .font_size = app.config.fonts.size,
        .dpi_scale = dpi_scale,
        .padding_x = app.config.fonts.padding_x,
        .padding_y = app.config.fonts.padding_y,
        .coverage_boost = app.config.fonts.coverage_boost,
        .coverage_add = app.config.fonts.coverage_add,
        .smoothing = switch (app.config.fonts.smoothing) {
            .grayscale => .grayscale,
            .subpixel => .subpixel,
        },
        .hinting = switch (app.config.fonts.hinting) {
            .none => .none,
            .light => .light,
            .normal => .normal,
        },
        .ligatures = app.config.fonts.ligatures,
        .embolden = app.config.fonts.embolden,
        .regular_path = app.config.fonts.regular,
        .bold_path = app.config.fonts.bold,
        .italic_path = app.config.fonts.italic,
        .bold_italic_path = app.config.fonts.bold_italic,
        .fallback_paths = app.config.fonts.fallback_paths.items,
    }) catch |err| blk: {
        std.log.err("ft_renderer init failed: {}", .{err});
        break :blk null;
    };

    // Feed measured cell dimensions back to the terminal so ghostty and the
    // mouse encoder use the correct physical pixel sizes.
    if (g_ft_renderer) |*renderer| {
        renderer.warmupAtlas();
        const cw: u32 = @max(1, @as(u32, @intFromFloat(renderer.cell_w)));
        const ch: u32 = @max(1, @as(u32, @intFromFloat(renderer.cell_h)));
        app.setCellSize(cw, ch);
        const pixel_size = windowSizeToPixels(c.sapp_widthf(), c.sapp_heightf());
        app.requestResize(pixel_size.width, pixel_size.height);
    }

    g_renderer_ready = false;

    app.sendFocus(true) catch {};
}

fn frameCb(user_data: ?*anyopaque) callconv(.c) void {
    const app = appFromUserData(user_data) orelse return;
    const frame_start_ns = std.time.nanoTimestamp();
    updatePerfCounters(frame_start_ns);
    g_frame_index += 1;
    if (!g_logged_first_frame) {
        g_logged_first_frame = true;
        std.log.info("sokol first frame (ft renderer)", .{});
    }
    app.tick() catch {};
    const after_tick_ns = std.time.nanoTimestamp();

    if (app.pending_quit) {
        c.sapp_request_quit();
        return;
    }

    const fb = framebufferSize();
    const width = fb.width;
    const height = fb.height;

    // Resolve background color for the clear pass.
    var clear_r: f32 = 0.07;
    var clear_g: f32 = 0.08;
    var clear_b: f32 = 0.11;
    if (app.ghostty) |*runtime| {
        if (app.activePane()) |pane| {
            if (pane.render_state_ready) {
                if (runtime.renderStateColors(pane.render_state)) |colors| {
                    clear_r = @as(f32, @floatFromInt(colors.background.r)) / 255.0;
                    clear_g = @as(f32, @floatFromInt(colors.background.g)) / 255.0;
                    clear_b = @as(f32, @floatFromInt(colors.background.b)) / 255.0;
                }
            }
        }
    }

    // ── Phase 1: Offscreen passes (render each pane to its cached RT) ────────
    //
    // Must happen BEFORE sg_begin_pass for the swapchain because sokol does not
    // allow nested passes.  For each pane we check the ghostty dirty flag:
    //   - dirty (or cache doesn't exist / wrong size): re-render to RT.
    //   - clean: skip queueInViewport entirely — just blit the cached texture.
    //
    // The atlas is flushed once per frame (inside the first dirty pane's
    // renderToCache call via queueInViewport → flushAtlas).

    // Compute layout once (used in both phases).
    var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
    const leaves = app.computeActiveLayout(&layout_buf);

    // Decide once whether to use direct rendering for single-pane mode.
    // Controlled by config.renderer_single_pane_direct (default false).
    // Prefer the cached RT path for smoother frame pacing; set to true to
    // opt into the lower-latency but burstier direct-render path.
    const use_direct_render = app.config.renderer_single_pane_direct and
        leaves.len == 0 and app.tabBarHeight() == 0;

    if (g_ft_renderer) |*renderer| {
        renderer.beginFrame();
        // Reset frame-local queue/gpu accumulators for the debug overlay.
        g_frame_queue_ns = 0;
        g_frame_gpu_ns = 0;

        // Pre-rasterize tab bar glyphs so they land in the atlas before any
        // pane offscreen pass flushes it (avoids a double sg_update_image).
        if (app.tabBarHeight() > 0 and app.shouldDrawTopBarTabs()) {
            const tc = app.tabCount();
            const close_sym = "\xc3\x97"; // U+00D7 ×
            for (0..tc) |ti| {
                var title_buf: [256]u8 = undefined;
                const title = app.topBarTitleSegment(ti, false, &title_buf).text;
                renderer.preRasterizeLabel(title);
                renderer.preRasterizeLabel(close_sym);
            }
        }

        if (app.ghostty) |*runtime| {
            const do_leaves = leaves.len > 0;
            const single_pane: ?*anyopaque = if (!do_leaves) blk: {
                if (app.activePane()) |p| {
                    if (p.render_state_ready) break :blk p else break :blk null;
                }
                break :blk null;
            } else null;

            // Helper closure: render one pane to its RT if dirty.
            // Returns true if the pane was re-rendered (dirty), false if skipped (clean).
            const renderPane = struct {
                fn call(
                    rend: *FtRenderer,
                    rt: *ghostty.Runtime,
                    pane: *Pane,
                    ox: f32,
                    oy: f32,
                    pw: f32,
                    ph: f32,
                    fb_w: f32,
                    fb_h: f32,
                    focused: bool,
                ) bool {
                    _ = oy;
                    _ = fb_w;
                    _ = fb_h;
                    const pw_u: u32 = @max(1, @as(u32, @intFromFloat(pw)));
                    const ph_u: u32 = @max(1, @as(u32, @intFromFloat(ph)));
                    const cache_entry = getOrCreatePaneCacheEntry(pane, pw_u, ph_u) orelse return false;

                    // Check dirty flag.
                    // We use pane.render_dirty, which tickPanes refreshes from
                    // Ghostty after updateRenderState() computes this frame's
                    // dirty level.
                    _ = ox; // suppress unused warning
                    const dirty_level = pane.render_dirty;
                    // Atlas-epoch check: if the atlas was flushed since this pane's
                    // last render, its existing RT content has stale glyph UVs and
                    // must be fully redrawn. Crucially we use the epoch (not the
                    // atlas_dirty bool) so that panes rendered AFTER the atlas flush
                    // in the same frame don't cause unnecessary full redraws.
                    const atlas_stale = cache_entry.last_atlas_epoch != rend.atlas_epoch;
                    if (dirty_level == .false_value and !atlas_stale) {
                        // Nothing changed — skip re-render, RT still valid.
                        return false;
                    }

                    // Resolve background colour for the clear.
                    var cr: f32 = 0.0;
                    var cg: f32 = 0.0;
                    var cb: f32 = 0.0;
                    if (rt.renderStateColors(pane.render_state)) |colors| {
                        cr = @as(f32, @floatFromInt(colors.background.r)) / 255.0;
                        cg = @as(f32, @floatFromInt(colors.background.g)) / 255.0;
                        cb = @as(f32, @floatFromInt(colors.background.b)) / 255.0;
                    }

                    // atlas stale → full redraw needed (glyph UVs changed under existing pixels).
                    // resize → handled by cache recreation (pw/ph mismatch), so we never see
                    //   a stale RT from a resize here.
                    // .full dirty_level → ghostty uses this for screen switches (alt-screen
                    //   enter/exit), resize, color-change events, and any other event that
                    //   invalidates the whole viewport.  All rows are marked dirty by ghostty,
                    //   but the row map may hold entries from the previous screen (different
                    //   rowRaw keys pointing at now-reused page slots, or same rowRaw key but
                    //   the slot now holds different content on the new screen).  We must
                    //   invalidate the row map so the hash skip does not fire for stale entries.
                    // .true_value dirty_level → normal content update; per-row dirty gives us the
                    //   minimal set of rows to re-render.
                    //
                    // For scrolling: ghostty marks dirty_level=.full and (empirically) marks ALL
                    // rows dirty in rowDirty() after a CSI S, so force_full here doesn't save work
                    // but does force a slow CLEAR action.  Use atlas_stale as the only trigger for
                    // force_full so that scroll frames stay as fast as partial updates.
                    const force_full = atlas_stale;

                    // Invalidate the row map whenever the screen contents cannot be trusted:
                    //   1. atlas_stale: glyph UVs changed, all rows must redraw with correct UVs.
                    //   2. dirty_level == .full: screen switched (alt/normal), resized, or global
                    //      color changed.  Row map entries from the previous screen are stale —
                    //      the hash skip must not fire because page slots may now hold new content
                    //      with the same rowRaw key.
                    if (force_full or dirty_level == .full) {
                        @memset(&cache_entry.row_map_keys, ROW_MAP_EMPTY);
                    }

                    rend.renderToCache(
                        &cache_entry.cache,
                        rt,
                        pane.render_state,
                        &pane.row_iterator,
                        &pane.row_cells,
                        pw,
                        ph,
                        focused,
                        cr,
                        cg,
                        cb,
                        force_full,
                        &cache_entry.row_map_keys,
                        &cache_entry.row_map_vals,
                        cache_entry.prev_cursor_row,
                    );
                    g_phase_accum_rows_rendered += rend.last_rows_rendered;
                    g_phase_accum_rows_skipped += rend.last_rows_skipped;
                    g_phase_accum_queue_ns += rend.last_queue_ns;
                    g_phase_accum_gpu_ns += rend.last_gpu_ns;
                    g_phase_accum_pass1_ns += rend.last_pass1_ns;
                    g_phase_accum_pass2_ns += rend.last_pass2_ns;
                    g_phase_accum_cells_visited += rend.last_cells_visited;
                    g_phase_accum_glyph_runs += rend.last_glyph_runs;
                    g_phase_accum_bg_rects += rend.last_bg_rects;
                    if (rend.last_atlas_flushed) g_phase_accum_atlas_flushes += 1;
                    // Frame-local accumulators for the debug overlay.
                    g_frame_queue_ns += rend.last_queue_ns;
                    g_frame_gpu_ns += rend.last_gpu_ns;

                    // Record the atlas epoch at the time this pane was rendered.
                    // After renderToCache the atlas may have been flushed (epoch advanced)
                    // if this pane introduced new glyphs — record the post-render epoch so
                    // the pane is not forced into another full redraw next frame unless the
                    // atlas changes again.
                    cache_entry.last_atlas_epoch = rend.atlas_epoch;

                    // Update prev_cursor_row for the next frame: the current cursor
                    // row becomes the "previous" cursor row so we can erase ghost
                    // pixels if the cursor moves away next frame.
                    cache_entry.prev_cursor_row = if (rt.cursorPos(pane.render_state)) |cp|
                        @as(usize, cp.y)
                    else
                        std.math.maxInt(usize);

                    // Clear the pane-level dirty flag so subsequent clean frames
                    // are skipped.
                    pane.render_dirty = .false_value;
                    return true;
                }
            }.call;

            if (do_leaves) {
                for (leaves) |leaf| {
                    if (!leaf.pane.render_state_ready) continue;
                    const ox: f32 = @floatFromInt(leaf.bounds.x);
                    const oy: f32 = @floatFromInt(leaf.bounds.y);
                    const pw: f32 = @floatFromInt(leaf.bounds.width);
                    const ph: f32 = @floatFromInt(leaf.bounds.height);
                    const focused = leaf.pane == app.activePane();
                    if (renderPane(renderer, runtime, leaf.pane, ox, oy, pw, ph, width, height, focused)) {
                        g_phase_accum_dirty_frames += 1;
                        g_phase_accum_cached_frames += 1;
                    } else {
                        g_phase_accum_clean_frames += 1;
                    }
                }
            } else if (single_pane) |sp| {
                const pane: *Pane = @ptrCast(@alignCast(sp));
                if (use_direct_render) {
                    // For single pane without tab bar, skip offscreen RT entirely.
                    // We'll render directly in the swapchain pass for lower latency.
                    // Still need to flush atlas if dirty so glyphs are available.
                    const atlas_was_dirty = renderer.atlas_dirty;
                    if (atlas_was_dirty) {
                        renderer.flushAtlas();
                        renderer.atlas_dirty = false;
                        g_phase_accum_atlas_flushes += 1;
                    }
                    // Track if we're rendering this frame (capture atlas state before clear).
                    if (pane.render_dirty != .false_value or atlas_was_dirty) {
                        g_phase_accum_dirty_frames += 1;
                    } else {
                        g_phase_accum_clean_frames += 1;
                    }
                    g_phase_accum_direct_frames += 1;
                } else {
                    // Use cached RT path
                    if (renderPane(renderer, runtime, pane, 0, 0, width, height, width, height, true)) {
                        g_phase_accum_dirty_frames += 1;
                    } else {
                        g_phase_accum_clean_frames += 1;
                    }
                    g_phase_accum_cached_frames += 1;
                }
            }
        }

        // Flush atlas if any new glyphs were rasterized during the offscreen
        // pass(es) — needed before the swapchain pass uses the atlas.
        // Skip for direct render mode (already flushed above).
        if (!use_direct_render) {
            renderer.flushAtlasIfDirty();
        }
    }
    const after_offscreen_ns = std.time.nanoTimestamp();

    // ── Phase 2: Swapchain pass ────────────────────────────────────────────

    // Upload any pending glyph vertices BEFORE beginning the swapchain pass.
    // sg_update_buffer must NOT be called inside an active sg_pass on D3D11.
    // In cached-RT mode this is a no-op (count == 0 after per-pane offscreen flushes).
    // In direct-render mode this uploads the vertices accumulated by drawDirect().
    if (g_ft_renderer) |*renderer| {
        _ = renderer.uploadGlyphVerts();
    }

    var pass = std.mem.zeroes(c.sg_pass);
    pass.swapchain = c.sglue_swapchain();
    pass.action.colors[0].load_action = c.SG_LOADACTION_CLEAR;
    pass.action.colors[0].clear_value = .{ .r = clear_r, .g = clear_g, .b = clear_b, .a = 1.0 };
    c.sg_begin_pass(&pass);

    // Blit each pane's cached RT into the swapchain pass.
    // For single pane without tab bar with direct render enabled, render directly instead.
    // use_direct_render was computed once above before both phases.
    if (g_ft_renderer) |*renderer| {
        if (app.ghostty) |*runtime| {
            const do_leaves = leaves.len > 0;
            if (do_leaves) {
                for (leaves) |leaf| {
                    if (!leaf.pane.render_state_ready) continue;
                    const ox: f32 = @floatFromInt(leaf.bounds.x);
                    const oy: f32 = @floatFromInt(leaf.bounds.y);
                    const pw: f32 = @floatFromInt(leaf.bounds.width);
                    const ph: f32 = @floatFromInt(leaf.bounds.height);
                    const pw_u: u32 = @max(1, @as(u32, @intFromFloat(pw)));
                    const ph_u: u32 = @max(1, @as(u32, @intFromFloat(ph)));
                    if (getOrCreatePaneCache(leaf.pane, pw_u, ph_u)) |cache| {
                        renderer.blitCache(cache, ox, oy, pw, ph, width, height);
                    }
                }
            } else if (app.activePane()) |pane| {
                if (pane.render_state_ready) {
                    if (use_direct_render) {
                        // Direct render: skip the offscreen RT and render straight to swapchain
                        renderer.drawDirect(
                            runtime,
                            pane.render_state,
                            &pane.row_iterator,
                            &pane.row_cells,
                            width,
                            height,
                            pane.render_dirty == .full or renderer.atlas_dirty,
                        );
                        // Accumulate direct-render diagnostics.
                        g_phase_accum_rows_rendered += renderer.last_rows_rendered;
                        g_phase_accum_rows_skipped += renderer.last_rows_skipped;
                        g_phase_accum_cells_visited += renderer.last_cells_visited;
                        g_phase_accum_glyph_runs += renderer.last_glyph_runs;
                        g_phase_accum_bg_rects += renderer.last_bg_rects;
                        if (renderer.last_atlas_flushed) g_phase_accum_atlas_flushes += 1;
                        // Mark pane clean after direct render.
                        pane.render_dirty = .false_value;
                    } else {
                        // Use cached RT
                        const pw_u: u32 = @max(1, @as(u32, @intFromFloat(width)));
                        const ph_u: u32 = @max(1, @as(u32, @intFromFloat(height)));
                        if (getOrCreatePaneCache(pane, pw_u, ph_u)) |cache| {
                            renderer.blitCache(cache, 0, 0, width, height, width, height);
                        }
                    }
                }
            }
        }
    }

    // Draw split borders as filled 2px quads (only when >1 pane).
    // We draw only seam edges (right/bottom of each pane that is not the
    // framebuffer edge) to avoid overdrawing the active pane outline on top
    // of terminal content from neighbouring panes.
    if (leaves.len > 1) {
        const fw: i32 = @intFromFloat(width);
        const fh: i32 = @intFromFloat(height);
        const border_px: f32 = 2.0;

        // Reset viewport + scissor to the full framebuffer so rects are not
        // clipped to the last pane's sub-rect (sgl_defaults() would leave the
        // viewport at whatever queueInViewport set last).
        c.sgl_defaults();
        c.sgl_viewport(0, 0, fw, fh, true);
        c.sgl_scissor_rect(0, 0, fw, fh, true);
        c.sgl_load_default_pipeline();
        c.sgl_matrix_mode_projection();
        c.sgl_load_identity();
        c.sgl_ortho(0.0, width, height, 0.0, -1.0, 1.0);

        const active = app.activePane();
        for (leaves) |leaf| {
            const is_active = leaf.pane == active;
            const x0: f32 = @floatFromInt(leaf.bounds.x);
            const y0: f32 = @floatFromInt(leaf.bounds.y);
            const lw: f32 = @floatFromInt(leaf.bounds.width);
            const lh: f32 = @floatFromInt(leaf.bounds.height);
            const x1 = x0 + lw;
            const y1 = y0 + lh;

            // Colour: active pane gets a light-blue accent; others get a
            // subtle grey.
            const br: u8 = if (is_active) 120 else 60;
            const bg: u8 = if (is_active) 150 else 65;
            const bb: u8 = if (is_active) 220 else 75;
            const ba: u8 = 255;

            // Right seam — only draw if the right edge does not touch the
            // framebuffer boundary (i.e. there is a neighbour to the right).
            if (@as(i32, @intFromFloat(x1)) < fw) {
                // rect drawn at x1 - border_px/2 so it straddles the seam
                drawBorderRect(x1 - border_px / 2.0, y0, border_px, lh, br, bg, bb, ba);
            }
            // Bottom seam — same logic vertically.
            if (@as(i32, @intFromFloat(y1)) < fh) {
                drawBorderRect(x0, y1 - border_px / 2.0, lw, border_px, br, bg, bb, ba);
            }
        }
    }

    // Draw tab bar when ≥2 tabs exist.
    const tbh_u = app.tabBarHeight();
    if (tbh_u > 0) {
        if (g_ft_renderer) |*renderer| {
            const tbh: f32 = @floatFromInt(tbh_u);
            const fw: i32 = @intFromFloat(width);
            const fh: i32 = @intFromFloat(height);

            // Full-framebuffer projection (Y-down, origin top-left).
            c.sgl_defaults();
            c.sgl_viewport(0, 0, fw, fh, true);
            c.sgl_scissor_rect(0, 0, fw, fh, true);
            c.sgl_load_default_pipeline();
            c.sgl_matrix_mode_projection();
            c.sgl_load_identity();
            c.sgl_ortho(0.0, width, height, 0.0, -1.0, 1.0);

            const bar_bg = app.config.top_bar_bg;
            drawBorderRect(0.0, 0.0, width, tbh, bar_bg.r, bar_bg.g, bar_bg.b, 255);

            const tab_count = app.tabCount();
            const active_idx = app.activeTabIndex();
            const tab_w: f32 = if (tab_count > 0) width / @as(f32, @floatFromInt(tab_count)) else width;
            const close_w: f32 = renderer.cell_w + 10.0;
            var title_buf: [256]u8 = undefined;
            var left_text_buf: [512]u8 = undefined;
            var right_text_buf: [512]u8 = undefined;
            var left_segments_buf: [16]bar.Segment = undefined;
            var right_segments_buf: [16]bar.Segment = undefined;
            var custom_tab_layouts: [32]CustomTabLayout = undefined;
            var custom_tab_title_storage: [1024]u8 = undefined;

            const status_y: f32 = @floor((tbh - renderer.cell_h) * 0.5);
            var left_end: f32 = 4.0;
            var right_width: f32 = 0.0;
            var right_start: f32 = width;
            if (app.shouldDrawTopBarStatus()) {
                const left_segments = app.topBarStatus(.left, &left_segments_buf, &left_text_buf);
                const right_segments = app.topBarStatus(.right, &right_segments_buf, &right_text_buf);
                left_end = drawStatusSegments(renderer, 0.0, status_y, tbh, left_segments);
                for (right_segments) |seg| {
                    right_width += @as(f32, @floatFromInt(countCodepoints(seg.text))) * renderer.cell_w;
                }
                right_start = @max(left_end, width - right_width);
                _ = drawStatusSegments(renderer, right_start, status_y, tbh, right_segments);
            }

            if (app.shouldDrawWorkspaceSwitcher()) {
                var ws_buf: [128]u8 = undefined;
                const ws_seg = app.workspaceTitleSegment(app.activeWorkspaceIndex(), &ws_buf);
                const ws_default_bg = if (app.hasCustomWorkspaceTitle()) null else ghostty.ColorRgb{ .r = 36, .g = 39, .b = 48 };
                left_end = drawSingleSegment(renderer, left_end, status_y, tbh, ws_seg, ghostty.ColorRgb{ .r = 205, .g = 210, .b = 225 }, ws_default_bg);
                if (!app.hasCustomWorkspaceTitle()) left_end += renderer.cell_w * 0.5;
            }

            if (app.shouldDrawTopBarTabs()) {
                if (app.hasCustomTopBarTabs()) {
                    const tab_gap: f32 = if (right_width > 0) renderer.cell_w else 0.0;
                    const max_right = if (right_width > 0) right_start - tab_gap else width;
                    const layouts = computeCustomTabLayouts(app, renderer, left_end, max_right, &custom_tab_layouts, &custom_tab_title_storage);
                    for (layouts, 0..) |layout, ti| {
                        const is_active = ti == active_idx;
                        const hover_tab = app.hovered_tab_index != null and app.hovered_tab_index.? == ti;
                        const bg = layout.bg orelse if (is_active)
                            ghostty.ColorRgb{ .r = 64, .g = 68, .b = 86 }
                        else if (hover_tab)
                            ghostty.ColorRgb{ .r = 52, .g = 55, .b = 70 }
                        else
                            ghostty.ColorRgb{ .r = 43, .g = 45, .b = 55 };
                        drawBorderRect(layout.x, 0.0, layout.width, tbh, bg.r, bg.g, bg.b, 255);

                        const label_space = layout.width;
                        const max_label_chars: usize = if (label_space > 0)
                            @max(1, @as(usize, @intFromFloat(label_space / renderer.cell_w)))
                        else
                            0;
                        var display_buf: [256]u8 = undefined;
                        const display_title = fitTabLabel(layout.title, max_label_chars, &display_buf);
                        if (display_title.len > 0) {
                            const fg = layout.fg orelse ghostty.ColorRgb{
                                .r = if (is_active) 255 else 190,
                                .g = if (is_active) 255 else 190,
                                .b = if (is_active) 255 else 190,
                            };
                            renderer.drawLabelFace(@floor(layout.x), status_y, display_title, fg.r, fg.g, fg.b, if (layout.bold) 1 else 0);
                            c.sgl_load_default_pipeline();
                        }
                    }
                } else {
                    for (0..tab_count) |ti| {
                        const tx: f32 = @as(f32, @floatFromInt(ti)) * tab_w;

                        // Tab background.
                        const is_active = ti == active_idx;
                        const bg_r: u8 = if (is_active) 55 else 35;
                        const bg_g: u8 = if (is_active) 58 else 37;
                        const bg_b: u8 = if (is_active) 72 else 46;
                        drawBorderRect(tx + 1.0, 1.0, tab_w - 2.0, tbh - 1.0, bg_r, bg_g, bg_b, 255);

                        // Active tab: top accent line.
                        if (is_active) {
                            drawBorderRect(tx + 1.0, 0.0, tab_w - 2.0, 2.0, 120, 150, 220, 255);
                        }

                        // Tab title text — leave room for the close button on the right.
                        const hover_close = app.hovered_close_tab_index != null and app.hovered_close_tab_index.? == ti;
                        const title_seg = app.topBarTitleSegment(ti, hover_close, &title_buf);
                        const title = title_seg.text;
                        const label_space = tab_w - close_w - renderer.cell_w;
                        const max_label_chars: usize = if (label_space > 0)
                            @max(1, @as(usize, @intFromFloat(label_space / renderer.cell_w)))
                        else
                            0;
                        const label_y: f32 = @floor((tbh - renderer.cell_h) * 0.5);
                        const label_x: f32 = @floor(tx + renderer.cell_w * 0.5);
                        var display_buf: [256]u8 = undefined;
                        const display_title = fitTabLabel(title, max_label_chars, &display_buf);
                        if (display_title.len > 0) {
                            const fg = title_seg.fg orelse ghostty.ColorRgb{
                                .r = if (is_active) 255 else 185,
                                .g = if (is_active) 255 else 185,
                                .b = if (is_active) 255 else 185,
                            };
                            if (title_seg.bg) |bg| {
                                drawBorderRect(tx + 1.0, 1.0, tab_w - 2.0, tbh - 1.0, bg.r, bg.g, bg.b, 255);
                            } else if (!app.hasCustomTopBarTabs()) {
                                const fallback_bg_r: u8 = if (is_active) 55 else 35;
                                const fallback_bg_g: u8 = if (is_active) 58 else 37;
                                const fallback_bg_b: u8 = if (is_active) 72 else 46;
                                drawBorderRect(tx + 1.0, 1.0, tab_w - 2.0, tbh - 1.0, fallback_bg_r, fallback_bg_g, fallback_bg_b, 255);
                            }
                            const draw_x = if (app.hasCustomTopBarTabs()) tx + 1.0 else label_x;
                            renderer.drawLabelFace(draw_x, label_y, display_title, fg.r, fg.g, fg.b, if (title_seg.bold) 1 else 0);
                            // After drawLabel the pipeline changed; restore defaults for rects.
                            c.sgl_load_default_pipeline();
                        }

                        // Close button "×".
                        const close_x: f32 = @floor(tx + tab_w - close_w + 2.0);
                        const close_y: f32 = @floor((tbh - renderer.cell_h) * 0.5);
                        if (hover_close) {
                            drawBorderRect(close_x - 4.0, 3.0, close_w - 2.0, tbh - 6.0, 92, 44, 44, 255);
                        }
                        renderer.drawLabelFace(close_x, close_y - 1.0, "\xc3\x97", if (hover_close) 255 else 215, if (hover_close) 220 else 140, if (hover_close) 220 else 140, 1); // U+00D7 ×
                        c.sgl_load_default_pipeline();

                        // Separator line between tabs.
                        if (ti + 1 < tab_count) {
                            drawBorderRect(tx + tab_w - 1.0, 1.0, 1.0, tbh - 2.0, 50, 52, 65, 255);
                        }
                    }
                }
            }

            if (app.config.debug_overlay) {
                drawDebugOverlay(app, renderer, width, height);
            }
        }
    }

    // Flush all queued geometry — exactly once per frame.
    c.sgl_draw();

    // Draw glyph quads through the custom gamma-correct pipeline.
    // In direct-render mode these are the glyphs accumulated by drawDirect().
    // In cached-RT mode this is a no-op (glyph_verts_count == 0 after per-pane offscreen draws).
    //
    // NOTE: sg_update_buffer is normally illegal inside an active pass on D3D11.
    // The pre-pass uploadGlyphVerts() handles the normal path.  The second call
    // here is only needed when verts are added *during* the swapchain pass (e.g.
    // direct-render mode).  In cached-RT mode count is 0 so it's a no-op.
    // In direct-render mode, drawDirect() adds verts but uploadGlyphVerts() was
    // called before sg_begin_pass when count was still 0, so we need another
    // upload here.  sg_update_buffer inside a pass is technically invalid on
    // D3D11 debug; the real fix is to call drawDirect() before sg_begin_pass too.
    // For now we keep this as a safety net — it will be hit only in direct-render
    // mode which is disabled by default.
    if (g_ft_renderer) |*renderer| {
        renderer.drawGlyphQuads(width, height, false, .{ 0.0, 0.0, 0.0, 1.0 });
    }

    c.sg_end_pass();
    c.sg_commit();
    const after_commit_ns = std.time.nanoTimestamp();

    // ── Phase timing accumulation (logged every ~2 s) ─────────────────────
    g_phase_accum_tick_ns += after_tick_ns - frame_start_ns;
    g_phase_accum_offscreen_ns += after_offscreen_ns - after_tick_ns;
    g_phase_accum_swapchain_ns += after_commit_ns - after_offscreen_ns;
    g_phase_sample_frames += 1;

    // Update per-frame last values for the debug overlay (no division needed).
    g_last_frame_tick_ms = @as(f32, @floatFromInt(after_tick_ns - frame_start_ns)) / 1_000_000.0;
    g_last_frame_offscreen_ms = @as(f32, @floatFromInt(after_offscreen_ns - after_tick_ns)) / 1_000_000.0;
    g_last_frame_swap_ms = @as(f32, @floatFromInt(after_commit_ns - after_offscreen_ns)) / 1_000_000.0;
    g_last_frame_queue_ms = @as(f32, @floatFromInt(g_frame_queue_ns)) / 1_000_000.0;
    g_last_frame_gpu_ms = @as(f32, @floatFromInt(g_frame_gpu_ns)) / 1_000_000.0;

    if (g_phase_last_log_ns == 0) g_phase_last_log_ns = frame_start_ns;
    if (frame_start_ns - g_phase_last_log_ns >= 2_000_000_000) {
        const n: f32 = @floatFromInt(@max(1, g_phase_sample_frames));
        const tick_ms = @as(f32, @floatFromInt(g_phase_accum_tick_ns)) / n / 1_000_000.0;
        const off_ms = @as(f32, @floatFromInt(g_phase_accum_offscreen_ns)) / n / 1_000_000.0;
        const swap_ms = @as(f32, @floatFromInt(g_phase_accum_swapchain_ns)) / n / 1_000_000.0;
        const queue_ms = @as(f32, @floatFromInt(g_phase_accum_queue_ns)) / n / 1_000_000.0;
        const gpu_ms = @as(f32, @floatFromInt(g_phase_accum_gpu_ns)) / n / 1_000_000.0;
        const pass1_ms = @as(f32, @floatFromInt(g_phase_accum_pass1_ns)) / n / 1_000_000.0;
        const pass2_ms = @as(f32, @floatFromInt(g_phase_accum_pass2_ns)) / n / 1_000_000.0;
        const dirty = g_phase_accum_dirty_frames;
        const clean = g_phase_accum_clean_frames;
        const rows_rendered = g_phase_accum_rows_rendered;
        const rows_skipped = g_phase_accum_rows_skipped;
        const cells = g_phase_accum_cells_visited;
        const gruns = g_phase_accum_glyph_runs;
        const bgrects = g_phase_accum_bg_rects;
        const atlas_fl = g_phase_accum_atlas_flushes;
        const direct_f = g_phase_accum_direct_frames;
        const cached_f = g_phase_accum_cached_frames;
        std.log.info(
            "frame phases (avg/{d:.0}f): tick={d:.2}ms offscreen={d:.2}ms (queue={d:.2}ms [p1={d:.2}ms p2={d:.2}ms] gpu={d:.2}ms) swapchain={d:.2}ms  dirty={d} clean={d}  rows={d}/{d}  cells={d} gruns={d} bgrects={d} atlas_fl={d}  mode direct={d} cached={d}",
            .{ n, tick_ms, off_ms, queue_ms, pass1_ms, pass2_ms, gpu_ms, swap_ms, dirty, clean, rows_rendered, rows_skipped, cells, gruns, bgrects, atlas_fl, direct_f, cached_f },
        );
        g_phase_accum_tick_ns = 0;
        g_phase_accum_offscreen_ns = 0;
        g_phase_accum_swapchain_ns = 0;
        g_phase_accum_queue_ns = 0;
        g_phase_accum_gpu_ns = 0;
        g_phase_accum_pass1_ns = 0;
        g_phase_accum_pass2_ns = 0;
        g_phase_accum_dirty_frames = 0;
        g_phase_accum_clean_frames = 0;
        g_phase_accum_rows_rendered = 0;
        g_phase_accum_rows_skipped = 0;
        g_phase_accum_cells_visited = 0;
        g_phase_accum_glyph_runs = 0;
        g_phase_accum_bg_rects = 0;
        g_phase_accum_atlas_flushes = 0;
        g_phase_accum_direct_frames = 0;
        g_phase_accum_cached_frames = 0;
        g_phase_sample_frames = 0;
        g_phase_last_log_ns = frame_start_ns;
    }

    g_renderer_ready = true;

    if (!g_gui_ready_fired) {
        g_gui_ready_fired = true;
        app.fireGuiReady();
    }

    c.sapp_set_window_title(titleCString(app.activeTitle()));
}

fn updatePerfCounters(frame_start_ns: i128) void {
    if (g_last_frame_time_ns != 0) {
        const frame_delta = frame_start_ns - g_last_frame_time_ns;
        g_perf_accum_frame_ns += frame_delta;
        g_perf_accum_frames += 1;
        if (frame_delta > g_perf_window_max_frame_ns) {
            g_perf_window_max_frame_ns = frame_delta;
        }
    }

    if (g_last_perf_sample_ns == 0) g_last_perf_sample_ns = frame_start_ns;
    const sample_delta = frame_start_ns - g_last_perf_sample_ns;
    if (sample_delta >= std.time.ns_per_s / 4 and g_perf_accum_frames > 0) {
        const sample_seconds = @as(f32, @floatFromInt(sample_delta)) / @as(f32, @floatFromInt(std.time.ns_per_s));
        g_perf_fps = @as(f32, @floatFromInt(g_perf_accum_frames)) / sample_seconds;
        g_perf_frame_ms = (@as(f32, @floatFromInt(g_perf_accum_frame_ns)) / @as(f32, @floatFromInt(g_perf_accum_frames))) / @as(f32, @floatFromInt(std.time.ns_per_ms));
        g_perf_max_frame_ms = @as(f32, @floatFromInt(g_perf_window_max_frame_ns)) / @as(f32, @floatFromInt(std.time.ns_per_ms));
        g_last_perf_sample_ns = frame_start_ns;
        g_perf_accum_frame_ns = 0;
        g_perf_accum_frames = 0;
        g_perf_window_max_frame_ns = 0;
    }

    g_last_frame_time_ns = frame_start_ns;
}

fn drawDebugOverlay(app: *App, renderer: *FtRenderer, width: f32, height: f32) void {
    var runtime = app.ghostty;
    const pane = app.activePane();

    var rows: u16 = 0;
    var cols: u16 = 0;
    var scroll_total: u64 = 0;
    var scroll_offset: u64 = 0;
    var scroll_len: u64 = 0;
    if (runtime) |*rt| {
        if (pane) |p| {
            cols = rt.renderStateCols(p.render_state) orelse 0;
            rows = rt.renderStateRows(p.render_state) orelse 0;
            if (rt.terminalScrollbar(p.terminal)) |scrollbar| {
                scroll_total = scrollbar.total;
                scroll_offset = scrollbar.offset;
                scroll_len = scrollbar.len;
            }
        }
    }

    const render_mode: []const u8 = if (app.config.renderer_single_pane_direct and
        app.activePane() != null and app.tabBarHeight() == 0) "direct" else "cached";
    const dirty_count = g_phase_accum_dirty_frames;
    const clean_count = g_phase_accum_clean_frames;

    var lines: [11][96]u8 = undefined;
    const text0 = std.fmt.bufPrint(&lines[0], "fps {d:.1}  max {d:.2}ms", .{ g_perf_fps, g_perf_max_frame_ms }) catch "fps ?";
    const text1 = std.fmt.bufPrint(&lines[1], "avg {d:.2}ms", .{g_perf_frame_ms}) catch "frame ?";
    const text2 = std.fmt.bufPrint(&lines[2], "grid {d}x{d}", .{ cols, rows }) catch "grid ?";
    const text3 = std.fmt.bufPrint(&lines[3], "tabs {d} ws {d}", .{ app.tabCount(), app.workspaceCount() }) catch "tabs ?";
    const text4 = std.fmt.bufPrint(&lines[4], "scroll {d}/{d} vis {d}", .{ scroll_offset, scroll_total, scroll_len }) catch "scroll ?";
    const text5 = std.fmt.bufPrint(&lines[5], "frame #{d}", .{g_frame_index}) catch "frame #?";
    const text6 = std.fmt.bufPrint(&lines[6], "mode {s}", .{render_mode}) catch "mode ?";
    const text7 = std.fmt.bufPrint(&lines[7], "dirty {d} clean {d}", .{ dirty_count, clean_count }) catch "dirty ?";
    const text8 = std.fmt.bufPrint(&lines[8], "rows r={d} s={d}", .{ g_phase_accum_rows_rendered, g_phase_accum_rows_skipped }) catch "rows ?";
    const text9 = std.fmt.bufPrint(&lines[9], "cells={d} gruns={d} bgrects={d}", .{ g_phase_accum_cells_visited, g_phase_accum_glyph_runs, g_phase_accum_bg_rects }) catch "cells ?";
    // Per-frame breakdown: tick / offscreen (= queue + gpu) / swap
    const text10 = std.fmt.bufPrint(&lines[10], "t={d:.2} off={d:.2}(q={d:.2} g={d:.2}) sw={d:.2}", .{
        g_last_frame_tick_ms,  g_last_frame_offscreen_ms,
        g_last_frame_queue_ms, g_last_frame_gpu_ms,
        g_last_frame_swap_ms,
    }) catch "timing ?";
    const overlay_lines = [_][]const u8{ text0, text1, text2, text3, text4, text5, text6, text7, text8, text9, text10 };

    var max_chars: usize = 0;
    for (overlay_lines) |line| max_chars = @max(max_chars, countCodepoints(line));

    const pad_x = renderer.cell_w * 0.75;
    const pad_y = renderer.cell_h * 0.5;
    const panel_w = @as(f32, @floatFromInt(max_chars)) * renderer.cell_w + pad_x * 2.0;
    const panel_h = @as(f32, @floatFromInt(overlay_lines.len)) * renderer.cell_h + pad_y * 2.0;
    const panel_x = width - panel_w - renderer.cell_w;
    const panel_y = height - panel_h - renderer.cell_h;

    drawBorderRect(panel_x, panel_y, panel_w, panel_h, 20, 22, 29, 230);
    drawBorderRect(panel_x, panel_y, panel_w, 1.0, 122, 162, 247, 255);

    for (overlay_lines, 0..) |line, i| {
        const text_y = panel_y + pad_y + @as(f32, @floatFromInt(i)) * renderer.cell_h;
        renderer.drawLabelFace(panel_x + pad_x, text_y, line, 220, 225, 238, if (i < 2) 1 else 0);
        c.sgl_load_default_pipeline();
    }
}

fn cleanupCb(user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    std.log.info("sokol cleanup callback frame_count={d}", .{g_frame_index});
    if (g_ft_renderer) |*renderer| {
        renderer.deinit();
        g_ft_renderer = null;
    }
    c.sgl_shutdown();
    c.sg_shutdown();
}

fn eventCb(ev: [*c]const c.sapp_event, user_data: ?*anyopaque) callconv(.c) void {
    const app = appFromUserData(user_data) orelse return;
    const event = ev.*;

    if (event.type == c.SAPP_EVENTTYPE_QUIT_REQUESTED) {
        std.log.info("sokol quit requested", .{});
    }

    if (builtin.os.tag == .windows) {
        switch (event.type) {
            c.SAPP_EVENTTYPE_KEY_DOWN => handleKeyDown(app, event),
            c.SAPP_EVENTTYPE_CHAR => handleChar(app, event),
            c.SAPP_EVENTTYPE_MOUSE_DOWN => handleMouseButton(app, event, .press),
            c.SAPP_EVENTTYPE_MOUSE_UP => handleMouseButton(app, event, .release),
            c.SAPP_EVENTTYPE_MOUSE_MOVE => handleMouseMove(app, event),
            c.SAPP_EVENTTYPE_MOUSE_SCROLL => handleScroll(app, event),
            c.SAPP_EVENTTYPE_RESIZED => handleResize(app, event),
            c.SAPP_EVENTTYPE_FOCUSED => app.sendFocus(true) catch {},
            c.SAPP_EVENTTYPE_UNFOCUSED => app.sendFocus(false) catch {},
            c.SAPP_EVENTTYPE_QUIT_REQUESTED => c.sapp_request_quit(),
            else => {},
        }
        return;
    }

    switch (event.type) {
        c.SAPP_EVENTTYPE_KEY_DOWN => handleKeyDown(app, event),
        c.SAPP_EVENTTYPE_CHAR => handleChar(app, event),
        c.SAPP_EVENTTYPE_MOUSE_DOWN => handleMouseButton(app, event, .press),
        c.SAPP_EVENTTYPE_MOUSE_UP => handleMouseButton(app, event, .release),
        c.SAPP_EVENTTYPE_MOUSE_MOVE => handleMouseMove(app, event),
        c.SAPP_EVENTTYPE_MOUSE_SCROLL => app.scrollFloat(event.mouse_x, event.mouse_y, -event.scroll_y),
        c.SAPP_EVENTTYPE_RESIZED => handleResize(app, event),
        c.SAPP_EVENTTYPE_FOCUSED => app.sendFocus(true) catch {},
        c.SAPP_EVENTTYPE_UNFOCUSED => app.sendFocus(false) catch {},
        c.SAPP_EVENTTYPE_QUIT_REQUESTED => c.sapp_request_quit(),
        else => {},
    }
}

fn handleKeyDown(app: *App, event: c.sapp_event) void {
    if (!g_logged_first_key and builtin.os.tag == .windows) {
        g_logged_first_key = true;
        std.log.info("first Windows key event key_code={d}", .{event.key_code});
    }

    const mods = ghosttyMods(event.modifiers);
    const key = mapKey(event.key_code);

    // Give Lua a chance to consume this key before the terminal sees it.
    if (key != .unidentified) {
        const key_name = @tagName(key);
        if (app.fireOnKey(key_name, mods)) return;
    }

    if (key != .unidentified) _ = app.sendKey(key, mods, null) catch {};
}

fn handleChar(app: *App, event: c.sapp_event) void {
    if (!g_logged_first_char and builtin.os.tag == .windows) {
        g_logged_first_char = true;
        std.log.info("first Windows char event char_code={d}", .{event.char_code});
    }

    var utf8_buf: [5]u8 = [_]u8{0} ** 5;
    const utf8 = encodeCodepoint(event.char_code, &utf8_buf) orelse return;
    app.sendText(utf8) catch {};
}

fn handleMouseButton(app: *App, event: c.sapp_event, action: ghostty.MouseAction) void {
    if (!g_logged_first_mouse and builtin.os.tag == .windows) {
        g_logged_first_mouse = true;
        std.log.info("first Windows mouse event button={d} x={d:.2} y={d:.2}", .{ event.mouse_button, event.mouse_x, event.mouse_y });
    }

    // Intercept clicks in the tab bar (only on press; release falls through).
    if (action == .press) {
        const tbh: f32 = @floatFromInt(app.tabBarHeight());
        if (tbh > 0 and event.mouse_y < tbh) {
            if (event.mouse_button == c.SAPP_MOUSEBUTTON_LEFT) {
                const tab_count = app.tabCount();
                const win_w = c.sapp_widthf();
                if (tab_count > 0 and win_w > 0) {
                    if (app.hasCustomTopBarTabs()) {
                        if (app.hovered_tab_index) |ti| app.switchTab(ti);
                        return;
                    }
                    const tab_w: f32 = win_w / @as(f32, @floatFromInt(tab_count));
                    // Guard: tab_w must be positive and finite to avoid @intFromFloat panic.
                    const raw = event.mouse_x / tab_w;
                    const clamped = @min(@as(f32, @floatFromInt(tab_count - 1)), @max(0.0, raw));
                    const ti: usize = @intFromFloat(clamped);
                    // Determine if the close button was hit.
                    // close region: last cell_w + 4 px of the tab slot.
                    const close_w: f32 = if (g_ft_renderer) |r| r.cell_w + 10.0 else 26.0;
                    const tab_right: f32 = (@as(f32, @floatFromInt(ti)) + 1.0) * tab_w;
                    if (event.mouse_x >= tab_right - close_w) {
                        // Close button: switch to that tab first, then close.
                        app.switchTab(ti);
                        app.closeTab();
                    } else {
                        app.switchTab(ti);
                    }
                }
            }
            return; // do not forward to pane
        }
    }

    const button = switch (event.mouse_button) {
        c.SAPP_MOUSEBUTTON_LEFT => ghostty.MouseButton.left,
        c.SAPP_MOUSEBUTTON_RIGHT => ghostty.MouseButton.right,
        c.SAPP_MOUSEBUTTON_MIDDLE => ghostty.MouseButton.middle,
        else => return,
    };
    app.sendMouse(action, button, event.mouse_x, event.mouse_y, ghosttyMods(event.modifiers)) catch {};
}

fn handleMouseMove(app: *App, event: c.sapp_event) void {
    const close_w: f32 = if (g_ft_renderer) |r| r.cell_w + 10.0 else 26.0;
    app.updateTopBarHover(event.mouse_x, event.mouse_y, c.sapp_widthf(), close_w);
    app.sendMouse(.motion, null, event.mouse_x, event.mouse_y, ghosttyMods(event.modifiers)) catch {};
}

fn handleScroll(app: *App, event: c.sapp_event) void {
    if (!g_logged_first_scroll and builtin.os.tag == .windows) {
        g_logged_first_scroll = true;
        std.log.info("first Windows scroll event delta={d:.2}", .{event.scroll_y});
    }
    app.scrollFloat(event.mouse_x, event.mouse_y, -event.scroll_y);
}

fn handleResize(app: *App, event: c.sapp_event) void {
    const pixel_size = windowSizeToPixels(@floatFromInt(event.framebuffer_width), @floatFromInt(event.framebuffer_height));
    app.requestResize(pixel_size.width, pixel_size.height);
}

fn mapKey(key_code: c.sapp_keycode) ghostty.Key {
    return switch (key_code) {
        c.SAPP_KEYCODE_A => .a,
        c.SAPP_KEYCODE_B => .b,
        c.SAPP_KEYCODE_C => .c,
        c.SAPP_KEYCODE_D => .d,
        c.SAPP_KEYCODE_E => .e,
        c.SAPP_KEYCODE_F => .f,
        c.SAPP_KEYCODE_G => .g,
        c.SAPP_KEYCODE_H => .h,
        c.SAPP_KEYCODE_I => .i,
        c.SAPP_KEYCODE_J => .j,
        c.SAPP_KEYCODE_K => .k,
        c.SAPP_KEYCODE_L => .l,
        c.SAPP_KEYCODE_M => .m,
        c.SAPP_KEYCODE_N => .n,
        c.SAPP_KEYCODE_O => .o,
        c.SAPP_KEYCODE_P => .p,
        c.SAPP_KEYCODE_Q => .q,
        c.SAPP_KEYCODE_R => .r,
        c.SAPP_KEYCODE_S => .s,
        c.SAPP_KEYCODE_T => .t,
        c.SAPP_KEYCODE_U => .u,
        c.SAPP_KEYCODE_V => .v,
        c.SAPP_KEYCODE_W => .w,
        c.SAPP_KEYCODE_X => .x,
        c.SAPP_KEYCODE_Y => .y,
        c.SAPP_KEYCODE_Z => .z,
        c.SAPP_KEYCODE_0 => .digit_0,
        c.SAPP_KEYCODE_1 => .digit_1,
        c.SAPP_KEYCODE_2 => .digit_2,
        c.SAPP_KEYCODE_3 => .digit_3,
        c.SAPP_KEYCODE_4 => .digit_4,
        c.SAPP_KEYCODE_5 => .digit_5,
        c.SAPP_KEYCODE_6 => .digit_6,
        c.SAPP_KEYCODE_7 => .digit_7,
        c.SAPP_KEYCODE_8 => .digit_8,
        c.SAPP_KEYCODE_9 => .digit_9,
        c.SAPP_KEYCODE_ENTER => .enter,
        c.SAPP_KEYCODE_TAB => .tab,
        c.SAPP_KEYCODE_BACKSPACE => .backspace,
        c.SAPP_KEYCODE_DELETE => .delete,
        c.SAPP_KEYCODE_INSERT => .insert,
        c.SAPP_KEYCODE_RIGHT => .arrow_right,
        c.SAPP_KEYCODE_LEFT => .arrow_left,
        c.SAPP_KEYCODE_DOWN => .arrow_down,
        c.SAPP_KEYCODE_UP => .arrow_up,
        c.SAPP_KEYCODE_PAGE_UP => .page_up,
        c.SAPP_KEYCODE_PAGE_DOWN => .page_down,
        c.SAPP_KEYCODE_HOME => .home,
        c.SAPP_KEYCODE_END => .end,
        c.SAPP_KEYCODE_SPACE => .space,
        c.SAPP_KEYCODE_MINUS => .minus,
        c.SAPP_KEYCODE_EQUAL => .equal,
        c.SAPP_KEYCODE_LEFT_BRACKET => .bracket_left,
        c.SAPP_KEYCODE_RIGHT_BRACKET => .bracket_right,
        c.SAPP_KEYCODE_BACKSLASH => .backslash,
        c.SAPP_KEYCODE_SEMICOLON => .semicolon,
        c.SAPP_KEYCODE_APOSTROPHE => .quote,
        c.SAPP_KEYCODE_GRAVE_ACCENT => .backquote,
        c.SAPP_KEYCODE_COMMA => .comma,
        c.SAPP_KEYCODE_PERIOD => .period,
        c.SAPP_KEYCODE_SLASH => .slash,
        c.SAPP_KEYCODE_ESCAPE => .escape,
        c.SAPP_KEYCODE_F1 => .f1,
        c.SAPP_KEYCODE_F2 => .f2,
        c.SAPP_KEYCODE_F3 => .f3,
        c.SAPP_KEYCODE_F4 => .f4,
        c.SAPP_KEYCODE_F5 => .f5,
        c.SAPP_KEYCODE_F6 => .f6,
        c.SAPP_KEYCODE_F7 => .f7,
        c.SAPP_KEYCODE_F8 => .f8,
        c.SAPP_KEYCODE_F9 => .f9,
        c.SAPP_KEYCODE_F10 => .f10,
        c.SAPP_KEYCODE_F11 => .f11,
        c.SAPP_KEYCODE_F12 => .f12,
        else => .unidentified,
    };
}

fn ghosttyMods(modifiers: u32) u32 {
    var mods: u32 = ghostty.Mods.none;
    if ((modifiers & c.SAPP_MODIFIER_SHIFT) != 0) mods |= ghostty.Mods.shift;
    if ((modifiers & c.SAPP_MODIFIER_CTRL) != 0) mods |= ghostty.Mods.ctrl;
    if ((modifiers & c.SAPP_MODIFIER_ALT) != 0) mods |= ghostty.Mods.alt;
    if ((modifiers & c.SAPP_MODIFIER_SUPER) != 0) mods |= ghostty.Mods.super;
    return mods;
}

fn titleCString(text: []const u8) [*:0]const u8 {
    const len = @min(text.len, g_title_buf.len - 1);
    @memset(g_title_buf[0..], 0);
    @memcpy(g_title_buf[0..len], text[0..len]);
    g_title_buf[len] = 0;
    return @ptrCast(&g_title_buf);
}

fn encodeCodepoint(codepoint: u32, buf: *[5]u8) ?[]const u8 {
    if (codepoint == 0) return null;
    if (codepoint < 0x80) {
        buf[0] = @intCast(codepoint);
        return buf[0..1];
    }
    if (codepoint < 0x800) {
        buf[0] = @intCast(0xC0 | (codepoint >> 6));
        buf[1] = @intCast(0x80 | (codepoint & 0x3F));
        return buf[0..2];
    }
    if (codepoint < 0x10000) {
        buf[0] = @intCast(0xE0 | (codepoint >> 12));
        buf[1] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (codepoint & 0x3F));
        return buf[0..3];
    }
    buf[0] = @intCast(0xF0 | (codepoint >> 18));
    buf[1] = @intCast(0x80 | ((codepoint >> 12) & 0x3F));
    buf[2] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
    buf[3] = @intCast(0x80 | (codepoint & 0x3F));
    return buf[0..4];
}

fn appFromUserData(user_data: ?*anyopaque) ?*App {
    const ptr = user_data orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// Draw a filled RGBA rectangle using the current sokol_gl projection.
/// Assumes the default pipeline (no texture) is active.
fn drawBorderRect(x: f32, y: f32, w: f32, h: f32, r: u8, g: u8, b: u8, a: u8) void {
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
