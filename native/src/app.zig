const std = @import("std");
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
const layoutSplitTree = mux_mod.layoutSplitTree;
const MAX_LAYOUT_LEAVES = mux_mod.MAX_LAYOUT_LEAVES;
const Pane = @import("pane.zig").Pane;
const platform = @import("platform.zig");
const bar = @import("ui/bar.zig");

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
    /// Set when all panes/tabs have closed; the runtime should call sapp_request_quit().
    pending_quit: bool = false,
    hovered_tab_index: ?usize = null,
    hovered_close_tab_index: ?usize = null,

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
        self.config.deinit();
    }

    pub fn bootstrap(self: *App, config_override: ?[]const u8) !void {
        self.loaded_config_path = try self.resolveConfigPath(config_override);
        try self.ensureDynamicLibraryPath();

        self.tryInitLua();

        var runtime = try GhosttyRuntime.init(self.allocator, self.config.ghosttyLibrary());
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
        self.flushPendingResize();
        self.flushPendingLayoutResize();
        if (self.ghostty) |*runtime| try self.tickPanes(runtime);
        if (!self.logged_first_render_update) {
            self.logged_first_render_update = true;
            std.log.info("first render-state update complete", .{});
        }
        self.frame_count += 1;
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

    pub fn report(self: *App) void {
        std.log.info("native bootstrap ready", .{});
        std.log.info("host={s}", .{platform.name()});
        std.log.info("shell={s}", .{self.config.shellOrDefault()});
        std.log.info("backend requested={s} active={s}", .{ self.config.backend.asString(), self.renderer.?.activeName() });
        std.log.info("window={s} {d}x{d}", .{ self.config.windowTitle(), self.config.window_width, self.config.window_height });
        std.log.info("grid={d}x{d} scrollback={d}", .{ self.config.cols, self.config.rows, self.config.scrollback });
        if (self.loaded_config_path) |path| std.log.info("config={s}", .{path});
        if (self.ghostty) |runtime| std.log.info("libghostty-vt={s}", .{runtime.loaded_path});
        if (self.lua) |lua| std.log.info("luajit={s}", .{lua.loaded_path});
    }

    pub fn sendText(self: *App, text: []const u8) !void {
        const pane = self.activePane() orelse return;
        try pane.sendText(text);
    }

    pub fn setCellSize(self: *App, cell_w: u32, cell_h: u32) void {
        self.cell_width_px = @max(1, cell_w);
        self.cell_height_px = @max(1, cell_h);
        if (self.ghostty) |*runtime| self.resizeAllPanes(runtime, self.config.window_width, self.config.window_height, false);
        std.log.info("app: cell_size updated cell={d}x{d}", .{ self.cell_width_px, self.cell_height_px });
    }

    pub fn resize(self: *App, pixel_width: u32, pixel_height: u32) void {
        self.config.window_width = pixel_width;
        self.config.window_height = pixel_height;

        self.config.cols = @max(1, @as(u16, @intCast(pixel_width / @max(@as(u32, 1), self.cell_width_px))));
        self.config.rows = @max(1, @as(u16, @intCast(pixel_height / @max(@as(u32, 1), self.cell_height_px))));

        if (self.ghostty) |*runtime| self.resizeAllPanes(runtime, pixel_width, pixel_height, true);

        std.log.info("app: resized window={d}x{d} grid={d}x{d} cell={d}x{d}", .{ pixel_width, pixel_height, self.config.cols, self.config.rows, self.cell_width_px, self.cell_height_px });
    }

    pub fn requestResize(self: *App, pixel_width: u32, pixel_height: u32) void {
        self.pending_width = pixel_width;
        self.pending_height = pixel_height;
        self.pending_resize = true;
    }

    pub fn sendPaste(self: *App, text: []const u8) !void {
        const pane = self.activePane() orelse return;
        if (self.ghostty.?.terminalMode(pane.terminal, .bracketed_paste)) {
            try self.sendText("\x1b[200~");
            try self.sendText(text);
            try self.sendText("\x1b[201~");
            return;
        }
        try self.sendText(text);
    }

    pub fn sendFocus(self: *App, gained: bool) !void {
        const pane = self.activePane() orelse return;
        if (!self.ghostty.?.terminalMode(pane.terminal, .focus_event)) return;
        var buf: [8]u8 = undefined;
        const bytes = self.ghostty.?.encodeFocus(if (gained) .gained else .lost, &buf) orelse return;
        try self.sendText(bytes);
    }

    pub fn sendKey(self: *App, key: ghostty.Key, mods: u32, text: ?[]const u8) !bool {
        const pane = self.activePane() orelse return false;
        if (key == .escape and mods == ghostty.Mods.none and text == null) {
            try self.sendText("\x1b");
            return true;
        }

        var buf: [128]u8 = undefined;
        const consumed: u32 = if (text != null and (mods & ghostty.Mods.shift) != 0) ghostty.Mods.shift else ghostty.Mods.none;
        if (self.ghostty.?.encodeKey(pane.key_encoder, pane.key_event, key, mods, .press, consumed, if (text) |t| firstCodepoint(t) else 0, text, &buf)) |bytes| {
            try self.sendText(bytes);
            return true;
        }

        return false;
    }

    pub const HitTestResult = struct {
        pane: *Pane,
        x: f32,
        y: f32,
    };

    pub fn hitTestPane(self: *App, x: f32, y: f32) ?HitTestResult {
        if (self.mux) |*mux| {
            var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
            const leaves = mux.computeActiveLayout(self.config.window_width, self.config.window_height, &layout_buf);
            const ix = @as(u32, @intFromFloat(@max(0, x)));
            const iy = @as(u32, @intFromFloat(@max(0, y)));
            for (leaves) |leaf| {
                if (ix >= leaf.bounds.x and ix < leaf.bounds.x + leaf.bounds.width and
                    iy >= leaf.bounds.y and iy < leaf.bounds.y + leaf.bounds.height)
                {
                    return .{
                        .pane = leaf.pane,
                        .x = x - @as(f32, @floatFromInt(leaf.bounds.x)),
                        .y = y - @as(f32, @floatFromInt(leaf.bounds.y)),
                    };
                }
            }
        }
        if (self.activePane()) |pane| return .{ .pane = pane, .x = x, .y = y };
        return null;
    }

    pub fn sendMouse(self: *App, action: ghostty.MouseAction, button: ?ghostty.MouseButton, x: f32, y: f32, mods: u32) !void {
        const hit = self.hitTestPane(x, y) orelse return;
        if (action == .press) {
            if (self.mux) |*mux| mux.setActivePane(hit.pane);
        }
        var buf: [128]u8 = undefined;
        const bytes = self.ghostty.?.encodeMouse(hit.pane.mouse_encoder, hit.pane.mouse_event, action, button, mods, .{ .x = hit.x, .y = hit.y }, &buf) orelse return;
        try hit.pane.sendText(bytes);
    }

    pub fn scroll(self: *App, x: f32, y: f32, delta: isize) void {
        const hit = self.hitTestPane(x, y) orelse return;
        self.ghostty.?.terminalScroll(hit.pane.terminal, delta);
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
        self.pending_layout_resize = true;
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
        self.pending_layout_resize = true;
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
        self.pending_layout_resize = true;
        std.log.info("app: active pane closed via close_pane", .{});
    }

    pub fn nextTab(self: *App) void {
        if (self.mux) |*mux| mux.nextTab();
        self.pending_layout_resize = true;
    }

    pub fn prevTab(self: *App) void {
        if (self.mux) |*mux| mux.prevTab();
        self.pending_layout_resize = true;
    }

    pub fn newWorkspace(self: *App) void {
        var mux = if (self.mux) |*value| value else return;
        const runtime = if (self.ghostty) |*value| value else return;
        const cbs = terminalCallbacks();
        mux.newWorkspace(runtime, cbs, self.config, self.cell_width_px, self.cell_height_px, self.config.window_width, self.config.window_height) catch |err| {
            std.log.err("app: newWorkspace failed: {s}", .{@errorName(err)});
            return;
        };
        self.pending_layout_resize = true;
        std.log.info("app: created new workspace", .{});
    }

    pub fn nextWorkspace(self: *App) void {
        if (self.mux) |*mux| {
            mux.nextWorkspace();
            if (self.ghostty) |*runtime| {
                if (mux.activePane()) |active| runtime.registerCallbacks(active.terminal, terminalCallbacks());
            }
            self.pending_layout_resize = true;
        }
    }

    pub fn prevWorkspace(self: *App) void {
        if (self.mux) |*mux| {
            mux.prevWorkspace();
            if (self.ghostty) |*runtime| {
                if (mux.activePane()) |active| runtime.registerCallbacks(active.terminal, terminalCallbacks());
            }
            self.pending_layout_resize = true;
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
            self.pending_layout_resize = true;
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
        self.pending_layout_resize = true;
        std.log.info("app: pane split done direction={s}", .{@tagName(direction)});
    }

    pub fn resizePane(self: *App, direction: SplitDirection, delta: f32) void {
        if (self.mux) |*mux| {
            mux.resizeActivePane(direction, delta);
            self.pending_layout_resize = true;
        }
    }

    pub fn focusPane(self: *App, direction: FocusDirection) void {
        if (self.mux) |*mux| {
            mux.focusPaneInDirection(direction, self.config.window_width, self.config.window_height);
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
        std.log.info("App.tabTitle index={d}", .{index});
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
            self.pending_layout_resize = true;
        }
    }

    pub fn updateTopBarHover(self: *App, mouse_x: f32, mouse_y: f32, window_width: f32, close_w: f32) void {
        self.hovered_tab_index = null;
        self.hovered_close_tab_index = null;

        const tbh: f32 = @floatFromInt(self.tabBarHeight());
        const tab_count = self.tabCount();
        if (tbh <= 0 or mouse_y < 0 or mouse_y >= tbh or mouse_x < 0 or window_width <= 0 or tab_count == 0) return;

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

        const tab_w = window_width / @as(f32, @floatFromInt(tab_count));
        if (tab_w <= 0) return;

        const raw = mouse_x / tab_w;
        const clamped = @min(@as(f32, @floatFromInt(tab_count - 1)), @max(0.0, raw));
        const ti: usize = @intFromFloat(clamped);
        self.hovered_tab_index = ti;

        const tab_right = (@as(f32, @floatFromInt(ti)) + 1.0) * tab_w;
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

    fn ensureDynamicLibraryPath(self: *App) !void {
        if (self.config.lib_dir) |dir| {
            try prependLibraryPath(self.allocator, dir);
            return;
        }

        if (pathExists("third_party/ghostty/zig-out/lib")) try prependLibraryPath(self.allocator, "third_party/ghostty/zig-out/lib");
        if (pathExists("third_party/luajit/lib")) try prependLibraryPath(self.allocator, "third_party/luajit/lib");
        if (platform.isLinux()) try prependLibraryPath(self.allocator, "/home/linuxbrew/.linuxbrew/lib");
    }

    fn resolveConfigPath(self: *App, override: ?[]const u8) !?[]u8 {
        if (override) |path| return try self.allocator.dupe(u8, path);

        const user_path = try platform.defaultConfigPath(self.allocator);
        errdefer self.allocator.free(user_path);
        if (pathExists(user_path)) return user_path;
        self.allocator.free(user_path);

        const fallback = platform.projectFallbackConfigPath();
        if (pathExists(fallback)) return try self.allocator.dupe(u8, fallback);
        return null;
    }

    fn flushPendingResize(self: *App) void {
        if (!self.pending_resize) return;
        self.pending_resize = false;
        self.resize(self.pending_width, self.pending_height);
    }

    fn flushPendingLayoutResize(self: *App) void {
        if (!self.pending_layout_resize) return;
        self.pending_layout_resize = false;
        if (self.ghostty) |*runtime| {
            self.resizeAllPanes(runtime, self.config.window_width, self.config.window_height, false);
        }
    }

    fn tickPanes(self: *App, runtime: *GhosttyRuntime) !void {
        var has_dead = false;
        if (self.mux) |*mux| {
            var panes = mux.paneIterator();
            var pane_idx: usize = 0;
            while (panes.next()) |pane| {
                pane.pollPty(runtime) catch |err| {
                    std.log.err("pane pollPty error: {s}", .{@errorName(err)});
                };
                if (!pane.render_state_ready) {
                    pane_idx += 1;
                    continue;
                }
                runtime.updateRenderState(pane.render_state, pane.terminal) catch |err| {
                    std.log.err("pane updateRenderState error: {s}", .{@errorName(err)});
                };
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
                self.pending_layout_resize = true;
            }
        }
    }

    fn resizeAllPanes(self: *App, runtime: *GhosttyRuntime, pixel_width: u32, pixel_height: u32, recreate_render_helpers: bool) void {
        const mux = if (self.mux) |*m| m else return;
        const ws = mux.activeWorkspace() orelse return;
        var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;

        std.log.info("resizeAllPanes tab_count={d} px={d}x{d}", .{ ws.tabs.items.len, pixel_width, pixel_height });

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
                    const cols: u16 = @max(1, @as(u16, @intCast(leaf.bounds.width / @max(1, self.cell_width_px))));
                    const rows: u16 = @max(1, @as(u16, @intCast(leaf.bounds.height / @max(1, self.cell_height_px))));
                    leaf.pane.resize(runtime, cols, rows, self.cell_width_px, self.cell_height_px);
                    if (recreate_render_helpers) leaf.pane.recreateRenderHelpers(runtime);
                    leaf.pane.setMouseSize(runtime, leaf.bounds.width, leaf.bounds.height, self.cell_width_px, self.cell_height_px);
                    leaf.pane.render_state_ready = true;
                }
            } else {
                // Fallback: no split tree yet, resize all panes in this tab to
                // the full window size minus the tab bar.
                var panes = tab.paneIterator();
                while (panes.next()) |pane| {
                    const cols: u16 = @max(1, @as(u16, @intCast(pixel_width / @max(1, self.cell_width_px))));
                    const rows: u16 = @max(1, @as(u16, @intCast(pane_h / @max(1, self.cell_height_px))));
                    pane.resize(runtime, cols, rows, self.cell_width_px, self.cell_height_px);
                    if (recreate_render_helpers) pane.recreateRenderHelpers(runtime);
                    pane.setMouseSize(runtime, pixel_width, pane_h, self.cell_width_px, self.cell_height_px);
                    pane.render_state_ready = true;
                }
            }
        }
    }
    /// Fire the Lua on_key handler. Returns true if the key was consumed.
    pub fn fireOnKey(self: *App, key: []const u8, mods: u32) bool {
        if (self.lua) |*lua| return lua.fireOnKey(key, mods);
        return false;
    }
};

