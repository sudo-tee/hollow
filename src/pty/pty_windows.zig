const std = @import("std");
const fastmem = @import("../fastmem.zig");
const app = @import("../app.zig");
const windows = std.os.windows;
const kernel32 = windows.kernel32;
const LaunchCommand = @import("launch_command.zig").LaunchCommand;
const wsl_bypass_protocol = @import("wsl_bypass_protocol.zig");
const build_options = @import("build_options");

const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const HANDLE_FLAG_INHERIT: windows.DWORD = 0x00000001;
const WAIT_OBJECT_0: windows.DWORD = 0;
const STARTF_USESTDHANDLES: windows.DWORD = 0x00000100;
const STARTF_USESHOWWINDOW: windows.DWORD = 0x00000001;
const CREATE_NEW_CONSOLE: windows.DWORD = 0x00000010;
const SW_HIDE: windows.WORD = 0;
const WSL_BYPASS_STARTUP_TIMEOUT_MS: u64 = 1200;
const WSL_BYPASS_EXIT_TIMEOUT_MS: windows.DWORD = 1500;

/// Tracks which WSL distros have had the bypass binary deployed to /tmp/.
const WslBootState = struct {
    mutex: std.Thread.Mutex = .{},
    keys: std.ArrayListUnmanaged([]const u8) = .{},

    fn isBooted(self: *@This(), key: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.keys.items) |k| {
            if (std.mem.eql(u8, k, key)) return true;
        }
        return false;
    }

    fn markBooted(self: *@This(), key: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.keys.items) |k| {
            if (std.mem.eql(u8, k, key)) return;
        }
        const owned = std.heap.page_allocator.dupe(u8, key) catch return;
        self.keys.append(std.heap.page_allocator, owned) catch {
            std.heap.page_allocator.free(owned);
        };
    }
};

var wsl_boot_state = WslBootState{};

fn wslDistroKey(parsed_shell: []const []const u8) []const u8 {
    const split = splitWslLauncherArgs(parsed_shell);
    var i: usize = 1;
    while (i < split.launcher.len) {
        const arg = split.launcher[i];
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--distribution")) {
            if (i + 1 < split.launcher.len) return split.launcher[i + 1];
            i += 1;
        } else if (wslOptionTakesValue(arg)) {
            i += 1;
        }
        i += 1;
    }
    return "default";
}

fn wslBypassBinaryPath(allocator: std.mem.Allocator) ![]u8 {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    const dir = std.fs.path.dirname(exe_path) orelse ".";
    return std.fs.path.join(allocator, &.{ dir, "hollow-wsl-bypass" });
}

fn wslWindowsToLinuxPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len >= 18 and std.ascii.startsWithIgnoreCase(path, "\\\\wsl.localhost\\")) {
        var index: usize = 17;
        while (index < path.len and path[index] != '\\' and path[index] != '/') : (index += 1) {}
        if (index < path.len) {
            const remainder = path[index..];
            var buf = std.ArrayList(u8).empty;
            for (remainder) |ch| {
                try buf.append(allocator, if (ch == '\\') '/' else ch);
            }
            return buf.toOwnedSlice(allocator);
        }
        return allocator.dupe(u8, "/");
    }

    if (path.len < 3 or path[1] != ':') return allocator.dupe(u8, path);
    var buf = std.ArrayList(u8).empty;
    try buf.appendSlice(allocator, "/mnt/");
    try buf.append(allocator, std.ascii.toLower(path[0]));
    for (path[2..]) |ch| {
        try buf.append(allocator, if (ch == '\\') '/' else ch);
    }
    return buf.toOwnedSlice(allocator);
}

fn wslShellQuote(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, s, '\'') == null) {
        return std.fmt.allocPrint(allocator, "'{s}'", .{s});
    }
    var buf = std.ArrayList(u8).empty;
    try buf.append(allocator, '\'');
    for (s) |ch| {
        if (ch == '\'') {
            try buf.appendSlice(allocator, "'\\''");
        } else {
            try buf.append(allocator, ch);
        }
    }
    try buf.append(allocator, '\'');
    return buf.toOwnedSlice(allocator);
}

