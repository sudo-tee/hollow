const std = @import("std");
const windows = std.os.windows;

const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const HANDLE_FLAG_INHERIT: windows.DWORD = 0x00000001;
const WAIT_OBJECT_0: windows.DWORD = 0;

const HPCON = *opaque {};
const COORD = extern struct {
    X: i16,
    Y: i16,
};

const STARTUPINFOEXW = extern struct {
    StartupInfo: windows.STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

extern "kernel32" fn CreatePseudoConsole(size: COORD, hInput: windows.HANDLE, hOutput: windows.HANDLE, dwFlags: windows.DWORD, phPC: *?HPCON) callconv(.winapi) windows.HRESULT;
extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: COORD) callconv(.winapi) windows.HRESULT;
extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
extern "kernel32" fn CreatePipe(hReadPipe: *windows.HANDLE, hWritePipe: *windows.HANDLE, lpPipeAttributes: ?*windows.SECURITY_ATTRIBUTES, nSize: windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CreateProcessW(lpApplicationName: ?windows.LPWSTR, lpCommandLine: ?windows.LPWSTR, lpProcessAttributes: ?*windows.SECURITY_ATTRIBUTES, lpThreadAttributes: ?*windows.SECURITY_ATTRIBUTES, bInheritHandles: windows.BOOL, dwCreationFlags: windows.DWORD, lpEnvironment: ?*anyopaque, lpCurrentDirectory: ?windows.LPWSTR, lpStartupInfo: *windows.STARTUPINFOW, lpProcessInformation: *windows.PROCESS_INFORMATION) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetHandleInformation(hObject: windows.HANDLE, dwMask: windows.DWORD, dwFlags: windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn InitializeProcThreadAttributeList(lpAttributeList: ?*anyopaque, dwAttributeCount: windows.DWORD, dwFlags: windows.DWORD, lpSize: *usize) callconv(.winapi) windows.BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(lpAttributeList: ?*anyopaque, dwFlags: windows.DWORD, attribute: usize, lpValue: ?*const anyopaque, cbSize: usize, lpPreviousValue: ?*anyopaque, lpReturnSize: ?*usize) callconv(.winapi) windows.BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(lpAttributeList: ?*anyopaque) callconv(.winapi) void;

const EXTENDED_STARTUPINFO_PRESENT: windows.DWORD = 0x00080000;
const CREATE_UNICODE_ENVIRONMENT: windows.DWORD = 0x00000400;

const ReaderState = struct {
    mutex: std.Thread.Mutex = .{},
    buf: [65536]u8 = [_]u8{0} ** 65536,
    start: usize = 0,
    len: usize = 0,
    eof: bool = false,
    saw_read: bool = false,
};

pub const WindowsPty = struct {
    allocator: std.mem.Allocator,
    hpc: HPCON,
    process: windows.HANDLE,
    thread: windows.HANDLE,
    input_pipe_pty: windows.HANDLE,
    output_pipe_pty: windows.HANDLE,
    read_pipe: windows.HANDLE,
    write_pipe: windows.HANDLE,
    reader_state: *ReaderState,
    reader_thread: ?std.Thread,
    alive: bool = true,
    closed: bool = false,

    pub fn spawn(allocator: std.mem.Allocator, shell: [:0]const u8, cols: u16, rows: u16) !WindowsPty {
        return spawnWithShell(allocator, shell, cols, rows);
    }

    pub fn spawnWithFallbacks(allocator: std.mem.Allocator, preferred_shell: [:0]const u8, cols: u16, rows: u16, fallbacks: []const []const u8) !WindowsPty {
        if (spawnWithShell(allocator, preferred_shell, cols, rows)) |pty| {
            return pty;
        } else |err| switch (err) {
            error.CreateProcessFailed => {},
            else => return err,
        }

        for (fallbacks) |candidate| {
            if (std.mem.eql(u8, candidate, preferred_shell)) continue;
            const shell_z = try allocator.dupeZ(u8, candidate);
            defer allocator.free(shell_z);
            if (spawnWithShell(allocator, shell_z, cols, rows)) |pty| {
                return pty;
            } else |err| switch (err) {
                error.CreateProcessFailed => continue,
                else => return err,
            }
        }

        return error.CreateProcessFailed;
    }

    fn spawnWithShell(allocator: std.mem.Allocator, shell: [:0]const u8, cols: u16, rows: u16) !WindowsPty {
        var input_read: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
        var input_write: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
        var output_read: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
        var output_write: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
        try createPipe(&input_read, &input_write);
        errdefer closeHandleIfValid(input_read);
        errdefer closeHandleIfValid(input_write);
        try createPipe(&output_read, &output_write);
        errdefer closeHandleIfValid(output_read);
        errdefer closeHandleIfValid(output_write);

        if (SetHandleInformation(input_write, HANDLE_FLAG_INHERIT, 0) == windows.FALSE) return error.SetHandleInformationFailed;
        if (SetHandleInformation(output_read, HANDLE_FLAG_INHERIT, 0) == windows.FALSE) return error.SetHandleInformationFailed;

        var hpc: ?HPCON = null;
        const hr = CreatePseudoConsole(.{ .X = @intCast(cols), .Y = @intCast(rows) }, input_read, output_write, 0, &hpc);
        if (hr != 0 or hpc == null) {
            std.log.err("conpty CreatePseudoConsole failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return error.CreatePseudoConsoleFailed;
        }
        std.log.info("conpty CreatePseudoConsole ok hpc={*}", .{hpc.?});
        errdefer ClosePseudoConsole(hpc.?);

        var attr_size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
        const attr_mem = try allocator.alloc(u8, attr_size);
        defer allocator.free(attr_mem);
        if (InitializeProcThreadAttributeList(attr_mem.ptr, 1, 0, &attr_size) == 0) {
            std.log.err("conpty InitializeProcThreadAttributeList failed err={d}", .{windows.kernel32.GetLastError()});
            return error.AttributeListInitFailed;
        }
        defer DeleteProcThreadAttributeList(attr_mem.ptr);

        // lpValue must be the HPCON value itself (a pointer), not a pointer-to-HPCON.
        // MSDN: UpdateProcThreadAttribute for PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE takes
        // lpValue = HPCON, cbSize = sizeof(HPCON).
        if (UpdateProcThreadAttribute(attr_mem.ptr, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc.?, @sizeOf(HPCON), null, null) == 0) {
            std.log.err("conpty UpdateProcThreadAttribute failed err={d}", .{windows.kernel32.GetLastError()});
            return error.AttributeListUpdateFailed;
        }
        std.log.info("conpty UpdateProcThreadAttribute ok", .{});

        var si = std.mem.zeroes(STARTUPINFOEXW);
        si.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
        // Do NOT set STARTF_USESTDHANDLES for a ConPTY process — the ConPTY
        // owns the child's stdio.  Setting it (even with null handles) causes
        // some shells (notably wsl.exe) to ignore the pseudoconsole entirely.
        si.lpAttributeList = attr_mem.ptr;

        var pi = std.mem.zeroes(windows.PROCESS_INFORMATION);
        const spec = try buildCommandSpec(allocator, shell);
        defer freeSentinelU16(allocator, spec.application_utf16);
        defer freeSentinelU16(allocator, spec.command_line_utf16);
        defer freeSentinelU8(allocator, spec.log_command);
        if (CreateProcessW(
            spec.application_utf16.ptr,
            spec.command_line_utf16.ptr,
            null,
            null,
            windows.TRUE, // inherit handles (reverted to test if FALSE was causing input issues)
            EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
            null,
            null,
            &si.StartupInfo,
            &pi,
        ) == windows.FALSE) {
            std.log.err("conpty CreateProcessW failed err={d}", .{windows.kernel32.GetLastError()});
            return error.CreateProcessFailed;
        }
        std.log.info("conpty spawned process pid={d} shell={s}", .{ pi.dwProcessId, spec.log_command });

        // Briefly check if the child exited immediately (bad args, missing exe, etc.)
        std.Thread.sleep(100 * std.time.ns_per_ms);
        if (windows.kernel32.WaitForSingleObject(pi.hProcess, 0) == WAIT_OBJECT_0) {
            var exit_code: windows.DWORD = 0;
            _ = windows.kernel32.GetExitCodeProcess(pi.hProcess, &exit_code);
            std.log.warn("conpty child exited immediately after spawn code={d}", .{exit_code});
        } else {
            std.log.info("conpty child still alive after 100ms", .{});
        }

        // Do not write any initial input — let the shell start cleanly.
        std.log.info("conpty process spawned, waiting for shell prompt", .{});

        // Close output_write (the ConPTY's output side) so ReadFile on output_read
        // returns EOF when the shell exits.  We keep input_read open intentionally —
        // closing it here has been observed to silently break ConPTY input on some
        // WSL / Windows 11 configurations.
        closeHandleIfValid(output_write);
        std.log.info("conpty: closed output_write (kept input_read open)", .{});

        const reader_state = try allocator.create(ReaderState);
        reader_state.* = .{};
        errdefer allocator.destroy(reader_state);

        var pty = WindowsPty{
            .allocator = allocator,
            .hpc = hpc.?,
            .process = pi.hProcess,
            .thread = pi.hThread,
            .input_pipe_pty = input_read, // kept open (closing it breaks ConPTY input on some configs)
            .output_pipe_pty = windows.INVALID_HANDLE_VALUE, // already closed
            .read_pipe = output_read,
            .write_pipe = input_write,
            .reader_state = reader_state,
            .reader_thread = null,
        };

        pty.reader_thread = try std.Thread.spawn(.{}, readerLoop, .{ pty.read_pipe, pty.reader_state });

        return pty;
    }

    pub fn deinit(self: *WindowsPty) void {
        self.close();
    }

    pub fn isAlive(self: *WindowsPty) bool {
        if (self.closed) return false;
        // Use the pipe state as the liveness signal rather than the process handle.
        // wsl.exe (and similar launcher processes) exit immediately after handing
        // off to the actual shell, but the ConPTY output pipe stays open as long
        // as the shell is running.  The reader thread sets reader_state.eof = true
        // when ReadFile fails (broken pipe / handle closed).
        if (self.reader_state.eof) {
            if (self.alive) {
                self.alive = false;
                std.log.info("conpty pipe closed (shell exited)", .{});
            }
            return false;
        }
        return true;
    }

    pub fn read(self: *WindowsPty, buffer: []u8) !usize {
        if (buffer.len == 0) return 0;
        self.reader_state.mutex.lock();
        defer self.reader_state.mutex.unlock();

        if (self.reader_state.len == 0) return 0;

        const count = @min(buffer.len, self.reader_state.len);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            buffer[i] = self.reader_state.buf[(self.reader_state.start + i) % self.reader_state.buf.len];
        }
        self.reader_state.start = (self.reader_state.start + count) % self.reader_state.buf.len;
        self.reader_state.len -= count;
        return count;
    }

    pub fn hasPendingOutput(self: *WindowsPty) bool {
        self.reader_state.mutex.lock();
        defer self.reader_state.mutex.unlock();
        return self.reader_state.len > 0;
    }

    pub fn writeAll(self: *WindowsPty, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            var written: windows.DWORD = 0;
            const chunk: windows.DWORD = @intCast(bytes.len - offset);
            const ok = windows.kernel32.WriteFile(self.write_pipe, bytes.ptr + offset, chunk, &written, null);
            if (ok == windows.FALSE) {
                const err = windows.kernel32.GetLastError();
                std.log.err("conpty WriteFile failed err={d} written={d}", .{ err, written });
                return error.WriteFailed;
            }
            offset += written;
        }
    }

    pub fn resize(self: *WindowsPty, cols: u16, rows: u16) void {
        _ = ResizePseudoConsole(self.hpc, .{ .X = @intCast(cols), .Y = @intCast(rows) });
    }

    pub fn close(self: *WindowsPty) void {
        if (self.closed) return;
        if (self.isAlive()) _ = windows.kernel32.TerminateProcess(self.process, 0);
        closeHandleIfValid(self.input_pipe_pty);
        closeHandleIfValid(self.output_pipe_pty);
        closeHandleIfValid(self.read_pipe);
        closeHandleIfValid(self.write_pipe);
        if (self.reader_thread) |thread| thread.join();
        closeHandleIfValid(self.process);
        closeHandleIfValid(self.thread);
        ClosePseudoConsole(self.hpc);
        self.allocator.destroy(self.reader_state);
        self.closed = true;
        self.alive = false;
    }
};

fn readerLoop(read_pipe: windows.HANDLE, reader_state: *ReaderState) void {
    var temp: [4096]u8 = undefined;
    var loop_count: u64 = 0;
    std.log.info("conpty reader thread started", .{});
    while (true) {
        var read_count: windows.DWORD = 0;
        const ok = windows.kernel32.ReadFile(read_pipe, &temp, temp.len, &read_count, null);
        loop_count += 1;
        if (ok == windows.FALSE) {
            const err = windows.kernel32.GetLastError();
            std.log.warn("conpty ReadFile failed loop={d} err={d}", .{ loop_count, err });
            // Signal that the pipe is closed so isAlive() returns false.
            reader_state.mutex.lock();
            reader_state.eof = true;
            reader_state.mutex.unlock();
            return;
        }
        // Log every 60 seconds to show reader thread is still alive
        if (loop_count == 1 or loop_count % 100 == 0) {
            std.log.info("conpty reader alive loop={d}", .{loop_count});
        }

        if (loop_count == 1) {
            std.log.info("conpty first read bytes={d}", .{read_count});
            // Hex dump of the first read for diagnostics
            var hex_buf: [256]u8 = undefined;
            var hex_len: usize = 0;
            const show = @min(read_count, 80);
            for (temp[0..show]) |b| {
                if (hex_len + 3 < hex_buf.len) {
                    hex_buf[hex_len] = "0123456789abcdef"[b >> 4];
                    hex_buf[hex_len + 1] = "0123456789abcdef"[b & 0xf];
                    hex_buf[hex_len + 2] = ' ';
                    hex_len += 3;
                }
            }
            std.log.info("conpty first-read hex={s}", .{hex_buf[0..hex_len]});
        }

        reader_state.mutex.lock();
        defer reader_state.mutex.unlock();
        reader_state.saw_read = true;

        var i: usize = 0;
        while (i < read_count) : (i += 1) {
            if (reader_state.len == reader_state.buf.len) break;
            const idx = (reader_state.start + reader_state.len) % reader_state.buf.len;
            reader_state.buf[idx] = temp[i];
            reader_state.len += 1;
        }
    }
}

fn createPipe(read_pipe: *windows.HANDLE, write_pipe: *windows.HANDLE) !void {
    var sa = std.mem.zeroes(windows.SECURITY_ATTRIBUTES);
    sa.nLength = @sizeOf(windows.SECURITY_ATTRIBUTES);
    sa.bInheritHandle = windows.TRUE;
    if (CreatePipe(read_pipe, write_pipe, &sa, 0) == windows.FALSE) return error.CreatePipeFailed;
}

fn closeHandleIfValid(handle: windows.HANDLE) void {
    if (handle != windows.INVALID_HANDLE_VALUE and @intFromPtr(handle) != 0) _ = windows.CloseHandle(handle);
}

fn freeSentinelU8(allocator: std.mem.Allocator, bytes: [:0]u8) void {
    allocator.free(@as([*]u8, @ptrCast(bytes.ptr))[0 .. bytes.len + 1]);
}

fn freeSentinelU16(allocator: std.mem.Allocator, bytes: [:0]u16) void {
    allocator.free(@as([*]u16, @ptrCast(bytes.ptr))[0 .. bytes.len + 1]);
}

const CommandSpec = struct {
    application_utf16: [:0]u16,
    command_line_utf16: [:0]u16,
    log_command: [:0]u8,
};

fn buildCommandSpec(allocator: std.mem.Allocator, shell: [:0]const u8) !CommandSpec {
    const shell_name = std.fs.path.basename(shell);
    const argv: []const []const u8 = if (std.mem.eql(u8, shell_name, "cmd.exe") or std.mem.eql(u8, shell_name, "cmd"))
        &.{ shell, "/Q", "/K", "echo [hollow] child started" }
    else if (std.mem.eql(u8, shell_name, "wsl.exe") or std.mem.eql(u8, shell_name, "wsl"))
        &.{shell}
    else
        &.{shell};

    const command_line = try windowsCreateCommandLine(allocator, argv);
    errdefer freeSentinelU8(allocator, command_line);

    return .{
        .application_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(allocator, shell),
        .command_line_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(allocator, command_line),
        .log_command = command_line,
    };
}

fn windowsCreateCommandLine(allocator: std.mem.Allocator, argv: []const []const u8) ![:0]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const writer = &buf.writer;

    for (argv, 0..) |arg, arg_i| {
        if (arg_i != 0) try writer.writeByte(' ');
        if (std.mem.indexOfAny(u8, arg, " \t\n\"") == null) {
            try writer.writeAll(arg);
            continue;
        }

        try writer.writeByte('"');
        var backslash_count: usize = 0;
        for (arg) |byte| {
            switch (byte) {
                '\\' => backslash_count += 1,
                '"' => {
                    try writer.splatByteAll('\\', backslash_count * 2 + 1);
                    try writer.writeByte('"');
                    backslash_count = 0;
                },
                else => {
                    try writer.splatByteAll('\\', backslash_count);
                    try writer.writeByte(byte);
                    backslash_count = 0;
                },
            }
        }
        try writer.splatByteAll('\\', backslash_count * 2);
        try writer.writeByte('"');
    }

    return buf.toOwnedSliceSentinel(0);
}

threadlocal var preview_buf: [48]u8 = undefined;

fn previewBytes(bytes: []const u8) []const u8 {
    const len = @min(bytes.len, 48);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const ch = bytes[i];
        preview_buf[i] = if (ch >= 32 and ch <= 126) ch else '.';
    }
    return preview_buf[0..len];
}
