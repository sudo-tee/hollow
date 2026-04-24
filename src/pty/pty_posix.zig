const std = @import("std");
const LaunchCommand = @import("launch_command.zig").LaunchCommand;
const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("pty.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

pub const PosixPty = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    pid: c.pid_t,
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
            const argv = try buildArgv(std.heap.page_allocator, shell, launch_command);
            defer freeArgv(std.heap.page_allocator, argv);
            var env_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer env_arena.deinit();
            const envp = if (env_block) |env| buildEnvp(env_arena.allocator(), env) catch null else null;
            _ = c.execve(shell.ptr, @ptrCast(@constCast(argv.ptr)), if (envp) |items| @ptrCast(items.ptr) else null);
            c._exit(1);
        }
        if (pid < 0) return error.ForkPtyFailed;

        const flags = c.fcntl(master, c.F_GETFL, @as(c_int, 0));
        if (flags >= 0) _ = c.fcntl(master, c.F_SETFL, flags | c.O_NONBLOCK);

        return .{
            .allocator = allocator,
            .fd = master,
            .pid = pid,
        };
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

    fn buildArgv(allocator: std.mem.Allocator, shell: [:0]const u8, launch_command: ?LaunchCommand) ![]?[*:0]const u8 {
        var argv: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
        errdefer {
            freeArgvOwnedStrings(allocator, argv.items);
            argv.deinit(allocator);
        }
        try argv.append(allocator, shell.ptr);

        if (launch_command) |cmd| {
            const shell_name = std.fs.path.basename(shell);
            if (std.mem.eql(u8, shell_name, "bash") or std.mem.eql(u8, shell_name, "sh") or std.mem.eql(u8, shell_name, "zsh") or std.mem.eql(u8, shell_name, "fish")) {
                try argv.append(allocator, "-lc");
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
        if (argv.len > 2) {
            if (argv[2]) |ptr| allocator.free(std.mem.span(ptr));
        }
    }

    pub fn deinit(self: *PosixPty) void {
        self.close();
    }

    pub fn isAlive(self: *PosixPty) bool {
        if (self.closed or !self.alive) return false;
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
        const result = c.read(self.fd, buffer.ptr, buffer.len);
        if (result > 0) return @intCast(result);
        if (result == 0) {
            self.alive = false;
            return 0;
        }
        switch (std.posix.errno(-1)) {
            .AGAIN => return 0,
            else => return error.ReadFailed,
        }
    }

    pub fn hasPendingOutput(self: *PosixPty) bool {
        if (self.closed) return false;

        var pending: c_int = 0;
        if (c.ioctl(self.fd, c.FIONREAD, &pending) != 0) return false;
        return pending > 0;
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
        if (self.isAlive()) _ = c.kill(self.pid, c.SIGTERM);
        _ = c.close(self.fd);
        self.closed = true;
        self.alive = false;
    }
};
