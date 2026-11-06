const std = @import("std");
const io = @import("io.zig");
const platform = @import("platform.zig");

/// Native normal-window bounds, not framebuffer dimensions or minimized bounds.
pub const State = struct {
    version: u32 = 1,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    maximized: bool,

    pub fn valid(self: State) bool {
        return self.version == 1 and
            self.width > 0 and self.width <= 100_000 and
            self.height > 0 and self.height <= 100_000 and
            self.x >= -1_000_000 and self.x <= 1_000_000 and
            self.y >= -1_000_000 and self.y <= 1_000_000;
    }
};

fn decode(allocator: std.mem.Allocator, bytes: []const u8) !State {
    const parsed = try std.json.parseFromSlice(State, allocator, bytes, .{});
    defer parsed.deinit();
    if (!parsed.value.valid()) return error.InvalidWindowPlacement;
    return parsed.value;
}

pub fn load() ?State {
    const allocator = std.heap.page_allocator;
    const dir = platform.userDataDir(allocator) catch return null;
    defer allocator.free(dir);
    const path = std.fs.path.join(allocator, &.{ dir, "window-placement.json" }) catch return null;
    defer allocator.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io.get(), path, allocator, .limited(1024)) catch return null;
    defer allocator.free(bytes);
    return decode(allocator, bytes) catch null;
}

pub fn save(state: State) !void {
    if (!state.valid()) return error.InvalidWindowPlacement;
    const allocator = std.heap.page_allocator;
    const dir = try platform.userDataDir(allocator);
    defer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(io.get(), dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "window-placement.json" });
    defer allocator.free(path);
    const bytes = try std.json.Stringify.valueAlloc(allocator, state, .{});
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io.get(), .{ .sub_path = path, .data = bytes });
}

test "window placement round trips negative monitor coordinates and maximized state" {
    const state: State = .{ .x = -1920, .y = -200, .width = 1280, .height = 800, .maximized = true };
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, state, .{});
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualDeep(state, try decode(std.testing.allocator, bytes));
}

test "window placement rejects corrupt, invalid, and unsupported state" {
    try std.testing.expectError(error.UnexpectedEndOfInput, decode(std.testing.allocator, "{"));
    try std.testing.expectError(error.InvalidWindowPlacement, decode(std.testing.allocator,
        \\{"x":0,"y":0,"width":0,"height":800,"maximized":false}
    ));
    try std.testing.expectError(error.InvalidWindowPlacement, decode(std.testing.allocator,
        \\{"version":2,"x":0,"y":0,"width":1280,"height":800,"maximized":false}
    ));
}
