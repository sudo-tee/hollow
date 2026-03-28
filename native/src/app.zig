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
    read_buf: [4096]u8 = [_]u8{0} ** 4096,
    frame_count: usize = 0,
    logged_first_pty_read: bool = false,
    logged_first_render_update: bool = false,
    sent_win32_input_disable: bool = false,

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
            .cell_width = 8,
            .cell_height = 16,
            .padding_top = 0,
            .padding_bottom = 0,
            .padding_left = 0,
            .padding_right = 0,
        });
        self.ghostty.?.resizeTerminal(self.terminal, self.config.cols, self.config.rows, 8, 16);
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
        if (self.pty) |*pty| {
            if (pty.isAlive()) {
                const count = try pty.read(&self.read_buf);
                if (count > 0) {
                    if (!self.logged_first_pty_read) {
                        self.logged_first_pty_read = true;
                        std.log.info("first PTY bytes received count={d}", .{count});
                    }
                    self.ghostty.?.terminalWrite(self.terminal, self.read_buf[0..count]);
                    self.ghostty.?.syncKeyEncoder(self.key_encoder, self.terminal);
                    self.ghostty.?.syncMouseEncoder(self.mouse_encoder, self.terminal);

                    // On the first real PTY read, disable Win32 input mode (?9001h).
                    // wsl.exe / zsh send ESC[?9001h on startup expecting Win32 INPUT_RECORD
                    // structures.  Since we don't support that, we immediately reply with
                    // ESC[?9001l (disable) so the shell falls back to raw VT input.
                    if (!self.sent_win32_input_disable) {
                        self.sent_win32_input_disable = true;
                        const disable_win32_input = "\x1b[?9001l";
                        pty.writeAll(disable_win32_input) catch |err| {
                            std.log.err("app: failed to send ?9001l: {s}", .{@errorName(err)});
                        };
                        std.log.info("app: sent ESC[?9001l to disable Win32 input mode", .{});
                    }
                }
            }
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
        if (self.ghostty) |*runtime| {
            runtime.resizeTerminal(self.terminal, self.config.cols, self.config.rows, cell_w, cell_h);
            runtime.setMouseEncoderSize(self.mouse_encoder, .{
                .size = @sizeOf(ghostty.MouseEncoderSize),
                .screen_width = self.config.window_width,
                .screen_height = self.config.window_height,
                .cell_width = cell_w,
                .cell_height = cell_h,
                .padding_top = 0,
                .padding_bottom = 0,
                .padding_left = 0,
                .padding_right = 0,
            });
        }
        if (self.pty) |*pty| pty.resize(self.config.cols, self.config.rows);
        std.log.info("app: cell_size updated cell={d}x{d}", .{ cell_w, cell_h });
    }

    pub fn resize(self: *App, pixel_width: u32, pixel_height: u32) void {
        self.config.window_width = pixel_width;
        self.config.window_height = pixel_height;

        const cell_w: u32 = @max(8, pixel_width / @max(1, self.config.cols));
        const cell_h: u32 = @max(16, pixel_height / @max(1, self.config.rows));

        if (self.ghostty) |*runtime| {
            runtime.resizeTerminal(self.terminal, self.config.cols, self.config.rows, cell_w, cell_h);
            runtime.setMouseEncoderSize(self.mouse_encoder, .{
                .size = @sizeOf(ghostty.MouseEncoderSize),
                .screen_width = pixel_width,
                .screen_height = pixel_height,
                .cell_width = cell_w,
                .cell_height = cell_h,
                .padding_top = 0,
                .padding_bottom = 0,
                .padding_left = 0,
                .padding_right = 0,
            });
        }

        if (self.pty) |*pty| pty.resize(self.config.cols, self.config.rows);
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

fn writePtyCallback(_: ?*anyopaque, _: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void {
    const app = write_bridge orelse return;
    if (len > 0) {
        // Log first 32 bytes as hex for debugging
        const show = @min(len, 32);
        var hex: [96]u8 = undefined;
        var hi: usize = 0;
        for (bytes[0..show]) |b| {
            const nib = "0123456789abcdef";
            hex[hi] = nib[b >> 4];
            hex[hi + 1] = nib[b & 0xf];
            hex[hi + 2] = ' ';
            hi += 3;
        }
        std.log.info("writePtyCallback: {d} bytes -> {s}", .{ len, hex[0..hi] });
    }
    if (app.pty) |*pty| _ = pty.writeAll(bytes[0..len]) catch {};
}

fn sizeCallback(_: ?*anyopaque, _: ?*anyopaque, out: *ghostty.SizeReportSize) callconv(.c) bool {
    const app = size_bridge orelse return false;
    out.rows = app.config.rows;
    out.columns = app.config.cols;
    out.cell_width = 8;
    out.cell_height = 16;
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
