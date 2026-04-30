const std = @import("std");
const builtin = @import("builtin");
const c = @import("sokol_c");
const icon_data = @import("icon_data");
const App = @import("../app.zig").App;
const lua_mod = @import("../lua_bridge.zig");
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
const selection = @import("../selection.zig");

const LUA_GLOBALSINDEX: c_int = -10002;
const Api = lua_mod.Api;
const State = lua_mod.State;
const LuaType = lua_mod.LuaType;

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
    const POINT = extern struct {
        x: i32,
        y: i32,
    };
    const MONITORINFO = extern struct {
        cbSize: u32,
        rcMonitor: RECT,
        rcWork: RECT,
        dwFlags: u32,
    };
    const MINMAXINFO = extern struct {
        ptReserved: POINT,
        ptMaxSize: POINT,
        ptMaxPosition: POINT,
        ptMinTrackSize: POINT,
        ptMaxTrackSize: POINT,
    };
    const MARGINS = extern struct {
        cxLeftWidth: i32,
        cxRightWidth: i32,
        cyTopHeight: i32,
        cyBottomHeight: i32,
    };
    const NCCALCSIZE_PARAMS = extern struct {
        rgrc: [3]RECT,
        lppos: ?*anyopaque,
    };

    const GWL_STYLE: c_int = -16;
    const GWLP_WNDPROC: c_int = -4;
    const WS_CAPTION: u32 = 0x00C00000;
    const WS_THICKFRAME: u32 = 0x00040000;
    const WM_NCCALCSIZE: u32 = 0x0083;
    const WM_NCHITTEST: u32 = 0x0084;
    const WM_GETMINMAXINFO: u32 = 0x0024;
    const WM_DWMCOMPOSITIONCHANGED: u32 = 0x031E;
    const DWMWA_BORDER_COLOR: u32 = 34;
    const DWMWA_CAPTION_COLOR: u32 = 35;
    const DWMWA_TEXT_COLOR: u32 = 36;
    const DWMWA_USE_IMMERSIVE_DARK_MODE: u32 = 20;
    const DWMWA_COLOR_NONE: u32 = 0xFFFFFFFE;
    const MONITOR_DEFAULTTONEAREST: u32 = 0x00000002;
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
    extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.c) i32;
    extern "user32" fn GetSystemMetrics(nIndex: c_int) callconv(.c) c_int;
    extern "user32" fn IsIconic(hWnd: HWND) callconv(.c) i32;
    extern "user32" fn IsZoomed(hWnd: HWND) callconv(.c) i32;
    extern "user32" fn MonitorFromWindow(hWnd: HWND, dwFlags: u32) callconv(.c) ?*anyopaque;
    extern "user32" fn GetMonitorInfoW(hMonitor: ?*anyopaque, lpmi: *MONITORINFO) callconv(.c) i32;
    extern "user32" fn SetCapture(hWnd: HWND) callconv(.c) ?HWND;
    extern "user32" fn ReleaseCapture() callconv(.c) i32;
    extern "user32" fn SendMessageW(hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.c) isize;
    extern "user32" fn CallWindowProcW(lpPrevWndFunc: ?WNDPROC, hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.c) LRESULT;
    extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.c) LRESULT;
    extern "user32" fn LoadCursorW(hInstance: ?*anyopaque, lpCursorName: usize) callconv(.c) ?*anyopaque;
    extern "user32" fn SetCursor(hCursor: ?*anyopaque) callconv(.c) ?*anyopaque;
    extern "dwmapi" fn DwmExtendFrameIntoClientArea(hWnd: HWND, pMarInset: *const MARGINS) callconv(.c) i32;
    extern "dwmapi" fn DwmSetWindowAttribute(hwnd: HWND, dwAttribute: u32, pvAttribute: *const anyopaque, cbAttribute: u32) callconv(.c) i32;
    // Standard cursor IDs (as usize for use with LoadCursorW's lpCursorName param)
    const IDC_ARROW: usize = 32512;
    const IDC_IBEAM: usize = 32513;
    const IDC_SIZEWE: usize = 32644;
    const IDC_SIZENS: usize = 32645;
    // winmm — multimedia timer resolution
    extern "winmm" fn timeBeginPeriod(uPeriod: c_uint) callconv(.c) c_uint;
    extern "winmm" fn timeEndPeriod(uPeriod: c_uint) callconv(.c) c_uint;
} else struct {};
const WinLongPtr = if (builtin.os.tag == .windows) win32.LONG_PTR else isize;
const WinHwnd = if (builtin.os.tag == .windows) win32.HWND else *anyopaque;

var g_app: ?*App = null;
var g_title_buf: [256]u8 = [_]u8{0} ** 256;
var g_last_window_title: [256]u8 = [_]u8{0} ** 256;
var g_renderer_ready = false;
var g_logged_first_frame = false;
var g_frame_index: usize = 0;
var g_ft_renderer: ?FtRenderer = null;
var g_gui_ready_fired = false;
var g_window_chrome_applied = false;
var g_prev_wnd_proc: WinLongPtr = 0;
var g_subclassed_hwnd: ?WinHwnd = null;
var g_window_iconified = false;
var g_restore_pending = false;
var g_ignore_resize_frames: usize = 0;
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
var g_top_bar_cache: BarCache = .{};
var g_bottom_bar_cache: BarCache = .{};

// Per-phase timing accumulators (logged every 2 seconds).
var g_phase_accum_tick_ns: i128 = 0;
var g_phase_accum_offscreen_ns: i128 = 0;
var g_phase_accum_swapchain_ns: i128 = 0;
var g_phase_accum_offscreen_terminal_ns: i128 = 0;
var g_phase_accum_offscreen_bar_preraster_ns: i128 = 0;
var g_phase_accum_swapchain_panes_ns: i128 = 0;
var g_phase_accum_swapchain_ui_ns: i128 = 0;
var g_phase_accum_swapchain_glyph_ns: i128 = 0;
var g_phase_accum_swapchain_submit_ns: i128 = 0;
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
var g_idle_frame_ns: i128 = 33_000_000;
var g_swallow_char_pending: u8 = 0;
var g_swallow_char_until_frame: u64 = 0;
var g_selection_pointer_active = false;
var g_selection_pointer_pane: ?*Pane = null;
// Double/triple click tracking (event thread only)
var g_click_count: u32 = 0;
var g_last_click_time_ms: u64 = 0;
var g_last_click_x: f32 = 0;
var g_last_click_y: f32 = 0;
var g_scrollbar_drag_pane: ?*Pane = null;
var g_scrollbar_drag_metrics: ?App.ScrollbarMetrics = null;
var g_scrollbar_drag_grab_y: f32 = 0.0;
var g_scrollbar_hover_pane: ?*Pane = null;
var g_hover_hyperlink: bool = false;
var g_skip_mouse_release: ?ghostty.MouseButton = null;
var g_skip_mouse_move_frames: u32 = 0;
var g_block_left_mouse_until_up: bool = false;
var g_block_all_mouse_until_up: bool = false;

// Last-frame timing breakdown (ms) for the debug overlay — updated every frame.
var g_last_frame_tick_ms: f32 = 0;
var g_last_frame_offscreen_ms: f32 = 0;
var g_last_frame_queue_ms: f32 = 0;
var g_last_frame_gpu_ms: f32 = 0;
var g_last_frame_swap_ms: f32 = 0;
var g_last_frame_offscreen_terminal_ms: f32 = 0;
var g_last_frame_offscreen_bar_preraster_ms: f32 = 0;
var g_last_frame_swapchain_panes_ms: f32 = 0;
var g_last_frame_swapchain_ui_ms: f32 = 0;
var g_last_frame_swapchain_glyph_ms: f32 = 0;
var g_last_frame_swapchain_submit_ms: f32 = 0;
// Frame-local queue/gpu accumulators, reset at frame start, captured at offscreen end.
var g_frame_queue_ns: i128 = 0;
var g_frame_gpu_ns: i128 = 0;

// Per-pane render-to-texture caches.
// Keyed by pane pointer (stable for the lifetime of the pane).
// MAX_LAYOUT_LEAVES is the max concurrent panes we ever render.
const MAX_PANE_CACHES = 32;
const MAX_CACHED_VISIBLE_PANES = 12;
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
    /// Cached terminal background color used for the RT. If this changes we need
    /// one full clear so the padding and any untouched pixels match the new theme.
    last_bg_color: ghostty.ColorRgb = .{ .r = 0, .g = 0, .b = 0 },
    has_bg_color: bool = false,
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
                    entry.has_bg_color = false;
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

fn releaseAllPaneCaches() void {
    for (&g_pane_caches) |*slot| {
        if (slot.*) |*entry| {
            entry.cache.deinit();
            slot.* = null;
        }
    }
}

fn prunePaneCachesToVisible(leaves: []const LayoutLeaf, single_visible_pane: ?*Pane) void {
    for (&g_pane_caches) |*slot| {
        const entry = slot.* orelse continue;
        var keep = false;
        if (single_visible_pane) |pane| {
            if (entry.pane == pane) keep = true;
        }
        if (!keep) {
            for (leaves) |leaf| {
                if (entry.pane == leaf.pane) {
                    keep = true;
                    break;
                }
            }
        }
        if (!keep) {
            slot.*.?.cache.deinit();
            slot.* = null;
        }
    }
}

const CustomTabLayout = struct {
    x: f32,
    width: f32,
    title: []const u8,
    close_x: f32,
    close_w: f32,
    fg: ?ghostty.ColorRgb = null,
    bg: ?ghostty.ColorRgb = null,
    bold: bool = false,
};

const BarSurface = enum {
    top,
    bottom,
};

const BarHit = struct {
    surface: ?BarSurface = null,
    tab_index: ?usize = null,
    close_tab_index: ?usize = null,
    node_id: ?[]const u8 = null,

    fn inBar(self: BarHit) bool {
        return self.surface != null;
    }
};

const MAX_BAR_HIT_REGIONS = 256;

const CachedBarHitRegion = struct {
    x: f32 = 0,
    width: f32 = 0,
    close_x: f32 = 0,
    close_w: f32 = 0,
    has_close: bool = false,
    tab_index: ?usize = null,
    node_id: ?[]const u8 = null,
};

const BarBox = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    fn horizontal(self: BarBox) f32 {
        return self.left + self.right;
    }

    fn vertical(self: BarBox) f32 {
        return self.top + self.bottom;
    }
};

const BarStyle = struct {
    fg: ?ghostty.ColorRgb = null,
    bg: ?ghostty.ColorRgb = null,
    border: ?ghostty.ColorRgb = null,
    close_fg: ?ghostty.ColorRgb = null,
    close_bg: ?ghostty.ColorRgb = null,
    close_hover_fg: ?ghostty.ColorRgb = null,
    close_hover_bg: ?ghostty.ColorRgb = null,
    radius: f32 = 0,
    close_radius: f32 = 0,
    bold: bool = false,
    padding: BarBox = .{},
    margin: BarBox = .{},
};

const BarLayout = struct {
    padding: BarBox = .{},
    margin: BarBox = .{},
};

const BarSegmentView = struct {
    segment: bar.Segment = .{ .text = "" },
    style: BarStyle = .{},
    segments: [16]bar.Segment = [_]bar.Segment{.{ .text = "" }} ** 16,
    segments_len: usize = 0,
    text_storage: [512]u8 = [_]u8{0} ** 512,
    segments_text_storage: [1024]u8 = [_]u8{0} ** 1024,
    segments_id_storage: [16][128]u8 = [_][128]u8{[_]u8{0} ** 128} ** 16,
};

const BarTabView = struct {
    segment: bar.Segment = .{ .text = "" },
    style: BarStyle = .{},
    segments: [16]bar.Segment = [_]bar.Segment{.{ .text = "" }} ** 16,
    segments_len: usize = 0,
    text_storage: [512]u8 = [_]u8{0} ** 512,
    segments_text_storage: [1024]u8 = [_]u8{0} ** 1024,
    segments_id_storage: [16][128]u8 = [_][128]u8{[_]u8{0} ** 128} ** 16,
};

const BarItemKind = enum {
    spacer,
    segment,
    tabs,
};

const BarTabsView = struct {
    fit_content: bool = false,
    style: BarStyle = .{},
    tabs: [16]BarTabView = [_]BarTabView{.{}} ** 16,
    len: usize = 0,
};

const BarItemView = struct {
    kind: BarItemKind = .spacer,
    segment: BarSegmentView = .{ .segment = .{ .text = "" } },
    tabs: BarTabsView = .{},
};

const BarWidgetView = struct {
    layout: BarLayout = .{},
    style: BarStyle = .{},
    items: [32]BarItemView = [_]BarItemView{.{}} ** 32,
    len: usize = 0,
};

fn barBoxField(api: Api, state: *State, table_idx: c_int, field: [*:0]const u8) BarBox {
    var box = BarBox{};
    api.get_field(state, table_idx, field);
    defer pop(api, state, 1);
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) != .table) return box;
    const box_idx = absoluteIndex(api, state, -1);

    api.get_field(state, box_idx, "top");
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .number) box.top = @floatCast(api.to_number(state, -1));
    pop(api, state, 1);
    api.get_field(state, box_idx, "right");
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .number) box.right = @floatCast(api.to_number(state, -1));
    pop(api, state, 1);
    api.get_field(state, box_idx, "bottom");
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .number) box.bottom = @floatCast(api.to_number(state, -1));
    pop(api, state, 1);
    api.get_field(state, box_idx, "left");
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .number) box.left = @floatCast(api.to_number(state, -1));
    pop(api, state, 1);
    return box;
}

fn barStyleField(api: Api, state: *State, table_idx: c_int, field: [*:0]const u8) BarStyle {
    var style = BarStyle{};
    api.get_field(state, table_idx, field);
    defer pop(api, state, 1);
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) != .table) return style;
    const style_idx = absoluteIndex(api, state, -1);
    style.fg = lua_mod.parseColorField(api, state, style_idx, "fg");
    style.bg = lua_mod.parseColorField(api, state, style_idx, "bg");
    style.border = lua_mod.parseColorField(api, state, style_idx, "border");
    style.close_fg = lua_mod.parseColorField(api, state, style_idx, "close_fg");
    style.close_bg = lua_mod.parseColorField(api, state, style_idx, "close_bg");
    style.close_hover_fg = lua_mod.parseColorField(api, state, style_idx, "close_hover_fg");
    style.close_hover_bg = lua_mod.parseColorField(api, state, style_idx, "close_hover_bg");
    api.get_field(state, style_idx, "radius");
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .number) style.radius = @floatCast(api.to_number(state, -1));
    pop(api, state, 1);
    api.get_field(state, style_idx, "close_radius");
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .number) style.close_radius = @floatCast(api.to_number(state, -1));
    pop(api, state, 1);
    api.get_field(state, style_idx, "bold");
    style.bold = api.to_boolean(state, -1) != 0;
    pop(api, state, 1);
    style.padding = barBoxField(api, state, style_idx, "padding");
    style.margin = barBoxField(api, state, style_idx, "margin");
    return style;
}

fn topLevelBarLayout(api: Api, state: *State, table_idx: c_int) BarLayout {
    return .{
        .padding = barBoxField(api, state, table_idx, "padding"),
        .margin = barBoxField(api, state, table_idx, "margin"),
    };
}

fn copySegmentArray(parsed: []const bar.Segment, dst: []bar.Segment, text_storage: []u8, id_storage: [] [128]u8) struct { len: usize, used: usize } {
    var seg_count: usize = 0;
    var text_used: usize = 0;
    for (parsed) |seg| {
        if (seg_count >= dst.len or seg.text.len == 0) break;
        if (text_used + seg.text.len > text_storage.len) break;
        @memcpy(text_storage[text_used .. text_used + seg.text.len], seg.text);
        dst[seg_count] = seg;
        dst[seg_count].text = text_storage[text_used .. text_used + seg.text.len];
        if (seg.id) |id| {
            const id_len = @min(id.len, id_storage[seg_count].len);
            @memcpy(id_storage[seg_count][0..id_len], id[0..id_len]);
            dst[seg_count].id = id_storage[seg_count][0..id_len];
        }
        seg_count += 1;
        text_used += seg.text.len;
    }
    return .{ .len = seg_count, .used = text_used };
}

fn fillBarSegmentView(dst: *BarSegmentView, api: Api, state: *State, item_idx: c_int, text_buf: []u8) void {
    dst.* = .{};
    dst.style = barStyleField(api, state, item_idx, "style");
    const parsed = topBarSegmentFromLuaItem(api, state, item_idx, text_buf);
    const text_len = @min(parsed.text.len, dst.text_storage.len);
    @memcpy(dst.text_storage[0..text_len], parsed.text[0..text_len]);
    dst.segment = parsed;
    dst.segment.text = dst.text_storage[0..text_len];
    if (segmentArrayFieldIndex(api, state, item_idx)) |segments_idx| {
        var seg_buf: [16]bar.Segment = undefined;
        var seg_text_buf: [1024]u8 = undefined;
        const parsed_segments = lua_mod.parseSegmentArray(api, state, seg_buf[0..], seg_text_buf[0..], segments_idx);
        const copied = copySegmentArray(parsed_segments, dst.segments[0..], dst.segments_text_storage[0..], dst.segments_id_storage[0..]);
        dst.segments_len = copied.len;
        pop(api, state, 1);
    }
}

