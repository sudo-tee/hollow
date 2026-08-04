const std = @import("std");
const protocol = @import("pty/wsl_bypass_protocol.zig");
const shell_integration = @import("shell_integration.zig");
const io = @import("io.zig");
const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("pwd.h");
    @cInclude("pty.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/uio.h");
    @cInclude("sys/wait.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

const LaunchCommand = struct {
    command: ?[]const u8 = null,
    close_on_exit: bool = false,
};

const EnvOverride = struct {
    key: []const u8,
    value: []const u8,
};

const Options = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    cwd: ?[]const u8 = null,
    shell_args: std.ArrayListUnmanaged([]const u8) = .empty,
    env: std.ArrayListUnmanaged(EnvOverride) = .empty,
    launch: LaunchCommand = .{},

    fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        if (self.cwd) |cwd| allocator.free(cwd);
        for (self.shell_args.items) |arg| allocator.free(arg);
        self.shell_args.deinit(allocator);
        for (self.env.items) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        self.env.deinit(allocator);
        if (self.launch.command) |command| allocator.free(command);
        self.* = .{};
    }
};

const HostInputState = struct {
    header: [5]u8 = undefined,
    header_len: usize = 0,
    frame_type: ?protocol.FrameType = null,
    payload_remaining: usize = 0,
    resize_payload: [4]u8 = undefined,
    resize_len: usize = 0,
    pending: [4096]u8 = undefined,
    pending_offset: usize = 0,
    pending_len: usize = 0,
    discard: [256]u8 = undefined,

    fn hasPendingWrite(self: *const HostInputState) bool {
        return self.pending_offset < self.pending_len;
    }

    fn resetFrame(self: *HostInputState) void {
        self.header_len = 0;
        self.frame_type = null;
        self.payload_remaining = 0;
        self.resize_len = 0;
        self.pending_offset = 0;
        self.pending_len = 0;
    }
};

const NonBlockingRead = union(enum) {
    data: usize,
    would_block,
    eof,
};

const termination_grace_ms: i64 = 1500;
pub fn main(init: std.process.Init) !void {
    io.init(init.io, init.minimal.environ);
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Keep write failures on the host pipes in-band as EPIPE so deferred cleanup
    // still runs and reaps the shell child.
    var sa = std.mem.zeroes(c.struct_sigaction);
    sa.__sa_handler.sa_handler = @ptrFromInt(1);
    _ = c.sigemptyset(&sa.sa_mask);
    _ = c.sigaction(c.SIGPIPE, &sa, null);

    const options = parseArgs(allocator, init.minimal.args) catch return;
    defer {
        var owned = options;
        owned.deinit(allocator);
    }

    try run(allocator, options);
}

