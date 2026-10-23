//! Real terminal/mux background jobs, without window, GPU, Lua, or font libraries.
const std = @import("std");
const ghostty = @import("term/ghostty.zig");
const mux_mod = @import("mux.zig");
const Config = @import("config.zig").Config;
const io = @import("io.zig");

comptime {
    _ = @import("app/background_jobs.zig");
}

const Callbacks = struct {
    fn write(_: ?*anyopaque, _: ?*anyopaque, _: [*]const u8, _: usize) callconv(.c) void {}
    fn notify(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}
    fn string(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) ghostty.String {
        return .{ .ptr = null, .len = 0 };
    }
    fn size(_: ?*anyopaque, _: ?*anyopaque, _: *ghostty.SizeReportSize) callconv(.c) bool {
        return false;
    }
    fn color(_: ?*anyopaque, _: ?*anyopaque, _: *ghostty.ColorScheme) callconv(.c) bool {
        return false;
    }
    fn attributes(_: ?*anyopaque, _: ?*anyopaque, _: *ghostty.DeviceAttributes) callconv(.c) bool {
        return false;
    }
    const value: ghostty.TerminalCallbacks = .{ .write_pty = write, .bell = notify, .enquiry = string, .xtversion = string, .size = size, .color_scheme = color, .device_attributes = attributes, .title_changed = notify };
};

test "background jobs: launch preserves focus, drains output, retains failure, and cleanup preserves focus" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var config = Config.init(a);
    defer config.deinit();
    config.shell = try a.dupe(u8, "/bin/sh");
    var mux = mux_mod.Mux.init(a);
    defer mux.deinit(&runtime);
    try mux.bootstrapSingle(&runtime, Callbacks.value, config, 8, 16, 800, 600);
    const original_workspace = mux.activeWorkspace().?;
    const original_tab = mux.activeTab().?;
    const original_pane = mux.activePane().?;
    const SpawnObserver = struct {
        mux: *mux_mod.Mux,
        expected: *@import("pane.zig").Pane,
        changed: bool = false,
        calls: usize = 0,
        fn check(context: *anyopaque, _: std.mem.Allocator, _: *@import("pty/spawn_spec.zig").SpawnSpec) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            self.changed = self.changed or self.mux.activePane() != self.expected;
        }
    };
    var observer: SpawnObserver = .{ .mux = &mux, .expected = original_pane };
    mux.spawn_filter = .{ .context = &observer, .callback = SpawnObserver.check };
    const tab = try mux.newTabWithFocus(&runtime, Callbacks.value, config, 8, 16, 800, 600, "/", null, .{ .command = "printf 'retained failure\\n'; exit 7", .one_shot = true }, true, false);
    const pane = tab.activePane().?;
    pane.automation_token = "0123456789abcdef0123456789abcdef".*;
    try std.testing.expect(mux.activeWorkspace() == original_workspace);
    try std.testing.expect(mux.activeTab() == original_tab);
    try std.testing.expect(mux.activePane() == original_pane);
    try std.testing.expect(observer.calls > 0 and !observer.changed);
    try std.testing.expect(pane.retain_on_exit and pane.terminal_output_ready);
    const deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (pane.hasLiveChild() or pane.pty.?.jobOutputPending()) {
        _ = try pane.pollPty(&runtime, 16, 256 * 1024, 10 * std.time.ns_per_ms, 128 * 1024, false);
        if (io.nanoTimestamp() > deadline) return error.Timeout;
        try std.Io.sleep(io.get(), .fromMilliseconds(5), .awake);
    }
    try std.testing.expectEqual(@as(?u32, 7), pane.pty.?.exitStatus());
    const output = try pane.job_output.snapshot(a);
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "retained failure") != null);
    try std.testing.expect(!mux.closeDeadPanes(&runtime));
    try std.testing.expectEqual(@as(usize, 2), original_workspace.tabs.items.len);
    // A user may add a pane to a job's tab. Owned cleanup must not remove it.
    const sibling = try mux.createPane(&runtime, Callbacks.value, config, 8, 16, 800, 600, "/", null, null, null);
    try tab.splitActivePane(sibling, .vertical, 0.5);
    try std.testing.expect(!mux.closePaneByIdWithFocus(&runtime, @intFromPtr(pane), false));
    try std.testing.expect(mux.activePane() == original_pane);
    try std.testing.expect(mux.activeTab() == original_tab);
    try std.testing.expect(tab.activePane() == sibling);
    try std.testing.expectEqual(@as(usize, 2), original_workspace.tabs.items.len);
    try std.testing.expect(!mux.closePaneByIdWithFocus(&runtime, @intFromPtr(sibling), false));
    try std.testing.expectEqual(@as(usize, 1), original_workspace.tabs.items.len);
}

