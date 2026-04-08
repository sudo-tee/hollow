// See build.zig and build.zig.zon.
const zluajit = @import("zluajit");

pub fn main() !void {
    // Create a new Lua state.
    const state = try zluajit.State.init(.{});
    // Clean up resources before exiting.
    defer state.deinit();

    // Load Lua standard libraries.
    state.openLibs();

    // Parse, load and execute Lua code.
    try state.doString("print 'Hello from Lua'", null);
}