fn run(allocator: std.mem.Allocator, options: Options) !void {
    const shell_path = if (options.shell_args.items.len > 0) options.shell_args.items[0] else try defaultShellPath(allocator);
    defer if (options.shell_args.items.len == 0) allocator.free(shell_path);
    const bundle = try shell_integration.install(allocator, shell_path);
    if (bundle) |value| try shell_integration.setupEnv(allocator, value);
    const shell_argv = try buildShellArgv(allocator, options.shell_args.items, options.launch, bundle);
    defer freeExecArgv(allocator, shell_argv);

    const stderr_copy = c.dup(std.Io.File.stderr().handle);
    defer {
        if (stderr_copy >= 0) _ = c.close(stderr_copy);
    }
    if (stderr_copy >= 0) {
        const fd_flags = c.fcntl(stderr_copy, c.F_GETFD, @as(c_int, 0));
        if (fd_flags >= 0) _ = c.fcntl(stderr_copy, c.F_SETFD, fd_flags | c.FD_CLOEXEC);
    }

    var winsize = std.mem.zeroes(c.struct_winsize);
    winsize.ws_col = options.cols;
    winsize.ws_row = options.rows;

    var child_reaped = false;
    var exit_status: u32 = 0;

    var master: c_int = -1;
    const pid = c.forkpty(&master, null, null, &winsize);
    if (pid == 0) {
        childExec(allocator, options, shell_argv) catch |err| {
            reportChildExecFailure(stderr_copy, options, shell_argv, err);
        };
        c._exit(127);
    }
    if (pid < 0) return error.ForkPtyFailed;

    defer _ = c.close(master);
    defer if (!child_reaped) {
        exit_status = terminateAndReapChild(pid);
        child_reaped = true;
    };

    const flags = c.fcntl(master, c.F_GETFL, @as(c_int, 0));
    if (flags >= 0) _ = c.fcntl(master, c.F_SETFL, flags | c.O_NONBLOCK);

    try writeFrame(std.Io.File.stdout(), .hello, protocol.hello_payload[0..]);

    const stdin_file = std.Io.File.stdin();
    const stdin_flags = c.fcntl(stdin_file.handle, c.F_GETFL, @as(c_int, 0));
    if (stdin_flags >= 0) _ = c.fcntl(stdin_file.handle, c.F_SETFL, stdin_flags | c.O_NONBLOCK);

    const stdout_file = std.Io.File.stdout();

    var input_closed = false;
    var master_closed = false;
    var host_input = HostInputState{};
    var termination_requested = false;
    var termination_deadline_ms: ?i64 = null;

    while (true) {
        var poll_fds = [_]c.struct_pollfd{
            .{ .fd = stdin_file.handle, .events = if (input_closed or host_input.hasPendingWrite()) 0 else c.POLLIN, .revents = 0 },
            .{ .fd = master, .events = @intCast(c.POLLIN | if (host_input.hasPendingWrite()) c.POLLOUT else 0), .revents = 0 },
            .{ .fd = stdout_file.handle, .events = 0, .revents = 0 },
        };

        _ = c.poll(&poll_fds, poll_fds.len, 50);

        if (!input_closed and (poll_fds[0].revents & (c.POLLIN | c.POLLERR | c.POLLHUP | c.POLLNVAL)) != 0) {
            const still_open = advanceHostInput(stdin_file, master, &host_input) catch false;
            if (!still_open) input_closed = true;
        }
        if (!input_closed and (poll_fds[2].revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL)) != 0) {
            input_closed = true;
        }

        if (input_closed and !termination_requested and !child_reaped) {
            terminateChildGroup(pid, c.SIGHUP);
            std.log.info("wsl bypass shutdown requested; terminating child pid={d}", .{pid});
            termination_requested = true;
            termination_deadline_ms = milliTimestamp() + termination_grace_ms;
        }

        if (!master_closed and host_input.hasPendingWrite()) {
            try writePendingInput(master, &host_input);
        }

        if ((poll_fds[1].revents & (c.POLLIN | c.POLLHUP | c.POLLERR)) != 0) {
            var buf: [65536]u8 = undefined;
            const count = c.read(master, &buf, buf.len);
            if (count > 0) {
                try writeFrame(stdout_file, .output, buf[0..@intCast(count)]);
            } else if (count == 0) {
                master_closed = true;
            } else switch (std.posix.errno(-1)) {
                .AGAIN, .INTR => {},
                else => master_closed = true,
            }
        }
        if ((poll_fds[1].revents & c.POLLNVAL) != 0) {
            master_closed = true;
        }

        if (!child_reaped) {
            var status: c_int = 0;
            const wait_result = c.waitpid(pid, &status, c.WNOHANG);
            if (wait_result == pid) {
                child_reaped = true;
                exit_status = childExitStatus(status);
                std.log.info("wsl bypass child reaped exit_status={d} shutdown={any}", .{ exit_status, termination_requested });
            }
        }

        if (termination_requested and !child_reaped and termination_deadline_ms != null and milliTimestamp() >= termination_deadline_ms.?) {
            terminateChildGroup(pid, c.SIGKILL);
            termination_deadline_ms = null;
        }

        if (child_reaped and (master_closed or termination_requested)) break;
    }

    var exit_payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &exit_payload, exit_status, .little);
    if (!input_closed) {
        try writeFrame(std.Io.File.stdout(), .exit, &exit_payload);
    } else {
        _ = writeFrame(std.Io.File.stdout(), .exit, &exit_payload) catch {};
    }
}

