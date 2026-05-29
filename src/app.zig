const std = @import("std");
const c = @import("sokol_c");
const builtin = @import("builtin");
const command_mod = @import("command.zig");
const command_ipc = @import("command_ipc.zig");
const libc = if (builtin.os.tag == .windows) void else @cImport({
    @cInclude("stdlib.h");
});
const Config = @import("config.zig").Config;
const fastmem = @import("fastmem.zig");
const Backend = @import("render/backend.zig").Backend;
const FrameSnapshot = @import("render/debug_backend.zig").FrameSnapshot;
const build_options = @import("build_options");
const lua_mod = @import("lua_bridge.zig");
const LuaRuntime = lua_mod.Runtime;
const AppCallbacks = lua_mod.AppCallbacks;
const SidebarLayout = lua_mod.SidebarLayout;
const TopBarLayout = lua_mod.BottomBarLayout;
const BottomBarLayout = lua_mod.BottomBarLayout;
const HtpQueryResult = lua_mod.HtpQueryResult;
const OperationCallbackPayload = lua_mod.OperationCallbackPayload;
const LUA_NOREF: c_int = -1;
const GhosttyRuntime = @import("term/ghostty.zig").Runtime;
const ghostty = @import("term/ghostty.zig");
extern fn hollow_decode_png(
    userdata: ?*anyopaque,
    allocator: ?*const ghostty.Allocator,
    data: [*]const u8,
    data_len: usize,
    out: *ghostty.SysImage,
) callconv(.c) bool;
const mux_mod = @import("mux.zig");
const Mux = mux_mod.Mux;
const Workspace = mux_mod.Workspace;
const Tab = mux_mod.Tab;
const SplitDirection = mux_mod.SplitDirection;
const FocusDirection = mux_mod.FocusDirection;
const LayoutLeaf = mux_mod.LayoutLeaf;
const PaneBounds = mux_mod.PaneBounds;
const SplitNode = mux_mod.SplitNode;
const DividerHit = mux_mod.DividerHit;
const layoutSplitTree = mux_mod.layoutSplitTree;
const hitTestDivider = mux_mod.hitTestDivider;
const nodeIsInTree = mux_mod.nodeIsInTree;
const MAX_LAYOUT_LEAVES = mux_mod.MAX_LAYOUT_LEAVES;
const Pane = @import("pane.zig").Pane;
const LaunchCommand = @import("pty/launch_command.zig").LaunchCommand;
const platform = @import("platform.zig");
const debug_timing = @import("render/debug_timing.zig");
const bar = @import("ui/bar.zig");
const selection = @import("selection.zig");

const embedded_base_config: []const u8 = build_options.embedded_base_config;
threadlocal var g_prefixed_window_title_buf: [256]u8 = undefined;

const win32_env = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) i32;
} else struct {};

const SplitCommandMode = enum {
    send,
    spawn,
};

extern fn sapp_set_window_title(title: [*:0]const u8) void;

const CLIPBOARD_EVENT_MAX = 8192;
const HTP_OSC_PREFIX = "\x1b]1337;Hollow;";
const HTP_ST = "\x1b\\";
const HTP_MAX_CHUNK_PAYLOAD = 3072;

const BarSurface = enum {
    topbar,
    bottombar,
};

const CopyModeMoveKind = enum {
    left,
    right,
    up,
    down,
    page_up,
    page_down,
    line_start,
    line_end,
    top,
    bottom,
};

const PromptJumpDir = enum {
    prev,
    next,
};

const PromptJumpSource = union(enum) {
    live: struct {
        runtime: *GhosttyRuntime,
        terminal: ?*anyopaque,
    },
    copy_mode: []const CopyModeLine,
};

const CopyModePoint = struct {
    row: usize = 0,
    col: usize = 0,
};

const copy_mode_default_style_color = ghostty.StyleColor{ .tag = .none, .value = .{ .palette = 0 } };

const CopyModeCell = struct {
    text: []u8 = &.{},
    fg: ghostty.ColorRgb = .{ .r = 0, .g = 0, .b = 0 },
    bg: ?ghostty.ColorRgb = null,
    fg_style: ghostty.StyleColor = copy_mode_default_style_color,
    bg_style: ghostty.StyleColor = copy_mode_default_style_color,
    face_idx: u8 = 0,
};

const CopyModeLine = struct {
    text: []u8 = &.{},
    col_offsets: []u32 = &.{},
    cells: []CopyModeCell = &.{},
    cols: usize = 0,
    is_prompt: bool = false,
};

const CopyModeMatch = struct {
    row: usize,
    start_col: usize,
    end_col: usize,
};

pub const CopyModeSnapshotLine = struct {
    text: []const u8,
    cells: []const CopyModeCell,
    cols: usize,
};

pub const SearchHighlight = struct {
    row: usize,
    start_col: usize,
    end_col: usize,
    active: bool = false,
};

fn countUtf8Codepoints(text: []const u8) usize {
    var i: usize = 0;
    var count: usize = 0;
    while (i < text.len) {
        const b = text[i];
        const step: usize = if (b < 0x80) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
        if (i + step > text.len) break;
        i += step;
        count += 1;
    }
    return count;
}

fn copyModeRowIndexInViewport(target_row: usize, visible_top: usize, visible_rows: usize) ?usize {
    if (target_row < visible_top) return null;
    const row_index = target_row - visible_top;
    if (row_index >= visible_rows) return null;
    return row_index;
}

fn historySelectionRangeInViewport(history_range: selection.Range, visible_top: usize, visible_rows: usize) ?selection.Range {
    if (visible_rows == 0) return null;
    const visible_bottom = visible_top + visible_rows;
    if (history_range.start.row >= visible_bottom or history_range.end.row < visible_top) return null;

    const max_visible_row = visible_rows - 1;
    return .{
        .start = .{
            .row = if (history_range.start.row < visible_top) 0 else history_range.start.row - visible_top,
            .col = if (history_range.start.row < visible_top) 0 else history_range.start.col,
        },
        .end = .{
            .row = if (history_range.end.row >= visible_bottom) max_visible_row else history_range.end.row - visible_top,
            .col = if (history_range.end.row >= visible_bottom) std.math.maxInt(usize) else history_range.end.col,
        },
    };
}

fn viewportIteratorRowIndex(visual_row: usize, visible_rows: usize) ?usize {
    if (visual_row >= visible_rows) return null;
    if (builtin.os.tag == .linux and visible_rows > 0) {
        return (visible_rows - 1) - visual_row;
    }
    return visual_row;
}

fn snapshotHash(snapshot: *const FrameSnapshot, render_mode: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(render_mode);
    hasher.update(std.mem.asBytes(&snapshot.rows));
    hasher.update(std.mem.asBytes(&snapshot.cols));
    const dirty = @intFromEnum(snapshot.dirty);
    hasher.update(std.mem.asBytes(&dirty));
    hasher.update(snapshot.title);
    var line_idx: usize = 0;
    while (line_idx < snapshot.visible_line_count and line_idx < snapshot.lines.len) : (line_idx += 1) {
        hasher.update(snapshot.lines[line_idx][0..snapshot.line_lens[line_idx]]);
        hasher.update("\n");
    }
    return hasher.final();
}

fn titleCString(text: []const u8) [256:0]u8 {
    const max_len = 255;
    var buf: [max_len + 1:0]u8 = [_:0]u8{0} ** (max_len + 1);
    const trimmed = if (text.len > max_len) text[0..max_len] else text;
    fastmem.copy(u8, buf[0..trimmed.len], trimmed);
    return buf;
}

fn setProcessEnvVar(name: []const u8, value: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const name_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, name);
        defer std.heap.page_allocator.free(name_w);
        const value_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, value);
        defer std.heap.page_allocator.free(value_w);
        if (win32_env.SetEnvironmentVariableW(name_w.ptr, value_w.ptr) == 0) return error.SetEnvironmentVariableFailed;
        return;
    }

    const name_z = try std.heap.page_allocator.dupeZ(u8, name);
    defer std.heap.page_allocator.free(name_z);
    const value_z = try std.heap.page_allocator.dupeZ(u8, value);
    defer std.heap.page_allocator.free(value_z);
    if (libc.setenv(name_z.ptr, value_z.ptr, 1) != 0) return error.SetEnvironmentVariableFailed;
}

fn unsetProcessEnvVar(name: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const name_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, name);
        defer std.heap.page_allocator.free(name_w);
        if (win32_env.SetEnvironmentVariableW(name_w.ptr, null) == 0) return error.SetEnvironmentVariableFailed;
        return;
    }

    const name_z = try std.heap.page_allocator.dupeZ(u8, name);
    defer std.heap.page_allocator.free(name_z);
    if (libc.unsetenv(name_z.ptr) != 0) return error.SetEnvironmentVariableFailed;
}

fn jsonObjectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn dupeJsonSafeString(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(text)) return try allocator.dupe(u8, text);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            try out.append(allocator, '?');
            i += 1;
            continue;
        };
        if (i + seq_len > text.len) {
            try out.append(allocator, '?');
            break;
        }
        _ = std.unicode.utf8Decode(text[i .. i + seq_len]) catch {
            try out.append(allocator, '?');
            i += 1;
            continue;
        };
        try out.appendSlice(allocator, text[i .. i + seq_len]);
        i += seq_len;
    }

    return try out.toOwnedSlice(allocator);
}

fn jsonObjectValue(object: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    return object.get(key);
}

fn jsonObjectIndex(object: std.json.ObjectMap, key: []const u8) ?usize {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .float => |n| if (n >= 0 and std.math.floor(n) == n) @intFromFloat(n) else null,
        else => null,
    };
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    switch (value) {
        .null => return .null,
        .bool => |v| return .{ .bool = v },
        .integer => |v| return .{ .integer = v },
        .float => |v| return .{ .float = v },
        .number_string => |v| return .{ .number_string = try allocator.dupe(u8, v) },
        .string => |v| return .{ .string = try allocator.dupe(u8, v) },
        .array => |arr| {
            var out = std.json.Array.init(allocator);
            errdefer {
                for (out.items) |*item| deinitJsonValue(allocator, item.*);
                out.deinit();
            }
            for (arr.items) |item| {
                try out.append(try cloneJsonValue(allocator, item));
            }
            return .{ .array = out };
        },
        .object => |obj| {
            var out = std.json.ObjectMap.init(allocator);
            errdefer {
                var it = out.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    deinitJsonValue(allocator, entry.value_ptr.*);
                }
                out.deinit();
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                try out.put(try allocator.dupe(u8, entry.key_ptr.*), try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            return .{ .object = out };
        },
    }
}

fn deinitJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .number_string => |v| allocator.free(v),
        .string => |v| allocator.free(v),
        .array => |arr| {
            for (arr.items) |item| deinitJsonValue(allocator, item);
            var owned = arr;
            owned.deinit();
        },
        .object => |obj| {
            var owned = obj;
            var it = owned.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitJsonValue(allocator, entry.value_ptr.*);
            }
            owned.deinit();
        },
        else => {},
    }
}

