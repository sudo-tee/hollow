//! Connection-scoped non-PTY jobs. No transport or connector knowledge.
const std = @import("std");
const supervisor = @import("supervisor.zig");
pub const c = supervisor.c;
const A = std.heap.page_allocator;

pub const Reason = enum { cancelled, timeout, output_limit };
pub const Env = struct { key: []const u8, value: []const u8 };
pub const Options = struct {
    argv: []const []const u8,
    cwd: ?[]const u8,
    env: []const Env,
    timeout_ms: u64,
    output_limit: usize,
    stdout_stream: u64,
    stderr_stream: u64,
    inherited_fds: []const c_int = &.{},
    pty_size: ?struct { rows: u16, cols: u16 } = null,
    output_credit: usize = 0,
};

pub const Job = struct {
    id: u64,
    pid: c.pid_t,
    fds: [3]c_int,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    limit: usize,
    streams: [2]u64,
    deadline: u64,
    reason: ?Reason = null,
    kill_at: u64 = 0,
    killed: bool = false,
    reaped: bool = false,
    status: c_int = 0,
    launch_error: ?c_int = null,
    descendant_cleanup_at: ?u64 = null,
    rpc_worker: bool = false,
    supervised: bool = false,
    pty: bool = false,
    credit: usize = 0,
    input: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Job) void {
        for (&self.fds) |*fd| if (fd.* >= 0) {
            _ = c.close(fd.*);
            fd.* = -1;
        };
        self.stdout.deinit(A);
        self.stderr.deinit(A);
        self.input.deinit(A);
    }

    pub fn cancel(self: *Job, reason: Reason, now: u64) void {
        if (self.reason != null) return;
        self.reason = reason;
        self.kill_at = now + 1500;
        if (!self.reaped) _ = c.kill(if (self.supervised) self.pid else -self.pid, c.SIGTERM);
        self.stdout.clearRetainingCapacity();
        self.stderr.clearRetainingCapacity();
        self.input.clearRetainingCapacity();
    }

    pub fn tick(self: *Job, now: u64) void {
        if (self.reason == null and now >= self.deadline) self.cancel(.timeout, now);
        if (self.reason != null and !self.killed and now >= self.kill_at) {
            if (!self.reaped) _ = c.kill(if (self.supervised) self.pid else -self.pid, if (self.supervised) c.SIGUSR2 else c.SIGKILL);
            self.killed = true;
            // Detached descendants can escape a process group. Never wait for
            // inherited descriptors indefinitely after explicit truncation.
            for (&self.fds) |*fd| if (!self.supervised and fd.* >= 0) {
                _ = c.close(fd.*);
                fd.* = -1;
            };
        }
        // A connection-scoped exec cannot silently become a background-process
        // launcher. Terminate remaining members after their leader exits, even
        // if they redirected stdout/stderr and would otherwise be invisible.
        if (!self.supervised and self.reaped and self.reason == null and !groupGone(self.pid)) {
            if (self.descendant_cleanup_at) |deadline| {
                if (now >= deadline) _ = c.kill(-self.pid, c.SIGKILL);
            } else {
                _ = c.kill(-self.pid, c.SIGTERM);
                self.descendant_cleanup_at = now + 1500;
            }
        }
    }

    pub fn drain(self: *Job, index: usize, now: u64) !void {
        if (self.fds[index] < 0) return;
        var buf: [16384]u8 = undefined;
        // Per-dispatch budget keeps noisy children from monopolizing the loop.
        var budget: usize = 65536;
        while (budget != 0) {
            const room = if (self.pty and index == 0 and self.reason == null) 65536 - self.stdout.items.len else buf.len;
            if (room == 0) return;
            const n = c.read(self.fds[index], &buf, @min(room, @min(buf.len, budget)));
            if (n == 0) {
                _ = c.close(self.fds[index]);
                self.fds[index] = -1;
                return;
            }
            if (n < 0) {
                const e = c.__errno_location().*;
                if (e == c.EINTR) continue;
                if (e == c.EAGAIN) return;
                if (self.pty and index == 0 and e == c.EIO) {
                    _ = c.close(self.fds[index]);
                    self.fds[index] = -1;
                    return;
                }
                return error.IoError;
            }
            const count: usize = @intCast(n);
            budget -= count;
            if (index == 2) {
                // A successful exec closes this descriptor via CLOEXEC.
                if (count == @sizeOf(c_int)) self.launch_error = std.mem.bytesToValue(c_int, buf[0..@sizeOf(c_int)]);
            } else if (self.reason == null) {
                const used = self.stdout.items.len + self.stderr.items.len;
                if (!self.pty and count > self.limit - used) {
                    self.cancel(.output_limit, now);
                    continue;
                }
                const dest = if (index == 0) &self.stdout else &self.stderr;
                try dest.appendSlice(A, buf[0..count]);
            }
        }
    }

    pub fn done(self: *const Job, now: u64) bool {
        if (!self.reaped) return false;
        if (self.pty and self.stdout.items.len != 0) return false;
        if (self.supervised) return self.fds[0] < 0 and self.fds[1] < 0 and self.fds[2] < 0;
        if (self.reason != null) return self.killed or (groupGone(self.pid) and self.fds[0] < 0 and self.fds[1] < 0);
        _ = now;
        return groupGone(self.pid) and self.fds[0] < 0 and self.fds[1] < 0 and self.fds[2] < 0;
    }

    pub fn exitCode(self: *const Job) i32 {
        return if (c.WIFEXITED(self.status)) c.WEXITSTATUS(self.status) else 128 + c.WTERMSIG(self.status);
    }

    pub fn writeInput(self: *Job) !void {
        if (self.input.items.len == 0 or self.fds[0] < 0) return;
        const n = c.write(self.fds[0], self.input.items.ptr, self.input.items.len);
        if (n < 0) {
            const err = c.__errno_location().*;
            if (err == c.EAGAIN or err == c.EINTR) return;
            if (err == c.EIO) {
                self.input.clearRetainingCapacity();
                return;
            }
            return error.IoError;
        }
        const count: usize = @intCast(n);
        std.mem.copyForwards(u8, self.input.items, self.input.items[count..]);
        self.input.items.len -= count;
    }

    pub fn resize(self: *Job, rows: u16, cols: u16) !void {
        var size: c.struct_winsize = .{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
        if (self.fds[0] < 0 or c.ioctl(self.fds[0], c.TIOCSWINSZ, &size) < 0) return error.IoError;
    }
};