fn childExec(allocator: std.mem.Allocator, options: Options, argv: [:null]?[*:0]const u8) !void {
    if (options.cwd) |dir| {
        const cwd = try windowsPathToWsl(allocator, dir);
        defer allocator.free(cwd);
        const dir_z = try allocator.dupeZ(u8, cwd);
        defer allocator.free(dir_z);
        if (c.chdir(dir_z.ptr) != 0) return error.ChangeDirectoryFailed;
    }

    for (options.env.items) |entry| {
        const value = if (isPathEnvironmentVariable(entry.key))
            try windowsPathToWsl(allocator, entry.value)
        else
            try allocator.dupe(u8, entry.value);
        defer allocator.free(value);

        const key_z = try allocator.dupeZ(u8, entry.key);
        defer allocator.free(key_z);
        const value_z = try allocator.dupeZ(u8, value);
        defer allocator.free(value_z);
        if (c.setenv(key_z.ptr, value_z.ptr, 1) != 0) return error.SetEnvFailed;
    }

    if (options.shell_args.items.len == 0 and options.launch.command == null) {
        const shell = try defaultShellPath(allocator);
        defer allocator.free(shell);
        const shell_z = try allocator.dupeZ(u8, shell);
        defer allocator.free(shell_z);
        const shell_name = std.fs.path.basename(shell);
        if (std.mem.eql(u8, shell_name, "bash") or std.mem.eql(u8, shell_name, "sh") or std.mem.eql(u8, shell_name, "zsh") or std.mem.eql(u8, shell_name, "fish")) {
            _ = c.execl(shell_z.ptr, shell_z.ptr, "-i", @as(?*anyopaque, null));
        } else {
            _ = c.execl(shell_z.ptr, shell_z.ptr, @as(?*anyopaque, null));
        }
        return switch (std.posix.errno(-1)) {
            .NOENT => error.ExecNotFound,
            .ACCES => error.ExecAccessDenied,
            .FAULT => error.ExecBadAddress,
            else => error.ExecFailed,
        };
    }

    if (argv.len == 0 or argv[0] == null) return error.InvalidExe;
    _ = c.execvp(argv[0].?, @ptrCast(argv.ptr));
    return switch (std.posix.errno(-1)) {
        .NOENT => error.ExecNotFound,
        .ACCES => error.ExecAccessDenied,
        .FAULT => error.ExecBadAddress,
        else => error.ExecFailed,
    };
}

fn reportChildExecFailure(stderr_fd: c_int, options: Options, argv: [:null]?[*:0]const u8, err: anyerror) void {
    if (stderr_fd < 0) return;
    var stderr_buf: [256]u8 = undefined;
    var argv0_hex_buf: [96]u8 = undefined;
    const stderr_file = std.Io.File{ .handle = stderr_fd, .flags = .{ .nonblocking = false } };
    var stderr = stderr_file.writer(io.get(), &stderr_buf);
    const cwd = options.cwd orelse "<null>";
    const argv0 = if (argv.len > 0 and argv[0] != null) std.mem.span(argv[0].?) else "<null>";
    const argv0_hex = if (argv.len > 0 and argv[0] != null) previewHex(&argv0_hex_buf, argv[0].?) else "<null>";
    stderr.interface.print("hollow-wsl-bypass childExec failed err={s} cwd={s} argv0={s} argv0_hex={s}\n", .{ @errorName(err), cwd, argv0, argv0_hex }) catch {};
    stderr.interface.flush() catch {};
}

fn previewHex(buf: []u8, ptr: [*:0]const u8) []const u8 {
    var src_index: usize = 0;
    var dst_index: usize = 0;
    while (src_index < 16 and ptr[src_index] != 0 and dst_index + 2 <= buf.len) : (src_index += 1) {
        const byte = ptr[src_index];
        buf[dst_index] = "0123456789abcdef"[byte >> 4];
        buf[dst_index + 1] = "0123456789abcdef"[byte & 0x0f];
        dst_index += 2;
        if (src_index != 15 and ptr[src_index + 1] != 0 and dst_index < buf.len) {
            buf[dst_index] = ':';
            dst_index += 1;
        }
    }
    return buf[0..dst_index];
}

