//! `hollow-agent pty`: serves one interactive PTY over stdin/stdout frames.
//! Output is forwarded as soon as it is read; there is no credit/ack window.
const std = @import("std");
const wire = @import("pty_protocol.zig");
const shell_integration = @import("shell_integration");
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("pty.h");
    @cInclude("pwd.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/signalfd.h");
    @cInclude("sys/uio.h");
    @cInclude("sys/wait.h");
    @cInclude("termios.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

const read_chunk = 64 * 1024;
const pending_limit = 256 * 1024;
const termination_grace_ms = 1500;

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    // A handler (not SIG_IGN) so exec restores the default for the shell.
    _ = c.signal(c.SIGPIPE, ignoreSignal);

    var hello: [32]u8 = undefined;
    try writeFrame(1, .hello, try std.fmt.bufPrint(&hello, "{{\"version\":{d}}}", .{wire.version}));

    var reader: wire.Reader = .{};
    defer reader.deinit(allocator);
    const spawn_payload = readSpawn(allocator, &reader) catch |err| {
        reportError(err, "spawn frame");
        return;
    };
    defer allocator.free(spawn_payload);
    const parsed = std.json.parseFromSlice(wire.Spawn, allocator, spawn_payload, .{ .ignore_unknown_fields = true }) catch |err| {
        reportError(err, "spawn payload");
        return;
    };
    defer parsed.deinit();
    serve(allocator, io, parsed.value, &reader) catch |err| reportError(err, "pty");
}

fn ignoreSignal(_: c_int) callconv(.c) void {}

/// setenv() replaces libc's environ, so refresh the snapshot the shell
/// integration helpers read from.
fn libcEnviron() std.process.Environ {
    var count: usize = 0;
    while (std.c.environ[count] != null) count += 1;
    return .{ .block = .{ .slice = std.c.environ[0..count :null] } };
}

fn readSpawn(allocator: std.mem.Allocator, reader: *wire.Reader) ![]u8 {
    while (true) {
        if (try reader.next()) |frame| {
            if (frame.header.kind != .spawn) return error.ExpectedSpawn;
            return allocator.dupe(u8, frame.payload);
        }
        var buf: [4096]u8 = undefined;
        const n = c.read(0, &buf, buf.len);
        if (n == 0) return error.EndOfStream;
        if (n < 0) {
            if (errno() == c.EINTR) continue;
            return error.ReadFailed;
        }
        try reader.push(allocator, buf[0..@intCast(n)]);
    }
}