fn jsonObjectValueClone(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !?std.json.Value {
    const value = jsonObjectValue(object, key) orelse return null;
    return try cloneJsonValue(allocator, value);
}

fn appendOwnedJsonString(array: *std.json.Array, allocator: std.mem.Allocator, value: []const u8) !void {
    try array.append(.{ .string = try allocator.dupe(u8, value) });
}

fn sortStringsAsc(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn chunkPayloadObject(allocator: std.mem.Allocator, chunk: []const u8, index: usize, total: usize) !std.json.ObjectMap {
    var object = std.json.ObjectMap.init(allocator);
    errdefer {
        var it = object.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            deinitJsonValue(allocator, entry.value_ptr.*);
        }
        object.deinit();
    }
    try object.put(try allocator.dupe(u8, "index"), .{ .integer = @intCast(index) });
    try object.put(try allocator.dupe(u8, "total"), .{ .integer = @intCast(total) });
    try object.put(try allocator.dupe(u8, "data"), .{ .string = try allocator.dupe(u8, chunk) });
    return object;
}

/// An event captured on the sokol event thread, to be dispatched
/// on the frame thread inside tick() to avoid data races into the ghostty DLL.
/// Covers both mouse/focus events and key/char events so ALL DLL calls are
/// serialised through tick() on the frame thread.
pub const PendingMouseEvent = union(enum) {
    none,
    /// A button press or release.
    button: struct {
        action: ghostty.MouseAction,
        button: ghostty.MouseButton,
        x: f32,
        y: f32,
        mods: u32,
    },
    /// A mouse-motion event (button may be null for hover).
    motion: struct {
        held_button: ?ghostty.MouseButton,
        x: f32,
        y: f32,
        mods: u32,
    },
    /// A scroll delta (raw float, accumulated in scrollFloat on frame thread).
    scroll: struct {
        x: f32,
        y: f32,
        raw_delta: f32,
        mods: u32,
    },
    /// Switch to a specific tab index (calls runtime.registerCallbacks on frame thread).
    switch_tab: usize,
    /// Close a specific tab index without focusing it first.
    close_tab_at: usize,
    new_tab: struct {
        domain_name: ?[]const u8,
        command: ?[]const u8,
        callback_ref: c_int,
    },
    close_tab,
    close_pane,
    close_pane_by_id: usize,
    focus_pane_by_id: usize,
    command_request: command_mod.Request,
    reload_config,
    next_tab,
    prev_tab,
    new_workspace: struct {
        cwd: ?[]const u8,
        domain_name: ?[]const u8,
        command: ?[]const u8,
        name: ?[]const u8,
        callback_ref: c_int,
        queued_at_ms: i64,
    },
    close_workspace: ?usize,
    next_workspace,
    prev_workspace,
    switch_workspace: usize,
    set_workspace_name: []const u8,
    set_workspace_default_cwd: []const u8,
    split_pane: struct {
        direction: SplitDirection,
        ratio: f32,
        domain_name: ?[]const u8,
        cwd: ?[]const u8,
        command: ?[]const u8,
        command_mode: SplitCommandMode,
        close_on_exit: bool,
        floating: bool,
        fullscreen: bool,
        x: ?f32,
        y: ?f32,
        width: ?f32,
        height: ?f32,
        callback_ref: c_int,
    },
    toggle_pane_maximized: struct {
        pane_id: usize,
        show_background: bool,
    },
    set_pane_floating: struct {
        pane_id: usize,
        floating: bool,
    },
    set_floating_pane_bounds: struct {
        pane_id: usize,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    },
    move_pane: struct {
        pane_id: usize,
        direction: FocusDirection,
        amount: f32,
    },
    focus_pane: FocusDirection,
    resize_pane: struct {
        direction: SplitDirection,
        delta: f32,
    },
    /// Update top-bar hover state computed on the event thread.
    hover: struct {
        tab_index: ?usize,
        close_tab_index: ?usize,
    },
    /// Apply a divider drag ratio on the frame thread.
    divider_ratio: struct {
        node: *SplitNode,
        ratio: f32,
    },
    divider_commit,
    /// Focus gained (true) or lost (false) — calls runtime.encodeFocus on frame thread.
    focus: bool,
    /// A key event (calls app.sendKey on frame thread).
    key: struct {
        key: ghostty.Key,
        mods: u32,
        action: ghostty.KeyAction,
    },
    /// A printable character from a CHAR event (calls app.sendText on frame thread).
    /// Stored as a small UTF-8 byte array; len==0 means empty/invalid.
    char: struct {
        bytes: [5]u8,
        len: u8,
    },
    selection_begin: struct {
        pane: *Pane,
        point: selection.CellPoint,
        extend: bool,
    },
    /// Double-click: expand selection to the word containing `point`.
    selection_begin_word: struct {
        pane: *Pane,
        point: selection.CellPoint,
    },
    /// Triple-click: select the entire row containing `point`.
    selection_begin_line: struct {
        pane: *Pane,
        point: selection.CellPoint,
    },
    selection_update: struct {
        pane: *Pane,
        point: selection.CellPoint,
    },
    selection_end,
    clear_selection,
    copy_selection,
    paste_clipboard,
    paste: struct {
        bytes: [CLIPBOARD_EVENT_MAX]u8,
        len: u16,
    },
    scroll_pane_delta: struct {
        pane: *Pane,
        delta: isize,
    },
    scroll_pane_target: struct {
        pane: *Pane,
        top_row: u64,
    },
    scroll_active_delta: isize,
    scroll_active_page: isize,
    scroll_active_top,
    scroll_active_bottom,
    prompt_jump: PromptJumpDir,
    copy_mode_enter,
    copy_mode_exit,
    copy_mode_move: struct {
        kind: CopyModeMoveKind,
        extend: bool,
    },
    copy_mode_begin_selection: bool,
    copy_mode_clear_selection,
    copy_mode_copy,
    copy_mode_open_search,
    copy_mode_search_set_query: []u8,
    copy_mode_search_next,
    copy_mode_search_prev,
    open_hyperlink: struct {
        pane: *Pane,
        point: selection.CellPoint,
    },
};

pub var write_bridge: ?*App = null;
var size_bridge: ?*App = null;
var attrs_bridge: ?*App = null;
var title_bridge: ?*App = null;
var htp_bridge: ?*App = null;
var wake_bridge: ?*App = null;

fn htpMessageCallback(pane: *Pane, payload: []const u8) void {
    const app = htp_bridge orelse return;
    std.log.info("htp: received payload pane={x} bytes={d}", .{ @intFromPtr(pane), payload.len });
    app.queueHtpMessage(pane, payload);
}

fn htpIpcQueryCallback(ctx: *anyopaque, pane_id: usize, channel: []const u8, params: ?std.json.Value) anyerror!HtpQueryResult {
    const app: *App = @ptrCast(@alignCast(ctx));
    return app.dispatchHtpQuerySync(pane_id, channel, params);
}

fn htpIpcEventCallback(ctx: *anyopaque, pane_id: usize, channel: []const u8, payload: ?std.json.Value) anyerror!lua_mod.HtpDispatchResult {
    const app: *App = @ptrCast(@alignCast(ctx));
    return app.dispatchHtpEventSync(pane_id, channel, payload);
}

pub fn signalExternalWake() void {
    const app = wake_bridge orelse return;
    app.signalWake();
}

fn terminalCallbacks() ghostty.TerminalCallbacks {
    return .{
        .write_pty = writePtyCallback,
        .bell = bellCallback,
        .enquiry = enquiryCallback,
        .xtversion = xtversionCallback,
        .size = sizeCallback,
        .color_scheme = colorSchemeCallback,
        .device_attributes = deviceAttributesCallback,
        .title_changed = titleChangedCallback,
    };
}

pub const App = struct {
    pub const ScrollbarMetrics = struct {
        pane: *Pane,
        outer_bounds: PaneBounds,
        track_x: f32,
        track_y: f32,
        track_w: f32,
        track_h: f32,
        thumb_y: f32,
        thumb_h: f32,
        total: u64,
        offset: u64,
        len: u64,
    };

    pub const HoveredHyperlink = struct {
        pane: *Pane,
        row: usize,
        start_col: usize,
        end_col: usize,
    };

    const HyperlinkToken = struct {
        text: []const u8,
        start_col: usize,
        end_col: usize,
        open_text: []const u8,
    };

    allocator: std.mem.Allocator,
    config: Config,
    deinitialized: bool = false,
    lua: ?LuaRuntime = null,
    ghostty: ?GhosttyRuntime = null,
    renderer: ?Backend = null,
    mux: ?Mux = null,
    using_embedded_base_config: bool = false,
    base_config_path: ?[]u8 = null,
    override_config_path: ?[]u8 = null,
    frame_count: usize = 0,
    last_input_activity_ns: i128 = 0,
    last_visual_activity_ns: i128 = 0,
    logged_first_render_update: bool = false,
    cell_width_px: u32 = 8,
    cell_height_px: u32 = 16,
    pending_resize: bool = false,
    pending_width: u32 = 0,
    pending_height: u32 = 0,
    pending_renderer_refresh: bool = false,
    cached_sidebar_layout: ?SidebarLayout = null,
    cached_top_bar_layout: ?TopBarLayout = null,
    cached_bottom_bar_layout: ?BottomBarLayout = null,
    cached_bar_layouts_dirty: bool = true,
    /// Set when a split has just been performed; causes tick() to re-layout
    /// all panes on the next frame (safe from the frame callback thread).
    pending_layout_resize: bool = false,
    pending_layout_recreate_render_helpers: bool = false,
    pending_layout_skip_unchanged_pty: bool = false,
    layout_generation: u32 = 1,
    pending_drag_layout_resize: bool = false,
    pending_split_ratio_node: ?*SplitNode = null,
    pending_split_ratio: f32 = 0.5,
    /// Set when all panes/tabs have closed; the runtime should call sapp_request_quit().
    pending_quit: bool = false,
    hovered_tab_index: ?usize = null,
    hovered_close_tab_index: ?usize = null,
    startup_command: ?[]u8 = null,
    startup_command_delay_frames: usize = 0,
    startup_command_sent: bool = false,
    snapshot_dump_path: ?[]u8 = null,
    snapshot_dump_file: ?std.fs.File = null,
    snapshot_dump_last_hash: u64 = 0,
    snapshot_dump_has_last_hash: bool = false,
    /// Fractional scroll accumulator — prevents sub-pixel scroll events from
    /// being silently dropped by integer truncation on smooth / touchpad input.
    scroll_accum: f32 = 0,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    pointer_mods: u32 = 0,
    hover_probe_dirty: bool = true,
    selection_pane: ?*Pane = null,
    selection_anchor: ?selection.CellPoint = null,
    selection_head: ?selection.CellPoint = null,
    selection_drag_active: bool = false,
    selection_generation: u64 = 0,
    hovered_hyperlink: ?HoveredHyperlink = null,
    copy_mode_active: bool = false,
    copy_mode_pane: ?*Pane = null,
    copy_mode_history: std.ArrayListUnmanaged(CopyModeLine) = .empty,
    copy_mode_cursor: CopyModePoint = .{},
    copy_mode_top_row: usize = 0,
    copy_mode_restore_top_row: usize = 0,
    copy_mode_anchor: ?CopyModePoint = null,
    copy_mode_block_selection: bool = false,
    copy_mode_matches: std.ArrayListUnmanaged(CopyModeMatch) = .empty,
    copy_mode_match_index: ?usize = null,
    copy_mode_query: []u8 = &.{},
    copy_mode_needs_refresh: bool = false,
    htp_pending_messages: std.ArrayListUnmanaged(HtpQueuedMessage) = .empty,
    htp_chunk_assemblies: std.ArrayListUnmanaged(HtpChunkAssembly) = .empty,
    htp_next_message_id: u64 = 1,
    command_ipc_server: ?command_ipc.Server = null,
    pane_tags: std.ArrayListUnmanaged(PaneTagEntry) = .empty,
    command_mutex: std.Thread.Mutex = .{},
    command_ready: std.Thread.Condition = .{},
    command_done: std.Thread.Condition = .{},
    pending_command: ?*PendingCommandRequest = null,
    leader_visual_active: bool = false,
    leader_visual_expires_at_ns: i128 = 0,
    topbar_cache_visible: bool = false,
    topbar_cache_dirty: bool = true,
    topbar_cache_expires_at_ns: i128 = 0,
    bottombar_cache_visible: bool = false,
    bottombar_cache_dirty: bool = true,
    bottombar_cache_expires_at_ns: i128 = 0,
    next_idle_render_poll_ns: i128 = 0,
    wake_generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // ── Pending mouse event queue ─────────────────────────────────────────────
    // Sokol event callbacks run on the OS event thread; the ghostty DLL is NOT
    // thread-safe.  We must never call encodeMouse / terminalScroll from the
    // event thread while the frame thread may be inside updateRenderState /
    // resizeTerminal for the same terminal objects.
    //
    // Instead, event callbacks write into this fixed-size ring buffer and
    // tick() drains it on the frame thread before any DLL calls.
    //
    // Capacity: 64 slots.  At 120 fps we get one tick() per ~8 ms.  Between
    // two frames the OS can fire at most a handful of mouse events (scroll,
    // move, click), so 64 is more than enough.  If the queue is full, new
    // events are silently dropped (better than a crash or a data race).
    mouse_queue: [64]PendingMouseEvent = [_]PendingMouseEvent{.none} ** 64,
    mouse_queue_head: usize = 0, // next slot to read  (frame thread)
    mouse_queue_tail: usize = 0, // next slot to write (event thread)

    const HtpQueuedMessage = struct {
        pane_id: usize,
        payload: []u8,
    };

    const HtpChunkAssembly = struct {
        pane_id: usize,
        request_id: []u8,
        total: usize,
        next_index: usize,
        buffer: std.ArrayListUnmanaged(u8) = .empty,
    };

    const HtpEnvelope = struct {
        v: u8 = 1,
        id: u64,
        kind: []const u8,
        channel: ?[]const u8 = null,
        request_id: ?std.json.Value = null,
        status: ?[]const u8 = null,
        @"error": ?[]const u8 = null,
        payload: ?std.json.Value = null,
        params: ?std.json.Value = null,
    };

    const PaneTagEntry = struct {
        pane_id: usize,
        tags: std.StringArrayHashMapUnmanaged(void) = .empty,

        fn deinit(self: *PaneTagEntry, allocator: std.mem.Allocator) void {
            var it = self.tags.iterator();
            while (it.next()) |entry| allocator.free(entry.key_ptr.*);
            self.tags.deinit(allocator);
        }
    };

    const PendingCommandRequest = struct {
        request: command_mod.Request,
        response: ?command_mod.Response = null,
        done: bool = false,
    };

    const CommandExecutionMode = enum {
        sync,
        deferred,
    };

    /// Push any pending event onto the shared ring buffer.  Called from the
    /// event thread.  Returns true on success, false if the queue is full
    /// (event is dropped — better than a crash or a data race).
    pub fn enqueueMouse(self: *App, ev: PendingMouseEvent) bool {
        const cap = self.mouse_queue.len;
        const next_tail = (self.mouse_queue_tail + 1) % cap;
        if (next_tail == @atomicLoad(usize, &self.mouse_queue_head, .acquire)) {
            // Queue full — drop event.
            return false;
        }
        const now_ns = std.time.nanoTimestamp();
        self.last_input_activity_ns = now_ns;
        self.last_visual_activity_ns = now_ns;
        self.mouse_queue[self.mouse_queue_tail] = ev;
        @atomicStore(usize, &self.mouse_queue_tail, next_tail, .release);
        self.signalWake();
        return true;
    }

    /// Convenience wrapper for key-down events: enqueues a .key variant.
    /// Called from the event thread.
    pub fn enqueueKey(self: *App, key: ghostty.Key, mods: u32, action: ghostty.KeyAction) bool {
        return self.enqueueMouse(.{ .key = .{ .key = key, .mods = mods, .action = action } });
    }

    /// Convenience wrapper for char events: enqueues a .char variant.
    /// `bytes` must be a valid UTF-8 slice of at most 4 bytes.
    /// Called from the event thread.
    pub fn enqueueChar(self: *App, bytes: []const u8) bool {
        if (bytes.len == 0 or bytes.len > 4) return false;
        var ev: PendingMouseEvent = .{ .char = .{ .bytes = [_]u8{0} ** 5, .len = @intCast(bytes.len) } };
        fastmem.copy(u8, ev.char.bytes[0..bytes.len], bytes);
        return self.enqueueMouse(ev);
    }

    pub fn queueHtpMessage(self: *App, pane: *Pane, payload: []const u8) void {
        const owned = self.allocator.dupe(u8, payload) catch return;
        std.log.info("htp: queue pane={x} bytes={d}", .{ @intFromPtr(pane), payload.len });
        self.htp_pending_messages.append(self.allocator, .{
            .pane_id = @intFromPtr(pane),
            .payload = owned,
        }) catch {
            self.allocator.free(owned);
            return;
        };
        self.signalWake();
    }

    fn bindHtpHandlers(self: *App) void {
        std.log.info("htp: bind handlers mux_present={} panes_pending={}", .{ self.mux != null, if (self.mux) |_| true else false });
        if (self.mux) |*mux| {
            var panes = mux.paneIterator();
            while (panes.next()) |pane| {
                std.log.info("htp: binding pane={x}", .{@intFromPtr(pane)});
                pane.setHtpMessageHandler(htpMessageCallback);
            }
        }
    }

    fn startCommandTransport(self: *App) void {
        if (self.command_ipc_server != null) return;
        self.command_ipc_server = command_ipc.Server.init(self.allocator, self, commandIpcHandler);
        self.command_ipc_server.?.start() catch |err| {
            std.log.warn("command-ipc: failed to start: {s}", .{@errorName(err)});
            self.command_ipc_server.?.deinit();
            self.command_ipc_server = null;
            return;
        };
        if (self.command_ipc_server.?.address()) |addr| {
            std.log.info("command-ipc: listening on {s}", .{addr});
            setProcessEnvVar(command_ipc.EnvVar, addr) catch |err| {
                std.log.warn("command-ipc: failed to export {s}: {s}", .{ command_ipc.EnvVar, @errorName(err) });
            };
        }
        self.syncCommandTimingEnv();
    }

    fn syncCommandTimingEnv(self: *App) void {
        if (self.config.command_timing) {
            std.log.info("command-ipc: command_timing enabled", .{});
            setProcessEnvVar(command_ipc.TimingEnvVar, "1") catch |err| {
                std.log.warn("command-ipc: failed to export {s}: {s}", .{ command_ipc.TimingEnvVar, @errorName(err) });
            };
            return;
        }

        std.log.info("command-ipc: command_timing disabled", .{});
        unsetProcessEnvVar(command_ipc.TimingEnvVar) catch |err| {
            std.log.warn("command-ipc: failed to clear {s}: {s}", .{ command_ipc.TimingEnvVar, @errorName(err) });
        };
    }

    /// Drain all pending events and dispatch them.  Called from tick()
    /// on the frame thread, where it is safe to call into the ghostty DLL.
    fn drainMouseQueue(self: *App) void {
        const cap = self.mouse_queue.len;
        while (true) {
            const tail = @atomicLoad(usize, &self.mouse_queue_tail, .acquire);
            if (self.mouse_queue_head == tail) break; // queue empty

            const head = self.mouse_queue_head;
            const ev = self.mouse_queue[head];
            var advance: usize = 1;

            switch (ev) {
                .none => {},
                .button => |b| {
                    self.recordPointerState(b.x, b.y, b.mods);
                    _ = self.sendMouse(b.action, b.button, b.x, b.y, b.mods) catch false;
                },
                .motion => |m| {
                    self.recordPointerState(m.x, m.y, m.mods);
                    _ = self.sendMouse(.motion, m.held_button, m.x, m.y, m.mods) catch false;
                },
                .scroll => |s| {
                    self.recordPointerState(s.x, s.y, s.mods);
                    self.scrollFloat(s.x, s.y, s.raw_delta, s.mods);
                },
                .switch_tab => |idx| {
                    self.switchTab(idx);
                },
                .close_tab_at => |idx| {
                    self.closeTabAt(idx);
                },
                .new_tab => |payload| {
                    defer if (payload.domain_name) |owned| self.allocator.free(owned);
                    defer if (payload.command) |owned| self.allocator.free(owned);
                    self.newTab(payload.domain_name, payload.command, payload.callback_ref);
                },
                .close_tab => {
                    self.closeTab();
                },
                .close_pane => {
                    self.closeActivePane();
                },
                .close_pane_by_id => |pane_id| {
                    self.closePaneById(pane_id);
                },
                .focus_pane_by_id => |pane_id| {
                    self.focusPaneById(pane_id);
                },
                .command_request => |request| {
                    var owned = request;
                    defer owned.deinit(self.allocator);
                    _ = self.executeCommand(owned) catch |err| {
                        std.log.err("command-ipc: deferred command failed: {s}", .{@errorName(err)});
                    };
                },
                .reload_config => {
                    _ = self.reloadConfig();
                },
                .next_tab => {
                    self.nextTab();
                },
                .prev_tab => {
                    self.prevTab();
                },
                .new_workspace => |payload| {
                    defer if (payload.cwd) |value| self.allocator.free(value);
                    defer if (payload.domain_name) |value| self.allocator.free(value);
                    defer if (payload.command) |value| self.allocator.free(value);
                    defer if (payload.name) |value| self.allocator.free(value);
                    std.log.info("app: new_workspace dispatch_lag_ms={d}", .{std.time.milliTimestamp() - payload.queued_at_ms});
                    self.newWorkspace(payload.cwd, payload.domain_name, payload.command, payload.name, payload.callback_ref);
                },
                .close_workspace => |idx| {
                    self.closeWorkspace(idx);
                },
                .next_workspace => {
                    self.nextWorkspace();
                },
                .prev_workspace => {
                    self.prevWorkspace();
                },
                .switch_workspace => |idx| {
                    self.switchWorkspace(idx);
                },
                .set_workspace_name => |name| {
                    defer self.allocator.free(name);
                    self.setWorkspaceName(name);
                },
                .set_workspace_default_cwd => |cwd| {
                    defer self.allocator.free(cwd);
                    self.setWorkspaceDefaultCwd(cwd);
                },
                .split_pane => |split| {
                    defer if (split.domain_name) |owned| self.allocator.free(owned);
                    defer if (split.cwd) |owned| self.allocator.free(owned);
                    defer if (split.command) |owned| self.allocator.free(owned);
                    self.splitPane(split.direction, split.ratio, split.domain_name, split.cwd, split.command, split.command_mode, split.close_on_exit, split.floating, split.fullscreen, split.x, split.y, split.width, split.height, split.callback_ref);
                },
                .toggle_pane_maximized => |maximize| {
                    self.togglePaneMaximizedById(maximize.pane_id, maximize.show_background);
                },
                .set_pane_floating => |floating| {
                    self.setPaneFloatingById(floating.pane_id, floating.floating);
                },
                .set_floating_pane_bounds => |floating| {
                    self.setFloatingPaneBoundsById(floating.pane_id, floating.x, floating.y, floating.width, floating.height);
                },
                .move_pane => |move_ev| {
                    self.movePaneById(move_ev.pane_id, move_ev.direction, move_ev.amount);
                },
                .focus_pane => |direction| {
                    self.focusPane(direction);
                },
                .resize_pane => |resize_ev| {
                    self.resizePane(resize_ev.direction, resize_ev.delta);
                },
                .hover => |hover| {
                    self.hovered_tab_index = hover.tab_index;
                    self.hovered_close_tab_index = hover.close_tab_index;
                },
                .divider_ratio => |drag| {
                    if (self.isSplitNodeValid(drag.node)) {
                        self.previewSplitNodeRatio(drag.node, drag.ratio);
                    }
                },
                .divider_commit => {
                    self.requestLayoutResize(false);
                },
                .focus => |gained| {
                    self.sendFocus(gained) catch {};
                    self.emitLuaBuiltInEvent(if (gained) "window:focused" else "window:blurred", .none);
                },
                .key => |k| {
                    var text: ?[]const u8 = null;
                    var fallback_buf: [4]u8 = undefined;
                    if (k.action != .release) {
                        const next = (head + 1) % cap;
                        if (next != tail) {
                            switch (self.mouse_queue[next]) {
                                .char => |ch| {
                                    if (ch.len > 0) {
                                        text = ch.bytes[0..ch.len];
                                        advance = 2;
                                    }
                                },
                                else => {},
                            }
                        }
                    }

                    const printable_fallback = legacyPrintableKeyText(k.key, k.mods, &fallback_buf);
                    const use_char_text_only = builtin.os.tag != .windows and k.action != .release and text != null and (k.mods & (ghostty.Mods.ctrl | ghostty.Mods.alt | ghostty.Mods.super)) == 0;
                    if (!use_char_text_only) {
                        if (!(self.sendKey(k.key, k.mods, k.action, text) catch false)) {
                            if (printable_fallback == null) {
                                if (text) |bytes| self.sendText(bytes);
                            }
                        }
                    }
                },
                .char => |ch| {
                    if (ch.len > 0) self.sendText(ch.bytes[0..ch.len]);
                },
                .selection_begin => |sel| {
                    self.selectionBegin(sel.pane, sel.point, sel.extend);
                },
                .selection_begin_word => |sel| {
                    self.selectionBeginWord(sel.pane, sel.point);
                },
                .selection_begin_line => |sel| {
                    self.selectionBeginLine(sel.pane, sel.point);
                },
                .selection_update => |sel| {
                    self.selectionUpdate(sel.pane, sel.point);
                },
                .selection_end => {
                    self.selectionEnd();
                },
                .clear_selection => {
                    self.clearSelection();
                },
                .copy_selection => {
                    self.copySelectionToClipboard() catch |err| {
                        std.log.err("copy selection failed: {s}", .{@errorName(err)});
                    };
                },
                .paste_clipboard => {
                    self.pasteClipboard() catch |err| {
                        std.log.err("paste clipboard failed: {s}", .{@errorName(err)});
                    };
                },
                .paste => |paste| {
                    if (paste.len > 0) {
                        self.sendPaste(paste.bytes[0..paste.len]) catch |err| {
                            std.log.err("paste failed: {s}", .{@errorName(err)});
                        };
                    }
                },
                .scroll_pane_delta => |scroll_ev| {
                    if (!self.hasPane(scroll_ev.pane)) continue;
                    if (self.copy_mode_active and self.copy_mode_pane == scroll_ev.pane) {
                        self.copyModeScrollDelta(scroll_ev.delta);
                    } else {
                        self.scrollPaneViewport(scroll_ev.pane, scroll_ev.delta);
                    }
                },
                .scroll_pane_target => |scroll_ev| {
                    if (!self.hasPane(scroll_ev.pane)) continue;
                    if (self.copy_mode_active and self.copy_mode_pane == scroll_ev.pane) {
                        self.copyModeScrollToRow(scroll_ev.top_row);
                    } else {
                        self.scrollPaneViewportToRow(scroll_ev.pane, scroll_ev.top_row);
                    }
                },
                .scroll_active_delta => |delta| {
                    if (self.copy_mode_active) {
                        self.copyModeScrollDelta(delta);
                    } else {
                        self.scrollActiveViewport(delta);
                    }
                },
                .scroll_active_page => |pages| {
                    if (self.copy_mode_active) {
                        const pane = self.copy_mode_pane orelse continue;
                        self.copyModeScrollDelta(pages * pageScrollRows(pane));
                    } else {
                        self.scrollActiveViewportPage(pages);
                    }
                },
                .scroll_active_top => {
                    if (self.copy_mode_active) {
                        self.copyModeScrollToRow(0);
                    } else {
                        self.scrollActiveViewportTop();
                    }
                },
                .scroll_active_bottom => {
                    if (self.copy_mode_active) {
                        self.copyModeScrollToBottom();
                    } else {
                        self.scrollActiveViewportBottom();
                    }
                },
                .prompt_jump => |dir| {
                    if (self.copy_mode_active) {
                        self.copyModePromptJump(dir);
                    } else {
                        self.handlePromptJump(dir);
                    }
                },
                .copy_mode_enter => {
                    self.enterCopyMode();
                },
                .copy_mode_exit => {
                    self.exitCopyMode();
                },
                .copy_mode_move => |move| {
                    self.copyModeMove(move.kind, move.extend);
                },
                .copy_mode_begin_selection => |block| {
                    self.copyModeBeginSelectionWithBlock(block);
                },
                .copy_mode_clear_selection => {
                    self.copyModeClearSelection();
                },
                .copy_mode_copy => {
                    self.copyModeCopy() catch |err| {
                        std.log.err("copy mode copy failed: {s}", .{@errorName(err)});
                    };
                },
                .copy_mode_open_search => {
                    self.emitLuaBuiltInEvent("copy_mode:search_requested", .none);
                },
                .copy_mode_search_set_query => |query| {
                    defer self.allocator.free(query);
                    self.copyModeSetSearchQuery(query) catch |err| {
                        std.log.err("copy mode search query failed: {s}", .{@errorName(err)});
                    };
                },
                .copy_mode_search_next => {
                    self.copyModeJumpMatch(true);
                },
                .copy_mode_search_prev => {
                    self.copyModeJumpMatch(false);
                },
                .open_hyperlink => |open_ev| {
                    if (self.hasPane(open_ev.pane)) self.openHyperlinkAt(open_ev.pane, open_ev.point);
                },
            }

            @atomicStore(usize, &self.mouse_queue_head, (head + advance) % cap, .release);
        }

        self.drainPendingCommand();
    }

    fn drainPendingCommand(self: *App) void {
        self.command_mutex.lock();
        defer self.command_mutex.unlock();

        const pending = self.pending_command orelse return;
        if (pending.done) return;

        const timing_enabled = self.config.command_timing;
        const start_ns = if (timing_enabled) std.time.nanoTimestamp() else 0;
        pending.response = switch (commandExecutionMode(pending.request.kind)) {
            .sync => self.executeCommand(pending.request) catch |err| command_mod.Response.fail("internal", @errorName(err)),
            .deferred => self.enqueueDeferredCommand(pending.request),
        };
        if (timing_enabled) {
            std.log.info("command-ipc: dispatch_ms={d:.3} kind={s}", .{ elapsedMs(start_ns), @tagName(pending.request.kind) });
        }
        pending.done = true;
        self.command_done.signal();
    }

    pub fn runCommandSync(self: *App, request: command_mod.Request) command_mod.Response {
        var pending = PendingCommandRequest{ .request = request };

        self.command_mutex.lock();
        defer self.command_mutex.unlock();

        while (self.pending_command != null) {
            self.command_done.wait(&self.command_mutex);
        }

        self.pending_command = &pending;
        self.signalWake();
        self.command_ready.signal();

        while (!pending.done) {
            self.command_done.wait(&self.command_mutex);
        }

        self.pending_command = null;
        self.command_done.broadcast();
        return pending.response orelse command_mod.Response.fail("internal", "missing command response");
    }

    pub fn hasPendingCommand(self: *App) bool {
        self.command_mutex.lock();
        defer self.command_mutex.unlock();

        const pending = self.pending_command orelse return false;
        return !pending.done;
    }

    fn elapsedMs(start_ns: i128) f64 {
        return @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    }

    fn commandExecutionMode(kind: command_mod.Kind) CommandExecutionMode {
        return switch (kind) {
            .get_pane,
            .get_pane_text,
            .get_current_pane,
            .get_tab,
            .get_current_tab,
            .get_tabs,
            .get_panes,
            .get_workspace,
            .get_current_workspace,
            .get_workspaces,
            .get_domain,
            .get_htp,
                => .sync,
            else => .deferred,
        };
    }

    fn enqueueDeferredCommand(self: *App, request: command_mod.Request) command_mod.Response {
        switch (request.kind) {
            .workspace_new => return self.enqueueWorkspaceNewCommand(request),
            .workspace_close => {
                if (!self.enqueueMouse(.{ .close_workspace = request.id })) return command_mod.Response.fail("error", "command queue full");
                return okNull();
            },
            .workspace_next => {
                if (!self.enqueueMouse(.next_workspace)) return command_mod.Response.fail("error", "command queue full");
                return okNull();
            },
            .workspace_prev => {
                if (!self.enqueueMouse(.prev_workspace)) return command_mod.Response.fail("error", "command queue full");
                return okNull();
            },
            .workspace_select => {
                const index = request.index orelse return command_mod.Response.fail("invalid_args", "missing workspace index");
                if (!self.enqueueMouse(.{ .switch_workspace = index -| 1 })) return command_mod.Response.fail("error", "command queue full");
                return okNull();
            },
            .workspace_rename => return self.enqueueWorkspaceRenameCommand(request),
            .tab_new => return self.enqueueTabNewCommand(request),
            .tab_close => return self.enqueueTabCloseCommand(request),
            .tab_next => {
                if (!self.enqueueMouse(.next_tab)) return command_mod.Response.fail("error", "command queue full");
                return okNull();
            },
            .tab_prev => {
                if (!self.enqueueMouse(.prev_tab)) return command_mod.Response.fail("error", "command queue full");
                return okNull();
            },
            .tab_select => return self.enqueueTabSelectCommand(request),
            .tab_rename => return self.enqueueCommandRequest(request),
            .pane_split => return self.enqueuePaneSplitCommand(request),
            .pane_popup => return self.enqueuePanePopupCommand(request),
            .pane_close => return self.enqueueCommandRequest(request),
            .pane_zoom => return self.enqueuePaneZoomCommand(request),
            .pane_float => return self.enqueuePaneFloatingCommand(request, true),
            .pane_tile => return self.enqueuePaneFloatingCommand(request, false),
            .pane_move => return self.enqueuePaneMoveCommand(request),
            .pane_resize => return self.enqueuePaneResizeCommand(request),
            .pane_send_text, .send_keys => return self.enqueueCommandRequest(request),
            .pane_set_tag => return self.enqueueCommandRequest(request),
            .pane_remove_tag => return self.enqueueCommandRequest(request),
            .pane_set_tags => return self.enqueueCommandRequest(request),
            .focus => return self.enqueueFocusCommand(request),
            .scroll => return self.enqueueScrollCommand(request),
            .config_reload => {
                if (!self.enqueueMouse(.reload_config)) return command_mod.Response.fail("error", "command queue full");
                return okNull();
            },
            .config_theme => return self.enqueueCommandRequest(request),
            .run => return self.enqueueTabNewCommand(request),
            .emit => return self.enqueueCommandRequest(request),
            else => return self.enqueueCommandRequest(request),
        }
    }

    fn enqueueCommandRequest(self: *App, request: command_mod.Request) command_mod.Response {
        var cloned = self.cloneCommandRequest(request) catch return command_mod.Response.fail("internal", "oom");
        errdefer cloned.deinit(self.allocator);
        if (!self.enqueueMouse(.{ .command_request = cloned })) {
            cloned.deinit(self.allocator);
            return command_mod.Response.fail("error", "command queue full");
        }
        return okNull();
    }

    fn cloneOwnedOptionalString(self: *App, value: ?[]const u8) !?[]u8 {
        return if (value) |text| try self.allocator.dupe(u8, text) else null;
    }

    fn cloneOwnedOptionalJson(self: *App, value: ?std.json.Value) !?std.json.Value {
        return if (value) |json| try command_mod.cloneJsonValue(self.allocator, json) else null;
    }

    fn cloneOwnedOptionalStringSlice(self: *App, value: ?[]const []const u8) !?[]const []const u8 {
        const items = value orelse return null;
        var out = try self.allocator.alloc([]const u8, items.len);
        errdefer {
            for (out[0..items.len]) |item| self.allocator.free(item);
            self.allocator.free(out);
        }
        for (items, 0..) |item, index| {
            out[index] = try self.allocator.dupe(u8, item);
        }
        return out;
    }

    fn cloneCommandRequest(self: *App, request: command_mod.Request) !command_mod.Request {
        return .{
            .kind = request.kind,
            .pane_id = request.pane_id,
            .id = request.id,
            .index = request.index,
            .name = try self.cloneOwnedOptionalString(request.name),
            .cmd = try self.cloneOwnedOptionalString(request.cmd),
            .cwd = try self.cloneOwnedOptionalString(request.cwd),
            .domain = try self.cloneOwnedOptionalString(request.domain),
            .direction = try self.cloneOwnedOptionalString(request.direction),
            .amount = request.amount,
            .ratio = request.ratio,
            .x = request.x,
            .y = request.y,
            .width = request.width,
            .height = request.height,
            .text = try self.cloneOwnedOptionalString(request.text),
            .tag = try self.cloneOwnedOptionalString(request.tag),
            .tags = try self.cloneOwnedOptionalStringSlice(request.tags),
            .channel = try self.cloneOwnedOptionalString(request.channel),
            .params = try self.cloneOwnedOptionalJson(request.params),
            .payload = try self.cloneOwnedOptionalJson(request.payload),
        };
    }

    fn enqueueTabNewCommand(self: *App, request: command_mod.Request) command_mod.Response {
        const owned_domain = if (request.domain) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
        errdefer if (owned_domain) |value| self.allocator.free(value);
        const owned_command = if (request.cmd) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
        errdefer if (owned_command) |value| self.allocator.free(value);
        if (!self.enqueueMouse(.{ .new_tab = .{ .domain_name = owned_domain, .command = owned_command, .callback_ref = LUA_NOREF } })) {
            if (owned_command) |value| self.allocator.free(value);
            if (owned_domain) |value| self.allocator.free(value);
            return command_mod.Response.fail("error", "command queue full");
        }
        return okNull();
    }

    fn enqueueWorkspaceNewCommand(self: *App, request: command_mod.Request) command_mod.Response {
        const owned_cwd = if (request.cwd) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
        errdefer if (owned_cwd) |value| self.allocator.free(value);
        const owned_domain = if (request.domain) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
        errdefer if (owned_domain) |value| self.allocator.free(value);
        const owned_command = if (request.cmd) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
        errdefer if (owned_command) |value| self.allocator.free(value);
        const owned_name = if (request.name) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
        errdefer if (owned_name) |value| self.allocator.free(value);
        if (!self.enqueueMouse(.{ .new_workspace = .{ .cwd = owned_cwd, .domain_name = owned_domain, .command = owned_command, .name = owned_name, .callback_ref = LUA_NOREF, .queued_at_ms = std.time.milliTimestamp() } })) {
            if (owned_name) |value| self.allocator.free(value);
            if (owned_command) |value| self.allocator.free(value);
            if (owned_domain) |value| self.allocator.free(value);
            if (owned_cwd) |value| self.allocator.free(value);
            return command_mod.Response.fail("error", "command queue full");
        }
        return okNull();
    }

    fn enqueueWorkspaceRenameCommand(self: *App, request: command_mod.Request) command_mod.Response {
        const name = request.name orelse return command_mod.Response.fail("invalid_args", "missing workspace name");
        if (request.id) |workspace_id| {
            const active_id = self.currentWorkspaceIdValue() orelse return command_mod.Response.fail("invalid_args", "no active workspace");
            if (active_id != workspace_id) return command_mod.Response.fail("invalid_args", "workspace rename only supports the active workspace");
        }
        const owned_name = self.allocator.dupe(u8, name) catch return command_mod.Response.fail("internal", "oom");
        if (!self.enqueueMouse(.{ .set_workspace_name = owned_name })) {
            self.allocator.free(owned_name);
            return command_mod.Response.fail("error", "command queue full");
        }
        return okNull();
    }

    fn enqueueTabCloseCommand(self: *App, request: command_mod.Request) command_mod.Response {
        if (request.id) |tab_id| {
            const index = self.tabIndexById(tab_id) orelse return command_mod.Response.fail("invalid_args", "unknown tab id");
            if (!self.enqueueMouse(.{ .close_tab_at = index })) return command_mod.Response.fail("error", "command queue full");
            return okNull();
        }
        if (!self.enqueueMouse(.close_tab)) return command_mod.Response.fail("error", "command queue full");
        return okNull();
    }

    fn enqueueTabSelectCommand(self: *App, request: command_mod.Request) command_mod.Response {
        const tab_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing tab id");
        const index = self.tabIndexById(tab_id) orelse return command_mod.Response.fail("invalid_args", "unknown tab id");
        if (!self.enqueueMouse(.{ .switch_tab = index })) return command_mod.Response.fail("error", "command queue full");
        return okNull();
    }

    fn enqueuePaneSplitCommand(self: *App, request: command_mod.Request) command_mod.Response {
        const direction_text = request.direction orelse return command_mod.Response.fail("invalid_args", "missing pane direction");
        const direction = parseSplitDirection(direction_text) orelse return command_mod.Response.fail("invalid_args", "invalid pane direction");
        const owned_domain = if (request.domain) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
        errdefer if (owned_domain) |value| self.allocator.free(value);
        const owned_cwd = if (request.cwd) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
        errdefer if (owned_cwd) |value| self.allocator.free(value);
        const owned_command = if (request.cmd) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
        errdefer if (owned_command) |value| self.allocator.free(value);
        if (!self.enqueueMouse(.{ .split_pane = .{
            .direction = direction,
            .ratio = @floatCast(request.ratio orelse 0.5),
            .domain_name = owned_domain,
            .cwd = owned_cwd,
            .command = owned_command,
            .command_mode = .spawn,
            .close_on_exit = false,
            .floating = false,
            .fullscreen = false,
            .x = null,
            .y = null,
            .width = null,
            .height = null,
            .callback_ref = LUA_NOREF,
        } })) {
            if (owned_command) |value| self.allocator.free(value);
            if (owned_cwd) |value| self.allocator.free(value);
            if (owned_domain) |value| self.allocator.free(value);
            return command_mod.Response.fail("error", "command queue full");
        }
        return okNull();
    }

    fn enqueuePanePopupCommand(self: *App, request: command_mod.Request) command_mod.Response {
        const cmd = request.cmd orelse return command_mod.Response.fail("invalid_args", "missing popup command");
        const owned_domain = if (request.domain) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
        errdefer if (owned_domain) |value| self.allocator.free(value);
        const owned_cwd = if (request.cwd) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
        errdefer if (owned_cwd) |value| self.allocator.free(value);
        const owned_command = self.allocator.dupe(u8, cmd) catch return command_mod.Response.fail("internal", "oom");
        errdefer self.allocator.free(owned_command);
        if (!self.enqueueMouse(.{ .split_pane = .{
            .direction = .vertical,
            .ratio = 0.5,
            .domain_name = owned_domain,
            .cwd = owned_cwd,
            .command = owned_command,
            .command_mode = .spawn,
            .close_on_exit = false,
            .floating = true,
            .fullscreen = false,
            .x = if (request.x) |value| @floatCast(value) else null,
            .y = if (request.y) |value| @floatCast(value) else null,
            .width = if (request.width) |value| @floatCast(value) else null,
            .height = if (request.height) |value| @floatCast(value) else null,
            .callback_ref = LUA_NOREF,
        } })) {
            self.allocator.free(owned_command);
            if (owned_cwd) |value| self.allocator.free(value);
            if (owned_domain) |value| self.allocator.free(value);
            return command_mod.Response.fail("error", "command queue full");
        }
        return okNull();
    }

    fn enqueuePaneZoomCommand(self: *App, request: command_mod.Request) command_mod.Response {
        const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
        if (!self.enqueueMouse(.{ .toggle_pane_maximized = .{ .pane_id = pane_id, .show_background = false } })) return command_mod.Response.fail("error", "command queue full");
        return okNull();
    }

    fn enqueuePaneFloatingCommand(self: *App, request: command_mod.Request, floating: bool) command_mod.Response {
        const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
        if (!self.enqueueMouse(.{ .set_pane_floating = .{ .pane_id = pane_id, .floating = floating } })) return command_mod.Response.fail("error", "command queue full");
        return okNull();
    }

    fn enqueuePaneMoveCommand(self: *App, request: command_mod.Request) command_mod.Response {
        const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
        const direction = request.direction orelse return command_mod.Response.fail("invalid_args", "missing pane direction");
        const focus_direction = parseFocusDirection(direction) orelse return command_mod.Response.fail("invalid_args", "invalid pane direction");
        if (!self.enqueueMouse(.{ .move_pane = .{ .pane_id = pane_id, .direction = focus_direction, .amount = @floatCast(request.amount orelse 0.08) } })) return command_mod.Response.fail("error", "command queue full");
        return okNull();
    }

    fn enqueuePaneResizeCommand(self: *App, request: command_mod.Request) command_mod.Response {
        const direction = request.direction orelse return command_mod.Response.fail("invalid_args", "missing pane direction");
        const split_direction = parseSplitDirection(direction) orelse return command_mod.Response.fail("invalid_args", "invalid pane direction");
        const amount = @as(f32, @floatCast(request.amount orelse 0));
        const delta: f32 = if (std.mem.eql(u8, direction, "left") or std.mem.eql(u8, direction, "up")) -@abs(amount) else @abs(amount);
        if (!self.enqueueMouse(.{ .resize_pane = .{ .direction = split_direction, .delta = delta } })) return command_mod.Response.fail("error", "command queue full");
        return okNull();
    }

    fn enqueueFocusCommand(self: *App, request: command_mod.Request) command_mod.Response {
        const direction = request.direction orelse return command_mod.Response.fail("invalid_args", "missing focus direction");
        const focus_direction = parseFocusDirection(direction) orelse return command_mod.Response.fail("invalid_args", "invalid focus direction");
        if (!self.enqueueMouse(.{ .focus_pane = focus_direction })) return command_mod.Response.fail("error", "command queue full");
        return okNull();
    }

    fn enqueueScrollCommand(self: *App, request: command_mod.Request) command_mod.Response {
        const target = request.direction orelse return command_mod.Response.fail("invalid_args", "missing scroll target");
        if (std.mem.eql(u8, target, "top")) {
            if (!self.enqueueMouse(.scroll_active_top)) return command_mod.Response.fail("error", "command queue full");
        } else if (std.mem.eql(u8, target, "bottom")) {
            if (!self.enqueueMouse(.scroll_active_bottom)) return command_mod.Response.fail("error", "command queue full");
        } else if (std.mem.eql(u8, target, "page-up")) {
            if (!self.enqueueMouse(.{ .scroll_active_page = -1 })) return command_mod.Response.fail("error", "command queue full");
        } else if (std.mem.eql(u8, target, "page-down")) {
            if (!self.enqueueMouse(.{ .scroll_active_page = 1 })) return command_mod.Response.fail("error", "command queue full");
        } else {
            return command_mod.Response.fail("invalid_args", "invalid scroll target");
        }
        return okNull();
    }

    fn findPaneTagEntry(self: *App, pane_id: usize) ?*PaneTagEntry {
        for (self.pane_tags.items) |*entry| {
            if (entry.pane_id == pane_id) return entry;
        }
        return null;
    }

    fn ensurePaneTagEntry(self: *App, pane_id: usize) !*PaneTagEntry {
        if (self.findPaneTagEntry(pane_id)) |entry| return entry;
        try self.pane_tags.append(self.allocator, .{ .pane_id = pane_id });
        return &self.pane_tags.items[self.pane_tags.items.len - 1];
    }

    fn normalizePaneTag(tag: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, tag, " \t\r\n");
        if (trimmed.len == 0) return null;
        return trimmed;
    }

    pub fn getPaneTags(self: *App, pane_id: usize) !std.json.Value {
        var array = std.json.Array.init(self.allocator);
        errdefer {
            for (array.items) |item| deinitJsonValue(self.allocator, item);
            array.deinit();
        }

        const entry = self.findPaneTagEntry(pane_id) orelse return .{ .array = array };
        var tags: std.ArrayListUnmanaged([]const u8) = .empty;
        defer tags.deinit(self.allocator);

        var it = entry.tags.iterator();
        while (it.next()) |item| try tags.append(self.allocator, item.key_ptr.*);
        std.mem.sort([]const u8, tags.items, {}, sortStringsAsc);
        for (tags.items) |tag| try appendOwnedJsonString(&array, self.allocator, tag);
        return .{ .array = array };
    }

    pub fn setPaneTags(self: *App, pane_id: usize, tags: []const []const u8) !void {
        const entry = try self.ensurePaneTagEntry(pane_id);
        entry.deinit(self.allocator);
        entry.* = .{ .pane_id = pane_id };

        for (tags) |tag| {
            const normalized = normalizePaneTag(tag) orelse continue;
            const gop = try entry.tags.getOrPut(self.allocator, normalized);
            if (!gop.found_existing) gop.key_ptr.* = try self.allocator.dupe(u8, normalized);
        }

        if (entry.tags.count() == 0) self.clearPaneTags(pane_id);
    }

    pub fn addPaneTag(self: *App, pane_id: usize, tag: []const u8) !void {
        const normalized = normalizePaneTag(tag) orelse return;
        const entry = try self.ensurePaneTagEntry(pane_id);
        const gop = try entry.tags.getOrPut(self.allocator, normalized);
        if (!gop.found_existing) gop.key_ptr.* = try self.allocator.dupe(u8, normalized);
    }

    pub fn removePaneTag(self: *App, pane_id: usize, tag: []const u8) void {
        const normalized = normalizePaneTag(tag) orelse return;
        const entry = self.findPaneTagEntry(pane_id) orelse return;
        const removed = entry.tags.fetchSwapRemove(normalized) orelse return;
        self.allocator.free(removed.key);
        if (entry.tags.count() == 0) self.clearPaneTags(pane_id);
    }

    pub fn clearPaneTags(self: *App, pane_id: usize) void {
        var index: usize = 0;
        while (index < self.pane_tags.items.len) : (index += 1) {
            if (self.pane_tags.items[index].pane_id != pane_id) continue;
            self.pane_tags.items[index].deinit(self.allocator);
            _ = self.pane_tags.swapRemove(index);
            return;
        }
    }

    fn executeCommand(self: *App, request: command_mod.Request) !command_mod.Response {
        return switch (request.kind) {
            .get_pane => .ok(try self.snapshotPaneValue(request.id orelse request.pane_id)),
            .get_pane_text => .ok(try self.paneTextValue(request.id orelse request.pane_id)),
            .get_current_pane => .ok(try self.currentPaneValue()),
            .get_tab => .ok(try self.snapshotTabValue(request.id)),
            .get_current_tab => .ok(try self.currentTabValue()),
            .get_tabs => .ok(try self.tabsValue()),
            .get_panes => .ok(try self.panesValue(request.tag)),
            .get_workspace => .ok(try self.snapshotWorkspaceValue(request.id)),
            .get_current_workspace => .ok(try self.currentWorkspaceValue()),
            .get_workspaces => .ok(try self.workspacesValue()),
            .get_domain => .ok(try self.currentDomainValue()),
            .workspace_new => self.execWorkspaceNew(request),
            .workspace_close => self.execWorkspaceClose(request),
            .workspace_next => self.execWorkspaceNext(),
            .workspace_prev => self.execWorkspacePrev(),
            .workspace_select => self.execWorkspaceSelect(request),
            .workspace_rename => self.execWorkspaceRename(request),
            .tab_new => self.execTabNew(request),
            .tab_close => self.execTabClose(request),
            .tab_next => self.execTabNext(),
            .tab_prev => self.execTabPrev(),
            .tab_select => self.execTabSelect(request),
            .tab_rename => self.execTabRename(request),
            .pane_split => self.execPaneSplit(request),
            .pane_popup => self.execPanePopup(request),
            .pane_close => self.execPaneClose(request),
            .pane_zoom => self.execPaneZoom(request),
            .pane_float => self.execPaneFloating(request, true),
            .pane_tile => self.execPaneFloating(request, false),
            .pane_move => self.execPaneMove(request),
            .pane_resize => self.execPaneResize(request),
            .pane_send_text, .send_keys => self.execPaneSendText(request),
            .pane_set_tag => self.execPaneSetTag(request),
            .pane_remove_tag => self.execPaneRemoveTag(request),
            .pane_set_tags => self.execPaneSetTags(request),
            .focus => self.execFocus(request),
            .scroll => self.execScroll(request),
            .get_htp => self.execGetHtp(request),
            .config_reload => self.execConfigReload(),
            .config_theme => self.execConfigTheme(request),
            .run => self.execRun(request),
            .emit => self.execEmit(request),
        };
    }

    fn commandIpcHandler(app_ptr: *anyopaque, request: command_mod.Request) command_mod.Response {
        const app: *App = @ptrCast(@alignCast(app_ptr));
        return app.runCommandSync(request);
    }

    fn okNull() command_mod.Response {
        return .ok(null);
    }

    fn execWorkspaceNew(self: *App, request: command_mod.Request) command_mod.Response {
        self.newWorkspace(request.cwd, request.domain, request.cmd, request.name, LUA_NOREF);
        return okNull();
    }

    fn execWorkspaceClose(self: *App, request: command_mod.Request) command_mod.Response {
        self.closeWorkspace(request.id);
        return okNull();
    }

    fn execWorkspaceNext(self: *App) command_mod.Response {
        self.nextWorkspace();
        return okNull();
    }

    fn execWorkspacePrev(self: *App) command_mod.Response {
        self.prevWorkspace();
        return okNull();
    }

    fn execWorkspaceSelect(self: *App, request: command_mod.Request) command_mod.Response {
        const index = request.index orelse return command_mod.Response.fail("invalid_args", "missing workspace index");
        self.switchWorkspace(index -| 1);
        return okNull();
    }

    fn execWorkspaceRename(self: *App, request: command_mod.Request) command_mod.Response {
        const name = request.name orelse return command_mod.Response.fail("invalid_args", "missing workspace name");
        if (request.id) |workspace_id| {
            const active_id = self.currentWorkspaceIdValue() orelse return command_mod.Response.fail("invalid_args", "no active workspace");
            if (active_id != workspace_id) return command_mod.Response.fail("invalid_args", "workspace rename only supports the active workspace");
        }
        self.setWorkspaceName(name);
        return okNull();
    }

    fn execTabNew(self: *App, request: command_mod.Request) command_mod.Response {
        self.newTab(request.domain, request.cmd, LUA_NOREF);
        return okNull();
    }

    fn execTabClose(self: *App, request: command_mod.Request) command_mod.Response {
        if (request.id) |tab_id| {
            const index = self.tabIndexById(tab_id) orelse return command_mod.Response.fail("invalid_args", "unknown tab id");
            self.closeTabAt(index);
        } else {
            self.closeTab();
        }
        return okNull();
    }

    fn execTabNext(self: *App) command_mod.Response {
        self.nextTab();
        return okNull();
    }

    fn execTabPrev(self: *App) command_mod.Response {
        self.prevTab();
        return okNull();
    }

    fn execTabSelect(self: *App, request: command_mod.Request) command_mod.Response {
        const tab_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing tab id");
        const index = self.tabIndexById(tab_id) orelse return command_mod.Response.fail("invalid_args", "unknown tab id");
        self.switchTab(index);
        return okNull();
    }

    fn execTabRename(self: *App, request: command_mod.Request) command_mod.Response {
        const title = request.name orelse return command_mod.Response.fail("invalid_args", "missing tab title");
        const tab_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing tab id");
        if (!self.setTabTitleById(tab_id, title)) return command_mod.Response.fail("invalid_args", "unknown tab id");
        return okNull();
    }

    fn execPaneClose(self: *App, request: command_mod.Request) command_mod.Response {
        const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
        self.closePaneById(pane_id);
        self.clearPaneTags(pane_id);
        return okNull();
    }

    fn execPaneSplit(self: *App, request: command_mod.Request) command_mod.Response {
        const direction_text = request.direction orelse return command_mod.Response.fail("invalid_args", "missing pane direction");
        const direction = parseSplitDirection(direction_text) orelse return command_mod.Response.fail("invalid_args", "invalid pane direction");
        self.splitPane(
            direction,
            @floatCast(request.ratio orelse 0.5),
            request.domain,
            request.cwd,
            request.cmd,
            .spawn,
            false,
            false,
            false,
            null,
            null,
            null,
            null,
            LUA_NOREF,
        );
        return okNull();
    }

    fn execPanePopup(self: *App, request: command_mod.Request) command_mod.Response {
        const cmd = request.cmd orelse return command_mod.Response.fail("invalid_args", "missing popup command");
        self.splitPane(
            .vertical,
            0.5,
            request.domain,
            request.cwd,
            cmd,
            .spawn,
            false,
            true,
            false,
            if (request.x) |value| @floatCast(value) else null,
            if (request.y) |value| @floatCast(value) else null,
            if (request.width) |value| @floatCast(value) else null,
            if (request.height) |value| @floatCast(value) else null,
            LUA_NOREF,
        );
        return okNull();
    }

    fn execPaneZoom(self: *App, request: command_mod.Request) command_mod.Response {
        const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
        self.togglePaneMaximizedById(pane_id, false);
        return okNull();
    }

    fn execPaneFloating(self: *App, request: command_mod.Request, floating: bool) command_mod.Response {
        const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
        self.setPaneFloatingById(pane_id, floating);
        return okNull();
    }

    fn parseFocusDirection(direction: []const u8) ?FocusDirection {
        if (std.mem.eql(u8, direction, "left")) return .left;
        if (std.mem.eql(u8, direction, "right")) return .right;
        if (std.mem.eql(u8, direction, "up")) return .up;
        if (std.mem.eql(u8, direction, "down")) return .down;
        return null;
    }

    fn parseSplitDirection(direction: []const u8) ?SplitDirection {
        if (std.mem.eql(u8, direction, "vertical") or std.mem.eql(u8, direction, "horizontal")) {
            return if (std.mem.eql(u8, direction, "horizontal")) .horizontal else .vertical;
        }
        if (std.mem.eql(u8, direction, "left") or std.mem.eql(u8, direction, "right")) return .horizontal;
        if (std.mem.eql(u8, direction, "up") or std.mem.eql(u8, direction, "down")) return .vertical;
        return null;
    }

    fn execPaneMove(self: *App, request: command_mod.Request) command_mod.Response {
        const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
        const direction = request.direction orelse return command_mod.Response.fail("invalid_args", "missing pane direction");
        const focus_direction = parseFocusDirection(direction) orelse return command_mod.Response.fail("invalid_args", "invalid pane direction");
        self.movePaneById(pane_id, focus_direction, @floatCast(request.amount orelse 0.08));
        return okNull();
    }

    fn execPaneResize(self: *App, request: command_mod.Request) command_mod.Response {
        const direction = request.direction orelse return command_mod.Response.fail("invalid_args", "missing pane direction");
        const split_direction = parseSplitDirection(direction) orelse return command_mod.Response.fail("invalid_args", "invalid pane direction");
        const amount = @as(f32, @floatCast(request.amount orelse 0));
        const delta: f32 = if (std.mem.eql(u8, direction, "left") or std.mem.eql(u8, direction, "up")) -@abs(amount) else @abs(amount);
        self.resizePane(split_direction, delta);
        return okNull();
    }

    fn execPaneSendText(self: *App, request: command_mod.Request) command_mod.Response {
        const text = request.text orelse return command_mod.Response.fail("invalid_args", "missing pane text");
        const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
        if (!self.sendTextToPane(pane_id, text)) return command_mod.Response.fail("invalid_args", "unknown pane id");
        return okNull();
    }

    fn execPaneSetTag(self: *App, request: command_mod.Request) command_mod.Response {
        const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
        const tag = request.tag orelse return command_mod.Response.fail("invalid_args", "missing pane tag");
        self.addPaneTag(pane_id, tag) catch return command_mod.Response.fail("internal", "failed to add pane tag");
        return okNull();
    }

    fn execPaneRemoveTag(self: *App, request: command_mod.Request) command_mod.Response {
        const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
        const tag = request.tag orelse return command_mod.Response.fail("invalid_args", "missing pane tag");
        self.removePaneTag(pane_id, tag);
        return okNull();
    }

    fn execPaneSetTags(self: *App, request: command_mod.Request) command_mod.Response {
        const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
        self.setPaneTags(pane_id, request.tags orelse &.{}) catch return command_mod.Response.fail("internal", "failed to set pane tags");
        return okNull();
    }

    fn execFocus(self: *App, request: command_mod.Request) command_mod.Response {
        const direction = request.direction orelse return command_mod.Response.fail("invalid_args", "missing focus direction");
        const focus_direction = parseFocusDirection(direction) orelse return command_mod.Response.fail("invalid_args", "invalid focus direction");
        self.focusPane(focus_direction);
        return okNull();
    }

    fn execScroll(self: *App, request: command_mod.Request) command_mod.Response {
        const target = request.direction orelse return command_mod.Response.fail("invalid_args", "missing scroll target");
        if (std.mem.eql(u8, target, "top")) {
            self.scrollActiveViewportTop();
        } else if (std.mem.eql(u8, target, "bottom")) {
            self.scrollActiveViewportBottom();
        } else if (std.mem.eql(u8, target, "page-up")) {
            self.scrollActiveViewportPage(-1);
        } else if (std.mem.eql(u8, target, "page-down")) {
            self.scrollActiveViewportPage(1);
        } else {
            return command_mod.Response.fail("invalid_args", "invalid scroll target");
        }
        return okNull();
    }

    fn execConfigReload(self: *App) command_mod.Response {
        if (!self.reloadConfig()) return command_mod.Response.fail("error", "reload_config failed");
        return okNull();
    }

    fn execConfigTheme(self: *App, request: command_mod.Request) command_mod.Response {
        const name = request.name orelse return command_mod.Response.fail("invalid_args", "missing theme name");
        const theme_payload = std.json.Value{ .object = blk: {
            var object = std.json.ObjectMap.init(self.allocator);
            errdefer deinitJsonValue(self.allocator, .{ .object = object });
            object.put(self.allocator.dupe(u8, "name") catch return command_mod.Response.fail("internal", "oom"), .{ .string = self.allocator.dupe(u8, name) catch return command_mod.Response.fail("internal", "oom") }) catch return command_mod.Response.fail("internal", "oom");
            break :blk object;
        } };
        defer deinitJsonValue(self.allocator, theme_payload);

        const result = self.dispatchHtpEventSync(self.currentPaneIdValue(), "set_theme", theme_payload) catch |err| {
            return command_mod.Response.fail("internal", @errorName(err));
        };
        defer result.deinit(self.allocator);
        if (!result.success) return command_mod.Response.fail("error", result.error_message orelse "set_theme failed");
        return okNull();
    }

    fn execRun(self: *App, request: command_mod.Request) command_mod.Response {
        self.newTab(request.domain, request.cmd, LUA_NOREF);
        return okNull();
    }

    fn execGetHtp(self: *App, request: command_mod.Request) command_mod.Response {
        const channel = request.channel orelse return command_mod.Response.fail("invalid_args", "missing htp channel");
        const pane_id = request.id orelse request.pane_id;
        const result = self.dispatchHtpQuerySync(pane_id, channel, request.params) catch |err| {
            return command_mod.Response.fail("internal", @errorName(err));
        };
        defer result.deinit(self.allocator);
        if (!result.success) return command_mod.Response.fail("error", result.error_message orelse "htp query failed");
        if (result.value) |value| {
            const cloned = command_mod.cloneJsonValue(self.allocator, value) catch return command_mod.Response.fail("internal", "failed to clone htp payload");
            return .ok(cloned);
        }
        return .ok(null);
    }

    fn execEmit(self: *App, request: command_mod.Request) command_mod.Response {
        const channel = request.channel orelse return command_mod.Response.fail("invalid_args", "missing emit channel");
        const pane_id = request.id orelse request.pane_id;
        const result = self.dispatchHtpEventSync(pane_id, channel, request.payload) catch |err| {
            return command_mod.Response.fail("internal", @errorName(err));
        };
        defer result.deinit(self.allocator);
        if (!result.success) return command_mod.Response.fail("error", result.error_message orelse "htp emit failed");
        return okNull();
    }

    fn currentPaneIdValue(self: *App) usize {
        const pane = self.activePane() orelse return 0;
        return @intFromPtr(pane);
    }

    fn currentWorkspaceIdValue(self: *App) ?usize {
        const workspace = self.activeWorkspace() orelse return null;
        return workspace.id;
    }

    fn domainValue(self: *App, name: []const u8) !std.json.Value {
        var object = std.json.ObjectMap.init(self.allocator);
        errdefer deinitJsonValue(self.allocator, .{ .object = object });

        try object.put(try self.allocator.dupe(u8, "name"), .{ .string = try dupeJsonSafeString(self.allocator, name) });
        try object.put(try self.allocator.dupe(u8, "is_active"), .{ .bool = std.mem.eql(u8, self.activePane().?.domain_name, name) });
        try object.put(try self.allocator.dupe(u8, "is_default"), .{ .bool = if (self.config.defaultDomainName()) |default_name| std.mem.eql(u8, default_name, name) else false });

        if (self.config.domainByName(name)) |domain| {
            if (domain.shell) |shell| try object.put(try self.allocator.dupe(u8, "shell"), .{ .string = try dupeJsonSafeString(self.allocator, shell) });
            if (domain.default_cwd) |cwd| try object.put(try self.allocator.dupe(u8, "default_cwd"), .{ .string = try dupeJsonSafeString(self.allocator, cwd) });
        }

        return .{ .object = object };
    }

    fn currentDomainValue(self: *App) !?std.json.Value {
        const pane = self.activePane() orelse return null;
        if (pane.domain_name.len == 0) return null;
        return try self.domainValue(pane.domain_name);
    }

    fn paneFrameValue(self: *App, pane: *Pane) !std.json.Value {
        var object = std.json.ObjectMap.init(self.allocator);
        errdefer deinitJsonValue(self.allocator, .{ .object = object });
        try object.put(try self.allocator.dupe(u8, "x"), .{ .integer = @intCast(pane.x_px) });
        try object.put(try self.allocator.dupe(u8, "y"), .{ .integer = @intCast(pane.y_px) });
        try object.put(try self.allocator.dupe(u8, "width"), .{ .integer = @intCast(pane.width_px) });
        try object.put(try self.allocator.dupe(u8, "height"), .{ .integer = @intCast(pane.height_px) });
        return .{ .object = object };
    }

    fn paneSizeValue(self: *App, pane: *Pane) !std.json.Value {
        var object = std.json.ObjectMap.init(self.allocator);
        errdefer deinitJsonValue(self.allocator, .{ .object = object });
        try object.put(try self.allocator.dupe(u8, "rows"), .{ .integer = @intCast(pane.rows) });
        try object.put(try self.allocator.dupe(u8, "cols"), .{ .integer = @intCast(pane.cols) });
        try object.put(try self.allocator.dupe(u8, "width"), .{ .integer = @intCast(pane.width_px) });
        try object.put(try self.allocator.dupe(u8, "height"), .{ .integer = @intCast(pane.height_px) });
        return .{ .object = object };
    }

    fn snapshotPane(self: *App, pane_id: usize) !?std.json.Value {
        const pane = self.findPaneById(pane_id) orelse return null;
        var object = std.json.ObjectMap.init(self.allocator);
        errdefer deinitJsonValue(self.allocator, .{ .object = object });

        try object.put(try self.allocator.dupe(u8, "id"), .{ .integer = @intCast(pane_id) });
        try object.put(try self.allocator.dupe(u8, "pid"), .{ .integer = @intCast(pane.childPid()) });
        try object.put(try self.allocator.dupe(u8, "domain"), .{ .string = try dupeJsonSafeString(self.allocator, pane.domain_name) });
        try object.put(try self.allocator.dupe(u8, "cwd"), .{ .string = try dupeJsonSafeString(self.allocator, pane.cwd) });
        try object.put(try self.allocator.dupe(u8, "title"), .{ .string = try dupeJsonSafeString(self.allocator, pane.title) });
        try object.put(try self.allocator.dupe(u8, "foreground_process"), .{ .string = try dupeJsonSafeString(self.allocator, pane.foreground_process orelse "") });
        try object.put(try self.allocator.dupe(u8, "tags"), try self.getPaneTags(pane_id));
        try object.put(try self.allocator.dupe(u8, "is_focused"), .{ .bool = self.currentPaneIdValue() == pane_id });
        try object.put(try self.allocator.dupe(u8, "is_floating"), .{ .bool = pane.is_floating });
        try object.put(try self.allocator.dupe(u8, "is_maximized"), .{ .bool = if (self.mux) |*mux| mux.paneIsMaximized(pane) else false });
        try object.put(try self.allocator.dupe(u8, "frame"), try self.paneFrameValue(pane));
        try object.put(try self.allocator.dupe(u8, "size"), try self.paneSizeValue(pane));
        return .{ .object = object };
    }

    fn snapshotPaneValue(self: *App, pane_id: usize) !?std.json.Value {
        if (pane_id == 0) return self.currentPaneValue();
        return try self.snapshotPane(pane_id);
    }

    fn currentPaneValue(self: *App) !?std.json.Value {
        const pane = self.activePane() orelse return null;
        return try self.snapshotPane(@intFromPtr(pane));
    }

    fn paneTextValue(self: *App, pane_id: usize) !std.json.Value {
        const buf = try self.allocator.alloc(u8, 256 * 1024);
        defer self.allocator.free(buf);
        const text = self.getPaneText(pane_id, buf);
        return .{ .string = try self.allocator.dupe(u8, text) };
    }

    fn snapshotTab(self: *App, tab: *Tab, index: usize) !std.json.Value {
        var panes = std.json.Array.init(self.allocator);
        errdefer deinitJsonValue(self.allocator, .{ .array = panes });
        for (tab.panes.items) |pane| {
            const pane_value = try self.snapshotPane(@intFromPtr(pane));
            if (pane_value) |value| try panes.append(value);
        }

        var object = std.json.ObjectMap.init(self.allocator);
        errdefer deinitJsonValue(self.allocator, .{ .object = object });
        const active_pane = tab.activePane();
        const pane_value = if (active_pane) |pane| try self.snapshotPane(@intFromPtr(pane)) else null;
        try object.put(try self.allocator.dupe(u8, "id"), .{ .integer = @intCast(tab.id) });
        try object.put(try self.allocator.dupe(u8, "title"), .{ .string = try dupeJsonSafeString(self.allocator, if (active_pane) |pane| pane.title else "") });
        try object.put(try self.allocator.dupe(u8, "index"), .{ .integer = @intCast(index + 1) });
        try object.put(try self.allocator.dupe(u8, "is_active"), .{ .bool = if (self.activeTab()) |active| active == tab else false });
        try object.put(try self.allocator.dupe(u8, "panes"), .{ .array = panes });
        if (pane_value) |value| {
            try object.put(try self.allocator.dupe(u8, "pane"), value);
        } else {
            try object.put(try self.allocator.dupe(u8, "pane"), .null);
        }
        return .{ .object = object };
    }

    fn snapshotTabValue(self: *App, tab_id: ?usize) !?std.json.Value {
        const id = tab_id orelse return self.currentTabValue();
        const workspace = self.activeWorkspace() orelse return null;
        for (workspace.tabs.items, 0..) |tab, index| {
            if (tab.id == id) return try self.snapshotTab(tab, index);
        }
        return null;
    }

    fn currentTabValue(self: *App) !?std.json.Value {
        const workspace = self.activeWorkspace() orelse return null;
        const tab = self.activeTab() orelse return null;
        for (workspace.tabs.items, 0..) |candidate, index| {
            if (candidate == tab) return try self.snapshotTab(candidate, index);
        }
        return null;
    }

    fn tabsValue(self: *App) !std.json.Value {
        var array = std.json.Array.init(self.allocator);
        errdefer deinitJsonValue(self.allocator, .{ .array = array });
        const workspace = self.activeWorkspace() orelse return .{ .array = array };
        for (workspace.tabs.items, 0..) |tab, index| try array.append(try self.snapshotTab(tab, index));
        return .{ .array = array };
    }

    fn panesValue(self: *App, wanted_tag: ?[]const u8) !std.json.Value {
        var array = std.json.Array.init(self.allocator);
        errdefer deinitJsonValue(self.allocator, .{ .array = array });
        if (self.mux) |*mux| {
            var panes = mux.paneIterator();
            while (panes.next()) |pane| {
                const pane_id = @intFromPtr(pane);
                if (wanted_tag) |tag| {
                    const entry = self.findPaneTagEntry(pane_id) orelse continue;
                    if (!entry.tags.contains(tag)) continue;
                }
                const pane_value = try self.snapshotPane(pane_id);
                if (pane_value) |value| try array.append(value);
            }
        }
        return .{ .array = array };
    }

    fn snapshotWorkspace(self: *App, workspace: *Workspace, index: usize) !std.json.Value {
        var object = std.json.ObjectMap.init(self.allocator);
        errdefer deinitJsonValue(self.allocator, .{ .object = object });
        try object.put(try self.allocator.dupe(u8, "id"), .{ .integer = @intCast(workspace.id) });
        try object.put(try self.allocator.dupe(u8, "index"), .{ .integer = @intCast(index + 1) });
        try object.put(try self.allocator.dupe(u8, "name"), .{ .string = try self.allocator.dupe(u8, workspace.title()) });
        if (workspace.activeTab()) |tab| {
            if (tab.activePane()) |pane| {
                try object.put(try self.allocator.dupe(u8, "domain"), .{ .string = try dupeJsonSafeString(self.allocator, pane.domain_name) });
            } else {
                try object.put(try self.allocator.dupe(u8, "domain"), .null);
            }
        } else {
            try object.put(try self.allocator.dupe(u8, "domain"), .null);
        }
        try object.put(try self.allocator.dupe(u8, "is_active"), .{ .bool = if (self.activeWorkspace()) |active| active == workspace else false });
        return .{ .object = object };
    }

    fn snapshotWorkspaceValue(self: *App, workspace_id: ?usize) !?std.json.Value {
        const id = workspace_id orelse return self.currentWorkspaceValue();
        if (self.mux) |*mux| {
            for (mux.workspaces.items, 0..) |workspace, index| {
                if (workspace.id == id) return try self.snapshotWorkspace(workspace, index);
            }
        }
        return null;
    }

    fn currentWorkspaceValue(self: *App) !?std.json.Value {
        if (self.mux) |*mux| {
            const workspace = mux.activeWorkspace() orelse return null;
            return try self.snapshotWorkspace(workspace, mux.activeWorkspaceIndex());
        }
        return null;
    }

    fn workspacesValue(self: *App) !std.json.Value {
        var array = std.json.Array.init(self.allocator);
        errdefer deinitJsonValue(self.allocator, .{ .array = array });
        if (self.mux) |*mux| {
            for (mux.workspaces.items, 0..) |workspace, index| {
                try array.append(try self.snapshotWorkspace(workspace, index));
            }
        }
        return .{ .array = array };
    }

    pub fn init(allocator: std.mem.Allocator) App {
        return .{
            .allocator = allocator,
            .config = Config.init(allocator),
        };
    }

    pub fn shutdownRuntime(self: *App) void {
        if (self.deinitialized) return;
        std.log.info("App.shutdownRuntime begin", .{});

        write_bridge = null;
        size_bridge = null;
        attrs_bridge = null;
        title_bridge = null;
        htp_bridge = null;
        wake_bridge = null;

        if (self.command_ipc_server) |*server| {
            server.deinit();
            self.command_ipc_server = null;
        }

        if (self.renderer) |*renderer| {
            renderer.deinit();
            self.renderer = null;
        }

        if (self.ghostty) |*runtime| {
            if (self.mux) |*mux| {
                std.log.info("App.shutdownRuntime mux.deinit", .{});
                mux.deinit(runtime);
                self.mux = null;
            }
            runtime.deinit();
            self.ghostty = null;
        }

        if (self.lua) |*lua| {
            lua.deinit();
            self.lua = null;
        }

        std.log.info("App.shutdownRuntime done", .{});
    }

    pub fn deinit(self: *App) void {
        if (self.deinitialized) return;
        self.deinitialized = true;
        std.log.info("App.deinit begin", .{});

        self.shutdownRuntime();
        self.deinitCopyModeState();

        for (self.htp_pending_messages.items) |message| {
            self.allocator.free(message.payload);
        }
        self.htp_pending_messages.deinit(self.allocator);
        for (self.htp_chunk_assemblies.items) |*assembly| {
            self.allocator.free(assembly.request_id);
            assembly.buffer.deinit(self.allocator);
        }
        self.htp_chunk_assemblies.deinit(self.allocator);
        for (self.pane_tags.items) |*entry| entry.deinit(self.allocator);
        self.pane_tags.deinit(self.allocator);

        if (self.base_config_path) |path| {
            self.allocator.free(path);
            self.base_config_path = null;
        }
        if (self.override_config_path) |path| {
            self.allocator.free(path);
            self.override_config_path = null;
        }
        if (self.snapshot_dump_file) |file| {
            file.close();
            self.snapshot_dump_file = null;
        }
        if (self.snapshot_dump_path) |path| {
            self.allocator.free(path);
            self.snapshot_dump_path = null;
        }
        if (self.startup_command) |cmd| {
            self.allocator.free(cmd);
            self.startup_command = null;
        }
        self.config.deinit();
        std.log.info("App.deinit done", .{});
    }

    pub fn configureAutomation(self: *App, startup_command: ?[]const u8, startup_command_delay_frames: usize, snapshot_dump_path: ?[]const u8) !void {
        if (startup_command) |cmd| {
            if (self.startup_command) |owned| self.allocator.free(owned);
            self.startup_command = try self.allocator.dupe(u8, cmd);
            self.startup_command_delay_frames = startup_command_delay_frames;
            self.startup_command_sent = false;
        }

        if (snapshot_dump_path) |path| {
            if (self.snapshot_dump_file) |file| file.close();
            self.snapshot_dump_file = null;
            if (self.snapshot_dump_path) |owned| self.allocator.free(owned);
            self.snapshot_dump_path = try self.allocator.dupe(u8, path);
            self.snapshot_dump_file = try std.fs.cwd().createFile(path, .{ .truncate = true });
            self.snapshot_dump_last_hash = 0;
            self.snapshot_dump_has_last_hash = false;
        }
    }

    fn deinitCopyModeState(self: *App) void {
        for (self.copy_mode_history.items) |line| {
            if (line.text.len > 0) self.allocator.free(line.text);
            for (line.cells) |cell| {
                if (cell.text.len > 0) self.allocator.free(cell.text);
            }
            if (line.cells.len > 0) self.allocator.free(line.cells);
            if (line.col_offsets.len > 0) self.allocator.free(line.col_offsets);
        }
        self.copy_mode_history.deinit(self.allocator);
        self.copy_mode_matches.deinit(self.allocator);
        if (self.copy_mode_query.len > 0) {
            self.allocator.free(self.copy_mode_query);
            self.copy_mode_query = &.{};
        }
        self.copy_mode_pane = null;
        self.copy_mode_anchor = null;
        self.copy_mode_match_index = null;
        self.copy_mode_active = false;
        self.copy_mode_needs_refresh = false;
    }

    pub fn bootstrap(self: *App, config_override: ?[]const u8) !void {
        const config_paths = try self.resolveConfigPaths(config_override);
        self.using_embedded_base_config = config_paths.use_embedded_base;
        self.base_config_path = config_paths.base;
        self.override_config_path = config_paths.override;

        self.tryInitLua();
        std.log.info("config: command_timing={}", .{self.config.command_timing});
        self.syncCommandTimingEnv();

        var runtime = try GhosttyRuntime.init(self.allocator, null);
        errdefer runtime.deinit();
        _ = runtime.setSysUserdata(null);
        _ = runtime.setSysDecodePng(hollow_decode_png);

        var mux = Mux.init(self.allocator);
        errdefer mux.deinit(&runtime);

        // Set bridge globals before bootstrapSingle so the callbacks are valid
        // the moment ghostty can first invoke them (during resizeTerminal inside
        // bootstrap).
        write_bridge = self;
        size_bridge = self;
        attrs_bridge = self;
        title_bridge = self;
        htp_bridge = self;
        wake_bridge = self;
        self.startCommandTransport();
        const cbs = terminalCallbacks();
        try mux.bootstrapSingle(&runtime, cbs, self.config, self.cell_width_px, self.cell_height_px, self.config.window_width, self.config.window_height);

        self.ghostty = runtime;
        self.mux = mux;
        self.bindHtpHandlers();
        self.renderer = Backend.init(self.allocator, self.config);

        // Register app action callbacks so Lua can call split_pane etc.
        if (self.lua) |*lua| {
            self.registerLuaCallbacks(lua);
        }

        try self.tick();
    }

    pub fn fireGuiReady(self: *App) void {
        if (self.lua) |*lua| lua.fireGuiReady();
    }

    pub fn emitLuaBuiltInEvent(self: *App, name: []const u8, payload: lua_mod.BuiltInPayload) void {
        if (self.lua) |*lua| lua.emitBuiltInEvent(name, payload);
    }

    fn registerLuaCallbacks(self: *App, lua: *LuaRuntime) void {
        lua.registerAppCallbacks(.{
            .app = self,
            .refresh_live_config = luaRefreshLiveConfigCallback,
            .split_pane = luaSplitPaneCallback,
            .toggle_pane_maximized = luaTogglePaneMaximizedCallback,
            .set_pane_floating = luaSetPaneFloatingCallback,
            .set_floating_pane_bounds = luaSetFloatingPaneBoundsCallback,
            .set_pane_foreground_process = luaSetPaneForegroundProcessCallback,
            .move_pane = luaMovePaneCallback,
            .new_tab = luaNewTabCallback,
            .close_tab = luaCloseTabCallback,
            .close_pane = luaClosePaneCallback,
            .next_tab = luaNextTabCallback,
            .prev_tab = luaPrevTabCallback,
            .new_workspace = luaNewWorkspaceCallback,
            .close_workspace = luaCloseWorkspaceCallback,
            .next_workspace = luaNextWorkspaceCallback,
            .prev_workspace = luaPrevWorkspaceCallback,
            .switch_workspace = luaSwitchWorkspaceCallback,
            .focus_pane = luaFocusPaneCallback,
            .focus_pane_by_id = luaFocusPaneByIdCallback,
            .resize_pane = luaResizePaneCallback,
            .switch_tab = luaSwitchTabCallback,
            .set_workspace_name = luaSetWorkspaceNameCallback,
            .set_workspace_default_cwd = luaSetWorkspaceDefaultCwdCallback,
            .set_tab_title = luaSetTabTitleCallback,
            .set_tab_title_by_id = luaSetTabTitleByIdCallback,
            .reload_config = luaReloadConfigCallback,
            .get_tab_count = luaGetTabCountCallback,
            .get_active_tab_index = luaGetActiveTabIndexCallback,
            .get_current_tab_id = luaCurrentTabIdCallback,
            .get_current_pane_id = luaCurrentPaneIdCallback,
            .get_tab_id_at = luaGetTabIdAtCallback,
            .get_tab_pane_count = luaGetTabPaneCountCallback,
            .get_tab_pane_id_at = luaGetTabPaneIdAtCallback,
            .get_tab_active_pane_id = luaGetTabActivePaneIdCallback,
            .get_tab_index_by_id = luaGetTabIndexByIdCallback,
            .get_workspace_count = luaGetWorkspaceCountCallback,
            .get_active_workspace_index = luaGetActiveWorkspaceIndexCallback,
            .get_workspace_id = luaGetWorkspaceIdCallback,
            .get_workspace_name = luaGetWorkspaceNameCallback,
            .get_pane_pid = luaGetPanePidCallback,
            .get_pane_title = luaGetPaneTitleCallback,
            .get_pane_cwd = luaGetPaneCwdCallback,
            .get_pane_text = luaGetPaneTextCallback,
            .get_pane_foreground_process = luaGetPaneForegroundProcessCallback,
            .get_pane_rows = luaGetPaneRowsCallback,
            .get_pane_cols = luaGetPaneColsCallback,
            .get_pane_x = luaGetPaneXCallback,
            .get_pane_y = luaGetPaneYCallback,
            .get_pane_width = luaGetPaneWidthCallback,
            .get_pane_height = luaGetPaneHeightCallback,
            .get_window_width = luaGetWindowWidthCallback,
            .get_window_height = luaGetWindowHeightCallback,
            .now_ms = luaNowMsCallback,
            .pane_is_floating = luaPaneIsFloatingCallback,
            .pane_is_maximized = luaPaneIsMaximizedCallback,
            .pane_is_focused = luaPaneIsFocusedCallback,
            .pane_exists = luaPaneExistsCallback,
            .switch_tab_by_id = luaSwitchTabByIdCallback,
            .close_tab_by_id = luaCloseTabByIdCallback,
            .close_pane_by_id = luaClosePaneByIdCallback,
            .send_text_to_pane = luaSendTextToPaneCallback,
            .get_pane_domain = luaGetPaneDomainCallback,
            .is_leader_active = luaIsLeaderActiveCallback,
            .set_leader_state = luaSetLeaderStateCallback,
            .set_bar_cache_state = luaSetBarCacheStateCallback,
            .copy_selection = luaCopySelectionCallback,
            .paste_clipboard = luaPasteClipboardCallback,
            .scroll_active = luaScrollActiveCallback,
            .scroll_active_page = luaScrollActivePageCallback,
            .scroll_active_top = luaScrollActiveTopCallback,
            .scroll_active_bottom = luaScrollActiveBottomCallback,
            .prompt_jump = luaPromptJumpCallback,
            .copy_mode_enter = luaCopyModeEnterCallback,
            .copy_mode_exit = luaCopyModeExitCallback,
            .copy_mode_move = luaCopyModeMoveCallback,
            .copy_mode_begin_selection = luaCopyModeBeginSelectionCallback,
            .copy_mode_clear_selection = luaCopyModeClearSelectionCallback,
            .copy_mode_copy = luaCopyModeCopyCallback,
            .copy_mode_open_search = luaCopyModeOpenSearchCallback,
            .copy_mode_search_set_query = luaCopyModeSearchSetQueryCallback,
            .copy_mode_search_next = luaCopyModeSearchNextCallback,
            .copy_mode_search_prev = luaCopyModeSearchPrevCallback,
        });
    }

    fn tryInitLua(self: *App) void {
        self.leader_visual_active = false;
        self.leader_visual_expires_at_ns = 0;
        self.topbar_cache_dirty = true;
        self.topbar_cache_expires_at_ns = 0;
        self.bottombar_cache_dirty = true;
        self.bottombar_cache_expires_at_ns = 0;
        self.next_idle_render_poll_ns = 0;
        var lua = LuaRuntime.init(self.allocator, &self.config) catch |err| {
            std.log.warn("LuaJIT unavailable, continuing without scripting: {s}", .{@errorName(err)});
            return;
        };

        const core_lua = @embedFile("lua/core.lua");
        lua.runEmbeddedLuaFile("core.lua", core_lua, "core.lua") catch |err| {
            std.log.warn("failed to bootstrap lua core, scripting may be broken: {s}", .{@errorName(err)});
        };

        if (self.using_embedded_base_config) {
            lua.runEmbeddedProjectFile("conf/init.lua", embedded_base_config, "conf/init.lua") catch |err| {
                std.log.warn("embedded base config load failed, continuing with compiled defaults: {s}", .{@errorName(err)});
            };
        } else if (self.base_config_path) |path| {
            lua.runFile(path) catch |err| {
                std.log.warn("base config load failed, continuing with compiled defaults: {s}", .{@errorName(err)});
            };
        }

        if (self.override_config_path) |path| {
            lua.runFile(path) catch |err| {
                std.log.warn("override config load failed, continuing with base config: {s}", .{@errorName(err)});
            };
        }

        self.lua = lua;
    }

    pub fn tick(self: *App) !void {
        var cleanup_ns: i128 = 0;
        var prune_ns: i128 = 0;
        var events_ns: i128 = 0;
        var htp_ns: i128 = 0;
        var resize_ns: i128 = 0;
        var layout_ns: i128 = 0;
        var tick_panes_ns: i128 = 0;
        var hover_ns: i128 = 0;
        var startup_ns: i128 = 0;

        // Clean up dead panes BEFORE draining the mouse queue so that mouse
        // events never dispatch to panes whose PTY has already exited.  This
        // also invalidates any cached SplitNode pointers (g_drag_node,
        // pending_split_ratio_node) that referenced freed tree nodes, which
        // the validation in handleMouseMove / flushPendingLayoutResize will
        // detect and discard.
        if (self.ghostty) |*runtime| {
            const start_ns = if (self.config.debug_overlay) std.time.nanoTimestamp() else 0;
            self.cleanupDeadPanes(runtime);
            if (self.config.debug_overlay) cleanup_ns = std.time.nanoTimestamp() - start_ns;
        }
        {
            const start_ns = if (self.config.debug_overlay) std.time.nanoTimestamp() else 0;
            self.pruneSelectionIfInvalid();
            self.pruneCopyModeIfInvalid();
            if (self.config.debug_overlay) prune_ns = std.time.nanoTimestamp() - start_ns;
        }
        {
            const start_ns = if (self.config.debug_overlay) std.time.nanoTimestamp() else 0;
            if (self.lua) |*lua| lua.runDeferredCallbacks();
            if (self.config.debug_overlay) events_ns = std.time.nanoTimestamp() - start_ns;
        }
        {
            const start_ns = if (self.config.debug_overlay) std.time.nanoTimestamp() else 0;
            self.drainMouseQueue();
            if (self.config.debug_overlay) events_ns = std.time.nanoTimestamp() - start_ns;
        }
        {
            const start_ns = if (self.config.debug_overlay) std.time.nanoTimestamp() else 0;
            self.processHtpMessages();
            if (self.config.debug_overlay) htp_ns = std.time.nanoTimestamp() - start_ns;
        }
        {
            const start_ns = if (self.config.debug_overlay) std.time.nanoTimestamp() else 0;
            self.flushPendingResize();
            if (self.config.debug_overlay) resize_ns = std.time.nanoTimestamp() - start_ns;
        }
        {
            const start_ns = if (self.config.debug_overlay) std.time.nanoTimestamp() else 0;
            self.flushPendingLayoutResize();
            if (self.config.debug_overlay) layout_ns = std.time.nanoTimestamp() - start_ns;
        }
        if (self.ghostty) |*runtime| {
            const start_ns = if (self.config.debug_overlay) std.time.nanoTimestamp() else 0;
            try self.tickPanes(runtime);
            if (self.config.debug_overlay) tick_panes_ns = std.time.nanoTimestamp() - start_ns;
        }
        {
            const start_ns = if (self.config.debug_overlay) std.time.nanoTimestamp() else 0;
            self.updateHoveredHyperlink();
            if (self.config.debug_overlay) hover_ns = std.time.nanoTimestamp() - start_ns;
        }
        {
            const start_ns = if (self.config.debug_overlay) std.time.nanoTimestamp() else 0;
            self.maybeRunStartupCommand();
            if (self.config.debug_overlay) startup_ns = std.time.nanoTimestamp() - start_ns;
        }
        debug_timing.setTickPhaseTimes(
            @as(f32, @floatFromInt(cleanup_ns)) / 1_000_000.0,
            @as(f32, @floatFromInt(prune_ns)) / 1_000_000.0,
            @as(f32, @floatFromInt(events_ns)) / 1_000_000.0,
            @as(f32, @floatFromInt(htp_ns)) / 1_000_000.0,
            @as(f32, @floatFromInt(resize_ns)) / 1_000_000.0,
            @as(f32, @floatFromInt(layout_ns)) / 1_000_000.0,
            @as(f32, @floatFromInt(tick_panes_ns)) / 1_000_000.0,
            @as(f32, @floatFromInt(hover_ns)) / 1_000_000.0,
            @as(f32, @floatFromInt(startup_ns)) / 1_000_000.0,
        );
        if (!self.logged_first_render_update) self.logged_first_render_update = true;
        self.frame_count += 1;
    }

    pub fn hasVisualActivity(self: *App) bool {
        return self.hasVisualActivityAt(std.time.nanoTimestamp(), true);
    }

    fn hasVisualActivityAt(self: *App, now_ns: i128, check_panes: bool) bool {
        const recent_input_grace_ns: i128 = 24_000_000;
        const recent_visual_grace_ns: i128 = 16_000_000;
        if (self.last_input_activity_ns != 0 and now_ns - self.last_input_activity_ns < recent_input_grace_ns) {
            return true;
        }
        if (self.last_visual_activity_ns != 0 and now_ns - self.last_visual_activity_ns < recent_visual_grace_ns) {
            return true;
        }
        if (self.pending_resize or self.pending_layout_resize or self.pending_drag_layout_resize or self.pending_quit) {
            self.last_visual_activity_ns = now_ns;
            return true;
        }
        if (self.mouse_queue_head != @atomicLoad(usize, &self.mouse_queue_tail, .acquire)) {
            self.last_visual_activity_ns = now_ns;
            return true;
        }
        if (self.htp_pending_messages.items.len > 0) {
            self.last_visual_activity_ns = now_ns;
            return true;
        }
        if (self.selection_drag_active or self.hovered_tab_index != null or self.hovered_close_tab_index != null) {
            self.last_visual_activity_ns = now_ns;
            return true;
        }
        if (self.leaderVisualActive(now_ns)) {
            self.last_visual_activity_ns = now_ns;
            return true;
        }
        if (self.startup_command != null and !self.startup_command_sent and self.frame_count >= self.startup_command_delay_frames) {
            self.last_visual_activity_ns = now_ns;
            return true;
        }
        if (self.barCacheNeedsRefresh(.topbar, now_ns) or self.barCacheNeedsRefresh(.bottombar, now_ns)) {
            self.last_visual_activity_ns = now_ns;
            return true;
        }
        if (self.next_idle_render_poll_ns != 0 and now_ns >= self.next_idle_render_poll_ns) {
            self.last_visual_activity_ns = now_ns;
            return true;
        }
        if (check_panes) {
            if (self.mux) |*mux| {
                var panes = mux.paneIterator();
                while (panes.next()) |pane| {
                    if (pane.render_dirty != .false_value or pane.pty_received_data or pane.pty_wrote_this_frame or pane.title_dirty or pane.cwd_dirty) {
                        self.last_visual_activity_ns = now_ns;
                        return true;
                    }
                }
            }
        }
        return false;
    }

    fn leaderVisualActive(self: *App, now_ns: i128) bool {
        if (!self.leader_visual_active) return false;
        if (self.leader_visual_expires_at_ns != 0 and now_ns > self.leader_visual_expires_at_ns) {
            self.leader_visual_active = false;
            self.leader_visual_expires_at_ns = 0;
            return false;
        }
        return true;
    }

    pub fn setLeaderState(self: *App, active: bool, expires_at_ms: i64) void {
        if (!active or expires_at_ms <= 0) {
            self.leader_visual_active = false;
            self.leader_visual_expires_at_ns = 0;
            return;
        }
        self.leader_visual_active = true;
        self.leader_visual_expires_at_ns = @as(i128, expires_at_ms) * std.time.ns_per_ms;
    }

    pub fn setBarCacheState(self: *App, surface: BarSurface, dirty: bool, expires_at_ms: i64, visible: bool) void {
        const expires_at_ns: i128 = if (expires_at_ms > 0) @as(i128, expires_at_ms) * std.time.ns_per_ms else 0;
        const was_visible = switch (surface) {
            .topbar => self.topbar_cache_visible,
            .bottombar => self.bottombar_cache_visible,
        };
        switch (surface) {
            .topbar => {
                self.topbar_cache_visible = visible;
                self.topbar_cache_dirty = dirty;
                self.topbar_cache_expires_at_ns = expires_at_ns;
            },
            .bottombar => {
                self.bottombar_cache_visible = visible;
                self.bottombar_cache_dirty = dirty;
                self.bottombar_cache_expires_at_ns = expires_at_ns;
            },
        }
        if (was_visible != visible) self.requestLayoutRefresh();
    }

    pub fn barCacheNeedsRefresh(self: *App, surface: BarSurface, now_ns: i128) bool {
        return switch (surface) {
            .topbar => self.topbar_cache_dirty or (self.topbar_cache_expires_at_ns != 0 and now_ns >= self.topbar_cache_expires_at_ns),
            .bottombar => self.bottombar_cache_dirty or (self.bottombar_cache_expires_at_ns != 0 and now_ns >= self.bottombar_cache_expires_at_ns),
        };
    }

    pub fn nextIdleWakeNs(self: *const App) i128 {
        var next_wake_ns = self.next_idle_render_poll_ns;
        if (self.leader_visual_active and self.leader_visual_expires_at_ns != 0) {
            next_wake_ns = minWakeNs(next_wake_ns, self.leader_visual_expires_at_ns);
        }
        if (self.topbar_cache_expires_at_ns != 0) {
            next_wake_ns = minWakeNs(next_wake_ns, self.topbar_cache_expires_at_ns);
        }
        if (self.bottombar_cache_expires_at_ns != 0) {
            next_wake_ns = minWakeNs(next_wake_ns, self.bottombar_cache_expires_at_ns);
        }
        return next_wake_ns;
    }

    pub fn signalWake(self: *App) void {
        _ = self.wake_generation.fetchAdd(1, .release);
        self.last_visual_activity_ns = std.time.nanoTimestamp();
    }

    pub fn currentWakeGeneration(self: *const App) u32 {
        return self.wake_generation.load(.acquire);
    }

    fn minWakeNs(current: i128, candidate: i128) i128 {
        if (candidate == 0) return current;
        if (current == 0 or candidate < current) return candidate;
        return current;
    }

    fn recordPointerState(self: *App, x: f32, y: f32, mods: u32) void {
        if (self.pointer_x != x or self.pointer_y != y) self.hover_probe_dirty = true;
        self.pointer_x = x;
        self.pointer_y = y;
        self.pointer_mods = mods;
    }

    fn processHtpMessages(self: *App) void {
        while (self.htp_pending_messages.items.len > 0) {
            const message = self.htp_pending_messages.orderedRemove(0);
            defer self.allocator.free(message.payload);
            const pane = self.findPaneById(message.pane_id) orelse {
                self.removeChunkAssembliesForPane(message.pane_id);
                continue;
            };
            self.handleHtpMessage(pane, message.payload);
        }
    }

    fn handleHtpMessage(self: *App, pane: *Pane, payload: []const u8) void {
        std.log.info("htp: handle pane={x} payload={s}", .{ @intFromPtr(pane), payload });
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{ .ignore_unknown_fields = true }) catch |err| {
            self.sendHtpProtocolError(pane, null, "invalid_json", @errorName(err));
            return;
        };
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |object| object,
            else => {
                self.sendHtpProtocolError(pane, null, "invalid_message", "root JSON value must be an object");
                return;
            },
        };

        const kind = jsonObjectString(root, "kind") orelse jsonObjectString(root, "type") orelse {
            self.sendHtpProtocolError(pane, null, "invalid_message", "missing kind");
            return;
        };
        const message_id = jsonObjectString(root, "id");

        if (std.mem.eql(u8, kind, "chunk")) {
            self.handleHtpChunk(pane, message_id, root);
            return;
        }

        if (std.mem.eql(u8, kind, "event")) {
            const channel = jsonObjectString(root, "name") orelse jsonObjectString(root, "channel") orelse {
                self.sendHtpProtocolError(pane, message_id, "invalid_message", "event message missing name");
                return;
            };
            const payload_value = jsonObjectValueClone(self.allocator, root, "payload") catch |err| {
                self.sendHtpProtocolError(pane, message_id, "internal", @errorName(err));
                return;
            };
            defer if (payload_value) |value| deinitJsonValue(self.allocator, value);
            self.dispatchHtpEvent(pane, message_id, channel, payload_value);
            return;
        }

        if (std.mem.eql(u8, kind, "query")) {
            const channel = jsonObjectString(root, "name") orelse jsonObjectString(root, "channel") orelse {
                self.sendHtpProtocolError(pane, message_id, "invalid_message", "query message missing name");
                return;
            };
            const request_id = jsonObjectString(root, "request_id") orelse message_id;
            const params_value = jsonObjectValueClone(self.allocator, root, "params") catch |err| {
                self.sendHtpQueryError(pane, message_id, request_id, "internal", @errorName(err));
                return;
            };
            defer if (params_value) |value| deinitJsonValue(self.allocator, value);
            self.dispatchHtpQuery(pane, message_id, request_id, channel, params_value);
            return;
        }

        self.sendHtpProtocolError(pane, message_id, "invalid_message", "unknown kind");
    }

    fn handleHtpChunk(self: *App, pane: *Pane, message_id: ?[]const u8, root: std.json.ObjectMap) void {
        const request_id = jsonObjectString(root, "request_id") orelse {
            self.sendHtpProtocolError(pane, message_id, "invalid_message", "chunk missing request_id");
            return;
        };
        const payload_value = jsonObjectValue(root, "payload") orelse {
            self.sendHtpProtocolError(pane, message_id, "invalid_message", "chunk missing payload");
            return;
        };
        const payload_object = switch (payload_value) {
            .object => |obj| obj,
            else => {
                self.sendHtpProtocolError(pane, message_id, "invalid_message", "chunk payload must be an object");
                return;
            },
        };
        const index = jsonObjectIndex(payload_object, "index") orelse {
            self.sendHtpProtocolError(pane, message_id, "invalid_message", "chunk missing index");
            return;
        };
        const total = jsonObjectIndex(payload_object, "total") orelse {
            self.sendHtpProtocolError(pane, message_id, "invalid_message", "chunk missing total");
            return;
        };
        const data = jsonObjectString(payload_object, "data") orelse {
            self.sendHtpProtocolError(pane, message_id, "invalid_message", "chunk missing data");
            return;
        };
        if (index == 0 or total == 0 or index > total) {
            self.sendHtpProtocolError(pane, message_id, "invalid_message", "chunk index out of range");
            return;
        }

        var assembly = self.findOrCreateChunkAssembly(pane, request_id, total) catch |err| {
            self.sendHtpProtocolError(pane, message_id, "internal", @errorName(err));
            return;
        };
        if (assembly.total != total or assembly.next_index != index) {
            self.resetChunkAssembly(assembly);
            self.sendHtpProtocolError(pane, message_id, "invalid_message", "unexpected chunk order");
            return;
        }
        assembly.buffer.appendSlice(self.allocator, data) catch |err| {
            self.resetChunkAssembly(assembly);
            self.sendHtpProtocolError(pane, message_id, "internal", @errorName(err));
            return;
        };
        assembly.next_index += 1;
        if (index < total) return;

        const joined = self.allocator.dupe(u8, assembly.buffer.items) catch |err| {
            self.resetChunkAssembly(assembly);
            self.sendHtpProtocolError(pane, message_id, "internal", @errorName(err));
            return;
        };
        defer self.allocator.free(joined);
        self.removeChunkAssembly(pane, request_id);
        self.handleHtpMessage(pane, joined);
    }

    fn findOrCreateChunkAssembly(self: *App, pane: *Pane, request_id: []const u8, total: usize) !*HtpChunkAssembly {
        for (self.htp_chunk_assemblies.items) |*assembly| {
            if (assembly.pane_id == @intFromPtr(pane) and std.mem.eql(u8, assembly.request_id, request_id)) return assembly;
        }
        const request_id_owned = try self.allocator.dupe(u8, request_id);
        errdefer self.allocator.free(request_id_owned);
        try self.htp_chunk_assemblies.append(self.allocator, .{
            .pane_id = @intFromPtr(pane),
            .request_id = request_id_owned,
            .total = total,
            .next_index = 1,
        });
        return &self.htp_chunk_assemblies.items[self.htp_chunk_assemblies.items.len - 1];
    }

    fn resetChunkAssembly(self: *App, assembly: *HtpChunkAssembly) void {
        _ = self;
        assembly.buffer.clearRetainingCapacity();
        assembly.next_index = 1;
    }

    fn removeChunkAssembly(self: *App, pane: *Pane, request_id: []const u8) void {
        var index: usize = 0;
        while (index < self.htp_chunk_assemblies.items.len) : (index += 1) {
            const assembly = &self.htp_chunk_assemblies.items[index];
            if (assembly.pane_id != @intFromPtr(pane) or !std.mem.eql(u8, assembly.request_id, request_id)) continue;
            self.allocator.free(assembly.request_id);
            assembly.buffer.deinit(self.allocator);
            _ = self.htp_chunk_assemblies.swapRemove(index);
            return;
        }
    }

    fn removeChunkAssembliesForPane(self: *App, pane_id: usize) void {
        var index: usize = 0;
        while (index < self.htp_chunk_assemblies.items.len) {
            const assembly = &self.htp_chunk_assemblies.items[index];
            if (assembly.pane_id != pane_id) {
                index += 1;
                continue;
            }
            self.allocator.free(assembly.request_id);
            assembly.buffer.deinit(self.allocator);
            _ = self.htp_chunk_assemblies.swapRemove(index);
        }
    }

    fn dispatchHtpEvent(self: *App, pane: *Pane, message_id: ?[]const u8, channel: []const u8, payload: ?std.json.Value) void {
        std.log.info("htp: dispatch event pane={x} channel={s}", .{ @intFromPtr(pane), channel });
        const lua = if (self.lua) |*value| value else {
            self.sendHtpProtocolError(pane, message_id, "unavailable", "lua runtime unavailable");
            return;
        };

        const ok = lua.dispatchHtpEvent(@intFromPtr(pane), channel, payload) catch |err| {
            self.sendHtpProtocolError(pane, message_id, "internal", @errorName(err));
            return;
        };

        if (!ok.success) {
            self.sendHtpProtocolError(pane, message_id, "handler_error", ok.error_message orelse "event handler failed");
            return;
        }
    }

    fn dispatchHtpQuery(self: *App, pane: *Pane, message_id: ?[]const u8, request_id: ?[]const u8, channel: []const u8, params: ?std.json.Value) void {
        std.log.info("htp: dispatch query pane={x} channel={s}", .{ @intFromPtr(pane), channel });
        const result = self.dispatchHtpQuerySync(@intFromPtr(pane), channel, params) catch |err| {
            self.sendHtpQueryError(pane, message_id, request_id, "internal", @errorName(err));
            return;
        };
        defer result.deinit(self.allocator);

        if (!result.success) {
            self.sendHtpQueryError(pane, message_id, request_id, "handler_error", result.error_message orelse "query handler failed");
            return;
        }

        const payload_value = if (result.value) |value| cloneJsonValue(self.allocator, value) catch |err| {
            self.sendHtpQueryError(pane, message_id, request_id, "internal", @errorName(err));
            return;
        } else null;
        defer if (payload_value) |value| deinitJsonValue(self.allocator, value);

        const envelope = HtpEnvelope{
            .id = self.nextHtpMessageId(),
            .kind = "result",
            .status = "ok",
            .channel = channel,
            .request_id = if (request_id) |value| .{ .string = value } else null,
            .payload = payload_value,
        };
        self.sendHtpEnvelope(pane, envelope);
    }

    fn dispatchHtpQuerySync(self: *App, pane_id: usize, channel: []const u8, params: ?std.json.Value) anyerror!HtpQueryResult {
        const lua = if (self.lua) |*runtime| runtime else return .{ .success = false, .error_message = try self.allocator.dupe(u8, "lua runtime unavailable") };
        return try lua.dispatchHtpQuery(pane_id, channel, params);
    }

    fn dispatchHtpEventSync(self: *App, pane_id: usize, channel: []const u8, payload: ?std.json.Value) anyerror!lua_mod.HtpDispatchResult {
        const lua = if (self.lua) |*runtime| runtime else return .{ .success = false, .error_message = try self.allocator.dupe(u8, "lua runtime unavailable") };
        return try lua.dispatchHtpEvent(pane_id, channel, payload);
    }

    fn sendHtpProtocolError(self: *App, pane: *Pane, request_id: ?[]const u8, code: []const u8, message: []const u8) void {
        const envelope = HtpEnvelope{
            .id = self.nextHtpMessageId(),
            .kind = "error",
            .status = code,
            .request_id = if (request_id) |value| .{ .string = value } else null,
            .@"error" = message,
        };
        self.sendHtpEnvelope(pane, envelope);
    }

    fn sendHtpQueryError(self: *App, pane: *Pane, message_id: ?[]const u8, request_id: ?[]const u8, code: []const u8, message: []const u8) void {
        const envelope = HtpEnvelope{
            .id = self.nextHtpMessageId(),
            .kind = "result",
            .status = code,
            .request_id = if (request_id orelse message_id) |value| .{ .string = value } else null,
            .@"error" = message,
        };
        self.sendHtpEnvelope(pane, envelope);
    }

    fn sendHtpEnvelope(self: *App, pane: *Pane, envelope: HtpEnvelope) void {
        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();

        std.json.Stringify.value(envelope, .{}, &buf.writer) catch return;
        std.log.info("htp: send pane={x} payload={s}", .{ @intFromPtr(pane), buf.written() });
        self.sendHtpChunkedJson(pane, buf.written());
    }

    fn sendHtpChunkedJson(self: *App, pane: *Pane, json_text: []const u8) void {
        if (json_text.len <= HTP_MAX_CHUNK_PAYLOAD) {
            var writer: std.Io.Writer.Allocating = .init(self.allocator);
            defer writer.deinit();
            writer.writer.writeAll(HTP_OSC_PREFIX) catch return;
            writer.writer.writeAll(json_text) catch return;
            writer.writer.writeAll(HTP_ST) catch return;
            pane.writeEscapeSequence(writer.written());
            return;
        }

        const total = std.math.divCeil(usize, json_text.len, HTP_MAX_CHUNK_PAYLOAD) catch return;
        const request_id = self.nextHtpMessageId();
        var index: usize = 0;
        while (index < total) : (index += 1) {
            const start = index * HTP_MAX_CHUNK_PAYLOAD;
            const end = @min(start + HTP_MAX_CHUNK_PAYLOAD, json_text.len);
            var buf: std.Io.Writer.Allocating = .init(self.allocator);
            defer buf.deinit();
            std.json.Stringify.value(HtpEnvelope{
                .id = self.nextHtpMessageId(),
                .kind = "chunk",
                .request_id = .{ .integer = @intCast(request_id) },
                .status = "partial",
                .payload = std.json.Value{ .object = chunkPayloadObject(self.allocator, json_text[start..end], index + 1, total) catch return },
            }, .{}, &buf.writer) catch return;
            var writer: std.Io.Writer.Allocating = .init(self.allocator);
            defer writer.deinit();
            writer.writer.writeAll(HTP_OSC_PREFIX) catch return;
            writer.writer.writeAll(buf.written()) catch return;
            writer.writer.writeAll(HTP_ST) catch return;
            pane.writeEscapeSequence(writer.written());
        }
    }

    fn nextHtpMessageId(self: *App) u64 {
        const value = self.htp_next_message_id;
        self.htp_next_message_id +%= 1;
        return value;
    }

    pub fn captureSnapshot(self: *App) ?FrameSnapshot {
        if (self.renderer) |*renderer| {
            if (self.ghostty) |*runtime| {
                if (self.activePane()) |pane| {
                    if (!paneRenderHelpersReady(pane)) return null;
                    return renderer.fillSnapshot(runtime, pane.render_state, &pane.row_iterator, &pane.row_cells, self.config, pane.title);
                }
            }
        }
        return null;
    }

    pub fn dumpSnapshot(self: *App, frame_index: usize, render_mode: []const u8) void {
        const file = if (self.snapshot_dump_file) |*f| f else return;
        const snapshot = self.captureSnapshot() orelse return;
        const hash = snapshotHash(&snapshot, render_mode);
        if (self.snapshot_dump_has_last_hash and self.snapshot_dump_last_hash == hash) return;
        self.snapshot_dump_last_hash = hash;
        self.snapshot_dump_has_last_hash = true;

        var buf: [4096]u8 = undefined;
        var writer = file.writer(&buf);
        writer.interface.print(
            "=== frame={d} mode={s} dirty={s} rows={d} cols={d} visible={d} title={s} hash={x} ===\n",
            .{ frame_index, render_mode, @tagName(snapshot.dirty), snapshot.rows, snapshot.cols, snapshot.visible_line_count, snapshot.title, hash },
        ) catch return;

        var line_idx: usize = 0;
        while (line_idx < snapshot.visible_line_count and line_idx < snapshot.lines.len) : (line_idx += 1) {
            const line = snapshot.lines[line_idx][0..snapshot.line_lens[line_idx]];
            writer.interface.print("{d:0>3}: {s}\n", .{ line_idx, line }) catch return;
        }
        writer.interface.writeAll("\n") catch return;
        writer.interface.flush() catch {};
    }

    pub fn currentLayoutGeneration(self: *const App) u32 {
        return self.layout_generation;
    }

    pub fn report(self: *App) void {
        std.log.info("native bootstrap ready", .{});
        std.log.info("host={s}", .{platform.name()});
        std.log.info("shell={s}", .{self.config.shellOrDefault()});
        std.log.info("backend requested={s} active={s}", .{ self.config.backend.asString(), self.renderer.?.activeName() });
        std.log.info("window={s} {d}x{d}", .{ self.config.windowTitle(), self.config.window_width, self.config.window_height });
        std.log.info("grid={d}x{d} scrollback={d}", .{ self.config.cols, self.config.rows, self.config.scrollback });
        std.log.info("renderer_safe_mode={}", .{self.config.renderer_safe_mode});
        std.log.info("renderer_disable_swapchain_glyphs={}", .{self.config.renderer_disable_swapchain_glyphs});
        std.log.info("renderer_disable_multi_pane_cache={}", .{self.config.renderer_disable_multi_pane_cache});
        std.log.info("embedded_base_config={}", .{self.using_embedded_base_config});
        if (self.base_config_path) |path| std.log.info("base_config={s}", .{path});
        if (self.override_config_path) |path| std.log.info("override_config={s}", .{path});
    }

    pub fn sendText(self: *App, text: []const u8) void {
        const pane = self.activePane() orelse return;
        const now_ns = std.time.nanoTimestamp();
        self.last_input_activity_ns = now_ns;
        self.last_visual_activity_ns = now_ns;
        pane.pty_received_data = true;
        pane.pty_wrote_this_frame = true;
        pane.last_render_state_update_ns = 0;
        if (self.config.debug_terminal_trace) {
            std.log.info("terminal-trace sendText pane={x} len={d} sample={s}", .{
                @intFromPtr(pane),
                text.len,
                text[0..@min(text.len, 32)],
            });
        }
        self.scrollActiveViewportBottom();
        pane.sendText(text);
        self.signalWake();
    }

    pub fn sendTextToPane(self: *App, pane_id: usize, text: []const u8) bool {
        const pane = self.findPaneById(pane_id) orelse return false;
        pane.sendText(text);
        return true;
    }

    pub fn setCellSize(self: *App, cell_w: u32, cell_h: u32) void {
        self.cell_width_px = @max(1, cell_w);
        self.cell_height_px = @max(1, cell_h);
        if (self.ghostty) |*runtime| self.resizeAllPanes(runtime, self.config.window_width, self.config.window_height, true, false, false);
        std.log.info("app: cell_size updated cell={d}x{d}", .{ self.cell_width_px, self.cell_height_px });
    }

    pub fn resize(self: *App, pixel_width: u32, pixel_height: u32) void {
        const prev_window_width = self.config.window_width;
        const prev_window_height = self.config.window_height;
        const prev_cols = self.config.cols;
        const prev_rows = self.config.rows;

        self.config.window_width = pixel_width;
        self.config.window_height = pixel_height;

        const tbh = self.tabBarHeight();
        const bbh = self.bottomBarHeight();
        const sidebar = self.sidebarLayout();
        const left_inset = if (sidebar != null and sidebar.?.reserve and sidebar.?.side == .left)
            self.sidebarReservedWidthPx(sidebar.?)
        else
            0;
        const right_inset = if (sidebar != null and sidebar.?.reserve and sidebar.?.side == .right)
            self.sidebarReservedWidthPx(sidebar.?)
        else
            0;
        const horizontal_reserved = if (self.activePane()) |pane|
            self.paneHorizontalReserved(pane)
        else
            self.config.terminal_padding.horizontal();
        const content_width = if (pixel_width > left_inset + right_inset) pixel_width - left_inset - right_inset else 1;
        const inner_width = if (content_width > horizontal_reserved) content_width - horizontal_reserved else 1;
        const vertical_reserved = tbh + bbh;
        const content_height = if (pixel_height > vertical_reserved) pixel_height - vertical_reserved else 1;
        const inner_height = if (content_height > self.config.terminal_padding.vertical()) content_height - self.config.terminal_padding.vertical() else 1;

        self.config.cols = @max(1, @as(u16, @intCast(inner_width / @max(@as(u32, 1), self.cell_width_px))));
        self.config.rows = @max(1, @as(u16, @intCast(inner_height / @max(@as(u32, 1), self.cell_height_px))));

        const grid_unchanged = self.config.cols == prev_cols and self.config.rows == prev_rows;
        const size_unchanged = pixel_width == prev_window_width and pixel_height == prev_window_height;

        if (self.ghostty) |*runtime| {
            // A same-grid resize should stay a pure layout/cache refresh.
            // Forcing a PTY/ghostty resize in this case sends an unnecessary
            // SIGWINCH/reflow, which is what causes shell-mode content to come
            // back looking as if `clear` had run after minimize/restore.
            self.resizeAllPanes(runtime, pixel_width, pixel_height, false, grid_unchanged, false);
        }

        _ = size_unchanged;
        std.log.info("app: resized window={d}x{d} grid={d}x{d} cell={d}x{d}", .{ pixel_width, pixel_height, self.config.cols, self.config.rows, self.cell_width_px, self.cell_height_px });
        self.emitLuaBuiltInEvent("window:resized", .{ .window_size = .{
            .rows = self.config.rows,
            .cols = self.config.cols,
            .width = pixel_width,
            .height = pixel_height,
        } });
    }

    pub fn requestResize(self: *App, pixel_width: u32, pixel_height: u32) void {
        self.pending_width = pixel_width;
        self.pending_height = pixel_height;
        self.pending_resize = true;
        self.hover_probe_dirty = true;
        self.invalidateCachedBarLayouts();
        self.signalWake();
    }

    fn requestLayoutResize(self: *App, recreate_render_helpers: bool) void {
        self.pending_layout_resize = true;
        self.pending_layout_recreate_render_helpers = self.pending_layout_recreate_render_helpers or recreate_render_helpers;
        self.layout_generation +%= 1;
        if (self.layout_generation == 0) self.layout_generation = 1;
        self.hover_probe_dirty = true;
        self.invalidateCachedBarLayouts();
        self.signalWake();
    }

    fn requestLayoutRefresh(self: *App) void {
        self.pending_layout_resize = true;
        self.pending_layout_skip_unchanged_pty = true;
        self.layout_generation +%= 1;
        if (self.layout_generation == 0) self.layout_generation = 1;
        self.hover_probe_dirty = true;
        self.invalidateCachedBarLayouts();
        self.signalWake();
    }

    fn invalidateCachedBarLayouts(self: *App) void {
        self.cached_bar_layouts_dirty = true;
        self.cached_sidebar_layout = null;
        self.cached_top_bar_layout = null;
        self.cached_bottom_bar_layout = null;
    }

    fn invalidateFocusedPaneCache(self: *App, previous: ?*Pane, current: ?*Pane) void {
        _ = self;
        if (previous == current) return;
        if (previous) |pane| pane.render_dirty = .full;
        if (current) |pane| pane.render_dirty = .full;
    }

    fn syncActivePaneChange(self: *App, previous: ?*Pane, current: ?*Pane) void {
        self.invalidateFocusedPaneCache(previous, current);
        if (previous == current) return;
        if (self.ghostty) |*runtime| {
            if (current) |pane| runtime.registerCallbacks(pane.terminal, terminalCallbacks());
        }
    }

    fn refreshActivePaneBinding(self: *App) void {
        if (self.activePane()) |pane| {
            pane.render_dirty = .full;
            if (self.ghostty) |*runtime| {
                runtime.registerCallbacks(pane.terminal, terminalCallbacks());
            }
        }
    }

    fn refreshActivePaneDisplay(self: *App) void {
        const pane = self.activePane() orelse return;
        const runtime = if (self.ghostty) |*rt| rt else return;
        runtime.terminalScrollBottom(pane.terminal);
        pane.render_dirty = .full;
        pane.last_render_state_update_ns = 0;
        pane.pty_received_data = true;
        self.scroll_accum = 0;
        _ = self.refreshPaneScrollbar(runtime, pane);
    }

    fn maybeRunStartupCommand(self: *App) void {
        if (self.startup_command_sent) return;
        const command = self.startup_command orelse return;
        if (self.frame_count < self.startup_command_delay_frames) return;
        self.sendText(command);
        if (!std.mem.endsWith(u8, command, "\r") and !std.mem.endsWith(u8, command, "\n")) {
            self.sendText("\r");
        }
        self.startup_command_sent = true;
    }

    pub fn invalidateAllPanes(self: *App) void {
        const mux = if (self.mux) |*m| m else return;
        var panes = mux.paneIterator();
        while (panes.next()) |pane| {
            pane.render_dirty = .full;
            pane.last_render_state_update_ns = 0;
        }
    }

    pub fn sendPaste(self: *App, text: []const u8) !void {
        const pane = self.activePane() orelse return;
        const rt = if (self.ghostty) |*r| r else {
            // No ghostty runtime — just send raw text without bracketed paste.
            if (self.config.debug_terminal_trace) {
                std.log.info("terminal-trace sendPaste pane={x} len={d} bracketed=false runtime=false", .{ @intFromPtr(pane), text.len });
            }
            self.sendText(text);
            return;
        };
        const bracketed = rt.terminalMode(pane.terminal, .bracketed_paste);
        if (self.config.debug_terminal_trace) {
            std.log.info("terminal-trace sendPaste pane={x} len={d} bracketed={}", .{ @intFromPtr(pane), text.len, bracketed });
        }
        if (bracketed) {
            const prefix = "\x1b[200~";
            const suffix = "\x1b[201~";
            const payload = try self.allocator.alloc(u8, prefix.len + text.len + suffix.len);
            defer self.allocator.free(payload);
            @memcpy(payload[0..prefix.len], prefix);
            @memcpy(payload[prefix.len .. prefix.len + text.len], text);
            @memcpy(payload[prefix.len + text.len ..], suffix);
            self.sendText(payload);
            return;
        }
        self.sendText(text);
    }

    pub fn selectionRange(self: *const App, pane: *const Pane) ?selection.Range {
        const history_range = self.selectionHistoryRange(pane) orelse return null;
        const scrollbar = pane.scrollbar();
        const visible_top: usize = @intCast(scrollbarTopRow(scrollbar));
        const visible_rows: usize = @intCast(@max(@as(u64, 1), @min(scrollbar.total, scrollbar.len)));
        return historySelectionRangeInViewport(history_range, visible_top, visible_rows);
    }

    pub fn copyModeSelectionRange(self: *const App, pane: *const Pane) ?selection.Range {
        if (!self.copy_mode_active or self.copy_mode_pane != pane) return null;
        const range = self.copyModeVisibleRange() orelse return null;
        if (range.start.row == range.end.row and range.start.col == range.end.col) return null;
        return range;
    }

    pub fn copyModeActiveForPane(self: *const App, pane: ?*const Pane) bool {
        const value = pane orelse return false;
        return self.copy_mode_active and self.copy_mode_pane == value;
    }

    pub fn copyModeCursorColForRow(self: *const App, pane: *const Pane, row: usize) ?usize {
        if (!self.copy_mode_active or self.copy_mode_pane != pane) return null;
        const visible_top = self.copyModeVisibleTopRow() orelse return null;
        if (self.copy_mode_cursor.row != visible_top + row) return null;
        return self.copy_mode_cursor.col;
    }

    pub fn copyModeActive(self: *const App) bool {
        return self.copy_mode_active;
    }

    pub fn copyModeSnapshotLineForRow(self: *const App, pane: *const Pane, row: usize) ?CopyModeSnapshotLine {
        if (!self.copy_mode_active or self.copy_mode_pane != pane) return null;
        const visible_top = self.copyModeVisibleTopRow() orelse return null;
        const history_row = visible_top + row;
        if (history_row >= self.copy_mode_history.items.len) return null;
        const line = self.copy_mode_history.items[history_row];
        return .{ .text = line.text, .cells = line.cells, .cols = line.cols };
    }

    pub fn searchHighlightForRow(self: *const App, pane: *const Pane, row: usize) ?SearchHighlight {
        if (!self.copy_mode_active or self.copy_mode_pane != pane) return null;
        if (self.copy_mode_matches.items.len == 0) return null;
        const visible_top = self.copyModeVisibleTopRow() orelse return null;
        const history_row = visible_top + row;
        const active_idx = self.copy_mode_match_index;
        var fallback: ?SearchHighlight = null;
        for (self.copy_mode_matches.items, 0..) |match, index| {
            if (match.row != history_row) continue;
            const highlight = SearchHighlight{
                .row = row,
                .start_col = match.start_col,
                .end_col = match.end_col,
                .active = active_idx != null and active_idx.? == index,
            };
            if (highlight.active) return highlight;
            if (fallback == null) fallback = highlight;
        }
        return fallback;
    }

    pub fn selectionGeneration(self: *const App) u64 {
        return self.selection_generation;
    }

    fn copyModeVisibleRows(self: *const App, pane: *const Pane) usize {
        const fallback = @max(@as(usize, 1), @as(usize, pane.rows));
        const runtime = if (self.ghostty) |*rt| @constCast(rt) else return fallback;
        if (runtime.terminalScrollbar(pane.terminal)) |scrollbar| {
            return @max(@as(usize, 1), @as(usize, @intCast(scrollbar.len)));
        }
        if (!pane.render_state_ready or pane.render_state == null) return fallback;
        const rows = runtime.renderStateRows(pane.render_state) orelse return fallback;
        return @max(@as(usize, 1), @as(usize, @intCast(rows)));
    }

    fn syncCopyModeTopRowFromViewport(self: *App, pane: *Pane) void {
        const runtime = if (self.ghostty) |*rt| rt else return;
        const scrollbar = self.refreshPaneScrollbar(runtime, pane);
        self.copy_mode_top_row = @intCast(scrollbarTopRow(scrollbar));
    }

    fn copyModeVisibleTopRow(self: *const App) ?usize {
        const pane = self.copy_mode_pane orelse return null;
        const visible_rows = self.copyModeVisibleRows(pane);
        const max_top = self.copy_mode_history.items.len -| visible_rows;
        return @min(self.copy_mode_top_row, max_top);
    }

    fn copyModeVisibleRange(self: *const App) ?selection.Range {
        const pane = self.copy_mode_pane orelse return null;
        const anchor = self.copy_mode_anchor orelse return null;
        const top = self.copyModeVisibleTopRow() orelse return null;
        const cursor = self.copy_mode_cursor;
        const start_row = anchor.row -| top;
        const end_row = cursor.row -| top;
        if (anchor.row < top and cursor.row < top) return null;
        const max_visible_row = self.copyModeVisibleRows(pane) - 1;
        if (start_row > max_visible_row and end_row > max_visible_row) return null;
        const start = selection.CellPoint{ .row = @min(max_visible_row, start_row), .col = anchor.col };
        const end_ = selection.CellPoint{ .row = @min(max_visible_row, end_row), .col = cursor.col };
        if (self.copy_mode_block_selection) return selection.normalizeBlock(start, end_);
        return selection.normalize(start, end_);
    }

    fn gridRefForHistoryRow(self: *const App, pane: *Pane, history_row: usize) ?ghostty.GridRef {
        const runtime = if (self.ghostty) |*rt| @constCast(rt) else return null;
        const scrollbar = runtime.terminalScrollbar(pane.terminal) orelse return null;
        const scrollback_rows: usize = @intCast(scrollbar.total - @min(scrollbar.total, scrollbar.len));
        return gridRefForHistoryPoint(runtime, pane.terminal, history_row, 0, scrollback_rows);
    }

    fn gridRefForHistoryCell(self: *const App, pane: *Pane, history_row: usize, col: usize) ?ghostty.GridRef {
        const runtime = if (self.ghostty) |*rt| @constCast(rt) else return null;
        const scrollbar = runtime.terminalScrollbar(pane.terminal) orelse return null;
        const scrollback_rows: usize = @intCast(scrollbar.total - @min(scrollbar.total, scrollbar.len));
        return gridRefForHistoryPoint(runtime, pane.terminal, history_row, col, scrollback_rows);
    }

    fn selectionHistoryRange(self: *const App, pane: *const Pane) ?selection.Range {
        if (self.selection_pane != pane) return null;
        const anchor = self.selection_anchor orelse return null;
        const head = self.selection_head orelse return null;
        return selection.normalize(anchor, head);
    }

    fn selectionPointToHistory(self: *App, pane: *Pane, point: selection.CellPoint) selection.CellPoint {
        const scrollbar = if (self.ghostty) |*rt|
            self.refreshPaneScrollbar(rt, pane)
        else
            pane.scrollbar();
        return .{
            .row = @as(usize, @intCast(scrollbarTopRow(scrollbar))) + point.row,
            .col = point.col,
        };
    }

    fn copyModeAlignTopRowForCursor(self: *App, target_row: usize) void {
        const pane = self.copy_mode_pane orelse return;
        const visible_rows = self.copyModeVisibleRows(pane);
        const top = self.copyModeVisibleTopRow() orelse 0;
        const aligned_top = alignedTopRowForTarget(top, visible_rows, target_row);
        self.copy_mode_top_row = aligned_top;
        self.scrollPaneViewportToRow(pane, aligned_top);
        self.syncCopyModeTopRowFromViewport(pane);
        self.refreshCopyModeVisibleSlice(pane) catch {};
    }

    pub fn selectionBegin(self: *App, pane: *Pane, point: selection.CellPoint, extend: bool) void {
        if (!self.hasPane(pane)) return;
        if (self.mux) |*mux| {
            const previous = mux.activePane();
            mux.setActivePane(pane);
            self.syncActivePaneChange(previous, pane);
        }
        const history_point = self.selectionPointToHistory(pane, point);
        const had_selection = self.hasSelection();
        const previous_selection_pane = self.selection_pane;
        if (!extend or self.selection_pane != pane or self.selection_anchor == null) {
            self.selection_pane = pane;
            self.selection_anchor = history_point;
        }
        self.selection_head = history_point;
        self.selection_drag_active = true;
        if (previous_selection_pane) |prev| {
            if (prev != pane) prev.render_dirty = .full;
        }
        pane.render_dirty = .full;
        self.selection_generation +%= 1;
        if (had_selection) {
            self.emitLuaBuiltInEvent("selection:cleared", .none);
        }
    }

    pub fn selectionUpdate(self: *App, pane: *Pane, point: selection.CellPoint) void {
        if (!self.selection_drag_active or self.selection_pane != pane or !self.hasPane(pane)) return;
        const history_point = self.selectionPointToHistory(pane, point);
        if (self.selection_head) |head| {
            if (head.row == history_point.row and head.col == history_point.col) return;
        }
        self.selection_head = history_point;
        pane.render_dirty = .full;
        self.selection_generation +%= 1;
    }

    pub fn selectionEnd(self: *App) void {
        self.selection_drag_active = false;
        if (self.hasSelection()) {
            self.emitLuaBuiltInEvent("selection:begin", .none);
        }
    }

    /// Double-click: select the word (whitespace-delimited token) at `point`.
    pub fn selectionBeginWord(self: *App, pane: *Pane, point: selection.CellPoint) void {
        if (!self.hasPane(pane)) return;
        if (self.mux) |*mux| {
            const previous = mux.activePane();
            mux.setActivePane(pane);
            self.syncActivePaneChange(previous, pane);
        }
        const history_point = self.selectionPointToHistory(pane, point);
        const had_selection = self.hasSelection();

        const runtime = if (self.ghostty) |*rt| rt else return;
        if (!runtime.populateRowIterator(pane.render_state, &pane.row_iterator)) return;

        // Scan to the target row and extract per-column codepoints (ASCII only; non-ASCII treated as word chars).
        var ascii_cols: [4096]u8 = [_]u8{0} ** 4096;
        var col_count: usize = 0;
        var row_index: usize = 0;
        var found_row = false;
        while (runtime.nextRow(pane.row_iterator)) : (row_index += 1) {
            if (row_index != point.row) continue;
            if (!runtime.populateRowCells(pane.row_iterator, &pane.row_cells)) break;
            while (runtime.nextCell(pane.row_cells) and col_count < ascii_cols.len) : (col_count += 1) {
                var cell_buf: [16]u8 = [_]u8{0} ** 16;
                var cell_len: usize = 0;
                appendCellText(runtime, pane.row_cells, &cell_buf, &cell_len);
                // ASCII printable non-space → word char; everything else (incl. NUL, non-ASCII) treated as word char too.
                // Only space (0x20) and control chars (< 0x21) are word boundaries.
                ascii_cols[col_count] = if (cell_len == 1 and cell_buf[0] != 0) cell_buf[0] else ' ';
            }
            found_row = true;
            break;
        }

        if (!found_row or col_count == 0 or point.col >= col_count) {
            // Fall back to single-cell selection.
            self.selectionBegin(pane, point, false);
            return;
        }

        const isWordChar = struct {
            fn call(ch: u8) bool {
                // Word chars: printable non-whitespace (everything except space, tab, and other control chars)
                return ch != ' ' and ch != '\t' and ch >= 0x21;
            }
        }.call;

        if (!isWordChar(ascii_cols[point.col])) {
            // Clicked on whitespace: single-cell selection
            self.selectionBegin(pane, point, false);
            return;
        }

        var start = point.col;
        while (start > 0 and isWordChar(ascii_cols[start - 1])) : (start -= 1) {}
        var end = point.col;
        while (end + 1 < col_count and isWordChar(ascii_cols[end + 1])) : (end += 1) {}

        if (had_selection) {
            self.emitLuaBuiltInEvent("selection:cleared", .none);
        }
        self.selection_pane = pane;
        self.selection_anchor = .{ .row = history_point.row, .col = start };
        self.selection_head = .{ .row = history_point.row, .col = end };
        self.selection_drag_active = false;
        pane.render_dirty = .full;
        self.selection_generation +%= 1;
        self.emitLuaBuiltInEvent("selection:begin", .none);
    }

    /// Triple-click: select the entire row containing `point`.
    pub fn selectionBeginLine(self: *App, pane: *Pane, point: selection.CellPoint) void {
        if (!self.hasPane(pane)) return;
        if (self.mux) |*mux| {
            const previous = mux.activePane();
            mux.setActivePane(pane);
            self.syncActivePaneChange(previous, pane);
        }
        const history_point = self.selectionPointToHistory(pane, point);
        const had_selection = self.hasSelection();

        const cols = @max(@as(usize, 1), @as(usize, pane.cols));
        if (had_selection) {
            self.emitLuaBuiltInEvent("selection:cleared", .none);
        }
        self.selection_pane = pane;
        self.selection_anchor = .{ .row = history_point.row, .col = 0 };
        self.selection_head = .{ .row = history_point.row, .col = cols - 1 };
        self.selection_drag_active = false;
        pane.render_dirty = .full;
        self.selection_generation +%= 1;
        self.emitLuaBuiltInEvent("selection:begin", .none);
    }

    pub fn clearSelection(self: *App) void {
        const pane = self.selection_pane;
        self.selection_pane = null;
        self.selection_anchor = null;
        self.selection_head = null;
        self.selection_drag_active = false;
        if (pane) |p| p.render_dirty = .full;
        self.selection_generation +%= 1;
        self.emitLuaBuiltInEvent("selection:cleared", .none);
    }

    pub fn hasSelection(self: *const App) bool {
        if (self.selection_pane == null) return false;
        return self.selectionHistoryRange(self.selection_pane.?) != null;
    }

    pub fn copySelectionToClipboard(self: *App) !void {
        const pane = self.selection_pane orelse return;
        if (!self.hasPane(pane)) {
            self.pruneSelectionIfInvalid();
            return;
        }
        const range = self.selectionHistoryRange(pane) orelse return;
        var text_buf: [CLIPBOARD_EVENT_MAX]u8 = undefined;
        const text = self.captureSelectionText(pane, range, text_buf[0 .. text_buf.len - 1]) orelse return;
        if (text.len == 0) return;
        text_buf[text.len] = 0;
        c.sapp_set_clipboard_string(@ptrCast(text_buf[0..text.len :0].ptr));
        self.clearSelection();
    }

    pub fn pasteClipboard(self: *App) !void {
        const clipboard = c.sapp_get_clipboard_string();
        const text = std.mem.span(clipboard);
        if (text.len == 0) return;
        try self.sendPaste(text);
    }

    fn enterCopyMode(self: *App) void {
        const pane = self.activePane() orelse return;
        const runtime = if (self.ghostty) |*rt| rt else null;
        const top = if (runtime) |rt|
            blk: {
                const scrollbar = self.refreshPaneScrollbar(rt, pane);
                break :blk @as(usize, @intCast(scrollbarTopRow(scrollbar)));
            }
        else
            0;
        self.copy_mode_pane = pane;
        self.copy_mode_active = true;
        self.copy_mode_anchor = null;
        self.copy_mode_block_selection = false;
        self.copy_mode_match_index = null;
        self.copy_mode_restore_top_row = top;
        self.copy_mode_top_row = top;
        self.copy_mode_needs_refresh = true;
        const visible_rows = self.copyModeVisibleRows(pane);
        self.copy_mode_top_row = top;
        self.copy_mode_cursor = .{
            .row = top + visible_rows - 1,
            .col = 0,
        };
        pane.render_dirty = .full;
        self.emitCopyModeChanged();
    }

    fn exitCopyMode(self: *App) void {
        const pane = self.copy_mode_pane;
        self.copy_mode_active = false;
        self.copy_mode_pane = null;
        self.copy_mode_anchor = null;
        self.copy_mode_top_row = 0;
        const restore_top = self.copy_mode_restore_top_row;
        self.copy_mode_restore_top_row = 0;
        self.copy_mode_match_index = null;
        self.clearSelection();
        if (pane) |value| {
            if (self.renderer) |*renderer| renderer.invalidatePaneCache(value);
            self.scrollPaneViewportToRow(value, restore_top);
            value.render_state_fresh = false;
            value.last_render_state_update_ns = 0;
            value.pty_received_data = true;
            value.render_dirty = .full;
        }
        self.emitCopyModeChanged();
    }

    fn emitCopyModeChanged(self: *App) void {
        self.emitLuaBuiltInEvent("copy_mode:changed", .{ .copy_mode = .{
            .active = self.copy_mode_active,
            .query = self.copy_mode_query,
            .match_count = self.copy_mode_matches.items.len,
            .match_index = self.copy_mode_match_index,
            .selecting = self.copy_mode_anchor != null,
            .block = self.copy_mode_block_selection,
        } });
    }

    fn refreshCopyModeSnapshot(self: *App) !void {
        const pane = self.copy_mode_pane orelse return;
        const runtime = if (self.ghostty) |*rt| rt else return;
        if (!self.hasPane(pane)) return;

        for (self.copy_mode_history.items) |line| self.freeCopyModeLine(line);
        self.copy_mode_history.clearRetainingCapacity();
        self.copy_mode_matches.clearRetainingCapacity();
        self.copy_mode_match_index = null;

        const scrollbar = self.refreshPaneScrollbar(runtime, pane);
        const total_rows: usize = @intCast(scrollbar.total);
        var history_row: usize = 0;
        while (history_row < total_rows) : (history_row += 1) {
            const line = try self.captureCopyModeLine(pane, history_row);
            try self.copy_mode_history.append(self.allocator, line);
        }

        try self.refreshCopyModeVisibleSlice(pane);

        self.copy_mode_needs_refresh = false;
        if (self.copy_mode_query.len > 0) try self.rebuildCopyModeMatches();
    }

    fn freeCopyModeLine(self: *App, line: CopyModeLine) void {
        if (line.text.len > 0) self.allocator.free(line.text);
        for (line.cells) |cell| {
            if (cell.text.len > 0) self.allocator.free(cell.text);
        }
        if (line.cells.len > 0) self.allocator.free(line.cells);
        if (line.col_offsets.len > 0) self.allocator.free(line.col_offsets);
    }

    fn refreshCopyModeVisibleSlice(self: *App, pane: *Pane) !void {
        const runtime = if (self.ghostty) |*rt| rt else return;
        try self.syncPaneRenderState(runtime, pane);
        const scrollbar = self.refreshPaneScrollbar(runtime, pane);
        const start_row: usize = @intCast(scrollbarTopRow(scrollbar));
        const visible_rows: usize = @intCast(@min(scrollbar.total, scrollbar.len));
        if (start_row >= self.copy_mode_history.items.len or visible_rows == 0) return;
        if (!pane.render_state_ready or pane.render_state == null) return;
        if (!runtime.populateRowIterator(pane.render_state, &pane.row_iterator)) return;

        var row_index: usize = 0;
        while (runtime.nextRow(pane.row_iterator) and row_index < visible_rows and start_row + row_index < self.copy_mode_history.items.len) : (row_index += 1) {
            const target_row = start_row + row_index;
            self.freeCopyModeLine(self.copy_mode_history.items[target_row]);
            self.copy_mode_history.items[target_row] = try self.captureCopyModeVisibleLine(pane, target_row, runtime, pane.row_iterator, &pane.row_cells);
        }

        if (self.copy_mode_query.len > 0) {
            const previous_index = self.copy_mode_match_index;
            try self.rebuildCopyModeMatches();
            if (previous_index) |index| {
                if (self.copy_mode_matches.items.len > 0) {
                    const next_index = @min(index, self.copy_mode_matches.items.len - 1);
                    const match = self.copy_mode_matches.items[next_index];
                    self.copy_mode_match_index = next_index;
                    self.copy_mode_cursor = .{ .row = match.row, .col = match.start_col };
                    self.copy_mode_anchor = .{ .row = match.row, .col = match.end_col -| 1 };
                }
            }
        }
    }

    fn syncPaneRenderState(self: *App, runtime: *GhosttyRuntime, pane: *Pane) !void {
        if (!pane.render_state_ready or pane.render_state == null) return;
        runtime.clearRenderStateDirty(pane.render_state);
        try runtime.updateRenderState(pane.render_state, pane.terminal);
        pane.last_render_state_update_ns = std.time.nanoTimestamp();
        pane.pty_received_data = false;
        pane.render_state_fresh = false;
        _ = self.refreshPaneScrollbar(runtime, pane);
    }

    fn captureCopyModeLine(self: *App, pane: *Pane, history_row: usize) !CopyModeLine {
        const runtime = if (self.ghostty) |*rt| rt else return .{};
        var row_text: [4096]u8 = undefined;
        var offsets: [4097]u32 = [_]u32{0} ** 4097;
        var cell_buf: [512]CopyModeCell = undefined;
        var row_cols: usize = 0;
        const row_ref = self.gridRefForHistoryRow(pane, history_row) orelse return .{};
        const row = runtime.gridRefRow(&row_ref) orelse return .{};

        var len: usize = 0;
        while (row_cols < cell_buf.len) : (row_cols += 1) {
            offsets[row_cols] = @intCast(len);
            const cell_ref = self.gridRefForHistoryCell(pane, history_row, row_cols) orelse break;
            const raw_cell = runtime.gridRefCell(&cell_ref) orelse break;
            const cell_text = try captureCopyModeGridRefText(self.allocator, runtime, &cell_ref, raw_cell);
            var style: ghostty.Style = undefined;
            const has_style = runtime.gridRefStyleInto(&cell_ref, &style);
            cell_buf[row_cols] = .{
                .text = cell_text,
                .fg = colorFromGridRefCell(runtime, &cell_ref, raw_cell, true) orelse ghostty.ColorRgb{ .r = 220, .g = 220, .b = 220 },
                .bg = colorFromGridRefCell(runtime, &cell_ref, raw_cell, false),
                .fg_style = if (has_style) style.fg_color else copy_mode_default_style_color,
                .bg_style = if (has_style) style.bg_color else copy_mode_default_style_color,
                .face_idx = if (has_style)
                    (if (style.bold and style.italic) 2 else if (style.bold) 1 else if (style.italic) 3 else 0)
                else
                    0,
            };
            appendCopyModeCellBytes(row_text[0..], &len, cell_text);
        }
        offsets[@min(offsets.len - 1, row_cols)] = @intCast(len);
        while (len > 0 and row_text[len - 1] == ' ') len -= 1;
        while (row_cols > 0 and offsets[row_cols] > len) row_cols -= 1;
        const owned_offsets = try self.allocator.alloc(u32, row_cols + 1);
        const owned_cells = try self.allocator.alloc(CopyModeCell, row_cols);
        for (owned_offsets, 0..) |*dst, idx| dst.* = offsets[idx];
        for (owned_cells, 0..) |*dst, idx| dst.* = cell_buf[idx];
        return .{
            .text = try self.allocator.dupe(u8, row_text[0..len]),
            .col_offsets = owned_offsets,
            .cells = owned_cells,
            .cols = row_cols,
            .is_prompt = runtime.rowSemanticPrompt(row) == .prompt,
        };
    }

    fn captureCopyModeVisibleLine(
        self: *App,
        _: *Pane,
        history_row: usize,
        runtime: *GhosttyRuntime,
        row_iterator: ?*anyopaque,
        row_cells: *?*anyopaque,
    ) !CopyModeLine {
        var row_text: [4096]u8 = undefined;
        var offsets: [4097]u32 = [_]u32{0} ** 4097;
        var cell_buf: [512]CopyModeCell = undefined;
        var row_cols: usize = 0;
        var row: u64 = 0;
        if (row_iterator != null) row = runtime.rowRaw(row_iterator);

        var len: usize = 0;
        if (!runtime.populateRowCells(row_iterator, row_cells)) return .{};
        while (runtime.nextCell(row_cells.*) and row_cols < cell_buf.len) : (row_cols += 1) {
            offsets[row_cols] = @intCast(len);

            var cell_text_buf: [32]u8 = undefined;
            var cell_len: usize = 0;
            appendCellText(runtime, row_cells.*, cell_text_buf[0..], &cell_len);
            const cell_text = try self.allocator.dupe(u8, cell_text_buf[0..cell_len]);

            var style: ghostty.Style = undefined;
            const has_style = runtime.cellStyleInto(row_cells.*, &style);
            cell_buf[row_cols] = .{
                .text = cell_text,
                .fg = runtime.cellForeground(row_cells.*) orelse ghostty.ColorRgb{ .r = 220, .g = 220, .b = 220 },
                .bg = runtime.cellBackground(row_cells.*),
                .fg_style = if (has_style) style.fg_color else copy_mode_default_style_color,
                .bg_style = if (has_style) style.bg_color else copy_mode_default_style_color,
                .face_idx = if (has_style)
                    (if (style.bold and style.italic) 2 else if (style.bold) 1 else if (style.italic) 3 else 0)
                else
                    0,
            };
            appendCopyModeCellBytes(row_text[0..], &len, cell_text);
        }

        offsets[@min(offsets.len - 1, row_cols)] = @intCast(len);
        while (len > 0 and row_text[len - 1] == ' ') len -= 1;
        while (row_cols > 0 and offsets[row_cols] > len) row_cols -= 1;
        const owned_offsets = try self.allocator.alloc(u32, row_cols + 1);
        const owned_cells = try self.allocator.alloc(CopyModeCell, row_cols);
        for (owned_offsets, 0..) |*dst, idx| dst.* = offsets[idx];
        for (owned_cells, 0..) |*dst, idx| dst.* = cell_buf[idx];
        return .{
            .text = try self.allocator.dupe(u8, row_text[0..len]),
            .col_offsets = owned_offsets,
            .cells = owned_cells,
            .cols = row_cols,
            .is_prompt = runtime.rowSemanticPrompt(@intCast(history_row)) == .prompt or runtime.rowSemanticPrompt(row) == .prompt,
        };
    }

    fn rebuildCopyModeMatches(self: *App) !void {
        self.copy_mode_matches.clearRetainingCapacity();
        self.copy_mode_match_index = null;
        if (self.copy_mode_query.len == 0) return;
        if (self.copy_mode_query.len == 0) return;
        for (self.copy_mode_history.items, 0..) |line, row| {
            var start: usize = 0;
            while (true) {
                const match = copyModeRegexFind(self.copy_mode_query, line.text, start) orelse break;
                const start_col = copyModeColumnForByteOffset(line, match.start);
                const end_col = copyModeColumnForByteOffset(line, match.end);
                try self.copy_mode_matches.append(self.allocator, .{
                    .row = row,
                    .start_col = start_col,
                    .end_col = end_col,
                });
                start = match.start + @max(@as(usize, 1), match.end - match.start);
            }
        }
        self.emitCopyModeChanged();
    }

    fn copyModeSetSearchQuery(self: *App, query: []const u8) !void {
        if (self.copy_mode_query.len > 0) self.allocator.free(self.copy_mode_query);
        self.copy_mode_query = try self.allocator.dupe(u8, query);
        if (self.copy_mode_needs_refresh) try self.refreshCopyModeSnapshot();
        try self.rebuildCopyModeMatches();
        self.copyModeJumpMatch(true);
        if (self.copy_mode_matches.items.len == 0) {
            if (self.copy_mode_pane) |pane| pane.render_dirty = .full;
            self.emitCopyModeChanged();
        }
    }

    fn copyModeJumpMatch(self: *App, forward: bool) void {
        if (self.copy_mode_matches.items.len == 0) return;
        const next_index = if (self.copy_mode_match_index) |current|
            if (forward)
                (current + 1) % self.copy_mode_matches.items.len
            else
                (current + self.copy_mode_matches.items.len - 1) % self.copy_mode_matches.items.len
        else if (forward)
            0
        else
            self.copy_mode_matches.items.len - 1;
        self.copy_mode_match_index = next_index;
        const match = self.copy_mode_matches.items[next_index];
        self.copy_mode_cursor = .{ .row = match.row, .col = match.start_col };
        self.copy_mode_anchor = .{ .row = match.row, .col = match.end_col -| 1 };
        if (self.copy_mode_pane) |pane| {
            const visible_rows = self.copyModeVisibleRows(pane);
            const top_target = if (match.row >= visible_rows / 2) match.row - visible_rows / 2 else 0;
            self.copy_mode_top_row = top_target;
            self.scrollPaneViewportToRow(pane, top_target);
            self.syncCopyModeTopRowFromViewport(pane);
            self.refreshCopyModeVisibleSlice(pane) catch {};
            pane.render_dirty = .full;
        }
        self.emitCopyModeChanged();
    }

    fn copyModeMove(self: *App, kind: CopyModeMoveKind, extend: bool) void {
        const pane = self.copy_mode_pane orelse return;
        if (self.copy_mode_needs_refresh) self.refreshCopyModeSnapshot() catch return;
        if (self.copy_mode_history.items.len == 0) return;

        const previous_cursor = self.copy_mode_cursor;
        var cursor = self.copy_mode_cursor;
        switch (kind) {
            .left => {
                if (cursor.col > 0) cursor.col -= 1;
            },
            .right => cursor.col += 1,
            .up => {
                if (cursor.row > 0) cursor.row -= 1;
            },
            .down => {
                if (cursor.row + 1 < self.copy_mode_history.items.len) cursor.row += 1;
            },
            .page_up => cursor.row -|= self.copyModeVisibleRows(pane) - 1,
            .page_down => cursor.row = @min(self.copy_mode_history.items.len - 1, cursor.row + self.copyModeVisibleRows(pane) - 1),
            .line_start => cursor.col = 0,
            .line_end => cursor.col = self.copy_mode_history.items[cursor.row].cols,
            .top => cursor.row = 0,
            .bottom => cursor.row = self.copy_mode_history.items.len - 1,
        }
        const cols = @max(1, @as(usize, pane.cols));
        cursor.col = @min(cursor.col, cols - 1);
        self.copy_mode_cursor = cursor;
        if (extend) {
            if (self.copy_mode_anchor == null) self.copy_mode_anchor = previous_cursor;
        } else {
            self.copy_mode_anchor = null;
            self.copy_mode_block_selection = false;
        }

        self.copyModeAlignTopRowForCursor(cursor.row);
        pane.render_dirty = .full;
        self.emitCopyModeChanged();
    }

    fn copyModeScrollDelta(self: *App, delta: isize) void {
        const pane = self.copy_mode_pane orelse return;
        if (self.copy_mode_needs_refresh) self.refreshCopyModeSnapshot() catch return;
        const visible_rows = self.copyModeVisibleRows(pane);
        const max_top = self.copy_mode_history.items.len -| visible_rows;
        const current_top: isize = @intCast(self.copyModeVisibleTopRow() orelse 0);
        const min_top: isize = 0;
        const max_top_i: isize = @intCast(max_top);
        const next_top = std.math.clamp(current_top + delta, min_top, max_top_i);
        self.copy_mode_top_row = @intCast(next_top);
        self.scrollPaneViewportToRow(pane, self.copy_mode_top_row);
        self.syncCopyModeTopRowFromViewport(pane);
        self.refreshCopyModeVisibleSlice(pane) catch {};
        pane.render_dirty = .full;
        self.emitCopyModeChanged();
    }

    fn copyModeScrollToRow(self: *App, top_row: u64) void {
        const pane = self.copy_mode_pane orelse return;
        if (self.copy_mode_needs_refresh) self.refreshCopyModeSnapshot() catch return;
        const visible_rows = self.copyModeVisibleRows(pane);
        const max_top = self.copy_mode_history.items.len -| visible_rows;
        self.copy_mode_top_row = @min(@as(usize, @intCast(top_row)), max_top);
        self.scrollPaneViewportToRow(pane, self.copy_mode_top_row);
        self.syncCopyModeTopRowFromViewport(pane);
        self.refreshCopyModeVisibleSlice(pane) catch {};
        pane.render_dirty = .full;
        self.emitCopyModeChanged();
    }

    fn copyModeScrollToBottom(self: *App) void {
        const pane = self.copy_mode_pane orelse return;
        if (self.copy_mode_needs_refresh) self.refreshCopyModeSnapshot() catch return;
        const visible_rows = self.copyModeVisibleRows(pane);
        self.copy_mode_top_row = self.copy_mode_history.items.len -| visible_rows;
        self.scrollPaneViewportToRow(pane, self.copy_mode_top_row);
        self.syncCopyModeTopRowFromViewport(pane);
        self.refreshCopyModeVisibleSlice(pane) catch {};
        pane.render_dirty = .full;
        self.emitCopyModeChanged();
    }

    fn copyModePromptJump(self: *App, direction: PromptJumpDir) void {
        const pane = self.copy_mode_pane orelse return;
        const runtime = if (self.ghostty) |*rt| rt else return;
        const scrollbar = self.refreshPaneScrollbar(runtime, pane);
        const total: usize = @intCast(scrollbar.total);
        if (total == 0) return;
        const start_row = switch (direction) {
            .next => self.copy_mode_cursor.row +| 1,
            .prev => self.copy_mode_cursor.row -| 1,
        };
        const target_row = findPromptJumpTarget(.{ .live = .{ .runtime = runtime, .terminal = pane.terminal } }, direction, start_row, total) orelse return;
        self.copy_mode_cursor = .{ .row = target_row, .col = 0 };
        self.copy_mode_anchor = null;
        self.copy_mode_block_selection = false;
        self.copyModeAlignTopRowForCursor(target_row);
        pane.render_dirty = .full;
        self.emitCopyModeChanged();
    }

    fn copyModeClearSelection(self: *App) void {
        const pane = self.copy_mode_pane orelse return;
        self.copy_mode_anchor = null;
        self.copy_mode_block_selection = false;
        pane.render_dirty = .full;
        self.emitCopyModeChanged();
    }

    fn copyModeBeginSelection(self: *App) void {
        self.copyModeBeginSelectionWithBlock(false);
    }

    fn copyModeBeginSelectionWithBlock(self: *App, block: bool) void {
        const pane = self.copy_mode_pane orelse return;
        if (self.copy_mode_anchor == null) self.copy_mode_anchor = self.copy_mode_cursor;
        self.copy_mode_block_selection = block;
        pane.render_dirty = .full;
        self.emitCopyModeChanged();
    }

    fn copyModeCopy(self: *App) !void {
        _ = self.copy_mode_pane orelse return;
        if (self.copy_mode_needs_refresh) try self.refreshCopyModeSnapshot();
        const anchor = self.copy_mode_anchor orelse self.copy_mode_cursor;
        const range = normalizeCopyModeRange(anchor, self.copy_mode_cursor);
        var text_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer text_buf.deinit(self.allocator);
        var row = range.start.row;
        while (row <= range.end.row and row < self.copy_mode_history.items.len) : (row += 1) {
            const line = self.copy_mode_history.items[row];
            const start_col = if (row == range.start.row) @min(range.start.col, line.cols) else 0;
            const end_col = if (row == range.end.row) @min(range.end.col + 1, line.cols) else line.cols;
            const start_byte = copyModeByteOffsetForColumn(line, start_col);
            const end_byte = copyModeByteOffsetForColumn(line, end_col);
            if (end_byte > start_byte) try text_buf.appendSlice(self.allocator, line.text[start_byte..end_byte]);
            if (row < range.end.row) try text_buf.append(self.allocator, '\n');
        }
        if (text_buf.items.len == 0) return;
        var clipboard = try self.allocator.alloc(u8, text_buf.items.len + 1);
        defer self.allocator.free(clipboard);
        fastmem.copy(u8, clipboard[0..text_buf.items.len], text_buf.items);
        clipboard[text_buf.items.len] = 0;
        c.sapp_set_clipboard_string(@ptrCast(clipboard[0..text_buf.items.len :0].ptr));
        self.exitCopyMode();
    }

    fn normalizeCopyModeRange(a: CopyModePoint, b: CopyModePoint) struct { start: CopyModePoint, end: CopyModePoint } {
        if (a.row < b.row or (a.row == b.row and a.col <= b.col)) {
            return .{ .start = a, .end = b };
        }
        return .{ .start = b, .end = a };
    }

    fn copyModeByteOffsetForColumn(line: CopyModeLine, col: usize) usize {
        if (line.col_offsets.len == 0) return @min(col, line.text.len);
        return @min(@as(usize, line.col_offsets[@min(col, line.col_offsets.len - 1)]), line.text.len);
    }

    fn copyModeColumnForByteOffset(line: CopyModeLine, byte_offset: usize) usize {
        if (line.col_offsets.len == 0) return @min(byte_offset, line.cols);
        const target: u32 = @intCast(@min(byte_offset, line.text.len));
        var col: usize = 0;
        while (col + 1 < line.col_offsets.len and line.col_offsets[col + 1] <= target) : (col += 1) {}
        return @min(col, line.cols);
    }

    fn copyModeRegexAtomLen(pattern: []const u8, index: usize) ?usize {
        if (index >= pattern.len) return null;
        if (pattern[index] == '\\') {
            if (index + 1 >= pattern.len) return null;
            return 2;
        }
        return 1;
    }

    fn copyModeRegexCharMatches(token: []const u8, ch: u8) bool {
        if (token.len == 0) return false;
        if (token.len == 1) return token[0] == '.' or token[0] == ch;
        if (token.len == 2 and token[0] == '\\') {
            return switch (token[1]) {
                'd' => std.ascii.isDigit(ch),
                's' => std.ascii.isWhitespace(ch),
                'w' => std.ascii.isAlphanumeric(ch) or ch == '_',
                't' => ch == '\t',
                'n' => ch == '\n',
                '\\' => ch == '\\',
                '.' => ch == '.',
                '*' => ch == '*',
                '+' => ch == '+',
                '?' => ch == '?',
                '^' => ch == '^',
                '$' => ch == '$',
                else => ch == token[1],
            };
        }
        return false;
    }

    fn copyModeRegexQuantifier(pattern: []const u8, next_index: usize) ?u8 {
        if (next_index >= pattern.len) return null;
        return switch (pattern[next_index]) {
            '*', '+', '?' => pattern[next_index],
            else => null,
        };
    }

    fn copyModeRegexMatchFrom(pattern: []const u8, pattern_index: usize, text: []const u8, text_index: usize) ?usize {
        if (pattern_index >= pattern.len) return text_index;
        if (pattern[pattern_index] == '$') {
            if (pattern_index + 1 != pattern.len) return null;
            return if (text_index == text.len) text_index else null;
        }

        const atom_len = copyModeRegexAtomLen(pattern, pattern_index) orelse return null;
        const atom = pattern[pattern_index .. pattern_index + atom_len];
        const quant = copyModeRegexQuantifier(pattern, pattern_index + atom_len);
        const quant_len: usize = if (quant != null) 1 else 0;
        const rest_index = pattern_index + atom_len + quant_len;

        if (quant) |value| {
            var max_count: usize = 0;
            while (text_index + max_count < text.len and copyModeRegexCharMatches(atom, text[text_index + max_count])) : (max_count += 1) {}
            const min_count: usize = if (value == '+') 1 else 0;
            if (value == '?' and max_count > 1) max_count = 1;
            if (max_count < min_count) return null;

            var count = max_count + 1;
            while (count > min_count) {
                count -= 1;
                if (copyModeRegexMatchFrom(pattern, rest_index, text, text_index + count)) |end| return end;
            }
            if (min_count == 0) {
                return copyModeRegexMatchFrom(pattern, rest_index, text, text_index);
            }
            return null;
        }

        if (text_index >= text.len or !copyModeRegexCharMatches(atom, text[text_index])) return null;
        return copyModeRegexMatchFrom(pattern, rest_index, text, text_index + 1);
    }

    fn copyModeRegexFind(pattern: []const u8, text: []const u8, start: usize) ?struct { start: usize, end: usize } {
        if (pattern.len == 0 or start > text.len) return null;
        if (pattern[0] == '^') {
            if (start != 0) return null;
            const end = copyModeRegexMatchFrom(pattern, 1, text, 0) orelse return null;
            return .{ .start = 0, .end = end };
        }

        var index = start;
        while (index <= text.len) : (index += 1) {
            const end = copyModeRegexMatchFrom(pattern, 0, text, index) orelse continue;
            return .{ .start = index, .end = end };
        }
        return null;
    }

    fn captureSelectionText(self: *App, pane: *Pane, range: selection.Range, out: []u8) ?[]const u8 {
        const runtime = if (self.ghostty) |*rt| rt else return null;
        if (self.selection_pane != pane) return null;

        var writer = std.io.fixedBufferStream(out);
        var row_index = range.start.row;
        while (row_index <= range.end.row) : (row_index += 1) {
            var row_text: [4096]u8 = undefined;
            var row_len: usize = 0;
            var col_index: usize = 0;

            while (true) : (col_index += 1) {
                const cell_ref = self.gridRefForHistoryCell(pane, row_index, col_index) orelse break;
                const raw_cell = runtime.gridRefCell(&cell_ref) orelse break;
                if (!selection.cellSelected(range, row_index, col_index)) continue;
                appendGridRefText(runtime, &cell_ref, raw_cell, row_text[0..], &row_len);
            }
            while (row_len > 0 and row_text[row_len - 1] == ' ') row_len -= 1;
            writer.writer().writeAll(row_text[0..row_len]) catch break;
            if (row_index == range.end.row) break;
            writer.writer().writeByte('\n') catch break;
        }

        return writer.getWritten();
    }

    pub fn cellPointFromPaneLocal(self: *const App, pane: *const Pane, x: f32, y: f32) selection.CellPoint {
        const cols = @max(@as(usize, 1), @as(usize, pane.cols));
        const rows = @max(@as(usize, 1), @as(usize, pane.rows));
        const cell_w = @max(self.cell_width_px, @as(u32, 1));
        const cell_h = @max(self.cell_height_px, @as(u32, 1));
        const col = @min(cols - 1, @as(usize, @intFromFloat(@max(0, x) / @as(f32, @floatFromInt(cell_w)))));
        const row = @min(rows - 1, @as(usize, @intFromFloat(@max(0, y) / @as(f32, @floatFromInt(cell_h)))));
        return .{ .row = row, .col = col };
    }

    pub fn cellPointInPane(self: *App, pane: *Pane, x: f32, y: f32) ?selection.CellPoint {
        var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
        const leaves = self.computeActiveLayout(&layout_buf);
        for (leaves) |leaf| {
            if (leaf.pane != pane) continue;
            const inner = self.paneInnerBounds(leaf.pane, leaf.bounds);
            const inner_right = inner.x + inner.width;
            const inner_bottom = inner.y + inner.height;
            const clamped_x = std.math.clamp(x, @as(f32, @floatFromInt(inner.x)), @as(f32, @floatFromInt(inner_right - 1)));
            const clamped_y = std.math.clamp(y, @as(f32, @floatFromInt(inner.y)), @as(f32, @floatFromInt(inner_bottom - 1)));
            return self.cellPointFromPaneLocal(
                pane,
                clamped_x - @as(f32, @floatFromInt(inner.x)),
                clamped_y - @as(f32, @floatFromInt(inner.y)),
            );
        }
        if (self.activePane() == pane) {
            return self.cellPointFromPaneLocal(pane, x, y);
        }
        return null;
    }

    fn rowTextForHyperlinks(self: *App, pane: *Pane, row: usize, out: []u8) ?[]const u8 {
        const runtime = if (self.ghostty) |*rt| rt else return null;
        if (!paneRenderHelpersReady(pane)) return null;
        if (!runtime.populateRowIterator(pane.render_state, &pane.row_iterator)) return null;

        var row_index: usize = 0;
        while (runtime.nextRow(pane.row_iterator)) : (row_index += 1) {
            if (row_index != row) continue;
            if (!runtime.populateRowCells(pane.row_iterator, &pane.row_cells)) return null;

            var len: usize = 0;
            while (runtime.nextCell(pane.row_cells)) {
                appendCellText(runtime, pane.row_cells, out, &len);
            }
            return out[0..len];
        }

        return null;
    }

    fn hyperlinkUriAt(self: *App, pane: *Pane, point: selection.CellPoint, out: []u8) ?[]const u8 {
        const rt = self.ghostty orelse return null;
        const terminal = pane.terminal orelse return null;

        var ref = ghostty.GridRef{
            .size = @sizeOf(ghostty.GridRef),
            .node = null,
            .x = 0,
            .y = 0,
        };
        const lookup_point = ghostty.Point{
            .tag = .viewport,
            .value = .{ .coordinate = .{
                .x = @intCast(point.col),
                .y = @intCast(point.row),
            } },
        };
        if (rt.terminal_grid_ref(terminal, lookup_point, &ref) != ghostty.success) return null;

        var uri_len: usize = 0;
        const probe_result = rt.grid_ref_hyperlink_uri(&ref, null, 0, &uri_len);
        if (probe_result == ghostty.success) return null;
        if (probe_result != ghostty.out_of_space or uri_len == 0 or uri_len > out.len) return null;
        if (rt.grid_ref_hyperlink_uri(&ref, out.ptr, out.len, &uri_len) != ghostty.success or uri_len == 0) return null;
        return out[0..uri_len];
    }

    fn hyperlinkTokenAt(self: *App, pane: *Pane, point: selection.CellPoint, out: []u8) ?HyperlinkToken {
        const runtime = if (self.ghostty) |*rt| rt else return null;
        if (!paneRenderHelpersReady(pane)) return null;
        if (!runtime.populateRowIterator(pane.render_state, &pane.row_iterator)) return null;
        var row_index: usize = 0;
        while (runtime.nextRow(pane.row_iterator)) : (row_index += 1) {
            if (row_index != point.row) continue;
            if (!runtime.populateRowCells(pane.row_iterator, &pane.row_cells)) return null;

            // OSC 8 hyperlinks are tracked by URI in the terminal grid.
            if (self.hyperlinkUriAt(pane, point, out)) |url| {
                var compare_buf: [8192]u8 = undefined;
                var start_col = point.col;
                while (start_col > 0) {
                    const prev_url = self.hyperlinkUriAt(pane, .{ .row = point.row, .col = start_col - 1 }, &compare_buf) orelse break;
                    if (!std.mem.eql(u8, prev_url, url)) break;
                    start_col -= 1;
                }

                var end_col = point.col + 1;
                const cols = @as(usize, pane.cols);
                while (end_col < cols) {
                    const next_url = self.hyperlinkUriAt(pane, .{ .row = point.row, .col = end_col }, &compare_buf) orelse break;
                    if (!std.mem.eql(u8, next_url, url)) break;
                    end_col += 1;
                }

                return .{
                    .text = "",
                    .start_col = start_col,
                    .end_col = end_col,
                    .open_text = url,
                };
            }

            // Fallback: manual pattern matching
            if (!runtime.populateRowCells(pane.row_iterator, &pane.row_cells)) return null;
            var ascii_cols: [4096]u8 = [_]u8{0} ** 4096;
            var col_count: usize = 0;
            while (runtime.nextCell(pane.row_cells) and col_count < ascii_cols.len) : (col_count += 1) {
                var cell_buf: [16]u8 = [_]u8{0} ** 16;
                var cell_len: usize = 0;
                appendCellText(runtime, pane.row_cells, &cell_buf, &cell_len);
                ascii_cols[col_count] = if (cell_len == 1 and cell_buf[0] < 128) cell_buf[0] else 0;
            }

            if (point.col >= col_count) return null;
            const cfg = self.config.hyperlinks;
            const delimiters = cfg.delimitersOrDefault();
            const isDelimiter = struct {
                fn call(delims: []const u8, ch: u8) bool {
                    return ch == 0 or std.mem.indexOfScalar(u8, delims, ch) != null;
                }
            }.call;

            if (isDelimiter(delimiters, ascii_cols[point.col])) return null;

            var start = point.col;
            while (start > 0 and !isDelimiter(delimiters, ascii_cols[start - 1])) : (start -= 1) {}

            var end = point.col;
            while (end < col_count and !isDelimiter(delimiters, ascii_cols[end])) : (end += 1) {}
            if (end <= start) return null;

            if (!runtime.populateRowCells(pane.row_iterator, &pane.row_cells)) return null;
            var len: usize = 0;
            var col: usize = 0;
            while (runtime.nextCell(pane.row_cells)) : (col += 1) {
                if (col < start) continue;
                if (col >= end) break;
                appendCellText(runtime, pane.row_cells, out, &len);
            }
            if (len == 0) return null;

            var token = out[0..len];
            var token_start = start;
            const trim_leading_chars = cfg.trimLeadingOrDefault();
            while (token.len > 0 and std.mem.indexOfScalar(u8, trim_leading_chars, token[0]) != null) {
                token = token[1..];
                token_start += 1;
            }
            var trimmed_end = end;
            const trim_chars = cfg.trimTrailingOrDefault();
            while (token.len > 0 and std.mem.indexOfScalar(u8, trim_chars, token[token.len - 1]) != null) {
                token = token[0 .. token.len - 1];
                trimmed_end -= 1;
            }
            if (token.len == 0 or trimmed_end <= token_start) return null;

            const open_text = if (cfg.match_www and std.mem.startsWith(u8, token, "www.")) blk: {
                if (out.len < token.len + "https://".len) return null;
                fastmem.copy(u8, out[0..8], "https://");
                fastmem.copy(u8, out[8 .. 8 + token.len], token);
                break :blk out[0 .. 8 + token.len];
            } else token;

            var prefixes = std.mem.tokenizeScalar(u8, cfg.prefixesOrDefault(), ' ');
            while (prefixes.next()) |prefix| {
                if (prefix.len == 0) continue;
                if (std.mem.startsWith(u8, token, prefix)) return .{
                    .text = token,
                    .start_col = token_start,
                    .end_col = trimmed_end,
                    .open_text = open_text,
                };
            }

            if (cfg.match_www and std.mem.startsWith(u8, token, "www.")) return .{
                .text = token,
                .start_col = token_start,
                .end_col = trimmed_end,
                .open_text = open_text,
            };

            return null;
        }

        return null;
    }

    fn openHyperlinkAt(self: *App, pane: *Pane, point: selection.CellPoint) void {
        if (!self.config.hyperlinks.enabled) return;
        var row_buf: [8192]u8 = undefined;
        const token = self.hyperlinkTokenAt(pane, point, &row_buf) orelse return;
        platform.openExternalWithOpenerAsync(token.open_text, self.config.hyperlinks.opener) catch |err| {
            std.log.err("open hyperlink failed: {s}", .{@errorName(err)});
        };
    }

    pub fn hasHyperlinkAt(self: *App, pane: *Pane, point: selection.CellPoint) bool {
        var row_buf: [8192]u8 = undefined;
        return self.hyperlinkTokenAt(pane, point, &row_buf) != null;
    }

    pub fn isHoveringHyperlink(self: *const App, pane: *const Pane, row: usize, col: usize) bool {
        const hovered = self.hovered_hyperlink orelse return false;
        return hovered.pane == pane and hovered.row == row and col >= hovered.start_col and col < hovered.end_col;
    }

    fn updateHoveredHyperlink(self: *App) void {
        if (!self.hover_probe_dirty) return;
        self.hover_probe_dirty = false;
        self.hovered_hyperlink = null;
        if (!self.config.hyperlinks.enabled) return;
        if (self.hitTestPane(self.pointer_x, self.pointer_y)) |hit| {
            const point = self.cellPointFromPaneLocal(hit.pane, hit.x, hit.y);
            var row_buf: [8192]u8 = undefined;
            const token = self.hyperlinkTokenAt(hit.pane, point, &row_buf) orelse return;
            self.hovered_hyperlink = .{
                .pane = hit.pane,
                .row = point.row,
                .start_col = token.start_col,
                .end_col = token.end_col,
            };
        }
    }

    pub fn hoveredHyperlinkAtPointer(self: *App) ?struct {
        pane: *Pane,
        point: selection.CellPoint,
    } {
        const hovered = self.hovered_hyperlink orelse return null;
        if (self.hitTestPane(self.pointer_x, self.pointer_y)) |hit| {
            if (hit.pane != hovered.pane) return null;
            const point = self.cellPointFromPaneLocal(hit.pane, hit.x, hit.y);
            if (point.row != hovered.row or point.col < hovered.start_col or point.col >= hovered.end_col) return null;
            return .{ .pane = hit.pane, .point = point };
        }
        return null;
    }

    fn scrollbarVisible(self: *const App, scrollbar: ghostty.TerminalScrollbar) bool {
        return self.config.scrollbar.enabled and scrollbar.len > 0 and scrollbar.total > scrollbar.len;
    }

    fn paneScrollbarGutter(self: *const App, pane: *const Pane) u32 {
        return if (self.scrollbarVisible(pane.scrollbar())) self.config.scrollbar.gutterWidth() else 0;
    }

    fn paneHorizontalReserved(self: *const App, pane: *const Pane) u32 {
        return self.config.terminal_padding.horizontal() + self.paneScrollbarGutter(pane);
    }

    pub fn hasPane(self: *App, needle: *const Pane) bool {
        if (self.mux) |*mux| {
            var panes = mux.paneIterator();
            while (panes.next()) |pane| {
                if (pane == needle) return true;
            }
        }
        return false;
    }

    pub fn findPaneById(self: *App, pane_id: usize) ?*Pane {
        if (self.mux) |*mux| {
            var panes = mux.paneIterator();
            while (panes.next()) |pane| {
                if (@intFromPtr(pane) == pane_id) return pane;
            }
        }
        return null;
    }

    pub fn setPaneForegroundProcess(self: *App, pane_id: usize, process: []const u8) void {
        if (self.findPaneById(pane_id)) |pane| {
            if (pane.foreground_process) |existing_process| {
                self.allocator.free(existing_process);
            }
            pane.foreground_process = self.allocator.dupe(u8, process) catch null;
        }
    }

    pub fn getPaneForegroundProcess(self: *App, pane_id: usize, out_buf: []u8) []const u8 {
        _ = out_buf;
        const pane = self.findPaneById(pane_id) orelse return "";
        return pane.foreground_process orelse "";
    }

    fn paneRenderHelpersReady(pane: *const Pane) bool {
        return pane.render_state_ready and pane.render_state != null and pane.row_iterator != null and pane.row_cells != null;
    }

    pub fn getPaneText(self: *App, pane_id: usize, out: []u8) []const u8 {
        const runtime = if (self.ghostty) |*rt| rt else return "";
        const pane = self.findPaneById(pane_id) orelse return "";
        if (!paneRenderHelpersReady(pane) or pane.rows == 0) return "";
        if (!runtime.populateRowIterator(pane.render_state, &pane.row_iterator)) return "";

        var writer = std.io.fixedBufferStream(out);
        var row_index: usize = 0;
        while (runtime.nextRow(pane.row_iterator) and row_index < pane.rows) : (row_index += 1) {
            if (!runtime.populateRowCells(pane.row_iterator, &pane.row_cells)) break;

            var row_text: [4096]u8 = undefined;
            var row_len: usize = 0;
            while (runtime.nextCell(pane.row_cells)) {
                appendCellText(runtime, pane.row_cells, row_text[0..], &row_len);
            }
            while (row_len > 0 and row_text[row_len - 1] == ' ') row_len -= 1;
            writer.writer().writeAll(row_text[0..row_len]) catch break;
            if (row_index + 1 < pane.rows) writer.writer().writeByte('\n') catch break;
        }

        return writer.getWritten();
    }

    pub fn isPaneVisible(self: *App, needle: *const Pane) bool {
        var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
        const leaves = self.computeActiveLayout(&layout_buf);
        for (leaves) |leaf| {
            if (leaf.pane == needle) return true;
        }
        return false;
    }

    fn pruneSelectionIfInvalid(self: *App) void {
        const pane = self.selection_pane orelse return;
        if (self.hasPane(pane) and self.isPaneVisible(pane)) return;
        self.selection_pane = null;
        self.selection_anchor = null;
        self.selection_head = null;
        self.selection_drag_active = false;
        self.selection_generation +%= 1;
        self.emitLuaBuiltInEvent("selection:cleared", .none);
    }

    fn pruneCopyModeIfInvalid(self: *App) void {
        const pane = self.copy_mode_pane orelse return;
        if (self.hasPane(pane) and self.isPaneVisible(pane)) return;
        self.exitCopyMode();
    }

    pub fn sendFocus(self: *App, gained: bool) !void {
        const pane = self.activePane() orelse return;
        const rt = if (self.ghostty) |*r| r else return;
        if (!rt.terminalMode(pane.terminal, .focus_event)) return;
        var buf: [8]u8 = undefined;
        const bytes = rt.encodeFocus(if (gained) .gained else .lost, &buf) orelse return;
        self.sendText(bytes);
    }

    pub fn sendKey(self: *App, key: ghostty.Key, mods: u32, action: ghostty.KeyAction, text: ?[]const u8) !bool {
        const pane = self.activePane() orelse return false;
        if (action == .press and key == .escape and mods == ghostty.Mods.none and text == null) {
            self.sendText("\x1b");
            return true;
        }

        const rt = if (self.ghostty) |*r| r else return false;
        var buf: [128]u8 = undefined;
        var derived_text_buf: [4]u8 = undefined;
        const effective_text = text orelse legacyPrintableKeyText(key, mods, &derived_text_buf);
        const consumed: u32 = if (effective_text != null and (mods & ghostty.Mods.shift) != 0) ghostty.Mods.shift else ghostty.Mods.none;
        if (rt.encodeKey(pane.key_encoder, pane.key_event, key, mods, action, consumed, if (effective_text) |t| firstCodepoint(t) else 0, effective_text, &buf)) |bytes| {
            self.sendText(bytes);
            return true;
        }

        if (action != .release and effective_text != null and (mods & ghostty.Mods.alt) != 0 and (mods & (ghostty.Mods.ctrl | ghostty.Mods.super)) == 0) {
            self.sendText("\x1b");
            self.sendText(effective_text.?);
            return true;
        }

        return false;
    }

    pub const HitTestResult = struct {
        pane: *Pane,
        x: f32,
        y: f32,
    };

    fn paneInnerBounds(self: *const App, pane: *const Pane, bounds: PaneBounds) PaneBounds {
        const pad = self.config.terminal_padding;
        const scrollbar_gutter = @min(bounds.width, self.paneScrollbarGutter(pane));
        const trim_x = @min(bounds.width, pad.horizontal() + scrollbar_gutter);
        const trim_y = @min(bounds.height, pad.vertical());
        const inner_w = @max(@as(u32, 1), bounds.width - trim_x);
        const inner_h = @max(@as(u32, 1), bounds.height - trim_y);
        const inset_left = @min(pad.left, bounds.width - inner_w);
        const inset_top = @min(pad.top, bounds.height - inner_h);
        return .{
            .x = bounds.x + inset_left,
            .y = bounds.y + inset_top,
            .width = inner_w,
            .height = inner_h,
        };
    }

    pub fn hitTestPane(self: *App, x: f32, y: f32) ?HitTestResult {
        var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
        const leaves = self.computeActiveLayout(&layout_buf);
        const ix = @as(u32, @intFromFloat(@max(0, x)));
        const iy = @as(u32, @intFromFloat(@max(0, y)));
        var i = leaves.len;
        while (i > 0) {
            i -= 1;
            const leaf = leaves[i];
            const inner = self.paneInnerBounds(leaf.pane, leaf.bounds);
            if (ix >= leaf.bounds.x and ix < leaf.bounds.x + leaf.bounds.width and
                iy >= leaf.bounds.y and iy < leaf.bounds.y + leaf.bounds.height)
            {
                const inner_right = inner.x + inner.width;
                const inner_bottom = inner.y + inner.height;
                const clamped_x = std.math.clamp(x, @as(f32, @floatFromInt(inner.x)), @as(f32, @floatFromInt(inner_right - 1)));
                const clamped_y = std.math.clamp(y, @as(f32, @floatFromInt(inner.y)), @as(f32, @floatFromInt(inner_bottom - 1)));
                return .{
                    .pane = leaf.pane,
                    .x = clamped_x - @as(f32, @floatFromInt(inner.x)),
                    .y = clamped_y - @as(f32, @floatFromInt(inner.y)),
                };
            }
        }
        if (self.activePane()) |pane| return .{ .pane = pane, .x = x, .y = y };
        return null;
    }

    /// Hit-test the divider seams of the active tab's split tree.
    /// `radius` is the pixel slop on each side of the 2px seam line.
    /// Returns the matching DividerHit (node + its bounds) or null.
    pub fn hitTestDividerAt(self: *App, x: f32, y: f32, radius: f32) ?DividerHit {
        if (self.hitTestPane(x, y)) |hit| {
            if (hit.pane.is_floating) return null;
        }
        const mux = if (self.mux) |*m| m else return null;
        const tab = mux.activeTab() orelse return null;
        const root = tab.root_split orelse return null;
        const bounds = self.activeLayoutBounds();
        return hitTestDivider(root, bounds, x, y, radius);
    }

    /// Returns true if `node` is still a valid node in the active tab's split
    /// tree.  Used to guard against use-after-free when cached node pointers
    /// (`g_drag_node`, `pending_split_ratio_node`) might have been invalidated
    /// by tree mutations (pane close, tab switch, etc.).
    pub fn isSplitNodeValid(self: *App, node: *const SplitNode) bool {
        const mux = if (self.mux) |*m| m else return false;
        const tab = mux.activeTab() orelse return false;
        const root = tab.root_split orelse return false;
        return nodeIsInTree(root, node);
    }

    /// Directly set the ratio of a split node and schedule a layout re-flow.
    pub fn setSplitNodeRatio(self: *App, node: *SplitNode, ratio: f32) void {
        std.log.info("setSplitNodeRatio queued node={x} ratio={d:.4}", .{ @intFromPtr(node), ratio });
        self.pending_split_ratio_node = node;
        self.pending_split_ratio = std.math.clamp(ratio, 0.1, 0.9);
        self.requestLayoutResize(false);
    }

    pub fn previewSplitNodeRatio(self: *App, node: *SplitNode, ratio: f32) void {
        node.ratio = std.math.clamp(ratio, 0.1, 0.9);
        self.pending_drag_layout_resize = true;
        self.signalWake();
    }

    fn encodeMouseForPane(self: *App, pane: *Pane, action: ghostty.MouseAction, button: ?ghostty.MouseButton, x: f32, y: f32, mods: u32) !bool {

        // The DLL's mouse_encoder_encode crashes in several cases we have observed:
        //   - action=press when mouse_tracking == 0
        //   - action=release when mouse_tracking != 0 (internal state inconsistency)
        // Rather than trying to enumerate all safe vs. unsafe combinations, we bypass
        // the DLL encoder entirely and use our own SGR 1006 encoding, which is the
        // standard protocol used by modern terminals and supported by nvim, vim, etc.
        // The DLL encoder is only needed for exotic encoding modes (X10, UTF-8 coords,
        // URXVT); those are not required here, and falling back to SGR is safe for all
        // common use-cases.
        //
        // The DLL objects (mouse_encoder, mouse_event) are still created so that
        // syncMouseEncoder can keep the encoder state in sync with the terminal
        // (required for correctness if we ever re-enable the DLL path).
        // SGR 1006 mouse encoding.
        // Only encode when mouse tracking is enabled AND there's something to report.
        // - Hover motion (no button held) is suppressed — apps only care about
        //   button events and drag (button held during motion).
        if (pane.last_mouse_tracking == 0) return false;
        if (action == .motion and button == null) return false; // suppress hover motion
        if (button == null) return false; // no button info for non-motion events
        const cell_w: f32 = @floatFromInt(self.cell_width_px);
        const cell_h: f32 = @floatFromInt(self.cell_height_px);
        if (cell_w <= 0 or cell_h <= 0) return false;
        const col: u32 = @max(1, @as(u32, @intFromFloat(@max(0.0, x) / cell_w)) + 1);
        const row: u32 = @max(1, @as(u32, @intFromFloat(@max(0.0, y) / cell_h)) + 1);
        // SGR 1006 button codes: 0=left, 1=middle, 2=right, 64=scroll-up, 65=scroll-down.
        // For motion with button held, add 32 (drag modifier).
        // For release, use the same button code but final char 'm' instead of 'M'.
        // Modifier bits: shift=4, alt=8, ctrl=16.
        var sgr_button: u32 = switch (button.?) {
            .left => 0,
            .middle => 1,
            .right => 2,
            .four => 64, // scroll up
            .five => 65, // scroll down
            else => return false,
        };
        if (action == .motion) sgr_button |= 32; // drag modifier
        if ((mods & ghostty.Mods.shift) != 0) sgr_button |= 4;
        if ((mods & ghostty.Mods.alt) != 0) sgr_button |= 8;
        if ((mods & ghostty.Mods.ctrl) != 0) sgr_button |= 16;
        const final_char: u8 = if (action == .release) 'm' else 'M';
        var sgr_buf: [64]u8 = undefined;
        const sgr = std.fmt.bufPrint(&sgr_buf, "\x1b[<{d};{d};{d}{c}", .{ sgr_button, col, row, final_char }) catch return false;
        std.log.info("encodeMouseForPane: SGR encoded action={s} btn={d} col={d} row={d}", .{ @tagName(action), sgr_button, col, row });
        pane.sendText(sgr);
        return true;
    }

    pub fn sendMouse(self: *App, action: ghostty.MouseAction, button: ?ghostty.MouseButton, x: f32, y: f32, mods: u32) !bool {
        const hit = self.hitTestPane(x, y) orelse return false;
        if (action == .press) {
            if (self.mux) |*mux| {
                const was_active = mux.activePane();
                mux.setActivePane(hit.pane);
                self.syncActivePaneChange(was_active, hit.pane);
            }
        }
        return try self.encodeMouseForPane(hit.pane, action, button, hit.x, hit.y, mods);
    }

    fn refreshPaneScrollbar(self: *App, runtime: *GhosttyRuntime, pane: *Pane) ghostty.TerminalScrollbar {
        const was_visible = self.scrollbarVisible(pane.scrollbar());
        if (runtime.terminalScrollbar(pane.terminal)) |scrollbar| {
            pane.scrollbar_total = scrollbar.total;
            pane.scrollbar_offset = scrollbar.offset;
            pane.scrollbar_len = scrollbar.len;
            if (was_visible != self.scrollbarVisible(scrollbar)) self.requestLayoutResize(false);
            return scrollbar;
        }
        pane.scrollbar_total = @max(@as(u64, 1), @as(u64, pane.rows));
        pane.scrollbar_offset = 0;
        pane.scrollbar_len = @max(@as(u64, 1), pane.rows);
        const fallback = pane.scrollbar();
        if (was_visible != self.scrollbarVisible(fallback)) self.requestLayoutResize(false);
        return fallback;
    }

    fn scrollbarMaxTopRow(scrollbar: ghostty.TerminalScrollbar) u64 {
        return if (scrollbar.total > scrollbar.len) scrollbar.total - scrollbar.len else 0;
    }

    fn scrollbarTopRow(scrollbar: ghostty.TerminalScrollbar) u64 {
        return @min(scrollbar.offset, scrollbarMaxTopRow(scrollbar));
    }

    fn pageScrollRows(pane: *const Pane) isize {
        return @max(@as(isize, 1), @as(isize, @intCast(@max(@as(u16, 1), pane.rows))) - 1);
    }

    fn scrollPaneViewport(self: *App, pane: *Pane, delta: isize) void {
        if (delta == 0) return;
        const runtime = if (self.ghostty) |*rt| rt else return;
        std.log.info("scrollPaneViewport pane={x} ui_delta={d}", .{ @intFromPtr(pane), delta });
        runtime.terminalScroll(pane.terminal, delta);
        pane.render_dirty = .full;
        pane.last_render_state_update_ns = 0;
        pane.pty_received_data = true;
        self.scroll_accum = 0;
        _ = self.refreshPaneScrollbar(runtime, pane);
        self.syncDraggedSelectionToPointer(pane);
    }

    fn syncDraggedSelectionToPointer(self: *App, pane: *Pane) void {
        if (!self.selection_drag_active or self.selection_pane != pane) return;
        const hit = self.hitTestPane(self.pointer_x, self.pointer_y) orelse return;
        if (hit.pane != pane) return;
        self.selectionUpdate(pane, self.cellPointFromPaneLocal(pane, hit.x, hit.y));
    }

    fn forceScrollPaneViewportToRow(self: *App, pane: *Pane, top_row: u64) void {
        const runtime = if (self.ghostty) |*rt| rt else return;
        const scrollbar = self.refreshPaneScrollbar(runtime, pane);
        const max_top = scrollbarMaxTopRow(scrollbar);
        const clamped_target = @min(top_row, max_top);

        if (clamped_target == 0) {
            runtime.terminalScrollTop(pane.terminal);
        } else if (clamped_target == max_top) {
            runtime.terminalScrollBottom(pane.terminal);
        } else {
            runtime.terminalScrollTop(pane.terminal);
            const delta_i64: i64 = @intCast(clamped_target);
            const delta: isize = std.math.cast(isize, delta_i64) orelse std.math.maxInt(isize);
            runtime.terminalScroll(pane.terminal, delta);
        }

        pane.render_dirty = .full;
        pane.render_state_fresh = false;
        pane.last_render_state_update_ns = 0;
        pane.pty_received_data = true;
        self.scroll_accum = 0;
        _ = self.refreshPaneScrollbar(runtime, pane);
    }

    fn restorePaneViewportFromBottom(self: *App, pane: *Pane, top_row: usize) void {
        const runtime = if (self.ghostty) |*rt| rt else return;
        const scrollbar = self.refreshPaneScrollbar(runtime, pane);
        const max_top: usize = @intCast(scrollbarMaxTopRow(scrollbar));
        const clamped_target = @min(top_row, max_top);

        runtime.terminalScrollBottom(pane.terminal);
        if (clamped_target < max_top) {
            const delta_i64: i64 = -@as(i64, @intCast(max_top - clamped_target));
            const delta: isize = std.math.cast(isize, delta_i64) orelse std.math.minInt(isize);
            runtime.terminalScroll(pane.terminal, delta);
        }

        pane.render_dirty = .full;
        pane.render_state_fresh = false;
        pane.last_render_state_update_ns = 0;
        pane.pty_received_data = true;
        self.scroll_accum = 0;
        _ = self.refreshPaneScrollbar(runtime, pane);
    }

    fn scrollPaneViewportToRow(self: *App, pane: *Pane, top_row: u64) void {
        const runtime = if (self.ghostty) |*rt| rt else return;
        const scrollbar = self.refreshPaneScrollbar(runtime, pane);
        const max_top = scrollbarMaxTopRow(scrollbar);
        const clamped_target = @min(top_row, max_top);
        const current_top = scrollbarTopRow(scrollbar);
        if (clamped_target == current_top) return;

        if (clamped_target == 0) {
            runtime.terminalScrollTop(pane.terminal);
            pane.render_dirty = .full;
            pane.last_render_state_update_ns = 0;
            pane.pty_received_data = true;
            self.scroll_accum = 0;
            _ = self.refreshPaneScrollbar(runtime, pane);
            return;
        }

        if (clamped_target == max_top) {
            runtime.terminalScrollBottom(pane.terminal);
            pane.render_dirty = .full;
            pane.last_render_state_update_ns = 0;
            pane.pty_received_data = true;
            self.scroll_accum = 0;
            _ = self.refreshPaneScrollbar(runtime, pane);
            return;
        }

        const target_i64: i64 = @intCast(clamped_target);
        const current_i64: i64 = @intCast(current_top);
        const delta_i64 = target_i64 - current_i64;
        const delta: isize = std.math.cast(isize, delta_i64) orelse if (delta_i64 < 0)
            std.math.minInt(isize)
        else
            std.math.maxInt(isize);
        self.scrollPaneViewport(pane, delta);
    }

    fn scrollActiveViewport(self: *App, delta: isize) void {
        const pane = self.activePane() orelse return;
        self.scrollPaneViewport(pane, delta);
    }

    fn scrollActiveViewportPage(self: *App, pages: isize) void {
        const pane = self.activePane() orelse return;
        self.scrollPaneViewport(pane, pages * pageScrollRows(pane));
    }

    fn scrollActiveViewportTop(self: *App) void {
        const pane = self.activePane() orelse return;
        self.scrollPaneViewportToRow(pane, 0);
    }

    fn scrollActiveViewportBottom(self: *App) void {
        const pane = self.activePane() orelse return;
        self.scrollPaneViewportToRow(pane, scrollbarMaxTopRow(pane.scrollbar()));
    }

    fn handlePromptJump(self: *App, direction: PromptJumpDir) void {
        const pane = self.activePane() orelse return;
        const runtime = if (self.ghostty) |*rt| rt else return;
        const scrollbar = self.refreshPaneScrollbar(runtime, pane);
        const total: usize = @intCast(scrollbar.total);
        if (total == 0) return;
        const visible = @max(@as(usize, 1), @as(usize, pane.rows));
        const current_top: usize = @intCast(scrollbarTopRow(scrollbar));
        const start_row = switch (direction) {
            .next => current_top +| visible,
            .prev => current_top -| 1,
        };
        const target_row = findPromptJumpTarget(.{ .live = .{ .runtime = runtime, .terminal = pane.terminal } }, direction, start_row, total) orelse return;
        self.scrollPaneViewportToRow(pane, target_row);
    }

    fn paneScrollbarMetrics(self: *App, pane: *Pane, outer_bounds: PaneBounds) ?ScrollbarMetrics {
        if (!self.config.scrollbar.enabled) return null;
        const gutter = self.paneScrollbarGutter(pane);
        if (gutter == 0 or outer_bounds.width <= gutter) return null;

        const scrollbar = pane.scrollbar();
        if (scrollbar.len == 0 or scrollbar.total <= scrollbar.len) return null;
        const track_len = scrollbar.len;
        const total = scrollbar.total;

        const margin_f: f32 = @floatFromInt(self.config.scrollbar.margin);
        const width_f: f32 = @floatFromInt(@max(@as(u32, 1), self.config.scrollbar.width));
        const gutter_f: f32 = @floatFromInt(gutter);
        const track_x = @as(f32, @floatFromInt(outer_bounds.x)) + @as(f32, @floatFromInt(outer_bounds.width)) - gutter_f + margin_f;
        const track_y = @as(f32, @floatFromInt(outer_bounds.y)) + margin_f;
        const track_h = @max(@as(f32, 1.0), @as(f32, @floatFromInt(outer_bounds.height)) - margin_f * 2.0);
        const min_thumb_h: f32 = @floatFromInt(@max(@as(u32, 1), self.config.scrollbar.min_thumb_size));
        const visible_ratio = @as(f32, @floatFromInt(track_len)) / @as(f32, @floatFromInt(total));
        const thumb_h = @min(track_h, @max(min_thumb_h, track_h * visible_ratio));
        const max_top = if (total > track_len) total - track_len else 0;
        const travel = @max(@as(f32, 0.0), track_h - thumb_h);
        const ui_offset = scrollbarTopRow(scrollbar);
        const thumb_y = track_y + if (max_top == 0)
            0.0
        else
            travel * (@as(f32, @floatFromInt(ui_offset)) / @as(f32, @floatFromInt(max_top)));

        return .{
            .pane = pane,
            .outer_bounds = outer_bounds,
            .track_x = track_x,
            .track_y = track_y,
            .track_w = width_f,
            .track_h = track_h,
            .thumb_y = thumb_y,
            .thumb_h = thumb_h,
            .total = total,
            .offset = ui_offset,
            .len = track_len,
        };
    }

    pub fn scrollbarMetricsForPane(self: *App, pane: *Pane) ?ScrollbarMetrics {
        var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
        const leaves = self.computeActiveLayout(&layout_buf);
        for (leaves) |leaf| {
            if (leaf.pane == pane) return self.paneScrollbarMetrics(pane, leaf.bounds);
        }

        if (self.activePane() == pane) {
            const tbh = self.tabBarHeight();
            const bbh = self.bottomBarHeight();
            const pane_h = if (self.config.window_height > tbh + bbh) self.config.window_height - tbh - bbh else 1;
            return self.paneScrollbarMetrics(pane, .{
                .x = 0,
                .y = tbh,
                .width = self.config.window_width,
                .height = pane_h,
            });
        }

        return null;
    }

    pub fn hitTestScrollbar(self: *App, x: f32, y: f32) ?ScrollbarMetrics {
        var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
        const leaves = self.computeActiveLayout(&layout_buf);
        var i = leaves.len;
        while (i > 0) {
            i -= 1;
            const leaf = leaves[i];
            const metrics = self.paneScrollbarMetrics(leaf.pane, leaf.bounds) orelse continue;
            if (x >= metrics.track_x and x < metrics.track_x + metrics.track_w and y >= metrics.track_y and y < metrics.track_y + metrics.track_h) {
                return metrics;
            }
        }

        if (self.activePane()) |pane| {
            if (self.scrollbarMetricsForPane(pane)) |metrics| {
                if (x >= metrics.track_x and x < metrics.track_x + metrics.track_w and y >= metrics.track_y and y < metrics.track_y + metrics.track_h) {
                    return metrics;
                }
            }
        }

        return null;
    }

    pub fn scroll(self: *App, x: f32, y: f32, delta: isize, mods: u32) void {
        const hit = self.hitTestPane(x, y) orelse return;
        if (self.copy_mode_active and self.copy_mode_pane == hit.pane) {
            if (self.hitTestScrollbar(x, y)) |metrics| {
                const ratio = std.math.clamp((y - metrics.track_y) / metrics.track_h, 0.0, 1.0);
                const runtime = if (self.ghostty) |*rt| rt else return;
                const scrollbar = self.refreshPaneScrollbar(runtime, hit.pane);
                const max_top: usize = @intCast(scrollbarMaxTopRow(scrollbar));
                const target = @as(u64, @intFromFloat(@round(ratio * @as(f32, @floatFromInt(max_top)))));
                self.copyModeScrollToRow(target);
            } else {
                self.copyModeScrollDelta(delta);
            }
            return;
        }
        const runtime = if (self.ghostty) |*rt| rt else return;
        const scrollbar = self.refreshPaneScrollbar(runtime, hit.pane);
        const max_top = scrollbarMaxTopRow(scrollbar);
        const in_scrollback = scrollbarTopRow(scrollbar) < max_top;
        const over_scrollbar = self.hitTestScrollbar(x, y) != null;
        const should_scroll_viewport = in_scrollback or over_scrollbar or hit.pane.last_mouse_tracking == 0;

        if (should_scroll_viewport) {
            self.scrollPaneViewport(hit.pane, delta);
            return;
        }

        const count: usize = @intCast(if (delta < 0) -delta else delta);
        if (count > 0) {
            const button: ghostty.MouseButton = if (delta < 0) .four else .five;
            // Try to encode scroll as mouse button 4/5 (for programs that support
            // mouse reporting, like nvim).  If the encoder returns sequences, the
            // scroll reaches the application via the PTY.
            if (self.encodeMouseForPane(hit.pane, .press, button, hit.x, hit.y, mods) catch false) {
                var i: usize = 1;
                while (i < count) : (i += 1) {
                    _ = self.encodeMouseForPane(hit.pane, .press, button, hit.x, hit.y, mods) catch false;
                }
                return;
            }
        }
        // Fallback: adjust ghostty's viewport directly.  This is correct when the
        // application does NOT use mouse reporting (plain shell scrollback).
        // When an app like nvim IS using mouse reporting but the encoder failed,
        // this only moves the viewport without notifying the app — the visual
        // result depends on the app re-rendering on its own.
        self.scrollPaneViewport(hit.pane, delta);
    }

    /// Scroll with a raw float delta (e.g. from a touchpad or smooth mouse
    /// wheel).  Fractional amounts are accumulated and fired as whole-line
    /// steps so no scroll motion is silently dropped.
    pub fn scrollFloat(self: *App, x: f32, y: f32, raw_delta: f32, mods: u32) void {
        self.scroll_accum += raw_delta * self.config.scroll_multiplier;
        const steps = @as(isize, @intFromFloat(self.scroll_accum));
        if (steps != 0) {
            self.scroll_accum -= @as(f32, @floatFromInt(steps));
            std.log.info("scroll: raw_delta={d:.3} accum_after={d:.3} steps={d}", .{ raw_delta, self.scroll_accum, steps });
            self.scroll(x, y, steps, mods);
        }
    }

    pub fn hasLiveChild(self: *App) bool {
        if (self.activePane()) |pane| return pane.hasLiveChild();
        return false;
    }

    pub fn activeWorkspace(self: *App) ?*Workspace {
        if (self.mux) |*mux| return mux.activeWorkspace();
        return null;
    }

    pub fn activeTab(self: *App) ?*Tab {
        if (self.mux) |*mux| return mux.activeTab();
        return null;
    }

    pub fn activePane(self: *App) ?*Pane {
        if (self.mux) |*mux| return mux.activePane();
        return null;
    }

    pub fn tabById(self: *App, id: usize) ?*Tab {
        if (self.mux) |*mux| return mux.tabById(id);
        return null;
    }

    pub fn reloadConfig(self: *App) bool {
        if (!self.using_embedded_base_config and self.base_config_path == null and self.override_config_path == null) return false;

        const old_window_width = self.config.window_width;
        const old_window_height = self.config.window_height;
        const old_cell_width = self.cell_width_px;
        const old_cell_height = self.cell_height_px;

        self.config.deinit();
        self.config = Config.init(self.allocator);
        self.invalidateCachedBarLayouts();

        if (self.lua) |*lua| {
            lua.deinit();
            self.lua = null;
        }

        self.tryInitLua();
        if (self.lua == null) return false;
        std.log.info("config: command_timing={}", .{self.config.command_timing});
        self.syncCommandTimingEnv();

        if (self.config.window_width == 1280 and old_window_width != 0) self.config.window_width = old_window_width;
        if (self.config.window_height == 800 and old_window_height != 0) self.config.window_height = old_window_height;
        self.cell_width_px = @max(1, old_cell_width);
        self.cell_height_px = @max(1, old_cell_height);

        if (self.ghostty) |*runtime| {
            if (self.mux) |*mux| {
                var panes = mux.paneIterator();
                while (panes.next()) |pane| {
                    pane.refreshTitle(runtime, self.config.windowTitle(), self.config.shellForDomain(if (pane.domain_name.len > 0) pane.domain_name else null) catch self.config.shellOrDefault());
                    _ = pane.refreshCwd();
                }
                if (mux.activePane()) |active| runtime.registerCallbacks(active.terminal, terminalCallbacks());
            }
            self.pending_renderer_refresh = self.config.backend == .sokol or self.config.backend == .webgpu;
            self.resize(self.config.window_width, self.config.window_height);
            self.requestLayoutResize(true);
        }

        const window_title = titleCString(self.activeTitle());
        sapp_set_window_title(&window_title);

        if (self.lua) |*lua| self.registerLuaCallbacks(lua);
        self.emitLuaBuiltInEvent("config:reloaded", .none);
        return true;
    }

    pub fn newTab(self: *App, domain_name: ?[]const u8, command: ?[]const u8, callback_ref: c_int) void {
        const start_ms = std.time.milliTimestamp();
        var mux = if (self.mux) |*value| value else return;
        const runtime = if (self.ghostty) |*value| value else return;
        const cbs = terminalCallbacks();
        const previous = mux.activePane();
        const launch_command: ?LaunchCommand = if (command) |value|
            .{ .command = value }
        else
            null;
        mux.newTab(runtime, cbs, self.config, self.cell_width_px, self.cell_height_px, self.config.window_width, self.config.window_height, domain_name, launch_command) catch |err| {
            std.log.err("app: newTab failed: {s}", .{@errorName(err)});
            if (self.lua) |*lua| lua.invokeOperationCallback(callback_ref, false, .none);
            return;
        };
        self.requestLayoutResize(false);
        self.syncActivePaneChange(previous, mux.activePane());
        const tab_id = if (mux.activeTab()) |tab| tab.id else 0;
        if (mux.activeTab()) |tab| {
            self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
        }
        self.bindHtpHandlers();
        if (self.lua) |*lua| lua.invokeOperationCallback(callback_ref, true, .{ .tab_id = tab_id });
        std.log.info("app: newTab total_ms={d}", .{std.time.milliTimestamp() - start_ms});
        std.log.info("app: created new tab", .{});
    }

    pub fn closeTab(self: *App) void {
        var mux = if (self.mux) |*value| value else return;
        const runtime = if (self.ghostty) |*value| value else return;
        const closed_tab_id = if (mux.activeTab()) |tab| tab.id else null;
        const should_quit = mux.closeTab(runtime);
        if (closed_tab_id) |tab_id| {
            self.emitLuaBuiltInEvent("term:tab_closed", .{ .tab_id = tab_id });
        }
        if (should_quit) {
            std.log.info("app: last tab closed, quitting", .{});
            self.pending_quit = true;
            return;
        }
        self.refreshActivePaneBinding();
        if (mux.activeTab()) |tab| {
            self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
        }
        self.requestLayoutRefresh();
    }

    pub fn closeTabAt(self: *App, index: usize) void {
        var mux = if (self.mux) |*value| value else return;
        const runtime = if (self.ghostty) |*value| value else return;
        const closed_tab_id = if (mux.tabAt(index)) |tab| tab.id else null;
        const should_quit = mux.closeTabAt(runtime, index);
        if (closed_tab_id) |tab_id| {
            self.emitLuaBuiltInEvent("term:tab_closed", .{ .tab_id = tab_id });
        }
        if (should_quit) {
            std.log.info("app: last tab closed, quitting", .{});
            self.pending_quit = true;
            return;
        }
        self.refreshActivePaneBinding();
        if (mux.activeTab()) |tab| {
            self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
        }
        self.requestLayoutRefresh();
    }

    pub fn closeActivePane(self: *App) void {
        var mux = if (self.mux) |*value| value else return;
        const runtime = if (self.ghostty) |*value| value else return;
        const should_quit = mux.closeActivePane(runtime);
        if (should_quit) {
            std.log.info("app: last pane closed via close_pane, quitting", .{});
            self.pending_quit = true;
            return;
        }
        self.refreshActivePaneBinding();
        self.requestLayoutResize(false);
        std.log.info("app: active pane closed via close_pane", .{});
    }

    pub fn closePaneById(self: *App, pane_id: usize) void {
        var mux = if (self.mux) |*value| value else return;
        const runtime = if (self.ghostty) |*value| value else return;
        const previous = mux.activePane();
        const should_quit = mux.closePaneById(runtime, pane_id);
        if (should_quit) {
            std.log.info("app: last pane closed via close_pane_by_id, quitting", .{});
            self.pending_quit = true;
            return;
        }
        self.syncActivePaneChange(previous, mux.activePane());
        self.refreshActivePaneBinding();
        self.requestLayoutResize(false);
        self.requestLayoutRefresh();
    }

    pub fn focusPaneById(self: *App, pane_id: usize) void {
        if (self.mux) |*mux| {
            const previous = mux.activePane();
            if (!mux.focusPaneById(pane_id)) return;
            self.syncActivePaneChange(previous, mux.activePane());
            self.refreshActivePaneDisplay();
            if (mux.activeTab()) |tab| self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
            self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
            self.emitLuaBuiltInEvent("term:pane_focused", .{ .pane_id = pane_id });
            self.requestLayoutRefresh();
        }
    }

    pub fn nextTab(self: *App) void {
        if (self.mux) |*mux| {
            const previous = mux.activePane();
            mux.nextTab();
            self.syncActivePaneChange(previous, mux.activePane());
            self.refreshActivePaneDisplay();
            if (mux.activeTab()) |tab| self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
        }
        self.requestLayoutRefresh();
    }

    pub fn prevTab(self: *App) void {
        if (self.mux) |*mux| {
            const previous = mux.activePane();
            mux.prevTab();
            self.syncActivePaneChange(previous, mux.activePane());
            self.refreshActivePaneDisplay();
            if (mux.activeTab()) |tab| self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
        }
        self.requestLayoutRefresh();
    }

    pub fn newWorkspace(self: *App, cwd: ?[]const u8, domain_name: ?[]const u8, command: ?[]const u8, name: ?[]const u8, callback_ref: c_int) void {
        const start_ms = std.time.milliTimestamp();
        std.log.info("app: newWorkspace start_ms={d}", .{start_ms});
        var mux = if (self.mux) |*value| value else return;
        const runtime = if (self.ghostty) |*value| value else return;
        const cbs = terminalCallbacks();
        const previous = mux.activePane();
        const inherited_domain = if (domain_name) |value|
            if (value.len > 0) value else null
        else if (previous) |pane|
            if (pane.domain_name.len > 0) pane.domain_name else null
        else
            null;
        const inherited_cwd = if (cwd) |value|
            if (value.len > 0) value else null
        else if (previous) |pane|
            if (pane.cwd.len > 0 and std.mem.eql(u8, pane.domain_name, inherited_domain orelse "")) pane.cwd else null
        else
            null;
        mux.newWorkspace(runtime, cbs, self.config, self.cell_width_px, self.cell_height_px, self.config.window_width, self.config.window_height, inherited_cwd, inherited_domain, null, name) catch |err| {
            std.log.err("app: newWorkspace failed: {s}", .{@errorName(err)});
            if (self.lua) |*lua| lua.invokeOperationCallback(callback_ref, false, .none);
            return;
        };
        self.bindHtpHandlers();
        self.syncActivePaneChange(previous, mux.activePane());
        if (command) |value| {
            if (mux.activePane()) |pane| pane.sendText(value);
        }
        self.emitLuaBuiltInEvent("workspace:new", .{ .workspace_index = mux.activeWorkspaceIndex() });
        self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
        self.requestLayoutResize(false);
        if (self.lua) |*lua| lua.invokeOperationCallback(callback_ref, true, .{ .workspace_index = mux.activeWorkspaceIndex() });
        std.log.info("app: newWorkspace total_ms={d}", .{std.time.milliTimestamp() - start_ms});
        std.log.info("app: created new workspace", .{});
    }

    pub fn closeWorkspace(self: *App, workspace_id: ?usize) void {
        var mux = if (self.mux) |*value| value else return;
        const runtime = if (self.ghostty) |*value| value else return;
        const closing_active_workspace = if (workspace_id) |target_id|
            if (mux.activeWorkspace()) |workspace| workspace.id == target_id else false
        else
            mux.activeWorkspace() != null;
        const previous = if (closing_active_workspace) null else mux.activePane();
        const should_quit = mux.closeWorkspace(runtime, workspace_id);
        if (should_quit) {
            std.log.info("app: last workspace closed, quitting", .{});
            self.pending_quit = true;
            return;
        }
        self.syncActivePaneChange(previous, mux.activePane());
        self.refreshActivePaneDisplay();
        if (mux.activeTab()) |tab| self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
        self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
        self.requestLayoutRefresh();
    }

    pub fn nextWorkspace(self: *App) void {
        if (self.mux) |*mux| {
            const previous = mux.activePane();
            mux.nextWorkspace();
            self.syncActivePaneChange(previous, mux.activePane());
            self.refreshActivePaneDisplay();
            self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
            self.requestLayoutRefresh();
        }
    }

    pub fn prevWorkspace(self: *App) void {
        if (self.mux) |*mux| {
            const previous = mux.activePane();
            mux.prevWorkspace();
            self.syncActivePaneChange(previous, mux.activePane());
            self.refreshActivePaneDisplay();
            self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
            self.requestLayoutRefresh();
        }
    }

    pub fn workspaceCount(self: *App) usize {
        if (self.mux) |*mux| return mux.workspaceCount();
        return 0;
    }

    pub fn activeWorkspaceIndex(self: *App) usize {
        if (self.mux) |*mux| return mux.activeWorkspaceIndex();
        return 0;
    }

    pub fn switchWorkspace(self: *App, index: usize) void {
        if (self.mux) |*mux| {
            const previous = mux.activePane();
            mux.switchWorkspace(index);
            self.syncActivePaneChange(previous, mux.activePane());
            self.refreshActivePaneDisplay();
            if (mux.activeTab()) |tab| self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
            self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
            self.requestLayoutRefresh();
        }
    }

    pub fn splitPane(self: *App, direction: SplitDirection, ratio: f32, domain_name: ?[]const u8, cwd: ?[]const u8, command: ?[]const u8, command_mode: SplitCommandMode, close_on_exit: bool, floating: bool, fullscreen: bool, x: ?f32, y: ?f32, width: ?f32, height: ?f32, callback_ref: c_int) void {
        const start_ms = std.time.milliTimestamp();
        var mux = if (self.mux) |*value| value else return;
        const runtime = if (self.ghostty) |*value| value else return;
        const cbs = terminalCallbacks();
        const previous = mux.activePane();
        const launch_command: ?LaunchCommand = if (command != null and command_mode == .spawn)
            .{ .command = command.?, .close_on_exit = close_on_exit }
        else
            null;
        const pane = mux.splitActivePane(runtime, cbs, self.config, self.cell_width_px, self.cell_height_px, self.config.window_width, self.config.window_height, direction, ratio, domain_name, cwd, floating, launch_command) catch |err| {
            std.log.err("app: splitPane failed: {s}", .{@errorName(err)});
            if (self.lua) |*lua| lua.invokeOperationCallback(callback_ref, false, .none);
            return;
        };
        if (floating) {
            if (x != null or y != null or width != null or height != null) {
                _ = mux.setFloatingPaneBounds(
                    pane,
                    x orelse pane.floating_x,
                    y orelse pane.floating_y,
                    width orelse pane.floating_width,
                    height orelse pane.floating_height,
                );
            }
        }
        if (fullscreen) {
            _ = mux.togglePaneMaximized(pane, false);
        }
        if (command_mode == .send) {
            if (command) |cmd| {
                sendSplitPaneCommand(self, pane, cmd, close_on_exit);
            }
        }
        self.bindHtpHandlers();
        self.syncActivePaneChange(previous, mux.activePane());
        if (self.lua) |*lua| lua.invokeOperationCallback(callback_ref, true, .{ .pane_id = @intFromPtr(pane) });
        // Schedule a layout resize for the next tick() (frame callback thread),
        // rather than calling ghostty_terminal_resize from the event callback thread.
        self.requestLayoutResize(false);
        std.log.info("app: splitPane total_ms={d}", .{std.time.milliTimestamp() - start_ms});
        std.log.info("app: pane split done direction={s}", .{@tagName(direction)});
    }

    pub fn resizePane(self: *App, direction: SplitDirection, delta: f32) void {
        if (self.mux) |*mux| {
            mux.resizeActivePane(direction, delta);
            self.requestLayoutResize(false);
        }
    }

    pub fn togglePaneMaximizedById(self: *App, pane_id: usize, show_background: bool) void {
        const pane = self.findPaneById(pane_id) orelse return;
        if (self.mux) |*mux| {
            const previous = mux.activePane();
            if (!mux.togglePaneMaximized(pane, show_background)) return;
            self.syncActivePaneChange(previous, mux.activePane());
            self.requestLayoutResize(false);
            self.emitLuaBuiltInEvent("term:pane_focused", .{ .pane_id = pane_id });
            self.emitLuaBuiltInEvent("term:pane_layout_changed", .{ .pane_layout_changed = .{ .pane_id = pane_id } });
        }
    }

    pub fn setPaneFloatingById(self: *App, pane_id: usize, floating: bool) void {
        const pane = self.findPaneById(pane_id) orelse return;
        if (self.mux) |*mux| {
            const previous = mux.activePane();
            if (!mux.setPaneFloating(pane, floating)) return;
            self.syncActivePaneChange(previous, mux.activePane());
            self.requestLayoutResize(false);
            if (floating) self.emitLuaBuiltInEvent("term:pane_focused", .{ .pane_id = pane_id });
            self.emitLuaBuiltInEvent("term:pane_layout_changed", .{ .pane_layout_changed = .{ .pane_id = pane_id } });
        }
    }

    pub fn setFloatingPaneBoundsById(self: *App, pane_id: usize, x: f32, y: f32, width: f32, height: f32) void {
        const pane = self.findPaneById(pane_id) orelse return;
        if (self.mux) |*mux| {
            if (!mux.setFloatingPaneBounds(pane, x, y, width, height)) return;
            self.requestLayoutResize(false);
            self.emitLuaBuiltInEvent("term:pane_layout_changed", .{ .pane_layout_changed = .{ .pane_id = pane_id } });
        }
    }

    pub fn movePaneById(self: *App, pane_id: usize, direction: FocusDirection, amount: f32) void {
        const pane = self.findPaneById(pane_id) orelse return;
        if (self.mux) |*mux| {
            if (!mux.movePane(pane, direction, self.config.window_width, self.config.window_height, amount)) return;
            self.requestLayoutResize(false);
            self.emitLuaBuiltInEvent("term:pane_layout_changed", .{ .pane_layout_changed = .{ .pane_id = pane_id } });
        }
    }

    pub fn focusPane(self: *App, direction: FocusDirection) void {
        if (self.mux) |*mux| {
            const previous = mux.activePane();
            mux.focusPaneInDirection(direction, self.config.window_width, self.config.window_height);
            self.syncActivePaneChange(previous, mux.activePane());
            if (mux.activePane()) |pane| {
                if (previous != pane) self.emitLuaBuiltInEvent("term:pane_focused", .{ .pane_id = @intFromPtr(pane) });
            }
        }
    }

    pub fn computeActiveLayout(self: *App, out: []LayoutLeaf) []LayoutLeaf {
        const bounds = self.activeLayoutBounds();
        if (self.mux) |*mux| {
            const tab = mux.activeTab() orelse return out[0..0];
            return tab.computeLayoutInBounds(bounds, out);
        }
        return out[0..0];
    }

    fn activeLayoutBounds(self: *App) PaneBounds {
        const tbh = self.tabBarHeight();
        const bbh = self.bottomBarHeight();
        const height = if (self.config.window_height > tbh + bbh) self.config.window_height - tbh - bbh else 1;
        const sidebar = self.sidebarLayout();
        const left_inset = if (sidebar != null and sidebar.?.reserve and sidebar.?.side == .left)
            self.sidebarReservedWidthPx(sidebar.?)
        else
            0;
        const right_inset = if (sidebar != null and sidebar.?.reserve and sidebar.?.side == .right)
            self.sidebarReservedWidthPx(sidebar.?)
        else
            0;
        const width = if (self.config.window_width > left_inset + right_inset)
            self.config.window_width - left_inset - right_inset
        else
            1;
        return .{
            .x = left_inset,
            .y = tbh,
            .width = width,
            .height = height,
        };
    }

    pub fn sidebarLayout(self: *App) ?SidebarLayout {
        if (self.cached_bar_layouts_dirty) self.refreshCachedBarLayouts();
        if (self.cached_sidebar_layout) |layout| return layout;
        return null;
    }

    pub fn sidebarReservedWidthPx(self: *App, sidebar: SidebarLayout) u32 {
        if (!sidebar.reserve or sidebar.width_cols == 0) return 0;
        const cols_u32 = std.math.cast(u32, sidebar.width_cols) orelse std.math.maxInt(u32);
        const base = cols_u32 * self.cell_width_px;
        return @min(self.config.window_width, base + self.cell_width_px);
    }

    pub fn activeTitle(self: *App) []const u8 {
        if (self.activePane()) |pane| {
            if (pane.usesWslBypass()) {
                if (pane.title.len > 0) return prefixedWindowTitle("[wsl-bypass] ", pane.title);
                return prefixedWindowTitle("[wsl-bypass] ", self.config.windowTitle());
            }
            if (pane.title.len > 0) return pane.title;
        }
        return self.config.windowTitle();
    }

    fn prefixedWindowTitle(prefix: []const u8, title: []const u8) []const u8 {
        const prefix_len = @min(prefix.len, g_prefixed_window_title_buf.len);
        fastmem.copy(u8, g_prefixed_window_title_buf[0..prefix_len], prefix[0..prefix_len]);
        const room = g_prefixed_window_title_buf.len - prefix_len;
        const title_len = @min(title.len, room);
        fastmem.copy(u8, g_prefixed_window_title_buf[prefix_len .. prefix_len + title_len], title[0..title_len]);
        return g_prefixed_window_title_buf[0 .. prefix_len + title_len];
    }

    /// Height in pixels of the shared top bar. 0 when hidden.
    pub fn tabBarHeight(self: *App) u32 {
        if (!self.shouldShowTopBar()) return 0;
        if (self.topBarLayout()) |layout| return layout.height_px;
        if (self.config.top_bar_height > 0) return self.config.top_bar_height;
        return (self.cell_height_px * 3 / 2 + 1) & ~@as(u32, 1);
    }

    pub fn shouldShowTopBar(self: *App) bool {
        return switch (self.config.top_bar_mode) {
            .always => true,
            .tabs => self.tabCount() > 1,
        };
    }

    pub fn topBarLayout(self: *App) ?TopBarLayout {
        if (!self.shouldShowTopBar()) return null;
        if (self.cached_bar_layouts_dirty) self.refreshCachedBarLayouts();
        if (self.cached_top_bar_layout) |layout| return layout;
        if (self.config.top_bar_height == 0) return null;
        return .{ .height_px = self.config.top_bar_height };
    }

    pub fn bottomBarLayout(self: *App) ?BottomBarLayout {
        if (!self.config.bottom_bar_show) return null;
        if (self.bottombar_cache_dirty) self.cached_bar_layouts_dirty = true;
        if (self.cached_bar_layouts_dirty) self.refreshCachedBarLayouts();
        if (self.cached_bottom_bar_layout) |layout| return layout;
        if (self.config.bottom_bar_height == 0) return null;
        return .{ .height_px = self.config.bottom_bar_height };
    }

    fn refreshCachedBarLayouts(self: *App) void {
        self.cached_bar_layouts_dirty = false;
        self.cached_sidebar_layout = null;
        self.cached_top_bar_layout = null;
        self.cached_bottom_bar_layout = null;
        if (self.lua) |*lua| {
            self.cached_sidebar_layout = lua.resolveSidebarLayout();
            if (self.shouldShowTopBar()) self.cached_top_bar_layout = lua.resolveTopBarLayout();
            if (self.config.bottom_bar_show) self.cached_bottom_bar_layout = lua.resolveBottomBarLayout();
        }
    }

    pub fn bottomBarHeight(self: *App) u32 {
        if (self.bottomBarLayout()) |layout| return layout.height_px;
        return 0;
    }

    pub fn shouldDrawWorkspaceSwitcher(self: *App) bool {
        return self.workspaceCount() > 0;
    }

    pub fn tabCount(self: *App) usize {
        if (self.mux) |*mux| return mux.tabCount();
        return 0;
    }

    /// Return the title of the tab at the given 0-based index (falls back to
    /// config window title if the tab or its active pane have no title).
    pub fn tabTitle(self: *App, index: usize) []const u8 {
        if (self.mux) |*mux| {
            if (mux.activeWorkspace()) |ws| {
                if (index < ws.tabs.items.len) {
                    const tab = ws.tabs.items[index];
                    if (tab.activePane()) |pane| {
                        if (pane.title.len > 0) return pane.title;
                    }
                }
            }
        }
        return self.config.windowTitle();
    }

    pub fn tabIndexById(self: *App, tab_id: usize) ?usize {
        const ws = self.activeWorkspace() orelse return null;
        for (ws.tabs.items, 0..) |tab, index| {
            if (tab.id == tab_id) return index;
        }
        return null;
    }

    pub fn topBarTitle(self: *App, index: usize, hover_close: bool, out_buf: []u8) []const u8 {
        const fallback = self.tabTitle(index);
        if (self.lua) |*lua| {
            return lua.resolveTopBarTitle(
                index,
                index == self.activeTabIndex(),
                self.hovered_tab_index != null and self.hovered_tab_index.? == index,
                hover_close,
                fallback,
                out_buf,
            ).text;
        }
        return fallback;
    }

    pub fn topBarTitleSegment(self: *App, index: usize, hover_close: bool, out_buf: []u8) bar.Segment {
        const fallback = self.tabTitle(index);
        if (self.lua) |*lua| {
            return lua.resolveTopBarTitle(
                index,
                index == self.activeTabIndex(),
                self.hovered_tab_index != null and self.hovered_tab_index.? == index,
                hover_close,
                fallback,
                out_buf,
            );
        }
        return .{ .text = fallback };
    }


    pub fn setWorkspaceName(self: *App, name: []const u8) void {
        const ws = self.activeWorkspace() orelse return;
        ws.setName(name) catch |err| {
            std.log.err("app: setWorkspaceName failed: {s}", .{@errorName(err)});
            return;
        };
        if (self.mux) |*mux| self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
    }

    pub fn setWorkspaceDefaultCwd(self: *App, cwd: []const u8) void {
        const ws = self.activeWorkspace() orelse return;
        ws.setDefaultCwd(if (cwd.len > 0) cwd else null) catch |err| {
            std.log.err("app: setWorkspaceDefaultCwd failed: {s}", .{@errorName(err)});
        };
    }

    pub fn workspaceName(self: *App, index: usize, out_buf: []u8) []const u8 {
        if (self.mux) |*mux| {
            if (index < mux.workspaces.items.len) return mux.workspaces.items[index].title();
        }
        return std.fmt.bufPrint(out_buf, "workspace {d}", .{index + 1}) catch "workspace";
    }

    pub fn workspaceId(self: *App, index: usize) usize {
        if (self.mux) |*mux| {
            if (index < mux.workspaces.items.len) return mux.workspaces.items[index].id;
        }
        return 0;
    }

    pub fn hasCustomTopBarTabs(self: *App) bool {
        if (self.lua) |*lua| return lua.hasTopBarFormatter();
        return false;
    }

    pub fn hasCustomWorkspaceTitle(self: *App) bool {
        if (self.lua) |*lua| return lua.hasWorkspaceTitleFormatter();
        return false;
    }

    pub fn topBarStatus(self: *App, side: bar.Side, segments: []bar.Segment, text_buf: []u8) []bar.Segment {
        if (self.lua) |*lua| {
            return lua.resolveTopBarStatus(side, segments, text_buf, self.activeTabIndex(), self.tabCount());
        }
        return segments[0..0];
    }

    pub fn activeTabIndex(self: *App) usize {
        if (self.mux) |*mux| return mux.activeTabIndex();
        return 0;
    }

    pub fn switchTab(self: *App, index: usize) void {
        if (self.mux) |*mux| {
            const previous = mux.activePane();
            mux.switchTab(index);
            self.syncActivePaneChange(previous, mux.activePane());
            self.refreshActivePaneDisplay();
            if (mux.activeTab()) |tab| self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
            self.requestLayoutRefresh();
        }
    }

    pub fn updateTopBarHover(self: *App, mouse_x: f32, mouse_y: f32, window_width: f32, close_w: f32) void {
        _ = mouse_x;
        _ = mouse_y;
        _ = window_width;
        _ = close_w;
        self.hovered_tab_index = null;
        self.hovered_close_tab_index = null;
    }

    /// Override the active pane's title (used by Lua hollow.set_tab_title).
    pub fn setTabTitle(self: *App, title: []const u8) void {
        const pane = self.activePane() orelse return;
        pane.setManualTitle(title);
    }

    pub fn setTabTitleById(self: *App, tab_id: usize, title: []const u8) bool {
        const tab = self.tabById(tab_id) orelse return false;
        const pane = tab.activePane() orelse return false;
        pane.setManualTitle(title);
        return true;
    }

    const ConfigPaths = struct {
        base: ?[]u8 = null,
        override: ?[]u8 = null,
        use_embedded_base: bool = false,
    };

    fn resolveConfigPaths(self: *App, override: ?[]const u8) !ConfigPaths {
        var result = ConfigPaths{};

        const fallback = platform.projectFallbackConfigPath();
        if (try platform.resolveRelativeToExe(self.allocator, fallback)) |exe_relative| {
            errdefer self.allocator.free(exe_relative);
            if (pathExists(exe_relative)) {
                result.base = exe_relative;
            } else {
                self.allocator.free(exe_relative);
                if (pathExists(fallback)) {
                    result.base = try self.allocator.dupe(u8, fallback);
                } else {
                    result.use_embedded_base = true;
                }
            }
        } else if (pathExists(fallback)) {
            result.base = try self.allocator.dupe(u8, fallback);
        } else {
            result.use_embedded_base = true;
        }

        if (override) |path| {
            result.override = try self.allocator.dupe(u8, path);
            return result;
        }

        const user_path = try platform.defaultConfigPath(self.allocator);
        errdefer self.allocator.free(user_path);
        if (pathExists(user_path) and (result.base == null or !std.mem.eql(u8, user_path, result.base.?))) {
            result.override = user_path;
            return result;
        }
        self.allocator.free(user_path);

        return result;
    }

    fn flushPendingResize(self: *App) void {
        if (!self.pending_resize) return;
        self.pending_resize = false;
        self.resize(self.pending_width, self.pending_height);
    }

    fn flushPendingLayoutResize(self: *App) void {
        if (self.pending_drag_layout_resize) {
            self.pending_drag_layout_resize = false;
            if (self.ghostty) |*runtime| {
                self.resizeAllPanes(runtime, self.config.window_width, self.config.window_height, false, true, false);
            }
        }
        if (!self.pending_layout_resize) return;
        const recreate_render_helpers = self.pending_layout_recreate_render_helpers;
        const skip_unchanged_pty = self.pending_layout_skip_unchanged_pty;
        self.pending_layout_resize = false;
        self.pending_layout_recreate_render_helpers = false;
        self.pending_layout_skip_unchanged_pty = false;
        if (self.pending_split_ratio_node) |node| {
            // Validate the cached node pointer is still in the active tree
            // before dereferencing it.  Tree mutations can free the node.
            if (self.isSplitNodeValid(node)) {
                std.log.info("flushPendingLayoutResize apply node={x} ratio={d:.4}", .{ @intFromPtr(node), self.pending_split_ratio });
                node.ratio = self.pending_split_ratio;
            } else {
                std.log.info("flushPendingLayoutResize: node={x} no longer valid, skipping ratio update", .{@intFromPtr(node)});
            }
            self.pending_split_ratio_node = null;
        }
        if (self.ghostty) |*runtime| {
            std.log.info("flushPendingLayoutResize resizeAllPanes window={d}x{d}", .{ self.config.window_width, self.config.window_height });
            self.resizeAllPanes(runtime, self.config.window_width, self.config.window_height, recreate_render_helpers, false, skip_unchanged_pty);
        }
    }

    /// Lightweight pre-pass: check for dead panes and remove them from the
    /// split tree.  This runs before drainMouseQueue so that mouse events
    /// never reference freed panes or stale SplitNode pointers.
    fn cleanupDeadPanes(self: *App, runtime: *GhosttyRuntime) void {
        const mux = if (self.mux) |*m| m else return;
        var has_dead = false;
        var panes = mux.paneIterator();
        while (panes.next()) |pane| {
            if (!pane.hasLiveChildForCleanup()) {
                has_dead = true;
                break;
            }
        }
        if (!has_dead) return;

        const should_quit = mux.closeDeadPanes(runtime);
        if (should_quit) {
            std.log.info("app: last pane closed (early cleanup), quitting", .{});
            self.pending_quit = true;
            return;
        }
        // Re-register callbacks for the (possibly new) active pane.
        if (mux.activePane()) |active| {
            runtime.registerCallbacks(active.terminal, terminalCallbacks());
        }
        self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
        if (mux.activeTab()) |tab| {
            self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
        }
        self.requestLayoutResize(false);
        // Invalidate pending_split_ratio_node — the tree has changed.
        self.pending_split_ratio_node = null;
    }

    fn tickPanes(self: *App, runtime: *GhosttyRuntime) !void {
        var has_dead = false;
        var next_idle_render_poll_ns: i128 = 0;
        if (self.mux) |*mux| {
            var panes = mux.paneIterator();
            var pane_idx: usize = 0;
            var total_pty_read_ns: i128 = 0;
            var total_terminal_write_ns: i128 = 0;
            var total_terminal_write_bytes: usize = 0;
            var total_terminal_write_chunks: usize = 0;
            var total_renderstate_ns: i128 = 0;
            var total_title_ns: i128 = 0;
            var total_cwd_ns: i128 = 0;
            var total_scrollbar_ns: i128 = 0;
            var total_has_pending_ns: i128 = 0;
            var total_sanitize_ns: i128 = 0;
            var total_child_alive_ns: i128 = 0;
            var total_encoder_sync_ns: i128 = 0;
            while (panes.next()) |pane| {
                const pane_is_active = (self.activePane() == pane);
                // Let the active pane drain a larger PTY backlog per tick so VT
                // parsing tracks the producer more like Ghostty's dedicated read
                // path instead of spreading one burst across many frame ticks.
                const pty_read_loops: usize = if (pane_is_active) 64 else 2;
                const pty_read_bytes: usize = if (pane_is_active) 1024 * 1024 else 32 * 1024;
                pane.pollPty(runtime, pty_read_loops, pty_read_bytes, self.config.debug_overlay) catch |err| {
                    std.log.err("pane pollPty error: {s}", .{@errorName(err)});
                };
                total_pty_read_ns += pane.last_pty_read_ns;
                total_terminal_write_ns += pane.last_terminal_write_ns;
                total_terminal_write_bytes += pane.last_terminal_write_bytes;
                total_terminal_write_chunks += pane.last_terminal_write_chunks;
                total_has_pending_ns += pane.last_has_pending_ns;
                total_sanitize_ns += pane.last_sanitize_ns;
                total_child_alive_ns += pane.last_child_alive_ns;
                total_encoder_sync_ns += pane.last_encoder_sync_ns;
                if (pane.title_dirty) {
                    const start_ns = if (self.config.debug_overlay) std.time.nanoTimestamp() else 0;
                    const old_title = self.allocator.dupe(u8, pane.title) catch null;
                    defer if (old_title) |value| self.allocator.free(value);
                    pane.refreshTitle(runtime, self.config.windowTitle(), self.config.shellForDomain(if (pane.domain_name.len > 0) pane.domain_name else null) catch self.config.shellOrDefault());
                    self.emitLuaBuiltInEvent("term:title_changed", .{ .pane_title_changed = .{
                        .pane_id = @intFromPtr(pane),
                        .old_title = if (old_title) |value| value else "",
                        .new_title = pane.title,
                    } });
                    if (self.config.debug_overlay) total_title_ns += std.time.nanoTimestamp() - start_ns;
                }
                if (pane.cwd_dirty) {
                    const start_ns = if (self.config.debug_overlay) std.time.nanoTimestamp() else 0;
                    const old_cwd = self.allocator.dupe(u8, pane.cwd) catch null;
                    defer if (old_cwd) |value| self.allocator.free(value);
                    if (pane.refreshCwd()) {
                        self.emitLuaBuiltInEvent("term:cwd_changed", .{ .pane_cwd_changed = .{
                            .pane_id = @intFromPtr(pane),
                            .old_cwd = if (old_cwd) |value| value else "",
                            .new_cwd = pane.cwd,
                        } });
                    }
                    if (self.config.debug_overlay) total_cwd_ns += std.time.nanoTimestamp() - start_ns;
                }
                if (!pane.render_state_ready) {
                    pane_idx += 1;
                    continue;
                }
                const now_ns = std.time.nanoTimestamp();
                const is_active = pane_is_active;
                // Ghostty-managed idle state (primarily cursor blink) does not
                // need a 60 Hz poll. Poll the active pane at a modest cadence so
                // idle windows do not burn CPU just to discover blink changes.
                const idle_poll_ns: i128 = if (is_active) 33_000_000 else 100_000_000;
                const pane_idle_deadline_ns = pane.last_render_state_update_ns + idle_poll_ns;
                const needs_update = pane.pty_received_data or
                    pane.render_dirty != .false_value or
                    (now_ns - pane.last_render_state_update_ns >= idle_poll_ns);
                    if (needs_update) {
                        const renderstate_start_ns = if (self.config.debug_overlay) std.time.nanoTimestamp() else 0;
                        if (pane.render_state_fresh) {
                            pane.render_state_fresh = false;
                            pane.pty_received_data = false;
                    } else {
                        pane.pty_received_data = false;
                        pane.last_render_state_update_ns = now_ns;
                        runtime.clearRenderStateDirty(pane.render_state);
                        runtime.updateRenderState(pane.render_state, pane.terminal) catch |err| {
                            std.log.err("pane updateRenderState error: {s}", .{@errorName(err)});
                        };
                        }
                        if (self.config.debug_overlay) total_renderstate_ns += std.time.nanoTimestamp() - renderstate_start_ns;
                        const post_dirty = runtime.getRenderStateDirty(pane.render_state) orelse .true_value;
                    if (self.config.debug_terminal_trace and pane_is_active) {
                        const cursor_pos = runtime.cursorPos(pane.render_state);
                        std.log.info("terminal-trace render-state pane={x} fresh={} pty_received={} render_dirty_before={s} post_dirty={s} cursor_visible={} cursor_blinking={} cursor_password={} cursor_style={s} cursor_pos={any}", .{
                            @intFromPtr(pane),
                            pane.render_state_fresh,
                            pane.pty_received_data,
                            @tagName(pane.render_dirty),
                            @tagName(post_dirty),
                            runtime.cursorVisible(pane.render_state),
                            runtime.cursorBlinking(pane.render_state),
                            runtime.cursorPasswordInput(pane.render_state),
                            @tagName(runtime.cursorVisualStyle(pane.render_state)),
                            cursor_pos,
                        });
                    }
                    if (@intFromEnum(post_dirty) > @intFromEnum(pane.render_dirty)) {
                        pane.render_dirty = post_dirty;
                    }
                    if (self.copy_mode_active and self.copy_mode_pane == pane and !self.copy_mode_needs_refresh) {
                        self.refreshCopyModeVisibleSlice(pane) catch {};
                    }
                    if (builtin.os.tag != .windows and pane.logged_first_pty_read and pane.title.len == 0) {
                        if (runtime.cursorPos(pane.render_state)) |cp| {
                            std.log.info("linux startup cursor row={d} col={d} render_rows={d} render_cols={d}", .{
                                cp.y,
                                cp.x,
                                runtime.renderStateRows(pane.render_state) orelse 0,
                                runtime.renderStateCols(pane.render_state) orelse 0,
                            });
                        }
                    }
                        const scrollbar_start_ns = if (self.config.debug_overlay) std.time.nanoTimestamp() else 0;
                        _ = self.refreshPaneScrollbar(runtime, pane);
                        if (self.config.debug_overlay) total_scrollbar_ns += std.time.nanoTimestamp() - scrollbar_start_ns;
                    if (self.hovered_hyperlink != null and self.hovered_hyperlink.?.pane == pane) {
                        self.hover_probe_dirty = true;
                    }
                } else if (pane.last_render_state_update_ns != 0) {
                    if (next_idle_render_poll_ns == 0 or pane_idle_deadline_ns < next_idle_render_poll_ns) {
                        next_idle_render_poll_ns = pane_idle_deadline_ns;
                    }
                }
                if (!pane.hasLiveChild()) has_dead = true;
                pane_idx += 1;
            }
            debug_timing.setTickDetailTimes(
                @as(f32, @floatFromInt(total_pty_read_ns)) / 1_000_000.0,
                @as(f32, @floatFromInt(total_terminal_write_ns)) / 1_000_000.0,
                @as(f32, @floatFromInt(total_renderstate_ns)) / 1_000_000.0,
            );
            debug_timing.setTickWriteShape(
                @intCast(@min(total_terminal_write_bytes, std.math.maxInt(u32))),
                @intCast(@min(total_terminal_write_chunks, std.math.maxInt(u32))),
            );
            debug_timing.setTickPaneDetailTimes(
                @as(f32, @floatFromInt(total_title_ns)) / 1_000_000.0,
                @as(f32, @floatFromInt(total_cwd_ns)) / 1_000_000.0,
                @as(f32, @floatFromInt(total_scrollbar_ns)) / 1_000_000.0,
            );
            debug_timing.setPollPtyDetailTimes(
                @as(f32, @floatFromInt(total_has_pending_ns)) / 1_000_000.0,
                @as(f32, @floatFromInt(total_sanitize_ns)) / 1_000_000.0,
                @as(f32, @floatFromInt(total_child_alive_ns)) / 1_000_000.0,
                @as(f32, @floatFromInt(total_encoder_sync_ns)) / 1_000_000.0,
            );
        }

        if (has_dead) {
            if (self.mux) |*mux| {
                const should_quit = mux.closeDeadPanes(runtime);
                if (should_quit) {
                    std.log.info("app: last pane closed, quitting", .{});
                    self.pending_quit = true;
                    return;
                }
                // Re-register callbacks for the (possibly new) active pane so
                // write/size/title events are routed correctly.
                if (mux.activePane()) |active| {
                    runtime.registerCallbacks(active.terminal, terminalCallbacks());
                }
                self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
                if (mux.activeTab()) |tab| {
                    self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
                }
                self.requestLayoutResize(false);
            }
        }
        self.next_idle_render_poll_ns = next_idle_render_poll_ns;
    }


    fn resizeAllPanes(self: *App, runtime: *GhosttyRuntime, pixel_width: u32, pixel_height: u32, recreate_render_helpers: bool, skip_pty: bool, skip_unchanged_pty: bool) void {
        const mux = if (self.mux) |*m| m else return;
        const ws = mux.activeWorkspace() orelse return;
        const active_tab = ws.activeTab();
        var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;

        // How many pixels the tab bar steals from the top.  We compute this
        // from the current cell size rather than from mux.tabCount() because
        // the mux hasn't changed yet at this call site (new tab just added).
        // Use tabBarHeight() which already handles the count guard.
        const tbh = self.tabBarHeight();
        const bbh = self.bottomBarHeight();
        const pane_h = if (pixel_height > tbh + bbh) pixel_height - tbh - bbh else 1;
        const sidebar = self.sidebarLayout();
        const left_inset = if (sidebar != null and sidebar.?.reserve and sidebar.?.side == .left)
            self.sidebarReservedWidthPx(sidebar.?)
        else
            0;
        const right_inset = if (sidebar != null and sidebar.?.reserve and sidebar.?.side == .right)
            self.sidebarReservedWidthPx(sidebar.?)
        else
            0;
        const layout_width = if (pixel_width > left_inset + right_inset)
            pixel_width - left_inset - right_inset
        else
            1;

        // Only resize the active tab. Hidden tabs keep their last good render
        // state until activation, where they get an authoritative resize.
        // Updating hidden tabs here can wipe prompt rows until fresh PTY
        // activity arrives when the tab becomes active again.
        const tab = active_tab orelse return;
        {
            const bounds = PaneBounds{
                .x = left_inset,
                .y = tbh,
                .width = layout_width,
                .height = pane_h,
            };
            const leaves = tab.computeLayoutInBounds(bounds, &layout_buf);
            if (leaves.len > 0) {
                for (leaves) |leaf| {
                    // Skip panes with zero-size bounds — can happen when the window
                    // is very small or during layout transitions.
                    if (leaf.bounds.width == 0 or leaf.bounds.height == 0) continue;
                    const inner = self.paneInnerBounds(leaf.pane, leaf.bounds);
                    const raw_cols: u32 = inner.width / @max(1, self.cell_width_px);
                    const raw_rows: u32 = inner.height / @max(1, self.cell_height_px);
                    // Cap at sane max to prevent DLL crashes on extreme values.
                    const cols: u16 = @intCast(@min(1000, @max(1, raw_cols)));
                    const rows: u16 = @intCast(@min(500, @max(1, raw_rows)));
                    if (recreate_render_helpers) {
                        leaf.pane.recreateRenderHelpers(runtime);
                    }
                    leaf.pane.width_px = leaf.bounds.width;
                    leaf.pane.height_px = leaf.bounds.height;
                    leaf.pane.x_px = leaf.bounds.x;
                    leaf.pane.y_px = leaf.bounds.y;
                    const pane_skip_pty = skip_pty or (skip_unchanged_pty and leaf.pane.cols == cols and leaf.pane.rows == rows);
                    leaf.pane.resize(runtime, cols, rows, self.cell_width_px, self.cell_height_px, pane_skip_pty);
                    // The encoder maps absolute surface pixels into pane-local cells
                    // using the full surface size plus the pane's outer padding.
                    const scrollbar_gutter = self.paneScrollbarGutter(leaf.pane);
                    leaf.pane.setMouseSize(
                        runtime,
                        leaf.bounds.width,
                        leaf.bounds.height,
                        self.cell_width_px,
                        self.cell_height_px,
                        self.config.terminal_padding.top,
                        self.config.terminal_padding.bottom,
                        self.config.terminal_padding.left,
                        self.config.terminal_padding.right + scrollbar_gutter,
                    );
                    leaf.pane.render_state_ready = true;
                }
            } else {
                // Fallback: no split tree yet, resize all panes in this tab to
                // the full window size minus the tab bar.
                if (pixel_width == 0 or pane_h == 0) return;
                var panes = tab.paneIterator();
                while (panes.next()) |pane| {
                    const scrollbar_gutter = self.paneScrollbarGutter(pane);
                    const horizontal_reserved = self.config.terminal_padding.horizontal() + scrollbar_gutter;
                    const inner_width = if (layout_width > horizontal_reserved) layout_width - horizontal_reserved else 1;
                    const inner_height = if (pane_h > self.config.terminal_padding.vertical()) pane_h - self.config.terminal_padding.vertical() else 1;
                    const cols: u16 = @intCast(@min(1000, @max(1, inner_width / @max(1, self.cell_width_px))));
                    const rows: u16 = @intCast(@min(500, @max(1, inner_height / @max(1, self.cell_height_px))));
                    if (recreate_render_helpers) {
                        pane.recreateRenderHelpers(runtime);
                    }
                    pane.width_px = pixel_width;
                    pane.height_px = pane_h;
                    pane.x_px = left_inset;
                    pane.y_px = tbh;
                    const pane_skip_pty = skip_pty or (skip_unchanged_pty and pane.cols == cols and pane.rows == rows);
                    pane.resize(runtime, cols, rows, self.cell_width_px, self.cell_height_px, pane_skip_pty);
                    pane.setMouseSize(
                        runtime,
                        layout_width,
                        pane_h,
                        self.cell_width_px,
                        self.cell_height_px,
                        self.config.terminal_padding.top,
                        self.config.terminal_padding.bottom,
                        self.config.terminal_padding.left,
                        self.config.terminal_padding.right + scrollbar_gutter,
                    );
                    pane.render_state_ready = true;
                }
            }
        }
    }
    /// Fire the Lua on_key handler. Returns true if the key was consumed.
    pub fn fireOnKey(self: *App, key: []const u8, mods: u32) bool {
        if (self.lua) |*lua| {
            const consumed = lua.fireOnKey(key, mods);
            if (!consumed) self.emitLuaBuiltInEvent("key:unhandled", .{ .key_unhandled = .{ .key = key, .mods = mods } });
            return consumed;
        }
        return false;
    }

    pub fn isLeaderActive(self: *App) bool {
        if (self.lua) |*lua| return lua.isLeaderActive();
        return false;
    }
};