fn bootstrapWslDistro(allocator: std.mem.Allocator, shell: [:0]const u8) !void {
    const parsed = try parseCommandString(allocator, shell);
    defer freeArgv(allocator, parsed);
    const split = splitWslLauncherArgs(parsed);

    if (split.launcher.len == 0) return error.InvalidCharacter;

    const windows_path = try wslBypassBinaryPath(allocator);
    defer allocator.free(windows_path);

    const wsl_path = try wslWindowsToLinuxPath(allocator, windows_path);
    defer allocator.free(wsl_path);

    const quoted_path = try wslShellQuote(allocator, wsl_path);
    defer allocator.free(quoted_path);

    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(allocator);

    try argv.appendSlice(allocator, split.launcher);
    try argv.append(allocator, try allocator.dupe(u8, "--exec"));
    try argv.append(allocator, try allocator.dupe(u8, "/bin/sh"));
    try argv.append(allocator, try allocator.dupe(u8, "-c"));
    const shell_cmd = try std.fmt.allocPrint(allocator, "cp {s} /tmp/hollow-wsl-bypass && chmod +x /tmp/hollow-wsl-bypass", .{quoted_path});
    defer allocator.free(shell_cmd);
    try argv.append(allocator, shell_cmd);

    const command_line = try windowsCreateCommandLine(allocator, argv.items);
    defer freeSentinelU8(allocator, command_line);

    const application = try resolveWindowsProgram(allocator, split.launcher[0]);
    defer allocator.free(application);

    const app_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(allocator, application);
    defer allocator.free(app_utf16);
    const cmd_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(allocator, command_line);
    defer allocator.free(cmd_utf16);

    var si = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;

    var pi = std.mem.zeroes(windows.PROCESS_INFORMATION);
    if (CreateProcessW(
        app_utf16.ptr,
        cmd_utf16.ptr,
        null,
        null,
        windows.FALSE,
        CREATE_UNICODE_ENVIRONMENT,
        null,
        null,
        &si,
        &pi,
    ) == windows.FALSE) {
        std.log.warn("wsl bootstrap CreateProcessW failed err={d}", .{kernel32.GetLastError()});
        return error.WslBypassUnavailable;
    }
    defer _ = CloseHandle(pi.hProcess);
    defer _ = CloseHandle(pi.hThread);

    const wait_result = kernel32.WaitForSingleObject(pi.hProcess, 10000);
    if (wait_result != WAIT_OBJECT_0) {
        std.log.warn("wsl bootstrap timed out after 10s", .{});
        _ = kernel32.TerminateProcess(pi.hProcess, 1);
        return error.WslBypassUnavailable;
    }

    var exit_code: windows.DWORD = 0;
    _ = kernel32.GetExitCodeProcess(pi.hProcess, &exit_code);
    if (exit_code != 0) {
        std.log.warn("wsl bootstrap failed exit_code={d}", .{exit_code});
        return error.WslBypassUnavailable;
    }

    std.log.info("wsl bootstrap ok distro={s} path={s}", .{ wslDistroKey(parsed), wsl_path });
}

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
extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn PeekNamedPipe(hNamedPipe: windows.HANDLE, lpBuffer: ?*anyopaque, nBufferSize: windows.DWORD, lpBytesRead: ?*windows.DWORD, lpTotalBytesAvail: ?*windows.DWORD, lpBytesLeftThisMessage: ?*windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CreateProcessW(lpApplicationName: ?windows.LPWSTR, lpCommandLine: ?windows.LPWSTR, lpProcessAttributes: ?*windows.SECURITY_ATTRIBUTES, lpThreadAttributes: ?*windows.SECURITY_ATTRIBUTES, bInheritHandles: windows.BOOL, dwCreationFlags: windows.DWORD, lpEnvironment: ?*anyopaque, lpCurrentDirectory: ?windows.LPWSTR, lpStartupInfo: *windows.STARTUPINFOW, lpProcessInformation: *windows.PROCESS_INFORMATION) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SearchPathW(lpPath: ?windows.LPCWSTR, lpFileName: windows.LPCWSTR, lpExtension: ?windows.LPCWSTR, nBufferLength: windows.DWORD, lpBuffer: ?windows.LPWSTR, lpFilePart: ?*windows.LPWSTR) callconv(.winapi) windows.DWORD;
extern "kernel32" fn SetHandleInformation(hObject: windows.HANDLE, dwMask: windows.DWORD, dwFlags: windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn InitializeProcThreadAttributeList(lpAttributeList: ?*anyopaque, dwAttributeCount: windows.DWORD, dwFlags: windows.DWORD, lpSize: *usize) callconv(.winapi) windows.BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(lpAttributeList: ?*anyopaque, dwFlags: windows.DWORD, attribute: usize, lpValue: ?*const anyopaque, cbSize: usize, lpPreviousValue: ?*anyopaque, lpReturnSize: ?*usize) callconv(.winapi) windows.BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(lpAttributeList: ?*anyopaque) callconv(.winapi) void;
extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) [*:0]u16;
extern "kernel32" fn FreeEnvironmentStringsW(lpszEnvironmentBlock: [*:0]u16) callconv(.winapi) windows.BOOL;
const EXTENDED_STARTUPINFO_PRESENT: windows.DWORD = 0x00080000;
const CREATE_UNICODE_ENVIRONMENT: windows.DWORD = 0x00000400;

const Backend = enum {
    conpty,
    wsl_bypass,
};

const ReaderState = struct {
    mutex: std.Thread.Mutex = .{},
    buf: std.ArrayListUnmanaged(u8) = .empty,
    start: usize = 0,
    eof: bool = false,
    saw_read: bool = false,
    exit_status: ?u32 = null,
};

pub const WindowsPty = struct {
    allocator: std.mem.Allocator,
    backend: Backend = .conpty,
    hpc: ?HPCON,
    process: windows.HANDLE,
    thread: windows.HANDLE,
    process_id: windows.DWORD,
    input_pipe_pty: windows.HANDLE,
    output_pipe_pty: windows.HANDLE,
    read_pipe: windows.HANDLE,
    write_pipe: windows.HANDLE,
    stderr_pipe: windows.HANDLE,
    reader_state: *ReaderState,
    reader_thread: ?std.Thread,
    pending_input: std.ArrayListUnmanaged(u8) = .empty,
    alive: bool = true,
    closed: bool = false,

    pub fn spawn(allocator: std.mem.Allocator, shell: [:0]const u8, cols: u16, rows: u16, cwd: ?[]const u8, env_block: ?[]const u8, launch_command: ?LaunchCommand) !WindowsPty {
        return spawnWithShell(allocator, shell, cols, rows, cwd, env_block, launch_command);
    }

    pub fn spawnWithFallbacks(allocator: std.mem.Allocator, preferred_shell: [:0]const u8, cols: u16, rows: u16, cwd: ?[]const u8, env_block: ?[]const u8, launch_command: ?LaunchCommand, fallbacks: []const []const u8) !WindowsPty {
        if (spawnWithShell(allocator, preferred_shell, cols, rows, cwd, env_block, launch_command)) |pty| {
            return pty;
        } else |err| switch (err) {
            error.CreateProcessFailed => {},
            else => return err,
        }

        for (fallbacks) |candidate| {
            if (std.mem.eql(u8, candidate, preferred_shell)) continue;
            const shell_z = try allocator.dupeZ(u8, candidate);
            defer allocator.free(shell_z);
            if (spawnWithShell(allocator, shell_z, cols, rows, cwd, env_block, launch_command)) |pty| {
                return pty;
            } else |err| switch (err) {
                error.CreateProcessFailed => continue,
                else => return err,
            }
        }

        return error.CreateProcessFailed;
    }

    fn spawnWithShell(allocator: std.mem.Allocator, shell: [:0]const u8, cols: u16, rows: u16, cwd: ?[]const u8, env_block: ?[]const u8, launch_command: ?LaunchCommand) !WindowsPty {
        if (isWslShell(shell)) {
            if (spawnWithWslBypass(allocator, shell, cols, rows, cwd, env_block, launch_command)) |pty| {
                return pty;
            } else |err| switch (err) {
                error.WslBypassUnavailable => {
                    std.log.warn("wsl bypass unavailable, falling back to ConPTY shell={s}", .{shell});
                },
                else => return err,
            }
        }

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
            std.log.err("conpty InitializeProcThreadAttributeList failed err={d}", .{kernel32.GetLastError()});
            return error.AttributeListInitFailed;
        }
        defer DeleteProcThreadAttributeList(attr_mem.ptr);

        // lpValue must be the HPCON value itself (a pointer), not a pointer-to-HPCON.
        // MSDN: UpdateProcThreadAttribute for PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE takes
        // lpValue = HPCON, cbSize = sizeof(HPCON).
        if (UpdateProcThreadAttribute(attr_mem.ptr, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc.?, @sizeOf(HPCON), null, null) == 0) {
            std.log.err("conpty UpdateProcThreadAttribute failed err={d}", .{kernel32.GetLastError()});
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
        const spec = try buildCommandSpec(allocator, shell, cwd, launch_command);
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
            std.log.err("conpty CreateProcessW failed err={d}", .{kernel32.GetLastError()});
            return error.CreateProcessFailed;
        }
        std.log.info("conpty spawned process pid={d} shell={s}", .{ pi.dwProcessId, spec.log_command });

        // Non-blocking check for immediate spawn failure (bad args, missing exe, etc.).
        if (kernel32.WaitForSingleObject(pi.hProcess, 0) == WAIT_OBJECT_0) {
            var exit_code: windows.DWORD = 0;
            _ = kernel32.GetExitCodeProcess(pi.hProcess, &exit_code);
            std.log.warn("conpty child exited immediately after spawn code={d}", .{exit_code});
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
            .backend = .conpty,
            .hpc = hpc.?,
            .process = pi.hProcess,
            .thread = pi.hThread,
            .process_id = pi.dwProcessId,
            .input_pipe_pty = input_read, // kept open (closing it breaks ConPTY input on some configs)
            .output_pipe_pty = windows.INVALID_HANDLE_VALUE, // already closed
            .read_pipe = output_read,
            .write_pipe = input_write,
            .stderr_pipe = windows.INVALID_HANDLE_VALUE,
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
        const pending = self.reader_state.buf.items.len - self.reader_state.start;
        self.reader_state.mutex.unlock();
        if (eof) {
            self.alive = false;
            switch (self.backend) {
                .conpty => std.log.info("conpty pipe closed (shell exited)", .{}),
                .wsl_bypass => {
                    self.logWslBypassDiagnostics();
                },
            }
            return false;
        }

        if (saw_read and pending > 0) return true;

        if (self.process != windows.INVALID_HANDLE_VALUE and @intFromPtr(self.process) != 0) {
            if (kernel32.WaitForSingleObject(self.process, 0) == WAIT_OBJECT_0) {
                self.alive = false;
                std.log.info("conpty process exited (WaitForSingleObject)", .{});
                return false;
            }
        }

        return true;
    }

    pub fn read(self: *WindowsPty, buffer: []u8) !usize {
        if (buffer.len == 0) return 0;
        try self.flushPendingInputIfReady();
        self.reader_state.mutex.lock();
        defer self.reader_state.mutex.unlock();

        const pending = self.reader_state.buf.items.len - self.reader_state.start;
        if (pending == 0) return 0;

        const count = @min(buffer.len, pending);
        fastmem.copy(u8, buffer[0..count], self.reader_state.buf.items[self.reader_state.start .. self.reader_state.start + count]);
        self.reader_state.start += count;
        if (self.reader_state.start == self.reader_state.buf.items.len) {
            self.reader_state.buf.items.len = 0;
            self.reader_state.start = 0;
        } else if (self.reader_state.start >= 65536 and self.reader_state.start * 2 >= self.reader_state.buf.items.len) {
            const remaining = self.reader_state.buf.items.len - self.reader_state.start;
            fastmem.move(u8, self.reader_state.buf.items[0..remaining], self.reader_state.buf.items[self.reader_state.start..]);
            self.reader_state.buf.items.len = remaining;
            self.reader_state.start = 0;
        }
        return count;
    }

    pub fn hasPendingOutput(self: *WindowsPty) bool {
        self.reader_state.mutex.lock();
        defer self.reader_state.mutex.unlock();
        return self.reader_state.buf.items.len > self.reader_state.start;
    }

    pub fn writeAll(self: *WindowsPty, bytes: []const u8) !void {
        if (!self.shellProducedOutput()) {
            try self.pending_input.appendSlice(self.allocator, bytes);
            return;
        }
        try self.flushPendingInputIfReady();
        try self.writeToPty(bytes);
    }

    fn writeToPty(self: *WindowsPty, bytes: []const u8) !void {
        switch (self.backend) {
            .conpty => {
                var offset: usize = 0;
                while (offset < bytes.len) {
                    var written: windows.DWORD = 0;
                    const chunk: windows.DWORD = @intCast(bytes.len - offset);
            const ok = kernel32.WriteFile(self.write_pipe, bytes.ptr + offset, chunk, &written, null);
            if (ok == windows.FALSE) {
                const err = kernel32.GetLastError();
                        std.log.err("conpty WriteFile failed err={d} written={d}", .{ err, written });
                        return error.WriteFailed;
                    }
                    if (written == 0) return error.WriteFailed;
                    offset += written;
                }
            },
            .wsl_bypass => try sendBypassFrame(self.write_pipe, .input, bytes),
        }
    }

    fn shellProducedOutput(self: *WindowsPty) bool {
        self.reader_state.mutex.lock();
        defer self.reader_state.mutex.unlock();
        return self.reader_state.saw_read;
    }

    fn flushPendingInputIfReady(self: *WindowsPty) !void {
        if (self.pending_input.items.len == 0 or !self.shellProducedOutput()) return;
        const pending = try self.pending_input.toOwnedSlice(self.allocator);
        defer self.allocator.free(pending);
        self.pending_input.clearRetainingCapacity();
        try self.writeToPty(pending);
    }

    pub fn resize(self: *WindowsPty, cols: u16, rows: u16) void {
        switch (self.backend) {
            .conpty => if (self.hpc) |hpc| {
                _ = ResizePseudoConsole(hpc, .{ .X = @intCast(cols), .Y = @intCast(rows) });
            },
            .wsl_bypass => {
                var payload: [4]u8 = undefined;
                std.mem.writeInt(u16, payload[0..2], cols, .little);
                std.mem.writeInt(u16, payload[2..4], rows, .little);
                sendBypassFrame(self.write_pipe, .resize, &payload) catch |err| {
                    std.log.warn("wsl bypass resize failed: {s}", .{@errorName(err)});
                };
            },
        }
    }

    pub fn childPid(self: *const WindowsPty) usize {
        return @intCast(self.process_id);
    }

    pub fn usesWslBypass(self: *const WindowsPty) bool {
        return self.backend == .wsl_bypass;
    }

    pub fn close(self: *WindowsPty) void {
        if (self.closed) return;
        std.log.info("WindowsPty.close backend={s} pid={d}", .{ @tagName(self.backend), self.process_id });
        switch (self.backend) {
            .conpty => {
                // Terminate the child process if still alive.
                if (self.isAlive()) _ = kernel32.TerminateProcess(self.process, 0);
                // ClosePseudoConsole MUST come before closing read_pipe and before
                // thread.join().  It tears down the ConPTY, which causes the in-flight
                // ReadFile on read_pipe (in the reader thread) to return immediately with
                // an error — unblocking the thread.  Closing read_pipe first leaves
                // ReadFile in an undefined state and can hang the join forever.
                if (self.hpc) |hpc| ClosePseudoConsole(hpc);
            },
            .wsl_bypass => {
                _ = sendBypassFrame(self.write_pipe, .exit, &.{}) catch {};
                if (self.process != windows.INVALID_HANDLE_VALUE and @intFromPtr(self.process) != 0) {
                    _ = kernel32.WaitForSingleObject(self.process, WSL_BYPASS_EXIT_TIMEOUT_MS);
                    if (kernel32.WaitForSingleObject(self.process, 0) != WAIT_OBJECT_0) {
                        _ = kernel32.TerminateProcess(self.process, 0);
                    }
                }
            },
        }
        closeHandleIfValid(self.input_pipe_pty);
        closeHandleIfValid(self.output_pipe_pty);
        closeHandleIfValid(self.read_pipe);
        closeHandleIfValid(self.write_pipe);
        closeHandleIfValid(self.stderr_pipe);
        if (self.reader_thread) |thread| thread.join();
        closeHandleIfValid(self.process);
        closeHandleIfValid(self.thread);
        self.pending_input.deinit(self.allocator);
        self.reader_state.buf.deinit(std.heap.page_allocator);
        self.allocator.destroy(self.reader_state);
        self.closed = true;
        self.alive = false;
    }

    fn logWslBypassDiagnostics(self: *WindowsPty) void {
        self.reader_state.mutex.lock();
        const exit_status = self.reader_state.exit_status;
        self.reader_state.mutex.unlock();

        if (exit_status) |status| {
            std.log.info("wsl bypass stream closed exit_status={d}", .{status});
        } else {
            std.log.info("wsl bypass stream closed without exit frame", .{});
        }

        if (self.process != windows.INVALID_HANDLE_VALUE and @intFromPtr(self.process) != 0 and kernel32.WaitForSingleObject(self.process, 0) == WAIT_OBJECT_0) {
            var process_exit_code: windows.DWORD = 0;
            _ = kernel32.GetExitCodeProcess(self.process, &process_exit_code);
            std.log.info("wsl bypass process exited code={d}", .{process_exit_code});
        }

        logAvailableBypassStderr(self.stderr_pipe);
    }
};

fn spawnWithWslBypass(allocator: std.mem.Allocator, shell: [:0]const u8, cols: u16, rows: u16, cwd: ?[]const u8, env_block: ?[]const u8, launch_command: ?LaunchCommand) !WindowsPty {
    const start_ms = std.time.milliTimestamp();

    {
        const parsed = try parseCommandString(allocator, shell);
        defer freeArgv(allocator, parsed);
        const distro_key = wslDistroKey(parsed);
        if (!wsl_boot_state.isBooted(distro_key)) {
            std.log.info("wsl bootstrap first use distro={s} …", .{distro_key});
            bootstrapWslDistro(allocator, shell) catch |err| {
                std.log.warn("wsl bootstrap failed err={s}", .{@errorName(err)});
                return error.WslBypassUnavailable;
            };
            wsl_boot_state.markBooted(distro_key);
        }
    }

    var child_stdin_read: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    var child_stdout_write: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    var child_stderr_write: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    var parent_stdin_write: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    var parent_stdout_read: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    var parent_stderr_read: windows.HANDLE = windows.INVALID_HANDLE_VALUE;

    try createPipe(&child_stdin_read, &parent_stdin_write);
    errdefer closeHandleIfValid(child_stdin_read);
    errdefer closeHandleIfValid(parent_stdin_write);
    try createPipe(&parent_stdout_read, &child_stdout_write);
    errdefer closeHandleIfValid(parent_stdout_read);
    errdefer closeHandleIfValid(child_stdout_write);
    try createPipe(&parent_stderr_read, &child_stderr_write);
    errdefer closeHandleIfValid(parent_stderr_read);
    errdefer closeHandleIfValid(child_stderr_write);

    if (SetHandleInformation(parent_stdin_write, HANDLE_FLAG_INHERIT, 0) == windows.FALSE) return error.SetHandleInformationFailed;
    if (SetHandleInformation(parent_stdout_read, HANDLE_FLAG_INHERIT, 0) == windows.FALSE) return error.SetHandleInformationFailed;
    if (SetHandleInformation(parent_stderr_read, HANDLE_FLAG_INHERIT, 0) == windows.FALSE) return error.SetHandleInformationFailed;

    var si = std.mem.zeroes(STARTUPINFOEXW);
    si.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    si.StartupInfo.wShowWindow = SW_HIDE;
    si.StartupInfo.hStdInput = child_stdin_read;
    si.StartupInfo.hStdOutput = child_stdout_write;
    si.StartupInfo.hStdError = child_stderr_write;

    var pi = std.mem.zeroes(windows.PROCESS_INFORMATION);
    const spec = try buildWslBypassCommandSpec(allocator, shell, cols, rows, cwd, env_block, launch_command);
    defer freeSentinelU16(allocator, spec.application_utf16);
    defer freeSentinelU16(allocator, spec.command_line_utf16);
    defer freeSentinelU8(allocator, spec.log_command);

    const shell_name = std.fs.path.basename(shellProgram(shell));
    const env_block_utf16 = try buildEnvironmentBlock(allocator, env_block, shell_name);
    defer if (env_block_utf16) |block| freeSentinelU16(allocator, block);

    if (CreateProcessW(
        spec.application_utf16.ptr,
        spec.command_line_utf16.ptr,
        null,
        null,
        windows.TRUE,
        CREATE_UNICODE_ENVIRONMENT | CREATE_NEW_CONSOLE,
        if (env_block_utf16) |block| @as(?*anyopaque, @ptrCast(block.ptr)) else null,
        null,
        &si.StartupInfo,
        &pi,
    ) == windows.FALSE) {
        std.log.warn("wsl bypass CreateProcessW failed err={d}", .{kernel32.GetLastError()});
        return error.WslBypassUnavailable;
    }

    closeHandleIfValid(child_stdin_read);
    child_stdin_read = windows.INVALID_HANDLE_VALUE;
    closeHandleIfValid(child_stdout_write);
    child_stdout_write = windows.INVALID_HANDLE_VALUE;
    closeHandleIfValid(child_stderr_write);
    child_stderr_write = windows.INVALID_HANDLE_VALUE;

    const reader_state = try allocator.create(ReaderState);
    reader_state.* = .{};

    var pty = WindowsPty{
        .allocator = allocator,
        .backend = .wsl_bypass,
        .hpc = null,
        .process = pi.hProcess,
        .thread = pi.hThread,
        .process_id = pi.dwProcessId,
        .input_pipe_pty = windows.INVALID_HANDLE_VALUE,
        .output_pipe_pty = windows.INVALID_HANDLE_VALUE,
        .read_pipe = parent_stdout_read,
        .write_pipe = parent_stdin_write,
        .stderr_pipe = parent_stderr_read,
        .reader_state = reader_state,
        .reader_thread = null,
    };

    if (!readBypassHello(pty.process, pty.read_pipe, pty.reader_state, WSL_BYPASS_STARTUP_TIMEOUT_MS)) {
        pty.close();
        return error.WslBypassUnavailable;
    }

    pty.reader_thread = try std.Thread.spawn(.{}, wslBypassReaderLoop, .{ pty.read_pipe, pty.reader_state });

    std.log.info("wsl bypass ready pid={d} shell={s} startup_ms={d}", .{ pty.process_id, spec.log_command, std.time.milliTimestamp() - start_ms });
    return pty;
}

fn readerLoop(read_pipe: windows.HANDLE, reader_state: *ReaderState) void {
    var temp: [4096]u8 = undefined;
    var loop_count: u64 = 0;
    std.log.info("conpty reader thread started", .{});
    while (true) {
        var read_count: windows.DWORD = 0;
        const ok = kernel32.ReadFile(read_pipe, &temp, temp.len, &read_count, null);
        loop_count += 1;
        if (ok == windows.FALSE) {
            const err = kernel32.GetLastError();
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
        reader_state.buf.appendSlice(std.heap.page_allocator, temp[0..read_count]) catch {};
        reader_state.mutex.unlock();
        app.signalExternalWake();
    }
}

fn wslBypassReaderLoop(read_pipe: windows.HANDLE, reader_state: *ReaderState) void {
    var temp: [4096]u8 = undefined;
    while (true) {
        var header: [5]u8 = undefined;
        readExactHandle(read_pipe, &header) catch {
            markReaderEof(reader_state);
            return;
        };

        const frame_type = parseBypassFrameType(header[0]) orelse {
            markReaderEof(reader_state);
            return;
        };
        var remaining: usize = std.mem.readInt(u32, header[1..5], .little);
        switch (frame_type) {
            .hello => {
                if (!consumeHelloPayload(read_pipe, @intCast(remaining), &temp)) {
                    markReaderEof(reader_state);
                    return;
                }
            },
            .output => {
                while (remaining > 0) {
                    const chunk = @min(remaining, temp.len);
                    readExactHandle(read_pipe, temp[0..chunk]) catch {
                        markReaderEof(reader_state);
                        return;
                    };
                    pushReaderBytes(reader_state, temp[0..chunk]);
                    remaining -= chunk;
                }
            },
            .exit => {
                var exit_status: ?u32 = null;
                if (remaining == 4) {
                    var payload: [4]u8 = undefined;
                    readExactHandle(read_pipe, &payload) catch {
                        markReaderEof(reader_state);
                        return;
                    };
                    exit_status = std.mem.readInt(u32, &payload, .little);
                } else if (remaining > 0) {
                    tryDiscardPayload(read_pipe, remaining) catch {};
                }
                markReaderExit(reader_state, exit_status);
                return;
            },
            else => {
                tryDiscardPayload(read_pipe, remaining) catch {
                    markReaderEof(reader_state);
                    return;
                };
            },
        }
    }
}

fn parseBypassFrameType(byte: u8) ?wsl_bypass_protocol.FrameType {
    return switch (byte) {
        @intFromEnum(wsl_bypass_protocol.FrameType.hello) => .hello,
        @intFromEnum(wsl_bypass_protocol.FrameType.input) => .input,
        @intFromEnum(wsl_bypass_protocol.FrameType.output) => .output,
        @intFromEnum(wsl_bypass_protocol.FrameType.resize) => .resize,
        @intFromEnum(wsl_bypass_protocol.FrameType.exit) => .exit,
        else => null,
    };
}

fn createPipe(read_pipe: *windows.HANDLE, write_pipe: *windows.HANDLE) !void {
    var sa = std.mem.zeroes(windows.SECURITY_ATTRIBUTES);
    sa.nLength = @sizeOf(windows.SECURITY_ATTRIBUTES);
    sa.bInheritHandle = windows.TRUE;
    if (CreatePipe(read_pipe, write_pipe, &sa, 0) == windows.FALSE) return error.CreatePipeFailed;
}

fn readExactHandle(handle: windows.HANDLE, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        var read_count: windows.DWORD = 0;
        const chunk: windows.DWORD = @intCast(buffer.len - offset);
        const ok = kernel32.ReadFile(handle, buffer.ptr + offset, chunk, &read_count, null);
        if (ok == windows.FALSE) return error.ReadFailed;
        if (read_count == 0) return error.EndOfStream;
        offset += read_count;
    }
}

fn tryDiscardPayload(handle: windows.HANDLE, bytes: usize) !void {
    var remaining = bytes;
    var buf: [256]u8 = undefined;
    while (remaining > 0) {
        const chunk = @min(remaining, buf.len);
        try readExactHandle(handle, buf[0..chunk]);
        remaining -= chunk;
    }
}

fn pushReaderBytes(reader_state: *ReaderState, bytes: []const u8) void {
    reader_state.mutex.lock();
    defer reader_state.mutex.unlock();
    reader_state.saw_read = true;
    if (reader_state.start > 0 and reader_state.start + bytes.len > reader_state.buf.capacity) {
        const remaining = reader_state.buf.items.len - reader_state.start;
        fastmem.move(u8, reader_state.buf.items[0..remaining], reader_state.buf.items[reader_state.start..]);
        reader_state.buf.items.len = remaining;
        reader_state.start = 0;
    }
    reader_state.buf.appendSlice(std.heap.page_allocator, bytes) catch {};
    app.signalExternalWake();
}

fn markReaderEof(reader_state: *ReaderState) void {
    reader_state.mutex.lock();
    reader_state.eof = true;
    reader_state.mutex.unlock();
}

fn markReaderExit(reader_state: *ReaderState, exit_status: ?u32) void {
    reader_state.mutex.lock();
    reader_state.exit_status = exit_status;
    reader_state.eof = true;
    reader_state.mutex.unlock();
}

fn logAvailableBypassStderr(handle: windows.HANDLE) void {
    if (handle == windows.INVALID_HANDLE_VALUE or @intFromPtr(handle) == 0) return;

    var available: windows.DWORD = 0;
    if (PeekNamedPipe(handle, null, 0, null, &available, null) == windows.FALSE or available == 0) return;

    var buf: [1024]u8 = undefined;
    const to_read: windows.DWORD = @min(available, buf.len);
    var read_count: windows.DWORD = 0;
    if (kernel32.ReadFile(handle, &buf, to_read, &read_count, null) == windows.FALSE or read_count == 0) return;

    std.log.warn("wsl bypass stderr: {s}", .{std.mem.trim(u8, buf[0..read_count], "\r\n")});
}

fn readBypassHello(process: windows.HANDLE, read_pipe: windows.HANDLE, reader_state: *ReaderState, timeout_ms: u64) bool {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        var available: windows.DWORD = 0;
        if (PeekNamedPipe(read_pipe, null, 0, null, &available, null) != windows.FALSE and available >= 5) {
            break;
        }
        if (kernel32.WaitForSingleObject(process, 0) == WAIT_OBJECT_0) return false;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    var available: windows.DWORD = 0;
    if (PeekNamedPipe(read_pipe, null, 0, null, &available, null) == windows.FALSE or available < 5) return false;

    var header: [5]u8 = undefined;
    readExactHandle(read_pipe, &header) catch return false;
    const frame_type = parseBypassFrameType(header[0]) orelse return false;
    if (frame_type != .hello) return false;

    var temp: [64]u8 = undefined;
    if (!consumeHelloPayload(read_pipe, std.mem.readInt(u32, header[1..5], .little), &temp)) return false;

    reader_state.mutex.lock();
    reader_state.saw_read = true;
    reader_state.mutex.unlock();
    return true;
}

fn consumeHelloPayload(read_pipe: windows.HANDLE, remaining_u32: u32, temp: []u8) bool {
    const remaining: usize = remaining_u32;
    if (remaining != wsl_bypass_protocol.hello_payload.len) {
        tryDiscardPayload(read_pipe, remaining) catch return false;
        return false;
    }

    if (remaining > temp.len) return false;
    readExactHandle(read_pipe, temp[0..remaining]) catch return false;
    return std.mem.eql(u8, temp[0..remaining], wsl_bypass_protocol.hello_payload[0..]);
}

fn sendBypassFrame(handle: windows.HANDLE, frame_type: wsl_bypass_protocol.FrameType, payload: []const u8) !void {
    var header: [5]u8 = undefined;
    header[0] = @intFromEnum(frame_type);
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);
    var written: windows.DWORD = 0;
    if (kernel32.WriteFile(handle, &header, header.len, &written, null) == windows.FALSE or written != @as(windows.DWORD, header.len)) {
        return error.WriteFailed;
    }
    if (payload.len == 0) return;
    try writeHandleAll(handle, payload);
}

