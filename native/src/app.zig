const std = @import("std");
const Config = @import("config.zig").Config;
const Backend = @import("render/backend.zig").Backend;
const FrameSnapshot = @import("render/debug_backend.zig").FrameSnapshot;
const LuaRuntime = @import("lua/luajit.zig").Runtime;
const AppCallbacks = @import("lua/luajit.zig").AppCallbacks;
const GhosttyRuntime = @import("term/ghostty.zig").Runtime;
const ghostty = @import("term/ghostty.zig");
const Mux = @import("mux.zig").Mux;
const Workspace = @import("mux.zig").Workspace;
const Tab = @import("mux.zig").Tab;
const SplitDirection = @import("mux.zig").SplitDirection;
const LayoutLeaf = @import("mux.zig").LayoutLeaf;
const MAX_LAYOUT_LEAVES = @import("mux.zig").MAX_LAYOUT_LEAVES;
const Pane = @import("pane.zig").Pane;
const platform = @import("platform.zig");

var write_bridge: ?*App = null;
var size_bridge: ?*App = null;
var attrs_bridge: ?*App = null;
var title_bridge: ?*App = null;

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
        try mux.bootstrapSingle(&runtime, self.config, self.cell_width_px, self.cell_height_px, self.config.window_width, self.config.window_height);

        self.ghostty = runtime;
        self.mux = mux;
        self.renderer = Backend.init(self.allocator, self.config);

        write_bridge = self;
        size_bridge = self;
        attrs_bridge = self;
        title_bridge = self;
        const active_pane = self.activePane().?;
        self.ghostty.?.setWritePtyCallback(active_pane.terminal, writePtyCallback);
        self.ghostty.?.setSizeCallback(active_pane.terminal, sizeCallback);
        self.ghostty.?.setDeviceAttributesCallback(active_pane.terminal, deviceAttributesCallback);
        self.ghostty.?.setTitleChangedCallback(active_pane.terminal, titleChangedCallback);

        // Register app action callbacks so Lua can call split_pane etc.
        if (self.lua) |*lua| {
            lua.registerAppCallbacks(.{
                .app = self,
                .split_pane = luaSplitPaneCallback,
                .new_tab = luaNewTabCallback,
                .next_tab = luaNextTabCallback,
                .prev_tab = luaPrevTabCallback,
            });
        }

        try self.tick();
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
        var buf: [128]u8 = undefined;
        const consumed: u32 = if (text != null and (mods & ghostty.Mods.shift) != 0) ghostty.Mods.shift else ghostty.Mods.none;
        const bytes = self.ghostty.?.encodeKey(pane.key_encoder, pane.key_event, key, mods, .press, consumed, if (text) |t| firstCodepoint(t) else 0, text, &buf) orelse return false;
        try self.sendText(bytes);
        return true;
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
        var runtime = if (self.ghostty) |*value| value else return;
        mux.newTab(runtime, self.config, self.cell_width_px, self.cell_height_px, self.config.window_width, self.config.window_height) catch |err| {
            std.log.err("app: newTab failed: {s}", .{@errorName(err)});
            return;
        };
        if (mux.activePane()) |new_pane| {
            runtime.setWritePtyCallback(new_pane.terminal, writePtyCallback);
            runtime.setSizeCallback(new_pane.terminal, sizeCallback);
            runtime.setDeviceAttributesCallback(new_pane.terminal, deviceAttributesCallback);
            runtime.setTitleChangedCallback(new_pane.terminal, titleChangedCallback);
        }
        self.pending_layout_resize = true;
        std.log.info("app: created new tab", .{});
    }

    pub fn nextTab(self: *App) void {
        if (self.mux) |*mux| mux.nextTab();
        self.pending_layout_resize = true;
    }

    pub fn prevTab(self: *App) void {
        if (self.mux) |*mux| mux.prevTab();
        self.pending_layout_resize = true;
    }

    pub fn splitPane(self: *App, direction: SplitDirection) void {
        var mux = if (self.mux) |*value| value else return;
        var runtime = if (self.ghostty) |*value| value else return;
        mux.splitActivePane(runtime, self.config, self.cell_width_px, self.cell_height_px, self.config.window_width, self.config.window_height, direction) catch |err| {
            std.log.err("app: splitPane failed: {s}", .{@errorName(err)});
            return;
        };
        // Register callbacks for the new active pane
        if (mux.activePane()) |new_pane| {
            runtime.setWritePtyCallback(new_pane.terminal, writePtyCallback);
            runtime.setSizeCallback(new_pane.terminal, sizeCallback);
            runtime.setDeviceAttributesCallback(new_pane.terminal, deviceAttributesCallback);
            runtime.setTitleChangedCallback(new_pane.terminal, titleChangedCallback);
        }
        // Schedule a layout resize for the next tick() (frame callback thread),
        // rather than calling ghostty_terminal_resize from the event callback thread.
        self.pending_layout_resize = true;
        std.log.info("app: pane split direction={s}", .{@tagName(direction)});
    }

    pub fn computeActiveLayout(self: *App, out: []LayoutLeaf) []LayoutLeaf {
        if (self.mux) |*mux| return mux.computeActiveLayout(self.config.window_width, self.config.window_height, out);
        return out[0..0];
    }

    pub fn activeTitle(self: *App) []const u8 {
        if (self.activePane()) |pane| return pane.title;
        return self.config.windowTitle();
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
        if (self.mux) |*mux| {
            var panes = mux.paneIterator();
            while (panes.next()) |pane| {
                try pane.pollPty(runtime);
                try runtime.updateRenderState(pane.render_state, pane.terminal);
                pane.render_state_ready = true;
            }
        }
    }

    fn resizeAllPanes(self: *App, runtime: *GhosttyRuntime, pixel_width: u32, pixel_height: u32, recreate_render_helpers: bool) void {
        if (self.mux) |*mux| {
            var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
            const leaves = mux.computeActiveLayout(pixel_width, pixel_height, &layout_buf);
            if (leaves.len > 0) {
                // Resize each pane to its computed sub-rect.
                for (leaves) |leaf| {
                    const cols: u16 = @max(1, @as(u16, @intCast(leaf.bounds.width / @max(1, self.cell_width_px))));
                    const rows: u16 = @max(1, @as(u16, @intCast(leaf.bounds.height / @max(1, self.cell_height_px))));
                    leaf.pane.resize(runtime, cols, rows, self.cell_width_px, self.cell_height_px);
                    if (recreate_render_helpers) leaf.pane.recreateRenderHelpers(runtime);
                    leaf.pane.setMouseSize(runtime, leaf.bounds.width, leaf.bounds.height, self.cell_width_px, self.cell_height_px);
                }
            } else {
                // Fallback: no split tree yet, resize all panes to full window.
                var panes = mux.paneIterator();
                while (panes.next()) |pane| {
                    pane.resize(runtime, self.config.cols, self.config.rows, self.cell_width_px, self.cell_height_px);
                    if (recreate_render_helpers) pane.recreateRenderHelpers(runtime);
                    pane.setMouseSize(runtime, pixel_width, pixel_height, self.cell_width_px, self.cell_height_px);
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
fn luaSplitPaneCallback(app_ptr: *anyopaque, direction: []const u8) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const dir: SplitDirection = if (std.mem.eql(u8, direction, "horizontal")) .horizontal else .vertical;
    app.splitPane(dir);
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
    return app.activePane();
}

fn writePtyCallback(term: ?*anyopaque, _: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void {
    const app = write_bridge orelse return;
    const pane = getPaneForTerminal(app, term) orelse return;
    pane.sendText(bytes[0..len]) catch {};
}

fn sizeCallback(_: ?*anyopaque, _: ?*anyopaque, out: *ghostty.SizeReportSize) callconv(.c) bool {
    const app = size_bridge orelse return false;
    out.rows = app.config.rows;
    out.columns = app.config.cols;
    out.cell_width = app.cell_width_px;
    out.cell_height = app.cell_height_px;
    return true;
}

fn deviceAttributesCallback(_: ?*anyopaque, _: ?*anyopaque, out: *ghostty.DeviceAttributes) callconv(.c) bool {
    const app = attrs_bridge orelse return false;
    _ = app;
    out.conformance_level = 1;
    out.features = [_]u8{ 1, 2, 22, 0, 0, 0, 0, 0 };
    out.num_features = 3;
    out.device_type = 1;
    out.firmware_version = 1;
    out.rom_cartridge = 0;
    out.unit_id = 0;
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
    app.newTab();
}

fn luaNextTabCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    app.nextTab();
}

fn luaPrevTabCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    app.prevTab();
}