fn fillBarTabView(dst: *BarTabView, api: Api, state: *State, item_idx: c_int, text_buf: []u8) void {
    dst.* = .{};
    dst.style = barStyleField(api, state, item_idx, "style");
    const parsed = topBarSegmentFromLuaItem(api, state, item_idx, text_buf);
    const text_len = @min(parsed.text.len, dst.text_storage.len);
    @memcpy(dst.text_storage[0..text_len], parsed.text[0..text_len]);
    dst.segment = parsed;
    dst.segment.text = dst.text_storage[0..text_len];
    if (segmentArrayFieldIndex(api, state, item_idx)) |segments_idx| {
        var seg_buf: [16]bar.Segment = undefined;
        var seg_text_buf: [1024]u8 = undefined;
        const parsed_segments = lua_mod.parseSegmentArray(api, state, seg_buf[0..], seg_text_buf[0..], segments_idx);
        const copied = copySegmentArray(parsed_segments, dst.segments[0..], dst.segments_text_storage[0..], dst.segments_id_storage[0..]);
        dst.segments_len = copied.len;
        pop(api, state, 1);
    }
}

fn parseBarWidgetView(api: Api, state: *State, table_idx: c_int, text_buf: []u8) BarWidgetView {
    var view = BarWidgetView{};
    view.layout = topLevelBarLayout(api, state, table_idx);
    view.style = barStyleField(api, state, table_idx, "style");

    api.get_field(state, table_idx, "items");
    defer pop(api, state, 1);
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) != .table) return view;
    const items_idx = absoluteIndex(api, state, -1);

    var item_i: c_int = 1;
    while (view.len < view.items.len) : (item_i += 1) {
        api.rawgeti(state, items_idx, item_i);
        if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .nil_type) {
            lua_mod.pop(api, state, 1);
            break;
        }
        defer lua_mod.pop(api, state, 1);
        if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) != .table) continue;
        const item_idx = absoluteIndex(api, state, -1);

        api.get_field(state, item_idx, "kind");
        var kind_len: usize = 0;
        const kind_ptr = api.to_lstring(state, -1, &kind_len);
        const kind = if (kind_ptr) |ptr| ptr[0..kind_len] else "segment";
        lua_mod.pop(api, state, 1);

        const item_ptr = &view.items[view.len];
        item_ptr.* = .{};
        if (std.mem.eql(u8, kind, "spacer")) {
            item_ptr.kind = .spacer;
        } else if (std.mem.eql(u8, kind, "tabs")) {
            item_ptr.kind = .tabs;
            item_ptr.tabs.style = barStyleField(api, state, item_idx, "style");
            api.get_field(state, item_idx, "fit");
            var fit_len: usize = 0;
            const fit_ptr = api.to_lstring(state, -1, &fit_len);
            item_ptr.tabs.fit_content = fit_ptr != null and std.mem.eql(u8, fit_ptr.?[0..fit_len], "content");
            lua_mod.pop(api, state, 1);

            api.get_field(state, item_idx, "tabs");
            if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .table) {
                const tabs_idx = absoluteIndex(api, state, -1);
                var tab_i: c_int = 1;
                while (item_ptr.tabs.len < item_ptr.tabs.tabs.len) : (tab_i += 1) {
                    api.rawgeti(state, tabs_idx, tab_i);
                    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .nil_type) {
                        lua_mod.pop(api, state, 1);
                        break;
                    }
                    defer lua_mod.pop(api, state, 1);
                    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) != .table) continue;
                    const tab_idx = absoluteIndex(api, state, -1);
                    fillBarTabView(&item_ptr.tabs.tabs[item_ptr.tabs.len], api, state, tab_idx, text_buf);
                    item_ptr.tabs.len += 1;
                }
            }
            lua_mod.pop(api, state, 1);
        } else {
            item_ptr.kind = .segment;
            fillBarSegmentView(&item_ptr.segment, api, state, item_idx, text_buf);
        }

        view.len += 1;
    }

    return view;
}

fn segmentArrayTextLen(segments: []const bar.Segment) usize {
    var total: usize = 0;
    for (segments) |seg| total += seg.text.len;
    return total;
}

fn segmentArrayCodepoints(segments: []const bar.Segment) usize {
    var total: usize = 0;
    for (segments) |seg| total += countCodepoints(seg.text);
    return total;
}

fn segmentArrayFieldIndex(api: Api, state: *State, item_idx: c_int) ?c_int {
    api.get_field(state, item_idx, "segments");
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .table) {
        return absoluteIndex(api, state, -1);
    }
    pop(api, state, 1);
    return null;
}

fn drawSegmentArray(renderer: *FtRenderer, x: f32, y: f32, max_width: f32, segments: []const bar.Segment, default_fg: ghostty.ColorRgb) void {
    var cursor_x = x;
    for (segments) |seg| {
        if (seg.text.len == 0) continue;
        const seg_w = @as(f32, @floatFromInt(countCodepoints(seg.text))) * renderer.cell_w;
        if (cursor_x + seg_w > x + max_width) break;
        const fg = seg.fg orelse default_fg;
        renderer.drawLabelFace(cursor_x, y, seg.text, fg.r, fg.g, fg.b, if (seg.bold) 1 else 0);
        c.sgl_load_default_pipeline();
        cursor_x += seg_w;
    }
}

fn cacheBarSegmentArray(cache: *BarCache, renderer: *FtRenderer, x: f32, max_width: f32, segments: []const bar.Segment, tab_index: ?usize) void {
    var cursor_x = x;
    for (segments) |seg| {
        if (seg.text.len == 0) continue;
        const seg_w = @as(f32, @floatFromInt(countCodepoints(seg.text))) * renderer.cell_w;
        if (cursor_x + seg_w > x + max_width) break;
        if (seg.id != null or tab_index != null) {
            cacheBarHitRegion(cache, cursor_x, seg_w, null, 0.0, tab_index, seg.id);
        }
        cursor_x += seg_w;
    }
}

fn topBarSegmentFromLuaItem(api: Api, state: *State, item_idx: c_int, text_buf: []u8) bar.Segment {
    var seg = bar.Segment{ .text = "" };

    api.get_field(state, item_idx, "text");
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .string) {
        var len: usize = 0;
        if (api.to_lstring(state, -1, &len)) |ptr| {
            const n = @min(len, text_buf.len);
            @memcpy(text_buf[0..n], ptr[0..n]);
            seg.text = text_buf[0..n];
        }
    }
    lua_mod.pop(api, state, 1);

    api.get_field(state, item_idx, "bold");
    seg.bold = api.to_boolean(state, -1) != 0;
    lua_mod.pop(api, state, 1);

    seg.fg = lua_mod.parseColorField(api, state, item_idx, "fg");
    seg.bg = lua_mod.parseColorField(api, state, item_idx, "bg");

    api.get_field(state, item_idx, "id");
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .string) {
        var len: usize = 0;
        if (api.to_lstring(state, -1, &len)) |ptr| {
            seg.id = ptr[0..len];
        }
    }
    lua_mod.pop(api, state, 1);

    return seg;
}

const BarCache = struct {
    enabled: bool = false,
    width: f32 = 0,
    height: f32 = 0,
    y: f32 = 0,
    hit_count: usize = 0,
    hits: [MAX_BAR_HIT_REGIONS]CachedBarHitRegion = [_]CachedBarHitRegion{.{}} ** MAX_BAR_HIT_REGIONS,
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

fn takeTrailingCodepoints(text: []const u8, count: usize) []const u8 {
    const total = countCodepoints(text);
    if (count >= total) return text;
    const skip = total - count;
    var used_bytes: usize = 0;
    var used_codepoints: usize = 0;
    while (used_bytes < text.len and used_codepoints < skip) {
        const cp_len = utf8CodepointLen(text[used_bytes]);
        if (used_bytes + cp_len > text.len) break;
        used_bytes += cp_len;
        used_codepoints += 1;
    }
    return text[used_bytes..];
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

fn absoluteIndex(api: lua_mod.Api, state: *lua_mod.State, idx: c_int) c_int {
    if (idx > 0 or idx <= LUA_GLOBALSINDEX) return idx;
    return api.get_top(state) + idx + 1;
}

fn pop(api: lua_mod.Api, state: *lua_mod.State, count: c_int) void {
    api.set_top(state, -count - 1);
}

fn parseHexColor(text: []const u8) ?ghostty.ColorRgb {
    if (text.len != 7 or text[0] != '#') return null;
    const r = std.fmt.parseInt(u8, text[1..3], 16) catch return null;
    const g = std.fmt.parseInt(u8, text[3..5], 16) catch return null;
    const b = std.fmt.parseInt(u8, text[5..7], 16) catch return null;
    return .{ .r = r, .g = g, .b = b };
}

fn overlayRowSegmentsIndex(api: lua_mod.Api, state: *lua_mod.State, row_idx: c_int) c_int {
    api.get_field(state, row_idx, "segments");
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .table) {
        return absoluteIndex(api, state, -1);
    }
    pop(api, state, 1);
    return row_idx;
}

fn overlayRowColorField(api: lua_mod.Api, state: *lua_mod.State, row_idx: c_int, field: [*:0]const u8) ?ghostty.ColorRgb {
    api.get_field(state, row_idx, field);
    defer pop(api, state, 1);
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) != .string) return null;
    var len: usize = 0;
    const ptr = api.to_lstring(state, -1, &len) orelse return null;
    return parseHexColor(ptr[0..len]);
}

fn overlayRowBoolField(api: lua_mod.Api, state: *lua_mod.State, row_idx: c_int, field: [*:0]const u8) bool {
    api.get_field(state, row_idx, field);
    defer pop(api, state, 1);
    return api.to_boolean(state, -1) != 0;
}

fn drawRowSegments(renderer: *FtRenderer, x: f32, y: f32, max_width: f32, segments: []const bar.Segment) void {
    var cursor_x = x;
    for (segments) |seg| {
        if (seg.text.len == 0) continue;
        const seg_w = @as(f32, @floatFromInt(countCodepoints(seg.text))) * renderer.cell_w;
        if (seg.bg) |bg| {
            drawBorderRect(cursor_x, y + 1.0, seg_w, @max(@as(f32, 1.0), renderer.cell_h - 2.0), bg.r, bg.g, bg.b, 220);
        }
        const fg = seg.fg orelse ghostty.ColorRgb{ .r = 220, .g = 220, .b = 220 };
        renderer.drawLabelFace(cursor_x, y, seg.text, fg.r, fg.g, fg.b, if (seg.bold) 1 else 0);
        c.sgl_load_default_pipeline();
        cursor_x += seg_w;
        if (cursor_x >= x + max_width) break;
    }
}

fn drawRoundedRect(x: f32, y: f32, w: f32, h: f32, radius: f32, r: u8, g: u8, b: u8, a: u8) void {
    if (w <= 0 or h <= 0) return;
    const clamped_radius = @min(radius, @min(w, h) * 0.5);
    if (clamped_radius <= 0.5) {
        drawBorderRect(x, y, w, h, r, g, b, a);
        return;
    }

    const row_count: usize = @max(1, @as(usize, @intFromFloat(@ceil(h))));
    var row: usize = 0;
    while (row < row_count) : (row += 1) {
        const row_y = y + @as(f32, @floatFromInt(row));
        const row_h = @min(@as(f32, 1.0), y + h - row_y);
        if (row_h <= 0) break;

        const sample_y = @as(f32, @floatFromInt(row)) + row_h * 0.5;
        var inset: f32 = 0.0;
        if (sample_y < clamped_radius) {
            const dy = clamped_radius - sample_y;
            inset = clamped_radius - @sqrt(@max(@as(f32, 0.0), clamped_radius * clamped_radius - dy * dy));
        } else if (sample_y > h - clamped_radius) {
            const dy = sample_y - (h - clamped_radius);
            inset = clamped_radius - @sqrt(@max(@as(f32, 0.0), clamped_radius * clamped_radius - dy * dy));
        }

        const full_inset = @ceil(inset);
        const fringe = full_inset - inset;
        const row_x = x + full_inset;
        const row_w = w - full_inset * 2.0;
        if (row_w > 0) drawBorderRect(row_x, row_y, row_w, row_h, r, g, b, a);

        if (fringe > 0.001 and a > 0) {
            const fringe_alpha = @as(u8, @intFromFloat(@round(std.math.clamp(fringe, 0.0, 1.0) * @as(f32, @floatFromInt(a)))));
            if (fringe_alpha > 0) {
                const left_x = x + full_inset - 1.0;
                const right_x = x + w - full_inset;
                if (left_x >= x) drawBorderRect(left_x, row_y, 1.0, row_h, r, g, b, fringe_alpha);
                if (right_x + 1.0 <= x + w) drawBorderRect(right_x, row_y, 1.0, row_h, r, g, b, fringe_alpha);
            }
        }
    }
}

fn drawBarBackground(x: f32, y: f32, w: f32, h: f32, style: BarStyle) void {
    if (style.bg) |bg| drawRoundedRect(x, y, w, h, style.radius, bg.r, bg.g, bg.b, 255);
    if (style.border) |border| {
        drawRoundedRect(x, y, w, h, style.radius, border.r, border.g, border.b, 72);
    }
}

fn drawBarSegmentText(renderer: *FtRenderer, x: f32, y: f32, max_width: f32, view: BarSegmentView, default_fg: ghostty.ColorRgb) void {
    const fg = view.style.fg orelse view.segment.fg orelse default_fg;
    if (view.segments_len > 0) {
        drawSegmentArray(renderer, x, y, max_width, view.segments[0..view.segments_len], fg);
        return;
    }
    const max_chars: usize = if (max_width > 0)
        @max(1, @as(usize, @intFromFloat(max_width / renderer.cell_w)))
    else
        0;
    var display_buf: [512]u8 = undefined;
    const display = if (max_chars == 0) "" else fitTabLabel(view.segment.text, max_chars, display_buf[0..]);
    if (display.len == 0) return;
    renderer.drawLabelFace(x, y, display, fg.r, fg.g, fg.b, if (view.segment.bold or view.style.bold) 1 else 0);
    c.sgl_load_default_pipeline();
}

fn segmentViewCodepoints(view: BarSegmentView) usize {
    if (view.segments_len > 0) return segmentArrayCodepoints(view.segments[0..view.segments_len]);
    return countCodepoints(view.segment.text);
}

fn segmentViewTextLen(view: BarSegmentView) usize {
    if (view.segments_len > 0) return segmentArrayTextLen(view.segments[0..view.segments_len]);
    return view.segment.text.len;
}

fn tabViewTextLen(view: BarTabView) usize {
    if (view.segments_len > 0) return segmentArrayTextLen(view.segments[0..view.segments_len]);
    return view.segment.text.len;
}

fn segmentViewShowsFullSegments(view: BarSegmentView, display: []const u8) bool {
    return view.segments_len > 0 and display.len == view.segment.text.len and segmentViewTextLen(view) == view.segment.text.len;
}

fn tabViewShowsFullSegments(view: BarTabView, display: []const u8) bool {
    return view.segments_len > 0 and display.len == view.segment.text.len and tabViewTextLen(view) == view.segment.text.len;
}

fn segmentViewFullWidth(renderer: *FtRenderer, view: BarSegmentView) f32 {
    return view.style.margin.horizontal() + view.style.padding.horizontal() + @as(f32, @floatFromInt(segmentViewCodepoints(view))) * renderer.cell_w;
}

fn tabViewFullWidth(renderer: *FtRenderer, view: BarTabView) f32 {
    return view.style.margin.horizontal() + view.style.padding.horizontal() + @as(f32, @floatFromInt(countCodepoints(view.segment.text))) * renderer.cell_w;
}

fn barItemHeight(renderer: *FtRenderer, style: BarStyle) f32 {
    return renderer.cell_h + style.padding.top + style.padding.bottom;
}

