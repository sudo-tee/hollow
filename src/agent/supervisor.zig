//! A small, per-exec subreaper. It owns the workload's lifetime independently
//! of the RPC agent, and has neither a listener nor a persistence contract.
const std = @import("std");
pub const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/prctl.h");
    @cInclude("sys/signalfd.h");
    @cInclude("poll.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
    @cInclude("stdlib.h");
});

pub const Launch = struct {
    pipes: [3][2]c_int,
    null_fd: c_int,
    argv: []const ?[*:0]const u8,
    env: []const ?[*:0]const u8,
    candidates: []const [*:0]const u8,
    cwd: ?[:0]const u8,
    inherited_fds: []const c_int,
};

/// Called only in a fork child of the single-threaded agent. Launch memory was
/// prepared by the parent; the workload child allocates nothing before exec.
pub fn run(parent: c.pid_t, launch: Launch) noreturn {
    const error_fd = launch.pipes[2][1];
    _ = c.setpgid(0, 0);
    var signals: c.sigset_t = undefined;
    _ = c.sigemptyset(&signals);
    _ = c.sigaddset(&signals, c.SIGCHLD);
    _ = c.sigaddset(&signals, c.SIGTERM);
    _ = c.sigaddset(&signals, c.SIGINT);
    _ = c.sigaddset(&signals, c.SIGUSR2);
    if (c.sigprocmask(c.SIG_SETMASK, &signals, null) != 0) fail(error_fd, c.__errno_location().*);
    // SIGTERM remains blocked until signalfd is ready, closing the setup race.
    if (c.prctl(c.PR_SET_CHILD_SUBREAPER, @as(c_ulong, 1), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0 or
        c.prctl(c.PR_SET_PDEATHSIG, @as(c_ulong, c.SIGTERM), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0)
        fail(error_fd, c.__errno_location().*);
    if (c.getppid() != parent) c._exit(126);
    const signal_fd = c.signalfd(-1, &signals, c.SFD_CLOEXEC | c.SFD_NONBLOCK);
    if (signal_fd < 0) fail(error_fd, c.__errno_location().*);
    var path_buf: [96]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/self/task/{d}/children", .{c.getpid()}, 0) catch c._exit(126);
    const children_fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC);
    if (children_fd < 0) fail(error_fd, c.__errno_location().*);

    // No guardian may hold the RPC pipes or another job's descriptors open.
    for (launch.inherited_fds) |fd| if (fd >= 0) {
        _ = c.close(fd);
    };
    if (c.dup2(launch.null_fd, 0) < 0 or c.dup2(launch.null_fd, 1) < 0 or c.dup2(launch.null_fd, 2) < 0)
        fail(error_fd, c.__errno_location().*);
    const guardian_pid = c.getpid();
    const leader = c.fork();
    if (leader < 0) fail(error_fd, c.__errno_location().*);
    if (leader == 0) {
        _ = c.setpgid(0, 0);
        if (c.prctl(c.PR_SET_PDEATHSIG, @as(c_ulong, c.SIGKILL), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0)
            fail(error_fd, c.__errno_location().*);
        // Guardian death during fork setup must not leave a newly launched job.
        if (c.getppid() != guardian_pid) c._exit(126);
        var empty: c.sigset_t = undefined;
        _ = c.sigemptyset(&empty);
        _ = c.sigprocmask(c.SIG_SETMASK, &empty, null);
        _ = c.signal(c.SIGPIPE, null);
        if (c.dup2(launch.pipes[0][1], 1) < 0 or c.dup2(launch.pipes[1][1], 2) < 0)
            fail(error_fd, c.__errno_location().*);
        for (launch.pipes) |pair| _ = c.close(pair[0]);
        if (launch.cwd) |cwd| if (c.chdir(cwd) != 0) fail(error_fd, c.__errno_location().*);
        var failure: c_int = c.ENOENT;
        for (launch.candidates) |candidate| {
            _ = c.execve(candidate, @ptrCast(launch.argv.ptr), @ptrCast(launch.env.ptr));
            const err = c.__errno_location().*;
            if (err == c.EACCES) failure = err else if (err != c.ENOENT and err != c.ENOTDIR) fail(error_fd, err);
        }
        fail(error_fd, failure);
    }
    _ = c.setpgid(leader, leader);
    for (launch.pipes) |pair| for (pair) |fd| {
        _ = c.close(fd);
    };
    _ = c.close(launch.null_fd);
    supervise(leader, signal_fd, children_fd);
}

fn supervise(leader: c.pid_t, signal_fd: c_int, children_fd: c_int) noreturn {
    var leader_reaped = false;
    var leader_code: c_int = 126;
    var closing = false;
    var kill_at: u64 = 0;
    while (true) {
        // Reap until drained, including escaped/double-forked children adopted
        // by this subreaper. ECHILD is the only successful teardown condition.
        while (true) {
            var status: c_int = 0;
            const pid = c.waitpid(-1, &status, c.WNOHANG);
            if (pid > 0) {
                if (pid == leader) {
                    leader_reaped = true;
                    leader_code = if (c.WIFEXITED(status)) c.WEXITSTATUS(status) else 128 + c.WTERMSIG(status);
                }
                continue;
            }
            if (pid < 0 and c.__errno_location().* == c.EINTR) continue;
            if (pid < 0 and c.__errno_location().* == c.ECHILD) c._exit(leader_code);
            break;
        }
        var force = false;
        var info: c.struct_signalfd_siginfo = undefined;
        while (c.read(signal_fd, &info, @sizeOf(@TypeOf(info))) > 0) {
            if (info.ssi_signo == c.SIGUSR2) force = true;
            if (info.ssi_signo == c.SIGTERM or info.ssi_signo == c.SIGINT or force) {
                if (!closing) {
                    closing = true;
                    kill_at = nowMs() + 1500;
                    if (!leader_reaped) _ = c.kill(-leader, c.SIGTERM);
                    // Also address the leader directly: a workload can move
                    // out of its original process group before cancellation.
                    signalChildren(children_fd, c.SIGTERM, -1);
                }
            }
        }
        if (leader_reaped and !closing) {
            closing = true;
            kill_at = nowMs() + 1500;
            signalChildren(children_fd, c.SIGTERM, -1);
        }
        if (force) kill_at = 0;
        if (closing and nowMs() >= kill_at) {
            // Do not signal a PGID after reaping its leader: that numeric ID
            // could have been reused. Adopted children remain PID-pinned until
            // this supervisor reaps them, so individual signals are safe.
            if (!leader_reaped) _ = c.kill(-leader, c.SIGKILL);
            signalChildren(children_fd, c.SIGKILL, -1);
        }
        var pollfd = c.struct_pollfd{ .fd = signal_fd, .events = c.POLLIN, .revents = 0 };
        _ = c.poll(&pollfd, 1, 20);
    }
}

fn signalChildren(fd: c_int, signal: c_int, skip: c.pid_t) void {
    // A bounded prefix is sufficient: kill/reap frees that prefix and the next
    // iteration observes remaining descendants. Never parse a truncated PID.
    var bytes: [65536]u8 = undefined;
    if (c.lseek(fd, 0, c.SEEK_SET) < 0) return;
    const result = c.read(fd, &bytes, bytes.len);
    if (result <= 0) return;
    const count: usize = @intCast(result);
    var pid: u32 = 0;
    for (bytes[0..count]) |byte| {
        if (byte == ' ') {
            if (pid > 0 and pid <= std.math.maxInt(c.pid_t) and @as(c.pid_t, @intCast(pid)) != skip)
                _ = c.kill(@intCast(pid), signal);
            pid = 0;
        } else if (byte >= '0' and byte <= '9') {
            pid = std.math.mul(u32, pid, 10) catch return;
            pid = std.math.add(u32, pid, byte - '0') catch return;
        } else return;
    }
}

fn nowMs() u64 {
    var time: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &time);
    return @as(u64, @intCast(time.sec)) * 1000 + @as(u64, @intCast(time.nsec)) / 1000000;
}

fn fail(fd: c_int, errno_value: c_int) noreturn {
    _ = c.write(fd, &errno_value, @sizeOf(c_int));
    c._exit(126);
}