fn serve(allocator: std.mem.Allocator, io: std.Io, spawn: wire.Spawn, reader: *wire.Reader) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (spawn.env) |entry| {
        if (entry.key.len == 0 or std.mem.indexOfScalar(u8, entry.key, '=') != null) return error.InvalidEnv;
        const value = if (spawn.path_style == .wsl and isPathEnvironmentVariable(entry.key)) try windowsPathToWsl(arena, entry.value) else entry.value;
        if (c.setenv((try arena.dupeZ(u8, entry.key)).ptr, (try arena.dupeZ(u8, value)).ptr, 1) != 0) return error.SetEnvFailed;
    }
    const cwd: ?[:0]const u8 = if (spawn.cwd) |dir| try arena.dupeZ(u8, if (spawn.path_style == .wsl) try windowsPathToWsl(arena, dir) else dir) else null;

    shell_integration.io.init(io, libcEnviron());
    const shell = if (spawn.argv.len > 0) spawn.argv[0] else try defaultShellPath(arena);
    // Integration only wraps a bare shell; explicit arguments run verbatim.
    const integrate = spawn.shell_integration and spawn.argv.len <= 1;
    const bundle = if (integrate) shell_integration.install(arena, shell) catch null else null;
    if (bundle) |value| try shell_integration.setupEnv(arena, value);
    const argv = try buildShellArgv(arena, spawn.argv, shell, spawn.command, spawn.close_on_exit, bundle);

    // Block SIGCHLD before fork so its signalfd cannot miss an early exit.
    var signals: c.sigset_t = undefined;
    _ = c.sigemptyset(&signals);
    _ = c.sigaddset(&signals, c.SIGCHLD);
    if (c.sigprocmask(c.SIG_BLOCK, &signals, null) != 0) return error.SignalMaskFailed;
    const signal_fd = c.signalfd(-1, &signals, c.SFD_CLOEXEC | c.SFD_NONBLOCK);
    if (signal_fd < 0) return error.SignalFdFailed;
    defer _ = c.close(signal_fd);

    var winsize = std.mem.zeroes(c.struct_winsize);
    winsize.ws_col = spawn.cols;
    winsize.ws_row = spawn.rows;
    var master: c_int = -1;
    const pid = c.forkpty(&master, null, null, &winsize);
    if (pid < 0) return error.ForkPtyFailed;
    if (pid == 0) childExec(cwd, argv);
    defer _ = c.close(master);
    setNonBlocking(master);
    setNonBlocking(0);

    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    var reaped = false;
    var exit_status: u32 = 0;
    var master_open = true;
    var input_open = true;
    var hangup_sent = false;
    var kill_deadline: ?i64 = null;
    defer if (!reaped) {
        signalGroup(pid, c.SIGKILL);
        _ = waitChild(pid, 0);
    };

    // Frames that arrived together with the spawn request.
    if (!try processInput(allocator, reader, master, &pending)) input_open = false;

    var buf: [read_chunk]u8 = undefined;
    while (true) {
        if (!input_open and !hangup_sent and !reaped) {
            signalGroup(pid, c.SIGHUP);
            hangup_sent = true;
            kill_deadline = nowMs() + termination_grace_ms;
        }
        if (reaped and (!master_open or !input_open)) break;

        const read_input = input_open and pending.items.len < pending_limit;
        var fds = [_]c.struct_pollfd{
            // Keep polling stdin while input is throttled so a client hangup
            // is still noticed.
            .{ .fd = if (input_open) 0 else -1, .events = if (read_input) c.POLLIN else 0, .revents = 0 },
            .{ .fd = if (master_open) master else -1, .events = @intCast(c.POLLIN | if (pending.items.len > 0) c.POLLOUT else 0), .revents = 0 },
            .{ .fd = signal_fd, .events = c.POLLIN, .revents = 0 },
        };
        const timeout: c_int = if (kill_deadline) |deadline| @intCast(@max(0, deadline - nowMs())) else -1;
        if (c.poll(&fds, fds.len, timeout) < 0 and errno() != c.EINTR) return error.PollFailed;

        if ((fds[2].revents & c.POLLIN) != 0) {
            var info: c.struct_signalfd_siginfo = undefined;
            while (c.read(signal_fd, &info, @sizeOf(c.struct_signalfd_siginfo)) > 0) {}
        }
        if (!reaped) {
            if (waitChild(pid, c.WNOHANG)) |status| {
                reaped = true;
                exit_status = status;
            }
        }
        if (kill_deadline) |deadline| {
            if (!reaped and nowMs() >= deadline) signalGroup(pid, c.SIGKILL);
            if (reaped or nowMs() >= deadline) kill_deadline = null;
        }

        if (!read_input and (fds[0].revents & (c.POLLHUP | c.POLLERR)) != 0) {
            input_open = false;
        } else if ((fds[0].revents & (c.POLLIN | c.POLLHUP | c.POLLERR)) != 0) {
            const n = c.read(0, &buf, buf.len);
            if (n > 0) {
                try reader.push(allocator, buf[0..@intCast(n)]);
                if (!try processInput(allocator, reader, master, &pending)) input_open = false;
            } else if (n == 0 or (errno() != c.EAGAIN and errno() != c.EINTR)) input_open = false;
        }
        if (master_open and pending.items.len > 0) flushPending(master, &pending);

        if (master_open and (fds[1].revents & (c.POLLIN | c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) {
            const n = c.read(master, &buf, buf.len);
            if (n > 0) {
                writeFrame(1, .output, buf[0..@intCast(n)]) catch {
                    input_open = false;
                };
            } else if (n == 0 or (errno() != c.EAGAIN and errno() != c.EINTR)) {
                master_open = false;
                pending.clearRetainingCapacity();
            }
        }
    }

    var payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &payload, exit_status, .little);
    writeFrame(1, .exit, &payload) catch {};
}

/// Returns false when the client asked to close the session.
fn processInput(allocator: std.mem.Allocator, reader: *wire.Reader, master: c_int, pending: *std.ArrayList(u8)) !bool {
    while (try reader.next()) |frame| switch (frame.header.kind) {
        .input => try pending.appendSlice(allocator, frame.payload),
        .resize => {
            const size = wire.decodeResize(frame.payload) catch continue;
            applyResize(master, size.cols, size.rows);
        },
        .close => return false,
        else => {},
    };
    return true;
}

fn flushPending(master: c_int, pending: *std.ArrayList(u8)) void {
    var written: usize = 0;
    while (written < pending.items.len) {
        const n = c.write(master, pending.items.ptr + written, pending.items.len - written);
        if (n > 0) {
            written += @intCast(n);
            continue;
        }
        if (n < 0 and errno() == c.EINTR) continue;
        if (n < 0 and errno() == c.EAGAIN) break;
        written = pending.items.len;
    }
    const rest = pending.items.len - written;
    std.mem.copyForwards(u8, pending.items[0..rest], pending.items[written..]);
    pending.items.len = rest;
}

