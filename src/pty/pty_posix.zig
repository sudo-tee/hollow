const std = @import("std");
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

    pub fn spawn(allocator: std.mem.Allocator, shell: [:0]const u8, cols: u16, rows: u16, cwd: ?[]const u8, env_block: ?[]const u8) !PosixPty {
        var winsize = std.mem.zeroes(c.struct_winsize);
        winsize.ws_col = cols;
        winsize.ws_row = rows;

        var master: c_int = -1;
        const pid = c.forkpty(&master, null, null, &winsize);
        if (pid == 0) {
            if (cwd) |dir| {
                const dir_z = std.cstr.addNullByte(std.heap.page_allocator, dir) catch c._exit(1);
                defer std.heap.page_allocator.free(dir_z);
                if (c.chdir(dir_z.ptr) != 0) c._exit(1);
            }
            const argv = [_:null]?[*:0]const u8{ shell.ptr, null };
            const envp = if (env_block) |env| tryParseEnvBlock(std.heap.page_allocator, env) catch null else null;
            defer if (envp) |items| {
                for (items) |item| std.heap.page_allocator.free(item);
                std.heap.page_allocator.free(items);
            };
            _ = c.execve(shell.ptr, @ptrCast(@constCast(&argv)), if (envp) |items| @ptrCast(items.ptr) else null);
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

    fn tryParseEnvBlock(allocator: std.mem.Allocator, env_block: []const u8) ![][:0]u8 {
        var list = std.ArrayList([:0]u8).init(allocator);
        errdefer {
            for (list.items) |item| allocator.free(item);
            list.deinit();
        }
        var it = std.mem.splitScalar(u8, env_block, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            try list.append(try allocator.dupeZ(u8, line));
        }
        return try list.toOwnedSlice();
    }

    pub fn deinit(self: *PosixPty) void {
        self.close();
    }

    pub fn isAlive(self: *PosixPty) bool {
        if (self.closed or !self.alive) return false;
        var status: c_int = 0;
        const result = c.waitpid(self.pid, &status, c.WNOHANG);
        if (result == self.pid) self.alive = false;
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

    pub fn hasPendingOutput(_: *PosixPty) bool {
        return false;
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