/// AppCallbacks.split_pane implementation — called from Lua.
fn luaSplitPaneCallback(app_ptr: *anyopaque, direction: []const u8, ratio: f32) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const dir: SplitDirection = if (std.mem.eql(u8, direction, "horizontal")) .horizontal else .vertical;
    app.splitPane(dir, ratio);
}

fn prependLibraryPath(allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    _ = path;
    return;
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
    return text[0];
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
    std.log.info("writePtyCallback called len={d} bytes={*}", .{ len, bytes });
    if (bytes == null or len == 0) return;
    const bytes_ptr = bytes.?;
    const app = write_bridge orelse return;
    const pane = getPaneForTerminal(app, term) orelse return;
    pane.sendText(bytes_ptr[0..len]) catch {};
}

fn bellCallback(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}

fn enquiryCallback(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) ghostty.String {
    return .{ .ptr = null, .len = 0 };
}

fn xtversionCallback(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) ghostty.String {
    return .{ .ptr = null, .len = 0 };
}

fn sizeCallback(term: ?*anyopaque, _: ?*anyopaque, out: ?*ghostty.SizeReportSize) callconv(.c) bool {
    std.log.info("sizeCallback called out={*}", .{out});
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
    std.log.info("deviceAttributesCallback called out={*}", .{out});
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
    std.log.info("titleChangedCallback called", .{});
    const app = title_bridge orelse return;
    if (app.ghostty) |*runtime| {
        if (getPaneForTerminal(app, term)) |pane| {
            pane.refreshTitle(runtime, app.config.windowTitle());
        }
    }
}

fn luaNewTabCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    app.newTab();
}

fn luaCloseTabCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    app.closeTab();
}

fn luaClosePaneCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    app.closeActivePane();
}

fn luaNextTabCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    app.nextTab();
}

fn luaPrevTabCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    app.prevTab();
}

fn luaNewWorkspaceCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    app.newWorkspace();
}

fn luaNextWorkspaceCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    app.nextWorkspace();
}

fn luaPrevWorkspaceCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    app.prevWorkspace();
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
    app.focusPane(dir);
}

fn luaResizePaneCallback(app_ptr: *anyopaque, direction: []const u8, delta: f32) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const dir: SplitDirection = if (std.mem.eql(u8, direction, "horizontal")) .horizontal else .vertical;
    app.resizePane(dir, delta);
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