fn applyResize(master: c_int, cols: u16, rows: u16) void {
    var winsize = std.mem.zeroes(c.struct_winsize);
    winsize.ws_col = cols;
    winsize.ws_row = rows;
    var current = std.mem.zeroes(c.struct_winsize);
    const same_size = c.ioctl(master, c.TIOCGWINSZ, &current) == 0 and
        current.ws_col == cols and current.ws_row == rows;
    if (c.ioctl(master, c.TIOCSWINSZ, &winsize) == 0 and same_size) {
        // Same-size repaint nudges do not make the kernel emit SIGWINCH.
        const foreground = c.tcgetpgrp(master);
        if (foreground > 0) _ = c.kill(-foreground, c.SIGWINCH);
    }
}

fn childExec(cwd: ?[:0]const u8, argv: [:null]const ?[*:0]const u8) noreturn {
    var empty: c.sigset_t = undefined;
    _ = c.sigemptyset(&empty);
    _ = c.sigprocmask(c.SIG_SETMASK, &empty, null);
    // Like a login shell, start (or fall back to) HOME rather than whatever
    // directory the connector happened to leave the agent in.
    const home = c.getenv("HOME");
    if (cwd == null or c.chdir(cwd.?.ptr) != 0) {
        if (home) |dir| _ = c.chdir(dir);
    }
    _ = c.execvp(argv[0].?, @ptrCast(argv.ptr));
    // stdout is the PTY slave here, so the message lands in the pane.
    var msg: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&msg, "hollow-agent: cannot execute {s}: errno {d}\r\n", .{ std.mem.span(argv[0].?), errno() }) catch "hollow-agent: exec failed\r\n";
    _ = c.write(2, text.ptr, text.len);
    c._exit(127);
}

fn buildShellArgv(arena: std.mem.Allocator, input: []const []const u8, shell: []const u8, command: ?[]const u8, close_on_exit: bool, bundle: ?shell_integration.Bundle) ![:null]const ?[*:0]const u8 {
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    if (input.len == 0) {
        try argv.append(arena, (try arena.dupeZ(u8, shell)).ptr);
    } else for (input) |arg| try argv.append(arena, (try arena.dupeZ(u8, arg)).ptr);

    if (bundle) |value| {
        for (try shell_integration.argv(arena, value, command, close_on_exit)) |arg| try argv.append(arena, (try arena.dupeZ(u8, arg)).ptr);
    } else if (command) |text| {
        const trimmed = std.mem.trimEnd(u8, text, "\r\n");
        if (isPosixShell(shell)) try argv.append(arena, "-lc");
        try argv.append(arena, if (close_on_exit) try std.fmt.allocPrintSentinel(arena, "{s}; exit", .{trimmed}, 0) else try arena.dupeZ(u8, trimmed));
    } else if (input.len == 0 and isPosixShell(shell)) {
        try argv.append(arena, "-i");
    }
    return argv.toOwnedSliceSentinel(arena, null);
}

fn isPosixShell(path: []const u8) bool {
    const name = std.fs.path.basename(path);
    inline for (.{ "bash", "sh", "zsh", "fish" }) |known| if (std.mem.eql(u8, name, known)) return true;
    return false;
}

fn isPathEnvironmentVariable(key: []const u8) bool {
    inline for (.{ "HOME", "USERPROFILE", "PWD", "OLDPWD", "ZDOTDIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "HOLLOW_SHELL_INTEGRATION_DIR", "HOLLOW_ORIGINAL_ZDOTDIR" }) |known| {
        if (std.ascii.eqlIgnoreCase(key, known)) return true;
    }
    return false;
}

fn windowsPathToWsl(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const unc = "\\\\wsl.localhost\\";
    if (path.len > unc.len and std.ascii.startsWithIgnoreCase(path, unc)) {
        const rest = path[unc.len..];
        const slash = std.mem.indexOfAny(u8, rest, "\\/") orelse return allocator.dupe(u8, "/");
        const out = try allocator.dupe(u8, rest[slash..]);
        std.mem.replaceScalar(u8, out, '\\', '/');
        return out;
    }
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) {
        const out = try std.fmt.allocPrint(allocator, "/mnt/{c}{s}", .{ std.ascii.toLower(path[0]), path[2..] });
        std.mem.replaceScalar(u8, out, '\\', '/');
        return out;
    }
    return allocator.dupe(u8, path);
}