fn writeHandleAll(handle: windows.HANDLE, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var written: windows.DWORD = 0;
        const chunk: windows.DWORD = @intCast(bytes.len - offset);
        if (kernel32.WriteFile(handle, bytes.ptr + offset, chunk, &written, null) == windows.FALSE) return error.WriteFailed;
        if (written == 0) return error.WriteFailed;
        offset += written;
    }
}

fn buildWslBypassCommandSpec(allocator: std.mem.Allocator, shell: [:0]const u8, cols: u16, rows: u16, cwd: ?[]const u8, env_block: ?[]const u8, launch_command: ?LaunchCommand) !CommandSpec {
    const parsed_shell = try parseCommandString(allocator, shell);
    defer freeArgv(allocator, parsed_shell);
    if (parsed_shell.len == 0) return error.InvalidCharacter;

    const split = splitWslLauncherArgs(parsed_shell);
    if (split.launcher.len == 0) return error.InvalidCharacter;

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(allocator, split.launcher);
    const owned_start = argv.items.len;
    defer {
        freeArgvOwnedStrings(allocator, argv.items[owned_start..]);
        argv.deinit(allocator);
    }

    try argv.append(allocator, try allocator.dupe(u8, "--exec"));
    try argv.append(allocator, try allocator.dupe(u8, "/tmp/hollow-wsl-bypass"));
    try argv.append(allocator, try allocator.dupe(u8, "--cols"));
    try argv.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{cols}));
    try argv.append(allocator, try allocator.dupe(u8, "--rows"));
    try argv.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{rows}));

    if (cwd) |dir| {
        if (dir.len > 0) {
            try argv.append(allocator, try allocator.dupe(u8, "--cwd"));
            try argv.append(allocator, try allocator.dupe(u8, dir));
        }
    }

    for (split.inner) |arg| {
        try argv.append(allocator, try allocator.dupe(u8, "--shell-arg"));
        try argv.append(allocator, try allocator.dupe(u8, arg));
    }

    if (launch_command) |cmd| {
        try argv.append(allocator, try allocator.dupe(u8, "--command"));
        try argv.append(allocator, try allocator.dupe(u8, cmd.command));
        if (cmd.close_on_exit) {
            try argv.append(allocator, try allocator.dupe(u8, "--close-on-exit"));
        }
    }

    if (env_block) |block| {
        var i: usize = 0;
        while (i < block.len) {
            const start = i;
            while (i < block.len and block[i] != 0) : (i += 1) {}
            if (i > start) {
                try argv.append(allocator, try allocator.dupe(u8, "--env"));
                try argv.append(allocator, try allocator.dupe(u8, block[start..i]));
            }
            i += 1;
            if (i < block.len and block[i] == 0) break;
        }
    }

    const command_line = try windowsCreateCommandLine(allocator, argv.items);
    errdefer freeSentinelU8(allocator, command_line);

    const application = try resolveWindowsProgram(allocator, split.launcher[0]);
    defer allocator.free(application);

    return .{
        .application_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(allocator, application),
        .command_line_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(allocator, command_line),
        .cwd_utf16 = null,
        .log_command = command_line,
    };
}

