const std = @import("std");
const c = @import("sokol_c");
const builtin = @import("builtin");
const command_mod = @import("command.zig");
const command_ipc = @import("ipc.zig");
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
const ConfigWatcher = @import("config_watcher.zig").ConfigWatcher;
const selection = @import("selection.zig");
const terminal_callbacks = @import("app/terminal_callbacks.zig");
const lua_callbacks = @import("app/lua_callbacks.zig");
const text_helpers = @import("app/text_helpers.zig");
const selection_mod = @import("app/selection.zig");
const copy_mode = @import("app/copy_mode.zig");
const htp = @import("app/htp.zig");
const input = @import("app/input.zig");
const hyperlinks = @import("app/hyperlinks.zig");
const scroll = @import("app/scroll.zig");
const cmd_ipc = @import("app/command_dispatcher.zig");
const mux_ops = @import("app/mux_ops.zig");

const embedded_base_config: []const u8 = build_options.embedded_base_config;
const embedded_types: []const u8 = build_options.embedded_types;
threadlocal var g_prefixed_window_title_buf: [256]u8 = undefined;

pub const SplitCommandMode = enum {
    send,
    spawn,
};

extern fn sapp_set_window_title(title: [*:0]const u8) void;

const CLIPBOARD_EVENT_MAX = 8192;

pub const BarSurface = enum {
    topbar,
    bottombar,
};