fn defaultShellPath(allocator: std.mem.Allocator) ![]const u8 {
    const passwd = c.getpwuid(c.getuid());
    if (passwd != null and passwd.*.pw_shell != null) {
        const shell = std.mem.span(passwd.*.pw_shell);
        if (usableShell(shell)) return allocator.dupe(u8, shell);
    }
    if (c.getenv("SHELL")) |ptr| {
        const shell = std.mem.span(ptr);
        if (usableShell(shell)) return allocator.dupe(u8, shell);
    }
    return "/bin/sh";
}

fn usableShell(path: []const u8) bool {
    if (path.len == 0 or path.len >= 4096 or path[0] != '/') return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null or std.mem.endsWith(u8, path, ".exe")) return false;
    var buf: [4096]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return c.access(@ptrCast(&buf), c.X_OK) == 0;
}

fn writeFrame(fd: c_int, kind: wire.Kind, payload: []const u8) !void {
    var header = (wire.Header{ .kind = kind, .len = @intCast(payload.len) }).encode();
    var iov = [_]c.struct_iovec{
        .{ .iov_base = &header, .iov_len = header.len },
        .{ .iov_base = @constCast(payload.ptr), .iov_len = payload.len },
    };
    var remaining = header.len + payload.len;
    while (remaining > 0) {
        const n = c.writev(fd, &iov, iov.len);
        if (n < 0) switch (errno()) {
            c.EINTR => continue,
            c.EAGAIN => {
                var pfd = [_]c.struct_pollfd{.{ .fd = fd, .events = c.POLLOUT, .revents = 0 }};
                _ = c.poll(&pfd, 1, -1);
                continue;
            },
            else => return error.WriteFailed,
        };
        remaining -= @intCast(n);
        var advance: usize = @intCast(n);
        for (&iov) |*vec| {
            const step = @min(advance, vec.iov_len);
            vec.iov_base = @ptrFromInt(@intFromPtr(vec.iov_base) + step);
            vec.iov_len -= step;
            advance -= step;
        }
    }
}

fn reportError(err: anyerror, context: []const u8) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{s}: {s}", .{ context, @errorName(err) }) catch "agent error";
    writeFrame(1, .@"error", text) catch {};
}

fn waitChild(pid: c.pid_t, flags: c_int) ?u32 {
    while (true) {
        var status: c_int = 0;
        const result = c.waitpid(pid, &status, flags);
        if (result == pid) {
            if (c.WIFEXITED(status)) return @intCast(c.WEXITSTATUS(status));
            if (c.WIFSIGNALED(status)) return 128 + @as(u32, @intCast(c.WTERMSIG(status)));
            return 1;
        }
        if (result == 0) return null;
        if (errno() == c.EINTR) continue;
        return 1;
    }
}

fn signalGroup(pid: c.pid_t, signal: c_int) void {
    _ = c.kill(-pid, signal);
    _ = c.kill(pid, signal);
}

fn setNonBlocking(fd: c_int) void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags >= 0) _ = c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK);
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn errno() c_int {
    return c.__errno_location().*;
}

test "default bash argv uses the integration rcfile" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const argv = try buildShellArgv(arena_state.allocator(), &.{}, "/bin/bash", null, false, .{ .root = "/tmp/hollow-test", .shell = .bash });
    try std.testing.expectEqualStrings("/bin/bash", std.mem.span(argv[0].?));
    try std.testing.expectEqualStrings("--rcfile", std.mem.span(argv[1].?));
    try std.testing.expectEqualStrings("/tmp/hollow-test/bashrc", std.mem.span(argv[2].?));
    try std.testing.expectEqualStrings("-i", std.mem.span(argv[3].?));
    try std.testing.expectEqual(@as(usize, 4), argv.len);
}

test "launch command without integration wraps posix shells" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const argv = try buildShellArgv(arena_state.allocator(), &.{"/bin/sh"}, "/bin/sh", "htop\r\n", true, null);
    try std.testing.expectEqualStrings("-lc", std.mem.span(argv[1].?));
    try std.testing.expectEqualStrings("htop; exit", std.mem.span(argv[2].?));
}

test "windows paths convert to wsl paths" {
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "C:\\Users\\me", "/mnt/c/Users/me" },
        .{ "d:/src", "/mnt/d/src" },
        .{ "\\\\wsl.localhost\\Ubuntu\\home\\me", "/home/me" },
        .{ "\\\\wsl.localhost\\Ubuntu", "/" },
        .{ "/already/posix", "/already/posix" },
    };
    for (cases) |case| {
        const out = try windowsPathToWsl(a, case[0]);
        defer a.free(out);
        try std.testing.expectEqualStrings(case[1], out);
    }
    try std.testing.expect(isPathEnvironmentVariable("home"));
    try std.testing.expect(!isPathEnvironmentVariable("XDG_CONFIG_DIRS"));
}