const WslLauncherSplit = struct {
    launcher: []const []const u8,
    inner: []const []const u8,
};

fn splitWslLauncherArgs(argv: []const []const u8) WslLauncherSplit {
    if (argv.len == 0) return .{ .launcher = &.{}, .inner = &.{} };
    var index: usize = 1;
    while (index < argv.len) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--exec")) {
            return .{ .launcher = argv[0..index], .inner = argv[index + 1 ..] };
        }
        if (!std.mem.startsWith(u8, arg, "-")) break;
        if (wslOptionTakesValue(arg)) {
            if (index + 1 >= argv.len) break;
            index += 2;
            continue;
        }
        index += 1;
    }
    return .{ .launcher = argv[0..index], .inner = argv[index..] };
}

fn wslOptionTakesValue(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-d") or
        std.mem.eql(u8, arg, "--distribution") or
        std.mem.eql(u8, arg, "-u") or
        std.mem.eql(u8, arg, "--user") or
        std.mem.eql(u8, arg, "--cd");
}

fn isWslShell(shell: []const u8) bool {
    const shell_name = std.fs.path.basename(shellProgram(shell));
    return std.mem.eql(u8, shell_name, "wsl.exe") or std.mem.eql(u8, shell_name, "wsl");
}

fn closeHandleIfValid(handle: windows.HANDLE) void {
    if (handle != windows.INVALID_HANDLE_VALUE and @intFromPtr(handle) != 0) {
        _ = CloseHandle(handle);
    }
}