/// AppCallbacks.split_pane implementation — called from Lua.
fn luaSplitPaneCallback(app_ptr: *anyopaque, direction: []const u8, ratio: f32, domain_name: ?[]const u8, cwd: ?[]const u8, command: ?[]const u8, command_mode: []const u8, close_on_exit: bool, floating: bool, fullscreen: bool, x: f32, y: f32, width: f32, height: f32, has_bounds: bool, callback_ref: c_int) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const dir: SplitDirection = if (std.mem.eql(u8, direction, "horizontal")) .horizontal else .vertical;
    const mode: SplitCommandMode = if (std.mem.eql(u8, command_mode, "spawn")) .spawn else .send;
    const owned_domain = if (domain_name) |name| app.allocator.dupe(u8, name) catch null else null;
    const owned_cwd = if (cwd) |value| app.allocator.dupe(u8, value) catch null else null;
    const owned_command = if (command) |value| app.allocator.dupe(u8, value) catch null else null;
    _ = app.enqueueMouse(.{ .split_pane = .{
        .direction = dir,
        .ratio = ratio,
        .domain_name = owned_domain,
        .cwd = owned_cwd,
        .command = owned_command,
        .command_mode = mode,
        .close_on_exit = close_on_exit,
        .floating = floating,
        .fullscreen = fullscreen,
        .x = if (has_bounds) x else null,
        .y = if (has_bounds) y else null,
        .width = if (has_bounds) width else null,
        .height = if (has_bounds) height else null,
        .callback_ref = callback_ref,
    } });
}