fn renderBarWidgetSurface(surface: BarSurface, renderer: *FtRenderer, app: *App, width: f32, bar_y: f32, bar_h: f32, widget: BarWidgetView) void {
    if (bar_h <= 0) return;
    const cache = if (surface == .top) &g_top_bar_cache else &g_bottom_bar_cache;
    const default_fg = ghostty.ColorRgb{ .r = 220, .g = 220, .b = 220 };

    const frame_x = widget.layout.margin.left;
    const frame_y = bar_y + widget.layout.margin.top;
    const frame_w = @max(@as(f32, 0.0), width - widget.layout.margin.horizontal());
    const frame_h = @max(@as(f32, 0.0), bar_h - widget.layout.margin.vertical());
    if (widget.style.bg != null or widget.style.border != null) {
        drawBarBackground(frame_x, frame_y, frame_w, frame_h, widget.style);
    }

    const content_x = frame_x + widget.layout.padding.left;
    const content_y = frame_y + widget.layout.padding.top;
    const content_w = @max(@as(f32, 0.0), frame_w - widget.layout.padding.horizontal());
    const content_h = @max(@as(f32, 0.0), frame_h - widget.layout.padding.vertical());
    const content_right = content_x + content_w;

    var right_reserved: f32 = 0.0;
    var saw_spacer = false;
    for (widget.items[0..widget.len]) |item| {
        switch (item.kind) {
            .spacer => saw_spacer = true,
            .segment => if (saw_spacer) {
                right_reserved += segmentViewFullWidth(renderer, item.segment);
            },
            .tabs => if (saw_spacer) {
                for (item.tabs.tabs[0..item.tabs.len]) |tab| {
                    right_reserved += tabViewFullWidth(renderer, tab);
                }
            },
        }
    }

    var cursor_x = content_x;
    var on_right_side = false;
    const active_idx = app.activeTabIndex();
    for (widget.items[0..widget.len]) |item| {
        switch (item.kind) {
            .spacer => {
                cursor_x = @max(content_x, content_right - right_reserved);
                on_right_side = true;
            },
            .segment => {
                const view = item.segment;
                const full_w = segmentViewFullWidth(renderer, view);
                const available_w = if (on_right_side)
                    full_w
                else
                    @max(@as(f32, 0.0), content_right - right_reserved - cursor_x);
                const available_text_w = @max(@as(f32, 0.0), available_w - view.style.margin.horizontal() - view.style.padding.horizontal());
                const max_chars: usize = if (available_text_w > 0)
                    @max(1, @as(usize, @intFromFloat(available_text_w / renderer.cell_w)))
                else
                    0;
                const display = if (!on_right_side and max_chars > 0 and segmentViewCodepoints(view) > max_chars)
                    takeTrailingCodepoints(view.segment.text, max_chars)
                else if (max_chars == 0 and !on_right_side)
                    ""
                else
                    view.segment.text;
                if (display.len == 0) {
                    if (on_right_side) right_reserved -= full_w;
                    continue;
                }

                const text_w = @as(f32, @floatFromInt(countCodepoints(display))) * renderer.cell_w;
                const bg_h = barItemHeight(renderer, view.style);
                const bg_x = cursor_x + view.style.margin.left;
                const bg_y = content_y + view.style.margin.top + @max(@as(f32, 0.0), (content_h - view.style.margin.vertical() - bg_h) * 0.5);
                const bg_w = view.style.padding.left + text_w + view.style.padding.right;
                var bg_style = view.style;
                if (bg_style.bg == null) bg_style.bg = view.segment.bg;
                if (bg_style.fg == null) bg_style.fg = view.segment.fg;
                if (view.segment.id) |id| cacheBarHitRegion(cache, cursor_x, view.style.margin.horizontal() + bg_w, null, 0.0, null, id);
                if (bg_style.bg != null or bg_style.border != null) {
                    drawBarBackground(bg_x, bg_y, bg_w, bg_h, bg_style);
                }

                const text_x = bg_x + view.style.padding.left;
                const text_y = bg_y + view.style.padding.top;
                const fg = bg_style.fg orelse default_fg;
                if (segmentViewShowsFullSegments(view, display)) {
                    cacheBarSegmentArray(cache, renderer, text_x, text_w, view.segments[0..view.segments_len], null);
                    drawSegmentArray(renderer, text_x, text_y, text_w, view.segments[0..view.segments_len], fg);
                } else {
                    renderer.drawLabelFace(text_x, text_y, display, fg.r, fg.g, fg.b, if (view.segment.bold or view.style.bold) 1 else 0);
                    c.sgl_load_default_pipeline();
                }
                cursor_x += view.style.margin.horizontal() + bg_w;
                if (on_right_side) right_reserved -= full_w;
            },
            .tabs => {
                const available = @max(@as(f32, 1.0), content_right - cursor_x - right_reserved);
                const default_tab_w = if (item.tabs.len > 0) available / @as(f32, @floatFromInt(item.tabs.len)) else available;
                var used_width: f32 = 0.0;
                for (item.tabs.tabs[0..item.tabs.len], 0..) |tab, ti| {
                    const full_w = tabViewFullWidth(renderer, tab);
                    const tx = cursor_x + used_width;
                    const remaining_w = content_right - right_reserved - tx;
                    if (remaining_w <= 0) break;

                    const min_tab_w = tab.style.margin.horizontal() + tab.style.padding.horizontal() + renderer.cell_w;
                    const desired_tab_w = if (item.tabs.fit_content) full_w else @max(min_tab_w, default_tab_w);
                    const tab_w = @min(desired_tab_w, remaining_w);
                    const bg_h = barItemHeight(renderer, tab.style);
                    const bg_x = tx + tab.style.margin.left;
                    const bg_y = content_y + tab.style.margin.top + @max(@as(f32, 0.0), (content_h - tab.style.margin.vertical() - bg_h) * 0.5);
                    const bg_w = @max(@as(f32, 0.0), tab_w - tab.style.margin.horizontal());

                    var bg_style = tab.style;
                    if (bg_style.bg == null) {
                        bg_style.bg = tab.segment.bg orelse ghostty.ColorRgb{
                            .r = if (ti == active_idx) 55 else 35,
                            .g = if (ti == active_idx) 58 else 37,
                            .b = if (ti == active_idx) 72 else 46,
                        };
                    }
                    if (bg_style.fg == null) {
                        bg_style.fg = tab.segment.fg orelse ghostty.ColorRgb{
                            .r = if (ti == active_idx) 255 else 185,
                            .g = if (ti == active_idx) 255 else 185,
                            .b = if (ti == active_idx) 255 else 185,
                        };
                    }

                    cacheBarHitRegion(cache, tx, tab_w, null, 0.0, ti, tab.segment.id);
                    drawBarBackground(bg_x, bg_y, bg_w, bg_h, bg_style);
                    if (tab.style.radius <= 0 and tab.style.bg == null and tab.segment.bg == null and ti == active_idx) {
                        if (surface == .top) {
                            drawBorderRect(bg_x, bg_y, bg_w, @min(@as(f32, 2.0), bg_h), 120, 150, 220, 255);
                        } else {
                            drawBorderRect(bg_x, bg_y + @max(@as(f32, 0.0), bg_h - 2.0), bg_w, @min(@as(f32, 2.0), bg_h), 120, 150, 220, 255);
                        }
                    }

                    const label_x = bg_x + tab.style.padding.left;
                    const label_space = @max(@as(f32, 0.0), bg_x + bg_w - tab.style.padding.right - label_x);
                    const max_label_chars: usize = if (label_space > 0)
                        @max(1, @as(usize, @intFromFloat(label_space / renderer.cell_w)))
                    else
                        0;
                    var display_buf: [256]u8 = undefined;
                    const display_title = if (max_label_chars == 0) "" else fitTabLabel(tab.segment.text, max_label_chars, display_buf[0..]);
                    const text_y = bg_y + tab.style.padding.top;
                    const fg = bg_style.fg orelse default_fg;
                    if (tabViewShowsFullSegments(tab, display_title)) {
                        cacheBarSegmentArray(cache, renderer, label_x, label_space, tab.segments[0..tab.segments_len], ti);
                        drawSegmentArray(renderer, label_x, text_y, label_space, tab.segments[0..tab.segments_len], fg);
                    } else if (display_title.len > 0) {
                        renderer.drawLabelFace(label_x, text_y, display_title, fg.r, fg.g, fg.b, if (tab.segment.bold or tab.style.bold) 1 else 0);
                        c.sgl_load_default_pipeline();
                    }
                    used_width += tab_w;
                }
                cursor_x += used_width;
                if (on_right_side) right_reserved -= used_width;
            },
        }
    }
}

const WidgetRenderCtx = struct {
    app: *App,
    renderer: *FtRenderer,
    width: f32,
    height: f32,
};

var g_widget_render_ctx: ?WidgetRenderCtx = null;
var g_rect_pip: c.sgl_pipeline = .{ .id = 0 };

const WidgetPreRasterCtx = struct {
    app: *App,
    renderer: *FtRenderer,
};

var g_widget_pre_raster_ctx: ?WidgetPreRasterCtx = null;

fn barCacheDirty(api: Api, state: *State, ui_idx: c_int, dirty_field: [:0]const u8) bool {
    api.get_field(state, ui_idx, dirty_field);
    const dirty = api.to_boolean(state, -1) != 0;
    pop(api, state, 1);
    return dirty;
}

fn pushBarCachedTable(api: Api, state: *State, ui_idx: c_int, dirty_field: [:0]const u8, cache_field: [:0]const u8, producer_field: [:0]const u8) bool {
    const dirty = barCacheDirty(api, state, ui_idx, dirty_field);
    if (!dirty) {
        api.get_field(state, ui_idx, cache_field);
        if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .table) return true;
        pop(api, state, 1);
    }

    api.get_field(state, ui_idx, producer_field);
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .function and api.pcall(state, 0, 1, 0) == 0 and @as(LuaType, @enumFromInt(api.value_type(state, -1))) == .table) {
        return true;
    }
    pop(api, state, 1);
    return false;
}