fn freeSentinelU8(allocator: std.mem.Allocator, bytes: [:0]u8) void {
    allocator.free(@as([*]u8, @ptrCast(bytes.ptr))[0 .. bytes.len + 1]);
}

fn freeSentinelU16(allocator: std.mem.Allocator, bytes: [:0]u16) void {
    allocator.free(@as([*]u16, @ptrCast(bytes.ptr))[0 .. bytes.len + 1]);
}

fn writePowershellProfile(allocator: std.mem.Allocator) ![]u8 {
    const temp_dir = std.process.getEnvVarOwned(allocator, "TEMP") catch
        std.process.getEnvVarOwned(allocator, "TMP") catch
        try allocator.dupe(u8, "C:\\Windows\\Temp");
    defer allocator.free(temp_dir);

    const pid = windows.GetCurrentProcessId();
    const profile_dir = try std.fmt.allocPrint(allocator, "{s}\\hollow-{d}\\", .{ temp_dir, pid });
    defer allocator.free(profile_dir);

    const profile_path = try std.fmt.allocPrint(allocator, "{s}powershell.ps1", .{profile_dir});
    errdefer allocator.free(profile_path);

    std.fs.cwd().makePath(profile_dir) catch {};
    if (std.fs.accessAbsolute(profile_path, .{})) |_| {} else |_| {
        if (std.fs.createFileAbsolute(profile_path, .{})) |f| {
            defer f.close();
            f.writeAll(build_options.embedded_powershell_integration) catch {};
        } else |_| {}
    }

    return profile_path;
}