fn sendSplitPaneCommand(self: *App, pane: *Pane, command: []const u8, close_on_exit: bool) void {
    if (!close_on_exit) {
        pane.sendText(command);
        if (!std.mem.endsWith(u8, command, "\r") and !std.mem.endsWith(u8, command, "\n")) {
            pane.sendText("\r");
        }
        return;
    }

    const wrapped = wrapCommandForCloseOnExit(self, pane, command) catch |err| {
        std.log.err("app: failed to wrap split command for close_on_exit: {s}", .{@errorName(err)});
        pane.sendText(command);
        if (!std.mem.endsWith(u8, command, "\r") and !std.mem.endsWith(u8, command, "\n")) {
            pane.sendText("\r");
        }
        return;
    };
    defer self.allocator.free(wrapped);
    pane.sendText(wrapped);
    pane.sendText("\r");
}

fn wrapCommandForCloseOnExit(self: *App, pane: *Pane, command: []const u8) ![]u8 {
    const trimmed = std.mem.trimRight(u8, command, "\r\n");
    const is_windows_domain = pane.domain_name.len > 0 and !std.mem.eql(u8, pane.domain_name, "wsl") and !std.mem.eql(u8, pane.domain_name, "unix");

    if (is_windows_domain) {
        return std.fmt.allocPrint(self.allocator, "{s} & exit", .{trimmed});
    }

    return std.fmt.allocPrint(self.allocator, "{s}; exit", .{trimmed});
}

