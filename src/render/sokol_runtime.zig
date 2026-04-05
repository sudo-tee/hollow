const std = @import("std");
const builtin = @import("builtin");
const c = @import("sokol_c");
const icon_data = @import("icon_data");
const App = @import("../app.zig").App;
const ghostty = @import("../term/ghostty.zig");
const bar = @import("../ui/bar.zig");
const LayoutLeaf = @import("../mux.zig").LayoutLeaf;
const MAX_LAYOUT_LEAVES = @import("../mux.zig").MAX_LAYOUT_LEAVES;
const SplitNode = @import("../mux.zig").SplitNode;
const SplitDirection = @import("../mux.zig").SplitDirection;
const PaneBounds = @import("../mux.zig").PaneBounds;
const FtRenderer = @import("ft_renderer.zig").FtRenderer;
const FtRendererConfig = @import("ft_renderer.zig").FtRendererConfig;
const Config = @import("../config.zig").Config;
const PaneCache = @import("ft_renderer.zig").PaneCache;
const Pane = @import("../pane.zig").Pane;

const win32 = if (builtin.os.tag == .windows) struct {
    const HWND = *anyopaque;
    const LONG_PTR = isize;
    const LRESULT = isize;
    const WNDPROC = *const fn (hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.winapi) LRESULT;
    const RECT = extern struct {
        left: i32,
        top: i32,
        right: i32,
        bottom: i32,
    };

    const GWL_STYLE: c_int = -16;
    const GWLP_WNDPROC: c_int = -4;
    const WS_CAPTION: u32 = 0x00C00000;
    const WS_THICKFRAME: u32 = 0x00040000;
    const WM_NCCALCSIZE: u32 = 0x0083;
    const WM_NCHITTEST: u32 = 0x0084;
    const SWP_NOSIZE: u32 = 0x0001;
    const SWP_NOMOVE: u32 = 0x0002;
    const SWP_NOZORDER: u32 = 0x0004;
    const SWP_NOACTIVATE: u32 = 0x0010;
    const SWP_FRAMECHANGED: u32 = 0x0020;
    const WM_NCLBUTTONDOWN: u32 = 0x00A1;
    const HTCLIENT: usize = 1;
    const HTCAPTION: usize = 2;
    const HTLEFT: usize = 10;
    const HTRIGHT: usize = 11;
    const HTTOP: usize = 12;
    const HTTOPLEFT: usize = 13;
    const HTTOPRIGHT: usize = 14;
    const HTBOTTOM: usize = 15;
    const HTBOTTOMLEFT: usize = 16;
    const HTBOTTOMRIGHT: usize = 17;
    const SM_CXSIZEFRAME: c_int = 32;
    const SM_CYSIZEFRAME: c_int = 33;
    const SM_CXPADDEDBORDER: c_int = 92;

    extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: c_int) callconv(.c) LONG_PTR;
    extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: c_int, dwNewLong: LONG_PTR) callconv(.c) LONG_PTR;
    extern "user32" fn SetWindowPos(
        hWnd: HWND,
        hWndInsertAfter: ?HWND,
        X: c_int,
        Y: c_int,
        cx: c_int,
        cy: c_int,
        uFlags: u32,
    ) callconv(.c) i32;
    extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *RECT) callconv(.c) i32;
    extern "user32" fn GetSystemMetrics(nIndex: c_int) callconv(.c) c_int;
    extern "user32" fn SetCapture(hWnd: HWND) callconv(.c) ?HWND;
    extern "user32" fn ReleaseCapture() callconv(.c) i32;
    extern "user32" fn SendMessageW(hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.c) isize;
    extern "user32" fn CallWindowProcW(lpPrevWndFunc: ?WNDPROC, hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.c) LRESULT;
    extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.c) LRESULT;
    extern "user32" fn LoadCursorW(hInstance: ?*anyopaque, lpCursorName: usize) callconv(.c) ?*anyopaque;
    extern "user32" fn SetCursor(hCursor: ?*anyopaque) callconv(.c) ?*anyopaque;
    // Standard cursor IDs (as usize for use with LoadCursorW's lpCursorName param)
    const IDC_ARROW: usize = 32512;
    const IDC_SIZEWE: usize = 32644;
    const IDC_SIZENS: usize = 32645;
    // winmm — multimedia timer resolution
    extern "winmm" fn timeBeginPeriod(uPeriod: c_uint) callconv(.c) c_uint;
    extern "winmm" fn timeEndPeriod(uPeriod: c_uint) callconv(.c) c_uint;
} else struct {};

var g_app: ?*App = null;
var g_title_buf: [256]u8 = [_]u8{0} ** 256;
var g_renderer_ready = false;
var g_logged_first_frame = false;
var g_frame_index: usize = 0;
var g_ft_renderer: ?FtRenderer = null;
var g_gui_ready_fired = false;
var g_window_chrome_applied = false;
var g_prev_wnd_proc: win32.LONG_PTR = 0;
var g_subclassed_hwnd: ?win32.HWND = null;
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

// ── Pane-divider drag state ───────────────────────────────────────────────────
// When the user presses the left mouse button on a split seam we record the
// node being dragged plus enough context to compute a new ratio from the raw
// mouse position during MOUSE_MOVE events.
//
// `g_drag_node`        — the SplitNode whose ratio we are adjusting (null = not dragging)
// `g_drag_direction`   — .vertical (left/right seam) or .horizontal (top/bottom seam)
// `g_drag_bounds`      — pixel rect of the node (needed to map cursor → ratio)
//
// The ratio formula for a vertical split:
//   new_ratio = (mouse_x - bounds.x) / bounds.width
// For horizontal:
//   new_ratio = (mouse_y - bounds.y) / bounds.height
var g_drag_node: ?*SplitNode = null;
var g_drag_direction: SplitDirection = .vertical;
var g_drag_bounds: PaneBounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
var g_mouse_button_down: ?ghostty.MouseButton = null;
var g_top_bar_cache: TopBarCache = .{};

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
// Dirty-level distribution: how many frames had ghostty dirty_level==.full vs .true_value.
// Useful for split-scroll: every scroll frame should be .full; cursor-blink frames .true_value.
var g_phase_accum_full_dl_frames: usize = 0;
var g_phase_accum_true_dl_frames: usize = 0;
// Atlas-stale frames: how many frames triggered a force_full due to atlas_epoch mismatch.
// If this is high during split-scroll, the atlas is being re-uploaded every frame (glyph churn).
var g_phase_accum_atlas_stale_frames: usize = 0;
// Frames since last drag release — used for post-release diagnostics.
// Set to 0 on release, incremented each frame until > 20.
var g_frames_since_drag_release: usize = std.math.maxInt(usize);

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