const CommandSpec = struct {
    application_utf16: [:0]u16,
    command_line_utf16: [:0]u16,
    cwd_utf16: ?[:0]u16,
    log_command: [:0]u8,
};

fn buildCommandSpec(allocator: std.mem.Allocator, shell: [:0]const u8, cwd: ?[]const u8, launch_command: ?LaunchCommand) !CommandSpec {
    const shell_program = shellProgram(shell);
    const shell_name = std.fs.path.basename(shell_program);
    const argv = try buildArgv(allocator, shell, shell_name, cwd, launch_command);
    defer freeArgv(allocator, argv);

    const command_line = try windowsCreateCommandLine(allocator, argv);
    errdefer freeSentinelU8(allocator, command_line);
    const application = try resolveWindowsProgram(allocator, shell_program);
    defer allocator.free(application);

    return .{
        .application_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(allocator, application),
        .command_line_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(allocator, command_line),
        .cwd_utf16 = if (cwd) |value|
            if ((std.mem.eql(u8, shell_name, "wsl.exe") or std.mem.eql(u8, shell_name, "wsl")) or value.len == 0) null else try std.unicode.utf8ToUtf16LeAllocZ(allocator, value)
        else
            null,
        .log_command = command_line,
    };
}

fn buildArgv(allocator: std.mem.Allocator, shell: [:0]const u8, shell_name: []const u8, cwd: ?[]const u8, launch_command: ?LaunchCommand) ![]const []const u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        freeArgvOwnedStrings(allocator, argv.items);
        argv.deinit(allocator);
    }

    const shell_argv = try parseCommandString(allocator, shell);
    defer allocator.free(shell_argv);
    if (shell_argv.len == 0) return error.InvalidCharacter;
    const wrapped_program = if ((std.mem.eql(u8, shell_name, "wsl.exe") or std.mem.eql(u8, shell_name, "wsl")) and shell_argv.len > 1)
        std.fs.path.basename(shell_argv[1])
    else
        "";
    const shell_wraps_ssh = std.mem.eql(u8, wrapped_program, "ssh") or std.mem.eql(u8, wrapped_program, "ssh.exe");
    const shell_is_ssh = std.mem.eql(u8, shell_name, "ssh") or std.mem.eql(u8, shell_name, "ssh.exe");

    try argv.appendSlice(allocator, shell_argv);

    if (launch_command) |cmd| {
        const trimmed = std.mem.trimRight(u8, cmd.command, "\r\n");
        if (std.mem.eql(u8, shell_name, "cmd.exe") or std.mem.eql(u8, shell_name, "cmd")) {
            try argv.append(allocator, try allocator.dupe(u8, "/Q"));
            try argv.append(allocator, try allocator.dupe(u8, if (cmd.close_on_exit) "/C" else "/K"));
            const wrapped = try allocator.dupe(u8, trimmed);
            try argv.append(allocator, wrapped);
        } else if (isPowershell(shell_name)) {
            const profile_path = try writePowershellProfile(allocator);
            defer allocator.free(profile_path);
            if (!cmd.close_on_exit) try argv.append(allocator, try allocator.dupe(u8, "-NoExit"));
            try argv.append(allocator, try allocator.dupe(u8, "-ExecutionPolicy"));
            try argv.append(allocator, try allocator.dupe(u8, "Bypass"));
            try argv.append(allocator, try allocator.dupe(u8, "-Command"));
            const wrapped = try std.fmt.allocPrint(allocator, ". '{s}'; {s}", .{ profile_path, trimmed });
            try argv.append(allocator, wrapped);
        } else if (std.mem.eql(u8, shell_name, "wsl.exe") or std.mem.eql(u8, shell_name, "wsl")) {
            if (shell_wraps_ssh) {
                if (argv.items.len >= 3) {
                    try argv.insert(allocator, 2, try allocator.dupe(u8, "-tt"));
                } else {
                    try argv.append(allocator, try allocator.dupe(u8, "-tt"));
                }
                const wrapped = if (cmd.close_on_exit)
                    try std.fmt.allocPrint(allocator, "{s}; exit", .{trimmed})
                else
                    try allocator.dupe(u8, trimmed);
                try argv.append(allocator, wrapped);
                return try argv.toOwnedSlice(allocator);
            }
            if (cwd) |dir| {
                if (dir.len > 0) {
                    try argv.append(allocator, try allocator.dupe(u8, "--cd"));
                    try argv.append(allocator, try allocator.dupe(u8, dir));
                }
            }
            try argv.append(allocator, try allocator.dupe(u8, "sh"));
            try argv.append(allocator, try allocator.dupe(u8, "-lc"));
            const wrapped = if (cmd.close_on_exit)
                try std.fmt.allocPrint(allocator, "{s}; exit", .{trimmed})
            else
                try allocator.dupe(u8, trimmed);
            try argv.append(allocator, wrapped);
        } else {
            if (shell_is_ssh) {
                try argv.append(allocator, try allocator.dupe(u8, "-tt"));
            }
            const wrapped = if (cmd.close_on_exit)
                try std.fmt.allocPrint(allocator, "{s} & exit", .{trimmed})
            else
                try allocator.dupe(u8, trimmed);
            try argv.append(allocator, wrapped);
        }
    } else if (isPowershell(shell_name)) {
        const profile_path = try writePowershellProfile(allocator);
        defer allocator.free(profile_path);
        try argv.append(allocator, try allocator.dupe(u8, "-NoLogo"));
        try argv.append(allocator, try allocator.dupe(u8, "-NoExit"));
        try argv.append(allocator, try allocator.dupe(u8, "-ExecutionPolicy"));
        try argv.append(allocator, try allocator.dupe(u8, "Bypass"));
        try argv.append(allocator, try allocator.dupe(u8, "-Command"));
        const wrapped = try std.fmt.allocPrint(allocator, ". '{s}'", .{profile_path});
        try argv.append(allocator, wrapped);
    } else if ((std.mem.eql(u8, shell_name, "cmd.exe") or std.mem.eql(u8, shell_name, "cmd"))) {
        try argv.append(allocator, try allocator.dupe(u8, "/Q"));
        try argv.append(allocator, try allocator.dupe(u8, "/K"));
        try argv.append(allocator, try allocator.dupe(u8, "echo [hollow] child started"));
    } else if ((std.mem.eql(u8, shell_name, "wsl.exe") or std.mem.eql(u8, shell_name, "wsl")) and !shell_wraps_ssh and cwd != null and cwd.?.len > 0) {
        try argv.append(allocator, try allocator.dupe(u8, "--cd"));
        try argv.append(allocator, try allocator.dupe(u8, cwd.?));
    }

    return try argv.toOwnedSlice(allocator);
}

