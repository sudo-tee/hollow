const config = @import("../config.zig");

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
};
