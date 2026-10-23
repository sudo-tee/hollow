pub const LaunchCommand = struct {
    command: []const u8 = "",
    close_on_exit: bool = false,
    /// Execute directly, without a shell, expansion, or shell integration.
    argv: ?[]const []const u8 = null,
    /// A noninteractive shell command whose process exit preserves its result.
    one_shot: bool = false,
    user_shell: bool = false,

    /// Quote literal argv for an interactive target shell, never caller-side
    /// expansion. Fish accepts this concatenated single-quote form too.
    pub fn userShellCommand(self: LaunchCommand, a: @import("std").mem.Allocator, powershell: bool) ![]u8 {
        const std = @import("std");
        const args = self.argv orelse return a.dupe(u8, self.command);
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(a);
        try text.appendSlice(a, if (powershell) "&" else "exec");
        for (args) |arg| {
            try text.appendSlice(a, " '");
            for (arg) |ch| {
                if (ch == '\'') {
                    try text.appendSlice(a, if (powershell) "''" else "'\\''");
                } else if (ch == '\\' and !powershell) {
                    // Fish interprets backslashes inside single quotes; move
                    // each one outside quotes so POSIX shells and Fish agree.
                    try text.appendSlice(a, "'\\\\'");
                } else try text.append(a, ch);
            }
            try text.append(a, '\'');
        }
        if (powershell) try text.appendSlice(a, "; exit $LASTEXITCODE");
        return text.toOwnedSlice(a);
    }

    pub fn clone(self: LaunchCommand, a: @import("std").mem.Allocator) !LaunchCommand {
        var copy = self;
        copy.command = try a.dupe(u8, self.command);
        errdefer a.free(copy.command);
        if (self.argv) |args| {
            const owned = try a.alloc([]const u8, args.len);
            var count: usize = 0;
            errdefer {
                for (owned[0..count]) |arg| a.free(arg);
                a.free(owned);
            }
            for (args, 0..) |arg, i| {
                owned[i] = try a.dupe(u8, arg);
                count += 1;
            }
            copy.argv = owned;
        }
        return copy;
    }

    pub fn deinit(self: LaunchCommand, a: @import("std").mem.Allocator) void {
        a.free(self.command);
        if (self.argv) |args| {
            for (args) |arg| a.free(arg);
            a.free(args);
        }
    }
};

test "launch command clone owns literal argv and mode flags" {
    const std = @import("std");
    const a = std.testing.allocator;
    const source: LaunchCommand = .{ .argv = &.{ "demo", "$HOME; &", "" }, .one_shot = false };
    const owned = try source.clone(a);
    defer owned.deinit(a);
    try std.testing.expect(owned.argv.?.ptr != source.argv.?.ptr);
    try std.testing.expectEqualStrings("$HOME; &", owned.argv.?[1]);
    try std.testing.expectEqualStrings("", owned.argv.?[2]);
    try std.testing.expect(!owned.one_shot);
}
