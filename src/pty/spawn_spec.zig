const std = @import("std");

pub fn isWsl(shell: []const u8) bool {
    const trimmed = std.mem.trim(u8, shell, " \t");
    if (trimmed.len == 0) return false;
    const quoted = trimmed[0] == '"' or trimmed[0] == '\'';
    const start: usize = if (quoted) 1 else 0;
    const end = if (quoted)
        std.mem.indexOfScalarPos(u8, trimmed, start, trimmed[0]) orelse trimmed.len
    else
        std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    const program = trimmed[start..end];
    const base = if (std.mem.lastIndexOfAny(u8, program, "/\\")) |index| program[index + 1 ..] else program;
    return std.ascii.eqlIgnoreCase(base, "wsl") or std.ascii.eqlIgnoreCase(base, "wsl.exe");
}

/// Borrowed launch data; filter replacements live in the bootstrap arena.
pub const SpawnSpec = struct {
    shell: []const u8,
    domain: ?[]const u8,
    cwd: ?[]const u8,
    env_block: []const u8,
};

pub const Filter = struct {
    context: ?*anyopaque = null,
    callback: ?*const fn (*anyopaque, std.mem.Allocator, *SpawnSpec) anyerror!void = null,

    pub fn apply(self: Filter, allocator: std.mem.Allocator, spec: *SpawnSpec) !void {
        const context = self.context orelse return;
        if (self.callback) |callback| try callback(context, allocator, spec);
    }
};

test "WSL launchers are distinguished from native local shells" {
    try std.testing.expect(isWsl("wsl.exe -d Ubuntu"));
    try std.testing.expect(isWsl("\"C:\\Windows\\System32\\WSL.EXE\" -d Ubuntu"));
    try std.testing.expect(isWsl("/mnt/c/Windows/System32/wsl.exe"));
    try std.testing.expect(!isWsl("/bin/zsh -l"));
    try std.testing.expect(!isWsl("pwsh.exe"));
}
