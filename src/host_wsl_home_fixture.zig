//! Test-only Windows launcher: forward WSL argv, injecting an owned temporary HOME.
//! Never shipped or used by production connector defaults. No protocol handling.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(a);
    const home = try init.minimal.environ.getAlloc(a, "HOLLOW_TEST_WSL_HOME");
    const prefix = "/tmp/hollow-wsl-home-";
    if (!std.mem.startsWith(u8, home, prefix) or home.len != prefix.len + 12) return error.InvalidFixtureHome;
    for (home[prefix.len..]) |byte| if (!std.ascii.isAlphanumeric(byte)) return error.InvalidFixtureHome;
    const root = try init.minimal.environ.getAlloc(a, "SystemRoot");
    const wsl = try std.fs.path.join(a, &.{ root, "System32", "wsl.exe" });
    var argv: std.array_list.Managed([]const u8) = .init(a);
    try argv.append(wsl);
    var inserted = false;
    for (args[1..]) |arg| {
        try argv.append(arg);
        if (!inserted and std.mem.eql(u8, arg, "--exec")) {
            try argv.appendSlice(&.{ "/usr/bin/env", try std.fmt.allocPrint(a, "HOME={s}", .{home}) });
            inserted = true;
        }
    }
    if (!inserted) return error.MissingExec;
    var child = try std.process.spawn(init.io, .{ .argv = argv.items, .stdin = .inherit, .stdout = .inherit, .stderr = .inherit, .create_no_window = true });
    const term = try child.wait(init.io);
    std.process.exit(switch (term) {
        .exited => |code| code,
        else => 125,
    });
}
