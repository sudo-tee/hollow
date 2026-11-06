//! Real ConPTY tests, independent of the GUI and Linux guest agent.
const std = @import("std");
const windows = std.os.windows;
const io = @import("io.zig");
const WindowsPty = @import("pty/pty_windows.zig").WindowsPty;
const windows_job = @import("pty/windows_job.zig");
const testing = std.testing;

extern "kernel32" fn OpenProcess(access: windows.DWORD, inherit: windows.BOOL, pid: windows.DWORD) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;
extern "kernel32" fn IsProcessInJob(process: windows.HANDLE, job: ?windows.HANDLE, result: *windows.BOOL) callconv(.winapi) windows.BOOL;
extern "kernel32" fn TerminateProcess(process: windows.HANDLE, code: windows.UINT) callconv(.winapi) windows.BOOL;
extern "kernel32" fn Sleep(milliseconds: windows.DWORD) callconv(.winapi) void;

const wait_object_0 = 0;
const wait_timeout = 258;
const timeout_ns = 20 * std.time.ns_per_s;

fn spawn(command: []const u8, session: bool) !WindowsPty {
    const args = &.{ "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command };
    const launch = @import("pty/launch_command.zig").LaunchCommand{ .argv = args };
    if (session) return WindowsPty.spawnSession(testing.allocator, "powershell.exe", 120, 30, null, null, launch, .{});
    return WindowsPty.spawn(testing.allocator, "powershell.exe", 120, 30, null, null, launch, .{});
}

fn openProcess(pid: windows.DWORD) !windows.HANDLE {
    // Keep independent handles valid after WindowsPty.close releases its own.
    return OpenProcess(0x00100000 | 0x1000 | 0x0001, .FALSE, pid) orelse error.OpenProcessFailed;
}

fn expectMembership(process: windows.HANDLE, job: windows.HANDLE, expected: bool) !void {
    var member: windows.BOOL = .FALSE;
    try testing.expect(IsProcessInJob(process, job, &member).toBool());
    try testing.expectEqual(expected, member.toBool());
}

const Tree = struct {
    pty: WindowsPty,
    parent: windows.HANDLE,
    child: windows.HANDLE,

    fn init() !Tree {
        // Use the installed Windows PowerShell, not pwsh or external utilities.
        // Disable ShellExecute so this is a direct child, not a broker launch.
        var pty = try spawn(
            "$info = New-Object System.Diagnostics.ProcessStartInfo; $info.FileName = $PSHOME + '\\powershell.exe'; $info.Arguments = '-NoProfile -NonInteractive -Command \"Start-Sleep -Seconds 120\"'; $info.UseShellExecute = $false; $child = [System.Diagnostics.Process]::Start($info); Write-Output ('HOLLOW_CHILD=' + $child.Id + ';'); Start-Sleep -Seconds 120",
            true,
        );
        errdefer pty.close();
        const parent = try openProcess(pty.process_id);
        errdefer _ = CloseHandle(parent);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(testing.allocator);
        const deadline = io.nanoTimestamp() + timeout_ns;
        while (io.nanoTimestamp() < deadline) {
            var buffer: [4096]u8 = undefined;
            const n = try pty.read(&buffer);
            try output.appendSlice(testing.allocator, buffer[0..n]);
            if (output.items.len > 64 * 1024) return error.OutputLimitExceeded;
            if (std.mem.indexOf(u8, output.items, "HOLLOW_CHILD=")) |start| {
                const suffix = output.items[start + "HOLLOW_CHILD=".len ..];
                if (std.mem.indexOfScalar(u8, suffix, ';')) |end| {
                    const pid = try std.fmt.parseInt(windows.DWORD, suffix[0..end], 10);
                    const child = try openProcess(pid);
                    errdefer _ = CloseHandle(child);
                    try testing.expectEqual(wait_timeout, WaitForSingleObject(parent, 0));
                    try testing.expectEqual(wait_timeout, WaitForSingleObject(child, 0));
                    return .{ .pty = pty, .parent = parent, .child = child };
                }
            }
            if (!pty.isAlive()) return error.ParentExitedBeforeChildReady;
            Sleep(10);
        }
        return error.ChildStartupTimeout;
    }

    fn deinit(self: *Tree) void {
        self.pty.close();
        // Also clean up when a membership assertion exposes a broken backend.
        _ = TerminateProcess(self.child, 1);
        _ = TerminateProcess(self.parent, 1);
        _ = CloseHandle(self.child);
        _ = CloseHandle(self.parent);
    }

    fn expectStopped(self: *Tree) !void {
        try testing.expectEqual(wait_object_0, WaitForSingleObject(self.parent, 10_000));
        try testing.expectEqual(wait_object_0, WaitForSingleObject(self.child, 10_000));
    }
};

test "session ConPTY close kills parent and descendant and is idempotent" {
    var tree = try Tree.init();
    defer tree.deinit();
    try testing.expect(tree.pty.job != null);
    const job = tree.pty.job.?.handle.?;
    try expectMembership(tree.parent, job, true);
    try expectMembership(tree.child, job, true);
    tree.pty.close();
    tree.pty.close();
    try tree.expectStopped();
    try testing.expect(!tree.pty.isAlive());
}

test "closing one session job does not terminate another session tree" {
    var first = try Tree.init();
    defer first.deinit();
    var second = try Tree.init();
    defer second.deinit();
    const first_job = first.pty.job.?.handle.?;
    const second_job = second.pty.job.?.handle.?;
    try testing.expect(first_job != second_job);
    try expectMembership(first.parent, first_job, true);
    try expectMembership(first.child, first_job, true);
    try expectMembership(second.parent, second_job, true);
    try expectMembership(second.child, second_job, true);
    try expectMembership(second.parent, first_job, false);
    try expectMembership(second.child, first_job, false);
    first.pty.close();
    try first.expectStopped();
    try testing.expectEqual(wait_timeout, WaitForSingleObject(second.parent, 0));
    try testing.expectEqual(wait_timeout, WaitForSingleObject(second.child, 0));
    second.pty.close();
    second.pty.close();
    try second.expectStopped();
}

test "session ConPTY retains finite output and exit status until close" {
    var pty = try spawn("Write-Output 'HOLLOW_FINITE_OUTPUT'; exit 7", true);
    defer pty.close();
    try testing.expect(pty.job != null);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(testing.allocator);
    const deadline = io.nanoTimestamp() + timeout_ns;
    while (io.nanoTimestamp() < deadline) {
        var buffer: [4096]u8 = undefined;
        const n = try pty.read(&buffer);
        try output.appendSlice(testing.allocator, buffer[0..n]);
        if (output.items.len > 64 * 1024) return error.OutputLimitExceeded;
        if (!pty.isAlive() and std.mem.indexOf(u8, output.items, "HOLLOW_FINITE_OUTPUT") != null) break;
        Sleep(10);
    }
    try testing.expect(!pty.isAlive());
    try testing.expect(std.mem.indexOf(u8, output.items, "HOLLOW_FINITE_OUTPUT") != null);
    try testing.expectEqual(@as(?u32, 7), pty.exitStatus());
    try testing.expect(!pty.isAlive());
    try testing.expectEqual(@as(?u32, 7), pty.exitStatus());
    pty.close();
    pty.close();
    try testing.expectEqual(@as(?u32, 7), pty.exitStatus());
}

test "ordinary ConPTY spawn does not acquire a session job" {
    var pty = try spawn("Write-Output 'HOLLOW_ORDINARY'; exit 0", false);
    defer pty.close();
    try testing.expect(pty.job == null);
}

test "session ConPTY accepts input before its application prints output" {
    var pty = try spawn("$line = [Console]::ReadLine(); Write-Output ('HOLLOW_INPUT=' + $line); exit 9", true);
    defer pty.close();
    const oversized = try testing.allocator.alloc(u8, 1024 * 1024 + 1);
    defer testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try testing.expectError(error.ResourceExhausted, pty.writeAll(oversized));
    try testing.expect(pty.isAlive());
    // Submit immediately: this application cannot print its result until input
    // arrives, unlike an interactive shell that emits a prompt first.
    try pty.writeAll("session-input\r\n");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(testing.allocator);
    const deadline = io.nanoTimestamp() + timeout_ns;
    while (io.nanoTimestamp() < deadline) {
        var buffer: [4096]u8 = undefined;
        const n = try pty.read(&buffer);
        try output.appendSlice(testing.allocator, buffer[0..n]);
        if (output.items.len > 64 * 1024) return error.OutputLimitExceeded;
        if (!pty.isAlive() and std.mem.indexOf(u8, output.items, "HOLLOW_INPUT=session-input") != null) break;
        Sleep(10);
    }
    try testing.expect(!pty.isAlive());
    try testing.expect(std.mem.indexOf(u8, output.items, "HOLLOW_INPUT=session-input") != null);
    try testing.expectEqual(@as(?u32, 9), pty.exitStatus());
}

test {
    testing.refAllDecls(windows_job);
    testing.refAllDecls(@import("pty/pty_windows.zig"));
    testing.refAllDecls(WindowsPty);
}