fn isPowershell(shell_name: []const u8) bool {
    return std.mem.eql(u8, shell_name, "pwsh.exe") or
        std.mem.eql(u8, shell_name, "pwsh") or
        std.mem.eql(u8, shell_name, "powershell.exe") or
        std.mem.eql(u8, shell_name, "powershell");
}

fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    freeArgvOwnedStrings(allocator, argv);
    allocator.free(argv);
}

fn freeArgvOwnedStrings(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| allocator.free(arg);
}

fn parseCommandString(allocator: std.mem.Allocator, command: []const u8) ![]const []const u8 {
    var parts = std.ArrayList([]const u8).empty;
    errdefer {
        for (parts.items) |item| allocator.free(item);
        parts.deinit(allocator);
    }

    var current = std.ArrayList(u8).empty;
    defer current.deinit(allocator);

    var quote: ?u8 = null;

    for (command) |ch| {
        if (quote) |q| {
            if (ch == q) {
                quote = null;
            } else {
                try current.append(allocator, ch);
            }
            continue;
        }

        if (ch == '\'' or ch == '"') {
            quote = ch;
            continue;
        }

        if (std.ascii.isWhitespace(ch)) {
            if (current.items.len == 0) continue;
            try parts.append(allocator, try current.toOwnedSlice(allocator));
            current = std.ArrayList(u8).empty;
            continue;
        }

        try current.append(allocator, ch);
    }

    if (quote != null) return error.InvalidCharacter;
    if (current.items.len > 0) {
        try parts.append(allocator, try current.toOwnedSlice(allocator));
    }

    return try parts.toOwnedSlice(allocator);
}

