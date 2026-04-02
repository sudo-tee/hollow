const std = @import("std");
const platform = @import("platform.zig");
const ghostty = @import("term/ghostty.zig");

pub const RendererBackend = enum {
    null,
    sokol,
    webgpu,

    pub fn asString(self: RendererBackend) []const u8 {
        return switch (self) {
            .null => "null",
            .sokol => "sokol",
            .webgpu => "webgpu",
        };
    }
};

pub const Config = struct {
    pub const Fonts = struct {
        pub const Smoothing = enum {
            grayscale,
            subpixel,
        };

        pub const Hinting = enum {
            none,
            light,
            normal,
        };

        size: f32 = 15,
        padding_x: f32 = 0,
        padding_y: f32 = 0,
        coverage_boost: f32 = 1.0,
        coverage_add: f32 = 0.0,
        smoothing: Smoothing = .grayscale,
        hinting: Hinting = .normal,
        ligatures: bool = true,
        embolden: f32 = 0.0,
        regular: ?[]u8 = null,
        bold: ?[]u8 = null,
        italic: ?[]u8 = null,
        bold_italic: ?[]u8 = null,
        fallback_paths: std.ArrayListUnmanaged([]u8) = .{},

        pub fn deinit(self: *Fonts, allocator: std.mem.Allocator) void {
            freeOwned(allocator, &self.regular);
            freeOwned(allocator, &self.bold);
            freeOwned(allocator, &self.italic);
            freeOwned(allocator, &self.bold_italic);
            for (self.fallback_paths.items) |path| allocator.free(path);
            self.fallback_paths.deinit(allocator);
            self.* = .{};
        }
    };

    allocator: std.mem.Allocator,
    backend: RendererBackend = .sokol,
    shell: ?[]u8 = null,
    ghostty_library: ?[]u8 = null,
    luajit_library: ?[]u8 = null,
    fonts: Fonts = .{},
    window_title: ?[]u8 = null,
    window_width: u32 = 1280,
    window_height: u32 = 800,
    cols: u16 = 120,
    rows: u16 = 34,
    scrollback: u32 = 10000,
    lib_dir: ?[]u8 = null,
    top_bar_show: bool = true,
    window_titlebar_show: bool = true,
    top_bar_show_when_single_tab: bool = false,
    top_bar_height: u32 = 0,
    top_bar_bg: ghostty.ColorRgb = .{ .r = 28, .g = 30, .b = 38 },
    top_bar_draw_tabs: bool = true,
    top_bar_draw_status: bool = true,
    debug_overlay: bool = false,
    vsync: bool = true,
    /// Frame cap used when vsync is disabled. Set to 0 to leave the render
    /// loop uncapped.
    max_fps: u32 = 120,
    /// Allow single-pane mode to skip the offscreen render-target cache and
    /// render directly into the swapchain.  Defaulting to false preserves the
    /// cached-RT path which gives smoother frame pacing.  Set to true to
    /// opt back into the lower-latency but burstier direct-render path.
    renderer_single_pane_direct: bool = false,
    /// Multiplier applied to raw wheel/touchpad scroll delta before
    /// accumulation into whole-line steps.  1.0 is the neutral value; the
    /// old hard-coded value was 2.0.
    scroll_multiplier: f32 = 1.0,

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Config) void {
        freeOwned(self.allocator, &self.shell);
        freeOwned(self.allocator, &self.ghostty_library);
        freeOwned(self.allocator, &self.luajit_library);
        self.fonts.deinit(self.allocator);
        freeOwned(self.allocator, &self.window_title);
        freeOwned(self.allocator, &self.lib_dir);
    }

    pub fn shellOrDefault(self: Config) []const u8 {
        return self.shell orelse platform.defaultShell();
    }

    pub fn windowTitle(self: Config) []const u8 {
        return self.window_title orelse "hollow";
    }

    pub fn ghosttyLibrary(self: Config) ?[]const u8 {
        return self.ghostty_library;
    }

    pub fn luajitLibrary(self: Config) ?[]const u8 {
        return self.luajit_library;
    }

    pub fn setBackend(self: *Config, value: []const u8) !void {
        if (std.ascii.eqlIgnoreCase(value, "null")) {
            self.backend = .null;
            return;
        }

        if (std.ascii.eqlIgnoreCase(value, "sokol")) {
            self.backend = .sokol;
            return;
        }

        if (std.ascii.eqlIgnoreCase(value, "webgpu")) {
            self.backend = .webgpu;
            return;
        }

        return error.InvalidBackend;
    }

    pub fn setShell(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.shell, value);
    }

    pub fn setGhosttyLibrary(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.ghostty_library, value);
    }

    pub fn setLuajitLibrary(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.luajit_library, value);
    }

    pub fn setWindowTitle(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.window_title, value);
    }

    pub fn setLibDir(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.lib_dir, value);
    }

    pub fn setFontRegular(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.fonts.regular, value);
    }

    pub fn setFontBold(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.fonts.bold, value);
    }

    pub fn setFontItalic(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.fonts.italic, value);
    }

    pub fn setFontBoldItalic(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.fonts.bold_italic, value);
    }

    pub fn clearFontFallbacks(self: *Config) void {
        for (self.fonts.fallback_paths.items) |path| self.allocator.free(path);
        self.fonts.fallback_paths.clearRetainingCapacity();
    }

    pub fn addFontFallback(self: *Config, value: []const u8) !void {
        try self.fonts.fallback_paths.append(self.allocator, try self.allocator.dupe(u8, value));
    }

    pub fn setFontSmoothing(self: *Config, value: []const u8) !void {
        if (std.ascii.eqlIgnoreCase(value, "grayscale")) {
            self.fonts.smoothing = .grayscale;
            return;
        }
        if (std.ascii.eqlIgnoreCase(value, "subpixel") or std.ascii.eqlIgnoreCase(value, "lcd")) {
            self.fonts.smoothing = .subpixel;
            return;
        }
        return error.InvalidFontSmoothing;
    }

    pub fn setFontHinting(self: *Config, value: []const u8) !void {
        if (std.ascii.eqlIgnoreCase(value, "none")) {
            self.fonts.hinting = .none;
            return;
        }
        if (std.ascii.eqlIgnoreCase(value, "light")) {
            self.fonts.hinting = .light;
            return;
        }
        if (std.ascii.eqlIgnoreCase(value, "normal")) {
            self.fonts.hinting = .normal;
            return;
        }
        return error.InvalidFontHinting;
    }
};

fn replaceOwned(allocator: std.mem.Allocator, slot: *?[]u8, value: []const u8) !void {
    freeOwned(allocator, slot);
    slot.* = try allocator.dupe(u8, value);
}

fn freeOwned(allocator: std.mem.Allocator, slot: *?[]u8) void {
    if (slot.*) |owned| {
        allocator.free(owned);
        slot.* = null;
    }
}

test "backend parsing covers planned renderers" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    try cfg.setBackend("webgpu");
    try std.testing.expectEqual(RendererBackend.webgpu, cfg.backend);

    try cfg.setBackend("sokol");
    try std.testing.expectEqual(RendererBackend.sokol, cfg.backend);
}
