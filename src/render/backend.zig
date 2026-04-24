const config = @import("../config.zig");
const std = @import("std");
const ghostty = @import("../term/ghostty.zig");
const DebugBackend = @import("debug_backend.zig").DebugBackend;
const NullBackend = @import("null_backend.zig").NullBackend;

pub const Backend = union(enum) {
    null: NullBackend,
    debug: DebugBackend,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) Backend {
        return switch (cfg.backend) {
            .null => .{ .null = NullBackend.init(cfg.backend) },
            .sokol, .webgpu => .{ .debug = DebugBackend.init(allocator, cfg) },
        };
    }

    pub fn deinit(self: *Backend) void {
        switch (self.*) {
            .null => |*backend| backend.deinit(),
            .debug => |*backend| backend.deinit(),
        }
    }

    pub fn activeName(self: Backend) []const u8 {
        return switch (self) {
            .null => |backend| backend.activeName(),
            .debug => |backend| backend.activeName(),
        };
    }

    pub fn requestedName(self: Backend) []const u8 {
        return switch (self) {
            .null => |backend| backend.requestedName(),
            .debug => |backend| backend.requestedName(),
        };
    }

    pub fn fillSnapshot(self: *Backend, runtime: *ghostty.Runtime, render_state: ?*anyopaque, row_iterator: *?*anyopaque, row_cells: *?*anyopaque, cfg: config.Config, title: []const u8) ?@import("debug_backend.zig").FrameSnapshot {
        return switch (self.*) {
            .null => null,
            .debug => |*backend| backend.fillSnapshot(runtime, render_state, row_iterator, row_cells, cfg, title),
        };
    }
};