fn renderLuaWidgets(runtime: *lua_mod.Runtime) void {
    const ctx = g_widget_render_ctx orelse return;
    const api = runtime.context.api;
    const state = runtime.state;
    api.get_field(state, LUA_GLOBALSINDEX, "hollow");
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) != .table) {
        pop(api, state, 1);
        return;
    }
    api.get_field(state, -1, "ui");
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) != .table) {
        pop(api, state, 2);
        return;
    }
    const ui_idx = lua_mod.absoluteIndex(api, state, -1);
    var seg_text_buf: [2048]u8 = undefined;
    var reserved_sidebar_width: f32 = 0.0;
    var reserved_sidebar_side_right = false;
    var top_h: f32 = @as(f32, @floatFromInt(ctx.app.config.top_bar_height));
    var bottom_h: f32 = 0.0;

    if (pushBarCachedTable(api, state, ui_idx, "topbar_cache_dirty", "topbar_cache_layout", "_topbar_layout")) {
        const layout_idx = lua_mod.absoluteIndex(api, state, -1);
        api.get_field(state, layout_idx, "height");
        if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .number) {
            const height = api.to_number(state, -1);
            if (height > 0) top_h = @floatCast(height);
        }
        lua_mod.pop(api, state, 1);
        lua_mod.pop(api, state, 1);
    }

    if (pushBarCachedTable(api, state, ui_idx, "bottombar_cache_dirty", "bottombar_cache_layout", "_bottombar_layout")) {
        const layout_idx = lua_mod.absoluteIndex(api, state, -1);
        api.get_field(state, layout_idx, "height");
        if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .number) {
            const height = api.to_number(state, -1);
            if (height > 0) bottom_h = @as(f32, @floatCast(height));
        }
        lua_mod.pop(api, state, 1);
        lua_mod.pop(api, state, 1);
    }

    const bottom_y: f32 = ctx.height - bottom_h;

    if (top_h > 0 and pushBarCachedTable(api, state, ui_idx, "topbar_cache_dirty", "topbar_cache_state", "_topbar_state")) {
        const widget = parseBarWidgetView(api, state, lua_mod.absoluteIndex(api, state, -1), seg_text_buf[0..]);
        renderBarWidgetSurface(.top, ctx.renderer, ctx.app, ctx.width, 0.0, top_h, widget);
        lua_mod.pop(api, state, 1);
    }

    if (bottom_h > 0 and pushBarCachedTable(api, state, ui_idx, "bottombar_cache_dirty", "bottombar_cache_state", "_bottombar_state")) {
        const widget = parseBarWidgetView(api, state, lua_mod.absoluteIndex(api, state, -1), seg_text_buf[0..]);
        renderBarWidgetSurface(.bottom, ctx.renderer, ctx.app, ctx.width, bottom_y, bottom_h, widget);
        lua_mod.pop(api, state, 1);
    }

    api.get_field(state, -1, "_sidebar_state");
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .function and api.pcall(state, 0, 1, 0) == 0 and @as(LuaType, @enumFromInt(api.value_type(state, -1))) == .table) {
        const sidebar_idx = absoluteIndex(api, state, -1);
        api.get_field(state, sidebar_idx, "width");
        const sidebar_cols = if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .number) @as(usize, @intFromFloat(api.to_number(state, -1))) else 24;
        pop(api, state, 1);
        const sidebar_width = @as(f32, @floatFromInt(sidebar_cols)) * ctx.renderer.cell_w + ctx.renderer.cell_w;

        api.get_field(state, sidebar_idx, "reserve");
        const reserve = api.to_boolean(state, -1) != 0;
        pop(api, state, 1);

        api.get_field(state, sidebar_idx, "side");
        var side_len: usize = 0;
        const side_ptr = api.to_lstring(state, -1, &side_len);
        const side = if (side_ptr) |ptr| ptr[0..side_len] else "left";
        pop(api, state, 1);
        if (reserve) {
            reserved_sidebar_width = sidebar_width;
            reserved_sidebar_side_right = std.mem.eql(u8, side, "right");
        }

        const panel_x: f32 = if (std.mem.eql(u8, side, "right")) ctx.width - sidebar_width else 0.0;
        const panel_y: f32 = top_h;
        const panel_h: f32 = ctx.height - panel_y - bottom_h;
        drawBorderRect(panel_x, panel_y, sidebar_width, panel_h, 22, 27, 34, 235);
        drawBorderRect(panel_x, panel_y, sidebar_width, 1.0, 122, 162, 247, 255);

        api.get_field(state, sidebar_idx, "rows");
        if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .table) {
            var sidebar_seg_buf: [32]bar.Segment = undefined;
            const rows_idx = absoluteIndex(api, state, -1);
            var row_i: c_int = 1;
            while (true) : (row_i += 1) {
                api.rawgeti(state, rows_idx, row_i);
                if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .nil_type) {
                    pop(api, state, 1);
                    break;
                }
                if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .table) {
                    const row_segments = lua_mod.parseSegmentArray(api, state, sidebar_seg_buf[0..], seg_text_buf[0..], absoluteIndex(api, state, -1));
                    const text_y = panel_y + ctx.renderer.cell_h * @as(f32, @floatFromInt(row_i));
                    drawRowSegments(ctx.renderer, panel_x + ctx.renderer.cell_w * 0.5, text_y, sidebar_width - ctx.renderer.cell_w, row_segments);
                }
                pop(api, state, 1);
            }
        }
        pop(api, state, 1);
    }
    pop(api, state, 1);

    api.get_field(state, -1, "_overlay_state");
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .function and api.pcall(state, 0, 1, 0) == 0 and @as(LuaType, @enumFromInt(api.value_type(state, -1))) == .table) {
        var overlay_seg_buf: [32]bar.Segment = undefined;
        const stacks_idx = absoluteIndex(api, state, -1);
        var stack_i: c_int = 1;
        while (true) : (stack_i += 1) {
            api.rawgeti(state, stacks_idx, stack_i);
            if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .nil_type) {
                pop(api, state, 1);
                break;
            }
            if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .table) {
                const overlay_idx = absoluteIndex(api, state, -1);
                api.get_field(state, overlay_idx, "backdrop");
                var backdrop_color: ?ghostty.ColorRgb = null;
                var backdrop_alpha: u8 = 0;
                if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .table) {
                    api.get_field(state, -1, "color");
                    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .string) {
                        var color_len: usize = 0;
                        if (api.to_lstring(state, -1, &color_len)) |color_ptr| {
                            backdrop_color = parseHexColor(color_ptr[0..color_len]);
                        }
                    }
                    pop(api, state, 1);

                    api.get_field(state, -1, "alpha");
                    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .number) {
                        const value = api.to_number(state, -1);
                        backdrop_alpha = @intCast(std.math.clamp(@as(i32, @intFromFloat(value)), 0, 255));
                    }
                    pop(api, state, 1);
                }
                pop(api, state, 1);

                api.get_field(state, overlay_idx, "width");
                var width_rows: usize = 0;
                if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .number) {
                    const value = api.to_number(state, -1);
                    if (value > 0) width_rows = @intFromFloat(value);
                }
                pop(api, state, 1);

                api.get_field(state, overlay_idx, "height");
                var height_rows: usize = 0;
                if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .number) {
                    const value = api.to_number(state, -1);
                    if (value > 0) height_rows = @intFromFloat(value);
                }
                pop(api, state, 1);

                api.get_field(state, overlay_idx, "chrome");
                var panel_bg = ghostty.ColorRgb{ .r = 18, .g = 22, .b = 30 };
                var panel_border = ghostty.ColorRgb{ .r = 136, .g = 192, .b = 208 };
                if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .table) {
                    if (overlayRowColorField(api, state, absoluteIndex(api, state, -1), "bg")) |bg| {
                        panel_bg = bg;
                    }
                    if (overlayRowColorField(api, state, absoluteIndex(api, state, -1), "border")) |border| {
                        panel_border = border;
                    }
                }
                pop(api, state, 1);

                api.get_field(state, overlay_idx, "rows");
                if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) != .table) {
                    pop(api, state, 1);
                    pop(api, state, 1);
                    continue;
                }
                const rows_idx = absoluteIndex(api, state, -1);
                api.get_field(state, overlay_idx, "align");
                var align_len: usize = 0;
                const align_ptr = api.to_lstring(state, -1, &align_len);
                const overlay_align = if (align_ptr) |ptr| ptr[0..align_len] else "center";
                pop(api, state, 1);

                var max_chars: usize = 0;
                var row_count: usize = 0;
                var row_i_measure: c_int = 1;
                while (true) : (row_i_measure += 1) {
                    api.rawgeti(state, rows_idx, row_i_measure);
                    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .nil_type) {
                        pop(api, state, 1);
                        break;
                    }
                    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .table) {
                        const row_idx = absoluteIndex(api, state, -1);
                        const row_segments_idx = overlayRowSegmentsIndex(api, state, row_idx);
                        const row_segments = lua_mod.parseSegmentArray(api, state, overlay_seg_buf[0..], seg_text_buf[0..], row_segments_idx);
                        var row_chars: usize = 0;
                        for (row_segments) |seg| row_chars += countCodepoints(seg.text);
                        if (row_chars > max_chars) max_chars = row_chars;
                        row_count += 1;
                        if (row_segments_idx != row_idx) pop(api, state, 1);
                    }
                    pop(api, state, 1);
                }

                const available_width = @max(@as(f32, 160.0), ctx.width - reserved_sidebar_width);
                const max_panel_w = available_width - ctx.renderer.cell_w * 2.0;
                const content_w = @as(f32, @floatFromInt(max_chars)) * ctx.renderer.cell_w;
                const desired_panel_w = if (width_rows > 0)
                    @as(f32, @floatFromInt(width_rows)) * ctx.renderer.cell_w
                else
                    content_w + ctx.renderer.cell_w * 2.0;
                const desired_panel_h = if (height_rows > 0)
                    @as(f32, @floatFromInt(height_rows)) * ctx.renderer.cell_h
                else
                    @as(f32, @floatFromInt(@max(@as(usize, 1), row_count))) * ctx.renderer.cell_h + ctx.renderer.cell_h * 1.5;
                const panel_w = std.math.clamp(desired_panel_w, @as(f32, 160.0), @max(@as(f32, 160.0), max_panel_w));
                const panel_h = std.math.clamp(desired_panel_h, ctx.renderer.cell_h * 3.0, ctx.height - top_h - bottom_h - ctx.renderer.cell_h * 2.0);
                const content_left = if (reserved_sidebar_width > 0 and !reserved_sidebar_side_right)
                    reserved_sidebar_width
                else
                    0.0;
                const content_right = if (reserved_sidebar_width > 0 and reserved_sidebar_side_right)
                    ctx.width - reserved_sidebar_width
                else
                    ctx.width;
                const content_width = @max(@as(f32, 1.0), content_right - content_left);
                const overlay_margin_x = ctx.renderer.cell_w;
                const overlay_margin_y = ctx.renderer.cell_h;
                const stack_offset = ctx.renderer.cell_h * 0.75 * @as(f32, @floatFromInt(stack_i - 1));

                var panel_x = content_left + (content_width - panel_w) * 0.5;
                var panel_y = top_h + overlay_margin_y + stack_offset;

                if (std.mem.eql(u8, overlay_align, "top_left")) {
                    panel_x = content_left + overlay_margin_x;
                    panel_y = top_h + overlay_margin_y + stack_offset;
                } else if (std.mem.eql(u8, overlay_align, "top_center")) {
                    panel_x = content_left + (content_width - panel_w) * 0.5;
                    panel_y = top_h + overlay_margin_y + stack_offset;
                } else if (std.mem.eql(u8, overlay_align, "top_right")) {
                    panel_x = content_right - panel_w - overlay_margin_x;
                    panel_y = top_h + overlay_margin_y + stack_offset;
                } else if (std.mem.eql(u8, overlay_align, "left_center")) {
                    panel_x = content_left + overlay_margin_x;
                    panel_y = top_h + ((ctx.height - top_h - bottom_h) - panel_h) * 0.5 + stack_offset;
                } else if (std.mem.eql(u8, overlay_align, "right_center")) {
                    panel_x = content_right - panel_w - overlay_margin_x;
                    panel_y = top_h + ((ctx.height - top_h - bottom_h) - panel_h) * 0.5 + stack_offset;
                } else if (std.mem.eql(u8, overlay_align, "bottom_left")) {
                    panel_x = content_left + overlay_margin_x;
                    panel_y = ctx.height - bottom_h - panel_h - overlay_margin_y - stack_offset;
                } else if (std.mem.eql(u8, overlay_align, "bottom_center")) {
                    panel_x = content_left + (content_width - panel_w) * 0.5;
                    panel_y = ctx.height - bottom_h - panel_h - overlay_margin_y - stack_offset;
                } else if (std.mem.eql(u8, overlay_align, "bottom_right")) {
                    panel_x = content_right - panel_w - overlay_margin_x;
                    panel_y = ctx.height - bottom_h - panel_h - overlay_margin_y - stack_offset;
                }

                panel_x = std.math.clamp(panel_x, content_left + overlay_margin_x, content_right - panel_w - overlay_margin_x);
                panel_y = std.math.clamp(panel_y, top_h + overlay_margin_y, ctx.height - bottom_h - panel_h - overlay_margin_y);
                if (backdrop_color) |bg| {
                    if (backdrop_alpha > 0) {
                        drawBorderRect(content_left, top_h, content_width, ctx.height - top_h - bottom_h, bg.r, bg.g, bg.b, backdrop_alpha);
                    }
                }
                drawBorderRect(panel_x, panel_y, panel_w, panel_h, panel_bg.r, panel_bg.g, panel_bg.b, 235);
                drawBorderRect(panel_x, panel_y, panel_w, 1.0, panel_border.r, panel_border.g, panel_border.b, 255);

                var row_i: c_int = 1;
                while (true) : (row_i += 1) {
                    api.rawgeti(state, rows_idx, row_i);
                    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .nil_type) {
                        pop(api, state, 1);
                        break;
                    }
                    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .table) {
                        const row_idx = absoluteIndex(api, state, -1);
                        const row_segments_idx = overlayRowSegmentsIndex(api, state, row_idx);
                        const row_segments = lua_mod.parseSegmentArray(api, state, overlay_seg_buf[0..], seg_text_buf[0..], row_segments_idx);
                        const text_y = panel_y + ctx.renderer.cell_h * @as(f32, @floatFromInt(row_i));
                        const row_fill_bg = overlayRowColorField(api, state, row_idx, "fill_bg");
                        const row_divider = overlayRowColorField(api, state, row_idx, "divider");
                        const row_scrollbar_track = overlayRowBoolField(api, state, row_idx, "scrollbar_track");
                        const row_scrollbar_thumb = overlayRowBoolField(api, state, row_idx, "scrollbar_thumb");
                        const row_scrollbar_track_color = overlayRowColorField(api, state, row_idx, "scrollbar_track_color") orelse ghostty.ColorRgb{ .r = 90, .g = 99, .b = 117 };
                        const row_scrollbar_thumb_color = overlayRowColorField(api, state, row_idx, "scrollbar_thumb_color") orelse panel_border;
                        const row_x = panel_x + ctx.renderer.cell_w * 0.5;
                        const row_w = panel_w - ctx.renderer.cell_w;
                        if (row_fill_bg) |bg| {
                            drawBorderRect(row_x, text_y + 1.0, row_w, @max(@as(f32, 1.0), ctx.renderer.cell_h - 2.0), bg.r, bg.g, bg.b, 255);
                        }
                        if (row_divider) |divider| {
                            drawBorderRect(row_x, text_y + ctx.renderer.cell_h * 0.5, row_w, 1.0, divider.r, divider.g, divider.b, 255);
                        }
                        if (row_scrollbar_track) {
                            const sc = if (row_scrollbar_thumb) row_scrollbar_thumb_color else row_scrollbar_track_color;
                            drawBorderRect(row_x + row_w - 2.0, text_y + 2.0, 1.0, @max(@as(f32, 1.0), ctx.renderer.cell_h - 4.0), sc.r, sc.g, sc.b, if (row_scrollbar_thumb) 255 else 120);
                        }
                        drawRowSegments(ctx.renderer, panel_x + ctx.renderer.cell_w * 0.5, text_y, panel_w - ctx.renderer.cell_w, row_segments);
                        if (row_segments_idx != row_idx) pop(api, state, 1);
                    }
                    pop(api, state, 1);
                }
                pop(api, state, 1);
            }
            pop(api, state, 1);
        }
    }
    pop(api, state, 3);
}

fn preRasterizeLuaBarWidgets(runtime: *lua_mod.Runtime) void {
    const ctx = g_widget_pre_raster_ctx orelse return;
    const renderer = ctx.renderer;
    const api = runtime.context.api;
    const state = runtime.state;
    api.get_field(state, LUA_GLOBALSINDEX, "hollow");
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) != .table) {
        pop(api, state, 1);
        return;
    }
    api.get_field(state, -1, "ui");
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) != .table) {
        pop(api, state, 2);
        return;
    }
    const ui_idx = lua_mod.absoluteIndex(api, state, -1);

    const process_bar = struct {
        fn run(api_: Api, state_: *lua_mod.State, renderer_: *FtRenderer, ui_idx_: c_int, dirty_field: [:0]const u8, cache_field: [:0]const u8, producer_field: [:0]const u8) void {
            const dirty = barCacheDirty(api_, state_, ui_idx_, dirty_field);
            if (!dirty and !renderer_.atlas_dirty) return;
            if (pushBarCachedTable(api_, state_, ui_idx_, dirty_field, cache_field, producer_field)) {
                var text_buf: [2048]u8 = undefined;
                const view = parseBarWidgetView(api_, state_, lua_mod.absoluteIndex(api_, state_, -1), text_buf[0..]);
                for (view.items[0..view.len]) |item| {
                    switch (item.kind) {
                        .segment => {
                            if (item.segment.segment.text.len > 0) renderer_.preRasterizeLabel(item.segment.segment.text);
                        },
                        .tabs => {
                            for (item.tabs.tabs[0..item.tabs.len]) |tab| {
                                if (tab.segment.text.len > 0) renderer_.preRasterizeLabel(tab.segment.text);
                            }
                        },
                        .spacer => {},
                    }
                }
                lua_mod.pop(api_, state_, 1);
            }
        }
    };

    process_bar.run(api, state, renderer, ui_idx, "topbar_cache_dirty", "topbar_cache_state", "_topbar_state");
    process_bar.run(api, state, renderer, ui_idx, "bottombar_cache_dirty", "bottombar_cache_state", "_bottombar_state");

    pop(api, state, 2);
}