fn advanceHostInput(stdin_file: std.Io.File, master: c_int, state: *HostInputState) !bool {
    while (true) {
        if (state.hasPendingWrite()) return true;

        if (state.frame_type) |frame_type| {
            switch (frame_type) {
                .input => {
                    if (state.payload_remaining == 0) {
                        state.resetFrame();
                        continue;
                    }
                    const chunk = @min(state.payload_remaining, state.pending.len);
                    switch (try readNonBlocking(stdin_file, state.pending[0..chunk])) {
                        .data => |count| {
                            state.pending_offset = 0;
                            state.pending_len = count;
                            state.payload_remaining -= count;
                            return true;
                        },
                        .would_block => return true,
                        .eof => return false,
                    }
                },
                .resize => {
                    switch (try readNonBlocking(stdin_file, state.resize_payload[state.resize_len..])) {
                        .data => |count| state.resize_len += count,
                        .would_block => return true,
                        .eof => return false,
                    }
                    if (state.resize_len < state.resize_payload.len) continue;

                    applyResize(master, &state.resize_payload);
                    state.resetFrame();
                    continue;
                },
                else => {
                    if (state.payload_remaining == 0) {
                        state.resetFrame();
                        continue;
                    }
                    const chunk = @min(state.payload_remaining, state.discard.len);
                    switch (try readNonBlocking(stdin_file, state.discard[0..chunk])) {
                        .data => |count| state.payload_remaining -= count,
                        .would_block => return true,
                        .eof => return false,
                    }
                    continue;
                },
            }
        }

        switch (try readNonBlocking(stdin_file, state.header[state.header_len..])) {
            .data => |count| state.header_len += count,
            .would_block => return true,
            .eof => return false,
        }
        if (state.header_len < state.header.len) continue;

        state.frame_type = parseFrameType(state.header[0]) orelse return false;
        state.payload_remaining = std.mem.readInt(u32, state.header[1..5], .little);
        switch (state.frame_type.?) {
            .input => {},
            .resize => if (state.payload_remaining != state.resize_payload.len) return false,
            .exit => return false,
            else => {},
        }
        if (state.payload_remaining == 0) {
            state.resetFrame();
            continue;
        }
    }
}

