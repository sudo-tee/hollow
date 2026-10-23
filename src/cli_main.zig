//! Standalone CLI entry point. No terminal engine, renderer, Lua, or agent RPC.
const std = @import("std");
const io = @import("io.zig");
// Transport warnings belong to diagnostics, not the structured CLI error stream.
pub const std_options: std.Options = .{ .log_level = .err };

pub fn main(init: std.process.Init) !void {
    io.init(init.io, init.minimal.environ);
    const allocator = init.gpa;
    const args = try io.argsAlloc(allocator, init.minimal.args);
    defer io.argsFree(allocator, args);
    const status = @import("native_cli.zig").run(allocator, args[1..]);
    if (status != 0) std.process.exit(status);
}