test "background jobs: native argv preserves literal bytes and empty arguments without shell expansion" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const Pty = @import("pty/pty_posix.zig").PosixPty;
    var pty = try Pty.spawn(std.testing.allocator, "/bin/sh", 80, 24, "/", null, .{ .argv = &.{ "/usr/bin/printf", "<%s>\\n", "$HOME; & *", "" } }, .{});
    defer pty.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    const deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (true) {
        var buffer: [4096]u8 = undefined;
        const n = try pty.read(&buffer);
        try output.appendSlice(std.testing.allocator, buffer[0..n]);
        if (!pty.isAlive() and std.mem.indexOf(u8, output.items, "<>\r\n") != null) break;
        if (io.nanoTimestamp() > deadline) return error.Timeout;
        try std.Io.sleep(io.get(), .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(std.mem.indexOf(u8, output.items, "<$HOME; & *>\r\n<>\r\n") != null);
    try std.testing.expectEqual(@as(?u32, 0), pty.exitStatus());
}

test "background jobs: cleanup in another workspace preserves current workspace and tab" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var config = Config.init(a);
    defer config.deinit();
    config.shell = try a.dupe(u8, "/bin/sh");
    var mux = mux_mod.Mux.init(a);
    defer mux.deinit(&runtime);
    try mux.bootstrapSingle(&runtime, Callbacks.value, config, 8, 16, 800, 600);
    const original = mux.activePane().?;
    const original_tab = mux.activeTab().?;
    try mux.newWorkspace(&runtime, Callbacks.value, config, 8, 16, 800, 600, null, null, null, null);
    const other = mux.activeWorkspace().?;
    const user_tab = mux.activeTab().?;
    const job_tab = try mux.newTabWithFocus(&runtime, Callbacks.value, config, 8, 16, 800, 600, null, null, .{ .command = "true", .one_shot = true }, true, false);
    const job = job_tab.activePane().?;
    mux.switchWorkspace(0);
    try std.testing.expect(!mux.closePaneByIdWithFocus(&runtime, @intFromPtr(job), false));
    try std.testing.expect(mux.activePane() == original);
    try std.testing.expect(mux.activeTab() == original_tab);
    try std.testing.expect(other.activeTab() == user_tab);
    try std.testing.expectEqual(@as(usize, 1), other.tabs.items.len);
}

test "background jobs: user shell loads startup environment and preserves literal argv" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io.get(), .{ .sub_path = ".bashrc", .data = "export HOLLOW_JOB_STARTUP=loaded\n" });
    const home = try tmp.dir.realPathFileAlloc(io.get(), ".", a);
    defer a.free(home);
    const env = try std.fmt.allocPrint(a, "HOME={s}\x00\x00", .{home});
    defer a.free(env);
    var pty = try @import("pty/pty_posix.zig").PosixPty.spawn(a, "/bin/bash", 80, 24, "/", env, .{
        .argv = &.{ "/bin/sh", "-c", "printf '<%s>\\n' \"$HOLLOW_JOB_STARTUP\" \"$@\"; exit 7", "job", "$HOME; & *", "quote'\\tail", "" },
        .one_shot = true,
        .user_shell = true,
    }, .{});
    defer pty.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(a);
    const deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (true) {
        var buffer: [4096]u8 = undefined;
        const n = try pty.read(&buffer);
        try output.appendSlice(a, buffer[0..n]);
        if (!pty.isAlive() and pty.outputDrained()) break;
        if (io.nanoTimestamp() > deadline) return error.Timeout;
        try std.Io.sleep(io.get(), .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(std.mem.indexOf(u8, output.items, "<loaded>\r\n<$HOME; & *>\r\n<quote'\\tail>\r\n<>\r\n") != null);
    try std.testing.expectEqual(@as(?u32, 7), pty.exitStatus());
}
