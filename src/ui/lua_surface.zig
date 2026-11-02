//! State owned by a GUI-only Lua pane. Terminal resources never live here.
const std = @import("std");

pub const LuaSurface = struct {
    ref: c_int = -1,
    dirty: bool = true,
    hovered_id: ?[]u8 = null,
    context: ?*anyopaque = null,
    /// The host releases its Lua reference and runs unmount before storage dies.
    on_deinit: ?*const fn (*LuaSurface) void = null,

    pub fn deinit(self: *LuaSurface, allocator: std.mem.Allocator) void {
        if (self.on_deinit) |callback| {
            self.on_deinit = null;
            callback(self);
        }
        if (self.hovered_id) |id| allocator.free(id);
        self.* = .{};
    }
};

test "Lua surface releases its host reference and hover storage exactly once" {
    const Host = struct {
        calls: usize = 0,
        fn release(surface: *LuaSurface) void {
            const self: *@This() = @ptrCast(@alignCast(surface.context.?));
            std.debug.assert(surface.ref == 42);
            self.calls += 1;
        }
    };
    const allocator = std.testing.allocator;
    var host: Host = .{};
    var surface: LuaSurface = .{
        .ref = 42,
        .context = &host,
        .on_deinit = Host.release,
        .hovered_id = try allocator.dupe(u8, "pane:1:button"),
    };
    surface.deinit(allocator);
    surface.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), host.calls);
    try std.testing.expect(surface.hovered_id == null);
}