fn resolveWindowsProgram(allocator: std.mem.Allocator, program: []const u8) ![]u8 {
    if (program.len == 0) return allocator.dupe(u8, program);
    if (std.fs.path.isAbsolute(program) or std.mem.indexOfAny(u8, program, "\\/") != null) {
        return allocator.dupe(u8, program);
    }

    if (searchWindowsPath(allocator, program)) |resolved| return resolved else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    if (std.fs.path.extension(program).len == 0) {
        const exe_name = try std.fmt.allocPrint(allocator, "{s}.exe", .{program});
        defer allocator.free(exe_name);
        if (searchWindowsPath(allocator, exe_name)) |resolved| return resolved else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    if (resolveSystemTool(allocator, program)) |resolved| return resolved else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    return allocator.dupe(u8, program);
}

fn searchWindowsPath(allocator: std.mem.Allocator, program: []const u8) ![]u8 {
    const wide_program = try std.unicode.utf8ToUtf16LeAllocZ(allocator, program);
    defer allocator.free(wide_program);

    const required = SearchPathW(null, wide_program.ptr, null, 0, null, null);
    if (required == 0) return error.FileNotFound;

    const buf = try allocator.allocSentinel(u16, required, 0);
    defer allocator.free(buf);

    const actual = SearchPathW(null, wide_program.ptr, null, required, buf.ptr, null);
    if (actual == 0) return error.FileNotFound;

    return std.unicode.utf16LeToUtf8Alloc(allocator, buf[0..actual]);
}

fn resolveSystemTool(allocator: std.mem.Allocator, program: []const u8) ![]u8 {
    const system_root = std.process.getEnvVarOwned(allocator, "SystemRoot") catch return error.FileNotFound;
    defer allocator.free(system_root);

    const base = std.fs.path.basename(program);
    const tool_name = if (std.fs.path.extension(base).len == 0)
        try std.fmt.allocPrint(allocator, "{s}.exe", .{base})
    else
        try allocator.dupe(u8, base);
    defer allocator.free(tool_name);

    if (std.ascii.eqlIgnoreCase(tool_name, "ssh.exe") or
        std.ascii.eqlIgnoreCase(tool_name, "scp.exe") or
        std.ascii.eqlIgnoreCase(tool_name, "sftp.exe"))
    {
        return std.fs.path.join(allocator, &.{ system_root, "System32", "OpenSSH", tool_name });
    }

    if (std.ascii.eqlIgnoreCase(tool_name, "wsl.exe") or
        std.ascii.eqlIgnoreCase(tool_name, "cmd.exe"))
    {
        return std.fs.path.join(allocator, &.{ system_root, "System32", tool_name });
    }

    if (std.ascii.eqlIgnoreCase(tool_name, "powershell.exe")) {
        return std.fs.path.join(allocator, &.{ system_root, "System32", "WindowsPowerShell", "v1.0", tool_name });
    }

    return error.FileNotFound;
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
    defer utf16_block.deinit(allocator);
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
