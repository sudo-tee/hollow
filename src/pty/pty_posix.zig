const std = @import("std");
const app = @import("../app.zig");
const LaunchCommand = @import("launch_command.zig").LaunchCommand;
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

const ReaderState = struct {
    mutex: std.Thread.Mutex = .{},
    buf: std.ArrayListUnmanaged(u8) = .empty,
    start: usize = 0,
    eof: bool = false,
    saw_read: bool = false,
    closing: bool = false,
};

pub const PosixPty = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    pid: c.pid_t,
    reader_state: *ReaderState,
    reader_thread: ?std.Thread = null,
    alive: bool = true,
    closed: bool = false,

    pub fn spawn(allocator: std.mem.Allocator, shell: [:0]const u8, cols: u16, rows: u16, cwd: ?[]const u8, env_block: ?[]const u8, launch_command: ?LaunchCommand) !PosixPty {
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
            const bundle = try shell_integration.install(std.heap.page_allocator, shell);
            if (bundle) |value| try shell_integration.setupEnv(std.heap.page_allocator, value);
            const argv = try buildArgv(std.heap.page_allocator, shell, launch_command, bundle);
            defer freeArgv(std.heap.page_allocator, argv);
            var env_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer env_arena.deinit();
            const envp = if (env_block) |env| buildEnvp(env_arena.allocator(), env) catch null else null;
            _ = c.execve(shell.ptr, @ptrCast(@constCast(argv.ptr)), if (envp) |items| @ptrCast(items.ptr) else null);
            c._exit(1);
        }
        if (pid < 0) return error.ForkPtyFailed;

        const reader_state = try allocator.create(ReaderState);
        reader_state.* = .{};
        errdefer allocator.destroy(reader_state);

        var pty = PosixPty{
            .allocator = allocator,
            .fd = master,
            .pid = pid,
            .reader_state = reader_state,
        };
        pty.reader_thread = try std.Thread.spawn(.{}, readerLoop, .{ pty.fd, pty.reader_state });

        return pty;
    }

    fn buildEnvp(allocator: std.mem.Allocator, env_block: []const u8) ![:null]?[*:0]u8 {
        var env_map = try std.process.getEnvMap(allocator);
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

        return try std.process.createNullDelimitedEnvMap(allocator, &env_map);
    }

    fn buildArgv(allocator: std.mem.Allocator, shell: [:0]const u8, launch_command: ?LaunchCommand, bundle: ?shell_integration.Bundle) ![]?[*:0]const u8 {
        var argv: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
        errdefer {
            freeArgvOwnedStrings(allocator, argv.items);
            argv.deinit(allocator);
        }
        try argv.append(allocator, shell.ptr);

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
            const shell_name = std.fs.path.basename(shell);
            if (std.mem.eql(u8, shell_name, "bash") or std.mem.eql(u8, shell_name, "sh") or std.mem.eql(u8, shell_name, "zsh") or std.mem.eql(u8, shell_name, "fish")) {
                try argv.append(allocator, (try allocator.dupeZ(u8, "-lc")).ptr);
                const wrapped = if (cmd.close_on_exit)
                    try std.fmt.allocPrintSentinel(allocator, "{s}; exit", .{std.mem.trimRight(u8, cmd.command, "\r\n")}, 0)
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
        for (argv[1..]) |value| {
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
        if (pending == 0) return 0;

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
        return count;
    }

    pub fn hasPendingOutput(self: *PosixPty) bool {
        if (self.closed) return false;
        self.reader_state.mutex.lock();
        defer self.reader_state.mutex.unlock();
        return self.reader_state.buf.items.len > self.reader_state.start;
    }

    pub fn writeAll(self: *PosixPty, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const written = c.write(self.fd, bytes.ptr + offset, bytes.len - offset);
            if (written < 0) {
                switch (std.posix.errno(-1)) {
                    .AGAIN => continue,
                    else => return error.WriteFailed,
                }
            }
            offset += @intCast(written);
        }
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
        self.reader_state.mutex.unlock();
        if (self.isAlive()) _ = c.kill(self.pid, c.SIGTERM);
        _ = c.close(self.fd);
        if (self.reader_thread) |thread| thread.join();
        self.reader_state.buf.deinit(std.heap.page_allocator);
        self.allocator.destroy(self.reader_state);
        self.closed = true;
        self.alive = false;
    }
};

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
            reader_state.saw_read = true;
            reader_state.buf.appendSlice(std.heap.page_allocator, temp[0..@intCast(result)]) catch {};
            reader_state.mutex.unlock();
            app.signalExternalWake();
            continue;
        }
        if (result == 0) {
            reader_state.mutex.lock();
            reader_state.eof = true;
            reader_state.mutex.unlock();
            return;
        }
        switch (std.posix.errno(-1)) {
            .INTR => {},
            .AGAIN => {},
            else => {
                reader_state.mutex.lock();
                if (!reader_state.closing) reader_state.eof = true;
                reader_state.mutex.unlock();
                return;
            },
        }
    }
}
