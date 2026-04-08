const std = @import("std");
const c = @import("sokol_c");
const Config = @import("config.zig").Config;
const Backend = @import("render/backend.zig").Backend;
const FrameSnapshot = @import("render/debug_backend.zig").FrameSnapshot;
const LuaRuntime = @import("lua/luajit.zig").Runtime;
const AppCallbacks = @import("lua/luajit.zig").AppCallbacks;
const GhosttyRuntime = @import("term/ghostty.zig").Runtime;
const ghostty = @import("term/ghostty.zig");
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
const platform = @import("platform.zig");
const bar = @import("ui/bar.zig");
const selection = @import("selection.zig");

const CLIPBOARD_EVENT_MAX = 8192;

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
    /// Switch to a tab index and then close it (close_tab button click).
    switch_and_close_tab: usize,
    new_tab,
    close_tab,
    close_pane,
    next_tab,
    prev_tab,
    new_workspace,
    next_workspace,
    prev_workspace,
    split_pane: struct {
        direction: SplitDirection,
        ratio: f32,
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
    open_hyperlink: struct {
        pane: *Pane,
        point: selection.CellPoint,
    },
};

var write_bridge: ?*App = null;
var size_bridge: ?*App = null;
var attrs_bridge: ?*App = null;
var title_bridge: ?*App = null;

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
    lua: ?LuaRuntime = null,
    ghostty: ?GhosttyRuntime = null,
    renderer: ?Backend = null,
    mux: ?Mux = null,
    loaded_config_path: ?[]u8 = null,
    frame_count: usize = 0,
    logged_first_render_update: bool = false,
    cell_width_px: u32 = 8,
    cell_height_px: u32 = 16,
    pending_resize: bool = false,
    pending_width: u32 = 0,
    pending_height: u32 = 0,
    /// Set when a split has just been performed; causes tick() to re-layout
    /// all panes on the next frame (safe from the frame callback thread).
    pending_layout_resize: bool = false,
    pending_layout_recreate_render_helpers: bool = false,
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
    selection_pane: ?*Pane = null,
    selection_anchor: ?selection.CellPoint = null,
    selection_head: ?selection.CellPoint = null,
    selection_drag_active: bool = false,
    selection_generation: u64 = 0,
    hovered_hyperlink: ?HoveredHyperlink = null,

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
        self.mouse_queue[self.mouse_queue_tail] = ev;
        @atomicStore(usize, &self.mouse_queue_tail, next_tail, .release);
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
        @memcpy(ev.char.bytes[0..bytes.len], bytes);
        return self.enqueueMouse(ev);
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
                .switch_and_close_tab => |idx| {
                    self.switchTab(idx);
                    self.closeTab();
                },
                .new_tab => {
                    self.newTab();
                },
                .close_tab => {
                    self.closeTab();
                },
                .close_pane => {
                    self.closeActivePane();
                },
                .next_tab => {
                    self.nextTab();
                },
                .prev_tab => {
                    self.prevTab();
                },
                .new_workspace => {
                    self.newWorkspace();
                },
                .next_workspace => {
                    self.nextWorkspace();
                },
                .prev_workspace => {
                    self.prevWorkspace();
                },
                .split_pane => |split| {
                    self.splitPane(split.direction, split.ratio);
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
                },
                .key => |k| {
                    var text: ?[]const u8 = null;
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

                    if (!(self.sendKey(k.key, k.mods, k.action, text) catch false)) {
                        if (text) |bytes| self.sendText(bytes);
                    }
                },
                .char => |ch| {
                    if (ch.len > 0) self.sendText(ch.bytes[0..ch.len]);
                },
                .selection_begin => |sel| {
                    self.selectionBegin(sel.pane, sel.point, sel.extend);
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
                    if (self.hasPane(scroll_ev.pane)) self.scrollPaneViewport(scroll_ev.pane, scroll_ev.delta);
                },
                .scroll_pane_target => |scroll_ev| {
                    if (self.hasPane(scroll_ev.pane)) self.scrollPaneViewportToRow(scroll_ev.pane, scroll_ev.top_row);
                },
                .scroll_active_delta => |delta| {
                    self.scrollActiveViewport(delta);
                },
                .scroll_active_page => |pages| {
                    self.scrollActiveViewportPage(pages);
                },
                .scroll_active_top => {
                    self.scrollActiveViewportTop();
                },
                .scroll_active_bottom => {
                    self.scrollActiveViewportBottom();
                },
                .open_hyperlink => |open_ev| {
                    if (self.hasPane(open_ev.pane)) self.openHyperlinkAt(open_ev.pane, open_ev.point);
                },
            }

            @atomicStore(usize, &self.mouse_queue_head, (head + advance) % cap, .release);
        }
    }

    pub fn init(allocator: std.mem.Allocator) App {
        return .{
            .allocator = allocator,
            .config = Config.init(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        write_bridge = null;
        size_bridge = null;
        attrs_bridge = null;
        title_bridge = null;

        if (self.renderer) |*renderer| {
            renderer.deinit();
            self.renderer = null;
        }

        if (self.ghostty) |*runtime| {
            if (self.mux) |*mux| {
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

        if (self.loaded_config_path) |path| {
            self.allocator.free(path);
            self.loaded_config_path = null;
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

    pub fn bootstrap(self: *App, config_override: ?[]const u8) !void {
        self.loaded_config_path = try self.resolveConfigPath(config_override);

        self.tryInitLua();

        var runtime = try GhosttyRuntime.init(self.allocator, null);
        errdefer runtime.deinit();

        var mux = Mux.init(self.allocator);
        errdefer mux.deinit(&runtime);

        // Set bridge globals before bootstrapSingle so the callbacks are valid
        // the moment ghostty can first invoke them (during resizeTerminal inside
        // bootstrap).
        write_bridge = self;
        size_bridge = self;
        attrs_bridge = self;
        title_bridge = self;
        const cbs = terminalCallbacks();
        try mux.bootstrapSingle(&runtime, cbs, self.config, self.cell_width_px, self.cell_height_px, self.config.window_width, self.config.window_height);

        self.ghostty = runtime;
        self.mux = mux;
        self.renderer = Backend.init(self.allocator, self.config);

        // Register app action callbacks so Lua can call split_pane etc.
        if (self.lua) |*lua| {
            lua.registerAppCallbacks(.{
                .app = self,
                .split_pane = luaSplitPaneCallback,
                .new_tab = luaNewTabCallback,
                .close_tab = luaCloseTabCallback,
                .close_pane = luaClosePaneCallback,
                .next_tab = luaNextTabCallback,
                .prev_tab = luaPrevTabCallback,
                .new_workspace = luaNewWorkspaceCallback,
                .next_workspace = luaNextWorkspaceCallback,
                .prev_workspace = luaPrevWorkspaceCallback,
                .switch_workspace = luaSwitchWorkspaceCallback,
                .focus_pane = luaFocusPaneCallback,
                .resize_pane = luaResizePaneCallback,
                .switch_tab = luaSwitchTabCallback,
                .set_workspace_name = luaSetWorkspaceNameCallback,
                .set_tab_title = luaSetTabTitleCallback,
                .get_tab_count = luaGetTabCountCallback,
                .get_active_tab_index = luaGetActiveTabIndexCallback,
                .get_workspace_count = luaGetWorkspaceCountCallback,
                .get_active_workspace_index = luaGetActiveWorkspaceIndexCallback,
                .get_workspace_name = luaGetWorkspaceNameCallback,
                .is_leader_active = luaIsLeaderActiveCallback,
                .copy_selection = luaCopySelectionCallback,
                .paste_clipboard = luaPasteClipboardCallback,
                .scroll_active = luaScrollActiveCallback,
                .scroll_active_page = luaScrollActivePageCallback,
                .scroll_active_top = luaScrollActiveTopCallback,
                .scroll_active_bottom = luaScrollActiveBottomCallback,
            });
        }

        try self.tick();
    }

    pub fn fireGuiReady(self: *App) void {
        if (self.lua) |*lua| lua.fireGuiReady();
    }

    fn tryInitLua(self: *App) void {
        var lua = LuaRuntime.init(self.allocator, &self.config) catch |err| {
            std.log.warn("LuaJIT unavailable, continuing without scripting: {s}", .{@errorName(err)});
            return;
        };

        const core_lua = @embedFile("lua/core.lua");
        lua.runString(core_lua) catch |err| {
            std.log.warn("failed to bootstrap lua core, scripting may be broken: {s}", .{@errorName(err)});
        };

        if (self.loaded_config_path) |path| {
            lua.runFile(path) catch |err| {
                std.log.warn("config load failed, continuing with compiled defaults: {s}", .{@errorName(err)});
                lua.deinit();
                return;
            };
        }

        self.lua = lua;
    }

    pub fn tick(self: *App) !void {
        // Clean up dead panes BEFORE draining the mouse queue so that mouse
        // events never dispatch to panes whose PTY has already exited.  This
        // also invalidates any cached SplitNode pointers (g_drag_node,
        // pending_split_ratio_node) that referenced freed tree nodes, which
        // the validation in handleMouseMove / flushPendingLayoutResize will
        // detect and discard.
        if (self.ghostty) |*runtime| self.cleanupDeadPanes(runtime);
        self.pruneSelectionIfInvalid();
        self.drainMouseQueue();
        self.flushPendingResize();
        self.flushPendingLayoutResize();
        if (self.ghostty) |*runtime| try self.tickPanes(runtime);
        self.updateHoveredHyperlink();
        self.maybeRunStartupCommand();
        if (!self.logged_first_render_update) self.logged_first_render_update = true;
        self.frame_count += 1;
    }

    fn recordPointerState(self: *App, x: f32, y: f32, mods: u32) void {
        self.pointer_x = x;
        self.pointer_y = y;
        self.pointer_mods = mods;
    }

    pub fn captureSnapshot(self: *App) ?FrameSnapshot {
        if (self.renderer) |*renderer| {
            if (self.ghostty) |*runtime| {
                if (self.activePane()) |pane| {
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
        if (self.loaded_config_path) |path| std.log.info("config={s}", .{path});
    }

    pub fn sendText(self: *App, text: []const u8) void {
        const pane = self.activePane() orelse return;
        self.scrollActiveViewportBottom();
        pane.sendText(text);
    }

    pub fn setCellSize(self: *App, cell_w: u32, cell_h: u32) void {
        self.cell_width_px = @max(1, cell_w);
        self.cell_height_px = @max(1, cell_h);
        if (self.ghostty) |*runtime| self.resizeAllPanes(runtime, self.config.window_width, self.config.window_height, true, false);
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
        const horizontal_reserved = self.config.terminal_padding.horizontal() + self.config.scrollbar.gutterWidth();
        const inner_width = if (pixel_width > horizontal_reserved) pixel_width - horizontal_reserved else 1;
        const content_height = if (pixel_height > tbh) pixel_height - tbh else 1;
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
            self.resizeAllPanes(runtime, pixel_width, pixel_height, !grid_unchanged, grid_unchanged);
        }

        _ = size_unchanged;
        std.log.info("app: resized window={d}x{d} grid={d}x{d} cell={d}x{d}", .{ pixel_width, pixel_height, self.config.cols, self.config.rows, self.cell_width_px, self.cell_height_px });
    }

    pub fn requestResize(self: *App, pixel_width: u32, pixel_height: u32) void {
        self.pending_width = pixel_width;
        self.pending_height = pixel_height;
        self.pending_resize = true;
    }

    fn requestLayoutResize(self: *App, recreate_render_helpers: bool) void {
        self.pending_layout_resize = true;
        self.pending_layout_recreate_render_helpers = self.pending_layout_recreate_render_helpers or recreate_render_helpers;
        self.layout_generation +%= 1;
        if (self.layout_generation == 0) self.layout_generation = 1;
    }

    fn invalidateFocusedPaneCache(self: *App, previous: ?*Pane, current: ?*Pane) void {
        _ = self;
        if (previous == current) return;
        if (previous) |pane| pane.render_dirty = .full;
        if (current) |pane| pane.render_dirty = .full;
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
            self.sendText(text);
            return;
        };
        if (rt.terminalMode(pane.terminal, .bracketed_paste)) {
            self.sendText("\x1b[200~");
            self.sendText(text);
            self.sendText("\x1b[201~");
            return;
        }
        self.sendText(text);
    }

    pub fn selectionRange(self: *const App, pane: *const Pane) ?selection.Range {
        if (self.selection_pane != pane) return null;
        const anchor = self.selection_anchor orelse return null;
        const head = self.selection_head orelse return null;
        return selection.normalize(anchor, head);
    }

    pub fn selectionGeneration(self: *const App) u64 {
        return self.selection_generation;
    }

    pub fn selectionBegin(self: *App, pane: *Pane, point: selection.CellPoint, extend: bool) void {
        if (!self.hasPane(pane)) return;
        if (self.mux) |*mux| {
            const previous = mux.activePane();
            mux.setActivePane(pane);
            self.invalidateFocusedPaneCache(previous, pane);
        }
        const previous_selection_pane = self.selection_pane;
        if (!extend or self.selection_pane != pane or self.selection_anchor == null) {
            self.selection_pane = pane;
            self.selection_anchor = point;
        }
        self.selection_head = point;
        self.selection_drag_active = true;
        if (previous_selection_pane) |prev| {
            if (prev != pane) prev.render_dirty = .full;
        }
        pane.render_dirty = .full;
        self.selection_generation +%= 1;
    }

    pub fn selectionUpdate(self: *App, pane: *Pane, point: selection.CellPoint) void {
        if (!self.selection_drag_active or self.selection_pane != pane or !self.hasPane(pane)) return;
        if (self.selection_head) |head| {
            if (head.row == point.row and head.col == point.col) return;
        }
        self.selection_head = point;
        pane.render_dirty = .full;
        self.selection_generation +%= 1;
    }

    pub fn selectionEnd(self: *App) void {
        self.selection_drag_active = false;
    }

    pub fn clearSelection(self: *App) void {
        const pane = self.selection_pane;
        self.selection_pane = null;
        self.selection_anchor = null;
        self.selection_head = null;
        self.selection_drag_active = false;
        if (pane) |p| p.render_dirty = .full;
        self.selection_generation +%= 1;
    }

    pub fn hasSelection(self: *const App) bool {
        if (self.selection_pane == null) return false;
        return self.selectionRange(self.selection_pane.?) != null;
    }

    pub fn copySelectionToClipboard(self: *App) !void {
        const pane = self.selection_pane orelse return;
        if (!self.hasPane(pane)) {
            self.pruneSelectionIfInvalid();
            return;
        }
        const range = self.selectionRange(pane) orelse return;
        var text_buf: [CLIPBOARD_EVENT_MAX]u8 = undefined;
        const text = self.captureSelectionText(pane, range, text_buf[0 .. text_buf.len - 1]) orelse return;
        if (text.len == 0) return;
        text_buf[text.len] = 0;
        c.sapp_set_clipboard_string(@ptrCast(text_buf[0..text.len :0].ptr));
    }

    pub fn pasteClipboard(self: *App) !void {
        const clipboard = c.sapp_get_clipboard_string();
        const text = std.mem.span(clipboard);
        if (text.len == 0) return;
        try self.sendPaste(text);
    }

    fn captureSelectionText(self: *App, pane: *Pane, range: selection.Range, out: []u8) ?[]const u8 {
        const runtime = if (self.ghostty) |*rt| rt else return null;
        if (self.selection_pane != pane) return null;
        if (!runtime.populateRowIterator(pane.render_state, &pane.row_iterator)) return null;

        var writer = std.io.fixedBufferStream(out);
        var row_index: usize = 0;
        while (runtime.nextRow(pane.row_iterator) and row_index <= range.end.row) : (row_index += 1) {
            if (!selection.rowIntersects(range, row_index)) continue;
            if (!runtime.populateRowCells(pane.row_iterator, &pane.row_cells)) break;

            var row_text: [4096]u8 = undefined;
            var row_len: usize = 0;
            var col_index: usize = 0;
            while (runtime.nextCell(pane.row_cells)) : (col_index += 1) {
                if (!selection.cellSelected(range, row_index, col_index)) continue;
                appendCellText(runtime, pane.row_cells, row_text[0..], &row_len);
            }
            while (row_len > 0 and row_text[row_len - 1] == ' ') row_len -= 1;
            writer.writer().writeAll(row_text[0..row_len]) catch break;
            if (row_index < range.end.row) writer.writer().writeByte('\n') catch break;
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
            const inner = self.paneInnerBounds(leaf.bounds);
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

    fn hyperlinkTokenAt(self: *App, pane: *Pane, point: selection.CellPoint, out: []u8) ?HyperlinkToken {
        const runtime = if (self.ghostty) |*rt| rt else return null;
        if (!runtime.populateRowIterator(pane.render_state, &pane.row_iterator)) return null;
        var row_index: usize = 0;
        while (runtime.nextRow(pane.row_iterator)) : (row_index += 1) {
            if (row_index != point.row) continue;
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
                @memcpy(out[0..8], "https://");
                @memcpy(out[8 .. 8 + token.len], token);
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
        platform.openExternal(token.open_text) catch |err| {
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

    pub fn hasPane(self: *App, needle: *const Pane) bool {
        if (self.mux) |*mux| {
            var panes = mux.paneIterator();
            while (panes.next()) |pane| {
                if (pane == needle) return true;
            }
        }
        return false;
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

    fn paneInnerBounds(self: *const App, bounds: PaneBounds) PaneBounds {
        const pad = self.config.terminal_padding;
        const scrollbar_gutter = @min(bounds.width, self.config.scrollbar.gutterWidth());
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
        for (leaves) |leaf| {
            const inner = self.paneInnerBounds(leaf.bounds);
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
        const mux = if (self.mux) |*m| m else return null;
        const tab = mux.activeTab() orelse return null;
        const root = tab.root_split orelse return null;
        const tbh = self.tabBarHeight();
        const h = if (self.config.window_height > tbh) self.config.window_height - tbh else 1;
        const bounds = PaneBounds{
            .x = 0,
            .y = tbh,
            .width = self.config.window_width,
            .height = h,
        };
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
    }

    fn encodeMouseForPane(self: *App, pane: *Pane, action: ghostty.MouseAction, button: ?ghostty.MouseButton, x: f32, y: f32, mods: u32) !bool {
        std.log.info("encodeMouseForPane: action={s} x={d:.1} y={d:.1} render_state_ready={} mouse_tracking={d}", .{ @tagName(action), x, y, pane.render_state_ready, pane.last_mouse_tracking });

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
                self.invalidateFocusedPaneCache(was_active, hit.pane);
            }
        }
        return try self.encodeMouseForPane(hit.pane, action, button, hit.x, hit.y, mods);
    }

    fn refreshPaneScrollbar(self: *App, runtime: *GhosttyRuntime, pane: *Pane) ghostty.TerminalScrollbar {
        if (runtime.terminalScrollbar(pane.terminal)) |scrollbar| {
            pane.scrollbar_total = scrollbar.total;
            pane.scrollbar_offset = scrollbar.offset;
            pane.scrollbar_len = scrollbar.len;
            return scrollbar;
        }
        pane.scrollbar_total = @as(u64, pane.rows) + @as(u64, self.config.scrollback);
        pane.scrollbar_offset = 0;
        pane.scrollbar_len = @max(@as(u64, 1), pane.rows);
        return pane.scrollbar();
    }

    fn scrollbarMaxTopRow(scrollbar: ghostty.TerminalScrollbar) u64 {
        return if (scrollbar.total > scrollbar.len) scrollbar.total - scrollbar.len else 0;
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
    }

    fn scrollPaneViewportToRow(self: *App, pane: *Pane, top_row: u64) void {
        const runtime = if (self.ghostty) |*rt| rt else return;
        const scrollbar = self.refreshPaneScrollbar(runtime, pane);
        const max_top = scrollbarMaxTopRow(scrollbar);
        const clamped_target = @min(top_row, max_top);
        const current_top = @min(scrollbar.offset, max_top);
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

    fn paneScrollbarMetrics(self: *App, pane: *Pane, outer_bounds: PaneBounds) ?ScrollbarMetrics {
        if (!self.config.scrollbar.enabled) return null;
        const gutter = self.config.scrollbar.gutterWidth();
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
        const ui_offset = @min(scrollbar.offset, max_top);
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
            .offset = scrollbar.offset,
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
            const pane_h = if (self.config.window_height > tbh) self.config.window_height - tbh else 1;
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
        for (leaves) |leaf| {
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
        const runtime = if (self.ghostty) |*rt| rt else return;
        const scrollbar = self.refreshPaneScrollbar(runtime, hit.pane);
        const max_top = scrollbarMaxTopRow(scrollbar);
        const in_scrollback = scrollbar.offset < max_top;
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

    pub fn newTab(self: *App) void {
        var mux = if (self.mux) |*value| value else return;
        const runtime = if (self.ghostty) |*value| value else return;
        const cbs = terminalCallbacks();
        mux.newTab(runtime, cbs, self.config, self.cell_width_px, self.cell_height_px, self.config.window_width, self.config.window_height) catch |err| {
            std.log.err("app: newTab failed: {s}", .{@errorName(err)});
            return;
        };
        self.requestLayoutResize(false);
        std.log.info("app: created new tab", .{});
    }

    pub fn closeTab(self: *App) void {
        var mux = if (self.mux) |*value| value else return;
        const runtime = if (self.ghostty) |*value| value else return;
        const should_quit = mux.closeTab(runtime);
        if (should_quit) {
            std.log.info("app: last tab closed, quitting", .{});
            self.pending_quit = true;
            return;
        }
        // Re-register callbacks for the new active pane after tab switch.
        if (mux.activePane()) |active| {
            runtime.registerCallbacks(active.terminal, terminalCallbacks());
        }
        self.requestLayoutResize(false);
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
        // Re-register callbacks for the new active pane.
        if (mux.activePane()) |active| {
            runtime.registerCallbacks(active.terminal, terminalCallbacks());
        }
        self.requestLayoutResize(false);
        std.log.info("app: active pane closed via close_pane", .{});
    }

    pub fn nextTab(self: *App) void {
        if (self.mux) |*mux| mux.nextTab();
        self.requestLayoutResize(false);
    }

    pub fn prevTab(self: *App) void {
        if (self.mux) |*mux| mux.prevTab();
        self.requestLayoutResize(false);
    }

    pub fn newWorkspace(self: *App) void {
        var mux = if (self.mux) |*value| value else return;
        const runtime = if (self.ghostty) |*value| value else return;
        const cbs = terminalCallbacks();
        mux.newWorkspace(runtime, cbs, self.config, self.cell_width_px, self.cell_height_px, self.config.window_width, self.config.window_height) catch |err| {
            std.log.err("app: newWorkspace failed: {s}", .{@errorName(err)});
            return;
        };
        self.requestLayoutResize(false);
        std.log.info("app: created new workspace", .{});
    }

    pub fn nextWorkspace(self: *App) void {
        if (self.mux) |*mux| {
            mux.nextWorkspace();
            if (self.ghostty) |*runtime| {
                if (mux.activePane()) |active| runtime.registerCallbacks(active.terminal, terminalCallbacks());
            }
            self.requestLayoutResize(false);
        }
    }

    pub fn prevWorkspace(self: *App) void {
        if (self.mux) |*mux| {
            mux.prevWorkspace();
            if (self.ghostty) |*runtime| {
                if (mux.activePane()) |active| runtime.registerCallbacks(active.terminal, terminalCallbacks());
            }
            self.requestLayoutResize(false);
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
            mux.switchWorkspace(index);
            if (self.ghostty) |*runtime| {
                if (mux.activePane()) |active| runtime.registerCallbacks(active.terminal, terminalCallbacks());
            }
            self.requestLayoutResize(false);
        }
    }

    pub fn splitPane(self: *App, direction: SplitDirection, ratio: f32) void {
        var mux = if (self.mux) |*value| value else return;
        const runtime = if (self.ghostty) |*value| value else return;
        const cbs = terminalCallbacks();
        mux.splitActivePane(runtime, cbs, self.config, self.cell_width_px, self.cell_height_px, self.config.window_width, self.config.window_height, direction, ratio) catch |err| {
            std.log.err("app: splitPane failed: {s}", .{@errorName(err)});
            return;
        };
        // Schedule a layout resize for the next tick() (frame callback thread),
        // rather than calling ghostty_terminal_resize from the event callback thread.
        self.requestLayoutResize(false);
        std.log.info("app: pane split done direction={s}", .{@tagName(direction)});
    }

    pub fn resizePane(self: *App, direction: SplitDirection, delta: f32) void {
        if (self.mux) |*mux| {
            mux.resizeActivePane(direction, delta);
            self.requestLayoutResize(false);
        }
    }

    pub fn focusPane(self: *App, direction: FocusDirection) void {
        if (self.mux) |*mux| {
            const previous = mux.activePane();
            mux.focusPaneInDirection(direction, self.config.window_width, self.config.window_height);
            self.invalidateFocusedPaneCache(previous, mux.activePane());
        }
    }

    pub fn computeActiveLayout(self: *App, out: []LayoutLeaf) []LayoutLeaf {
        const tbh = self.tabBarHeight();
        const h = if (self.config.window_height > tbh) self.config.window_height - tbh else 1;
        if (self.mux) |*mux| {
            const tab = mux.activeTab() orelse return out[0..0];
            var written: usize = 0;
            const root = tab.root_split orelse return out[0..0];
            const bounds = PaneBounds{
                .x = 0,
                .y = tbh,
                .width = self.config.window_width,
                .height = h,
            };
            layoutSplitTree(root, bounds, out, &written);
            return out[0..written];
        }
        return out[0..0];
    }

    pub fn activeTitle(self: *App) []const u8 {
        if (self.activePane()) |pane| return pane.title;
        return self.config.windowTitle();
    }

    /// Height in pixels of the shared top bar. 0 when hidden.
    pub fn tabBarHeight(self: *App) u32 {
        if (!self.config.top_bar_show) return 0;
        const count = if (self.mux) |*mux| mux.tabCount() else 0;
        if (count < 2 and !self.config.top_bar_show_when_single_tab) return 0;
        if (self.config.top_bar_height > 0) return self.config.top_bar_height;
        return (self.cell_height_px * 3 / 2 + 1) & ~@as(u32, 1);
    }

    pub fn shouldDrawTopBarTabs(self: *App) bool {
        return self.config.top_bar_draw_tabs and self.tabCount() > 0;
    }

    pub fn shouldDrawWorkspaceSwitcher(self: *App) bool {
        return self.workspaceCount() > 0;
    }

    pub fn shouldDrawTopBarStatus(self: *App) bool {
        return self.config.top_bar_draw_status;
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

    pub fn topBarTitle(self: *App, index: usize, hover_close: bool, out_buf: []u8) []const u8 {
        const fallback = self.tabTitle(index);
        if (self.lua) |*lua| {
            return lua.resolveTopBarTitle(index, index == self.activeTabIndex(), hover_close, fallback, out_buf).text;
        }
        return fallback;
    }

    pub fn topBarTitleSegment(self: *App, index: usize, hover_close: bool, out_buf: []u8) bar.Segment {
        const fallback = self.tabTitle(index);
        if (self.lua) |*lua| {
            return lua.resolveTopBarTitle(index, index == self.activeTabIndex(), hover_close, fallback, out_buf);
        }
        return .{ .text = fallback };
    }

    pub fn workspaceTitle(self: *App, index: usize, out_buf: []u8) []const u8 {
        const fallback = if (self.mux) |*mux| blk: {
            if (index < mux.workspaces.items.len) break :blk mux.workspaces.items[index].title(out_buf);
            break :blk std.fmt.bufPrint(out_buf, "ws {d}", .{index + 1}) catch return "ws";
        } else std.fmt.bufPrint(out_buf, "ws {d}", .{index + 1}) catch return "ws";
        if (self.lua) |*lua| {
            return lua.resolveWorkspaceTitle(index, index == self.activeWorkspaceIndex(), self.activeWorkspaceIndex(), self.workspaceCount(), fallback, out_buf).text;
        }
        return fallback;
    }

    pub fn workspaceTitleSegment(self: *App, index: usize, out_buf: []u8) bar.Segment {
        const fallback = self.workspaceName(index, out_buf);
        if (self.lua) |*lua| {
            return lua.resolveWorkspaceTitle(index, index == self.activeWorkspaceIndex(), self.activeWorkspaceIndex(), self.workspaceCount(), fallback, out_buf);
        }
        const default_text = std.fmt.bufPrint(out_buf, "{s} {d}/{d}", .{ fallback, self.activeWorkspaceIndex() + 1, self.workspaceCount() }) catch fallback;
        return .{ .text = default_text };
    }

    pub fn setWorkspaceName(self: *App, name: []const u8) void {
        const ws = self.activeWorkspace() orelse return;
        ws.setName(name) catch |err| {
            std.log.err("app: setWorkspaceName failed: {s}", .{@errorName(err)});
        };
    }

    pub fn workspaceName(self: *App, index: usize, out_buf: []u8) []const u8 {
        if (self.mux) |*mux| {
            if (index < mux.workspaces.items.len) return mux.workspaces.items[index].title(out_buf);
        }
        return std.fmt.bufPrint(out_buf, "ws {d}", .{index + 1}) catch "ws";
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
            mux.switchTab(index);
            // Re-register callbacks for the new active pane.
            if (self.ghostty) |*runtime| {
                if (mux.activePane()) |active| {
                    runtime.registerCallbacks(active.terminal, terminalCallbacks());
                }
            }
            self.requestLayoutResize(false);
        }
    }

    pub fn updateTopBarHover(self: *App, mouse_x: f32, mouse_y: f32, window_width: f32, close_w: f32) void {
        self.hovered_tab_index = null;
        self.hovered_close_tab_index = null;

        const tbh: f32 = @floatFromInt(self.tabBarHeight());
        const tab_count = self.tabCount();
        if (tbh <= 0 or mouse_y < 0 or mouse_y >= tbh or mouse_x < 0 or window_width <= 0 or tab_count == 0) return;

        var left_end: f32 = 0.0;
        if (self.shouldDrawTopBarStatus()) {
            var left_text_buf: [512]u8 = undefined;
            var right_text_buf: [512]u8 = undefined;
            var left_segments_buf: [16]bar.Segment = undefined;
            var right_segments_buf: [16]bar.Segment = undefined;
            const left_segments = self.topBarStatus(.left, &left_segments_buf, &left_text_buf);
            const right_segments = self.topBarStatus(.right, &right_segments_buf, &right_text_buf);

            left_end = 4.0;
            for (left_segments) |seg| {
                left_end += @as(f32, @floatFromInt(countUtf8Codepoints(seg.text))) * @as(f32, @floatFromInt(self.cell_width_px));
            }

            if (self.shouldDrawWorkspaceSwitcher()) {
                var ws_buf: [128]u8 = undefined;
                const ws_seg = self.workspaceTitleSegment(self.activeWorkspaceIndex(), &ws_buf);
                left_end += @as(f32, @floatFromInt(countUtf8Codepoints(ws_seg.text))) * @as(f32, @floatFromInt(self.cell_width_px));
            }

            _ = right_segments;
        }

        if (self.hasCustomTopBarTabs()) {
            var title_buf: [256]u8 = undefined;
            const left_reserved: f32 = @as(f32, @floatFromInt(self.cell_width_px)) * 4.0;
            const right_reserved: f32 = @as(f32, @floatFromInt(self.cell_width_px)) * 4.0;
            const available = @max(@as(f32, 1.0), window_width - left_reserved - right_reserved);
            const tab_w = available / @as(f32, @floatFromInt(tab_count));
            var cursor_x: f32 = left_reserved;
            for (0..tab_count) |ti| {
                _ = self.topBarTitle(ti, false, &title_buf);
                if (mouse_x >= cursor_x and mouse_x < cursor_x + tab_w and mouse_y >= 0 and mouse_y < tbh) {
                    self.hovered_tab_index = ti;
                    return;
                }
                cursor_x += tab_w;
            }
            return;
        }

        var left_reserved: f32 = 4.0;
        var right_reserved: f32 = 0.0;
        if (self.shouldDrawTopBarStatus()) {
            var left_text_buf: [512]u8 = undefined;
            var right_text_buf: [512]u8 = undefined;
            var left_segments_buf: [16]bar.Segment = undefined;
            var right_segments_buf: [16]bar.Segment = undefined;
            const left_segments = self.topBarStatus(.left, &left_segments_buf, &left_text_buf);
            const right_segments = self.topBarStatus(.right, &right_segments_buf, &right_text_buf);

            for (left_segments) |seg| {
                left_reserved += @as(f32, @floatFromInt(countUtf8Codepoints(seg.text))) * @as(f32, @floatFromInt(self.cell_width_px));
            }

            if (self.shouldDrawWorkspaceSwitcher()) {
                var ws_buf: [128]u8 = undefined;
                const ws_seg = self.workspaceTitleSegment(self.activeWorkspaceIndex(), &ws_buf);
                left_reserved += @as(f32, @floatFromInt(countUtf8Codepoints(ws_seg.text))) * @as(f32, @floatFromInt(self.cell_width_px));
            }

            for (right_segments) |seg| {
                right_reserved += @as(f32, @floatFromInt(countUtf8Codepoints(seg.text))) * @as(f32, @floatFromInt(self.cell_width_px));
            }
        }

        const tab_start = left_reserved;
        const tab_end = @max(tab_start + 1.0, window_width - right_reserved);
        if (mouse_x < tab_start or mouse_x >= tab_end) return;

        const usable_width = @max(@as(f32, 1.0), tab_end - tab_start);
        const tab_w = usable_width / @as(f32, @floatFromInt(tab_count));
        if (tab_w <= 0) return;

        const raw = (mouse_x - tab_start) / tab_w;
        const clamped = @min(@as(f32, @floatFromInt(tab_count - 1)), @max(0.0, raw));
        const ti: usize = @intFromFloat(clamped);
        self.hovered_tab_index = ti;

        const tab_right = tab_start + (@as(f32, @floatFromInt(ti)) + 1.0) * tab_w;
        if (mouse_x >= tab_right - close_w) {
            self.hovered_close_tab_index = ti;
        }
    }

    /// Override the active pane's title (used by Lua hollow.set_tab_title).
    pub fn setTabTitle(self: *App, title: []const u8) void {
        const pane = self.activePane() orelse return;
        if (pane.title.len > 0) pane.allocator.free(pane.title);
        pane.title = pane.allocator.dupe(u8, title) catch &.{};
    }

    fn resolveConfigPath(self: *App, override: ?[]const u8) !?[]u8 {
        if (override) |path| return try self.allocator.dupe(u8, path);

        const user_path = try platform.defaultConfigPath(self.allocator);
        errdefer self.allocator.free(user_path);
        if (pathExists(user_path)) return user_path;
        self.allocator.free(user_path);

        const fallback = platform.projectFallbackConfigPath();
        if (pathExists(fallback)) return try self.allocator.dupe(u8, fallback);

        if (try platform.resolveRelativeToExe(self.allocator, fallback)) |exe_relative| {
            errdefer self.allocator.free(exe_relative);
            if (pathExists(exe_relative)) return exe_relative;
            self.allocator.free(exe_relative);
        }

        return null;
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
                self.resizeAllPanes(runtime, self.config.window_width, self.config.window_height, false, true);
            }
        }
        if (!self.pending_layout_resize) return;
        const recreate_render_helpers = self.pending_layout_recreate_render_helpers;
        self.pending_layout_resize = false;
        self.pending_layout_recreate_render_helpers = false;
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
            self.resizeAllPanes(runtime, self.config.window_width, self.config.window_height, recreate_render_helpers, false);
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
            if (!pane.hasLiveChild()) {
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
        self.requestLayoutResize(false);
        // Invalidate pending_split_ratio_node — the tree has changed.
        self.pending_split_ratio_node = null;
    }

    fn tickPanes(self: *App, runtime: *GhosttyRuntime) !void {
        var has_dead = false;
        if (self.mux) |*mux| {
            var panes = mux.paneIterator();
            var pane_idx: usize = 0;
            while (panes.next()) |pane| {
                std.log.info("tickPanes[{d}]: pollPty start pane={x} ready={}", .{ pane_idx, @intFromPtr(pane), pane.render_state_ready });
                pane.pollPty(runtime) catch |err| {
                    std.log.err("pane pollPty error: {s}", .{@errorName(err)});
                };
                std.log.info("tickPanes[{d}]: pollPty done", .{pane_idx});
                if (!pane.render_state_ready) {
                    pane_idx += 1;
                    continue;
                }
                const now_ns = std.time.nanoTimestamp();
                const is_active = (self.activePane() == pane);
                const idle_poll_ns: i128 = if (is_active) 16_000_000 else 500_000_000;
                const needs_update = pane.pty_received_data or
                    pane.render_dirty != .false_value or
                    (now_ns - pane.last_render_state_update_ns >= idle_poll_ns);
                if (needs_update) {
                    pane.pty_received_data = false;
                    pane.last_render_state_update_ns = now_ns;
                    std.log.info("tickPanes[{d}]: clearRenderStateDirty", .{pane_idx});
                    runtime.clearRenderStateDirty(pane.render_state);
                    std.log.info("tickPanes[{d}]: updateRenderState", .{pane_idx});
                    runtime.updateRenderState(pane.render_state, pane.terminal) catch |err| {
                        std.log.err("pane updateRenderState error: {s}", .{@errorName(err)});
                    };
                    std.log.info("tickPanes[{d}]: updateRenderState done", .{pane_idx});
                    const post_dirty = runtime.getRenderStateDirty(pane.render_state) orelse .true_value;
                    if (@intFromEnum(post_dirty) > @intFromEnum(pane.render_dirty)) {
                        pane.render_dirty = post_dirty;
                    }
                }
                _ = self.refreshPaneScrollbar(runtime, pane);
                if (!pane.hasLiveChild()) has_dead = true;
                pane_idx += 1;
            }
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
                self.requestLayoutResize(false);
            }
        }
    }

    fn resizeAllPanes(self: *App, runtime: *GhosttyRuntime, pixel_width: u32, pixel_height: u32, recreate_render_helpers: bool, skip_pty: bool) void {
        const mux = if (self.mux) |*m| m else return;
        const ws = mux.activeWorkspace() orelse return;
        var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;

        // How many pixels the tab bar steals from the top.  We compute this
        // from the current cell size rather than from mux.tabCount() because
        // the mux hasn't changed yet at this call site (new tab just added).
        // Use tabBarHeight() which already handles the count guard.
        const tbh = self.tabBarHeight();
        const pane_h = if (pixel_height > tbh) pixel_height - tbh else 1;

        // Resize panes on every tab so that background tabs get
        // render_state_ready = true even when they are not visible.
        // Without this, tickPanes would call ghostty on uninitialised state
        // the moment a new tab is created and the old tab's panes are iterated.
        for (ws.tabs.items) |tab| {
            var written: usize = 0;
            const bounds = PaneBounds{
                .x = 0,
                .y = tbh,
                .width = pixel_width,
                .height = pane_h,
            };
            if (tab.root_split) |root| {
                layoutSplitTree(root, bounds, &layout_buf, &written);
            }
            const leaves = layout_buf[0..written];
            if (leaves.len > 0) {
                for (leaves) |leaf| {
                    // Skip panes with zero-size bounds — can happen when the window
                    // is very small or during layout transitions.
                    if (leaf.bounds.width == 0 or leaf.bounds.height == 0) continue;
                    const inner = self.paneInnerBounds(leaf.bounds);
                    const raw_cols: u32 = inner.width / @max(1, self.cell_width_px);
                    const raw_rows: u32 = inner.height / @max(1, self.cell_height_px);
                    // Cap at sane max to prevent DLL crashes on extreme values.
                    const cols: u16 = @intCast(@min(1000, @max(1, raw_cols)));
                    const rows: u16 = @intCast(@min(500, @max(1, raw_rows)));
                    std.log.info("resizeAllPanes leaf pane={x} bounds=({d},{d} {d}x{d}) grid={d}x{d}", .{
                        @intFromPtr(leaf.pane), leaf.bounds.x, leaf.bounds.y, leaf.bounds.width, leaf.bounds.height, cols, rows,
                    });
                    std.log.info("resizeAllPanes: calling pane.resize pane={x}", .{@intFromPtr(leaf.pane)});
                    if (recreate_render_helpers) {
                        std.log.info("resizeAllPanes: recreateRenderHelpers pane={x}", .{@intFromPtr(leaf.pane)});
                        leaf.pane.recreateRenderHelpers(runtime);
                        std.log.info("resizeAllPanes: recreateRenderHelpers done pane={x}", .{@intFromPtr(leaf.pane)});
                    }
                    leaf.pane.resize(runtime, cols, rows, self.cell_width_px, self.cell_height_px, skip_pty);
                    std.log.info("resizeAllPanes: pane.resize done pane={x}", .{@intFromPtr(leaf.pane)});
                    // The encoder maps absolute surface pixels into pane-local cells
                    // using the full surface size plus the pane's outer padding.
                    leaf.pane.setMouseSize(
                        runtime,
                        leaf.bounds.width,
                        leaf.bounds.height,
                        self.cell_width_px,
                        self.cell_height_px,
                        self.config.terminal_padding.top,
                        self.config.terminal_padding.bottom,
                        self.config.terminal_padding.left,
                        self.config.terminal_padding.right + self.config.scrollbar.gutterWidth(),
                    );
                    leaf.pane.render_state_ready = true;
                    std.log.info("resizeAllPanes: leaf done pane={x} render_state_ready=true", .{@intFromPtr(leaf.pane)});
                }
            } else {
                // Fallback: no split tree yet, resize all panes in this tab to
                // the full window size minus the tab bar.
                if (pixel_width == 0 or pane_h == 0) continue;
                var panes = tab.paneIterator();
                while (panes.next()) |pane| {
                    const horizontal_reserved = self.config.terminal_padding.horizontal() + self.config.scrollbar.gutterWidth();
                    const inner_width = if (pixel_width > horizontal_reserved) pixel_width - horizontal_reserved else 1;
                    const inner_height = if (pane_h > self.config.terminal_padding.vertical()) pane_h - self.config.terminal_padding.vertical() else 1;
                    const cols: u16 = @intCast(@min(1000, @max(1, inner_width / @max(1, self.cell_width_px))));
                    const rows: u16 = @intCast(@min(500, @max(1, inner_height / @max(1, self.cell_height_px))));
                    std.log.info("resizeAllPanes (fallback): pane={x} grid={d}x{d}", .{ @intFromPtr(pane), cols, rows });
                    if (recreate_render_helpers) {
                        std.log.info("resizeAllPanes (fallback): recreateRenderHelpers pane={x}", .{@intFromPtr(pane)});
                        pane.recreateRenderHelpers(runtime);
                        std.log.info("resizeAllPanes (fallback): recreateRenderHelpers done pane={x}", .{@intFromPtr(pane)});
                    }
                    pane.resize(runtime, cols, rows, self.cell_width_px, self.cell_height_px, skip_pty);
                    pane.setMouseSize(
                        runtime,
                        pixel_width,
                        pane_h,
                        self.cell_width_px,
                        self.cell_height_px,
                        self.config.terminal_padding.top,
                        self.config.terminal_padding.bottom,
                        self.config.terminal_padding.left,
                        self.config.terminal_padding.right + self.config.scrollbar.gutterWidth(),
                    );
                    pane.render_state_ready = true;
                    std.log.info("resizeAllPanes (fallback): pane done pane={x}", .{@intFromPtr(pane)});
                }
            }
        }
    }
    /// Fire the Lua on_key handler. Returns true if the key was consumed.
    pub fn fireOnKey(self: *App, key: []const u8, mods: u32) bool {
        if (self.lua) |*lua| return lua.fireOnKey(key, mods);
        return false;
    }

    pub fn isLeaderActive(self: *App) bool {
        if (self.lua) |*lua| return lua.isLeaderActive();
        return false;
    }
};

/// AppCallbacks.split_pane implementation — called from Lua.
fn luaSplitPaneCallback(app_ptr: *anyopaque, direction: []const u8, ratio: f32) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const dir: SplitDirection = if (std.mem.eql(u8, direction, "horizontal")) .horizontal else .vertical;
    _ = app.enqueueMouse(.{ .split_pane = .{ .direction = dir, .ratio = ratio } });
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
        @memcpy(out[len.* .. len.* + encoded_len], utf8_buf[0..encoded_len]);
        len.* += encoded_len;
    }
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
    if (app.ghostty) |*runtime| {
        if (getPaneForTerminal(app, term)) |pane| {
            pane.refreshTitle(runtime, app.config.windowTitle());
        }
    }
}

fn luaNewTabCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.new_tab);
}

fn luaCloseTabCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.close_tab);
}

fn luaClosePaneCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.close_pane);
}

fn luaNextTabCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.next_tab);
}

fn luaPrevTabCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.prev_tab);
}

fn luaNewWorkspaceCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.new_workspace);
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
    app.switchWorkspace(index);
}

fn luaSetWorkspaceNameCallback(app_ptr: *anyopaque, name: []const u8) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    app.setWorkspaceName(name);
}

fn luaFocusPaneCallback(app_ptr: *anyopaque, direction: []const u8) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const dir: FocusDirection = if (std.mem.eql(u8, direction, "left")) .left else if (std.mem.eql(u8, direction, "right")) .right else if (std.mem.eql(u8, direction, "up")) .up else .down;
    _ = app.enqueueMouse(.{ .focus_pane = dir });
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

fn luaIsLeaderActiveCallback(app_ptr: *anyopaque) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.isLeaderActive();
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