const CacheValidity = enum {
    invalid,
    priming,
    valid,
};
const ROW_MAP_EMPTY: u64 = 0; // sentinel: slot is unoccupied
const PaneCacheEntry = struct {
    pane: *const Pane,
    cache: PaneCache,
    /// Newly created or resized render targets must be cleared on their next
    /// render pass; LOAD on an uninitialized RT leaves visible garbage.
    needs_clear: bool = true,
    /// After a geometry change, keep forcing full redraws for a couple of
    /// frames so terminal reflow/resize fallout cannot leave stale glyphs in
    /// the cache.
    force_full_frames: u8 = 2,
    layout_generation: u32 = 0,
    stable_after_resize: bool = false,
    last_cols: u16 = 0,
    last_rows: u16 = 0,
    validity: CacheValidity = .invalid,
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
                    entry.cache.clear();
                    entry.needs_clear = true;
                    entry.force_full_frames = 2;
                    entry.layout_generation = 0;
                    entry.stable_after_resize = false;
                    entry.last_cols = 0;
                    entry.last_rows = 0;
                    entry.validity = .invalid;
                    @memset(&entry.row_map_keys, ROW_MAP_EMPTY);
                    @memset(&entry.row_map_vals, 0);
                    entry.prev_cursor_row = std.math.maxInt(usize);
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
    var new_entry = PaneCacheEntry{
        .pane = pane,
        .cache = PaneCache.init(w, h),
        .needs_clear = true,
        .force_full_frames = 2,
        .layout_generation = 0,
        .stable_after_resize = false,
        .last_cols = 0,
        .last_rows = 0,
        .validity = .invalid,
        .last_atlas_epoch = 0,
    };
    new_entry.cache.clear();
    g_pane_caches[free_slot] = new_entry;
    return &g_pane_caches[free_slot].?;
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

const TopBarHit = struct {
    in_top_bar: bool = false,
    tab_index: ?usize = null,
    close_tab_index: ?usize = null,
};

const MAX_TOP_BAR_TABS = 64;

const CachedTopBarTab = struct {
    x: f32 = 0,
    width: f32 = 0,
    close_x: f32 = 0,
    close_w: f32 = 0,
    has_close: bool = false,
};

const TopBarCache = struct {
    enabled: bool = false,
    width: f32 = 0,
    height: f32 = 0,
    tab_count: usize = 0,
    tabs: [MAX_TOP_BAR_TABS]CachedTopBarTab = [_]CachedTopBarTab{.{}} ** MAX_TOP_BAR_TABS,
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

fn resetTopBarCache(window_width: f32, tbh: f32) void {
    g_top_bar_cache = .{
        .enabled = tbh > 0,
        .width = window_width,
        .height = tbh,
    };
}

fn cacheTopBarTab(index: usize, x: f32, width: f32, close_x: ?f32, close_w: f32) void {
    if (index >= g_top_bar_cache.tabs.len) return;
    g_top_bar_cache.tab_count = @max(g_top_bar_cache.tab_count, index + 1);
    g_top_bar_cache.tabs[index] = .{
        .x = x,
        .width = width,
        .close_x = close_x orelse 0,
        .close_w = close_w,
        .has_close = close_x != null,
    };
}

fn topBarHitTest(_: *App, mouse_x: f32, mouse_y: f32, window_width: f32) TopBarHit {
    var hit = TopBarHit{};
    if (!g_top_bar_cache.enabled or mouse_y < 0 or mouse_y >= g_top_bar_cache.height or mouse_x < 0 or mouse_x >= window_width) return hit;

    hit.in_top_bar = true;
    const tab_count = @min(g_top_bar_cache.tab_count, g_top_bar_cache.tabs.len);
    for (g_top_bar_cache.tabs[0..tab_count], 0..) |tab, ti| {
        if (tab.width <= 0) continue;
        if (mouse_x >= tab.x and mouse_x < tab.x + tab.width) {
            hit.tab_index = ti;
            if (tab.has_close and mouse_x >= tab.close_x and mouse_x < tab.close_x + tab.close_w) {
                hit.close_tab_index = ti;
            }
            return hit;
        }
    }
    return hit;
}

fn updateTopBarHover(app: *App, mouse_x: f32, mouse_y: f32, window_width: f32) TopBarHit {
    const hit = topBarHitTest(app, mouse_x, mouse_y, window_width);
    _ = app.enqueueMouse(.{ .hover = .{
        .tab_index = hit.tab_index,
        .close_tab_index = hit.close_tab_index,
    } });
    return hit;
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

fn sleepForFrameCap(app: *App, frame_start_ns: i128, frame_end_ns: i128) void {
    if (app.config.vsync or app.config.max_fps == 0) return;

    const target_frame_ns = @divFloor(std.time.ns_per_s, @as(i128, @intCast(app.config.max_fps)));
    const deadline_ns = frame_start_ns + target_frame_ns;
    if (frame_end_ns >= deadline_ns) return;

    // Windows scheduler granularity commonly overshoots sub-10ms sleeps enough
    // to turn a 120 FPS cap into ~60 FPS. Sleep most of the gap, then use a
    // short yield/spin tail so higher caps remain reachable.
    const spin_tail_ns: i128 = 1_000_000;
    var now_ns = frame_end_ns;
    while (now_ns < deadline_ns) {
        const remaining_ns = deadline_ns - now_ns;
        if (remaining_ns > spin_tail_ns) {
            std.Thread.sleep(@as(u64, @intCast(remaining_ns - spin_tail_ns)));
        } else if (remaining_ns > 100_000) {
            std.Thread.yield() catch {};
        }
        now_ns = std.time.nanoTimestamp();
    }
}

pub fn run(app: *App) !void {
    g_app = app;
    g_renderer_ready = false;
    g_logged_first_frame = false;
    g_frame_index = 0;
    g_ft_renderer = null;
    g_gui_ready_fired = false;
    g_window_chrome_applied = false;
    g_prev_wnd_proc = 0;
    g_subclassed_hwnd = null;
    g_last_frame_time_ns = 0;
    g_last_perf_sample_ns = 0;
    g_perf_accum_frame_ns = 0;
    g_perf_accum_frames = 0;
    g_perf_fps = 0;
    g_perf_frame_ms = 0;
    g_perf_window_max_frame_ns = 0;
    g_perf_max_frame_ms = 0;
    g_drag_node = null;
    g_mouse_button_down = null;

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
    std.log.info("sokol: max_fps={d}", .{app.config.max_fps});
    std.log.info("sokol: renderer_single_pane_direct={s} (default=false, false=cached RT path)", .{
        if (app.config.renderer_single_pane_direct) "true" else "false",
    });
    std.log.info("sokol: renderer_safe_mode={s} (true=direct draw for all panes)", .{
        if (app.config.renderer_safe_mode) "true" else "false",
    });
    std.log.info("sokol: renderer_disable_swapchain_glyphs={s}", .{
        if (app.config.renderer_disable_swapchain_glyphs) "true" else "false",
    });
    std.log.info("sokol: renderer_disable_multi_pane_cache={s}", .{
        if (app.config.renderer_disable_multi_pane_cache) "true" else "false",
    });
    std.log.info("sokol: scroll_multiplier={d:.2}", .{app.config.scroll_multiplier});

    // Raise the Windows multimedia timer resolution to 1 ms so that
    // std.Thread.sleep() can hit sub-10ms targets accurately.
    // Without this the default 15.6 ms scheduler tick causes a 120 fps cap
    // to collapse to ~60 fps.  timeEndPeriod(1) is called in cleanupCb.
    if (builtin.os.tag == .windows and !app.config.vsync and app.config.max_fps > 0) {
        _ = win32.timeBeginPeriod(1);
    }

    // Set the window icon from pre-resized RGBA pixel data.
    desc.icon.images[0] = .{
        .width = 16,
        .height = 16,
        .pixels = .{ .ptr = &icon_data.icon_16x16_rgba, .size = icon_data.icon_16x16_rgba.len },
    };
    desc.icon.images[1] = .{
        .width = 32,
        .height = 32,
        .pixels = .{ .ptr = &icon_data.icon_32x32_rgba, .size = icon_data.icon_32x32_rgba.len },
    };
    desc.icon.images[2] = .{
        .width = 64,
        .height = 64,
        .pixels = .{ .ptr = &icon_data.icon_64x64_rgba, .size = icon_data.icon_64x64_rgba.len },
    };

    c.sapp_run(&desc);
}

fn initCb(user_data: ?*anyopaque) callconv(.c) void {
    const app = appFromUserData(user_data) orelse return;
    std.log.info("sokol init callback", .{});

    var sg_desc = std.mem.zeroes(c.sg_desc);
    sg_desc.environment = c.sglue_environment();
    c.sg_setup(&sg_desc);
    {
        const sc = c.sglue_swapchain();
        std.log.info("sokol: swapchain color_format={d} depth_format={d} samples={d}", .{ sc.color_format, sc.depth_format, sc.sample_count });
        std.log.info("sokol: environment color_format={d} depth_format={d} samples={d}", .{ sg_desc.environment.defaults.color_format, sg_desc.environment.defaults.depth_format, sg_desc.environment.defaults.sample_count });
    }

    // sokol_gl is required by sokol_fontstash for glyph rendering.
    var sgl_desc = std.mem.zeroes(c.sgl_desc_t);
    sgl_desc.max_vertices = 1 << 20;
    sgl_desc.max_commands = 1 << 18;
    c.sgl_setup(&sgl_desc);

    // Query DPI scale after sg_setup so the GPU context is ready.
    // On a 2× HiDPI display this returns 2.0; on a 1× display it returns 1.0.
    const dpi_scale = c.sapp_dpi_scale();
    std.log.info("sokol dpi_scale={d:.2} font_size={d:.1} line_height={d:.2}", .{ dpi_scale, app.config.fonts.size, app.config.fonts.line_height });

    _ = applyWindowChrome(app);

    g_ft_renderer = FtRenderer.init(std.heap.page_allocator, .{
        .font_size = app.config.fonts.size,
        .dpi_scale = dpi_scale,
        .line_height = app.config.fonts.line_height,
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

    _ = app.enqueueMouse(.{ .focus = true });
}

/// Release cache entries for panes that no longer exist in the mux.
/// Called once per frame after tick() has already cleaned up dead panes.
/// O(MAX_PANE_CACHES × live_pane_count) — negligible cost.
fn evictStalePaneCaches(app: *App) void {
    for (&g_pane_caches) |*slot| {
        const entry = slot.* orelse continue;
        // Check if this pane pointer is still alive in the mux.
        var found = false;
        var iter = app.mux.?.paneIterator();
        while (iter.next()) |live_pane| {
            if (live_pane == entry.pane) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.log.info("evictStalePaneCaches: releasing cache for dead pane={x}", .{@intFromPtr(entry.pane)});
            slot.*.?.cache.deinit();
            slot.* = null;
        }
    }
}

fn frameCb(user_data: ?*anyopaque) callconv(.c) void {
    const app = appFromUserData(user_data) orelse return;
    const frame_start_ns = std.time.nanoTimestamp();
    updatePerfCounters(frame_start_ns);
    if (builtin.os.tag == .windows and !g_window_chrome_applied) {
        g_window_chrome_applied = applyWindowChrome(app);
    }
    g_frame_index += 1;
    if (g_frames_since_drag_release < std.math.maxInt(usize)) g_frames_since_drag_release += 1;
    if (!g_logged_first_frame) {
        g_logged_first_frame = true;
        std.log.info("sokol first frame (ft renderer)", .{});
    }
    app.tick() catch {};
    // Release cached render textures for panes destroyed during tick()
    // (closed tab, closed split, dead PTY). Must happen after tick() so the
    // mux has already removed dead panes from its lists.
    if (app.mux != null) evictStalePaneCaches(app);
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
    if (app.config.terminal_theme.enabled) {
        clear_r = @as(f32, @floatFromInt(app.config.terminal_theme.background.r)) / 255.0;
        clear_g = @as(f32, @floatFromInt(app.config.terminal_theme.background.g)) / 255.0;
        clear_b = @as(f32, @floatFromInt(app.config.terminal_theme.background.b)) / 255.0;
    }
    if (app.ghostty) |*runtime| {
        if (app.activePane()) |pane| {
            if (pane.render_state_ready) {
                if (!app.config.terminal_theme.enabled) {
                    if (runtime.renderStateColors(pane.render_state)) |colors| {
                        clear_r = @as(f32, @floatFromInt(colors.background.r)) / 255.0;
                        clear_g = @as(f32, @floatFromInt(colors.background.g)) / 255.0;
                        clear_b = @as(f32, @floatFromInt(colors.background.b)) / 255.0;
                    }
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

    // Decide once whether to use direct rendering.
    // renderer_safe_mode forces the simpler direct path for all panes as a
    // diagnostic escape hatch from the cached RT pipeline.
    const use_direct_render = app.config.renderer_single_pane_direct and
        leaves.len == 0 and app.tabBarHeight() == 0;
    const use_safe_render = app.config.renderer_safe_mode;
    const use_direct_multi_pane = app.config.renderer_disable_multi_pane_cache and leaves.len > 1;
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
            const PaneRenderPath = enum {
                cached_clean,
                cached_dirty,
            };

            // Returns how this pane should be presented this frame.
            const renderPane = struct {
                fn call(
                    rend: *FtRenderer,
                    rt: *ghostty.Runtime,
                    cfg: *const Config,
                    pane: *Pane,
                    ox: f32,
                    oy: f32,
                    pw: f32,
                    ph: f32,
                    fb_w: f32,
                    fb_h: f32,
                    focused: bool,
                    layout_generation: u32,
                    cell_width_px: u32,
                    cell_height_px: u32,
                ) PaneRenderPath {
                    _ = oy;
                    _ = fb_w;
                    _ = fb_h;
                    const pw_u: u32 = @max(1, @as(u32, @intFromFloat(pw)));
                    const ph_u: u32 = @max(1, @as(u32, @intFromFloat(ph)));
                    const cache_entry = getOrCreatePaneCacheEntry(pane, pw_u, ph_u) orelse return .cached_clean;

                    // Check dirty flag.
                    // We use pane.render_dirty, which tickPanes refreshes from
                    // Ghostty after updateRenderState() computes this frame's
                    // dirty level.
                    _ = ox; // suppress unused warning
                    const dirty_level = pane.render_dirty;
                    const geometry_stale = cache_entry.force_full_frames > 0 or g_drag_node != null or cache_entry.layout_generation != layout_generation;
                    // Atlas-epoch check: if the atlas was flushed since this pane's
                    // last render, its existing RT content has stale glyph UVs and
                    // must be fully redrawn. Crucially we use the epoch (not the
                    // atlas_dirty bool) so that panes rendered AFTER the atlas flush
                    // in the same frame don't cause unnecessary full redraws.
                    const atlas_stale = cache_entry.last_atlas_epoch != rend.atlas_epoch;

                    // Resolve background colour for the clear.
                    var cr: f32 = 0.0;
                    var cg: f32 = 0.0;
                    var cb: f32 = 0.0;
                    if (cfg.terminal_theme.enabled) {
                        cr = @as(f32, @floatFromInt(cfg.terminal_theme.background.r)) / 255.0;
                        cg = @as(f32, @floatFromInt(cfg.terminal_theme.background.g)) / 255.0;
                        cb = @as(f32, @floatFromInt(cfg.terminal_theme.background.b)) / 255.0;
                    } else if (rt.renderStateColors(pane.render_state)) |colors| {
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
                    const expected_cols: u16 = @intCast(@min(1000, @max(1, pw_u / @max(@as(u32, 1), cell_width_px))));
                    const expected_rows: u16 = @intCast(@min(500, @max(1, ph_u / @max(@as(u32, 1), cell_height_px))));
                    const size_mismatch = pane.cols != expected_cols or pane.rows != expected_rows;
                    const grid_changed = cache_entry.last_cols != pane.cols or cache_entry.last_rows != pane.rows;
                    if (grid_changed) {
                        cache_entry.stable_after_resize = false;
                    }
                    const settled_clean = dirty_level == .false_value and !atlas_stale and !cache_entry.needs_clear and !geometry_stale and !size_mismatch and !grid_changed;
                    if (dirty_level == .false_value and cache_entry.validity == .valid and settled_clean and cache_entry.stable_after_resize) {
                        // Nothing changed and the pane has already survived a clean
                        // post-reflow frame, so the cached RT is safe to reuse.
                        if (g_frames_since_drag_release < 10) {
                            std.log.info("post_release[{d}] pane={x} cached_clean (skipped render entirely)", .{ g_frames_since_drag_release, @intFromPtr(pane) });
                        }
                        return .cached_clean;
                    }
                    const unsettled = size_mismatch or grid_changed or !cache_entry.stable_after_resize;
                    const force_full = g_drag_node != null or dirty_level == .full or atlas_stale or cache_entry.needs_clear or geometry_stale or unsettled;

                    // Diagnostic counters for log output.
                    if (dirty_level == .full) g_phase_accum_full_dl_frames += 1;
                    if (dirty_level == .true_value) g_phase_accum_true_dl_frames += 1;
                    if (atlas_stale) g_phase_accum_atlas_stale_frames += 1;

                    // Post-release diagnostics: log every render for the first 10 frames
                    // after a drag release so we can see exactly when partial renders fire.
                    if (g_frames_since_drag_release < 10) {
                        std.log.info(
                            "post_release[{d}] pane={x} dirty={s} force_full={} ff_frames={d} geom_stale={} atlas_stale={} needs_clear={} stable={} unsettled={} size_mm={} grid_chg={} pty_active={} rows_rendered={d} rows_skipped={d}",
                            .{
                                g_frames_since_drag_release,
                                @intFromPtr(pane),
                                @tagName(dirty_level),
                                force_full,
                                cache_entry.force_full_frames,
                                geometry_stale,
                                atlas_stale,
                                cache_entry.needs_clear,
                                cache_entry.stable_after_resize,
                                unsettled,
                                size_mismatch,
                                grid_changed,
                                pane.pty_wrote_this_frame,
                                rend.last_rows_rendered,
                                rend.last_rows_skipped,
                            },
                        );
                    }

                    // Row-hash map strategy: the map lets renderToCache skip rows whose
                    // content hasn't changed by comparing a per-row cell hash against the
                    // stored value from the previous frame.  This is the key optimisation
                    // for cursor-blink frames (dirty_level == .true_value) where ghostty
                    // marks only the cursor row dirty but may re-scan all rows.
                    //
                    // dirty_level == .full means every row is dirty (content update, scroll,
                    // resize, alt-screen switch, etc.).  In this case the hash check cannot
                    // skip ANY row (all are dirty and all will have changed hashes) — but
                    // we still WANT to write fresh hashes into the map during the .full pass
                    // so that the very next .true_value frame (cursor blink) can skip all
                    // unchanged rows.  renderToCache therefore uses force_full to decide
                    // whether to SKIP rows (never on force_full) vs WRITE hashes (always).
                    //
                    // force_full (atlas stale or resize) invalidates existing RT pixels, so
                    // any stored hash entry from before the atlas change is stale (the glyph
                    // UVs changed) → zero the map so no false-positive skips happen.
                    // dirty_level == .full from content updates can also invalidate the map
                    // because alt-screen switches / resize-like events may reuse rowRaw keys
                    // for different content. Clear the map, then let renderToCache write the
                    // fresh hashes during this frame so the next .true_value frame can skip.
                    const row_map_skip = g_drag_node == null and dirty_level != .full and !force_full;
                    if (!row_map_skip) {
                        // Stored hashes are invalid for this frame; rebuild them as we render.
                        @memset(&cache_entry.row_map_keys, ROW_MAP_EMPTY);
                    }

                    rend.renderToCache(
                        &cache_entry.cache,
                        rt,
                        cfg,
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
                        row_map_skip,
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
                    cache_entry.layout_generation = layout_generation;
                    cache_entry.last_cols = pane.cols;
                    cache_entry.last_rows = pane.rows;
                    // If PTY data arrived this frame (shell is still writing its
                    // redraw response to the resize), ghostty's snapshot may be
                    // a partially-updated screen.  Keep force_full alive and
                    // needs_clear set so we keep doing CLEAR renders until the
                    // shell output settles.  Only mark stable / clear needs_clear
                    // on a quiet frame with no new PTY data.
                    const pty_active = pane.pty_wrote_this_frame;
                    pane.pty_wrote_this_frame = false; // consumed by renderer
                    cache_entry.needs_clear = pty_active;
                    const now_stable = !pty_active and dirty_level == .false_value and !atlas_stale and !geometry_stale and !size_mismatch and !grid_changed;
                    cache_entry.stable_after_resize = now_stable;
                    cache_entry.validity = if (cache_entry.stable_after_resize) .valid else .priming;
                    if (cache_entry.force_full_frames > 0 and !pty_active) cache_entry.force_full_frames -= 1;
                    if (dirty_level == .full) {
                        @memset(&cache_entry.row_map_keys, ROW_MAP_EMPTY);
                        @memset(&cache_entry.row_map_vals, 0);
                    }

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
                    return .cached_dirty;
                }
            }.call;

            if (use_safe_render or use_direct_multi_pane) {
                g_phase_accum_direct_frames += 1;
            } else if (do_leaves) {
                for (leaves) |leaf| {
                    if (!leaf.pane.render_state_ready) continue;
                    const ox: f32 = @floatFromInt(leaf.bounds.x);
                    const oy: f32 = @floatFromInt(leaf.bounds.y);
                    const pw: f32 = @floatFromInt(leaf.bounds.width);
                    const ph: f32 = @floatFromInt(leaf.bounds.height);
                    const focused = leaf.pane == app.activePane();
                    switch (renderPane(renderer, runtime, &app.config, leaf.pane, ox, oy, pw, ph, width, height, focused, app.currentLayoutGeneration(), app.cell_width_px, app.cell_height_px)) {
                        .cached_dirty => {
                            g_phase_accum_dirty_frames += 1;
                            g_phase_accum_cached_frames += 1;
                        },
                        .cached_clean => {
                            g_phase_accum_clean_frames += 1;
                        },
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
                    switch (renderPane(renderer, runtime, &app.config, pane, 0, 0, width, height, width, height, true, app.currentLayoutGeneration(), app.cell_width_px, app.cell_height_px)) {
                        .cached_dirty => {
                            g_phase_accum_dirty_frames += 1;
                        },
                        .cached_clean => {
                            g_phase_accum_clean_frames += 1;
                        },
                    }
                    g_phase_accum_cached_frames += 1;
                }
            }
        }

        if (use_safe_render or use_direct_multi_pane) {
            if (app.ghostty) |*runtime| {
                if (leaves.len > 0) {
                    const active = app.activePane();
                    for (leaves) |leaf| {
                        if (!leaf.pane.render_state_ready) continue;
                        const ox: f32 = @floatFromInt(leaf.bounds.x);
                        const oy: f32 = @floatFromInt(leaf.bounds.y);
                        const pw: f32 = @floatFromInt(leaf.bounds.width);
                        const ph: f32 = @floatFromInt(leaf.bounds.height);
                        renderer.queueInViewport(
                            runtime,
                            &app.config,
                            leaf.pane.render_state,
                            &leaf.pane.row_iterator,
                            &leaf.pane.row_cells,
                            ox,
                            oy,
                            pw,
                            ph,
                            width,
                            height,
                            leaf.pane == active,
                            true,
                            null,
                            null,
                            false,
                            std.math.maxInt(usize),
                        );
                        g_phase_accum_rows_rendered += renderer.last_rows_rendered;
                        g_phase_accum_rows_skipped += renderer.last_rows_skipped;
                        g_phase_accum_cells_visited += renderer.last_cells_visited;
                        g_phase_accum_glyph_runs += renderer.last_glyph_runs;
                        g_phase_accum_bg_rects += renderer.last_bg_rects;
                        if (renderer.last_atlas_flushed) g_phase_accum_atlas_flushes += 1;
                        leaf.pane.render_dirty = .false_value;
                    }
                } else if (app.activePane()) |pane| {
                    if (!pane.render_state_ready) {
                        // nothing to queue
                    } else {
                        renderer.queueInViewport(
                            runtime,
                            &app.config,
                            pane.render_state,
                            &pane.row_iterator,
                            &pane.row_cells,
                            0,
                            0,
                            width,
                            height,
                            width,
                            height,
                            true,
                            true,
                            null,
                            null,
                            false,
                            std.math.maxInt(usize),
                        );
                        g_phase_accum_rows_rendered += renderer.last_rows_rendered;
                        g_phase_accum_rows_skipped += renderer.last_rows_skipped;
                        g_phase_accum_cells_visited += renderer.last_cells_visited;
                        g_phase_accum_glyph_runs += renderer.last_glyph_runs;
                        g_phase_accum_bg_rects += renderer.last_bg_rects;
                        if (renderer.last_atlas_flushed) g_phase_accum_atlas_flushes += 1;
                        pane.render_dirty = .false_value;
                    }
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
            if (use_safe_render or use_direct_multi_pane) {
                // Visible panes were already queued on the default sgl context
                // before the swapchain pass so we can upload glyph verts outside
                // the pass. Nothing to blit here.
            } else if (do_leaves) {
                for (leaves) |leaf| {
                    if (!leaf.pane.render_state_ready) continue;
                    const ox: f32 = @floatFromInt(leaf.bounds.x);
                    const oy: f32 = @floatFromInt(leaf.bounds.y);
                    const pw: f32 = @floatFromInt(leaf.bounds.width);
                    const ph: f32 = @floatFromInt(leaf.bounds.height);
                    const pw_u: u32 = @max(1, @as(u32, @intFromFloat(pw)));
                    const ph_u: u32 = @max(1, @as(u32, @intFromFloat(ph)));
                    if (getOrCreatePaneCacheEntry(leaf.pane, pw_u, ph_u)) |entry| {
                        renderer.blitCache(&entry.cache, ox, oy, pw, ph, width, height);
                    }
                }
            } else if (app.activePane()) |pane| {
                if (pane.render_state_ready) {
                    if (use_direct_render) {
                        // Direct render: skip the offscreen RT and render straight to swapchain
                        renderer.drawDirect(
                            runtime,
                            &app.config,
                            pane.render_state,
                            &pane.row_iterator,
                            &pane.row_cells,
                            0,
                            0,
                            width,
                            height,
                            width,
                            height,
                            true,
                            pane.render_dirty == .full or renderer.atlas_dirty,
                            std.math.maxInt(usize),
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
                        if (getOrCreatePaneCacheEntry(pane, pw_u, ph_u)) |entry| {
                            renderer.blitCache(&entry.cache, 0, 0, width, height, width, height);
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
    resetTopBarCache(width, @floatFromInt(tbh_u));
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
                        cacheTopBarTab(ti, layout.x, layout.width, null, 0.0);
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
                        const close_x: f32 = @floor(tx + tab_w - close_w + 2.0);
                        cacheTopBarTab(ti, tx, tab_w, close_x - 4.0, close_w);

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

    // Draw 1px window frame border when the OS title bar is hidden.
    if (!app.config.window_titlebar_show) {
        const fw: i32 = @intFromFloat(width);
        const fh: i32 = @intFromFloat(height);
        c.sgl_defaults();
        c.sgl_viewport(0, 0, fw, fh, true);
        c.sgl_scissor_rect(0, 0, fw, fh, true);
        c.sgl_load_default_pipeline();
        c.sgl_matrix_mode_projection();
        c.sgl_load_identity();
        c.sgl_ortho(0.0, width, height, 0.0, -1.0, 1.0);
        // Subtle border colour — matches the inactive split-pane seam tone.
        const br: u8 = 60;
        const bg_: u8 = 65;
        const bb: u8 = 75;
        const ba: u8 = 255;
        drawBorderRect(0.0, 0.0, width, 1.0, br, bg_, bb, ba); // top
        drawBorderRect(0.0, height - 1.0, width, 1.0, br, bg_, bb, ba); // bottom
        drawBorderRect(0.0, 0.0, 1.0, height, br, bg_, bb, ba); // left
        drawBorderRect(width - 1.0, 0.0, 1.0, height, br, bg_, bb, ba); // right
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
        if (app.config.renderer_disable_swapchain_glyphs) {
            renderer.discardGlyphQuads();
        } else {
            renderer.drawGlyphQuads(width, height, false, .{ 0.0, 0.0, 0.0, 1.0 });
        }
    }

    c.sg_end_pass();
    c.sg_commit();
    const after_commit_ns = std.time.nanoTimestamp();
    sleepForFrameCap(app, frame_start_ns, after_commit_ns);

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
        const fps = n / 2.0; // 2-second window → fps = frames/2
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
        const full_dl = g_phase_accum_full_dl_frames;
        const true_dl = g_phase_accum_true_dl_frames;
        const stale_f = g_phase_accum_atlas_stale_frames;
        std.log.info(
            "frame phases (avg/{d:.0}f  fps={d:.1}): tick={d:.2}ms offscreen={d:.2}ms (queue={d:.2}ms [p1={d:.2}ms p2={d:.2}ms] gpu={d:.2}ms) swapchain={d:.2}ms  dirty={d} clean={d}  dl full={d} true={d}  atlas_stale={d} atlas_fl={d}  rows r={d} s={d}  cells={d} gruns={d} bgrects={d}  mode direct={d} cached={d}",
            .{ n, fps, tick_ms, off_ms, queue_ms, pass1_ms, pass2_ms, gpu_ms, swap_ms, dirty, clean, full_dl, true_dl, stale_f, atlas_fl, rows_rendered, rows_skipped, cells, gruns, bgrects, direct_f, cached_f },
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
        g_phase_accum_full_dl_frames = 0;
        g_phase_accum_true_dl_frames = 0;
        g_phase_accum_atlas_stale_frames = 0;
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

    const render_mode: []const u8 = if (app.config.renderer_safe_mode) "safe-direct" else if (app.config.renderer_single_pane_direct and
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
    if (builtin.os.tag == .windows) {
        if (g_subclassed_hwnd) |hwnd| {
            if (g_prev_wnd_proc != 0) _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_WNDPROC, g_prev_wnd_proc);
        }
        g_prev_wnd_proc = 0;
        g_subclassed_hwnd = null;
        // Restore default timer resolution.
        _ = win32.timeEndPeriod(1);
    }
    if (g_ft_renderer) |*renderer| {
        renderer.deinit();
        g_ft_renderer = null;
    }
    c.sgl_shutdown();
    c.sg_shutdown();
}

fn applyWindowChrome(app: *App) bool {
    if (builtin.os.tag != .windows) return false;

    if (app.config.window_titlebar_show) return true;

    const hwnd_raw = c.sapp_win32_get_hwnd() orelse return false;
    const hwnd: win32.HWND = @ptrCast(@constCast(hwnd_raw));
    if (g_subclassed_hwnd == null) {
        const new_proc: win32.WNDPROC = &windowProc;
        const new_proc_raw: win32.LONG_PTR = @bitCast(@intFromPtr(new_proc));
        const prev_proc_raw = win32.SetWindowLongPtrW(hwnd, win32.GWLP_WNDPROC, new_proc_raw);
        if (prev_proc_raw == 0) return false;
        g_prev_wnd_proc = prev_proc_raw;
        g_subclassed_hwnd = hwnd;
    }
    var style = win32.GetWindowLongPtrW(hwnd, win32.GWL_STYLE);
    style &= ~@as(win32.LONG_PTR, @intCast(win32.WS_CAPTION));
    style |= @as(win32.LONG_PTR, @intCast(win32.WS_THICKFRAME));
    _ = win32.SetWindowLongPtrW(hwnd, win32.GWL_STYLE, style);
    _ = win32.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        0,
        0,
        win32.SWP_NOSIZE | win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | win32.SWP_FRAMECHANGED,
    );
    return true;
}

fn borderHitTest(local_x: i32, local_y: i32, width: i32, height: i32) usize {
    if (builtin.os.tag != .windows) return win32.HTCLIENT;

    const border_x = @max(1, win32.GetSystemMetrics(win32.SM_CXSIZEFRAME) + win32.GetSystemMetrics(win32.SM_CXPADDEDBORDER));
    const border_y = @max(1, win32.GetSystemMetrics(win32.SM_CYSIZEFRAME) + win32.GetSystemMetrics(win32.SM_CXPADDEDBORDER));
    const on_left = local_x >= 0 and local_x < border_x;
    const on_right = local_x < width and local_x >= width - border_x;
    const on_top = local_y >= 0 and local_y < border_y;
    const on_bottom = local_y < height and local_y >= height - border_y;

    if (on_top and on_left) return win32.HTTOPLEFT;
    if (on_top and on_right) return win32.HTTOPRIGHT;
    if (on_bottom and on_left) return win32.HTBOTTOMLEFT;
    if (on_bottom and on_right) return win32.HTBOTTOMRIGHT;
    if (on_top) return win32.HTTOP;
    if (on_bottom) return win32.HTBOTTOM;
    if (on_left) return win32.HTLEFT;
    if (on_right) return win32.HTRIGHT;
    return win32.HTCLIENT;
}

fn getXLParam(lparam: isize) i32 {
    const bits: usize = @bitCast(lparam);
    const value: u16 = @truncate(bits & 0xFFFF);
    return @as(i32, @as(i16, @bitCast(value)));
}

fn getYLParam(lparam: isize) i32 {
    const bits: usize = @bitCast(lparam);
    const value: u16 = @truncate((bits >> 16) & 0xFFFF);
    return @as(i32, @as(i16, @bitCast(value)));
}

fn windowProc(hWnd: win32.HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.winapi) win32.LRESULT {
    switch (Msg) {
        win32.WM_NCCALCSIZE => {
            if (wParam != 0) return 0;
        },
        win32.WM_NCHITTEST => {
            var rect: win32.RECT = undefined;
            if (win32.GetWindowRect(hWnd, &rect) != 0) {
                const local_x = getXLParam(lParam) - rect.left;
                const local_y = getYLParam(lParam) - rect.top;
                const width = rect.right - rect.left;
                const height = rect.bottom - rect.top;
                const hit = borderHitTest(local_x, local_y, width, height);
                if (hit != win32.HTCLIENT) return @as(win32.LRESULT, @intCast(hit));
            }
        },
        else => {},
    }

    if (g_prev_wnd_proc != 0) {
        const prev: win32.WNDPROC = @ptrFromInt(@as(usize, @intCast(g_prev_wnd_proc)));
        return win32.CallWindowProcW(prev, hWnd, Msg, wParam, lParam);
    }
    return win32.DefWindowProcW(hWnd, Msg, wParam, lParam);
}

fn beginWindowDrag() void {
    if (builtin.os.tag != .windows) return;
    const hwnd_raw = c.sapp_win32_get_hwnd() orelse return;
    const hwnd: win32.HWND = @ptrCast(@constCast(hwnd_raw));
    _ = win32.ReleaseCapture();
    _ = win32.SendMessageW(hwnd, win32.WM_NCLBUTTONDOWN, win32.HTCAPTION, 0);
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
            c.SAPP_EVENTTYPE_FOCUSED => _ = app.enqueueMouse(.{ .focus = true }),
            c.SAPP_EVENTTYPE_UNFOCUSED => _ = app.enqueueMouse(.{ .focus = false }),
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
        c.SAPP_EVENTTYPE_MOUSE_SCROLL => _ = app.enqueueMouse(.{ .scroll = .{
            .x = event.mouse_x,
            .y = event.mouse_y,
            .raw_delta = -event.scroll_y,
            .mods = ghosttyMods(event.modifiers),
        } }),
        c.SAPP_EVENTTYPE_RESIZED => handleResize(app, event),
        c.SAPP_EVENTTYPE_FOCUSED => _ = app.enqueueMouse(.{ .focus = true }),
        c.SAPP_EVENTTYPE_UNFOCUSED => _ = app.enqueueMouse(.{ .focus = false }),
        c.SAPP_EVENTTYPE_QUIT_REQUESTED => c.sapp_request_quit(),
        else => {},
    }
}

fn handleKeyDown(app: *App, event: c.sapp_event) void {
    const mods = ghosttyMods(event.modifiers);
    const key = mapKey(event.key_code);

    // Give Lua a chance to consume this key before the terminal sees it.
    // fireOnKey calls LuaJIT (not the ghostty DLL) so it is safe on the
    // event thread.  If Lua consumes the key we stop here — no DLL call needed.
    if (key != .unidentified) {
        const key_name = @tagName(key);
        if (app.fireOnKey(key_name, mods)) return;
    }

    // Defer the actual DLL call (encodeKey) to the frame thread via the queue.
    // This prevents a data race with syncKeyEncoder / syncMouseEncoder which
    // run on the frame thread inside tickPanes / resizeAllPanes.
    if (key != .unidentified) _ = app.enqueueKey(key, mods);
}

fn handleChar(app: *App, event: c.sapp_event) void {
    var utf8_buf: [5]u8 = [_]u8{0} ** 5;
    const utf8 = encodeCodepoint(event.char_code, &utf8_buf) orelse return;
    // Defer sendText to the frame thread — avoids racing with DLL calls in tick().
    _ = app.enqueueChar(utf8);
}

fn handleMouseButton(app: *App, event: c.sapp_event, action: ghostty.MouseAction) void {
    const button = switch (event.mouse_button) {
        c.SAPP_MOUSEBUTTON_LEFT => ghostty.MouseButton.left,
        c.SAPP_MOUSEBUTTON_RIGHT => ghostty.MouseButton.right,
        c.SAPP_MOUSEBUTTON_MIDDLE => ghostty.MouseButton.middle,
        else => null,
    };

    if (action == .press) {
        g_mouse_button_down = button;
    }

    // On left-button release always end any active drag.
    if (action == .release and event.mouse_button == c.SAPP_MOUSEBUTTON_LEFT) {
        if (g_drag_node != null) {
            _ = app.enqueueMouse(.divider_commit);
            // Reset all pane cache entries so they do force-full CLEAR renders
            // for the next few frames after the drag ends.  During the drag,
            // force_full_frames may have been decremented to 0 and
            // stable_after_resize may be true — leaving the first post-release
            // partial render to fire with a hash map built during the drag.
            // That map can contain stale entries if the terminal reflowed
            // content between the last drag frame and the release frame.
            // Resetting here guarantees every pane gets at least
            // force_full_frames CLEAR renders before any hash-skip logic runs.
            for (&g_pane_caches) |*slot| {
                if (slot.*) |*entry| {
                    entry.force_full_frames = 3;
                    entry.stable_after_resize = false;
                    entry.needs_clear = true;
                    @memset(&entry.row_map_keys, ROW_MAP_EMPTY);
                    @memset(&entry.row_map_vals, 0);
                }
            }
            g_frames_since_drag_release = 0;
            std.log.info("drag_release: reset all pane caches, g_frames_since_drag_release=0", .{});
        }
        g_drag_node = null;
        if (builtin.os.tag == .windows) _ = win32.ReleaseCapture();
    }

    const top_bar_hit = updateTopBarHover(app, event.mouse_x, event.mouse_y, c.sapp_widthf());
    if (top_bar_hit.in_top_bar) {
        if (action == .press and event.mouse_button == c.SAPP_MOUSEBUTTON_LEFT) {
            if (top_bar_hit.tab_index) |ti| {
                if (app.hasCustomTopBarTabs()) {
                    _ = app.enqueueMouse(.{ .switch_tab = ti });
                } else if (top_bar_hit.close_tab_index != null and top_bar_hit.close_tab_index.? == ti) {
                    _ = app.enqueueMouse(.{ .switch_and_close_tab = ti });
                } else {
                    _ = app.enqueueMouse(.{ .switch_tab = ti });
                }
                return;
            }
            if (builtin.os.tag == .windows and !app.config.window_titlebar_show) {
                beginWindowDrag();
            }
        }
        return;
    }

    // On left-button press, check for a divider hit before forwarding to the terminal.
    if (action == .press and event.mouse_button == c.SAPP_MOUSEBUTTON_LEFT) {
        // 6-pixel hit radius on each side of the 2px seam.
        if (app.hitTestDividerAt(event.mouse_x, event.mouse_y, 6.0)) |hit| {
            g_drag_node = hit.node;
            g_drag_direction = hit.node.direction;
            g_drag_bounds = hit.bounds;
            if (builtin.os.tag == .windows) {
                const hwnd_raw = c.sapp_win32_get_hwnd() orelse null;
                if (hwnd_raw) |raw| {
                    const hwnd: win32.HWND = @ptrCast(@constCast(raw));
                    _ = win32.SetCapture(hwnd);
                }
            }
            // Don't forward the click to the terminal — it's a resize gesture.
            return;
        }
    }

    if (button) |b| {
        _ = app.enqueueMouse(.{ .button = .{
            .action = action,
            .button = b,
            .x = event.mouse_x,
            .y = event.mouse_y,
            .mods = ghosttyMods(event.modifiers),
        } });
    }

    if (action == .release) {
        g_mouse_button_down = null;
    }
}

fn handleMouseMove(app: *App, event: c.sapp_event) void {
    // If we are currently dragging a divider, update the split ratio and skip
    // forwarding the event to the terminal (the cursor is a resize cursor, not
    // a text cursor).
    if (g_drag_node) |node| {
        // Validate that the cached node pointer is still part of the active
        // split tree.  Tree mutations (pane close, tab switch) can free the
        // node, leaving g_drag_node dangling.
        if (!app.isSplitNodeValid(node)) {
            std.log.info("divider drag cancelled: node={x} no longer in tree", .{@intFromPtr(node)});
            g_drag_node = null;
        } else {
            const bw: f32 = @floatFromInt(@max(1, g_drag_bounds.width));
            const bh: f32 = @floatFromInt(@max(1, g_drag_bounds.height));
            const bx: f32 = @floatFromInt(g_drag_bounds.x);
            const by: f32 = @floatFromInt(g_drag_bounds.y);
            const new_ratio = switch (g_drag_direction) {
                .vertical => (event.mouse_x - bx) / bw,
                .horizontal => (event.mouse_y - by) / bh,
            };
            _ = app.enqueueMouse(.{ .divider_ratio = .{
                .node = node,
                .ratio = new_ratio,
            } });
            // Keep the resize cursor active while dragging.
            if (builtin.os.tag == .windows) {
                const cursor_id: usize = switch (g_drag_direction) {
                    .vertical => win32.IDC_SIZEWE,
                    .horizontal => win32.IDC_SIZENS,
                };
                _ = win32.SetCursor(win32.LoadCursorW(null, cursor_id));
            }
            return;
        }
    }

    const top_bar_hit = updateTopBarHover(app, event.mouse_x, event.mouse_y, c.sapp_widthf());
    if (top_bar_hit.in_top_bar) {
        // Restore default cursor when in tab bar.
        if (builtin.os.tag == .windows) _ = win32.SetCursor(win32.LoadCursorW(null, win32.IDC_ARROW));
        return;
    }

    // Check if hovering over a split divider to show resize cursor.
    if (builtin.os.tag == .windows) {
        if (app.hitTestDividerAt(event.mouse_x, event.mouse_y, 6.0)) |hit| {
            const cursor_id: usize = switch (hit.node.direction) {
                .vertical => win32.IDC_SIZEWE,
                .horizontal => win32.IDC_SIZENS,
            };
            _ = win32.SetCursor(win32.LoadCursorW(null, cursor_id));
        } else {
            _ = win32.SetCursor(win32.LoadCursorW(null, win32.IDC_ARROW));
        }
    }

    _ = app.enqueueMouse(.{ .motion = .{
        .held_button = g_mouse_button_down,
        .x = event.mouse_x,
        .y = event.mouse_y,
        .mods = ghosttyMods(event.modifiers),
    } });
}

fn handleScroll(app: *App, event: c.sapp_event) void {
    if (topBarHitTest(app, event.mouse_x, event.mouse_y, c.sapp_widthf()).in_top_bar) return;
    _ = app.enqueueMouse(.{ .scroll = .{
        .x = event.mouse_x,
        .y = event.mouse_y,
        .raw_delta = -event.scroll_y,
        .mods = ghosttyMods(event.modifiers),
    } });
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
