//! Raw stdio <-> secured named-pipe bridge. Never interprets, retries, or
//! manufactures protocol frames. Closing the bridge only disconnects its view.
const std = @import("std");
const windows = std.os.windows;
const pipe = @import("session_pipe_windows.zig");

const chunk_size = 64 * 1024;
const write_timeout_ms = 3000;
const Handle = windows.HANDLE;

extern "kernel32" fn CreateEventW(?*windows.SECURITY_ATTRIBUTES, windows.BOOL, windows.BOOL, ?windows.LPCWSTR) callconv(.winapi) ?Handle;
extern "kernel32" fn SetEvent(Handle) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WaitForSingleObject(Handle, windows.DWORD) callconv(.winapi) windows.DWORD;
extern "kernel32" fn WaitForMultipleObjects(windows.DWORD, [*]const Handle, windows.BOOL, windows.DWORD) callconv(.winapi) windows.DWORD;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn ReadFile(Handle, [*]u8, windows.DWORD, *windows.DWORD, ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WriteFile(Handle, [*]const u8, windows.DWORD, *windows.DWORD, ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CancelIoEx(Handle, ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CancelSynchronousIo(Handle) callconv(.winapi) windows.BOOL;

const State = struct {
    connection: Handle,
    input: Handle,
    output: Handle,
    stop: Handle,
    changed: Handle,
    done: [2]Handle,
    // Only synchronous stdout writes need supervisor deadlines. Pipe writes
    // wait on overlapped completion and stop events on their own worker.
    stdout_deadline: std.atomic.Value(u64) = .init(0),
    input_error: ?anyerror = null,
    output_error: ?anyerror = null,

    fn init(connection: Handle, input: Handle, output: Handle) !State {
        const stop = try event(true);
        errdefer pipe.close(stop);
        const changed = try event(false);
        errdefer pipe.close(changed);
        const first = try event(true);
        errdefer pipe.close(first);
        const second = try event(true);
        return .{ .connection = connection, .input = input, .output = output, .stop = stop, .changed = changed, .done = .{ first, second } };
    }

    fn deinit(self: *State) void {
        pipe.close(self.stop);
        pipe.close(self.changed);
        for (self.done) |handle| pipe.close(handle);
    }

    fn stopped(self: *State) bool {
        return WaitForSingleObject(self.stop, 0) == 0;
    }

    fn inputWorker(self: *State) void {
        self.inputLoop() catch |err| {
            if (!self.stopped() and err != error.BrokenPipe) self.input_error = err;
        };
        _ = SetEvent(self.done[0]);
    }

    fn inputLoop(self: *State) !void {
        var operation = try pipe.Operation.init();
        defer operation.deinit();
        defer operation.cancel(self.connection);
        var buffer: [chunk_size]u8 = undefined;
        while (!self.stopped()) {
            var count: windows.DWORD = 0;
            if (ReadFile(self.input, &buffer, buffer.len, &count, null) == .FALSE) {
                if (stdioClosed(GetLastError())) return;
                return error.StdioReadFailed;
            }
            if (count == 0 or self.stopped()) return;
            var offset: usize = 0;
            const deadline = GetTickCount64() + write_timeout_ms;
            while (offset < count and !self.stopped()) {
                try operation.write(self.connection, buffer[offset..count]);
                const n = try self.complete(&operation, deadline);
                if (n == 0) return;
                offset += n;
            }
        }
    }

    fn outputWorker(self: *State) void {
        self.outputLoop() catch |err| {
            if (!self.stopped() and err != error.BrokenPipe) self.output_error = err;
        };
        _ = SetEvent(self.done[1]);
    }

    fn outputLoop(self: *State) !void {
        var operation = try pipe.Operation.init();
        defer operation.deinit();
        defer operation.cancel(self.connection);
        var buffer: [chunk_size]u8 = undefined;
        while (!self.stopped()) {
            try operation.read(self.connection, &buffer);
            const count = try self.complete(&operation, null);
            if (count == 0 or self.stopped()) return;
            self.stdout_deadline.store(GetTickCount64() + write_timeout_ms, .release);
            _ = SetEvent(self.changed);
            defer {
                self.stdout_deadline.store(0, .release);
                _ = SetEvent(self.changed);
            }
            var offset: usize = 0;
            while (offset < count and !self.stopped()) {
                var written: windows.DWORD = 0;
                if (WriteFile(self.output, buffer[offset..].ptr, @intCast(count - offset), &written, null) == .FALSE) {
                    if (stdioClosed(GetLastError())) return;
                    return error.StdioWriteFailed;
                }
                if (written == 0) return;
                offset += written;
            }
        }
    }

    fn complete(self: *State, operation: *pipe.Operation, deadline: ?u64) !usize {
        const events = [_]Handle{ operation.event, self.stop };
        while (true) {
            if (self.stopped()) return error.OperationAborted;
            if (try operation.result(self.connection)) |n| return n;
            const now = GetTickCount64();
            if (deadline != null and now >= deadline.?) return error.Timeout;
            const wait_ms: u32 = if (deadline) |end| @intCast(end - now) else std.math.maxInt(u32);
            const result = WaitForMultipleObjects(events.len, &events, .FALSE, wait_ms);
            if (result == 258) return error.Timeout;
            if (result == 0xffffffff) return error.WaitFailed;
        }
    }
};

fn event(manual_reset: bool) !Handle {
    return CreateEventW(null, if (manual_reset) .TRUE else .FALSE, .FALSE, null) orelse error.ResourceExhausted;
}

fn stdioClosed(code: u32) bool {
    // Anonymous pipes and named stdio pipes use different EOF/closing codes.
    return code == 109 or code == 232 or code == 233;
}

/// Takes ownership of `connection` on admission, including failure. Stdio
/// handles are borrowed and are not closed or modified. Exactly two workers,
/// two 64 KiB buffers, and no growing queues are used per bridge.
pub fn run(connection: Handle, input: Handle, output: Handle) !void {
    defer pipe.close(connection);
    var state = try State.init(connection, input, output);
    defer state.deinit();
    const input_thread = try std.Thread.spawn(.{}, State.inputWorker, .{&state});
    const output_thread = std.Thread.spawn(.{}, State.outputWorker, .{&state}) catch |err| {
        stopAndJoin(&state, input_thread, null);
        return err;
    };
    const timed_out = supervise(&state) catch |err| {
        stopAndJoin(&state, input_thread, output_thread);
        return err;
    };
    stopAndJoin(&state, input_thread, output_thread);
    if (timed_out) return error.Timeout;
    if (state.input_error) |err| return err;
    if (state.output_error) |err| return err;
}

fn supervise(state: *State) !bool {
    const events = [_]Handle{ state.done[0], state.done[1], state.changed };
    while (true) {
        const deadline = state.stdout_deadline.load(.acquire);
        const now = GetTickCount64();
        const wait_ms: u32 = if (deadline == 0) std.math.maxInt(u32) else @intCast(deadline -| now);
        const result = WaitForMultipleObjects(events.len, &events, .FALSE, wait_ms);
        switch (result) {
            0, 1 => return false,
            2 => continue,
            258 => {
                const current = state.stdout_deadline.load(.acquire);
                if (current != 0 and GetTickCount64() >= current) return true;
            },
            else => return error.WaitFailed,
        }
    }
}

fn stopAndJoin(state: *State, input_thread: std.Thread, output_thread: ?std.Thread) void {
    _ = SetEvent(state.stop);
    const count: u32 = if (output_thread != null) 2 else 1;
    // Repeat cancellation to cover stop-check -> synchronous I/O submission
    // races. No buffers, OVERLAPPED values, or borrowed handles are freed early.
    while (true) {
        _ = CancelIoEx(state.connection, null);
        _ = CancelSynchronousIo(input_thread.getHandle());
        if (output_thread) |thread| _ = CancelSynchronousIo(thread.getHandle());
        if (WaitForMultipleObjects(count, &state.done, .TRUE, 10) == 0) break;
    }
    input_thread.join();
    if (output_thread) |thread| thread.join();
}
