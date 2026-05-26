const config = @import("../config.zig");
const Pane = @import("../pane.zig").Pane;

pub const NullBackend = struct {
    requested: config.RendererBackend,

    pub fn init(requested: config.RendererBackend) NullBackend {
        return .{ .requested = requested };
    }

    pub fn activeName(self: NullBackend) []const u8 {
        _ = self;
        return "bootstrap";
    }

    pub fn requestedName(self: NullBackend) []const u8 {
        return self.requested.asString();
    }

    pub fn deinit(self: *NullBackend) void {
        _ = self;
    }

    pub fn invalidatePaneCache(self: *NullBackend, pane: *const Pane) void {
        _ = self;
        _ = pane;
    }
};