fn writePendingInput(master: c_int, state: *HostInputState) !void {
    while (state.hasPendingWrite()) {
        const count = c.write(master, state.pending[state.pending_offset..state.pending_len].ptr, state.pending_len - state.pending_offset);
        if (count > 0) {
            state.pending_offset += @intCast(count);
            continue;
        }
        if (count == 0) return error.WriteFailed;
        switch (std.posix.errno(-1)) {
            .AGAIN => return,
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
    state.pending_offset = 0;
    state.pending_len = 0;
    if (state.frame_type == .input and state.payload_remaining == 0) state.resetFrame();
}

fn applyResize(master: c_int, payload: *const [4]u8) void {
    var winsize = std.mem.zeroes(c.struct_winsize);
    winsize.ws_col = std.mem.readInt(u16, payload[0..2], .little);
    winsize.ws_row = std.mem.readInt(u16, payload[2..4], .little);
    var current = std.mem.zeroes(c.struct_winsize);
    const same_size = c.ioctl(master, c.TIOCGWINSZ, &current) == 0 and
        current.ws_col == winsize.ws_col and current.ws_row == winsize.ws_row;
    if (c.ioctl(master, c.TIOCSWINSZ, &winsize) == 0 and same_size) {
        // Same-size repaint nudges do not make the kernel emit SIGWINCH.
        const foreground_pgid = c.tcgetpgrp(master);
        if (foreground_pgid > 0) _ = c.kill(-foreground_pgid, c.SIGWINCH);
    }
}

fn parseFrameType(byte: u8) ?protocol.FrameType {
    return switch (byte) {
        @intFromEnum(protocol.FrameType.hello) => .hello,
        @intFromEnum(protocol.FrameType.input) => .input,
        @intFromEnum(protocol.FrameType.output) => .output,
        @intFromEnum(protocol.FrameType.resize) => .resize,
        @intFromEnum(protocol.FrameType.exit) => .exit,
        else => null,
    };
}

fn readNonBlocking(file: std.Io.File, buffer: []u8) !NonBlockingRead {
    while (true) {
        const count = c.read(file.handle, buffer.ptr, buffer.len);
        if (count > 0) return .{ .data = @intCast(count) };
        if (count == 0) return .eof;
        switch (std.posix.errno(-1)) {
            .AGAIN => return .would_block,
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
}

fn writeFrame(file: std.Io.File, frame_type: protocol.FrameType, payload: []const u8) !void {
    var header: [5]u8 = undefined;
    header[0] = @intFromEnum(frame_type);
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);
    if (payload.len == 0) {
        try writeAllFd(file.handle, &header);
        return;
    }
    var iov = [_]c.struct_iovec{
        .{ .iov_base = &header, .iov_len = header.len },
        .{ .iov_base = @constCast(payload.ptr), .iov_len = payload.len },
    };
    const total = header.len + payload.len;
    var written: usize = 0;
    while (written < total) {
        const n = c.writev(file.handle, &iov, iov.len);
        if (n < 0) {
            return switch (std.posix.errno(-1)) {
                .INTR => continue,
                .AGAIN => {
                    var pfd = [_]c.struct_pollfd{.{ .fd = file.handle, .events = c.POLLOUT, .revents = 0 }};
                    _ = c.poll(&pfd, pfd.len, -1);
                    continue;
                },
                else => error.WriteFailed,
            };
        }
        written += @intCast(n);
        if (written >= total) break;
        advanceIovecs(&iov, @intCast(n));
    }
}

fn advanceIovecs(iovecs: []c.struct_iovec, count: usize) void {
    var remaining = count;
    for (iovecs) |*iov| {
        if (remaining == 0) break;
        if (remaining >= iov.iov_len) {
            remaining -= iov.iov_len;
            iov.iov_len = 0;
        } else {
            iov.iov_base = @ptrFromInt(@intFromPtr(iov.iov_base) + remaining);
            iov.iov_len -= remaining;
            break;
        }
    }
}

fn writeAllFd(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (count > 0) {
            offset += @intCast(count);
            continue;
        }
        switch (std.posix.errno(-1)) {
            .AGAIN => {
                var poll_fd = [_]c.struct_pollfd{.{ .fd = fd, .events = c.POLLOUT, .revents = 0 }};
                _ = c.poll(&poll_fd, poll_fd.len, -1);
            },
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

fn childExitStatus(status: c_int) u32 {
    if (c.WIFEXITED(status)) return @intCast(c.WEXITSTATUS(status));
    if (c.WIFSIGNALED(status)) return 128 + @as(u32, @intCast(c.WTERMSIG(status)));
    return 1;
}

fn terminateAndReapChild(pid: c_int) u32 {
    terminateChildGroup(pid, c.SIGHUP);

    const deadline = milliTimestamp() + termination_grace_ms;
    while (milliTimestamp() < deadline) {
        if (waitForChildExit(pid, c.WNOHANG)) |status| return status;
        std.Io.sleep(io.get(), .fromMilliseconds(20), .awake) catch {};
    }

    terminateChildGroup(pid, c.SIGKILL);
    return waitForChildExit(pid, 0) orelse 1;
}

fn milliTimestamp() i64 {
    return @intCast(std.Io.Clock.awake.now(io.get()).toMilliseconds());
}

fn terminateChildGroup(pid: c_int, signal: c_int) void {
    _ = c.kill(-pid, signal);
    _ = c.kill(pid, signal);
}

fn waitForChildExit(pid: c_int, flags: c_int) ?u32 {
    while (true) {
        var status: c_int = 0;
        const wait_result = c.waitpid(pid, &status, flags);
        if (wait_result == pid) return childExitStatus(status);
        if (wait_result == 0) return null;
        switch (std.posix.errno(-1)) {
            .INTR => continue,
            .CHILD => return 0,
            else => return 1,
        }
    }
}

fn parseArgs(allocator: std.mem.Allocator, process_args: std.process.Args) !Options {
    const args = try io.argsAlloc(allocator, process_args);
    defer io.argsFree(allocator, args);

    var options = Options{};
    errdefer options.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--cols")) {
            i += 1;
            if (i >= args.len) return error.MissingCols;
            options.cols = try std.fmt.parseInt(u16, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--rows")) {
            i += 1;
            if (i >= args.len) return error.MissingRows;
            options.rows = try std.fmt.parseInt(u16, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--cwd")) {
            i += 1;
            if (i >= args.len) return error.MissingCwd;
            options.cwd = try allocator.dupe(u8, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--shell-arg")) {
            i += 1;
            if (i >= args.len) return error.MissingShellArg;
            try options.shell_args.append(allocator, try allocator.dupe(u8, args[i]));
            continue;
        }
        if (std.mem.eql(u8, arg, "--env")) {
            i += 1;
            if (i >= args.len) return error.MissingEnv;
            const entry = args[i];
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return error.InvalidEnv;
            try options.env.append(allocator, .{
                .key = try allocator.dupe(u8, entry[0..eq]),
                .value = try allocator.dupe(u8, entry[eq + 1 ..]),
            });
            continue;
        }
        if (std.mem.eql(u8, arg, "--command")) {
            i += 1;
            if (i >= args.len) return error.MissingCommand;
            options.launch.command = try allocator.dupe(u8, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--close-on-exit")) {
            options.launch.close_on_exit = true;
            continue;
        }
        return error.InvalidArgument;
    }

    return options;
}

fn buildShellArgv(allocator: std.mem.Allocator, input_shell_args: []const []const u8, launch: LaunchCommand, bundle: ?shell_integration.Bundle) ![:null]?[*:0]const u8 {
    var shell_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer shell_args.deinit(allocator);
    var default_shell_owned: ?[]u8 = null;
    defer if (default_shell_owned) |shell| allocator.free(shell);

    if (input_shell_args.len == 0) {
        const default_shell = try defaultShellPath(allocator);
        default_shell_owned = default_shell;
        try shell_args.append(allocator, default_shell);
    } else {
        try shell_args.appendSlice(allocator, input_shell_args);
    }

    var argv: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
    errdefer {
        freeExecArgvOwnedStrings(allocator, argv.items);
        argv.deinit(allocator);
    }

    for (shell_args.items) |arg| {
        const duped = try allocator.dupeZ(u8, arg);
        try argv.append(allocator, duped.ptr);
    }

    const shell_name = std.fs.path.basename(shell_args.items[0]);
    if (bundle) |value| {
        const integration_argv = try shell_integration.argv(allocator, value, launch.command, launch.close_on_exit);
        defer {
            for (integration_argv) |arg| allocator.free(arg);
            allocator.free(integration_argv);
        }
        for (integration_argv) |arg| try argv.append(allocator, (try allocator.dupeZ(u8, arg)).ptr);
        try argv.append(allocator, null);
        return try argv.toOwnedSliceSentinel(allocator, null);
    }
    if (launch.command) |command| {
        const trimmed = std.mem.trimEnd(u8, command, "\r\n");
        if (std.mem.eql(u8, shell_name, "bash") or std.mem.eql(u8, shell_name, "sh") or std.mem.eql(u8, shell_name, "zsh") or std.mem.eql(u8, shell_name, "fish")) {
            try argv.append(allocator, (try allocator.dupeZ(u8, "-lc")).ptr);
            const wrapped = if (launch.close_on_exit)
                try std.fmt.allocPrintSentinel(allocator, "{s}; exit", .{trimmed}, 0)
            else
                try allocator.dupeZ(u8, trimmed);
            try argv.append(allocator, wrapped.ptr);
        } else if (std.mem.eql(u8, shell_name, "ssh") or std.mem.eql(u8, shell_name, "ssh.exe")) {
            try argv.append(allocator, (try allocator.dupeZ(u8, "-tt")).ptr);
            const wrapped = if (launch.close_on_exit)
                try std.fmt.allocPrintSentinel(allocator, "{s}; exit", .{trimmed}, 0)
            else
                try allocator.dupeZ(u8, trimmed);
            try argv.append(allocator, wrapped.ptr);
        } else {
            const wrapped = if (launch.close_on_exit)
                try std.fmt.allocPrintSentinel(allocator, "{s}; exit", .{trimmed}, 0)
            else
                try allocator.dupeZ(u8, trimmed);
            try argv.append(allocator, wrapped.ptr);
        }
    } else if (input_shell_args.len == 0) {
        if (std.mem.eql(u8, shell_name, "bash") or std.mem.eql(u8, shell_name, "sh") or std.mem.eql(u8, shell_name, "zsh") or std.mem.eql(u8, shell_name, "fish")) {
            try argv.append(allocator, (try allocator.dupeZ(u8, "-i")).ptr);
        }
    }

    try argv.append(allocator, null);
    return try argv.toOwnedSliceSentinel(allocator, null);
}

fn freeExecArgv(allocator: std.mem.Allocator, argv: [:null]?[*:0]const u8) void {
    freeExecArgvOwnedStrings(allocator, argv);
    allocator.free(argv);
}

fn freeExecArgvOwnedStrings(allocator: std.mem.Allocator, argv: []const ?[*:0]const u8) void {
    for (argv) |maybe_ptr| {
        if (maybe_ptr) |ptr| allocator.free(std.mem.sliceTo(ptr, 0));
    }
}

fn isPathEnvironmentVariable(key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, "HOME") or
        std.ascii.eqlIgnoreCase(key, "USERPROFILE") or
        std.ascii.eqlIgnoreCase(key, "PWD") or
        std.ascii.eqlIgnoreCase(key, "OLDPWD") or
        std.ascii.eqlIgnoreCase(key, "ZDOTDIR") or
        std.ascii.eqlIgnoreCase(key, "XDG_CONFIG_HOME") or
        std.ascii.eqlIgnoreCase(key, "XDG_DATA_HOME") or
        std.ascii.eqlIgnoreCase(key, "XDG_CACHE_HOME") or
        std.ascii.eqlIgnoreCase(key, "XDG_STATE_HOME") or
        std.ascii.eqlIgnoreCase(key, "HOLLOW_SHELL_INTEGRATION_DIR") or
        std.ascii.eqlIgnoreCase(key, "HOLLOW_ORIGINAL_ZDOTDIR");
}

fn windowsPathToWsl(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len >= 18 and std.ascii.startsWithIgnoreCase(path, "\\\\wsl.localhost\\")) {
        var index: usize = 17;
        while (index < path.len and path[index] != '\\' and path[index] != '/') : (index += 1) {}
        if (index < path.len) {
            const remainder = path[index..];
            var converted: std.ArrayListUnmanaged(u8) = .empty;
            errdefer converted.deinit(allocator);
            for (remainder) |ch| {
                try converted.append(allocator, if (ch == '\\') '/' else ch);
            }
            return converted.toOwnedSlice(allocator);
        }
        return allocator.dupe(u8, "/");
    }

    if (!(path.len >= 3 and path[1] == ':' and (path[2] == '\\' or path[2] == '/'))) {
        return allocator.dupe(u8, path);
    }

    var converted: std.ArrayListUnmanaged(u8) = .empty;
    errdefer converted.deinit(allocator);

    try converted.appendSlice(allocator, "/mnt/");
    try converted.append(allocator, std.ascii.toLower(path[0]));
    for (path[2..]) |ch| {
        try converted.append(allocator, if (ch == '\\') '/' else ch);
    }
    return converted.toOwnedSlice(allocator);
}

fn defaultShellPath(allocator: std.mem.Allocator) ![]u8 {
    const passwd = c.getpwuid(c.getuid());
    if (passwd != null and passwd.*.pw_shell != null) {
        const shell = std.mem.span(passwd.*.pw_shell);
        if (isLikelyPosixShellPath(shell) and try isExecutablePath(allocator, shell)) return allocator.dupe(u8, shell);
    }

    const env_shell = io.getEnvVarOwned(allocator, "SHELL") catch null;
    defer if (env_shell) |value| allocator.free(value);
    if (env_shell) |value| {
        if (isLikelyPosixShellPath(value) and try isExecutablePath(allocator, value)) return allocator.dupe(u8, value);
    }

    return allocator.dupe(u8, "/bin/sh");
}

fn isExecutablePath(allocator: std.mem.Allocator, path: []const u8) !bool {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    return c.access(path_z.ptr, c.X_OK) == 0;
}

fn isLikelyPosixShellPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] != '/') return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    if (std.mem.endsWith(u8, path, ".exe")) return false;
    return true;
}

test "parseFrameType rejects unknown protocol bytes" {
    try std.testing.expectEqual(@as(?protocol.FrameType, null), parseFrameType(0));
    try std.testing.expectEqual(@as(?protocol.FrameType, null), parseFrameType(0xff));
    try std.testing.expectEqual(@as(?protocol.FrameType, .input), parseFrameType(@intFromEnum(protocol.FrameType.input)));
}

test "advanceIovecs advances from the latest partial write" {
    var first = [_]u8{ 1, 2, 3, 4, 5 };
    var second = [_]u8{ 6, 7, 8 };
    var iov = [_]c.struct_iovec{
        .{ .iov_base = &first, .iov_len = first.len },
        .{ .iov_base = &second, .iov_len = second.len },
    };

    advanceIovecs(&iov, 2);
    advanceIovecs(&iov, 1);

    try std.testing.expectEqual(@as(usize, 2), iov[0].iov_len);
    try std.testing.expectEqual(@as(usize, second.len), iov[1].iov_len);
}

test "default bash argv includes shell integration" {
    const argv = try buildShellArgv(std.testing.allocator, &.{"/bin/bash"}, .{}, .{ .root = "/tmp/hollow-test", .shell = .bash });
    defer freeExecArgv(std.testing.allocator, argv);

    try std.testing.expectEqualStrings("/bin/bash", std.mem.span(argv[0].?));
    try std.testing.expectEqualStrings("--rcfile", std.mem.span(argv[1].?));
    try std.testing.expectEqualStrings("/tmp/hollow-test/bashrc", std.mem.span(argv[2].?));
    try std.testing.expectEqualStrings("-i", std.mem.span(argv[3].?));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), argv[4]);
}

