const std = @import("std");
const Config = @import("config.zig").Config;
const Backend = @import("render/backend.zig").Backend;
const FrameSnapshot = @import("render/debug_backend.zig").FrameSnapshot;
const LuaRuntime = @import("lua/luajit.zig").Runtime;
const GhosttyRuntime = @import("term/ghostty.zig").Runtime;
const GhosttyOptions = @import("term/ghostty.zig").TerminalOptions;
const ghostty = @import("term/ghostty.zig");
const Pty = @import("pty/pty.zig").Pty;
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
    pty: ?Pty = null,
    terminal: ?*anyopaque = null,
    render_state: ?*anyopaque = null,
    row_iterator: ?*anyopaque = null,
    row_cells: ?*anyopaque = null,
    key_encoder: ?*anyopaque = null,
    key_event: ?*anyopaque = null,
    mouse_encoder: ?*anyopaque = null,
    mouse_event: ?*anyopaque = null,
    loaded_config_path: ?[]u8 = null,
    title: []u8 = &.{},
    read_buf: [65536]u8 = [_]u8{0} ** 65536,
    frame_count: usize = 0,
    logged_first_pty_read: bool = false,
    logged_first_render_update: bool = false,
    cell_width_px: u32 = 8,
    cell_height_px: u32 = 16,
    pending_resize: bool = false,
    pending_width: u32 = 0,
    pending_height: u32 = 0,
    pty_pending_seq: [8]u8 = [_]u8{0} ** 8,
    pty_pending_len: usize = 0,
    pty_sanitize_buf: [65544]u8 = [_]u8{0} ** 65544,

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
            runtime.freeMouseEvent(self.mouse_event);
            runtime.freeMouseEncoder(self.mouse_encoder);
            runtime.freeKeyEvent(self.key_event);
            runtime.freeKeyEncoder(self.key_encoder);
            runtime.freeRowCells(self.row_cells);
            runtime.freeRowIterator(self.row_iterator);
            runtime.freeRenderState(self.render_state);
            runtime.freeTerminal(self.terminal);
            runtime.deinit();
            self.ghostty = null;
        }

        if (self.pty) |*pty| {
            pty.deinit();
            self.pty = null;
        }

        if (self.lua) |*lua| {
            lua.deinit();
            self.lua = null;
        }

        if (self.loaded_config_path) |path| {
            self.allocator.free(path);
            self.loaded_config_path = null;
        }

        if (self.title.len > 0) self.allocator.free(self.title);

        self.config.deinit();
    }

    pub fn bootstrap(self: *App, config_override: ?[]const u8) !void {
        self.loaded_config_path = try self.resolveConfigPath(config_override);
        try self.ensureDynamicLibraryPath();

        self.tryInitLua();

        var runtime = try GhosttyRuntime.init(self.allocator, self.config.ghosttyLibrary());
        errdefer runtime.deinit();

        const terminal = try runtime.createTerminal(.{
            .cols = self.config.cols,
            .rows = self.config.rows,
            .max_scrollback = self.config.scrollback,
        });
        errdefer runtime.freeTerminal(terminal);

        const render_state = try runtime.createRenderState();
        errdefer runtime.freeRenderState(render_state);

        const row_iterator = try runtime.createRowIterator();
        errdefer runtime.freeRowIterator(row_iterator);

        const row_cells = try runtime.createRowCells();
        errdefer runtime.freeRowCells(row_cells);

        const key_encoder = try runtime.createKeyEncoder();
        errdefer runtime.freeKeyEncoder(key_encoder);

        const key_event = try runtime.createKeyEvent();
        errdefer runtime.freeKeyEvent(key_event);

        const mouse_encoder = try runtime.createMouseEncoder();
        errdefer runtime.freeMouseEncoder(mouse_encoder);

        const mouse_event = try runtime.createMouseEvent();
        errdefer runtime.freeMouseEvent(mouse_event);

        const shell = try self.allocator.dupeZ(u8, self.config.shellOrDefault());
        defer self.allocator.free(shell);
        var pty = try @import("pty/pty.zig").spawn(self.allocator, shell, self.config.cols, self.config.rows);
        errdefer pty.deinit();

        self.ghostty = runtime;
        self.terminal = terminal;
        self.render_state = render_state;
        self.row_iterator = row_iterator;
        self.row_cells = row_cells;
        self.key_encoder = key_encoder;
        self.key_event = key_event;
        self.mouse_encoder = mouse_encoder;
        self.mouse_event = mouse_event;
        self.pty = pty;
        self.renderer = Backend.init(self.allocator, self.config);

        write_bridge = self;
        size_bridge = self;
        attrs_bridge = self;
        title_bridge = self;
        self.ghostty.?.setWritePtyCallback(self.terminal, writePtyCallback);
        self.ghostty.?.setSizeCallback(self.terminal, sizeCallback);
        self.ghostty.?.setDeviceAttributesCallback(self.terminal, deviceAttributesCallback);
        self.ghostty.?.setTitleChangedCallback(self.terminal, titleChangedCallback);

        self.ghostty.?.syncKeyEncoder(self.key_encoder, self.terminal);
        self.ghostty.?.syncMouseEncoder(self.mouse_encoder, self.terminal);
        self.ghostty.?.setMouseEncoderSize(self.mouse_encoder, .{
            .size = @sizeOf(ghostty.MouseEncoderSize),
            .screen_width = self.config.window_width,
            .screen_height = self.config.window_height,
            .cell_width = self.cell_width_px,
            .cell_height = self.cell_height_px,
            .padding_top = 0,
            .padding_bottom = 0,
            .padding_left = 0,
            .padding_right = 0,
        });
        self.ghostty.?.resizeTerminal(self.terminal, self.config.cols, self.config.rows, self.cell_width_px, self.cell_height_px);
        self.pty.?.resize(self.config.cols, self.config.rows);

        self.refreshTitle();
        try self.tick();
    }

    fn tryInitLua(self: *App) void {
        var lua = LuaRuntime.init(self.allocator, &self.config) catch |err| {
            std.log.warn("LuaJIT unavailable, continuing without scripting: {s}", .{@errorName(err)});
            return;
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
        if (self.pty) |*pty| {
            var total_read: usize = 0;
            var read_loops: usize = 0;
            while ((pty.isAlive() or pty.hasPendingOutput()) and read_loops < 64 and total_read < (1024 * 1024)) {
                const count = try pty.read(&self.read_buf);
                if (count == 0) break;
                read_loops += 1;
                total_read += count;
                if (count > 0) {
                    if (!self.logged_first_pty_read) {
                        self.logged_first_pty_read = true;
                        std.log.info("first PTY bytes received count={d}", .{count});
                    }
                    const pty_bytes = self.sanitizePtyOutput(self.read_buf[0..count]);
                    if (pty_bytes.len > 0) {
                        self.ghostty.?.terminalWrite(self.terminal, pty_bytes);
                    }

                }
            }
            self.ghostty.?.syncKeyEncoder(self.key_encoder, self.terminal);
            self.ghostty.?.syncMouseEncoder(self.mouse_encoder, self.terminal);
        }
        try self.ghostty.?.updateRenderState(self.render_state, self.terminal);
        if (!self.logged_first_render_update) {
            self.logged_first_render_update = true;
            std.log.info("first render-state update complete", .{});
        }
        self.frame_count += 1;
    }

    pub fn captureSnapshot(self: *App) ?FrameSnapshot {
        if (self.renderer) |*renderer| {
            if (self.ghostty) |*runtime| {
                return renderer.fillSnapshot(runtime, self.render_state, &self.row_iterator, &self.row_cells, self.config, self.title);
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
        if (self.pty) |*pty| try pty.writeAll(text);
    }

    pub fn setCellSize(self: *App, cell_w: u32, cell_h: u32) void {
        self.cell_width_px = @max(1, cell_w);
        self.cell_height_px = @max(1, cell_h);
        if (self.ghostty) |*runtime| {
            runtime.resizeTerminal(self.terminal, self.config.cols, self.config.rows, self.cell_width_px, self.cell_height_px);
            runtime.setMouseEncoderSize(self.mouse_encoder, .{
                .size = @sizeOf(ghostty.MouseEncoderSize),
                .screen_width = self.config.window_width,
                .screen_height = self.config.window_height,
                .cell_width = self.cell_width_px,
                .cell_height = self.cell_height_px,
                .padding_top = 0,
                .padding_bottom = 0,
                .padding_left = 0,
                .padding_right = 0,
            });
        }
        if (self.pty) |*pty| pty.resize(self.config.cols, self.config.rows);
        std.log.info("app: cell_size updated cell={d}x{d}", .{ self.cell_width_px, self.cell_height_px });
    }

    pub fn resize(self: *App, pixel_width: u32, pixel_height: u32) void {
        self.config.window_width = pixel_width;
        self.config.window_height = pixel_height;

        self.config.cols = @max(1, @as(u16, @intCast(pixel_width / @max(@as(u32, 1), self.cell_width_px))));
        self.config.rows = @max(1, @as(u16, @intCast(pixel_height / @max(@as(u32, 1), self.cell_height_px))));

        if (self.ghostty) |*runtime| {
            runtime.resizeTerminal(self.terminal, self.config.cols, self.config.rows, self.cell_width_px, self.cell_height_px);
            self.recreateRenderHelpers(runtime);
            runtime.setMouseEncoderSize(self.mouse_encoder, .{
                .size = @sizeOf(ghostty.MouseEncoderSize),
                .screen_width = pixel_width,
                .screen_height = pixel_height,
                .cell_width = self.cell_width_px,
                .cell_height = self.cell_height_px,
                .padding_top = 0,
                .padding_bottom = 0,
                .padding_left = 0,
                .padding_right = 0,
            });
        }

        if (self.pty) |*pty| pty.resize(self.config.cols, self.config.rows);
        std.log.info("app: resized window={d}x{d} grid={d}x{d} cell={d}x{d}", .{ pixel_width, pixel_height, self.config.cols, self.config.rows, self.cell_width_px, self.cell_height_px });
    }

    pub fn requestResize(self: *App, pixel_width: u32, pixel_height: u32) void {
        self.pending_width = pixel_width;
        self.pending_height = pixel_height;
        self.pending_resize = true;
    }

    pub fn sendPaste(self: *App, text: []const u8) !void {
        if (self.ghostty.?.terminalMode(self.terminal, .bracketed_paste)) {
            try self.sendText("\x1b[200~");
            try self.sendText(text);
            try self.sendText("\x1b[201~");
            return;
        }
        try self.sendText(text);
    }

    pub fn sendFocus(self: *App, gained: bool) !void {
        if (!self.ghostty.?.terminalMode(self.terminal, .focus_event)) return;
        var buf: [8]u8 = undefined;
        const bytes = self.ghostty.?.encodeFocus(if (gained) .gained else .lost, &buf) orelse return;
        try self.sendText(bytes);
    }

    pub fn sendKey(self: *App, key: ghostty.Key, mods: u32, text: ?[]const u8) !bool {
        var buf: [128]u8 = undefined;
        const consumed: u32 = if (text != null and (mods & ghostty.Mods.shift) != 0) ghostty.Mods.shift else ghostty.Mods.none;
        const bytes = self.ghostty.?.encodeKey(self.key_encoder, self.key_event, key, mods, .press, consumed, if (text) |t| firstCodepoint(t) else 0, text, &buf) orelse return false;
        try self.sendText(bytes);
        return true;
    }

    pub fn sendMouse(self: *App, action: ghostty.MouseAction, button: ?ghostty.MouseButton, x: f32, y: f32, mods: u32) !void {
        var buf: [128]u8 = undefined;
        const bytes = self.ghostty.?.encodeMouse(self.mouse_encoder, self.mouse_event, action, button, mods, .{ .x = x, .y = y }, &buf) orelse return;
        try self.sendText(bytes);
    }

    pub fn scroll(self: *App, delta: isize) void {
        self.ghostty.?.terminalScroll(self.terminal, delta);
    }

    pub fn hasLiveChild(self: *App) bool {
        if (self.pty) |*pty| return pty.isAlive();
        return false;
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

    fn refreshTitle(self: *App) void {
        if (self.title.len > 0) {
            self.allocator.free(self.title);
            self.title = &.{};
        }
        const maybe_title = self.ghostty.?.terminalTitle(self.allocator, self.terminal) catch null;
        if (maybe_title) |title| {
            self.title = title;
        } else {
            self.title = self.allocator.dupe(u8, self.config.windowTitle()) catch &.{};
        }
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

    fn recreateRenderHelpers(self: *App, runtime: *GhosttyRuntime) void {
        const new_render_state = runtime.createRenderState() catch |err| {
            std.log.err("app: recreate render_state failed: {s}", .{@errorName(err)});
            return;
        };
        errdefer runtime.freeRenderState(new_render_state);

        const new_row_iterator = runtime.createRowIterator() catch |err| {
            std.log.err("app: recreate row_iterator failed: {s}", .{@errorName(err)});
            return;
        };
        errdefer runtime.freeRowIterator(new_row_iterator);

        const new_row_cells = runtime.createRowCells() catch |err| {
            std.log.err("app: recreate row_cells failed: {s}", .{@errorName(err)});
            return;
        };

        runtime.freeRowCells(self.row_cells);
        runtime.freeRowIterator(self.row_iterator);
        runtime.freeRenderState(self.render_state);
        self.render_state = new_render_state;
        self.row_iterator = new_row_iterator;
        self.row_cells = new_row_cells;
    }

    fn sanitizePtyOutput(self: *App, bytes: []u8) []const u8 {
        if (!platform.isWindows()) return bytes;

        const enable = "\x1b[?9001h";
        const disable = "\x1b[?9001l";
        var combined_len: usize = self.pty_pending_len;
        if (combined_len > 0) {
            @memcpy(self.pty_sanitize_buf[0..combined_len], self.pty_pending_seq[0..combined_len]);
        }
        @memcpy(self.pty_sanitize_buf[combined_len .. combined_len + bytes.len], bytes);
        combined_len += bytes.len;

        var read_idx: usize = 0;
        var write_idx: usize = 0;
        while (read_idx < combined_len) {
            const remaining = self.pty_sanitize_buf[read_idx..combined_len];
            if (std.mem.startsWith(u8, remaining, enable)) {
                read_idx += enable.len;
                continue;
            }
            if (std.mem.startsWith(u8, remaining, disable)) {
                read_idx += disable.len;
                continue;
            }
            self.pty_sanitize_buf[write_idx] = self.pty_sanitize_buf[read_idx];
            read_idx += 1;
            write_idx += 1;
        }

        const tail_len = trailingWin32ModePrefixLen(self.pty_sanitize_buf[0..write_idx]);
        self.pty_pending_len = tail_len;
        if (tail_len > 0) {
            @memcpy(self.pty_pending_seq[0..tail_len], self.pty_sanitize_buf[write_idx - tail_len .. write_idx]);
            write_idx -= tail_len;
        }

        return self.pty_sanitize_buf[0..write_idx];
    }
};

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

fn trailingWin32ModePrefixLen(bytes: []const u8) usize {
    const enable = "\x1b[?9001h";
    const disable = "\x1b[?9001l";
    const max_check = @min(bytes.len, enable.len - 1);
    var prefix_len = max_check;
    while (prefix_len > 0) : (prefix_len -= 1) {
        if (std.mem.eql(u8, bytes[bytes.len - prefix_len ..], enable[0..prefix_len])) return prefix_len;
        if (std.mem.eql(u8, bytes[bytes.len - prefix_len ..], disable[0..prefix_len])) return prefix_len;
    }
    return 0;
}

fn writePtyCallback(_: ?*anyopaque, _: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void {
    const app = write_bridge orelse return;
    if (app.pty) |*pty| _ = pty.writeAll(bytes[0..len]) catch {};
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

fn titleChangedCallback(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const app = title_bridge orelse return;
    app.refreshTitle();
}
