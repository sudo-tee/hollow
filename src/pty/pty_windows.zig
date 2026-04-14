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
extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) [*:0]u16;
extern "kernel32" fn FreeEnvironmentStringsW(lpszEnvironmentBlock: [*:0]u16) callconv(.winapi) windows.BOOL;

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
    process_id: windows.DWORD,
    input_pipe_pty: windows.HANDLE,
    output_pipe_pty: windows.HANDLE,
    read_pipe: windows.HANDLE,
    write_pipe: windows.HANDLE,
    reader_state: *ReaderState,
    reader_thread: ?std.Thread,
    alive: bool = true,
    closed: bool = false,

    pub fn spawn(allocator: std.mem.Allocator, shell: [:0]const u8, cols: u16, rows: u16, cwd: ?[]const u8, env_block: ?[]const u8) !WindowsPty {
        return spawnWithShell(allocator, shell, cols, rows, cwd, env_block);
    }

    pub fn spawnWithFallbacks(allocator: std.mem.Allocator, preferred_shell: [:0]const u8, cols: u16, rows: u16, cwd: ?[]const u8, env_block: ?[]const u8, fallbacks: []const []const u8) !WindowsPty {
        if (spawnWithShell(allocator, preferred_shell, cols, rows, cwd, env_block)) |pty| {
            return pty;
        } else |err| switch (err) {
            error.CreateProcessFailed => {},
            else => return err,
        }

        for (fallbacks) |candidate| {
            if (std.mem.eql(u8, candidate, preferred_shell)) continue;
            const shell_z = try allocator.dupeZ(u8, candidate);
            defer allocator.free(shell_z);
            if (spawnWithShell(allocator, shell_z, cols, rows, cwd, env_block)) |pty| {
                return pty;
            } else |err| switch (err) {
                error.CreateProcessFailed => continue,
                else => return err,
            }
        }

        return error.CreateProcessFailed;
    }

    fn spawnWithShell(allocator: std.mem.Allocator, shell: [:0]const u8, cols: u16, rows: u16, cwd: ?[]const u8, env_block: ?[]const u8) !WindowsPty {
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
        const spec = try buildCommandSpec(allocator, shell, cwd);
        defer freeSentinelU16(allocator, spec.application_utf16);
        defer freeSentinelU16(allocator, spec.command_line_utf16);
        defer if (spec.cwd_utf16) |value| freeSentinelU16(allocator, value);
        defer freeSentinelU8(allocator, spec.log_command);

        // Build the environment block for the process
        const shell_name = std.fs.path.basename(shellProgram(shell));
        const env_block_utf16 = try buildEnvironmentBlock(allocator, env_block, shell_name);
        defer if (env_block_utf16) |block| freeSentinelU16(allocator, block);

        if (CreateProcessW(
            spec.application_utf16.ptr,
            spec.command_line_utf16.ptr,
            null,
            null,
            windows.TRUE, // inherit handles (reverted to test if FALSE was causing input issues)
            EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
            if (env_block_utf16) |block| @as(?*anyopaque, @ptrCast(block.ptr)) else null,
            if (spec.cwd_utf16) |value| value.ptr else null,
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
            .process_id = pi.dwProcessId,
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
        // Fast path: already known dead.
        if (!self.alive) return false;

        // Check pipe EOF first — the reader thread sets this when ReadFile fails.
        self.reader_state.mutex.lock();
        const eof = self.reader_state.eof;
        const saw_read = self.reader_state.saw_read;
        const pending = self.reader_state.len;
        self.reader_state.mutex.unlock();
        if (eof) {
            self.alive = false;
            std.log.info("conpty pipe closed (shell exited)", .{});
            return false;
        }

        if (saw_read and pending > 0) return true;

        if (self.process != windows.INVALID_HANDLE_VALUE and @intFromPtr(self.process) != 0) {
            if (windows.kernel32.WaitForSingleObject(self.process, 0) == WAIT_OBJECT_0) {
                self.alive = false;
                std.log.info("conpty process exited (WaitForSingleObject)", .{});
                return false;
            }
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

    pub fn childPid(self: *const WindowsPty) usize {
        return @intCast(self.process_id);
    }

    pub fn close(self: *WindowsPty) void {
        if (self.closed) return;
        // Terminate the child process if still alive.
        if (self.isAlive()) _ = windows.kernel32.TerminateProcess(self.process, 0);
        // ClosePseudoConsole MUST come before closing read_pipe and before
        // thread.join().  It tears down the ConPTY, which causes the in-flight
        // ReadFile on read_pipe (in the reader thread) to return immediately with
        // an error — unblocking the thread.  Closing read_pipe first leaves
        // ReadFile in an undefined state and can hang the join forever.
        ClosePseudoConsole(self.hpc);
        closeHandleIfValid(self.input_pipe_pty);
        closeHandleIfValid(self.output_pipe_pty);
        closeHandleIfValid(self.read_pipe);
        closeHandleIfValid(self.write_pipe);
        if (self.reader_thread) |thread| thread.join();
        closeHandleIfValid(self.process);
        closeHandleIfValid(self.thread);
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
        reader_state.saw_read = true;

        var i: usize = 0;
        while (i < read_count) : (i += 1) {
            if (reader_state.len == reader_state.buf.len) break;
            const idx = (reader_state.start + reader_state.len) % reader_state.buf.len;
            reader_state.buf[idx] = temp[i];
            reader_state.len += 1;
        }
        reader_state.mutex.unlock();
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
    cwd_utf16: ?[:0]u16,
    log_command: [:0]u8,
};

fn buildCommandSpec(allocator: std.mem.Allocator, shell: [:0]const u8, cwd: ?[]const u8) !CommandSpec {
    const shell_program = shellProgram(shell);
    const shell_name = std.fs.path.basename(shell_program);
    const argv: []const []const u8 = if (std.mem.eql(u8, shell_name, "cmd.exe") or std.mem.eql(u8, shell_name, "cmd"))
        &.{ shell, "/Q", "/K", "echo [hollow] child started" }
    else if ((std.mem.eql(u8, shell_name, "wsl.exe") or std.mem.eql(u8, shell_name, "wsl")) and cwd != null and cwd.?.len > 0)
        &.{ shell, "--cd", cwd.? }
    else
        &.{shell};

    const command_line = try windowsCreateCommandLine(allocator, argv);
    errdefer freeSentinelU8(allocator, command_line);

    return .{
        .application_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(allocator, shell_program),
        .command_line_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(allocator, command_line),
        .cwd_utf16 = if (cwd) |value|
            if ((std.mem.eql(u8, shell_name, "wsl.exe") or std.mem.eql(u8, shell_name, "wsl")) or value.len == 0) null else try std.unicode.utf8ToUtf16LeAllocZ(allocator, value)
        else
            null,
        .log_command = command_line,
    };
}

fn shellProgram(shell_command: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, shell_command, " \t\r\n");
    if (trimmed.len == 0) return trimmed;
    if (trimmed[0] == '"') {
        const rest = trimmed[1..];
        const end_quote = std.mem.indexOfScalar(u8, rest, '"') orelse return rest;
        return rest[0..end_quote];
    }
    const end = std.mem.indexOfAny(u8, trimmed, " \t\r\n") orelse trimmed.len;
    return trimmed[0..end];
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

/// Builds a Windows UTF-16 environment block from a null-separated UTF-8 env_block string.
/// The env_block format is: "KEY1=value1\0KEY2=value2\0\0"
/// Returns a UTF-16 environment block suitable for CreateProcessW, or null if env_block is null.
/// Caller must free the returned memory with freeSentinelU16.
fn buildEnvironmentBlock(allocator: std.mem.Allocator, env_block: ?[]const u8, shell_name: []const u8) !?[:0]u16 {
    if (env_block == null or env_block.?.len == 0) return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp_alloc = arena.allocator();

    // Start by inheriting the parent environment from Windows
    var vars: std.ArrayListUnmanaged(struct { key: []const u8, value: []const u8 }) = .empty;
    const parent_env = GetEnvironmentStringsW();
    defer _ = FreeEnvironmentStringsW(parent_env);
    var idx: usize = 0;
    while (parent_env[idx] != 0) {
        const entry_start = idx;
        while (parent_env[idx] != 0) : (idx += 1) {}
        const entry_utf16 = parent_env[entry_start..idx];
        idx += 1;
        const entry_utf8 = std.unicode.utf16LeToUtf8Alloc(temp_alloc, entry_utf16) catch continue;
        // Skip Windows-internal vars that start with '='
        if (entry_utf8.len == 0 or entry_utf8[0] == '=') continue;
        if (std.mem.indexOfScalar(u8, entry_utf8, '=')) |eq_pos| {
            try vars.append(temp_alloc, .{ .key = entry_utf8[0..eq_pos], .value = entry_utf8[eq_pos + 1 ..] });
        }
    }
    std.log.info("buildEnvironmentBlock: inherited {} parent vars", .{vars.items.len});

    // Parse and override/add custom vars from env_block
    var i: usize = 0;
    while (i < env_block.?.len) {
        const entry_start = i;
        while (i < env_block.?.len and env_block.?[i] != 0) : (i += 1) {}
        if (i > entry_start) {
            const entry = env_block.?[entry_start..i];
            if (std.mem.indexOfScalar(u8, entry, '=')) |eq_pos| {
                const key = entry[0..eq_pos];
                const value = entry[eq_pos + 1 ..];
                var found = false;
                for (vars.items) |*v| {
                    if (std.ascii.eqlIgnoreCase(v.key, key)) {
                        v.value = value;
                        found = true;
                        break;
                    }
                }
                if (!found) try vars.append(temp_alloc, .{ .key = key, .value = value });
            }
        }
        i += 1;
        if (i < env_block.?.len and env_block.?[i] == 0) break;
    }

    // For WSL: append HOLLOW_* vars to WSLENV so they cross the boundary
    const is_wsl = std.mem.eql(u8, shell_name, "wsl.exe") or std.mem.eql(u8, shell_name, "wsl");
    if (is_wsl) {
        var wslenv_additions: std.ArrayListUnmanaged(u8) = .empty;
        var j: usize = 0;
        while (j < env_block.?.len) {
            const entry_start = j;
            while (j < env_block.?.len and env_block.?[j] != 0) : (j += 1) {}
            if (j > entry_start) {
                const entry = env_block.?[entry_start..j];
                if (std.mem.indexOfScalar(u8, entry, '=')) |eq_pos| {
                    const key = entry[0..eq_pos];
                    if (std.mem.startsWith(u8, key, "HOLLOW_")) {
                        if (wslenv_additions.items.len > 0) try wslenv_additions.append(temp_alloc, ':');
                        try wslenv_additions.appendSlice(temp_alloc, key);
                        if (std.mem.indexOf(u8, key, "DIR") != null) {
                            try wslenv_additions.appendSlice(temp_alloc, "/p");
                        } else {
                            try wslenv_additions.appendSlice(temp_alloc, "/u");
                        }
                    }
                }
            }
            j += 1;
            if (j < env_block.?.len and env_block.?[j] == 0) break;
        }

        if (wslenv_additions.items.len > 0) {
            // Find existing WSLENV and append, or add new
            var found = false;
            for (vars.items) |*v| {
                if (std.ascii.eqlIgnoreCase(v.key, "WSLENV")) {
                    const new_val = if (v.value.len > 0)
                        try std.fmt.allocPrint(temp_alloc, "{s}:{s}", .{ v.value, wslenv_additions.items })
                    else
                        wslenv_additions.items;
                    v.value = new_val;
                    found = true;
                    break;
                }
            }
            if (!found) try vars.append(temp_alloc, .{ .key = "WSLENV", .value = wslenv_additions.items });
        }
    }

    // Build the UTF-16 environment block: each "KEY=value\0", terminated by extra \0
    var utf16_block: std.ArrayListUnmanaged(u16) = .empty;
    errdefer utf16_block.deinit(allocator);
    for (vars.items) |v| {
        var entry_utf8: std.ArrayListUnmanaged(u8) = .empty;
        defer entry_utf8.deinit(temp_alloc);
        try entry_utf8.appendSlice(temp_alloc, v.key);
        try entry_utf8.append(temp_alloc, '=');
        try entry_utf8.appendSlice(temp_alloc, v.value);
        const entry_utf16 = try std.unicode.utf8ToUtf16LeAlloc(temp_alloc, entry_utf8.items);
        try utf16_block.appendSlice(allocator, entry_utf16);
        try utf16_block.append(allocator, 0);
    }
    try utf16_block.append(allocator, 0); // final double-null

    return try allocator.dupeZ(u16, utf16_block.items);
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