test "environment path conversion is limited to known single paths" {
    try std.testing.expect(isPathEnvironmentVariable("HOME"));
    try std.testing.expect(isPathEnvironmentVariable("home"));
    try std.testing.expect(isPathEnvironmentVariable("HOLLOW_SHELL_INTEGRATION_DIR"));
    try std.testing.expect(!isPathEnvironmentVariable("XDG_CONFIG_DIRS"));
    try std.testing.expect(!isPathEnvironmentVariable("CUSTOM_DIR"));
}

test "host input stops at a full master pipe instead of blocking" {
    var host_pipe: [2]c_int = undefined;
    var master_pipe: [2]c_int = undefined;
    if (c.pipe(&host_pipe) != 0) return error.PipeFailed;
    defer _ = c.close(host_pipe[0]);
    defer _ = c.close(host_pipe[1]);
    if (c.pipe(&master_pipe) != 0) return error.PipeFailed;
    defer _ = c.close(master_pipe[0]);
    defer _ = c.close(master_pipe[1]);
    try setNonBlockingFd(host_pipe[0]);
    try setNonBlockingFd(master_pipe[0]);
    try setNonBlockingFd(master_pipe[1]);

    const host_read = std.Io.File{ .handle = host_pipe[0], .flags = .{ .nonblocking = true } };
    const master_write = master_pipe[1];
    const fill = [_]u8{0} ** 4096;
    while (true) {
        const count = c.write(master_write, &fill, fill.len);
        if (count > 0) continue;
        if (std.posix.errno(-1) == .AGAIN) break;
        return error.WriteFailed;
    }

    var frame_header = [_]u8{ @intFromEnum(protocol.FrameType.input), 0, 0, 0, 0 };
    std.mem.writeInt(u32, frame_header[1..5], 4096, .little);
    var payload = [_]u8{0x41} ** 4096;
    try writeTestFd(host_pipe[1], &frame_header);
    try writeTestFd(host_pipe[1], &payload);

    var state = HostInputState{};
    try std.testing.expect(try advanceHostInput(host_read, master_write, &state));
    try std.testing.expect(try advanceHostInput(host_read, master_write, &state));
    try std.testing.expect(state.hasPendingWrite());
    try writePendingInput(master_write, &state);
    try std.testing.expect(state.hasPendingWrite());

    var drained: [4096]u8 = undefined;
    while (c.read(master_pipe[0], &drained, drained.len) > 0) {}
    try writePendingInput(master_write, &state);
    try std.testing.expect(!state.hasPendingWrite());
}

fn writeTestFd(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (count > 0) {
            offset += @intCast(count);
            continue;
        }
        if (count < 0 and std.posix.errno(-1) == .INTR) continue;
        return error.WriteFailed;
    }
}

fn setNonBlockingFd(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.SetNonBlockingFailed;
}