pub const CopyModeMoveKind = enum {
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

pub const PromptJumpDir = enum {
    prev,
    next,
};

fn viewportIteratorRowIndex(visual_row: usize, visible_rows: usize) ?usize {
    if (visual_row >= visible_rows) return null;
    if (builtin.os.tag == .linux and visible_rows > 0) {
        return (visible_rows - 1) - visual_row;
    }
    return visual_row;
}

pub fn jsonObjectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

pub fn dupeJsonSafeString(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn jsonObjectValue(object: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    return object.get(key);
}

pub fn jsonObjectIndex(object: std.json.ObjectMap, key: []const u8) ?usize {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .float => |n| if (n >= 0 and std.math.floor(n) == n) @intFromFloat(n) else null,
        else => null,
    };
}

pub fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
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

pub fn deinitJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
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

pub fn jsonObjectValueClone(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !?std.json.Value {
    const value = jsonObjectValue(object, key) orelse return null;
    return try cloneJsonValue(allocator, value);
}

/// Re-exported from input.zig (formerly PendingMouseEvent).
pub const PendingInputEvent = input.PendingInputEvent;

var wake_bridge: ?*App = null;

pub fn signalExternalWake() void {
    const app = wake_bridge orelse return;
    app.signalWake();
}

pub const App = struct {
    pub const ScrollbarMetrics = scroll.ScrollbarMetrics;
    pub const HoveredHyperlink = hyperlinks.HoveredHyperlink;

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
    pending_post_split_snap: ?struct {
        node: *SplitNode,
        ratio: f32,
        direction: SplitDirection,
    } = null,
    debug_split_trace_frames: u8 = 0,
    /// Set when all panes/tabs have closed; the runtime should call sapp_request_quit().
    pending_quit: bool = false,
    hovered_tab_index: ?usize = null,
    hovered_close_tab_index: ?usize = null,
    startup_command: ?[]u8 = null,
    startup_command_delay_frames: usize = 0,
    startup_command_sent: bool = false,
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
    copy_mode_history: std.ArrayListUnmanaged(copy_mode.CopyModeLine) = .empty,
    copy_mode_cursor: copy_mode.CopyModePoint = .{},
    copy_mode_anchor: ?copy_mode.CopyModePoint = null,
    copy_mode_matches: std.ArrayListUnmanaged(copy_mode.CopyModeMatch) = .empty,
    copy_mode_match_index: ?usize = null,
    copy_mode_query: []u8 = &.{},
    copy_mode_needs_refresh: bool = false,
    copy_mode_top_row: usize = 0,
    copy_mode_block_selection: bool = false,
    copy_mode_restore_top_row: usize = 0,
    htp_pending_messages: std.ArrayListUnmanaged(htp.HtpQueuedMessage) = .empty,
    htp_pending_message_head: usize = 0,
    htp_pending_message_bytes: usize = 0,
    htp_chunk_assemblies: std.ArrayListUnmanaged(htp.HtpChunkAssembly) = .empty,
    htp_next_message_id: u64 = 1,
    command_ipc_server: ?command_ipc.Server = null,
    pane_tags: std.ArrayListUnmanaged(cmd_ipc.PaneTagEntry) = .empty,
    command_mutex: std.Thread.Mutex = .{},
    command_ready: std.Thread.Condition = .{},
    command_done: std.Thread.Condition = .{},
    pending_command: ?*cmd_ipc.PendingCommandRequest = null,
    leader_visual_active: bool = false,
    leader_visual_expires_at_ns: i128 = 0,
    topbar_cache_visible: bool = false,
    topbar_cache_dirty: bool = true,
    topbar_cache_expires_at_ns: i128 = 0,
    config_watcher: ?*ConfigWatcher = null,
    config_watch_reload_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    bottombar_cache_visible: bool = false,
    bottombar_cache_dirty: bool = true,
    bottombar_cache_expires_at_ns: i128 = 0,
    next_idle_render_poll_ns: i128 = 0,
    wake_generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // ── Pending input event queue ─────────────────────────────────────────────
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
    input_queue: [64]input.PendingInputEvent = [_]input.PendingInputEvent{.none} ** 64,
    input_queue_head: usize = 0, // next slot to read  (frame thread)
    input_queue_tail: usize = 0, // next slot to write (event thread)

    pub fn hasPendingCommand(self: *App) bool {
        return cmd_ipc.hasPendingCommand(self);
    }

    /// Push any pending event onto the shared ring buffer.  Called from the
    /// event thread.  Returns true on success, false if the queue is full
    /// (event is dropped — better than a crash or a data race).
    pub fn enqueueMouse(self: *App, ev: input.PendingInputEvent) bool {
        const cap = self.input_queue.len;
        const next_tail = (self.input_queue_tail + 1) % cap;
        if (next_tail == @atomicLoad(usize, &self.input_queue_head, .acquire)) {
            return false;
        }
        const now_ns = std.time.nanoTimestamp();
        self.last_input_activity_ns = now_ns;
        self.last_visual_activity_ns = now_ns;
        self.input_queue[self.input_queue_tail] = ev;
        @atomicStore(usize, &self.input_queue_tail, next_tail, .release);
        input.signalWake(self);
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
        var ev: input.PendingInputEvent = .{ .char = .{ .bytes = [_]u8{0} ** 5, .len = @intCast(bytes.len) } };
        fastmem.copy(u8, ev.char.bytes[0..bytes.len], bytes);
        return self.enqueueMouse(ev);
    }



    pub fn currentPaneIdValue(self: *App) usize {
        const pane = self.activePane() orelse return 0;
        return @intFromPtr(pane);
    }

    pub fn currentWorkspaceIdValue(self: *App) ?usize {
        const workspace = self.activeWorkspace() orelse return null;
        return workspace.id;
    }

    pub fn domainValue(self: *App, name: []const u8) !std.json.Value {
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

    pub fn currentDomainValue(self: *App) !?std.json.Value {
        const pane = self.activePane() orelse return null;
        if (pane.domain_name.len == 0) return null;
        return try self.domainValue(pane.domain_name);
    }

    pub fn paneFrameValue(self: *App, pane: *Pane) !std.json.Value {
        var object = std.json.ObjectMap.init(self.allocator);
        errdefer deinitJsonValue(self.allocator, .{ .object = object });
        try object.put(try self.allocator.dupe(u8, "x"), .{ .integer = @intCast(pane.x_px) });
        try object.put(try self.allocator.dupe(u8, "y"), .{ .integer = @intCast(pane.y_px) });
        try object.put(try self.allocator.dupe(u8, "width"), .{ .integer = @intCast(pane.width_px) });
        try object.put(try self.allocator.dupe(u8, "height"), .{ .integer = @intCast(pane.height_px) });
        return .{ .object = object };
    }

    pub fn paneSizeValue(self: *App, pane: *Pane) !std.json.Value {
        var object = std.json.ObjectMap.init(self.allocator);
        errdefer deinitJsonValue(self.allocator, .{ .object = object });
        try object.put(try self.allocator.dupe(u8, "rows"), .{ .integer = @intCast(pane.rows) });
        try object.put(try self.allocator.dupe(u8, "cols"), .{ .integer = @intCast(pane.cols) });
        try object.put(try self.allocator.dupe(u8, "width"), .{ .integer = @intCast(pane.width_px) });
        try object.put(try self.allocator.dupe(u8, "height"), .{ .integer = @intCast(pane.height_px) });
        return .{ .object = object };
    }

    pub fn snapshotPane(self: *App, pane_id: usize) !?std.json.Value {
        const pane = self.findPaneById(pane_id) orelse return null;
        var object = std.json.ObjectMap.init(self.allocator);
        errdefer deinitJsonValue(self.allocator, .{ .object = object });

        try object.put(try self.allocator.dupe(u8, "id"), .{ .integer = @intCast(pane_id) });
        try object.put(try self.allocator.dupe(u8, "pid"), .{ .integer = @intCast(pane.childPid()) });
        try object.put(try self.allocator.dupe(u8, "domain"), .{ .string = try dupeJsonSafeString(self.allocator, pane.domain_name) });
        try object.put(try self.allocator.dupe(u8, "cwd"), .{ .string = try dupeJsonSafeString(self.allocator, pane.cwd) });
        try object.put(try self.allocator.dupe(u8, "title"), .{ .string = try dupeJsonSafeString(self.allocator, pane.title) });
        try object.put(try self.allocator.dupe(u8, "foreground_process"), .{ .string = try dupeJsonSafeString(self.allocator, pane.foreground_process orelse "") });
        try object.put(try self.allocator.dupe(u8, "tags"), try cmd_ipc.getPaneTags(self, pane_id));
        try object.put(try self.allocator.dupe(u8, "is_focused"), .{ .bool = self.currentPaneIdValue() == pane_id });
        try object.put(try self.allocator.dupe(u8, "is_floating"), .{ .bool = pane.is_floating });
        try object.put(try self.allocator.dupe(u8, "is_maximized"), .{ .bool = if (self.mux) |*mux| mux.paneIsMaximized(pane) else false });
        try object.put(try self.allocator.dupe(u8, "frame"), try self.paneFrameValue(pane));
        try object.put(try self.allocator.dupe(u8, "size"), try self.paneSizeValue(pane));
        return .{ .object = object };
    }

    pub fn snapshotPaneValue(self: *App, pane_id: usize) !?std.json.Value {
        if (pane_id == 0) return self.currentPaneValue();
        return try self.snapshotPane(pane_id);
    }

    pub fn currentPaneValue(self: *App) !?std.json.Value {
        const pane = self.activePane() orelse return null;
        return try self.snapshotPane(@intFromPtr(pane));
    }

    pub fn paneTextValue(self: *App, pane_id: usize) !std.json.Value {
        const buf = try self.allocator.alloc(u8, 256 * 1024);
        defer self.allocator.free(buf);
        const text = self.getPaneText(pane_id, buf);
        return .{ .string = try self.allocator.dupe(u8, text) };
    }

    pub fn snapshotTab(self: *App, tab: *Tab, index: usize) !std.json.Value {
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

    pub fn snapshotTabValue(self: *App, tab_id: ?usize) !?std.json.Value {
        const id = tab_id orelse return self.currentTabValue();
        const workspace = self.activeWorkspace() orelse return null;
        for (workspace.tabs.items, 0..) |tab, index| {
            if (tab.id == id) return try self.snapshotTab(tab, index);
        }
        return null;
    }

    pub fn currentTabValue(self: *App) !?std.json.Value {
        const workspace = self.activeWorkspace() orelse return null;
        const tab = self.activeTab() orelse return null;
        for (workspace.tabs.items, 0..) |candidate, index| {
            if (candidate == tab) return try self.snapshotTab(candidate, index);
        }
        return null;
    }

    pub fn tabsValue(self: *App) !std.json.Value {
        var array = std.json.Array.init(self.allocator);
        errdefer deinitJsonValue(self.allocator, .{ .array = array });
        const workspace = self.activeWorkspace() orelse return .{ .array = array };
        for (workspace.tabs.items, 0..) |tab, index| try array.append(try self.snapshotTab(tab, index));
        return .{ .array = array };
    }

    pub fn panesValue(self: *App, wanted_tag: ?[]const u8) !std.json.Value {
        var array = std.json.Array.init(self.allocator);
        errdefer deinitJsonValue(self.allocator, .{ .array = array });
        if (self.mux) |*mux| {
            var panes = mux.paneIterator();
            while (panes.next()) |pane| {
                const pane_id = @intFromPtr(pane);
                if (wanted_tag) |tag| {
                    const entry = cmd_ipc.findPaneTagEntry(self, pane_id) orelse continue;
                    if (!entry.tags.contains(tag)) continue;
                }
                const pane_value = try self.snapshotPane(pane_id);
                if (pane_value) |value| try array.append(value);
            }
        }
        return .{ .array = array };
    }

    pub fn snapshotWorkspace(self: *App, workspace: *Workspace, index: usize) !std.json.Value {
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

    pub fn snapshotWorkspaceValue(self: *App, workspace_id: ?usize) !?std.json.Value {
        const id = workspace_id orelse return self.currentWorkspaceValue();
        if (self.mux) |*mux| {
            for (mux.workspaces.items, 0..) |workspace, index| {
                if (workspace.id == id) return try self.snapshotWorkspace(workspace, index);
            }
        }
        return null;
    }

    pub fn currentWorkspaceValue(self: *App) !?std.json.Value {
        if (self.mux) |*mux| {
            const workspace = mux.activeWorkspace() orelse return null;
            return try self.snapshotWorkspace(workspace, mux.activeWorkspaceIndex());
        }
        return null;
    }

    pub fn workspacesValue(self: *App) !std.json.Value {
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

        terminal_callbacks.write_bridge = null;
        terminal_callbacks.size_bridge = null;
        terminal_callbacks.attrs_bridge = null;
        terminal_callbacks.title_bridge = null;
        terminal_callbacks.bell_bridge = null;
        htp.htp_bridge = null;
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
        std.log.info("App.deinit begin", .{});

        input.deinitInputQueue(self);
        self.shutdownRuntime();
        self.deinitialized = true;
        copy_mode.deinitCopyModeState(self);

        for (self.htp_pending_messages.items[self.htp_pending_message_head..]) |message| {
            self.allocator.free(message.payload);
        }
        self.htp_pending_messages.deinit(self.allocator);
        for (self.htp_chunk_assemblies.items) |*assembly| {
            htp.deinitChunkAssembly(self.allocator, assembly);
        }
        self.htp_chunk_assemblies.deinit(self.allocator);
        cmd_ipc.deinitPaneTags(self);

        if (self.base_config_path) |path| {
            self.allocator.free(path);
            self.base_config_path = null;
        }
        if (self.override_config_path) |path| {
            self.allocator.free(path);
            self.override_config_path = null;
        }
        if (self.startup_command) |cmd| {
            self.allocator.free(cmd);
            self.startup_command = null;
        }
        if (self.config_watcher) |w| {
            w.destroy(self.allocator);
            self.config_watcher = null;
        }
        self.config.deinit();
        std.log.info("App.deinit done", .{});
    }

    pub fn configureAutomation(self: *App, startup_command: ?[]const u8, startup_command_delay_frames: usize) !void {
        if (startup_command) |cmd| {
            if (self.startup_command) |owned| self.allocator.free(owned);
            self.startup_command = try self.allocator.dupe(u8, cmd);
            self.startup_command_delay_frames = startup_command_delay_frames;
            self.startup_command_sent = false;
        }
    }

    pub fn bootstrap(self: *App, config_override: ?[]const u8) !void {
        const config_paths = try self.resolveConfigPaths(config_override);
        self.using_embedded_base_config = config_paths.use_embedded_base;
        self.base_config_path = config_paths.base;
        self.override_config_path = config_paths.override;

        {
            const config_user_path = try platform.defaultConfigPath(self.allocator);
            defer self.allocator.free(config_user_path);
            if (std.fs.path.dirname(config_user_path)) |config_dir| {
                std.fs.cwd().makePath(config_dir) catch |err| {
                    std.log.warn("could not create config dir for LuaLS types: {s}", .{@errorName(err)});
                };
                if (std.fs.cwd().openDir(config_dir, .{})) |captured| {
                    var dir = captured;
                    defer dir.close();
                    dir.makePath("types") catch |err| {
                        std.log.warn("could not create types dir for LuaLS: {s}", .{@errorName(err)});
                    };
                    dir.writeFile(.{ .sub_path = "types/hollow.lua", .data = embedded_types }) catch |err| {
                        std.log.warn("failed to write LuaLS types: {s}", .{@errorName(err)});
                    };
                } else |err| {
                    std.log.warn("could not open config dir for LuaLS types: {s}", .{@errorName(err)});
                }
            }
        }

        self.tryInitLua();
        std.log.info("config: command_timing={}", .{self.config.command_timing});
        cmd_ipc.syncCommandTimingEnv(self);

        var runtime = try GhosttyRuntime.init(self.allocator, null);
        errdefer runtime.deinit();
        _ = runtime.setSysUserdata(null);
        _ = runtime.setSysDecodePng(hollow_decode_png);

        var mux = Mux.init(self.allocator);
        errdefer mux.deinit(&runtime);

        // Set bridge globals before bootstrapSingle so the callbacks are valid
        // the moment ghostty can first invoke them (during resizeTerminal inside
        // bootstrap).
        terminal_callbacks.write_bridge = self;
        terminal_callbacks.size_bridge = self;
        terminal_callbacks.attrs_bridge = self;
        terminal_callbacks.title_bridge = self;
        terminal_callbacks.bell_bridge = self;
        htp.htp_bridge = self;
        wake_bridge = self;
        cmd_ipc.startCommandTransport(self);
        const cbs = terminal_callbacks.terminalCallbacks();
        try mux.bootstrapSingle(&runtime, cbs, self.config, self.cell_width_px, self.cell_height_px, self.config.window_width, self.config.window_height);

        self.ghostty = runtime;
        self.mux = mux;
        htp.bindHtpHandlers(self);
        self.renderer = Backend.init(self.allocator, self.config);

        // Register app action callbacks so Lua can call split_pane etc.
        if (self.lua) |*lua| {
            self.registerLuaCallbacks(lua);
        }

        try self.tick();
        self.startConfigWatcher();
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
            .refresh_live_config = lua_callbacks.luaRefreshLiveConfigCallback,
            .split_pane = lua_callbacks.luaSplitPaneCallback,
            .toggle_pane_maximized = lua_callbacks.luaTogglePaneMaximizedCallback,
            .set_pane_floating = lua_callbacks.luaSetPaneFloatingCallback,
            .set_floating_pane_bounds = lua_callbacks.luaSetFloatingPaneBoundsCallback,
            .set_pane_foreground_process = lua_callbacks.luaSetPaneForegroundProcessCallback,
            .move_pane = lua_callbacks.luaMovePaneCallback,
            .new_tab = lua_callbacks.luaNewTabCallback,
            .close_tab = lua_callbacks.luaCloseTabCallback,
            .close_pane = lua_callbacks.luaClosePaneCallback,
            .next_tab = lua_callbacks.luaNextTabCallback,
            .prev_tab = lua_callbacks.luaPrevTabCallback,
            .new_workspace = lua_callbacks.luaNewWorkspaceCallback,
            .close_workspace = lua_callbacks.luaCloseWorkspaceCallback,
            .next_workspace = lua_callbacks.luaNextWorkspaceCallback,
            .prev_workspace = lua_callbacks.luaPrevWorkspaceCallback,
            .switch_workspace = lua_callbacks.luaSwitchWorkspaceCallback,
            .focus_pane = lua_callbacks.luaFocusPaneCallback,
            .focus_pane_by_id = lua_callbacks.luaFocusPaneByIdCallback,
            .resize_pane = lua_callbacks.luaResizePaneCallback,
            .switch_tab = lua_callbacks.luaSwitchTabCallback,
            .set_workspace_name = lua_callbacks.luaSetWorkspaceNameCallback,
            .set_workspace_default_cwd = lua_callbacks.luaSetWorkspaceDefaultCwdCallback,
            .set_tab_title = lua_callbacks.luaSetTabTitleCallback,
            .set_tab_title_by_id = lua_callbacks.luaSetTabTitleByIdCallback,
            .reload_config = lua_callbacks.luaReloadConfigCallback,
            .get_tab_count = lua_callbacks.luaGetTabCountCallback,
            .get_active_tab_index = lua_callbacks.luaGetActiveTabIndexCallback,
            .get_current_tab_id = lua_callbacks.luaCurrentTabIdCallback,
            .get_current_pane_id = lua_callbacks.luaCurrentPaneIdCallback,
            .get_tab_id_at = lua_callbacks.luaGetTabIdAtCallback,
            .get_tab_pane_count = lua_callbacks.luaGetTabPaneCountCallback,
            .get_tab_pane_id_at = lua_callbacks.luaGetTabPaneIdAtCallback,
            .get_tab_active_pane_id = lua_callbacks.luaGetTabActivePaneIdCallback,
            .get_tab_index_by_id = lua_callbacks.luaGetTabIndexByIdCallback,
            .get_workspace_count = lua_callbacks.luaGetWorkspaceCountCallback,
            .get_active_workspace_index = lua_callbacks.luaGetActiveWorkspaceIndexCallback,
            .get_workspace_id = lua_callbacks.luaGetWorkspaceIdCallback,
            .get_workspace_name = lua_callbacks.luaGetWorkspaceNameCallback,
            .get_pane_pid = lua_callbacks.luaGetPanePidCallback,
            .get_pane_title = lua_callbacks.luaGetPaneTitleCallback,
            .get_pane_cwd = lua_callbacks.luaGetPaneCwdCallback,
            .get_pane_text = lua_callbacks.luaGetPaneTextCallback,
            .get_pane_foreground_process = lua_callbacks.luaGetPaneForegroundProcessCallback,
            .get_pane_rows = lua_callbacks.luaGetPaneRowsCallback,
            .get_pane_cols = lua_callbacks.luaGetPaneColsCallback,
            .get_pane_x = lua_callbacks.luaGetPaneXCallback,
            .get_pane_y = lua_callbacks.luaGetPaneYCallback,
            .get_pane_width = lua_callbacks.luaGetPaneWidthCallback,
            .get_pane_height = lua_callbacks.luaGetPaneHeightCallback,
            .get_window_width = lua_callbacks.luaGetWindowWidthCallback,
            .get_window_height = lua_callbacks.luaGetWindowHeightCallback,
            .now_ms = lua_callbacks.luaNowMsCallback,
            .pane_is_floating = lua_callbacks.luaPaneIsFloatingCallback,
            .pane_is_maximized = lua_callbacks.luaPaneIsMaximizedCallback,
            .pane_is_focused = lua_callbacks.luaPaneIsFocusedCallback,
            .pane_has_bell = lua_callbacks.luaPaneHasBellCallback,
            .pane_exists = lua_callbacks.luaPaneExistsCallback,
            .switch_tab_by_id = lua_callbacks.luaSwitchTabByIdCallback,
            .close_tab_by_id = lua_callbacks.luaCloseTabByIdCallback,
            .close_pane_by_id = lua_callbacks.luaClosePaneByIdCallback,
            .move_tab_to_workspace = lua_callbacks.luaMoveTabToWorkspaceCallback,
            .move_pane_to_workspace = lua_callbacks.luaMovePaneToWorkspaceCallback,
            .send_text_to_pane = lua_callbacks.luaSendTextToPaneCallback,
            .send_key_to_pane = lua_callbacks.luaSendKeyToPaneCallback,
            .get_pane_domain = lua_callbacks.luaGetPaneDomainCallback,
            .get_pane_active_screen = lua_callbacks.luaGetPaneActiveScreenCallback,
            .is_leader_active = lua_callbacks.luaIsLeaderActiveCallback,
            .set_leader_state = lua_callbacks.luaSetLeaderStateCallback,
            .set_bar_cache_state = lua_callbacks.luaSetBarCacheStateCallback,
            .copy_selection = lua_callbacks.luaCopySelectionCallback,
            .paste_clipboard = lua_callbacks.luaPasteClipboardCallback,
            .scroll_active = lua_callbacks.luaScrollActiveCallback,
            .scroll_active_page = lua_callbacks.luaScrollActivePageCallback,
            .scroll_active_top = lua_callbacks.luaScrollActiveTopCallback,
            .scroll_active_bottom = lua_callbacks.luaScrollActiveBottomCallback,
            .prompt_jump = lua_callbacks.luaPromptJumpCallback,
            .copy_mode_enter = lua_callbacks.luaCopyModeEnterCallback,
            .copy_mode_exit = lua_callbacks.luaCopyModeExitCallback,
            .copy_mode_move = lua_callbacks.luaCopyModeMoveCallback,
            .copy_mode_begin_selection = lua_callbacks.luaCopyModeBeginSelectionCallback,
            .copy_mode_clear_selection = lua_callbacks.luaCopyModeClearSelectionCallback,
            .copy_mode_copy = lua_callbacks.luaCopyModeCopyCallback,
            .copy_mode_open_search = lua_callbacks.luaCopyModeOpenSearchCallback,
            .copy_mode_search_set_query = lua_callbacks.luaCopyModeSearchSetQueryCallback,
            .copy_mode_search_next = lua_callbacks.luaCopyModeSearchNextCallback,
            .copy_mode_search_prev = lua_callbacks.luaCopyModeSearchPrevCallback,
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

        lua.runString("if type(hollow) == 'table' and type(hollow.keymap) == 'table' and type(hollow.keymap.apply_defaults) == 'function' then hollow.keymap.apply_defaults() end") catch {};

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
            mux_ops.cleanupDeadPanes(self, runtime);
            if (self.config.debug_overlay) cleanup_ns = std.time.nanoTimestamp() - start_ns;
        }
        {
            const start_ns = if (self.config.debug_overlay) std.time.nanoTimestamp() else 0;
            selection_mod.pruneSelectionIfInvalid(self);
            copy_mode.pruneCopyModeIfInvalid(self);
            if (self.config.debug_overlay) prune_ns = std.time.nanoTimestamp() - start_ns;
        }
        {
            const start_ns = if (self.config.debug_overlay) std.time.nanoTimestamp() else 0;
            if (self.lua) |*lua| lua.runDeferredCallbacks();
            if (self.config.debug_overlay) events_ns = std.time.nanoTimestamp() - start_ns;
        }
        {
            const start_ns = if (self.config.debug_overlay) std.time.nanoTimestamp() else 0;
            input.processInputQueue(self);
            if (self.config.debug_overlay) events_ns = std.time.nanoTimestamp() - start_ns;
        }
        {
            const start_ns = if (self.config.debug_overlay) std.time.nanoTimestamp() else 0;
            htp.processHtpMessages(self);
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
            hyperlinks.updateHoveredHyperlink(self);
            if (self.config.debug_overlay) hover_ns = std.time.nanoTimestamp() - start_ns;
        }
        {
            const start_ns = if (self.config.debug_overlay) std.time.nanoTimestamp() else 0;
            mux_ops.maybeRunStartupCommand(self, );
            if (self.config.debug_overlay) startup_ns = std.time.nanoTimestamp() - start_ns;
        }
        {
            self.drainConfigWatchFlag();
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
        return input.hasVisualActivityAt(self, std.time.nanoTimestamp(), true);
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
            next_wake_ns = input.minWakeNs(next_wake_ns, self.leader_visual_expires_at_ns);
        }
        if (self.topbar_cache_expires_at_ns != 0) {
            next_wake_ns = input.minWakeNs(next_wake_ns, self.topbar_cache_expires_at_ns);
        }
        if (self.bottombar_cache_expires_at_ns != 0) {
            next_wake_ns = input.minWakeNs(next_wake_ns, self.bottombar_cache_expires_at_ns);
        }
        return next_wake_ns;
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
        for (self.config.watch_dirs.items) |dir| std.log.info("watch_dir={s}", .{dir});
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

    pub fn requestLayoutResize(self: *App, recreate_render_helpers: bool) void {
        self.pending_layout_resize = true;
        self.pending_layout_recreate_render_helpers = self.pending_layout_recreate_render_helpers or recreate_render_helpers;
        self.layout_generation +%= 1;
        if (self.layout_generation == 0) self.layout_generation = 1;
        self.hover_probe_dirty = true;
        self.invalidateCachedBarLayouts();
        self.signalWake();
    }

    pub fn requestLayoutRefresh(self: *App) void {
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

    pub fn syncActivePaneChange(self: *App, previous: ?*Pane, current: ?*Pane) void {
        self.invalidateFocusedPaneCache(previous, current);
        if (previous == current) return;
        if (current) |pane| {
            if (pane.has_bell_attention) {
                pane.has_bell_attention = false;
                // Tab labels may have been rendering an attention marker.
                self.topbar_cache_dirty = true;
            }
        }
        if (self.ghostty) |*runtime| {
            if (current) |pane| runtime.registerCallbacks(pane.terminal, terminal_callbacks.terminalCallbacks());
        }
    }

    pub fn refreshActivePaneBinding(self: *App) void {
        if (self.activePane()) |pane| {
            pane.render_dirty = .full;
            if (self.ghostty) |*runtime| {
                runtime.registerCallbacks(pane.terminal, terminal_callbacks.terminalCallbacks());
            }
        }
    }

    pub fn refreshActivePaneDisplay(self: *App) void {
        const pane = self.activePane() orelse return;
        const runtime = if (self.ghostty) |*rt| rt else return;
        runtime.terminalScrollBottom(pane.terminal);
        pane.render_dirty = .full;
        pane.last_render_state_update_ns = 0;
        pane.pty_received_data = true;
        self.scroll_accum = 0;
        _ = scroll.refreshPaneScrollbar(self, runtime, pane);
    }

    pub fn pasteClipboard(self: *App) !void {
        const clipboard = c.sapp_get_clipboard_string();
        const text = std.mem.span(clipboard);
        if (text.len == 0) {
            std.log.warn("pasteClipboard: clipboard string is empty", .{});
            return;
        }
        try mux_ops.sendPaste(self, text);
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
            return selection_mod.cellPointFromPaneLocal(
                self,
                pane,
                clamped_x - @as(f32, @floatFromInt(inner.x)),
                clamped_y - @as(f32, @floatFromInt(inner.y)),
            );
        }
        if (self.activePane() == pane) {
            return selection_mod.cellPointFromPaneLocal(self, pane, x, y);
        }
        return null;
    }

    pub fn signalWake(self: *App) void {
        input.signalWake(self);
    }

    pub fn currentWakeGeneration(self: *const App) u32 {
        return input.currentWakeGeneration(self);
    }

    pub fn waitForWake(self: *const App, wake_generation: u32, timeout_ns: u64) void {
        std.Thread.Futex.timedWait(&self.wake_generation, wake_generation, timeout_ns) catch {};
    }

    fn panePadding(self: *const App, pane: *const Pane) Config.TerminalPadding {
        return if (pane.active_screen == @intFromEnum(ghostty.TerminalScreen.alternate))
            self.config.alternate_screen_padding
        else
            self.config.terminal_padding;
    }

    fn paneHorizontalReserved(self: *const App, pane: *const Pane) u32 {
        return self.panePadding(pane).horizontal() + scroll.paneScrollbarGutter(self, pane);
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

    pub fn paneRenderHelpersReady(pane: *const Pane) bool {
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
                text_helpers.appendCellText(runtime, pane.row_cells, row_text[0..], &row_len);
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

    pub fn sendFocus(self: *App, gained: bool) !void {
        const pane = self.activePane() orelse return;
        const rt = if (self.ghostty) |*r| r else return;
        if (!rt.terminalMode(pane.terminal, .focus_event)) return;
        var buf: [8]u8 = undefined;
        const bytes = rt.encodeFocus(if (gained) .gained else .lost, &buf) orelse return;
        mux_ops.sendText(self, bytes);
    }

    pub fn sendKey(self: *App, key: ghostty.Key, mods: u32, action: ghostty.KeyAction, text: ?[]const u8) !bool {
        const pane = self.activePane() orelse return false;
        if (action == .press and key == .escape and mods == ghostty.Mods.none and text == null) {
            mux_ops.sendText(self, "\x1b");
            return true;
        }

        const rt = if (self.ghostty) |*r| r else return false;
        var buf: [128]u8 = undefined;
        var derived_text_buf: [4]u8 = undefined;
        const effective_text = text orelse text_helpers.legacyPrintableKeyText(key, mods, &derived_text_buf);
        const consumed: u32 = if (effective_text != null and (mods & ghostty.Mods.shift) != 0) ghostty.Mods.shift else ghostty.Mods.none;
        if (rt.encodeKey(pane.key_encoder, pane.key_event, key, mods, action, consumed, if (effective_text) |t| text_helpers.firstCodepoint(t) else 0, effective_text, &buf)) |bytes| {
            mux_ops.sendText(self, bytes);
            return true;
        }

        if (action != .release and effective_text != null and (mods & ghostty.Mods.alt) != 0 and (mods & (ghostty.Mods.ctrl | ghostty.Mods.super)) == 0) {
            mux_ops.sendText(self, "\x1b");
            mux_ops.sendText(self, effective_text.?);
            return true;
        }

        return false;
    }

    pub const HitTestResult = struct {
        pane: *Pane,
        x: f32,
        y: f32,
    };

    pub fn paneInnerBounds(self: *const App, pane: *const Pane, bounds: PaneBounds) PaneBounds {
        const pad = self.panePadding(pane);
        const scrollbar_gutter = @min(bounds.width, scroll.paneScrollbarGutter(self, pane));
        const inset_left = @min(pad.left, bounds.width -| scrollbar_gutter);
        const inset_top = @min(pad.top, bounds.height);
        const available_w = @max(@as(u32, 1), bounds.width -| inset_left -| scrollbar_gutter);
        const available_h = @max(@as(u32, 1), bounds.height -| inset_top);
        // Preserve top/left padding, but let bottom/right padding shrink before
        // sacrificing a whole row/column. This minimizes visible dead bands when
        // the pane is just a few pixels short of the next cell.
        const cell_w = @max(1, self.cell_width_px);
        const cell_h = @max(1, self.cell_height_px);
        const snapped_w = (available_w / cell_w) * cell_w;
        const snapped_h = (available_h / cell_h) * cell_h;
        return .{
            .x = bounds.x + inset_left,
            .y = bounds.y + inset_top,
            .width = @max(1, snapped_w),
            .height = @max(1, snapped_h),
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
        self.pending_split_ratio = std.math.clamp(ratio, 0.05, 0.95);
        self.requestLayoutResize(false);
    }

    pub fn previewSplitNodeRatio(self: *App, node: *SplitNode, ratio: f32) void {
        node.ratio = std.math.clamp(ratio, 0.05, 0.95);
        self.pending_drag_layout_resize = true;
        self.signalWake();
    }

    pub fn hitTestScrollbar(self: *App, x: f32, y: f32) ?ScrollbarMetrics {
        return input.hitTestScrollbar(self, x, y);
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
        cmd_ipc.syncCommandTimingEnv(self);

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
                if (mux.activePane()) |active| runtime.registerCallbacks(active.terminal, terminal_callbacks.terminalCallbacks());
            }
            self.pending_renderer_refresh = self.config.backend == .sokol or self.config.backend == .webgpu;
            self.resize(self.config.window_width, self.config.window_height);
            self.requestLayoutResize(true);
        }

        const window_title = text_helpers.titleCString(self.activeTitle());
        sapp_set_window_title(&window_title);

        if (self.lua) |*lua| self.registerLuaCallbacks(lua);
        self.emitLuaBuiltInEvent("config:reloaded", .none);
        return true;
    }

    fn drainConfigWatchFlag(self: *App) void {
        if (self.config_watch_reload_flag.load(.acquire)) {
            self.config_watch_reload_flag.store(false, .release);
            std.log.info("config change detected by watcher", .{});
            _ = self.enqueueMouse(.reload_config);
        }
    }

    fn startConfigWatcher(self: *App) void {
        const has_watch_dirs = self.config.watch_dirs.items.len > 0;
        const has_config_file = self.base_config_path != null or self.override_config_path != null;
        if (!has_watch_dirs and !has_config_file) return;

        const watcher = ConfigWatcher.create(self.allocator, &self.config_watch_reload_flag) catch |err| {
            std.log.err("config watcher init failed: {s}", .{@errorName(err)});
            return;
        };
        for (self.config.watch_dirs.items) |dir| {
            watcher.watch(dir) catch |err| {
                std.log.warn("watch_dir add failed: {s} err={s}", .{ dir, @errorName(err) });
            };
        }
        if (self.base_config_path) |path| {
            watcher.watchFile(path) catch |err| {
                std.log.warn("base config watch failed: {s} err={s}", .{ path, @errorName(err) });
            };
        }
        if (self.override_config_path) |path| {
            watcher.watchFile(path) catch |err| {
                std.log.warn("override config watch failed: {s} err={s}", .{ path, @errorName(err) });
            };
        }
        self.config_watcher = watcher;
    }

    pub fn computeActiveLayout(self: *App, out: []LayoutLeaf) []LayoutLeaf {
        const bounds = self.activeLayoutBounds();
        if (self.mux) |*mux| {
            const tab = mux.activeTab() orelse return out[0..0];
            return tab.computeLayoutInBounds(bounds, out, self.cell_width_px, self.cell_height_px);
        }
        return out[0..0];
    }

    pub fn activeLayoutBounds(self: *App) PaneBounds {
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
        return mux_ops.workspaceCount(self, ) > 0;
    }

    pub fn tabCount(self: *App) usize {
        if (self.mux) |*mux| return mux.tabCount();
        return 0;
    }

    pub fn topBarTitle(self: *App, index: usize, hover_close: bool, out_buf: []u8) []const u8 {
        const fallback = mux_ops.tabTitle(self, index);
        if (self.lua) |*lua| {
            return lua.resolveTopBarTitle(
                index,
                index == mux_ops.activeTabIndex(self, ),
                self.hovered_tab_index != null and self.hovered_tab_index.? == index,
                hover_close,
                fallback,
                out_buf,
            ).text;
        }
        return fallback;
    }

    pub fn topBarTitleSegment(self: *App, index: usize, hover_close: bool, out_buf: []u8) bar.Segment {
        const fallback = mux_ops.tabTitle(self, index);
        if (self.lua) |*lua| {
            return lua.resolveTopBarTitle(
                index,
                index == mux_ops.activeTabIndex(self, ),
                self.hovered_tab_index != null and self.hovered_tab_index.? == index,
                hover_close,
                fallback,
                out_buf,
            );
        }
        return .{ .text = fallback };
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
            return lua.resolveTopBarStatus(side, segments, text_buf, mux_ops.activeTabIndex(self, ), self.tabCount());
        }
        return segments[0..0];
    }

    pub fn updateTopBarHover(self: *App, mouse_x: f32, mouse_y: f32, window_width: f32, close_w: f32) void {
        _ = mouse_x;
        _ = mouse_y;
        _ = window_width;
        _ = close_w;
        self.hovered_tab_index = null;
        self.hovered_close_tab_index = null;
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
        if (self.pending_post_split_snap) |pending| {
            if (self.isSplitNodeValid(pending.node)) {
                const mux = if (self.mux) |*m| m else null;
                if (mux) |*value| {
                    if (value.*.activeSplitRoot()) |root| {
                        const bounds = self.activeLayoutBounds();
                        if (mux_mod.boundsForNode(root, pending.node, bounds, self.cell_width_px, self.cell_height_px)) |node_bounds| {
                            const corrected_new_ratio = mux_ops.snapSplitRatio(self, pending.ratio, pending.node.direction, .{ .x = 0, .y = 0, .width = node_bounds.width, .height = node_bounds.height });
                            std.log.info("split-trace post dir={s} requested={d:.4} corrected={d:.4} node_bounds={d}x{d}", .{
                                @tagName(pending.direction),
                                pending.ratio,
                                corrected_new_ratio,
                                node_bounds.width,
                                node_bounds.height,
                            });
                            pending.node.ratio = std.math.clamp(1.0 - corrected_new_ratio, 0.05, 0.95);
                        }
                    }
                }
            }
            self.pending_post_split_snap = null;
        }
        if (self.ghostty) |*runtime| {
            std.log.info("flushPendingLayoutResize resizeAllPanes window={d}x{d}", .{ self.config.window_width, self.config.window_height });
            self.resizeAllPanes(runtime, self.config.window_width, self.config.window_height, recreate_render_helpers, false, skip_unchanged_pty);
        }
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
                const active_screen_before = pane.active_screen;
                // Let the active pane drain a larger PTY backlog per tick so VT
                // parsing tracks the producer more like Ghostty's dedicated read
                // path instead of spreading one burst across many frame ticks.
                const pty_read_loops: usize = if (pane_is_active) 64 else 2;
                const pty_read_bytes: usize = if (pane_is_active) 1024 * 1024 else 32 * 1024;
                pane.pollPty(runtime, pty_read_loops, pty_read_bytes, self.config.debug_overlay) catch |err| {
                    std.log.err("pane pollPty error: {s}", .{@errorName(err)});
                };
                if (pane.active_screen != active_screen_before) {
                    std.log.info("app: pane screen changed pane={x} {d}->{d}, resizing layout", .{
                        @intFromPtr(pane),
                        active_screen_before,
                        pane.active_screen,
                    });
                    if (pane.active_screen == @intFromEnum(ghostty.TerminalScreen.alternate)) {
                        pane.pending_alt_screen_nudge = true;
                        pane.alt_screen_nudge_quiet_ticks = 0;
                    } else {
                        pane.pending_alt_screen_nudge = false;
                        pane.alt_screen_nudge_quiet_ticks = 0;
                    }
                    self.requestLayoutResize(false);
                }
                const had_pty_output_this_tick = pane.pty_received_data;
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
                if (pane.bell_dirty) {
                    pane.bell_dirty = false;
                    const now_bell_ns = std.time.nanoTimestamp();
                    if (self.config.bell.visual) {
                        pane.bell_active = true;
                        pane.bell_started_at_ns = now_bell_ns;
                    }
                    const is_focused = (self.activePane() == pane);
                    if (!is_focused) pane.has_bell_attention = true;
                    self.last_visual_activity_ns = now_bell_ns;
                    // Tab labels may render an attention marker, so force the
                    // top bar to re-layout on the next frame.
                    self.topbar_cache_dirty = true;
                    self.emitLuaBuiltInEvent("term:bell", .{ .pane_id = @intFromPtr(pane) });
                }
                if (pane.bell_active) {
                    const now_bell_ns = std.time.nanoTimestamp();
                    const duration_ns: i128 = @as(i128, @intCast(self.config.bell.visual_duration_ms)) * std.time.ns_per_ms;
                    if (now_bell_ns - pane.bell_started_at_ns >= duration_ns) {
                        pane.bell_active = false;
                    } else {
                        // hasVisualActivity() already wakes the render loop for
                        // every frame while bell_active is set, and the flash
                        // overlay is drawn on top of the (possibly cached) pane
                        // content, so we don't need to invalidate the pane
                        // render cache here.
                        self.last_visual_activity_ns = now_bell_ns;
                    }
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
                        copy_mode.refreshCopyModeVisibleSlice(self, pane) catch {};
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
                        _ = scroll.refreshPaneScrollbar(self, runtime, pane);
                        if (self.config.debug_overlay) total_scrollbar_ns += std.time.nanoTimestamp() - scrollbar_start_ns;
                    if (self.hovered_hyperlink != null and self.hovered_hyperlink.?.pane == pane) {
                        self.hover_probe_dirty = true;
                    }
                } else if (pane.last_render_state_update_ns != 0) {
                    if (next_idle_render_poll_ns == 0 or pane_idle_deadline_ns < next_idle_render_poll_ns) {
                        next_idle_render_poll_ns = pane_idle_deadline_ns;
                    }
                }
                if (pane.pending_alt_screen_nudge) {
                    if (pane.active_screen != @intFromEnum(ghostty.TerminalScreen.alternate)) {
                        pane.pending_alt_screen_nudge = false;
                        pane.alt_screen_nudge_quiet_ticks = 0;
                    } else if (self.pending_resize or self.pending_layout_resize or self.pending_drag_layout_resize) {
                        pane.alt_screen_nudge_quiet_ticks = 0;
                        self.last_visual_activity_ns = now_ns;
                    } else if (had_pty_output_this_tick) {
                        pane.alt_screen_nudge_quiet_ticks = 0;
                        self.last_visual_activity_ns = now_ns;
                    } else {
                        pane.alt_screen_nudge_quiet_ticks +|= 1;
                        if (pane.alt_screen_nudge_quiet_ticks >= 3) {
                            std.log.info("app: pane alt-screen repaint nudge pane={x} rows={d} cols={d}", .{
                                @intFromPtr(pane),
                                pane.rows,
                                pane.cols,
                            });
                            pane.nudgeResize(runtime, self.cell_width_px, self.cell_height_px);
                            pane.pending_alt_screen_nudge = false;
                            pane.alt_screen_nudge_quiet_ticks = 0;
                            self.last_visual_activity_ns = now_ns;
                        } else {
                            self.last_visual_activity_ns = now_ns;
                        }
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
                    mux_ops.quitOnWorkspaceRemoved(self, mux, "app: last pane closed, quitting");
                    return;
                }
                mux_ops.emitWorkspaceClosedIfRemoved(self, mux);
                // Re-register callbacks for the (possibly new) active pane so
                // write/size/title events are routed correctly.
                if (mux.activePane()) |active| {
                    runtime.registerCallbacks(active.terminal, terminal_callbacks.terminalCallbacks());
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
            const leaves = tab.computeLayoutInBounds(bounds, &layout_buf, self.cell_width_px, self.cell_height_px);
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
                    const actual_left = inner.x - leaf.bounds.x;
                    const actual_top = inner.y - leaf.bounds.y;
                    const actual_right = leaf.bounds.width - actual_left - inner.width;
                    const actual_bottom = leaf.bounds.height - actual_top - inner.height;
                    if (self.debug_split_trace_frames > 0) {
                        std.log.info("split-trace leaf pane={x} outer={d}x{d} inner={d}x{d} insets=t{d} r{d} b{d} l{d} rows={d} cols={d}", .{
                            @intFromPtr(leaf.pane),
                            leaf.bounds.width,
                            leaf.bounds.height,
                            inner.width,
                            inner.height,
                            actual_top,
                            actual_right,
                            actual_bottom,
                            actual_left,
                            rows,
                            cols,
                        });
                    }
                    leaf.pane.setMouseSize(
                        runtime,
                        leaf.bounds.width,
                        leaf.bounds.height,
                        self.cell_width_px,
                        self.cell_height_px,
                        actual_top,
                        actual_bottom,
                        actual_left,
                        actual_right,
                    );
                    leaf.pane.render_state_ready = true;
                }
            } else {
                // Fallback: no split tree yet, resize all panes in this tab to
                // the full window size minus the tab bar.
                if (pixel_width == 0 or pane_h == 0) return;
                var panes = tab.paneIterator();
                while (panes.next()) |pane| {
                    const outer = PaneBounds{ .x = left_inset, .y = tbh, .width = layout_width, .height = pane_h };
                    const inner = self.paneInnerBounds(pane, outer);
                    const inner_width = inner.width;
                    const inner_height = inner.height;
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
                    const actual_left = inner.x - outer.x;
                    const actual_top = inner.y - outer.y;
                    const actual_right = outer.width - actual_left - inner.width;
                    const actual_bottom = outer.height - actual_top - inner.height;
                    pane.setMouseSize(
                        runtime,
                        layout_width,
                        pane_h,
                        self.cell_width_px,
                        self.cell_height_px,
                        actual_top,
                        actual_bottom,
                        actual_left,
                        actual_right,
                    );
                    pane.render_state_ready = true;
                }
            }
            if (self.debug_split_trace_frames > 0) self.debug_split_trace_frames -|= 1;
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

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
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