fn computeCustomTabLayouts(app: *App, renderer: *FtRenderer, start_x: f32, max_right: f32, layouts: []CustomTabLayout, title_storage: []u8) []CustomTabLayout {
    const tab_count = @min(app.tabCount(), layouts.len);
    if (tab_count == 0 or max_right <= start_x or title_storage.len == 0) return layouts[0..0];

    var temp_title_buf: [256]u8 = undefined;
    const available_width = max_right - start_x;
    if (available_width <= 0) return layouts[0..0];
    const close_w: f32 = renderer.cell_w + 10.0;
    const label_padding: f32 = renderer.cell_w;

    var text_used: usize = 0;
    var cursor_x = start_x;
    var layout_count: usize = 0;
    for (0..tab_count) |ti| {
        if (cursor_x >= max_right) break;
        const seg = app.topBarTitleSegment(ti, false, &temp_title_buf);
        const title = seg.text;
        const x = cursor_x;
        const desired_width = @max(close_w + label_padding, @as(f32, @floatFromInt(countCodepoints(title))) * renderer.cell_w + close_w + label_padding);
        const width = @min(desired_width, max_right - x);
        if (width <= 0) break;
        const close_x = @floor(x + width - close_w + 2.0);
        const remaining_storage = title_storage.len - text_used;
        if (remaining_storage == 0) break;
        const copy_len = @min(title.len, remaining_storage);
        @memcpy(title_storage[text_used .. text_used + copy_len], title[0..copy_len]);
        const stored_title = title_storage[text_used .. text_used + copy_len];

        layouts[layout_count] = .{
            .x = x,
            .width = width,
            .title = stored_title,
            .close_x = close_x,
            .close_w = close_w,
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

fn resetBarCache(cache: *BarCache, window_width: f32, y: f32, bar_h: f32) void {
    cache.* = .{
        .enabled = bar_h > 0,
        .width = window_width,
        .height = bar_h,
        .y = y,
    };
}

fn cacheBarHitRegion(cache: *BarCache, x: f32, width: f32, close_x: ?f32, close_w: f32, tab_index: ?usize, node_id: ?[]const u8) void {
    if (cache.hit_count >= cache.hits.len or width <= 0) return;
    cache.hits[cache.hit_count] = .{
        .x = x,
        .width = width,
        .close_x = close_x orelse 0,
        .close_w = close_w,
        .has_close = close_x != null,
        .tab_index = tab_index,
        .node_id = node_id,
    };
    cache.hit_count += 1;
}

fn hitTestBar(cache: *const BarCache, surface: BarSurface, mouse_x: f32, mouse_y: f32, window_width: f32) BarHit {
    var hit = BarHit{};
    if (!cache.enabled or mouse_y < cache.y or mouse_y >= cache.y + cache.height or mouse_x < 0 or mouse_x >= window_width) return hit;

    hit.surface = surface;
    var idx = @min(cache.hit_count, cache.hits.len);
    while (idx > 0) {
        idx -= 1;
        const region = cache.hits[idx];
        if (region.width <= 0) continue;
        if (mouse_x < region.x or mouse_x >= region.x + region.width) continue;

        hit.tab_index = region.tab_index;
        hit.node_id = region.node_id;
        if (region.has_close and mouse_x >= region.close_x and mouse_x < region.close_x + region.close_w) {
            hit.close_tab_index = region.tab_index;
        }
        return hit;
    }
    return hit;
}

fn topBarHitTest(_: *App, mouse_x: f32, mouse_y: f32, window_width: f32) BarHit {
    return hitTestBar(&g_top_bar_cache, .top, mouse_x, mouse_y, window_width);
}

fn bottomBarHitTest(_: *App, mouse_x: f32, mouse_y: f32, window_width: f32) BarHit {
    return hitTestBar(&g_bottom_bar_cache, .bottom, mouse_x, mouse_y, window_width);
}

fn updateBarHover(app: *App, mouse_x: f32, mouse_y: f32, window_width: f32) BarHit {
    const bottom_hit = bottomBarHitTest(app, mouse_x, mouse_y, window_width);
    const top_hit = topBarHitTest(app, mouse_x, mouse_y, window_width);
    const hit = if (bottom_hit.surface != null) bottom_hit else top_hit;
    _ = app.enqueueMouse(.{ .hover = .{
        .tab_index = hit.tab_index,
        .close_tab_index = hit.close_tab_index,
    } });
    if (hit.surface == .top) {
        if (hit.node_id) |id| {
            app.emitLuaBuiltInEvent("topbar:hover", .{ .topbar_node = .{ .id = id } });
        } else {
            app.emitLuaBuiltInEvent("topbar:leave", .none);
        }
        app.emitLuaBuiltInEvent("bottombar:leave", .none);
        return hit;
    }

    app.emitLuaBuiltInEvent("topbar:leave", .none);
    if (hit.node_id) |id| {
        app.emitLuaBuiltInEvent("bottombar:hover", .{ .bottombar_node = .{ .id = id } });
    } else {
        app.emitLuaBuiltInEvent("bottombar:leave", .none);
    }
    return hit;
}

fn updateTopBarHover(app: *App, mouse_x: f32, mouse_y: f32, window_width: f32) BarHit {
    const hit = topBarHitTest(app, mouse_x, mouse_y, window_width);
    _ = app.enqueueMouse(.{ .hover = .{
        .tab_index = hit.tab_index,
        .close_tab_index = hit.close_tab_index,
    } });
    if (hit.node_id) |id| {
        app.emitLuaBuiltInEvent("topbar:hover", .{ .topbar_node = .{ .id = id } });
    } else {
        app.emitLuaBuiltInEvent("topbar:leave", .none);
    }
    return hit;
}

fn scrollbarTrackRowForPosition(metrics: App.ScrollbarMetrics, pointer_y: f32, grab_offset_y: f32) u64 {
    const travel = @max(@as(f32, 0.0), metrics.track_h - metrics.thumb_h);
    if (travel <= 0 or metrics.total <= metrics.len) return 0;

    const thumb_y = std.math.clamp(pointer_y - grab_offset_y, metrics.track_y, metrics.track_y + travel);
    const ratio = (thumb_y - metrics.track_y) / travel;
    const max_top = if (metrics.total > metrics.len) metrics.total - metrics.len else 0;
    return @intFromFloat(@round(ratio * @as(f32, @floatFromInt(max_top))));
}

fn scrollbarHitThumb(metrics: App.ScrollbarMetrics, x: f32, y: f32) bool {
    return x >= metrics.track_x and x < metrics.track_x + metrics.track_w and y >= metrics.thumb_y and y < metrics.thumb_y + metrics.thumb_h;
}

fn drawScrollbar(app: *App, metrics: App.ScrollbarMetrics) void {
    const cfg = app.config.scrollbar;
    const hover = g_scrollbar_hover_pane == metrics.pane;
    const active = g_scrollbar_drag_pane == metrics.pane;
    const thumb_color = if (active)
        cfg.thumb_active_color
    else if (hover)
        cfg.thumb_hover_color
    else
        cfg.thumb_color;
    const inset_x = metrics.track_x + 2.0;
    const inset_w = @max(@as(f32, 2.0), metrics.track_w - 4.0);

    drawBorderRect(metrics.track_x, metrics.track_y, metrics.track_w, metrics.track_h, cfg.track_color.r, cfg.track_color.g, cfg.track_color.b, 72);
    drawBorderRect(metrics.track_x + metrics.track_w - 1.0, metrics.track_y, 1.0, metrics.track_h, cfg.border_color.r, cfg.border_color.g, cfg.border_color.b, 96);
    drawBorderRect(inset_x, metrics.track_y, 1.0, metrics.track_h, cfg.border_color.r, cfg.border_color.g, cfg.border_color.b, 36);
    drawBorderRect(inset_x, metrics.thumb_y, inset_w, metrics.thumb_h, thumb_color.r, thumb_color.g, thumb_color.b, if (active) 230 else 190);
}

fn drawStatusSegments(renderer: *FtRenderer, x: f32, y: f32, bar_y: f32, bar_h: f32, segments: []const bar.Segment) f32 {
    var cursor_x = x;
    for (segments) |seg| {
        if (seg.text.len == 0) continue;
        const seg_w = @as(f32, @floatFromInt(countCodepoints(seg.text))) * renderer.cell_w;
        if (seg.id) |id| {
            cacheBarHitRegion(&g_top_bar_cache, cursor_x, seg_w, null, 0.0, null, id);
        }
        if (seg.bg) |bg| {
            drawBorderRect(cursor_x, bar_y, seg_w, bar_h, bg.r, bg.g, bg.b, 255);
        }
        const fg = seg.fg orelse ghostty.ColorRgb{ .r = 220, .g = 220, .b = 220 };
        renderer.drawLabelFace(cursor_x, y, seg.text, fg.r, fg.g, fg.b, if (seg.bold) 1 else 0);
        c.sgl_load_default_pipeline();
        cursor_x += seg_w;
    }
    return cursor_x;
}

fn drawSingleSegment(renderer: *FtRenderer, x: f32, y: f32, bar_y: f32, bar_h: f32, segment: bar.Segment, default_fg: ghostty.ColorRgb, default_bg: ?ghostty.ColorRgb) f32 {
    if (segment.text.len == 0) return x;
    const seg_w = @as(f32, @floatFromInt(countCodepoints(segment.text))) * renderer.cell_w;
    if (segment.id) |id| {
        cacheBarHitRegion(&g_top_bar_cache, x, seg_w, null, 0.0, null, id);
    }
    if (segment.bg orelse default_bg) |bg| {
        drawBorderRect(x, bar_y, seg_w, bar_h, bg.r, bg.g, bg.b, 255);
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

fn rebuildFtRenderer(app: *App) void {
    if (g_ft_renderer) |*renderer| {
        renderer.deinit();
        g_ft_renderer = null;
    }

    const dpi_scale = c.sapp_dpi_scale();
    std.log.info("sokol dpi_scale={d:.2} font_size={d:.1} line_height={d:.2}", .{ dpi_scale, app.config.fonts.size, app.config.fonts.line_height });

    g_ft_renderer = FtRenderer.init(std.heap.page_allocator, .{
        .font_size = app.config.fonts.size,
        .dpi_scale = dpi_scale,
        .line_height = app.config.fonts.line_height,
        .padding_x = app.config.fonts.padding_x + @as(f32, @floatFromInt(app.config.terminal_padding.left)),
        .padding_y = app.config.fonts.padding_y + @as(f32, @floatFromInt(app.config.terminal_padding.top)),
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
        .family = app.config.fonts.family,
        .regular_path = app.config.fonts.regular,
        .bold_path = app.config.fonts.bold,
        .italic_path = app.config.fonts.italic,
        .bold_italic_path = app.config.fonts.bold_italic,
        .fallback_paths = app.config.fonts.fallback_paths.items,
    }) catch |err| blk: {
        std.log.err("ft_renderer init failed: {}", .{err});
        break :blk null;
    };

    invalidateAllPaneCaches();
    g_renderer_ready = false;

    if (g_ft_renderer) |*renderer| {
        renderer.warmupAtlas();
        const cw: u32 = @max(1, @as(u32, @intFromFloat(renderer.cell_w)));
        const ch: u32 = @max(1, @as(u32, @intFromFloat(renderer.cell_h)));
        app.setCellSize(cw, ch);
        const pixel_size = windowSizeToPixels(c.sapp_widthf(), c.sapp_heightf());
        app.requestResize(pixel_size.width, pixel_size.height);
    }
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
    @memset(g_last_window_title[0..], 0);
    g_gui_ready_fired = false;
    g_window_chrome_applied = false;
    g_prev_wnd_proc = 0;
    g_subclassed_hwnd = null;
    g_window_iconified = false;
    g_restore_pending = false;
    g_ignore_resize_frames = 0;
    g_selection_pointer_active = false;
    g_selection_pointer_pane = null;
    g_scrollbar_drag_pane = null;
    g_scrollbar_drag_metrics = null;
    g_scrollbar_drag_grab_y = 0.0;
    g_scrollbar_hover_pane = null;
    g_hover_hyperlink = false;
    g_skip_mouse_release = null;
    g_skip_mouse_move_frames = 0;
    g_block_left_mouse_until_up = false;
    g_block_all_mouse_until_up = false;
    g_last_frame_time_ns = 0;
    g_last_perf_sample_ns = 0;
    g_perf_accum_frame_ns = 0;
    g_perf_accum_frames = 0;
    g_perf_fps = 0;
    g_perf_frame_ms = 0;
    g_perf_window_max_frame_ns = 0;
    g_perf_max_frame_ms = 0;
    g_phase_accum_tick_ns = 0;
    g_phase_accum_offscreen_ns = 0;
    g_phase_accum_swapchain_ns = 0;
    g_phase_accum_offscreen_terminal_ns = 0;
    g_phase_accum_offscreen_bar_preraster_ns = 0;
    g_phase_accum_swapchain_panes_ns = 0;
    g_phase_accum_swapchain_ui_ns = 0;
    g_phase_accum_swapchain_glyph_ns = 0;
    g_phase_accum_swapchain_submit_ns = 0;
    g_phase_accum_dirty_frames = 0;
    g_phase_accum_clean_frames = 0;
    g_phase_sample_frames = 0;
    g_phase_last_log_ns = 0;
    g_last_frame_tick_ms = 0;
    g_last_frame_offscreen_ms = 0;
    g_last_frame_queue_ms = 0;
    g_last_frame_gpu_ms = 0;
    g_last_frame_swap_ms = 0;
    g_last_frame_offscreen_terminal_ms = 0;
    g_last_frame_offscreen_bar_preraster_ms = 0;
    g_last_frame_swapchain_panes_ms = 0;
    g_last_frame_swapchain_ui_ms = 0;
    g_last_frame_swapchain_glyph_ms = 0;
    g_last_frame_swapchain_submit_ms = 0;
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
    desc.logger.func = c.slog_func;
    if (builtin.os.tag == .linux) {
        // Sokol defaults to a GL 4.3 core context on Linux. Some GLX drivers
        // reject that request even though they can run a 3.3 core context.
        desc.gl.major_version = 3;
        desc.gl.minor_version = 3;
    }
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
    sg_desc.logger.func = c.slog_func;
    // The cached multi-pane renderer allocates per-pane images, views, samplers,
    // buffers, pipelines, and commit listeners. The sokol defaults are tuned for
    // simple demos and start failing once a realistic multi-project workspace has
    // many tabs plus split panes alive at once, even if only one tab is visible.
    sg_desc.buffer_pool_size = MAX_PANE_CACHES * 2 + 64;
    sg_desc.image_pool_size = MAX_PANE_CACHES * 2 + 32;
    sg_desc.sampler_pool_size = MAX_PANE_CACHES * 3 + 32;
    sg_desc.shader_pool_size = 64;
    sg_desc.view_pool_size = MAX_PANE_CACHES * 4 + 64;
    sg_desc.max_commit_listeners = MAX_PANE_CACHES * 2 + 64;
    // Each pane cache ends up consuming a surprising number of sg pipelines:
    // one sokol_gl context default pipeline (5 backend pipelines) plus one
    // extra pane atlas pipeline (another 5). With 6 panes we exceed sokol_gfx's
    // default pipeline pool size of 64 and crash during cache creation.
    sg_desc.pipeline_pool_size = MAX_PANE_CACHES * 12 + 64;
    c.sg_setup(&sg_desc);
    {
        const sc = c.sglue_swapchain();
        std.log.info("sokol: swapchain color_format={d} depth_format={d} samples={d}", .{ sc.color_format, sc.depth_format, sc.sample_count });
        std.log.info("sokol: environment color_format={d} depth_format={d} samples={d}", .{ sg_desc.environment.defaults.color_format, sg_desc.environment.defaults.depth_format, sg_desc.environment.defaults.sample_count });
    }

    // sokol_gl is required by sokol_fontstash for glyph rendering.
    var sgl_desc = std.mem.zeroes(c.sgl_desc_t);
    sgl_desc.logger.func = c.slog_func;
    sgl_desc.max_vertices = 1 << 20;
    sgl_desc.max_commands = 1 << 18;
    // Each pane cache owns its own sokol_gl context, plus the default context
    // used for swapchain/UI rendering. The sokol_gl default context pool size is
    // 4 total contexts, which makes the 4th cached pane fail to get a usable
    // context and drops overlays like the cursor. Size the pool to our cache cap.
    sgl_desc.context_pool_size = MAX_PANE_CACHES + 1;
    sgl_desc.pipeline_pool_size = MAX_PANE_CACHES * 2 + 16;
    c.sgl_setup(&sgl_desc);

    var rect_pip_desc = std.mem.zeroes(c.sg_pipeline_desc);
    rect_pip_desc.colors[0].blend.enabled = true;
    rect_pip_desc.colors[0].blend.src_factor_rgb = c.SG_BLENDFACTOR_SRC_ALPHA;
    rect_pip_desc.colors[0].blend.dst_factor_rgb = c.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
    rect_pip_desc.colors[0].blend.src_factor_alpha = c.SG_BLENDFACTOR_ONE;
    rect_pip_desc.colors[0].blend.dst_factor_alpha = c.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
    g_rect_pip = c.sgl_make_pipeline(&rect_pip_desc);

    _ = applyWindowChrome(app);
    rebuildFtRenderer(app);

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

fn invalidateAllPaneCaches() void {
    for (&g_pane_caches) |*slot| {
        if (slot.*) |*entry| {
            entry.needs_clear = true;
            entry.force_full_frames = 2;
            entry.layout_generation = 0;
            entry.stable_after_resize = false;
            entry.last_cols = 0;
            entry.last_rows = 0;
            entry.validity = .invalid;
            entry.last_atlas_epoch = 0;
            entry.has_bg_color = false;
            @memset(&entry.row_map_keys, ROW_MAP_EMPTY);
            @memset(&entry.row_map_vals, 0);
            entry.prev_cursor_row = std.math.maxInt(usize);
        }
    }
}

fn frameCb(user_data: ?*anyopaque) callconv(.c) void {
    const app = appFromUserData(user_data) orelse return;
    const frame_start_ns = std.time.nanoTimestamp();
    const collect_perf = app.config.debug_overlay;
    if (collect_perf) {
        updatePerfCounters(frame_start_ns);
    }
    if (builtin.os.tag == .windows and !g_window_chrome_applied) {
        g_window_chrome_applied = applyWindowChrome(app);
    }
    g_frame_index += 1;
    if (g_frames_since_drag_release < std.math.maxInt(usize)) g_frames_since_drag_release += 1;
    if (g_ignore_resize_frames > 0) g_ignore_resize_frames -= 1;
    if (@atomicLoad(bool, &g_restore_pending, .acquire)) {
        @atomicStore(bool, &g_restore_pending, false, .release);
        invalidateAllPaneCaches();
        app.invalidateAllPanes();
        // Do not trust sapp_widthf()/heightf() here on Windows restore.
        // Sokol can still report the transient minimized size (e.g. 160x28)
        // for one frame, which collapses the shell grid to 17x1 and makes the
        // restored terminal look as if `clear` ran.  The real resize is handled
        // by the restore/resize events themselves.
    }
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

    if (g_drag_node == null and !app.hasVisualActivity()) {
        // With vsync on, a long pre-render idle sleep can push a newly-active
        // frame past the next refresh and make scrolling feel like 30 FPS.
        const idle_frame_ns = if (app.config.vsync) @as(i128, 8_000_000) else g_idle_frame_ns;
        const idle_deadline_ns = frame_start_ns + idle_frame_ns;
        var now_ns = after_tick_ns;
        // Re-check activity in short slices so fresh PTY output does not sit
        // behind the full idle delay and make interactive apps feel sticky.
        while (now_ns < idle_deadline_ns and !app.hasVisualActivity()) {
            const remaining_ns = idle_deadline_ns - now_ns;
            if (remaining_ns > 100_000) {
                const sleep_ns = @min(remaining_ns, @as(i128, 1_000_000));
                std.Thread.sleep(@as(u64, @intCast(sleep_ns)));
            } else {
                std.Thread.yield() catch {};
            }
            now_ns = std.time.nanoTimestamp();
        }
    }

    if (@atomicLoad(bool, &g_window_iconified, .acquire)) return;

    const fb = framebufferSize();
    const width = fb.width;
    const height = fb.height;
    if (width <= 0 or height <= 0) return;

    if (app.pending_renderer_refresh) {
        app.pending_renderer_refresh = false;
        rebuildFtRenderer(app);
    }

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
    var offscreen_terminal_ns: i128 = 0;
    var offscreen_bar_preraster_ns: i128 = 0;

    // Decide once whether to use direct rendering.
    // renderer_safe_mode forces the simpler direct path for all panes as a
    // diagnostic escape hatch from the cached RT pipeline.
    const use_direct_render = app.config.renderer_single_pane_direct and
        leaves.len == 0 and app.tabBarHeight() == 0 and app.bottomBarHeight() == 0;
    const use_safe_render = app.config.renderer_safe_mode;
    const single_visible_pane = if (leaves.len == 0) app.activePane() else null;
    const auto_disable_multi_pane_cache = leaves.len > MAX_CACHED_VISIBLE_PANES;
    const use_direct_multi_pane = (app.config.renderer_disable_multi_pane_cache or auto_disable_multi_pane_cache) and leaves.len > 1;
    if (use_direct_multi_pane) {
        releaseAllPaneCaches();
    } else {
        prunePaneCachesToVisible(leaves, single_visible_pane);
    }
    if (g_ft_renderer) |*renderer| {
        renderer.beginFrame();
        // Reset frame-local queue/gpu accumulators for the debug overlay.
        g_frame_queue_ns = 0;
        g_frame_gpu_ns = 0;
        const offscreen_terminal_start_ns = std.time.nanoTimestamp();

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
                    selection_range: ?selection.Range,
                    hovered_hyperlink: ?App.HoveredHyperlink,
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
                    pane_pad_x: u32,
                    pane_pad_y: u32,
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
                    var bg_color = ghostty.ColorRgb{ .r = 0, .g = 0, .b = 0 };
                    if (cfg.terminal_theme.enabled) {
                        bg_color = cfg.terminal_theme.background;
                        cr = @as(f32, @floatFromInt(cfg.terminal_theme.background.r)) / 255.0;
                        cg = @as(f32, @floatFromInt(cfg.terminal_theme.background.g)) / 255.0;
                        cb = @as(f32, @floatFromInt(cfg.terminal_theme.background.b)) / 255.0;
                    } else if (rt.renderStateColors(pane.render_state)) |colors| {
                        bg_color = colors.background;
                        cr = @as(f32, @floatFromInt(colors.background.r)) / 255.0;
                        cg = @as(f32, @floatFromInt(colors.background.g)) / 255.0;
                        cb = @as(f32, @floatFromInt(colors.background.b)) / 255.0;
                    }
                    const background_changed = !cache_entry.has_bg_color or
                        cache_entry.last_bg_color.r != bg_color.r or
                        cache_entry.last_bg_color.g != bg_color.g or
                        cache_entry.last_bg_color.b != bg_color.b;

                    // atlas stale → full redraw needed (glyph UVs changed under existing pixels).
                    // resize → handled by cache recreation (pw/ph mismatch), so we never see
                    //   a stale RT from a resize here.
                    // .full dirty_level → ghostty uses this for screen switches (alt-screen
                    //   enter/exit), resize, color-change events, and app-driven scroll.
                    //   We do NOT automatically clear the whole RT for .full because scroll
                    //   frames already mark every row dirty and the per-row redraw path is
                    //   cheaper than a full CLEAR pass. We only force a full redraw when the
                    //   cache itself is invalid (resize/atlas/layout) or the background color
                    //   changed and we must repaint padding / untouched pixels.
                    //   The row map may hold entries from the previous screen (different
                    //   rowRaw keys pointing at now-reused page slots, or same rowRaw key but
                    //   the slot now holds different content on the new screen), so .full
                    //   still invalidates the row map before this frame is rendered.
                    // .true_value dirty_level → normal content update; per-row dirty gives us the
                    //   minimal set of rows to re-render.
                    const inner_w = if (pw_u > pane_pad_x) pw_u - pane_pad_x else 1;
                    const inner_h = if (ph_u > pane_pad_y) ph_u - pane_pad_y else 1;
                    const expected_cols: u16 = @intCast(@min(1000, @max(1, inner_w / @max(@as(u32, 1), cell_width_px))));
                    const expected_rows: u16 = @intCast(@min(500, @max(1, inner_h / @max(@as(u32, 1), cell_height_px))));
                    const size_mismatch = pane.cols != expected_cols or pane.rows != expected_rows;
                    const grid_changed = cache_entry.last_cols != pane.cols or cache_entry.last_rows != pane.rows;
                    const pty_active = pane.pty_wrote_this_frame;
                    if (grid_changed) {
                        cache_entry.stable_after_resize = false;
                    }
                    const settled_clean = dirty_level == .false_value and !pty_active and !atlas_stale and !cache_entry.needs_clear and !geometry_stale and !size_mismatch and !grid_changed;
                    if (dirty_level == .false_value and cache_entry.validity == .valid and settled_clean and cache_entry.stable_after_resize) {
                        // Nothing changed and the pane has already survived a clean
                        // post-reflow frame, so the cached RT is safe to reuse.
                        if (g_frames_since_drag_release < 10) {
                            std.log.info("post_release[{d}] pane={x} cached_clean (skipped render entirely)", .{ g_frames_since_drag_release, @intFromPtr(pane) });
                        }
                        return .cached_clean;
                    }
                    const unsettled = size_mismatch or grid_changed or !cache_entry.stable_after_resize;
                    const force_full = atlas_stale or cache_entry.needs_clear or geometry_stale or unsettled or background_changed;

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
                                pty_active,
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
                    // skip rows this frame, so maintaining the row map would add a second
                    // full-row scan on top of rendering. That increases frame-time variance
                    // during heavy app-driven scroll. Reserve row-map work for partial frames.
                    //
                    // force_full (atlas stale or resize) invalidates existing RT pixels, so
                    // any stored hash entry from before the atlas change is stale (the glyph
                    // UVs changed) → zero the map so no false-positive skips happen.
                    // dirty_level == .full from content updates can also invalidate the map
                    // because alt-screen switches / resize-like events may reuse rowRaw keys
                    // for different content. Clear the map and rebuild lazily on later partial
                    // frames where hash skips can actually pay off.
                    const use_row_map = g_drag_node == null and dirty_level != .full and !force_full;
                    if (!use_row_map) {
                        @memset(&cache_entry.row_map_keys, ROW_MAP_EMPTY);
                        @memset(&cache_entry.row_map_vals, 0);
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
                        if (use_row_map) &cache_entry.row_map_keys else null,
                        if (use_row_map) &cache_entry.row_map_vals else null,
                        use_row_map,
                        selection_range,
                        hovered_hyperlink,
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
                    // Cache invalidation state is now reserved for cases where the
                    // existing RT pixels are definitely stale (resize, drag-release,
                    // atlas change, background-color change). Normal PTY output and
                    // scroll frames redraw the dirty rows without forcing a CLEAR.
                    pane.pty_wrote_this_frame = false; // consumed by renderer
                    cache_entry.needs_clear = false;
                    const now_stable = !pty_active and dirty_level == .false_value and !atlas_stale and !geometry_stale and !size_mismatch and !grid_changed;
                    cache_entry.stable_after_resize = now_stable;
                    cache_entry.validity = if (cache_entry.stable_after_resize) .valid else .priming;
                    if (cache_entry.force_full_frames > 0 and !pty_active) cache_entry.force_full_frames -= 1;
                    cache_entry.last_bg_color = bg_color;
                    cache_entry.has_bg_color = true;

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
                    switch (renderPane(renderer, runtime, &app.config, app.selectionRange(leaf.pane), app.hovered_hyperlink, leaf.pane, ox, oy, pw, ph, width, height, focused, app.currentLayoutGeneration(), app.cell_width_px, app.cell_height_px, app.config.terminal_padding.horizontal(), app.config.terminal_padding.vertical())) {
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
                    switch (renderPane(renderer, runtime, &app.config, app.selectionRange(pane), app.hovered_hyperlink, pane, 0, 0, width, height, width, height, true, app.currentLayoutGeneration(), app.cell_width_px, app.cell_height_px, app.config.terminal_padding.horizontal(), app.config.terminal_padding.vertical())) {
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
                            app.selectionRange(leaf.pane),
                            app.hovered_hyperlink,
                            std.math.maxInt(usize),
                        );
                        g_phase_accum_rows_rendered += renderer.last_rows_rendered;
                        g_phase_accum_rows_skipped += renderer.last_rows_skipped;
                        g_phase_accum_cells_visited += renderer.last_cells_visited;
                        g_phase_accum_glyph_runs += renderer.last_glyph_runs;
                        g_phase_accum_bg_rects += renderer.last_bg_rects;
                        if (renderer.last_atlas_flushed) g_phase_accum_atlas_flushes += 1;
                        leaf.pane.render_dirty = .false_value;
                        leaf.pane.pty_wrote_this_frame = false;
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
                            app.selectionRange(pane),
                            app.hovered_hyperlink,
                            std.math.maxInt(usize),
                        );
                        g_phase_accum_rows_rendered += renderer.last_rows_rendered;
                        g_phase_accum_rows_skipped += renderer.last_rows_skipped;
                        g_phase_accum_cells_visited += renderer.last_cells_visited;
                        g_phase_accum_glyph_runs += renderer.last_glyph_runs;
                        g_phase_accum_bg_rects += renderer.last_bg_rects;
                        if (renderer.last_atlas_flushed) g_phase_accum_atlas_flushes += 1;
                        pane.render_dirty = .false_value;
                        pane.pty_wrote_this_frame = false;
                    }
                }
            }
        }
        offscreen_terminal_ns += std.time.nanoTimestamp() - offscreen_terminal_start_ns;

        if (app.lua) |*lua| {
            const offscreen_bar_preraster_start_ns = std.time.nanoTimestamp();
            g_widget_pre_raster_ctx = .{ .app = app, .renderer = renderer };
            defer g_widget_pre_raster_ctx = null;
            lua.withLockedState(void, preRasterizeLuaBarWidgets);
            offscreen_bar_preraster_ns += std.time.nanoTimestamp() - offscreen_bar_preraster_start_ns;
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
    var swapchain_panes_ns: i128 = 0;
    var swapchain_ui_ns: i128 = 0;
    var swapchain_glyph_ns: i128 = 0;

    // Blit each pane's cached RT into the swapchain pass.
    // For single pane without tab bar with direct render enabled, render directly instead.
    // use_direct_render was computed once above before both phases.
    const swapchain_panes_start_ns = std.time.nanoTimestamp();
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
                            pane.render_dirty == .full or pane.pty_wrote_this_frame or renderer.atlas_dirty,
                            app.selectionRange(pane),
                            app.hovered_hyperlink,
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
                        pane.pty_wrote_this_frame = false;
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
    swapchain_panes_ns += std.time.nanoTimestamp() - swapchain_panes_start_ns;

    // Draw split borders as filled 2px quads (only when >1 pane).
    // Floating panes are modal overlays, so any seam covered by a floating pane
    // is skipped here and the floating pane gets its own explicit outline below.
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
                const seam = PaneBounds{
                    .x = @as(u32, @intFromFloat(@max(0.0, x1 - border_px / 2.0))),
                    .y = leaf.bounds.y,
                    .width = @max(@as(u32, 1), @as(u32, @intFromFloat(border_px))),
                    .height = leaf.bounds.height,
                };
                if (!seamCoveredByFloating(leaves, seam)) {
                    // rect drawn at x1 - border_px/2 so it straddles the seam
                    drawBorderRect(x1 - border_px / 2.0, y0, border_px, lh, br, bg, bb, ba);
                }
            }
            // Bottom seam — same logic vertically.
            if (@as(i32, @intFromFloat(y1)) < fh) {
                const seam = PaneBounds{
                    .x = leaf.bounds.x,
                    .y = @as(u32, @intFromFloat(@max(0.0, y1 - border_px / 2.0))),
                    .width = leaf.bounds.width,
                    .height = @max(@as(u32, 1), @as(u32, @intFromFloat(border_px))),
                };
                if (!seamCoveredByFloating(leaves, seam)) {
                    drawBorderRect(x0, y1 - border_px / 2.0, lw, border_px, br, bg, bb, ba);
                }
            }
        }

        for (leaves) |leaf| {
            if (!leaf.pane.is_floating) continue;

            const is_active = leaf.pane == active;
            const x0: f32 = @floatFromInt(leaf.bounds.x);
            const y0: f32 = @floatFromInt(leaf.bounds.y);
            const lw: f32 = @floatFromInt(leaf.bounds.width);
            const lh: f32 = @floatFromInt(leaf.bounds.height);
            const br: u8 = if (is_active) 120 else 72;
            const bg: u8 = if (is_active) 150 else 90;
            const bb: u8 = if (is_active) 220 else 110;
            const ba: u8 = 255;

            drawBorderRect(x0, y0, lw, border_px, br, bg, bb, ba);
            drawBorderRect(x0, y0 + lh - border_px, lw, border_px, br, bg, bb, ba);
            drawBorderRect(x0, y0, border_px, lh, br, bg, bb, ba);
            drawBorderRect(x0 + lw - border_px, y0, border_px, lh, br, bg, bb, ba);
        }
    }

    // Draw top bar background; Lua widgets render the contents.
    const swapchain_ui_start_ns = std.time.nanoTimestamp();
    const tbh_u = app.tabBarHeight();
    const bbh_u = app.bottomBarHeight();
    resetBarCache(&g_top_bar_cache, width, 0.0, @floatFromInt(tbh_u));
    resetBarCache(&g_bottom_bar_cache, width, height - @as(f32, @floatFromInt(bbh_u)), @floatFromInt(bbh_u));
    if (g_ft_renderer) |*renderer| {
        const fw: i32 = @intFromFloat(width);
        const fh: i32 = @intFromFloat(height);
        c.sgl_defaults();
        c.sgl_viewport(0, 0, fw, fh, true);
        c.sgl_scissor_rect(0, 0, fw, fh, true);
        c.sgl_load_default_pipeline();
        c.sgl_matrix_mode_projection();
        c.sgl_load_identity();
        c.sgl_ortho(0.0, width, height, 0.0, -1.0, 1.0);

        if (app.config.debug_overlay) {
            drawDebugOverlay(app, renderer, width, height);
        }

        var layout_buf_scrollbar: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
        const scrollbar_leaves = app.computeActiveLayout(&layout_buf_scrollbar);
        for (scrollbar_leaves) |leaf| {
            if (app.scrollbarMetricsForPane(leaf.pane)) |metrics| {
                drawScrollbar(app, metrics);
            }
        }
    }

    if (g_ft_renderer) |*renderer| {
        c.sgl_defaults();
        c.sgl_viewport(0, 0, @intFromFloat(width), @intFromFloat(height), true);
        c.sgl_scissor_rect(0, 0, @intFromFloat(width), @intFromFloat(height), true);
        c.sgl_load_default_pipeline();
        c.sgl_matrix_mode_projection();
        c.sgl_load_identity();
        c.sgl_ortho(0.0, width, height, 0.0, -1.0, 1.0);

        if (app.lua) |*lua| {
            g_widget_render_ctx = .{ .app = app, .renderer = renderer, .width = width, .height = height };
            defer g_widget_render_ctx = null;
            lua.withLockedState(void, renderLuaWidgets);
        }
    }

    // Flush all queued geometry — exactly once per frame.
    c.sgl_draw();
    swapchain_ui_ns += std.time.nanoTimestamp() - swapchain_ui_start_ns;

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
    const swapchain_glyph_start_ns = std.time.nanoTimestamp();
    if (g_ft_renderer) |*renderer| {
        if (app.config.renderer_disable_swapchain_glyphs) {
            renderer.discardGlyphQuads();
        } else {
            renderer.drawGlyphQuads(width, height, false, .{ 0.0, 0.0, 0.0, 1.0 });
        }
    }
    swapchain_glyph_ns += std.time.nanoTimestamp() - swapchain_glyph_start_ns;

    const swapchain_submit_start_ns = std.time.nanoTimestamp();
    c.sg_end_pass();
    c.sg_commit();
    const after_commit_ns = std.time.nanoTimestamp();
    const swapchain_submit_ns = after_commit_ns - swapchain_submit_start_ns;
    sleepForFrameCap(app, frame_start_ns, after_commit_ns);

    if (collect_perf) {
        // ── Phase timing accumulation (logged every ~2 s) ─────────────────
        g_phase_accum_tick_ns += after_tick_ns - frame_start_ns;
        g_phase_accum_offscreen_ns += after_offscreen_ns - after_tick_ns;
        g_phase_accum_swapchain_ns += after_commit_ns - after_offscreen_ns;
        g_phase_accum_offscreen_terminal_ns += offscreen_terminal_ns;
        g_phase_accum_offscreen_bar_preraster_ns += offscreen_bar_preraster_ns;
        g_phase_accum_swapchain_panes_ns += swapchain_panes_ns;
        g_phase_accum_swapchain_ui_ns += swapchain_ui_ns;
        g_phase_accum_swapchain_glyph_ns += swapchain_glyph_ns;
        g_phase_accum_swapchain_submit_ns += swapchain_submit_ns;
        g_phase_sample_frames += 1;

        // Update per-frame last values for the debug overlay (no division needed).
        g_last_frame_tick_ms = @as(f32, @floatFromInt(after_tick_ns - frame_start_ns)) / 1_000_000.0;
        g_last_frame_offscreen_ms = @as(f32, @floatFromInt(after_offscreen_ns - after_tick_ns)) / 1_000_000.0;
        g_last_frame_swap_ms = @as(f32, @floatFromInt(after_commit_ns - after_offscreen_ns)) / 1_000_000.0;
        g_last_frame_queue_ms = @as(f32, @floatFromInt(g_frame_queue_ns)) / 1_000_000.0;
        g_last_frame_gpu_ms = @as(f32, @floatFromInt(g_frame_gpu_ns)) / 1_000_000.0;
        g_last_frame_offscreen_terminal_ms = @as(f32, @floatFromInt(offscreen_terminal_ns)) / 1_000_000.0;
        g_last_frame_offscreen_bar_preraster_ms = @as(f32, @floatFromInt(offscreen_bar_preraster_ns)) / 1_000_000.0;
        g_last_frame_swapchain_panes_ms = @as(f32, @floatFromInt(swapchain_panes_ns)) / 1_000_000.0;
        g_last_frame_swapchain_ui_ms = @as(f32, @floatFromInt(swapchain_ui_ns)) / 1_000_000.0;
        g_last_frame_swapchain_glyph_ms = @as(f32, @floatFromInt(swapchain_glyph_ns)) / 1_000_000.0;
        g_last_frame_swapchain_submit_ms = @as(f32, @floatFromInt(swapchain_submit_ns)) / 1_000_000.0;

        if (g_phase_last_log_ns == 0) g_phase_last_log_ns = frame_start_ns;
        if (frame_start_ns - g_phase_last_log_ns >= 2_000_000_000) {
            const n: f32 = @floatFromInt(@max(1, g_phase_sample_frames));
            const tick_ms = @as(f32, @floatFromInt(g_phase_accum_tick_ns)) / n / 1_000_000.0;
            const off_ms = @as(f32, @floatFromInt(g_phase_accum_offscreen_ns)) / n / 1_000_000.0;
            const swap_ms = @as(f32, @floatFromInt(g_phase_accum_swapchain_ns)) / n / 1_000_000.0;
            const off_term_ms = @as(f32, @floatFromInt(g_phase_accum_offscreen_terminal_ns)) / n / 1_000_000.0;
            const off_bar_ms = @as(f32, @floatFromInt(g_phase_accum_offscreen_bar_preraster_ns)) / n / 1_000_000.0;
            const swap_panes_ms = @as(f32, @floatFromInt(g_phase_accum_swapchain_panes_ns)) / n / 1_000_000.0;
            const swap_ui_ms = @as(f32, @floatFromInt(g_phase_accum_swapchain_ui_ns)) / n / 1_000_000.0;
            const swap_glyph_ms = @as(f32, @floatFromInt(g_phase_accum_swapchain_glyph_ns)) / n / 1_000_000.0;
            const swap_submit_ms = @as(f32, @floatFromInt(g_phase_accum_swapchain_submit_ns)) / n / 1_000_000.0;
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
                "frame phases (avg/{d:.0}f  fps={d:.1}): tick={d:.2}ms offscreen={d:.2}ms (term={d:.2}ms bars={d:.2}ms queue={d:.2}ms [p1={d:.2}ms p2={d:.2}ms] gpu={d:.2}ms) swapchain={d:.2}ms (panes={d:.2}ms ui={d:.2}ms glyph={d:.2}ms submit={d:.2}ms)  dirty={d} clean={d}  dl full={d} true={d}  atlas_stale={d} atlas_fl={d}  rows r={d} s={d}  cells={d} gruns={d} bgrects={d}  mode direct={d} cached={d}",
                .{ n, fps, tick_ms, off_ms, off_term_ms, off_bar_ms, queue_ms, pass1_ms, pass2_ms, gpu_ms, swap_ms, swap_panes_ms, swap_ui_ms, swap_glyph_ms, swap_submit_ms, dirty, clean, full_dl, true_dl, stale_f, atlas_fl, rows_rendered, rows_skipped, cells, gruns, bgrects, direct_f, cached_f },
            );
            g_phase_accum_tick_ns = 0;
            g_phase_accum_offscreen_ns = 0;
            g_phase_accum_swapchain_ns = 0;
            g_phase_accum_offscreen_terminal_ns = 0;
            g_phase_accum_offscreen_bar_preraster_ns = 0;
            g_phase_accum_swapchain_panes_ns = 0;
            g_phase_accum_swapchain_ui_ns = 0;
            g_phase_accum_swapchain_glyph_ns = 0;
            g_phase_accum_swapchain_submit_ns = 0;
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
    }

    g_renderer_ready = true;

    if (!g_gui_ready_fired) {
        g_gui_ready_fired = true;
        app.fireGuiReady();
    }

    updateWindowTitle(app.activeTitle());
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
        app.activePane() != null and app.tabBarHeight() == 0 and app.bottomBarHeight() == 0) "direct" else "cached";
    const dirty_count = g_phase_accum_dirty_frames;
    const clean_count = g_phase_accum_clean_frames;

    var lines: [13][128]u8 = undefined;
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
    const text11 = std.fmt.bufPrint(&lines[11], "off term={d:.2} bars={d:.2}", .{
        g_last_frame_offscreen_terminal_ms,
        g_last_frame_offscreen_bar_preraster_ms,
    }) catch "off detail ?";
    const text12 = std.fmt.bufPrint(&lines[12], "sw panes={d:.2} ui={d:.2} glyph={d:.2} sub={d:.2}", .{
        g_last_frame_swapchain_panes_ms,
        g_last_frame_swapchain_ui_ms,
        g_last_frame_swapchain_glyph_ms,
        g_last_frame_swapchain_submit_ms,
    }) catch "sw detail ?";
    const overlay_lines = [_][]const u8{ text0, text1, text2, text3, text4, text5, text6, text7, text8, text9, text10, text11, text12 };

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

fn rectsOverlap(a: PaneBounds, b: PaneBounds) bool {
    const a_right = a.x + a.width;
    const a_bottom = a.y + a.height;
    const b_right = b.x + b.width;
    const b_bottom = b.y + b.height;
    return a.x < b_right and a_right > b.x and a.y < b_bottom and a_bottom > b.y;
}

fn seamCoveredByFloating(leaves: []const LayoutLeaf, seam: PaneBounds) bool {
    for (leaves) |leaf| {
        if (!leaf.pane.is_floating) continue;
        if (rectsOverlap(leaf.bounds, seam)) return true;
    }
    return false;
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
    if (g_rect_pip.id != 0) {
        c.sgl_destroy_pipeline(g_rect_pip);
        g_rect_pip = .{ .id = 0 };
    }
    c.sgl_shutdown();
    c.sg_shutdown();
}

fn applyWindowChrome(app: *App) bool {
    if (builtin.os.tag != .windows) return false;

    const hwnd_raw = c.sapp_win32_get_hwnd() orelse return false;
    const hwnd: win32.HWND = @ptrCast(@constCast(hwnd_raw));

    applyNativeWindowColors(hwnd, app);

    if (app.config.window_titlebar_show) return true;

    if (g_subclassed_hwnd == null) {
        const new_proc: win32.WNDPROC = &windowProc;
        const new_proc_raw: WinLongPtr = @bitCast(@intFromPtr(new_proc));
        const prev_proc_raw = win32.SetWindowLongPtrW(hwnd, win32.GWLP_WNDPROC, new_proc_raw);
        if (prev_proc_raw == 0) return false;
        g_prev_wnd_proc = prev_proc_raw;
        g_subclassed_hwnd = hwnd;
    }
    var style = win32.GetWindowLongPtrW(hwnd, win32.GWL_STYLE);
    style &= ~@as(WinLongPtr, @intCast(win32.WS_CAPTION));
    style |= @as(WinLongPtr, @intCast(win32.WS_THICKFRAME));
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
    extendDwmFrame(hwnd);
    return true;
}

fn applyNativeWindowColors(hwnd: win32.HWND, app: *App) void {
    if (builtin.os.tag != .windows) return;

    const dark_mode: i32 = 1;
    _ = win32.DwmSetWindowAttribute(
        hwnd,
        win32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(i32),
    );

    const caption_color: u32 = @as(u32, app.config.top_bar_bg.r) |
        (@as(u32, app.config.top_bar_bg.g) << 8) |
        (@as(u32, app.config.top_bar_bg.b) << 16);
    _ = win32.DwmSetWindowAttribute(
        hwnd,
        win32.DWMWA_CAPTION_COLOR,
        @ptrCast(&caption_color),
        @sizeOf(u32),
    );

    const text_color: u32 = 0x00FFFFFF;
    _ = win32.DwmSetWindowAttribute(
        hwnd,
        win32.DWMWA_TEXT_COLOR,
        @ptrCast(&text_color),
        @sizeOf(u32),
    );
}

fn extendDwmFrame(hwnd: win32.HWND) void {
    if (builtin.os.tag != .windows) return;

    const margins = win32.MARGINS{
        .cxLeftWidth = 1,
        .cxRightWidth = 1,
        .cyTopHeight = 0,
        .cyBottomHeight = 1,
    };
    _ = win32.DwmExtendFrameIntoClientArea(hwnd, &margins);

    const no_border: u32 = win32.DWMWA_COLOR_NONE;
    _ = win32.DwmSetWindowAttribute(
        hwnd,
        win32.DWMWA_BORDER_COLOR,
        @ptrCast(&no_border),
        @sizeOf(u32),
    );
}

fn borderHitTest(local_x: i32, local_y: i32, width: i32, height: i32) usize {
    if (builtin.os.tag != .windows) return win32.HTCLIENT;

    const border = windowFrameBorder();
    const border_x = border.x;
    const border_y = border.y;
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

fn windowFrameBorder() struct { x: i32, y: i32 } {
    if (builtin.os.tag != .windows) return .{ .x = 0, .y = 0 };

    return .{
        .x = @max(1, win32.GetSystemMetrics(win32.SM_CXSIZEFRAME) + win32.GetSystemMetrics(win32.SM_CXPADDEDBORDER)),
        .y = @max(1, win32.GetSystemMetrics(win32.SM_CYSIZEFRAME) + win32.GetSystemMetrics(win32.SM_CXPADDEDBORDER)),
    };
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

fn adjustMaximizedClientRect(mmi: *win32.MINMAXINFO, hwnd: win32.HWND) void {
    if (builtin.os.tag != .windows) return;

    const monitor = win32.MonitorFromWindow(hwnd, win32.MONITOR_DEFAULTTONEAREST) orelse return;
    var mi = std.mem.zeroes(win32.MONITORINFO);
    mi.cbSize = @sizeOf(win32.MONITORINFO);
    if (win32.GetMonitorInfoW(monitor, &mi) == 0) return;

    const work = mi.rcWork;
    const monitor_rect = mi.rcMonitor;
    mmi.ptMaxPosition.x = work.left - monitor_rect.left;
    mmi.ptMaxPosition.y = work.top - monitor_rect.top;
    mmi.ptMaxSize.x = work.right - work.left;
    mmi.ptMaxSize.y = work.bottom - work.top;
}

fn windowProc(hWnd: win32.HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.winapi) win32.LRESULT {
    switch (Msg) {
        win32.WM_NCCALCSIZE => {
            if (wParam != 0) return 0;
        },
        win32.WM_GETMINMAXINFO => {
            const mmi: *win32.MINMAXINFO = @ptrFromInt(@as(usize, @intCast(lParam)));
            adjustMaximizedClientRect(mmi, hWnd);
            return 0;
        },
        win32.WM_DWMCOMPOSITIONCHANGED => {
            extendDwmFrame(hWnd);
        },
        win32.WM_NCHITTEST => {
            var rect: win32.RECT = undefined;
            if (win32.GetWindowRect(hWnd, &rect) != 0) {
                const local_x = getXLParam(lParam) - rect.left;
                const local_y = getYLParam(lParam) - rect.top;
                const width = rect.right - rect.left;
                const height = rect.bottom - rect.top;
                if (g_app) |app| {
                    if (!app.config.window_titlebar_show) {
                        const border = windowFrameBorder();
                        const top_bar_h: i32 = @intCast(app.tabBarHeight());
                        if (top_bar_h > 0 and local_y >= border.y and local_y < border.y + top_bar_h) {
                            const hit = topBarHitTest(app, @floatFromInt(local_x), @floatFromInt(local_y - border.y), @floatFromInt(width));
                            if (hit.inBar()) return @as(win32.LRESULT, @intCast(win32.HTCLIENT));
                        }
                    }
                }
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
            c.SAPP_EVENTTYPE_KEY_UP => handleKeyUp(app, event),
            c.SAPP_EVENTTYPE_CHAR => handleChar(app, event),
            c.SAPP_EVENTTYPE_MOUSE_DOWN => handleMouseButton(app, event, .press),
            c.SAPP_EVENTTYPE_MOUSE_UP => handleMouseButton(app, event, .release),
            c.SAPP_EVENTTYPE_MOUSE_MOVE => handleMouseMove(app, event),
            c.SAPP_EVENTTYPE_MOUSE_SCROLL => handleScroll(app, event),
            c.SAPP_EVENTTYPE_RESIZED => handleResize(app, event),
            c.SAPP_EVENTTYPE_ICONIFIED => @atomicStore(bool, &g_window_iconified, true, .release),
            c.SAPP_EVENTTYPE_RESTORED => {
                @atomicStore(bool, &g_window_iconified, false, .release);
                @atomicStore(bool, &g_restore_pending, true, .release);
                g_ignore_resize_frames = 2;
            },
            c.SAPP_EVENTTYPE_FOCUSED => _ = app.enqueueMouse(.{ .focus = true }),
            c.SAPP_EVENTTYPE_UNFOCUSED => _ = app.enqueueMouse(.{ .focus = false }),
            c.SAPP_EVENTTYPE_QUIT_REQUESTED => c.sapp_request_quit(),
            else => {},
        }
        return;
    }

    switch (event.type) {
        c.SAPP_EVENTTYPE_KEY_DOWN => handleKeyDown(app, event),
        c.SAPP_EVENTTYPE_KEY_UP => handleKeyUp(app, event),
        c.SAPP_EVENTTYPE_CHAR => handleChar(app, event),
        c.SAPP_EVENTTYPE_MOUSE_DOWN => handleMouseButton(app, event, .press),
        c.SAPP_EVENTTYPE_MOUSE_UP => handleMouseButton(app, event, .release),
        c.SAPP_EVENTTYPE_MOUSE_MOVE => handleMouseMove(app, event),
        c.SAPP_EVENTTYPE_MOUSE_SCROLL => handleScroll(app, event),
        c.SAPP_EVENTTYPE_RESIZED => handleResize(app, event),
        c.SAPP_EVENTTYPE_ICONIFIED => @atomicStore(bool, &g_window_iconified, true, .release),
        c.SAPP_EVENTTYPE_RESTORED => {
            @atomicStore(bool, &g_window_iconified, false, .release);
            @atomicStore(bool, &g_restore_pending, true, .release);
            g_ignore_resize_frames = 2;
        },
        c.SAPP_EVENTTYPE_FOCUSED => _ = app.enqueueMouse(.{ .focus = true }),
        c.SAPP_EVENTTYPE_UNFOCUSED => _ = app.enqueueMouse(.{ .focus = false }),
        c.SAPP_EVENTTYPE_QUIT_REQUESTED => c.sapp_request_quit(),
        else => {},
    }
}

fn handleKeyDown(app: *App, event: c.sapp_event) void {
    const mods = ghosttyMods(event.modifiers);
    const key = mapKey(event.key_code);

    if (shouldPasteOnKeyDown(event.key_code, mods)) {
        _ = app.enqueueMouse(.paste_clipboard);
        return;
    }

    if (key != .unidentified and handleClipboardShortcut(app, key, mods)) {
        c.sapp_consume_event();
        return;
    }

    // Give Lua a chance to consume this key before the terminal sees it.
    // fireOnKey calls LuaJIT (not the ghostty DLL) so it is safe on the
    // event thread.  If Lua consumes the key we stop here — no DLL call needed.
    if (key != .unidentified) {
        const key_name = @tagName(key);
        if (app.fireOnKey(key_name, mods)) {
            g_swallow_char_pending = 4;
            g_swallow_char_until_frame = event.frame_count + 1;
            c.sapp_consume_event();
            return;
        }

        if (handleScrollbackKey(app, key, mods)) {
            g_swallow_char_pending = 4;
            g_swallow_char_until_frame = event.frame_count + 1;
            c.sapp_consume_event();
            return;
        }
    }

    // Defer the actual DLL call (encodeKey) to the frame thread via the queue.
    // This prevents a data race with syncKeyEncoder / syncMouseEncoder which
    // run on the frame thread inside tickPanes / resizeAllPanes.
    if (key != .unidentified) _ = app.enqueueKey(key, mods, if (event.key_repeat) .repeat else .press);
}

fn handleKeyUp(app: *App, event: c.sapp_event) void {
    const mods = ghosttyMods(event.modifiers);
    const key = mapKey(event.key_code);
    if (key != .unidentified) _ = app.enqueueKey(key, mods, .release);
}

fn handleChar(app: *App, event: c.sapp_event) void {
    if (g_swallow_char_pending > 0) {
        if (event.frame_count <= g_swallow_char_until_frame) {
            g_swallow_char_pending -= 1;
            return;
        }
        g_swallow_char_pending = 0;
    }

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

    if (g_block_all_mouse_until_up) {
        c.sapp_consume_event();
        if (action == .release and event.mouse_button == c.SAPP_MOUSEBUTTON_LEFT) {
            g_block_all_mouse_until_up = false;
            g_block_left_mouse_until_up = false;
            g_skip_mouse_release = null;
            g_skip_mouse_move_frames = 0;
            g_mouse_button_down = null;
        }
        return;
    }

    if (g_block_left_mouse_until_up and event.mouse_button == c.SAPP_MOUSEBUTTON_LEFT) {
        c.sapp_consume_event();
        if (action == .release) {
            g_block_left_mouse_until_up = false;
            g_skip_mouse_release = null;
            g_skip_mouse_move_frames = 0;
            g_mouse_button_down = null;
        }
        return;
    }

    if (action == .release and button != null and g_skip_mouse_release == button.?) {
        g_skip_mouse_release = null;
        if (event.mouse_button == c.SAPP_MOUSEBUTTON_LEFT) g_mouse_button_down = null;
        return;
    }

    // On left-button release always end any active drag.
    if (action == .release and event.mouse_button == c.SAPP_MOUSEBUTTON_LEFT) {
        if (g_scrollbar_drag_pane != null) {
            g_scrollbar_drag_pane = null;
            g_scrollbar_drag_metrics = null;
            g_scrollbar_drag_grab_y = 0.0;
        }
        if (g_selection_pointer_active) {
            g_selection_pointer_active = false;
            g_selection_pointer_pane = null;
            _ = app.enqueueMouse(.selection_end);
        }
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

    const bar_hit = updateBarHover(app, event.mouse_x, event.mouse_y, c.sapp_widthf());
    if (bar_hit.inBar()) {
        if (action == .press and event.mouse_button == c.SAPP_MOUSEBUTTON_LEFT) {
            if (bar_hit.node_id != null and bar_hit.tab_index == null) {
                if (bar_hit.surface == .top) {
                    app.emitLuaBuiltInEvent("topbar:click", .{ .topbar_node = .{ .id = bar_hit.node_id.? } });
                } else if (bar_hit.surface == .bottom) {
                    app.emitLuaBuiltInEvent("bottombar:click", .{ .bottombar_node = .{ .id = bar_hit.node_id.? } });
                }
                return;
            }
            if (bar_hit.tab_index) |ti| {
                if (bar_hit.surface == .top and bar_hit.node_id != null and bar_hit.close_tab_index == null) {
                    app.emitLuaBuiltInEvent("topbar:click", .{ .topbar_node = .{ .id = bar_hit.node_id.? } });
                } else if (bar_hit.surface == .bottom and bar_hit.node_id != null) {
                    app.emitLuaBuiltInEvent("bottombar:click", .{ .bottombar_node = .{ .id = bar_hit.node_id.? } });
                } else if (bar_hit.close_tab_index != null and bar_hit.close_tab_index.? == ti) {
                    _ = app.enqueueMouse(.{ .close_tab_at = ti });
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

    if (action == .press and event.mouse_button == c.SAPP_MOUSEBUTTON_RIGHT) {
        if (app.hasSelection()) {
            _ = app.enqueueMouse(.copy_selection);
            return;
        }
    }

    // On left-button press, check for a divider hit before forwarding to the terminal.
    if (action == .press and event.mouse_button == c.SAPP_MOUSEBUTTON_LEFT) {
        const mods = ghosttyMods(event.modifiers);
        if (app.hitTestPane(event.mouse_x, event.mouse_y)) |_| {
            const wants_shift_click_link = app.config.hyperlinks.enabled and
                (!app.config.hyperlinks.shift_click_only or (mods & ghostty.Mods.shift) != 0);
            if (wants_shift_click_link) {
                if (app.hoveredHyperlinkAtPointer()) |hovered_link| {
                    c.sapp_consume_event();
                    g_block_all_mouse_until_up = true;
                    g_block_left_mouse_until_up = true;
                    g_skip_mouse_release = .left;
                    g_skip_mouse_move_frames = 8;
                    g_mouse_button_down = null;
                    _ = app.enqueueMouse(.{ .open_hyperlink = .{ .pane = hovered_link.pane, .point = hovered_link.point } });
                    return;
                }
            }
        }

        if (app.hitTestScrollbar(event.mouse_x, event.mouse_y)) |metrics| {
            g_scrollbar_hover_pane = metrics.pane;
            if (scrollbarHitThumb(metrics, event.mouse_x, event.mouse_y)) {
                g_scrollbar_drag_pane = metrics.pane;
                g_scrollbar_drag_metrics = metrics;
                g_scrollbar_drag_grab_y = event.mouse_y - metrics.thumb_y;
            } else {
                if (app.config.scrollbar.jump_to_click) {
                    const jump_grab_y = metrics.thumb_h * 0.5;
                    const target_row = scrollbarTrackRowForPosition(metrics, event.mouse_y, jump_grab_y);
                    _ = app.enqueueMouse(.{ .scroll_pane_target = .{
                        .pane = metrics.pane,
                        .top_row = target_row,
                    } });
                    g_scrollbar_drag_pane = metrics.pane;
                    g_scrollbar_drag_metrics = metrics;
                    g_scrollbar_drag_grab_y = jump_grab_y;
                } else {
                    const visible_rows: isize = @max(@as(isize, 1), std.math.cast(isize, metrics.len) orelse std.math.maxInt(isize));
                    const page_delta: isize = if (event.mouse_y < metrics.thumb_y) -visible_rows else visible_rows;
                    _ = app.enqueueMouse(.{ .scroll_pane_delta = .{
                        .pane = metrics.pane,
                        .delta = page_delta,
                    } });
                }
            }
            return;
        }

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

        if (app.hitTestPane(event.mouse_x, event.mouse_y)) |hit| {
            const wants_selection = selectionModifierActive(event.modifiers) or hit.pane.last_mouse_tracking == 0;
            if (wants_selection) {
                const extend = (ghosttyMods(event.modifiers) & ghostty.Mods.shift) != 0;
                const point = app.cellPointFromPaneLocal(hit.pane, hit.x, hit.y);

                // Detect double/triple click: same position within 500 ms.
                const now_ms: u64 = @intCast(@divFloor(std.time.nanoTimestamp(), std.time.ns_per_ms));
                const dt_ms = now_ms -| g_last_click_time_ms;
                const dx = event.mouse_x - g_last_click_x;
                const dy = event.mouse_y - g_last_click_y;
                const same_spot = dx * dx + dy * dy < 16.0; // within ~4 px radius
                if (dt_ms < 500 and same_spot) {
                    g_click_count += 1;
                } else {
                    g_click_count = 1;
                }
                g_last_click_time_ms = now_ms;
                g_last_click_x = event.mouse_x;
                g_last_click_y = event.mouse_y;

                g_selection_pointer_active = true;
                g_selection_pointer_pane = hit.pane;
                if (g_click_count >= 3) {
                    _ = app.enqueueMouse(.{ .selection_begin_line = .{
                        .pane = hit.pane,
                        .point = point,
                    } });
                } else if (g_click_count == 2) {
                    _ = app.enqueueMouse(.{ .selection_begin_word = .{
                        .pane = hit.pane,
                        .point = point,
                    } });
                } else {
                    _ = app.enqueueMouse(.{ .selection_begin = .{
                        .pane = hit.pane,
                        .point = point,
                        .extend = extend,
                    } });
                }
                return;
            }
        }

        if (app.hasSelection()) {
            _ = app.enqueueMouse(.clear_selection);
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
    if (g_block_all_mouse_until_up) {
        c.sapp_consume_event();
        return;
    }

    if (g_block_left_mouse_until_up) {
        c.sapp_consume_event();
        return;
    }

    if (g_skip_mouse_move_frames > 0) {
        g_skip_mouse_move_frames -= 1;
        return;
    }

    if (g_scrollbar_drag_pane) |pane| {
        const metrics = if (app.scrollbarMetricsForPane(pane)) |m| m else blk: {
            g_scrollbar_drag_pane = null;
            g_scrollbar_drag_metrics = null;
            g_scrollbar_drag_grab_y = 0.0;
            g_hover_hyperlink = false;
            break :blk null;
        };
        if (metrics) |scroll_metrics| {
            g_scrollbar_drag_metrics = scroll_metrics;
            g_scrollbar_hover_pane = pane;
            const target_row = scrollbarTrackRowForPosition(scroll_metrics, event.mouse_y, g_scrollbar_drag_grab_y);
            _ = app.enqueueMouse(.{ .scroll_pane_target = .{
                .pane = pane,
                .top_row = target_row,
            } });
            if (builtin.os.tag == .windows) {
                _ = win32.SetCursor(win32.LoadCursorW(null, win32.IDC_ARROW));
            }
            return;
        }
    }

    if (g_scrollbar_drag_metrics) |metrics| {
        g_scrollbar_hover_pane = metrics.pane;
    }

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

    const bar_hit = updateBarHover(app, event.mouse_x, event.mouse_y, c.sapp_widthf());
    if (bar_hit.inBar()) {
        g_scrollbar_hover_pane = null;
        g_hover_hyperlink = false;
        // Restore default cursor when in a bar.
        setTextSelectionCursor(.arrow);
        return;
    }

    if (app.hitTestScrollbar(event.mouse_x, event.mouse_y)) |scrollbar_hit| {
        g_scrollbar_hover_pane = scrollbar_hit.pane;
        g_hover_hyperlink = false;
        if (builtin.os.tag == .windows) setTextSelectionCursor(.arrow);
        return;
    }
    g_scrollbar_hover_pane = null;

    // Check if hovering over a split divider to show resize cursor.
    if (builtin.os.tag == .windows) {
        if (app.hitTestDividerAt(event.mouse_x, event.mouse_y, 6.0)) |hit| {
            const cursor_id: usize = switch (hit.node.direction) {
                .vertical => win32.IDC_SIZEWE,
                .horizontal => win32.IDC_SIZENS,
            };
            _ = win32.SetCursor(win32.LoadCursorW(null, cursor_id));
        } else {
            if (app.hitTestPane(event.mouse_x, event.mouse_y)) |hit| {
                const hover_link = hyperlinkHoverActive(app, event.modifiers);
                g_hover_hyperlink = hover_link;
                const wants_text_cursor = g_selection_pointer_active or selectionModifierActive(event.modifiers) or hit.pane.last_mouse_tracking == 0;
                setTextSelectionCursor(if (hover_link) .hand else if (wants_text_cursor) .ibeam else .arrow);
            } else {
                g_hover_hyperlink = false;
                setTextSelectionCursor(.arrow);
            }
        }
    }

    if (g_selection_pointer_active) {
        if (g_selection_pointer_pane) |pane| {
            if (app.cellPointInPane(pane, event.mouse_x, event.mouse_y)) |point| {
                _ = app.enqueueMouse(.{ .selection_update = .{ .pane = pane, .point = point } });
                return;
            }
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
    if (g_block_all_mouse_until_up) {
        c.sapp_consume_event();
        return;
    }

    if (topBarHitTest(app, event.mouse_x, event.mouse_y, c.sapp_widthf()).inBar()) return;
    if (bottomBarHitTest(app, event.mouse_x, event.mouse_y, c.sapp_widthf()).inBar()) return;
    if (g_scrollbar_drag_pane != null) return;
    if (app.hitTestScrollbar(event.mouse_x, event.mouse_y)) |_| {
        _ = app.enqueueMouse(.{ .scroll = .{
            .x = event.mouse_x,
            .y = event.mouse_y,
            .raw_delta = -event.scroll_y,
            .mods = ghosttyMods(event.modifiers),
        } });
        return;
    }
    _ = app.enqueueMouse(.{ .scroll = .{
        .x = event.mouse_x,
        .y = event.mouse_y,
        .raw_delta = -event.scroll_y,
        .mods = ghosttyMods(event.modifiers),
    } });
}

fn handleResize(app: *App, event: c.sapp_event) void {
    if (@atomicLoad(bool, &g_window_iconified, .acquire)) return;
    if (g_ignore_resize_frames > 0 and (event.framebuffer_width < 256 or event.framebuffer_height < 128)) {
        return;
    }
    var fb_width = event.framebuffer_width;
    var fb_height = event.framebuffer_height;

    if (builtin.os.tag == .windows) {
        const hwnd_raw = c.sapp_win32_get_hwnd() orelse return;
        const hwnd: win32.HWND = @ptrCast(@constCast(hwnd_raw));
        if (win32.IsIconic(hwnd) != 0) return;

        if (fb_width <= 0 or fb_height <= 0 or fb_width < 64 or fb_height < 64) {
            var client_rect: win32.RECT = undefined;
            if (win32.GetClientRect(hwnd, &client_rect) != 0) {
                const client_w = client_rect.right - client_rect.left;
                const client_h = client_rect.bottom - client_rect.top;
                if (client_w > 0 and client_h > 0) {
                    fb_width = client_w;
                    fb_height = client_h;
                }
            }
        }
    }

    if (fb_width <= 0 or fb_height <= 0) return;
    const pixel_size = windowSizeToPixels(@floatFromInt(fb_width), @floatFromInt(fb_height));
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
        c.SAPP_KEYCODE_LEFT_SHIFT => .shift_left,
        c.SAPP_KEYCODE_RIGHT_SHIFT => .shift_right,
        c.SAPP_KEYCODE_LEFT_CONTROL => .control_left,
        c.SAPP_KEYCODE_RIGHT_CONTROL => .control_right,
        c.SAPP_KEYCODE_LEFT_ALT => .alt_left,
        c.SAPP_KEYCODE_RIGHT_ALT => .alt_right,
        c.SAPP_KEYCODE_LEFT_SUPER => .meta_left,
        c.SAPP_KEYCODE_RIGHT_SUPER => .meta_right,
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

fn handleClipboardShortcut(app: *App, key: ghostty.Key, mods: u32) bool {
    const primary = if (builtin.os.tag == .macos) ghostty.Mods.super else ghostty.Mods.ctrl;
    if ((mods & primary) == 0) return false;
    if ((mods & (if (builtin.os.tag == .macos) ghostty.Mods.ctrl else ghostty.Mods.super)) != 0) return false;

    switch (key) {
        .c => {
            if (app.hasSelection()) {
                _ = app.enqueueMouse(.copy_selection);
                return true;
            }
        },
        else => {},
    }
    return false;
}

fn handleScrollbackKey(app: *App, key: ghostty.Key, mods: u32) bool {
    switch (key) {
        .page_up => {
            if (mods == (ghostty.Mods.alt | ghostty.Mods.shift)) {
                std.log.info("scrollback key: alt+shift+page_up", .{});
                _ = app.enqueueMouse(.{ .scroll_active_page = -1 });
                return true;
            }
        },
        .page_down => {
            if (mods == (ghostty.Mods.alt | ghostty.Mods.shift)) {
                std.log.info("scrollback key: alt+shift+page_down", .{});
                _ = app.enqueueMouse(.{ .scroll_active_page = 1 });
                return true;
            }
        },
        .home => {
            if (mods == (ghostty.Mods.ctrl | ghostty.Mods.shift)) {
                std.log.info("scrollback key: ctrl+shift+home", .{});
                _ = app.enqueueMouse(.scroll_active_top);
                return true;
            }
        },
        .end => {
            if (mods == (ghostty.Mods.ctrl | ghostty.Mods.shift)) {
                std.log.info("scrollback key: ctrl+shift+end", .{});
                _ = app.enqueueMouse(.scroll_active_bottom);
                return true;
            }
        },
        else => {},
    }
    return false;
}

fn shouldPasteOnKeyDown(key_code: c.sapp_keycode, mods: u32) bool {
    const only_shift = (mods & ghostty.Mods.shift) != 0 and (mods & (ghostty.Mods.ctrl | ghostty.Mods.alt | ghostty.Mods.super)) == ghostty.Mods.shift;
    if (only_shift and key_code == c.SAPP_KEYCODE_INSERT) return true;
    if (only_shift and key_code == c.SAPP_KEYCODE_KP_0) return true;

    const primary = if (builtin.os.tag == .macos) ghostty.Mods.super else ghostty.Mods.ctrl;
    const required = primary | ghostty.Mods.shift;
    if ((mods & required) != required) return false;
    if ((mods & ~(ghostty.Mods.shift | ghostty.Mods.ctrl | ghostty.Mods.alt | ghostty.Mods.super)) != 0) return false;
    if (builtin.os.tag == .macos) {
        if ((mods & (ghostty.Mods.ctrl | ghostty.Mods.alt)) != 0) return false;
    } else {
        if ((mods & (ghostty.Mods.alt | ghostty.Mods.super)) != 0) return false;
    }
    return key_code == c.SAPP_KEYCODE_V;
}

fn selectionModifierActive(modifiers: u32) bool {
    const mods = ghosttyMods(modifiers);
    const primary = if (builtin.os.tag == .macos) ghostty.Mods.super else ghostty.Mods.ctrl;
    return (mods & primary) != 0;
}

fn hyperlinkHoverActive(app: *App, modifiers: u32) bool {
    _ = modifiers;
    if (!app.config.hyperlinks.enabled) return false;
    return app.hovered_hyperlink != null;
}

const SelectionCursor = enum {
    arrow,
    ibeam,
    hand,
};

fn setTextSelectionCursor(cursor: SelectionCursor) void {
    if (builtin.os.tag != .windows) return;
    const cursor_id: usize = switch (cursor) {
        .arrow => win32.IDC_ARROW,
        .ibeam => win32.IDC_IBEAM,
        .hand => 32649,
    };
    _ = win32.SetCursor(win32.LoadCursorW(null, cursor_id));
}

fn titleCString(text: []const u8) [*:0]const u8 {
    const len = @min(text.len, g_title_buf.len - 1);
    @memset(g_title_buf[0..], 0);
    @memcpy(g_title_buf[0..len], text[0..len]);
    g_title_buf[len] = 0;
    return @ptrCast(&g_title_buf);
}

fn updateWindowTitle(text: []const u8) void {
    const len = @min(text.len, g_last_window_title.len - 1);
    if (std.mem.eql(u8, g_last_window_title[0..len], text) and g_last_window_title[len] == 0) return;
    @memset(g_last_window_title[0..], 0);
    @memcpy(g_last_window_title[0..len], text[0..len]);
    g_last_window_title[len] = 0;
    c.sapp_set_window_title(titleCString(text));
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
    if (g_rect_pip.id != 0) {
        c.sgl_load_pipeline(g_rect_pip);
    }
    c.sgl_begin_quads();
    c.sgl_c4f(rf, gf, bf, af);
    c.sgl_v2f(x, y);
    c.sgl_v2f(x + w, y);
    c.sgl_v2f(x + w, y + h);
    c.sgl_v2f(x, y + h);
    c.sgl_end();
    c.sgl_load_default_pipeline();
}