fn groupGone(pid: c.pid_t) bool {
    return c.kill(-pid, 0) < 0 and c.__errno_location().* == c.ESRCH;
}

fn valid(bytes: []const u8) bool {
    return bytes.len <= 131072 and std.mem.indexOfScalar(u8, bytes, 0) == null;
}

pub fn spawn(id: u64, opts: Options, now: u64) !Job {
    if (opts.argv.len == 0 or opts.argv.len > 4096 or opts.argv[0].len == 0) return error.InvalidArgv;
    var arena = std.heap.ArenaAllocator.init(A);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try a.alloc(?[*:0]const u8, opts.argv.len + 1);
    for (opts.argv, 0..) |arg, i| {
        if (!valid(arg)) return error.InvalidArgv;
        argv[i] = (try a.dupeZ(u8, arg)).ptr;
    }
    argv[opts.argv.len] = null;
    const cwd = if (opts.cwd) |dir| blk: {
        if (!valid(dir) or dir.len == 0 or dir.len > 4096) return error.InvalidPath;
        break :blk try a.dupeZ(u8, dir);
    } else null;

    var env_map: std.StringHashMap([]const u8) = .init(a);
    var i: usize = 0;
    while (c.environ[i]) |entry| : (i += 1) {
        const text = std.mem.span(entry);
        if (std.mem.indexOfScalar(u8, text, '=')) |eq| try env_map.put(text[0..eq], text[eq + 1 ..]);
    }
    for (opts.env) |env| {
        if (env.key.len == 0 or !valid(env.key) or !valid(env.value) or std.mem.indexOfScalar(u8, env.key, '=') != null) return error.InvalidArgv;
        try env_map.put(env.key, env.value);
    }
    const envp = try a.alloc(?[*:0]const u8, env_map.count() + 1);
    var iterator = env_map.iterator();
    i = 0;
    while (iterator.next()) |entry| : (i += 1) envp[i] = (try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }, 0)).ptr;
    envp[i] = null;

    var candidates: std.ArrayList([*:0]const u8) = .empty;
    if (std.mem.indexOfScalar(u8, opts.argv[0], '/') != null) {
        try candidates.append(a, argv[0].?);
    } else {
        const path = env_map.get("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
        var paths = std.mem.splitScalar(u8, path, ':');
        while (paths.next()) |dir| {
            if (candidates.items.len == 256) return error.InvalidArgv;
            const candidate = if (dir.len == 0) try a.dupeZ(u8, opts.argv[0]) else try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, opts.argv[0] }, 0);
            try candidates.append(a, candidate.ptr);
        }
    }
    var pipes: [3][2]c_int = .{ .{ -1, -1 }, .{ -1, -1 }, .{ -1, -1 } };
    defer for (pipes) |pair| for (pair) |fd| {
        if (fd >= 0) _ = c.close(fd);
    };
    for (&pipes) |*pair| if (c.pipe2(pair, c.O_CLOEXEC) != 0) return error.ResourceExhausted;
    const null_fd = c.open("/dev/null", c.O_RDONLY | c.O_CLOEXEC);
    if (null_fd < 0) return error.ResourceExhausted;
    defer _ = c.close(null_fd);
    const parent = c.getpid();
    var master: c_int = -1;
    var slave: c_int = -1;
    defer {
        if (master >= 0) _ = c.close(master);
        if (slave >= 0) _ = c.close(slave);
    }
    if (opts.pty_size) |size| {
        master = c.posix_openpt(c.O_RDWR | c.O_NOCTTY | c.O_CLOEXEC);
        if (master < 0 or c.grantpt(master) != 0 or c.unlockpt(master) != 0) return error.IoError;
        var name: [256]u8 = undefined;
        if (c.ptsname_r(master, &name, name.len) != 0) return error.IoError;
        slave = c.open(@ptrCast(&name), c.O_RDWR | c.O_NOCTTY | c.O_CLOEXEC);
        if (slave < 0) return error.IoError;
        var window: c.struct_winsize = .{ .ws_row = size.rows, .ws_col = size.cols, .ws_xpixel = 0, .ws_ypixel = 0 };
        if (c.ioctl(slave, c.TIOCSWINSZ, &window) < 0) return error.IoError;
    }
    const pid = c.fork();
    if (pid < 0) return error.ResourceExhausted;
    if (pid == 0) {
        supervisor.run(parent, .{ .pipes = pipes, .null_fd = null_fd, .argv = argv, .env = envp, .candidates = candidates.items, .cwd = cwd, .inherited_fds = opts.inherited_fds, .pty_master = master, .pty_slave = slave });
    }
    _ = c.setpgid(pid, pid);
    var fds: [3]c_int = undefined;
    for (&pipes, 0..) |*pair, index| {
        fds[index] = pair[0];
        pair[0] = -1;
        const flags = c.fcntl(fds[index], c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(fds[index], c.F_SETFL, flags | c.O_NONBLOCK);
    }
    if (master >= 0) {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        fds[0] = master;
        fds[1] = -1;
        master = -1;
        const flags = c.fcntl(fds[0], c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(fds[0], c.F_SETFL, flags | c.O_NONBLOCK);
    }
    return .{ .id = id, .pid = pid, .fds = fds, .limit = opts.output_limit, .streams = .{ opts.stdout_stream, opts.stderr_stream }, .deadline = now + opts.timeout_ms, .supervised = true, .pty = opts.pty_size != null, .credit = opts.output_credit };
}