fn luaTogglePaneMaximizedCallback(app_ptr: *anyopaque, pane_id: usize, show_background: bool) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.{ .toggle_pane_maximized = .{ .pane_id = pane_id, .show_background = show_background } });
}

fn luaSetPaneFloatingCallback(app_ptr: *anyopaque, pane_id: usize, floating: bool) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.{ .set_pane_floating = .{ .pane_id = pane_id, .floating = floating } });
}

fn luaSetFloatingPaneBoundsCallback(app_ptr: *anyopaque, pane_id: usize, x: f32, y: f32, width: f32, height: f32) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.{ .set_floating_pane_bounds = .{ .pane_id = pane_id, .x = x, .y = y, .width = width, .height = height } });
}

fn luaMovePaneCallback(app_ptr: *anyopaque, pane_id: usize, direction: []const u8, amount: f32) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const dir: FocusDirection = if (std.mem.eql(u8, direction, "left")) .left else if (std.mem.eql(u8, direction, "right")) .right else if (std.mem.eql(u8, direction, "up")) .up else .down;
    app.movePaneById(pane_id, dir, amount);
}

fn luaSetPaneForegroundProcessCallback(app_ptr: *anyopaque, pane_id: usize, process: []const u8) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    app.setPaneForegroundProcess(pane_id, process);
}

