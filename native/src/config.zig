const std = @import("std");
const platform = @import("platform.zig");

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
    allocator: std.mem.Allocator,
    backend: RendererBackend = .sokol,
    shell: ?[]u8 = null,
    ghostty_library: ?[]u8 = null,
    luajit_library: ?[]u8 = null,
    font_size: f32 = 15,
    window_title: ?[]u8 = null,
    window_width: u32 = 1280,
    window_height: u32 = 800,
    cols: u16 = 120,
    rows: u16 = 34,
    scrollback: u32 = 10000,
    lib_dir: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Config) void {
        freeOwned(self.allocator, &self.shell);
        freeOwned(self.allocator, &self.ghostty_library);
        freeOwned(self.allocator, &self.luajit_library);
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
