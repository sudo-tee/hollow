const std = @import("std");
const protocol = @import("pty/wsl_bypass_protocol.zig");
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

const termination_grace_ms: i64 = 1500;
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Keep write failures on the host pipes in-band as EPIPE so deferred cleanup
    // still runs and reaps the shell child.
    var sa = std.mem.zeroes(c.struct_sigaction);
    sa.__sa_handler.sa_handler = @ptrFromInt(1);
    _ = c.sigemptyset(&sa.sa_mask);
    _ = c.sigaction(c.SIGPIPE, &sa, null);

    const options = parseArgs(allocator) catch return;
    defer {
        var owned = options;
        owned.deinit(allocator);
    }

    try run(allocator, options);
}

fn run(allocator: std.mem.Allocator, options: Options) !void {
    const shell_argv = try buildShellArgv(allocator, options.shell_args.items, options.launch);
    defer freeExecArgv(allocator, shell_argv);

    const stderr_copy = c.dup(std.fs.File.stderr().handle);
    defer {
        if (stderr_copy >= 0) _ = c.close(stderr_copy);
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

    try writeFrame(std.fs.File.stdout(), .hello, protocol.hello_payload[0..]);

    const stdin_file = std.fs.File.stdin();
    const stdin_flags = c.fcntl(stdin_file.handle, c.F_GETFL, @as(c_int, 0));
    if (stdin_flags >= 0) _ = c.fcntl(stdin_file.handle, c.F_SETFL, stdin_flags | c.O_NONBLOCK);

    const stdout_file = std.fs.File.stdout();

    var input_closed = false;
    var master_closed = false;
    var termination_requested = false;
    var termination_deadline_ms: ?i64 = null;

    while (true) {
        var poll_fds = [_]c.struct_pollfd{
            .{ .fd = stdin_file.handle, .events = if (input_closed) 0 else c.POLLIN, .revents = 0 },
            .{ .fd = master, .events = c.POLLIN, .revents = 0 },
            .{ .fd = stdout_file.handle, .events = 0, .revents = 0 },
        };

        _ = c.poll(&poll_fds, poll_fds.len, 50);

        if (!input_closed and (poll_fds[0].revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL)) != 0) {
            input_closed = true;
        }
        if (!input_closed and (poll_fds[0].revents & c.POLLIN) != 0) {
            const still_open = handleHostFrame(stdin_file, master) catch false;
            if (!still_open) input_closed = true;
        }
        if (!input_closed and (poll_fds[2].revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL)) != 0) {
            input_closed = true;
        }

        if (input_closed and !termination_requested and !child_reaped) {
            terminateChildGroup(pid, c.SIGHUP);
            std.log.info("wsl bypass shutdown requested; terminating child pid={d}", .{pid});
            termination_requested = true;
            termination_deadline_ms = std.time.milliTimestamp() + termination_grace_ms;
        }

        if ((poll_fds[1].revents & (c.POLLIN | c.POLLHUP | c.POLLERR)) != 0) {
            var buf: [65536]u8 = undefined;
            const count = c.read(master, &buf, buf.len);
            if (count > 0) {
                try writeFrame(std.fs.File.stdout(), .output, buf[0..@intCast(count)]);
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

        if (termination_requested and !child_reaped and termination_deadline_ms != null and std.time.milliTimestamp() >= termination_deadline_ms.?) {
            terminateChildGroup(pid, c.SIGKILL);
            termination_deadline_ms = null;
        }

        if (child_reaped and (master_closed or termination_requested)) break;
    }

    var exit_payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &exit_payload, exit_status, .little);
    if (!input_closed) {
        try writeFrame(std.fs.File.stdout(), .exit, &exit_payload);
    } else {
        _ = writeFrame(std.fs.File.stdout(), .exit, &exit_payload) catch {};
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
        const value = if (std.mem.indexOf(u8, entry.key, "DIR") != null)
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
    var stderr_file = std.fs.File{ .handle = stderr_fd };
    var stderr = stderr_file.writer(&stderr_buf);
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

fn handleHostFrame(stdin_file: std.fs.File, master: c_int) !bool {
    var header: [5]u8 = undefined;
    if (!(try readExactNonBlocking(stdin_file, &header))) return false;

    const frame_type: protocol.FrameType = @enumFromInt(header[0]);
    const payload_len = std.mem.readInt(u32, header[1..5], .little);

    switch (frame_type) {
        .input => {
            var remaining: usize = payload_len;
            var buf: [4096]u8 = undefined;
            while (remaining > 0) {
                const chunk = @min(remaining, buf.len);
                if (!(try readExactNonBlocking(stdin_file, buf[0..chunk]))) return false;
                try writeAllFd(master, buf[0..chunk]);
                remaining -= chunk;
            }
        },
        .resize => {
            if (payload_len != 4) return error.InvalidResizeFrame;
            var payload: [4]u8 = undefined;
            if (!(try readExactNonBlocking(stdin_file, &payload))) return false;
            var winsize = std.mem.zeroes(c.struct_winsize);
            winsize.ws_col = std.mem.readInt(u16, payload[0..2], .little);
            winsize.ws_row = std.mem.readInt(u16, payload[2..4], .little);
            _ = c.ioctl(master, c.TIOCSWINSZ, &winsize);
        },
        .exit => return false,
        else => {
            var remaining: usize = payload_len;
            var discard: [256]u8 = undefined;
            while (remaining > 0) {
                const chunk = @min(remaining, discard.len);
                if (!(try readExactNonBlocking(stdin_file, discard[0..chunk]))) return false;
                remaining -= chunk;
            }
        },
    }

    return true;
}

fn writeFrame(file: std.fs.File, frame_type: protocol.FrameType, payload: []const u8) !void {
    var header: [5]u8 = undefined;
    header[0] = @intFromEnum(frame_type);
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);
    if (payload.len == 0) {
        try file.writeAll(&header);
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
        // advance iov past already-written bytes
        var remaining: usize = written;
        for (&iov) |*v| {
            if (remaining >= v.iov_len) {
                remaining -= v.iov_len;
                v.iov_len = 0;
            } else {
                v.iov_base = @ptrFromInt(@intFromPtr(v.iov_base) + remaining);
                v.iov_len -= remaining;
                break;
            }
        }
    }
}

fn readExactNonBlocking(file: std.fs.File, buffer: []u8) !bool {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const count = c.read(file.handle, buffer.ptr + offset, buffer.len - offset);
        if (count > 0) {
            offset += @intCast(count);
            continue;
        }
        if (count == 0) return false;
        switch (std.posix.errno(-1)) {
            .AGAIN => {
                var poll_fd = [_]c.struct_pollfd{.{ .fd = file.handle, .events = c.POLLIN, .revents = 0 }};
                _ = c.poll(&poll_fd, poll_fd.len, -1);
            },
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
    return true;
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

    const deadline = std.time.milliTimestamp() + termination_grace_ms;
    while (std.time.milliTimestamp() < deadline) {
        if (waitForChildExit(pid, c.WNOHANG)) |status| return status;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    terminateChildGroup(pid, c.SIGKILL);
    return waitForChildExit(pid, 0) orelse 1;
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

fn parseArgs(allocator: std.mem.Allocator) !Options {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

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

fn buildShellArgv(allocator: std.mem.Allocator, input_shell_args: []const []const u8, launch: LaunchCommand) ![:null]?[*:0]const u8 {
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
    if (launch.command) |command| {
        const trimmed = std.mem.trimRight(u8, command, "\r\n");
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

    const env_shell = std.process.getEnvVarOwned(allocator, "SHELL") catch null;
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