fn luaGetPaneForegroundProcessCallback(app_ptr: *anyopaque, pane_id: usize, out_buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.getPaneForegroundProcess(pane_id, out_buf);
}


fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn firstCodepoint(text: []const u8) u32 {
    if (text.len == 0) return 0;
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return text[0];
    if (len > text.len) return text[0];
    return std.unicode.utf8Decode(text[0..len]) catch text[0];
}

fn appendCellText(runtime: *GhosttyRuntime, row_cells: ?*anyopaque, out: []u8, len: *usize) void {
    if (len.* >= out.len) return;
    const grapheme_len = runtime.cellGraphemeLen(row_cells);
    if (grapheme_len == 0) {
        out[len.*] = ' ';
        len.* += 1;
        return;
    }

    var cps: [16]u32 = [_]u32{0} ** 16;
    runtime.cellGraphemes(row_cells, &cps);
    var cp_index: usize = 0;
    while (cp_index < grapheme_len and cps[cp_index] != 0) : (cp_index += 1) {
        var utf8_buf: [4]u8 = undefined;
        const encoded_len = encodeCodepointInto(cps[cp_index], &utf8_buf) orelse continue;
        if (len.* + encoded_len > out.len) return;
        fastmem.copy(u8, out[len.* .. len.* + encoded_len], utf8_buf[0..encoded_len]);
        len.* += encoded_len;
    }
}

