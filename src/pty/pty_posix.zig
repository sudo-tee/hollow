const std = @import("std");
const io = @import("../io.zig");
const LaunchCommand = @import("launch_command.zig").LaunchCommand;
const Wake = @import("wake.zig").Wake;
const shell_integration = @import("../shell_integration.zig");
const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("pty.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

const READER_HIGH_WATER_BYTES = 4 * 1024 * 1024;

const WRITER_HIGH_WATER_BYTES = 4 * 1024 * 1024;

const WriterState = struct {
    mutex: io.Mutex = .{},
    ready: io.Condition = .{},
    buf: std.ArrayListUnmanaged(u8) = .empty,
    start: usize = 0,
    closing: bool = false,
    failed: bool = false,
};

const ReaderState = struct {
    mutex: io.Mutex = .{},
    ready: io.Condition = .{},
    buf: std.ArrayListUnmanaged(u8) = .empty,
    start: usize = 0,
    eof: bool = false,
    saw_read: bool = false,
    closing: bool = false,
    out_of_memory: bool = false,
    wake: Wake = .{},
};

pub const PosixPty = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    pid: c.pid_t,
    reader_state: *ReaderState,
    reader_thread: ?std.Thread = null,
    writer_state: *WriterState,
    writer_thread: ?std.Thread = null,
    alive: bool = true,
    closed: bool = false,

    pub fn spawn(allocator: std.mem.Allocator, shell: [:0]const u8, cols: u16, rows: u16, cwd: ?[]const u8, env_block: ?[]const u8, launch_command: ?LaunchCommand, wake: Wake) !PosixPty {
        std.log.info("pty_posix.spawn shell={s} cwd={s} launch_command={}", .{
            shell,
            cwd orelse "<null>",
            launch_command != null,
        });
        var winsize = std.mem.zeroes(c.struct_winsize);
        winsize.ws_col = cols;
        winsize.ws_row = rows;

        var master: c_int = -1;
        const pid = c.forkpty(&master, null, null, &winsize);
        if (pid == 0) {
            if (cwd) |dir| {
                const dir_z = std.heap.page_allocator.dupeZ(u8, dir) catch c._exit(1);
                defer std.heap.page_allocator.free(dir_z);
                if (c.chdir(dir_z.ptr) != 0) c._exit(1);
            }
            const shell_args = parseCommandString(std.heap.page_allocator, shell) catch c._exit(1);
            defer freeCommandParts(std.heap.page_allocator, shell_args);
            if (shell_args.len == 0) c._exit(1);
            const shell_path = std.heap.page_allocator.dupeZ(u8, shell_args[0]) catch c._exit(1);
            defer std.heap.page_allocator.free(shell_path);
            const bundle = shell_integration.install(std.heap.page_allocator, shell_args[0]) catch c._exit(1);
            if (bundle) |value| shell_integration.setupEnv(std.heap.page_allocator, value) catch c._exit(1);
            const argv = buildArgv(std.heap.page_allocator, shell_args, launch_command, bundle) catch c._exit(1);
            defer freeArgv(std.heap.page_allocator, argv);
            var env_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer env_arena.deinit();
            const envp = if (env_block) |env| buildEnvp(env_arena.allocator(), env) catch c._exit(1) else null;
            execWithPath(shell_path, argv, if (envp) |items| @ptrCast(@constCast(items.ptr)) else null);
            c._exit(1);
        }
        if (pid < 0) return error.ForkPtyFailed;
        errdefer {
            _ = c.kill(pid, c.SIGKILL);
            _ = c.close(master);
            _ = c.waitpid(pid, null, 0);
        }

        const reader_state = try allocator.create(ReaderState);
        reader_state.* = .{ .wake = wake };
        errdefer allocator.destroy(reader_state);

        // Both workers share a nonblocking master. Never toggle descriptor flags
        // around individual writes: that races the reader thread.
        const flags = c.fcntl(master, c.F_GETFL, @as(c_int, 0));
        if (flags < 0 or c.fcntl(master, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.WriteFailed;
        const writer_state = try allocator.create(WriterState);
        writer_state.* = .{};
        errdefer allocator.destroy(writer_state);

        var pty = PosixPty{
            .allocator = allocator,
            .fd = master,
            .pid = pid,
            .reader_state = reader_state,
            .writer_state = writer_state,
        };
        pty.writer_thread = try std.Thread.spawn(.{}, writerLoop, .{ pty.fd, writer_state });
        errdefer {
            writer_state.mutex.lock();
            writer_state.closing = true;
            writer_state.ready.broadcast();
            writer_state.mutex.unlock();
            pty.writer_thread.?.join();
        }
        pty.reader_thread = try std.Thread.spawn(.{}, readerLoop, .{ pty.fd, pty.reader_state });

        return pty;
    }

    fn buildEnvp(allocator: std.mem.Allocator, env_block: []const u8) ![:null]const ?[*:0]const u8 {
        var env_map = try io.environ().createMap(allocator);
        defer env_map.deinit();

        var i: usize = 0;
        while (i < env_block.len) {
            const entry_start = i;
            while (i < env_block.len and env_block[i] != 0) : (i += 1) {}
            if (i > entry_start) {
                const entry = env_block[entry_start..i];
                if (std.mem.indexOfScalar(u8, entry, '=')) |eq_pos| {
                    try env_map.put(entry[0..eq_pos], entry[eq_pos + 1 ..]);
                }
            }
            i += 1;
            if (i < env_block.len and env_block[i] == 0) break;
        }

        return (try env_map.createPosixBlock(allocator, .{})).slice;
    }

    fn buildArgv(allocator: std.mem.Allocator, shell_args: []const []const u8, launch_command: ?LaunchCommand, bundle: ?shell_integration.Bundle) ![]?[*:0]const u8 {
        if (shell_args.len == 0) return error.InvalidCharacter;
        var argv: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
        errdefer {
            freeArgvOwnedStrings(allocator, argv.items);
            argv.deinit(allocator);
        }
        for (shell_args) |arg| {
            try argv.append(allocator, (try allocator.dupeZ(u8, arg)).ptr);
        }

        if (bundle) |value| {
            const integration_argv = try shell_integration.argv(allocator, value, if (launch_command) |cmd| cmd.command else null, if (launch_command) |cmd| cmd.close_on_exit else false);
            defer {
                for (integration_argv) |arg| allocator.free(arg);
                allocator.free(integration_argv);
            }
            for (integration_argv) |arg| try argv.append(allocator, (try allocator.dupeZ(u8, arg)).ptr);
            try argv.append(allocator, null);
            return try argv.toOwnedSlice(allocator);
        }

        if (launch_command) |cmd| {
            const shell_name = std.fs.path.basename(shell_args[0]);
            if (std.mem.eql(u8, shell_name, "bash") or std.mem.eql(u8, shell_name, "sh") or std.mem.eql(u8, shell_name, "zsh") or std.mem.eql(u8, shell_name, "fish")) {
                try argv.append(allocator, (try allocator.dupeZ(u8, "-lc")).ptr);
                const wrapped = if (cmd.close_on_exit)
                    try std.fmt.allocPrintSentinel(allocator, "{s}; exit", .{std.mem.trimEnd(u8, cmd.command, "\r\n")}, 0)
                else
                    try allocator.dupeZ(u8, cmd.command);
                try argv.append(allocator, wrapped.ptr);
            } else if (std.mem.eql(u8, shell_name, "ssh") or std.mem.eql(u8, shell_name, "ssh.exe")) {
                try argv.append(allocator, (try allocator.dupeZ(u8, "-tt")).ptr);
                const wrapped = if (cmd.close_on_exit)
                    try std.fmt.allocPrintSentinel(allocator, "{s}; exit", .{std.mem.trimEnd(u8, cmd.command, "\r\n")}, 0)
                else
                    try allocator.dupeZ(u8, cmd.command);
                try argv.append(allocator, wrapped.ptr);
            }
        }

        try argv.append(allocator, null);
        return try argv.toOwnedSlice(allocator);
    }

    fn freeArgv(allocator: std.mem.Allocator, argv: []?[*:0]const u8) void {
        freeArgvOwnedStrings(allocator, argv);
        allocator.free(argv);
    }

    fn freeArgvOwnedStrings(allocator: std.mem.Allocator, argv: []const ?[*:0]const u8) void {
        for (argv) |value| {
            if (value) |ptr| allocator.free(std.mem.span(ptr));
        }
    }

    pub fn deinit(self: *PosixPty) void {
        self.close();
    }

    pub fn isAlive(self: *PosixPty) bool {
        if (self.closed or !self.alive) return false;
        self.reader_state.mutex.lock();
        const eof = self.reader_state.eof;
        const saw_read = self.reader_state.saw_read;
        const pending = self.reader_state.buf.items.len - self.reader_state.start;
        self.reader_state.mutex.unlock();
        if (eof) {
            self.alive = false;
            return false;
        }
        if (saw_read and pending > 0) return true;
        var status: c_int = 0;
        const result = c.waitpid(self.pid, &status, c.WNOHANG);
        if (result == self.pid) {
            self.alive = false;
            if (c.WIFEXITED(status)) {
                std.log.info("pty_posix child exited pid={} status={}", .{ self.pid, c.WEXITSTATUS(status) });
            } else if (c.WIFSIGNALED(status)) {
                std.log.warn("pty_posix child signaled pid={} signal={}", .{ self.pid, c.WTERMSIG(status) });
            } else {
                std.log.warn("pty_posix child ended pid={} raw_status={}", .{ self.pid, status });
            }
        }
        return self.alive;
    }

    pub fn read(self: *PosixPty, buffer: []u8) !usize {
        if (buffer.len == 0) return 0;
        self.reader_state.mutex.lock();
        defer self.reader_state.mutex.unlock();

        const pending = self.reader_state.buf.items.len - self.reader_state.start;
        if (pending == 0) {
            if (self.reader_state.out_of_memory) {
                self.reader_state.out_of_memory = false;
                self.reader_state.eof = true;
                return error.OutOfMemory;
            }
            return 0;
        }

        const count = @min(buffer.len, pending);
        @memcpy(buffer[0..count], self.reader_state.buf.items[self.reader_state.start .. self.reader_state.start + count]);
        self.reader_state.start += count;
        if (self.reader_state.start == self.reader_state.buf.items.len) {
            self.reader_state.buf.items.len = 0;
            self.reader_state.start = 0;
        } else if (self.reader_state.start >= 65536 and self.reader_state.start * 2 >= self.reader_state.buf.items.len) {
            const remaining = self.reader_state.buf.items.len - self.reader_state.start;
            std.mem.copyForwards(u8, self.reader_state.buf.items[0..remaining], self.reader_state.buf.items[self.reader_state.start..]);
            self.reader_state.buf.items.len = remaining;
            self.reader_state.start = 0;
        }
        self.reader_state.ready.signal();
        return count;
    }

    pub fn hasPendingOutput(self: *PosixPty) bool {
        if (self.closed) return false;
        self.reader_state.mutex.lock();
        defer self.reader_state.mutex.unlock();
        return self.reader_state.buf.items.len > self.reader_state.start;
    }

    pub fn pendingOutputBytes(self: *PosixPty) usize {
        if (self.closed) return 0;
        self.reader_state.mutex.lock();
        defer self.reader_state.mutex.unlock();
        return self.reader_state.buf.items.len - self.reader_state.start;
    }

    pub fn hasPendingOutputOrExit(self: *PosixPty) bool {
        if (self.closed) return true;
        self.reader_state.mutex.lock();
        defer self.reader_state.mutex.unlock();
        return self.reader_state.eof or self.reader_state.out_of_memory or self.reader_state.buf.items.len > self.reader_state.start;
    }

    /// Enqueue input without waiting for the child to read it. Admission is
    /// all-or-nothing so callers never retry a partially accepted paste.
    pub fn writeAll(self: *PosixPty, bytes: []const u8) !void {
        const state = self.writer_state;
        state.mutex.lock();
        defer state.mutex.unlock();
        if (state.closing or state.failed) return error.WriteFailed;
        const pending = state.buf.items.len - state.start;
        if (bytes.len > WRITER_HIGH_WATER_BYTES - pending) return error.InputQueueFull;
        if (state.start > 0 and state.buf.capacity - state.buf.items.len < bytes.len) {
            std.mem.copyForwards(u8, state.buf.items[0..pending], state.buf.items[state.start..]);
            state.buf.items.len = pending;
            state.start = 0;
        }
        try state.buf.appendSlice(std.heap.page_allocator, bytes);
        state.ready.signal();
    }

    pub fn writeAllUntil(self: *PosixPty, bytes: []const u8, deadline_ns: i128) !usize {
        if (io.nanoTimestamp() >= deadline_ns) return 0;
        self.writeAll(bytes) catch |err| {
            if (err == error.InputQueueFull) return 0;
            return err;
        };
        return bytes.len;
    }

    pub fn resize(self: *PosixPty, cols: u16, rows: u16) void {
        var winsize = std.mem.zeroes(c.struct_winsize);
        winsize.ws_col = cols;
        winsize.ws_row = rows;
        _ = c.ioctl(self.fd, c.TIOCSWINSZ, &winsize);
    }

    pub fn childPid(self: *const PosixPty) usize {
        return @intCast(self.pid);
    }

    pub fn close(self: *PosixPty) void {
        if (self.closed) return;
        self.reader_state.mutex.lock();
        self.reader_state.closing = true;
        self.reader_state.ready.broadcast();
        self.reader_state.mutex.unlock();
        if (self.isAlive()) _ = c.kill(self.pid, c.SIGTERM);
        self.writer_state.mutex.lock();
        self.writer_state.closing = true;
        self.writer_state.ready.broadcast();
        self.writer_state.mutex.unlock();
        if (self.writer_thread) |thread| thread.join();
        if (self.reader_thread) |thread| thread.join();
        _ = c.close(self.fd);
        self.writer_state.buf.deinit(std.heap.page_allocator);
        self.allocator.destroy(self.writer_state);
        self.reader_state.buf.deinit(std.heap.page_allocator);
        self.allocator.destroy(self.reader_state);
        self.closed = true;
        self.alive = false;
    }
};

fn parseCommandString(allocator: std.mem.Allocator, command: []const u8) ![]const []const u8 {
    var parts = std.ArrayList([]const u8).empty;
    errdefer {
        for (parts.items) |item| allocator.free(item);
        parts.deinit(allocator);
    }

    var current = std.ArrayList(u8).empty;
    defer current.deinit(allocator);

    var quote: ?u8 = null;
    var escaped = false;
    for (command) |ch| {
        if (escaped) {
            try current.append(allocator, ch);
            escaped = false;
            continue;
        }

        if (quote == null and ch == '\\') {
            escaped = true;
            continue;
        }

        if (quote) |value| {
            if (ch == value) {
                quote = null;
            } else {
                try current.append(allocator, ch);
            }
            continue;
        }

        if (ch == '\'' or ch == '"') {
            quote = ch;
        } else if (std.ascii.isWhitespace(ch)) {
            if (current.items.len > 0) {
                try parts.append(allocator, try current.toOwnedSlice(allocator));
                current = std.ArrayList(u8).empty;
            }
        } else {
            try current.append(allocator, ch);
        }
    }

    if (escaped) try current.append(allocator, '\\');
    if (quote != null) return error.InvalidCharacter;
    if (current.items.len > 0) {
        try parts.append(allocator, try current.toOwnedSlice(allocator));
    }
    return try parts.toOwnedSlice(allocator);
}

fn freeCommandParts(allocator: std.mem.Allocator, parts: []const []const u8) void {
    for (parts) |item| allocator.free(item);
    allocator.free(parts);
}

fn execWithPath(path: [:0]const u8, argv: []?[*:0]const u8, envp: ?[*:null]?[*:0]const u8) void {
    const argv_ptr: [*:null]?[*:0]const u8 = @ptrCast(argv.ptr);
    if (std.mem.indexOfAny(u8, path, "/") != null) {
        _ = c.execve(path.ptr, @ptrCast(argv_ptr), if (envp) |items| @ptrCast(items) else null);
        return;
    }

    const path_env = c.getenv("PATH") orelse {
        _ = c.execve(path.ptr, @ptrCast(argv_ptr), if (envp) |items| @ptrCast(items) else null);
        return;
    };
    var path_iter = std.mem.splitScalar(u8, std.mem.span(path_env), ':');
    while (path_iter.next()) |directory| {
        const candidate = std.fmt.allocPrintSentinel(std.heap.page_allocator, "{s}/{s}", .{ if (directory.len > 0) directory else ".", path }, 0) catch return;
        defer std.heap.page_allocator.free(candidate);
        _ = c.execve(candidate.ptr, @ptrCast(argv_ptr), if (envp) |items| @ptrCast(items) else null);
        if (std.posix.errno(-1) != .NOENT) return;
    }
}

test "posix shell argv supports SSH commands" {
    const shell_args = try parseCommandString(std.testing.allocator, "ssh -o ControlPath=/tmp/hollow-ssh-%C devbox");
    defer freeCommandParts(std.testing.allocator, shell_args);

    const argv = try PosixPty.buildArgv(std.testing.allocator, shell_args, .{
        .command = "cd -- '/srv/project' && exec \"$SHELL\" -il",
    }, null);
    defer PosixPty.freeArgv(std.testing.allocator, argv);

    try std.testing.expectEqualStrings("ssh", std.mem.span(argv[0].?));
    try std.testing.expectEqualStrings("-o", std.mem.span(argv[1].?));
    try std.testing.expectEqualStrings("ControlPath=/tmp/hollow-ssh-%C", std.mem.span(argv[2].?));
    try std.testing.expectEqualStrings("devbox", std.mem.span(argv[3].?));
    try std.testing.expectEqualStrings("-tt", std.mem.span(argv[4].?));
    try std.testing.expectEqualStrings("cd -- '/srv/project' && exec \"$SHELL\" -il", std.mem.span(argv[5].?));
}

fn readerLoop(fd: c_int, reader_state: *ReaderState) void {
    var temp: [4096]u8 = undefined;
    while (true) {
        reader_state.mutex.lock();
        const closing = reader_state.closing;
        reader_state.mutex.unlock();
        if (closing) return;

        var poll_fd = c.struct_pollfd{
            .fd = fd,
            .events = c.POLLIN,
            .revents = 0,
        };
        const ready = c.poll(&poll_fd, 1, 100);
        if (ready == 0) continue;
        if (ready < 0) {
            if (std.posix.errno(-1) == .INTR) continue;
            return;
        }

        const result = c.read(fd, &temp, temp.len);
        if (result > 0) {
            reader_state.mutex.lock();
            const bytes = temp[0..@intCast(result)];
            while (!reader_state.closing and reader_state.buf.items.len - reader_state.start + bytes.len > READER_HIGH_WATER_BYTES) {
                reader_state.ready.wait(&reader_state.mutex);
            }
            if (reader_state.closing) {
                reader_state.mutex.unlock();
                return;
            }
            if (reader_state.start > 0 and reader_state.start + bytes.len > reader_state.buf.capacity) {
                const remaining = reader_state.buf.items.len - reader_state.start;
                std.mem.copyForwards(u8, reader_state.buf.items[0..remaining], reader_state.buf.items[reader_state.start..]);
                reader_state.buf.items.len = remaining;
                reader_state.start = 0;
            }
            reader_state.saw_read = true;
            reader_state.buf.appendSlice(std.heap.page_allocator, bytes) catch {
                reader_state.out_of_memory = true;
                reader_state.mutex.unlock();
                reader_state.wake.signal();
                return;
            };
            reader_state.mutex.unlock();
            reader_state.wake.signal();
            continue;
        }
        if (result == 0) {
            reader_state.mutex.lock();
            reader_state.eof = true;
            reader_state.mutex.unlock();
            reader_state.wake.signal();
            return;
        }
        switch (std.posix.errno(-1)) {
            .INTR => {},
            .AGAIN => {},
            else => {
                var exited = false;
                reader_state.mutex.lock();
                if (!reader_state.closing) {
                    reader_state.eof = true;
                    exited = true;
                }
                reader_state.mutex.unlock();
                if (exited) reader_state.wake.signal();
                return;
            },
        }
    }
}

fn writerLoop(fd: c_int, state: *WriterState) void {
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        state.mutex.lock();
        while (!state.closing and state.start == state.buf.items.len) state.ready.wait(&state.mutex);
        if (state.closing) {
            state.mutex.unlock();
            return;
        }
        const count = @min(chunk.len, state.buf.items.len - state.start);
        @memcpy(chunk[0..count], state.buf.items[state.start..][0..count]);
        state.mutex.unlock();

        var poll_fd = c.struct_pollfd{ .fd = fd, .events = c.POLLOUT, .revents = 0 };
        const ready = c.poll(&poll_fd, 1, 25);
        if (ready == 0) continue;
        if (ready < 0 and std.posix.errno(-1) == .INTR) continue;
        const written = if (ready > 0) c.write(fd, &chunk, count) else -1;
        if (written < 0) switch (std.posix.errno(-1)) {
            .AGAIN, .INTR => continue,
            else => {},
        };
        state.mutex.lock();
        if (written <= 0) {
            state.failed = true;
            state.mutex.unlock();
            return;
        }
        state.start += @intCast(written);
        if (state.start == state.buf.items.len) {
            state.buf.clearRetainingCapacity();
            state.start = 0;
        }
        state.mutex.unlock();
    }
}

test "queued input is bounded and admission preserves existing bytes" {
    var state = WriterState{};
    defer state.buf.deinit(std.heap.page_allocator);
    var pty = PosixPty{ .allocator = std.testing.allocator, .fd = -1, .pid = 0, .reader_state = undefined, .writer_state = &state };
    try pty.writeAll("first");
    const oversized = try std.testing.allocator.alloc(u8, WRITER_HIGH_WATER_BYTES);
    defer std.testing.allocator.free(oversized);
    try std.testing.expectError(error.InputQueueFull, pty.writeAll(oversized));
    try pty.writeAll("second");
    try std.testing.expectEqualStrings("firstsecond", state.buf.items);
    try std.testing.expectEqual(@as(usize, 0), try pty.writeAllUntil("late", io.nanoTimestamp() - 1));
    state.closing = true;
    try std.testing.expectError(error.WriteFailed, pty.writeAll("closed"));
}

test "writer shutdown completes when child pipe is full" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    const flags = c.fcntl(fds[1], c.F_GETFL, @as(c_int, 0));
    try std.testing.expect(c.fcntl(fds[1], c.F_SETFL, flags | c.O_NONBLOCK) >= 0);
    const filler = [_]u8{0} ** 4096;
    while (c.write(fds[1], &filler, filler.len) > 0) {}
    var state = WriterState{};
    defer state.buf.deinit(std.heap.page_allocator);
    var pty = PosixPty{ .allocator = std.testing.allocator, .fd = fds[1], .pid = 0, .reader_state = undefined, .writer_state = &state };
    try pty.writeAll("queued behind blocked pipe");
    const worker = try std.Thread.spawn(.{}, writerLoop, .{ fds[1], &state });
    state.mutex.lock();
    state.closing = true;
    state.ready.broadcast();
    state.mutex.unlock();
    worker.join();
    try std.testing.expectEqualStrings("queued behind blocked pipe", state.buf.items);
}
