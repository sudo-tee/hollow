const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform.zig");

pub const Pty = switch (builtin.os.tag) {
    .windows => @import("pty_windows.zig").WindowsPty,
    else => @import("pty_posix.zig").PosixPty,
};

pub fn spawn(allocator: std.mem.Allocator, shell: [:0]const u8, cols: u16, rows: u16) !Pty {
    return switch (builtin.os.tag) {
        .windows => Pty.spawnWithFallbacks(allocator, shell, cols, rows, platform.windowsShellCandidates()),
        else => Pty.spawn(allocator, shell, cols, rows),
    };
}