fn appendGridRefText(runtime: *GhosttyRuntime, ref: *const ghostty.GridRef, raw_cell: u64, out: []u8, len: *usize) void {
    if (len.* >= out.len) return;
    var cps: [16]u32 = [_]u32{0} ** 16;
    const grapheme_len = runtime.gridRefGraphemesInto(ref, cps[0..]) orelse 0;
    if (grapheme_len == 0) {
        if (!runtime.cellHasText(raw_cell)) {
            out[len.*] = ' ';
            len.* += 1;
            return;
        }
        const cp = runtime.cellCodepoint(raw_cell);
        var utf8_buf: [4]u8 = undefined;
        const encoded_len = encodeCodepointInto(cp, &utf8_buf) orelse return;
        if (len.* + encoded_len > out.len) return;
        fastmem.copy(u8, out[len.* .. len.* + encoded_len], utf8_buf[0..encoded_len]);
        len.* += encoded_len;
        return;
    }

    var cp_index: usize = 0;
    while (cp_index < grapheme_len and cps[cp_index] != 0) : (cp_index += 1) {
        var utf8_buf: [4]u8 = undefined;
        const encoded_len = encodeCodepointInto(cps[cp_index], &utf8_buf) orelse continue;
        if (len.* + encoded_len > out.len) return;
        fastmem.copy(u8, out[len.* .. len.* + encoded_len], utf8_buf[0..encoded_len]);
        len.* += encoded_len;
    }
}

