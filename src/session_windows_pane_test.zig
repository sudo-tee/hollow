//! Real owner-owned ConPTY/VT tests. No GUI or client owns the live pane.
const std = @import("std");
const testing = std.testing;
const a = testing.allocator;
const windows = std.os.windows;
const io = @import("io.zig");
const Pane = @import("agent/session_pane_windows.zig").Pane;
const session_vt = @import("agent/session_vt.zig");
const Wake = @import("pty/wake.zig").Wake;

extern "kernel32" fn CreateEventW(?*windows.SECURITY_ATTRIBUTES, windows.BOOL, windows.BOOL, ?windows.LPCWSTR) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetEvent(windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CloseHandle(windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WaitForSingleObject(windows.HANDLE, windows.DWORD) callconv(.winapi) windows.DWORD;
extern "kernel32" fn OpenProcess(windows.DWORD, windows.BOOL, windows.DWORD) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn TerminateProcess(windows.HANDLE, windows.UINT) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetEnvironmentVariableW(windows.LPCWSTR, ?windows.LPCWSTR) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetEnvironmentVariableW(windows.LPCWSTR, [*]u16, windows.DWORD) callconv(.winapi) windows.DWORD;

const timeout_ns = 20 * std.time.ns_per_s;
const scrollback_bytes = 1024 * 1024;

const Event = struct {
    handle: windows.HANDLE,

    fn init() !Event {
        return .{ .handle = CreateEventW(null, .FALSE, .FALSE, null) orelse return error.CreateEventFailed };
    }

    fn deinit(self: *Event) void {
        _ = CloseHandle(self.handle);
    }

    fn signal(context: *anyopaque) void {
        const self: *Event = @ptrCast(@alignCast(context));
        _ = SetEvent(self.handle);
    }

    fn wake(self: *Event) Wake {
        return .{ .context = self, .callback = signal };
    }

    fn wait(self: *Event, deadline: i128) !void {
        const remaining = deadline - io.nanoTimestamp();
        if (remaining <= 0) return error.PaneTimeout;
        const ms: windows.DWORD = @intCast(@min(@divTrunc(remaining, std.time.ns_per_ms) + 1, 20_000));
        switch (WaitForSingleObject(self.handle, ms)) {
            0 => {},
            258 => return error.PaneTimeout,
            else => return error.EventWaitFailed,
        }
    }
};

fn spawn(command: []const u8, event: *Event, env: ?[]const u8) !*Pane {
    // Explicit argv avoids shell integration, profiles, and host-specific pwsh.
    const argv = &.{ "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command };
    return Pane.create(a, .{
        .shell = "powershell.exe",
        .cols = 100,
        .rows = 8,
        .env_block = env,
        .launch_command = .{ .argv = argv },
        .scrollback_bytes = scrollback_bytes,
        .wake = event.wake(),
    });
}

fn readAvailable(pane: *Pane) !void {
    var buffer: [4096]u8 = undefined;
    // Bound each turn, including unexpectedly noisy children.
    for (0..256) |_| {
        if (try pane.read(&buffer) == 0) return;
    }
    return error.OutputLimitExceeded;
}

fn waitText(pane: *Pane, event: *Event, needle: []const u8) !void {
    const deadline = io.nanoTimestamp() + timeout_ns;
    while (true) {
        try readAvailable(pane);
        const text = try session_vt.plain(pane.vt.terminal, a);
        defer a.free(text);
        if (std.mem.indexOf(u8, text, needle) != null) return;
        if (pane.outputEnded()) {
            std.debug.print("missing {s} in terminal:\n{s}\n", .{ needle, text });
            return error.OutputEndedBeforeMarker;
        }
        try event.wait(deadline);
    }
}

fn waitExit(pane: *Pane, event: *Event) !void {
    const deadline = io.nanoTimestamp() + timeout_ns;
    while (true) {
        try readAvailable(pane);
        // ConPTY can retain its output handle until ClosePseudoConsole. Process
        // exit is independent of EOF; callers may keep draining after this.
        if (!pane.isAlive()) return;
        try event.wait(deadline);
    }
}

test "owner pane preserves process, variable, screen and scrollback after view destruction" {
    var event = try Event.init();
    // Callback context outlives all workers and process registrations.
    defer event.deinit();
    const pane = try spawn(
        "$saved = 'owner-state'; 1..40 | ForEach-Object { Write-Output ('HISTORY_' + $_) }; Write-Output 'VIEW_READY'; $null = [Console]::ReadLine(); Write-Output ('CONTINUED=' + $saved); $null = [Console]::ReadLine()",
        &event,
        null,
    );
    defer pane.destroy();
    try waitText(pane, &event, "VIEW_READY");
    const pid = pane.pty.process_id;
    var snapshot: std.ArrayList(u8) = .empty;
    defer snapshot.deinit(a);
    try pane.snapshot(a, &snapshot);
    const view = try session_vt.restore(snapshot.items, scrollback_bytes);
    {
        defer session_vt.freeTerminal(view);
        const text = try session_vt.plain(view, a);
        defer a.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "HISTORY_1\n") != null);
        try testing.expect(std.mem.indexOf(u8, text, "VIEW_READY") != null);
        const owner_text = try session_vt.plain(pane.vt.terminal, a);
        defer a.free(owner_text);
        try testing.expectEqualStrings(owner_text, text);
    }
    // Destroying a reconstructed client terminal must not touch the owner.
    try testing.expect(pane.isAlive());
    try testing.expectEqual(pid, pane.pty.process_id);
    try pane.writeAll("continue\r\n");
    try waitText(pane, &event, "CONTINUED=owner-state");
    var fallback: std.ArrayList(u8) = .empty;
    defer fallback.deinit(a);
    try pane.formatVt(a, &fallback);
    const client = try session_vt.Vt.create(a, 100, 8, scrollback_bytes);
    defer client.destroy();
    client.write(fallback.items);
    const actual = try session_vt.plain(client.terminal, a);
    defer a.free(actual);
    const expected = try session_vt.plain(pane.vt.terminal, a);
    defer a.free(expected);
    try testing.expectEqualStrings(expected, actual);
    try testing.expect(pane.isAlive());
}

test "owner resize updates VT immediately and ConPTY before subsequent input" {
    var event = try Event.init();
    defer event.deinit();
    const pane = try spawn("Write-Output 'RESIZE_READY'; $null = [Console]::ReadLine(); Write-Output ('SIZE=' + [Console]::WindowWidth + 'x' + [Console]::WindowHeight); $null = [Console]::ReadLine()", &event, null);
    defer pane.destroy();
    try waitText(pane, &event, "RESIZE_READY");
    try pane.resize(90, 20);
    try pane.resize(110, 28);
    const size = try pane.vt.size();
    try testing.expectEqual(@as(u16, 110), size.cols);
    try testing.expectEqual(@as(u16, 28), size.rows);
    try pane.flush();
    try pane.writeAll("size\r\n");
    try waitText(pane, &event, "SIZE=110x28");
}

test "owner answers DSR with no client and flushes replies without replay" {
    var event = try Event.init();
    defer event.deinit();
    const pane = try spawn("Write-Output 'QUERY_READY'; Start-Sleep -Seconds 2; Write-Output 'QUERY_DONE'; exit 0", &event, null);
    defer pane.destroy();
    try waitText(pane, &event, "QUERY_READY");
    // ConPTY may answer application DSR itself. Inject at the owner VT boundary
    // to test its answer path without claiming ConPTY forwarded a wire query.
    pane.vt.write("\x1b[3;7H\x1b[6n");
    try testing.expectEqualStrings("\x1b[3;7R", pane.vt.replies.items);
    // The next real output chunk lets Pane.read collect the VT callback replies.
    try waitText(pane, &event, "QUERY_DONE");
    try pane.flush();
    try testing.expectEqual(@as(usize, 0), pane.vt.replies.items.len);
    try testing.expectEqual(@as(usize, 0), pane.pending_replies.items.len);
    try pane.flush();
    try testing.expectEqual(@as(usize, 0), pane.pending_replies.items.len);
    try waitExit(pane, &event);
}

test "finite owner pane retains raw Windows exit code and terminal until close" {
    var event = try Event.init();
    defer event.deinit();
    const pane = try spawn("Write-Output 'FINITE_SCREEN'; exit 301", &event, null);
    defer pane.destroy();
    try waitText(pane, &event, "FINITE_SCREEN");
    try waitExit(pane, &event);
    try testing.expectEqual(@as(?u32, 301), pane.exitStatus());
    const before = try session_vt.plain(pane.vt.terminal, a);
    defer a.free(before);
    try testing.expect(std.mem.indexOf(u8, before, "FINITE_SCREEN") != null);
    var snapshot: std.ArrayList(u8) = .empty;
    defer snapshot.deinit(a);
    try pane.snapshot(a, &snapshot);
    const restored = try session_vt.restore(snapshot.items, scrollback_bytes);
    defer session_vt.freeTerminal(restored);
    const after = try session_vt.plain(restored, a);
    defer a.free(after);
    try testing.expectEqualStrings(before, after);
    pane.close();
    pane.close();
    try testing.expect(!pane.isAlive());
    try testing.expectEqual(@as(?u32, 301), pane.exitStatus());
}

test "input backpressure preserves reply suffix while owner drains output" {
    var event = try Event.init();
    defer event.deinit();
    const pane = try spawn("Write-Output 'BACKPRESSURE_READY'; $null = [Console]::ReadLine()", &event, null);
    defer pane.destroy();
    try waitText(pane, &event, "BACKPRESSURE_READY");
    try pane.pending_replies.appendSlice(a, "accepted-pending");
    pane.reply_offset = "accepted-".len;
    // Deterministically model full writer admission, without a timing-dependent
    // megabyte flood or blocking the test runner's own stdio.
    pane.pty.writer_state.mutex.lock();
    pane.pty.writer_state.queued_input_bytes = 1024 * 1024;
    pane.pty.writer_state.mutex.unlock();
    defer {
        pane.pty.writer_state.mutex.lock();
        pane.pty.writer_state.queued_input_bytes = 0;
        pane.pty.writer_state.mutex.unlock();
    }
    try testing.expectError(error.ResourceExhausted, pane.flush());
    pane.pty.reader_state.mutex.lock();
    pane.pty.reader_state.buf.appendSlice(a, "DRAIN_WITH_FULL_INPUT") catch |err| {
        pane.pty.reader_state.mutex.unlock();
        return err;
    };
    pane.pty.reader_state.eof = true;
    pane.pty.reader_state.mutex.unlock();
    try testing.expect(!pane.outputEnded());
    var buffer: [4096]u8 = undefined;
    const n = try pane.read(&buffer);
    try testing.expect(std.mem.indexOf(u8, buffer[0..n], "DRAIN_WITH_FULL_INPUT") != null);
    try testing.expectEqualStrings("pending", pane.pending_replies.items);
    try testing.expectEqual(@as(usize, 0), pane.reply_offset);
    try testing.expect(pane.outputEnded());
    // Writer failure is not proof of process exit.
    pane.pty.writer_state.mutex.lock();
    pane.pty.writer_state.failed = true;
    pane.pty.writer_state.mutex.unlock();
    try testing.expect(pane.isAlive());
    try testing.expectEqual(@as(?u32, null), pane.exitStatus());
}

const env_check =
    "foreach ($key in @('HOLLOW_PANE_ID','HOLLOW_WORKSPACE_ID','HOLLOW_COMMAND_ADDR')) { if ([Environment]::GetEnvironmentVariable($key)) { throw ('Leaked ' + $key) } }; if ($env:HOLLOW_TRANSPORT -cne 'osc') { throw 'Wrong transport' }; if ($env:HOLLOW_TEST_MARKER -cne 'preserved') { throw 'Lost marker' }; Write-Output 'ENV_ISOLATED'; exit 0";

test "session environment strips case-insensitive forged identities and preserves custom marker" {
    var event = try Event.init();
    defer event.deinit();
    const pane = try spawn(env_check, &event, "hollow_pane_id=forged\x00HoLlOw_WoRkSpAcE_iD=forged\x00hollow_command_addr=forged\x00hollow_transport=forged\x00HOLLOW_TEST_MARKER=preserved\x00\x00");
    defer pane.destroy();
    try waitText(pane, &event, "ENV_ISOLATED");
    try waitExit(pane, &event);
    try testing.expectEqual(@as(?u32, 0), pane.exitStatus());
}

const EnvGuard = struct {
    key: [:0]const u16,
    previous: ?[:0]u16,

    fn set(key: [:0]const u16, value: [:0]const u16) !EnvGuard {
        var buffer: [32768]u16 = undefined;
        const n = GetEnvironmentVariableW(key.ptr, &buffer, buffer.len);
        if (n >= buffer.len) return error.EnvironmentValueTooLong;
        const previous = if (n == 0) null else try a.dupeSentinel(u16, buffer[0..n], 0);
        errdefer if (previous) |p| a.free(p);
        if (!SetEnvironmentVariableW(key.ptr, value.ptr).toBool()) return error.SetEnvironmentFailed;
        return .{ .key = key, .previous = previous };
    }

    fn restore(self: EnvGuard) void {
        testing.expect(SetEnvironmentVariableW(self.key.ptr, if (self.previous) |p| p.ptr else null).toBool()) catch @panic("restore environment failed");
        if (self.previous) |p| a.free(p);
    }
};

test "session environment removes inherited identities and restores test parent environment" {
    const wide = std.unicode.utf8ToUtf16LeStringLiteral;
    // Zig runs these tests serially. Guards restore every changed OS variable,
    // including on spawn failure; no global mutation escapes this test.
    const pane_id = try EnvGuard.set(wide("HOLLOW_PANE_ID"), wide("parent-pane"));
    defer pane_id.restore();
    const workspace_id = try EnvGuard.set(wide("HOLLOW_WORKSPACE_ID"), wide("parent-workspace"));
    defer workspace_id.restore();
    const command_addr = try EnvGuard.set(wide("HOLLOW_COMMAND_ADDR"), wide("parent-command"));
    defer command_addr.restore();
    const transport = try EnvGuard.set(wide("HOLLOW_TRANSPORT"), wide("parent-transport"));
    defer transport.restore();
    const marker = try EnvGuard.set(wide("HOLLOW_TEST_MARKER"), wide("preserved"));
    defer marker.restore();
    var event = try Event.init();
    defer event.deinit();
    const pane = try spawn(env_check, &event, null);
    defer pane.destroy();
    try waitText(pane, &event, "ENV_ISOLATED");
    try waitExit(pane, &event);
    try testing.expectEqual(@as(?u32, 0), pane.exitStatus());
}

test "owner process exit wakes idle waiter while descendant keeps ConPTY alive; close kills descendant" {
    var event = try Event.init();
    defer event.deinit();
    const pane = try spawn("$info = New-Object System.Diagnostics.ProcessStartInfo; $info.FileName = $PSHOME + '\\powershell.exe'; $info.Arguments = '-NoProfile -NonInteractive -Command \"Start-Sleep -Seconds 120\"'; $info.UseShellExecute = $false; $child = [System.Diagnostics.Process]::Start($info); Write-Output ('CHILD=' + $child.Id + ';'); $null = [Console]::ReadLine(); Start-Sleep -Seconds 1; exit 23", &event, null);
    defer pane.destroy();
    try waitText(pane, &event, "CHILD=");
    const text = try session_vt.plain(pane.vt.terminal, a);
    defer a.free(text);
    const start = (std.mem.indexOf(u8, text, "CHILD=") orelse return error.MissingChild) + "CHILD=".len;
    const end = std.mem.indexOfScalarPos(u8, text, start, ';') orelse return error.MissingChildTerminator;
    const pid = try std.fmt.parseInt(windows.DWORD, text[start..end], 10);
    const child = OpenProcess(0x00100000 | 0x0001, .FALSE, pid) orelse return error.OpenProcessFailed;
    defer _ = CloseHandle(child);
    // Last-resort cleanup if the job ownership assertion fails.
    defer _ = TerminateProcess(child, 1);
    try testing.expect(pane.pty.job != null);
    try testing.expectEqual(@as(windows.DWORD, 258), WaitForSingleObject(child, 0));
    try pane.writeAll("exit\r\n");
    const deadline = io.nanoTimestamp() + timeout_ns;
    // Writer completion may wake first. Never poll: every status check follows
    // an event, so absent process-exit registration this reaches the deadline.
    while (true) {
        try event.wait(deadline);
        if (!pane.isAlive()) break;
        try readAvailable(pane);
    }
    try testing.expectEqual(@as(?u32, 23), pane.exitStatus());
    try testing.expectEqual(@as(windows.DWORD, 258), WaitForSingleObject(child, 0));
    pane.close();
    pane.close();
    try testing.expectEqual(@as(windows.DWORD, 0), WaitForSingleObject(child, 10_000));
}