fn captureCopyModeCellText(allocator: std.mem.Allocator, runtime: *GhosttyRuntime, row_cells: ?*anyopaque) ![]u8 {
    var buf: [32]u8 = undefined;
    var len: usize = 0;
    appendCellText(runtime, row_cells, &buf, &len);
    return try allocator.dupe(u8, buf[0..len]);
}

fn appendCopyModeCellBytes(out: []u8, len: *usize, cell_text: []const u8) void {
    if (cell_text.len == 0) return;
    if (len.* + cell_text.len > out.len) return;
    fastmem.copy(u8, out[len.* .. len.* + cell_text.len], cell_text);
    len.* += cell_text.len;
}

fn encodeCodepointInto(codepoint: u32, buf: *[4]u8) ?usize {
    if (codepoint == 0) return null;
    if (codepoint < 0x80) {
        buf[0] = @intCast(codepoint);
        return 1;
    }
    if (codepoint < 0x800) {
        buf[0] = @intCast(0xC0 | (codepoint >> 6));
        buf[1] = @intCast(0x80 | (codepoint & 0x3F));
        return 2;
    }
    if (codepoint < 0x10000) {
        buf[0] = @intCast(0xE0 | (codepoint >> 12));
        buf[1] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (codepoint & 0x3F));
        return 3;
    }
    buf[0] = @intCast(0xF0 | (codepoint >> 18));
    buf[1] = @intCast(0x80 | ((codepoint >> 12) & 0x3F));
    buf[2] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
    buf[3] = @intCast(0x80 | (codepoint & 0x3F));
    return 4;
}

fn isPromptRow(runtime: *ghostty.Runtime, terminal: ?*anyopaque, row: u64) bool {
    var ref: ghostty.GridRef = undefined;
    const point = ghostty.Point{
        .tag = .screen,
        .value = .{ .coordinate = .{ .x = 0, .y = @intCast(row) } },
    };
    if (runtime.terminal_grid_ref(terminal, point, &ref) != ghostty.success) return false;
    const g_row = runtime.gridRefRow(&ref) orelse return false;
    return runtime.rowSemanticPrompt(g_row) == .prompt;
}

fn alignedTopRowForTarget(current_top: usize, visible_rows: usize, target_row: usize) usize {
    if (target_row < current_top) return target_row;
    if (target_row >= current_top + visible_rows) return target_row - (visible_rows - 1);
    return current_top;
}

fn promptRowAt(source: PromptJumpSource, row: usize) bool {
    return switch (source) {
        .live => |live| isPromptRow(live.runtime, live.terminal, row),
        .copy_mode => |history| row < history.len and history[row].is_prompt,
    };
}

fn findPromptJumpTarget(source: PromptJumpSource, direction: PromptJumpDir, start_row: usize, total_rows: usize) ?usize {
    if (total_rows == 0) return null;
    switch (direction) {
        .next => {
            var row = start_row;
            while (row < total_rows) : (row += 1) {
                if (promptRowAt(source, row)) return row;
            }
        },
        .prev => {
            var row = @min(start_row, total_rows - 1);
            while (true) {
                if (promptRowAt(source, row)) return row;
                if (row == 0) break;
                row -= 1;
            }
        },
    }
    return null;
}

fn pointTagForHistoryRow(row: usize, scrollback_rows: usize) ghostty.PointTag {
    return if (row < scrollback_rows) .history else .screen;
}

fn pointYForHistoryRow(row: usize, scrollback_rows: usize) u32 {
    return if (row < scrollback_rows)
        @intCast(row)
    else
        @intCast(row - scrollback_rows);
}

fn gridRefForHistoryPoint(runtime: *GhosttyRuntime, terminal: ?*anyopaque, row: usize, col: usize, scrollback_rows: usize) ?ghostty.GridRef {
    var ref: ghostty.GridRef = undefined;
    const point = ghostty.Point{
        .tag = pointTagForHistoryRow(row, scrollback_rows),
        .value = .{ .coordinate = .{ .x = @intCast(col), .y = pointYForHistoryRow(row, scrollback_rows) } },
    };
    if (runtime.terminal_grid_ref(terminal, point, &ref) != ghostty.success) return null;
    return ref;
}

fn captureCopyModeGridRefText(allocator: std.mem.Allocator, runtime: *GhosttyRuntime, ref: *const ghostty.GridRef, raw_cell: u64) ![]u8 {
    var cps: [16]u32 = [_]u32{0} ** 16;
    const grapheme_len = runtime.gridRefGraphemesInto(ref, cps[0..]) orelse 0;
    var buf: [32]u8 = undefined;
    var len: usize = 0;

    if (grapheme_len == 0) {
        if (!runtime.cellHasText(raw_cell)) {
            buf[0] = ' ';
            return try allocator.dupe(u8, buf[0..1]);
        }
        const cp = runtime.cellCodepoint(raw_cell);
        if (encodeCodepointInto(cp, &buf[0..4].*)) |encoded_len| {
            return try allocator.dupe(u8, buf[0..encoded_len]);
        }
        buf[0] = ' ';
        return try allocator.dupe(u8, buf[0..1]);
    }

    var idx: usize = 0;
    while (idx < grapheme_len and cps[idx] != 0) : (idx += 1) {
        var utf8_buf: [4]u8 = undefined;
        const encoded_len = encodeCodepointInto(cps[idx], &utf8_buf) orelse continue;
        if (len + encoded_len > buf.len) break;
        fastmem.copy(u8, buf[len .. len + encoded_len], utf8_buf[0..encoded_len]);
        len += encoded_len;
    }
    if (len == 0) {
        buf[0] = ' ';
        len = 1;
    }
    return try allocator.dupe(u8, buf[0..len]);
}

fn colorFromGridRefCell(runtime: *GhosttyRuntime, ref: *const ghostty.GridRef, raw_cell: u64, foreground: bool) ?ghostty.ColorRgb {
    const tag = runtime.cellContentTag(raw_cell);
    if (!foreground and tag != .bg_color_palette and tag != .bg_color_rgb) return null;

    var style: ghostty.Style = undefined;
    if (runtime.gridRefStyleInto(ref, &style)) {
        if (foreground and style.fg_color.tag == .rgb) return style.fg_color.value.rgb;
        if (!foreground and style.bg_color.tag == .rgb) return style.bg_color.value.rgb;
    }

    if (foreground) return null;
    return switch (runtime.cellContentTag(raw_cell)) {
        .bg_color_rgb => blk: {
            var rgb: ghostty.ColorRgb = undefined;
            if (runtime.cell_get(raw_cell, @intFromEnum(ghostty.CellDataV.color_rgb), &rgb) == ghostty.success) break :blk rgb;
            break :blk null;
        },
        else => null,
    };
}

fn legacyPrintableKeyText(key: ghostty.Key, mods: u32, out: *[4]u8) ?[]const u8 {
    const shift = (mods & ghostty.Mods.shift) != 0;
    const ch: u8 = switch (key) {
        .a => if (shift) 'A' else 'a',
        .b => if (shift) 'B' else 'b',
        .c => if (shift) 'C' else 'c',
        .d => if (shift) 'D' else 'd',
        .e => if (shift) 'E' else 'e',
        .f => if (shift) 'F' else 'f',
        .g => if (shift) 'G' else 'g',
        .h => if (shift) 'H' else 'h',
        .i => if (shift) 'I' else 'i',
        .j => if (shift) 'J' else 'j',
        .k => if (shift) 'K' else 'k',
        .l => if (shift) 'L' else 'l',
        .m => if (shift) 'M' else 'm',
        .n => if (shift) 'N' else 'n',
        .o => if (shift) 'O' else 'o',
        .p => if (shift) 'P' else 'p',
        .q => if (shift) 'Q' else 'q',
        .r => if (shift) 'R' else 'r',
        .s => if (shift) 'S' else 's',
        .t => if (shift) 'T' else 't',
        .u => if (shift) 'U' else 'u',
        .v => if (shift) 'V' else 'v',
        .w => if (shift) 'W' else 'w',
        .x => if (shift) 'X' else 'x',
        .y => if (shift) 'Y' else 'y',
        .z => if (shift) 'Z' else 'z',
        .digit_0 => if (shift) ')' else '0',
        .digit_1 => if (shift) '!' else '1',
        .digit_2 => if (shift) '@' else '2',
        .digit_3 => if (shift) '#' else '3',
        .digit_4 => if (shift) '$' else '4',
        .digit_5 => if (shift) '%' else '5',
        .digit_6 => if (shift) '^' else '6',
        .digit_7 => if (shift) '&' else '7',
        .digit_8 => if (shift) '*' else '8',
        .digit_9 => if (shift) '(' else '9',
        .space => ' ',
        .tab => if (shift) return null else '\t',
        .enter => '\r',
        .backspace => 0x7f,
        .minus => if (shift) '_' else '-',
        .equal => if (shift) '+' else '=',
        .bracket_left => if (shift) '{' else '[',
        .bracket_right => if (shift) '}' else ']',
        .backslash => if (shift) '|' else '\\',
        .semicolon => if (shift) ':' else ';',
        .quote => if (shift) '"' else '\'',
        .backquote => if (shift) '~' else '`',
        .comma => if (shift) '<' else ',',
        .period => if (shift) '>' else '.',
        .slash => if (shift) '?' else '/',
        else => return null,
    };
    out[0] = ch;
    return out[0..1];
}

fn getPaneForTerminal(app: *App, term: ?*anyopaque) ?*Pane {
    if (app.mux) |*mux| {
        var panes = mux.paneIterator();
        while (panes.next()) |pane| {
            if (pane.terminal == term) return pane;
        }
    }
    return null;
}

fn writePtyCallback(term: ?*anyopaque, _: ?*anyopaque, bytes: ?[*]const u8, len: usize) callconv(.c) void {
    if (bytes == null or len == 0) return;
    const bytes_ptr = bytes.?;
    const app = write_bridge orelse return;
    const pane = getPaneForTerminal(app, term) orelse return;
    pane.sendText(bytes_ptr[0..len]);
}

fn bellCallback(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}

fn enquiryCallback(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) ghostty.String {
    return .{ .ptr = null, .len = 0 };
}

fn xtversionCallback(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) ghostty.String {
    return .{ .ptr = null, .len = 0 };
}

fn sizeCallback(term: ?*anyopaque, _: ?*anyopaque, out: ?*ghostty.SizeReportSize) callconv(.c) bool {
    if (out == null) return false;
    const out_ptr = out.?;
    const app = size_bridge orelse return false;
    // Report the actual per-pane terminal dimensions rather than the global
    // config values, so each split pane reports its own correct size.
    if (getPaneForTerminal(app, term)) |pane| {
        out_ptr.rows = if (pane.rows > 0) pane.rows else app.config.rows;
        out_ptr.columns = if (pane.cols > 0) pane.cols else app.config.cols;
        out_ptr.cell_width = app.cell_width_px;
        out_ptr.cell_height = app.cell_height_px;
        return true;
    }
    out_ptr.rows = app.config.rows;
    out_ptr.columns = app.config.cols;
    out_ptr.cell_width = app.cell_width_px;
    out_ptr.cell_height = app.cell_height_px;
    return true;
}

fn colorSchemeCallback(_: ?*anyopaque, _: ?*anyopaque, _: ?*ghostty.ColorScheme) callconv(.c) bool {
    return false;
}

fn deviceAttributesCallback(_: ?*anyopaque, _: ?*anyopaque, out: ?*ghostty.DeviceAttributes) callconv(.c) bool {
    if (out == null) return false;
    const out_ptr = out.?;
    const app = attrs_bridge orelse return false;
    _ = app;
    out_ptr.primary.conformance_level = 1;
    out_ptr.primary.features = [_]u16{ 1, 2, 22 } ++ ([_]u16{0} ** 61);
    out_ptr.primary.num_features = 3;
    out_ptr.secondary.device_type = 1;
    out_ptr.secondary.firmware_version = 1;
    out_ptr.secondary.rom_cartridge = 0;
    out_ptr.tertiary.unit_id = 0;
    return true;
}

fn titleChangedCallback(term: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const app = title_bridge orelse return;
    _ = app;
    if (getPaneForTerminal(title_bridge orelse return, term)) |pane| {
        if (pane.title_is_manual) return;
        pane.title_dirty = true;
    }
}

fn luaNewTabCallback(app_ptr: *anyopaque, domain_name: ?[]const u8, command: ?[]const u8, callback_ref: c_int) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const owned_domain = if (domain_name) |name| app.allocator.dupe(u8, name) catch null else null;
    const owned_command = if (command) |value| app.allocator.dupe(u8, value) catch null else null;
    _ = app.enqueueMouse(.{ .new_tab = .{ .domain_name = owned_domain, .command = owned_command, .callback_ref = callback_ref } });
}

fn luaCloseTabCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.close_tab);
}

fn luaClosePaneCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.close_pane);
}

fn luaClosePaneByIdCallback(app_ptr: *anyopaque, pane_id: usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.enqueueMouse(.{ .close_pane_by_id = pane_id });
}

fn luaNextTabCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.next_tab);
}

fn luaPrevTabCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.prev_tab);
}

fn luaNewWorkspaceCallback(app_ptr: *anyopaque, cwd: ?[]const u8, domain_name: ?[]const u8, command: ?[]const u8, name: ?[]const u8, callback_ref: c_int) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const owned_cwd = if (cwd) |value| app.allocator.dupe(u8, value) catch null else null;
    const owned_domain = if (domain_name) |value| app.allocator.dupe(u8, value) catch null else null;
    const owned_command = if (command) |value| app.allocator.dupe(u8, value) catch null else null;
    const owned_name = if (name) |value| app.allocator.dupe(u8, value) catch null else null;
    _ = app.enqueueMouse(.{ .new_workspace = .{ .cwd = owned_cwd, .domain_name = owned_domain, .command = owned_command, .name = owned_name, .callback_ref = callback_ref, .queued_at_ms = std.time.milliTimestamp() } });
}

fn luaCloseWorkspaceCallback(app_ptr: *anyopaque, workspace_id: ?usize) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.{ .close_workspace = workspace_id });
}

fn luaNextWorkspaceCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.next_workspace);
}

fn luaPrevWorkspaceCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.prev_workspace);
}

fn luaSwitchWorkspaceCallback(app_ptr: *anyopaque, index: usize) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.{ .switch_workspace = index });
}

fn luaSetWorkspaceNameCallback(app_ptr: *anyopaque, name: []const u8) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const owned = app.allocator.dupe(u8, name) catch return;
    _ = app.enqueueMouse(.{ .set_workspace_name = owned });
}

fn luaSetWorkspaceDefaultCwdCallback(app_ptr: *anyopaque, cwd: []const u8) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const owned = app.allocator.dupe(u8, cwd) catch return;
    _ = app.enqueueMouse(.{ .set_workspace_default_cwd = owned });
}

fn luaFocusPaneCallback(app_ptr: *anyopaque, direction: []const u8) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const dir: FocusDirection = if (std.mem.eql(u8, direction, "left")) .left else if (std.mem.eql(u8, direction, "right")) .right else if (std.mem.eql(u8, direction, "up")) .up else .down;
    _ = app.enqueueMouse(.{ .focus_pane = dir });
}

fn luaFocusPaneByIdCallback(app_ptr: *anyopaque, pane_id: usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    if (app.findPaneById(pane_id) == null) return false;
    return app.enqueueMouse(.{ .focus_pane_by_id = pane_id });
}

fn luaResizePaneCallback(app_ptr: *anyopaque, direction: []const u8, delta: f32) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const dir: SplitDirection = if (std.mem.eql(u8, direction, "horizontal")) .horizontal else .vertical;
    _ = app.enqueueMouse(.{ .resize_pane = .{ .direction = dir, .delta = delta } });
}

fn luaSwitchTabCallback(app_ptr: *anyopaque, index: usize) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    app.switchTab(index);
}

fn luaSetTabTitleCallback(app_ptr: *anyopaque, title: []const u8) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    app.setTabTitle(title);
}

fn luaCurrentTabIdCallback(app_ptr: *anyopaque) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const tab = app.activeTab() orelse return 0;
    return tab.id;
}

fn luaCurrentPaneIdCallback(app_ptr: *anyopaque) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.activePane() orelse return 0;
    return @intFromPtr(pane);
}

fn luaGetTabIdAtCallback(app_ptr: *anyopaque, index: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const ws = app.activeWorkspace() orelse return 0;
    if (index >= ws.tabs.items.len) return 0;
    return ws.tabs.items[index].id;
}

fn luaGetTabPaneCountCallback(app_ptr: *anyopaque, tab_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const tab = app.tabById(tab_id) orelse return 0;
    return tab.panes.items.len;
}

fn luaGetTabPaneIdAtCallback(app_ptr: *anyopaque, tab_id: usize, index: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const tab = app.tabById(tab_id) orelse return 0;
    if (index >= tab.panes.items.len) return 0;
    return @intFromPtr(tab.panes.items[index]);
}

fn luaGetTabActivePaneIdCallback(app_ptr: *anyopaque, tab_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const tab = app.tabById(tab_id) orelse return 0;
    const pane = tab.activePane() orelse return 0;
    return @intFromPtr(pane);
}

fn luaGetTabIndexByIdCallback(app_ptr: *anyopaque, tab_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.tabIndexById(tab_id) orelse std.math.maxInt(usize);
}

fn luaGetPanePidCallback(app_ptr: *anyopaque, pane_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return 0;
    return pane.childPid();
}

fn luaGetPaneTitleCallback(app_ptr: *anyopaque, pane_id: usize, out_buf: []u8) []const u8 {
    _ = out_buf;
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return "";
    return pane.title;
}

fn luaGetPaneTextCallback(app_ptr: *anyopaque, pane_id: usize, out_buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.getPaneText(pane_id, out_buf);
}

fn luaGetPaneCwdCallback(app_ptr: *anyopaque, pane_id: usize, out_buf: []u8) []const u8 {
    _ = out_buf;
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return "";
    return pane.cwd;
}

fn luaGetPaneDomainCallback(app_ptr: *anyopaque, pane_id: usize, out_buf: []u8) []const u8 {
    _ = out_buf;
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return "";
    return pane.domain_name;
}

fn luaGetPaneRowsCallback(app_ptr: *anyopaque, pane_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return 0;
    return pane.rows;
}

fn luaGetPaneColsCallback(app_ptr: *anyopaque, pane_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return 0;
    return pane.cols;
}

fn luaGetPaneXCallback(app_ptr: *anyopaque, pane_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return 0;
    return pane.x_px;
}

fn luaGetPaneYCallback(app_ptr: *anyopaque, pane_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return 0;
    return pane.y_px;
}

fn luaGetPaneWidthCallback(app_ptr: *anyopaque, pane_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return 0;
    return pane.width_px;
}

fn luaGetPaneHeightCallback(app_ptr: *anyopaque, pane_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return 0;
    return pane.height_px;
}

fn luaGetWindowWidthCallback(app_ptr: *anyopaque) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.config.window_width;
}

fn luaGetWindowHeightCallback(app_ptr: *anyopaque) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.config.window_height;
}

fn luaNowMsCallback(app_ptr: *anyopaque) i64 {
    _ = app_ptr;
    return @intCast(@divFloor(std.time.nanoTimestamp(), std.time.ns_per_ms));
}

fn luaPaneIsFloatingCallback(app_ptr: *anyopaque, pane_id: usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return false;
    return pane.is_floating;
}

fn luaPaneIsMaximizedCallback(app_ptr: *anyopaque, pane_id: usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return false;
    if (app.mux) |*mux| return mux.paneIsMaximized(pane);
    return false;
}

fn luaPaneIsFocusedCallback(app_ptr: *anyopaque, pane_id: usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.activePane() orelse return false;
    return @intFromPtr(pane) == pane_id;
}

fn luaPaneExistsCallback(app_ptr: *anyopaque, pane_id: usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.findPaneById(pane_id) != null;
}

fn luaSwitchTabByIdCallback(app_ptr: *anyopaque, tab_id: usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const index = app.tabIndexById(tab_id) orelse return false;
    return app.enqueueMouse(.{ .switch_tab = index });
}

fn luaCloseTabByIdCallback(app_ptr: *anyopaque, tab_id: usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const index = app.tabIndexById(tab_id) orelse return false;
    return app.enqueueMouse(.{ .close_tab_at = index });
}

fn luaSetTabTitleByIdCallback(app_ptr: *anyopaque, tab_id: usize, title: []const u8) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.setTabTitleById(tab_id, title);
}

fn luaReloadConfigCallback(app_ptr: *anyopaque) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.reload_config);
    return true;
}

fn luaRefreshLiveConfigCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    std.log.info("config: command_timing={}", .{app.config.command_timing});
    app.syncCommandTimingEnv();
    app.pending_renderer_refresh = app.config.backend == .sokol or app.config.backend == .webgpu;
    app.invalidateAllPanes();
    app.requestLayoutResize(true);
}

fn luaSendTextToPaneCallback(app_ptr: *anyopaque, pane_id: usize, text: []const u8) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.sendTextToPane(pane_id, text);
}

fn luaGetTabCountCallback(app_ptr: *anyopaque) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.tabCount();
}

fn luaGetActiveTabIndexCallback(app_ptr: *anyopaque) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.activeTabIndex();
}

fn luaGetWorkspaceCountCallback(app_ptr: *anyopaque) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.workspaceCount();
}

fn luaGetActiveWorkspaceIndexCallback(app_ptr: *anyopaque) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.activeWorkspaceIndex();
}

fn luaGetWorkspaceNameCallback(app_ptr: *anyopaque, index: usize, out_buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.workspaceName(index, out_buf);
}

fn luaGetWorkspaceIdCallback(app_ptr: *anyopaque, index: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.workspaceId(index);
}

fn luaIsLeaderActiveCallback(app_ptr: *anyopaque) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.isLeaderActive();
}

fn luaSetLeaderStateCallback(app_ptr: *anyopaque, active: bool, expires_at_ms: i64) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    app.setLeaderState(active, expires_at_ms);
}

fn luaSetBarCacheStateCallback(app_ptr: *anyopaque, surface: []const u8, dirty: bool, expires_at_ms: i64, visible: bool) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const bar_surface: BarSurface = if (std.mem.eql(u8, surface, "bottombar")) .bottombar else .topbar;
    app.setBarCacheState(bar_surface, dirty, expires_at_ms, visible);
}

fn luaCopySelectionCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.copy_selection);
}

fn luaPasteClipboardCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.paste_clipboard);
}

fn luaScrollActiveCallback(app_ptr: *anyopaque, delta: isize) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.{ .scroll_active_delta = delta });
}

fn luaScrollActivePageCallback(app_ptr: *anyopaque, pages: isize) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.{ .scroll_active_page = pages });
}

fn luaScrollActiveTopCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.scroll_active_top);
}

fn luaScrollActiveBottomCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.scroll_active_bottom);
}

fn luaPromptJumpCallback(app_ptr: *anyopaque, direction: []const u8) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const dir: PromptJumpDir = if (std.mem.eql(u8, direction, "prev")) .prev else .next;
    _ = app.enqueueMouse(.{ .prompt_jump = dir });
}

fn luaCopyModeEnterCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.copy_mode_enter);
}

fn luaCopyModeExitCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.copy_mode_exit);
}

fn luaCopyModeMoveCallback(app_ptr: *anyopaque, direction: []const u8, extend: bool) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const kind: CopyModeMoveKind = if (std.mem.eql(u8, direction, "left"))
        .left
    else if (std.mem.eql(u8, direction, "right"))
        .right
    else if (std.mem.eql(u8, direction, "up"))
        .up
    else if (std.mem.eql(u8, direction, "down"))
        .down
    else if (std.mem.eql(u8, direction, "page_up"))
        .page_up
    else if (std.mem.eql(u8, direction, "page_down"))
        .page_down
    else if (std.mem.eql(u8, direction, "line_start"))
        .line_start
    else if (std.mem.eql(u8, direction, "line_end"))
        .line_end
    else if (std.mem.eql(u8, direction, "top"))
        .top
    else if (std.mem.eql(u8, direction, "bottom"))
        .bottom
    else
        return;
    _ = app.enqueueMouse(.{ .copy_mode_move = .{ .kind = kind, .extend = extend } });
}

fn luaCopyModeClearSelectionCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.copy_mode_clear_selection);
}

fn luaCopyModeBeginSelectionCallback(app_ptr: *anyopaque, block: bool) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.{ .copy_mode_begin_selection = block });
}

fn luaCopyModeCopyCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.copy_mode_copy);
}

fn luaCopyModeOpenSearchCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.copy_mode_open_search);
}

fn luaCopyModeSearchSetQueryCallback(app_ptr: *anyopaque, query: []const u8) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const owned = app.allocator.dupe(u8, query) catch return;
    _ = app.enqueueMouse(.{ .copy_mode_search_set_query = owned });
}

fn luaCopyModeSearchNextCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.copy_mode_search_next);
}

fn luaCopyModeSearchPrevCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.copy_mode_search_prev);
}

test "app helpers count utf8 codepoints by leading byte" {
    try std.testing.expectEqual(@as(usize, 0), countUtf8Codepoints(""));
    try std.testing.expectEqual(@as(usize, 5), countUtf8Codepoints("hello"));
    try std.testing.expectEqual(@as(usize, 3), countUtf8Codepoints("A\xc3\xa9\xe2\x82\xac"));
    try std.testing.expectEqual(@as(usize, 1), countUtf8Codepoints("\xf0\x9f\x98\x80"));
    try std.testing.expectEqual(@as(usize, 1), countUtf8Codepoints("\xe2\x82"));
}

test "copy mode viewport row mapping handles unclamped and clamped scroll positions" {
    try std.testing.expectEqual(@as(?usize, 0), copyModeRowIndexInViewport(0, 0, 10));
    try std.testing.expectEqual(@as(?usize, 5), copyModeRowIndexInViewport(5, 0, 10));
    try std.testing.expectEqual(@as(?usize, 3), copyModeRowIndexInViewport(8, 5, 10));
    try std.testing.expectEqual(@as(?usize, 9), copyModeRowIndexInViewport(14, 5, 10));
    try std.testing.expectEqual(@as(?usize, null), copyModeRowIndexInViewport(15, 5, 10));
    try std.testing.expectEqual(@as(?usize, null), copyModeRowIndexInViewport(4, 5, 10));
}

test "history selection range projects into viewport bounds" {
    const within = historySelectionRangeInViewport(.{
        .start = .{ .row = 8, .col = 3 },
        .end = .{ .row = 11, .col = 4 },
    }, 5, 10).?;
    try std.testing.expectEqual(@as(usize, 3), within.start.row);
    try std.testing.expectEqual(@as(usize, 3), within.start.col);
    try std.testing.expectEqual(@as(usize, 6), within.end.row);
    try std.testing.expectEqual(@as(usize, 4), within.end.col);

    const clipped_top = historySelectionRangeInViewport(.{
        .start = .{ .row = 2, .col = 7 },
        .end = .{ .row = 6, .col = 1 },
    }, 5, 10).?;
    try std.testing.expectEqual(@as(usize, 0), clipped_top.start.row);
    try std.testing.expectEqual(@as(usize, 0), clipped_top.start.col);
    try std.testing.expectEqual(@as(usize, 1), clipped_top.end.row);
    try std.testing.expectEqual(@as(usize, 1), clipped_top.end.col);

    const clipped_bottom = historySelectionRangeInViewport(.{
        .start = .{ .row = 12, .col = 2 },
        .end = .{ .row = 20, .col = 9 },
    }, 5, 10).?;
    try std.testing.expectEqual(@as(usize, 7), clipped_bottom.start.row);
    try std.testing.expectEqual(@as(usize, 2), clipped_bottom.start.col);
    try std.testing.expectEqual(@as(usize, 9), clipped_bottom.end.row);
    try std.testing.expectEqual(@as(usize, std.math.maxInt(usize)), clipped_bottom.end.col);

    try std.testing.expectEqual(@as(?selection.Range, null), historySelectionRangeInViewport(.{
        .start = .{ .row = 0, .col = 0 },
        .end = .{ .row = 4, .col = 0 },
    }, 5, 10));
}

test "copy mode regex finder supports simple regexp operators" {
    const exact = App.copyModeRegexFind("foo", "xxfooyy", 0).?;
    try std.testing.expectEqual(@as(usize, 2), exact.start);
    try std.testing.expectEqual(@as(usize, 5), exact.end);

    const wildcard = App.copyModeRegexFind("f.o", "xxfoo", 0).?;
    try std.testing.expectEqual(@as(usize, 2), wildcard.start);
    try std.testing.expectEqual(@as(usize, 5), wildcard.end);

    const digits = App.copyModeRegexFind("\\d+", "abc123def", 0).?;
    try std.testing.expectEqual(@as(usize, 3), digits.start);
    try std.testing.expectEqual(@as(usize, 6), digits.end);

    const optional = App.copyModeRegexFind("colou?r", "color colour", 0).?;
    try std.testing.expectEqual(@as(usize, 0), optional.start);
    try std.testing.expectEqual(@as(usize, 5), optional.end);

    const anchored_start = App.copyModeRegexFind("^foo", "foobar", 0).?;
    try std.testing.expectEqual(@as(usize, 0), anchored_start.start);
    try std.testing.expectEqual(@as(usize, 3), anchored_start.end);

    const anchored_end = App.copyModeRegexFind("foo$", "barfoo", 0).?;
    try std.testing.expectEqual(@as(usize, 3), anchored_end.start);
    try std.testing.expectEqual(@as(usize, 6), anchored_end.end);

    const anchored_both = App.copyModeRegexFind("^foo$", "foo", 0).?;
    try std.testing.expectEqual(@as(usize, 0), anchored_both.start);
    try std.testing.expectEqual(@as(usize, 3), anchored_both.end);

    try std.testing.expectEqual(@as(?struct { start: usize, end: usize }, null), App.copyModeRegexFind("^foo", "xxfoo", 0));
    try std.testing.expectEqual(@as(?struct { start: usize, end: usize }, null), App.copyModeRegexFind("foo$", "foobar", 0));
}

test "viewport iterator row mapping follows platform row order" {
    if (builtin.os.tag == .linux) {
        try std.testing.expectEqual(@as(?usize, 4), viewportIteratorRowIndex(0, 5));
        try std.testing.expectEqual(@as(?usize, 2), viewportIteratorRowIndex(2, 5));
        try std.testing.expectEqual(@as(?usize, 0), viewportIteratorRowIndex(4, 5));
    } else {
        try std.testing.expectEqual(@as(?usize, 0), viewportIteratorRowIndex(0, 5));
        try std.testing.expectEqual(@as(?usize, 2), viewportIteratorRowIndex(2, 5));
        try std.testing.expectEqual(@as(?usize, 4), viewportIteratorRowIndex(4, 5));
    }
    try std.testing.expectEqual(@as(?usize, null), viewportIteratorRowIndex(5, 5));
}

test "titleCString truncates and null terminates window titles" {
    var input: [300]u8 = undefined;
    @memset(&input, 'x');

    const title = titleCString(input[0..]);

    try std.testing.expectEqual(@as(u8, 'x'), title[0]);
    try std.testing.expectEqual(@as(u8, 'x'), title[254]);
    try std.testing.expectEqual(@as(u8, 0), title[255]);
}

test "jsonObjectIndex accepts non-negative integers and whole floats" {
    var object = std.json.ObjectMap.init(std.testing.allocator);
    defer object.deinit();

    try object.put("int", .{ .integer = 7 });
    try object.put("float", .{ .float = 3.0 });
    try object.put("negative", .{ .integer = -1 });
    try object.put("fraction", .{ .float = 2.5 });
    try object.put("text", .{ .string = "4" });

    try std.testing.expectEqual(@as(?usize, 7), jsonObjectIndex(object, "int"));
    try std.testing.expectEqual(@as(?usize, 3), jsonObjectIndex(object, "float"));
    try std.testing.expectEqual(@as(?usize, null), jsonObjectIndex(object, "negative"));
    try std.testing.expectEqual(@as(?usize, null), jsonObjectIndex(object, "fraction"));
    try std.testing.expectEqual(@as(?usize, null), jsonObjectIndex(object, "text"));
    try std.testing.expectEqual(@as(?usize, null), jsonObjectIndex(object, "missing"));
}

test "chunkPayloadObject stores chunk metadata and owned payload" {
    const object = try chunkPayloadObject(std.testing.allocator, "payload", 2, 5);
    defer {
        const value = std.json.Value{ .object = object };
        deinitJsonValue(std.testing.allocator, value);
    }

    try std.testing.expectEqual(@as(?usize, 2), jsonObjectIndex(object, "index"));
    try std.testing.expectEqual(@as(?usize, 5), jsonObjectIndex(object, "total"));
    try std.testing.expectEqualStrings("payload", jsonObjectString(object, "data").?);
}

test "cloneJsonValue deep copies nested JSON values" {
    var source = std.json.ObjectMap.init(std.testing.allocator);
    defer {
        const source_value = std.json.Value{ .object = source };
        deinitJsonValue(std.testing.allocator, source_value);
    }

    var nested = std.json.Array.init(std.testing.allocator);
    try nested.append(.{ .string = try std.testing.allocator.dupe(u8, "alpha") });
    try nested.append(.{ .integer = 9 });
    try source.put(try std.testing.allocator.dupe(u8, "list"), .{ .array = nested });

    const clone = try cloneJsonValue(std.testing.allocator, .{ .object = source });
    defer deinitJsonValue(std.testing.allocator, clone);

    const cloned_object = clone.object;
    const cloned_array = cloned_object.get("list").?.array;
    try std.testing.expectEqual(@as(usize, 2), cloned_array.items.len);
    try std.testing.expectEqualStrings("alpha", cloned_array.items[0].string);
    try std.testing.expectEqual(@as(i64, 9), cloned_array.items[1].integer);

    const original_array = source.get("list").?.array;
    try std.testing.expect(cloned_array.items.ptr != original_array.items.ptr);
    try std.testing.expect(cloned_array.items[0].string.ptr != original_array.items[0].string.ptr);
}

test "firstCodepoint handles ascii utf8 and invalid prefixes" {
    try std.testing.expectEqual(@as(u32, 0), firstCodepoint(""));
    try std.testing.expectEqual(@as(u32, 'A'), firstCodepoint("ABC"));
    try std.testing.expectEqual(@as(u32, 0x20AC), firstCodepoint("\xe2\x82\xac rest"));
    try std.testing.expectEqual(@as(u32, 0xF0), firstCodepoint("\xf0\x9f"));
    try std.testing.expectEqual(@as(u32, 0xFF), firstCodepoint("\xffbad"));
}

test "encodeCodepointInto emits utf8 byte sequences" {
    var buf: [4]u8 = undefined;

    try std.testing.expectEqual(@as(?usize, null), encodeCodepointInto(0, &buf));
    try std.testing.expectEqual(@as(?usize, 1), encodeCodepointInto('A', &buf));
    try std.testing.expectEqualStrings("A", buf[0..1]);

    try std.testing.expectEqual(@as(?usize, 2), encodeCodepointInto(0x00E9, &buf));
    try std.testing.expectEqualSlices(u8, "\xc3\xa9", buf[0..2]);

    try std.testing.expectEqual(@as(?usize, 3), encodeCodepointInto(0x20AC, &buf));
    try std.testing.expectEqualSlices(u8, "\xe2\x82\xac", buf[0..3]);

    try std.testing.expectEqual(@as(?usize, 4), encodeCodepointInto(0x1F600, &buf));
    try std.testing.expectEqualSlices(u8, "\xf0\x9f\x98\x80", buf[0..4]);
}

test "legacyPrintableKeyText maps printable keys and shifted symbols" {
    var out: [4]u8 = undefined;

    try std.testing.expectEqualStrings("a", legacyPrintableKeyText(.a, 0, &out).?);
    try std.testing.expectEqualStrings("A", legacyPrintableKeyText(.a, ghostty.Mods.shift, &out).?);
    try std.testing.expectEqualStrings("1", legacyPrintableKeyText(.digit_1, 0, &out).?);
    try std.testing.expectEqualStrings("!", legacyPrintableKeyText(.digit_1, ghostty.Mods.shift, &out).?);
    try std.testing.expectEqualStrings("/", legacyPrintableKeyText(.slash, 0, &out).?);
    try std.testing.expectEqualStrings("?", legacyPrintableKeyText(.slash, ghostty.Mods.shift, &out).?);
    try std.testing.expectEqualStrings("\r", legacyPrintableKeyText(.enter, 0, &out).?);
    try std.testing.expectEqualStrings("\x7f", legacyPrintableKeyText(.backspace, 0, &out).?);
    try std.testing.expectEqual(@as(?[]const u8, null), legacyPrintableKeyText(.tab, ghostty.Mods.shift, &out));
    try std.testing.expectEqual(@as(?[]const u8, null), legacyPrintableKeyText(.escape, 0, &out));
}
