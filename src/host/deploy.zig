//! Installs `hollow-agent` on a host reached through a connector command
//! (wsl.exe, ssh, docker/podman exec, ...). Blocking; run it off the UI thread.
//!
//! 1. probe: `uname -m`, and whether the cached agent exists with the
//!    bundled digest;
//! 2. upload when missing: stream the bundled binary over the connector's
//!    stdin, check it with `sha256sum`, rename it into place;
//! 3. return the agent's path on the host.
//!
//! Verified installs are remembered for the process, so later connections
//! skip straight to step 3.
const std = @import("std");
const builtin = @import("builtin");
const posix = if (builtin.os.tag == .windows) struct {} else @import("posix_c");

const gpa = std.heap.smp_allocator;

pub const Arch = enum { x86_64, aarch64 };

pub const Artifact = struct {
    /// Client-native path of the Linux agent binary.
    path: []const u8,
    /// Lowercase hex SHA-256 of the binary.
    sha256: []const u8,
};

/// Runs commands on a host: the remote argv is appended to `argv`.
pub const Connector = struct {
    /// Empty runs commands locally.
    argv: []const []const u8 = &.{},
    /// The connector hands its arguments to a remote shell (ssh): append one
    /// `exec 'arg' ...` word instead of raw argv.
    remote_shell: bool = false,

    pub fn command(self: Connector, a: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
        var argv: std.ArrayList([]const u8) = try .initCapacity(a, self.argv.len + args.len);
        argv.appendSliceAssumeCapacity(self.argv);
        if (!self.remote_shell) {
            argv.appendSliceAssumeCapacity(args);
            return argv.items;
        }
        var line: std.ArrayList(u8) = .empty;
        try line.appendSlice(a, "exec");
        for (args) |arg| {
            try line.appendSlice(a, " '");
            for (arg) |ch| if (ch == '\'') try line.appendSlice(a, "'\"'\"'") else try line.append(a, ch);
            try line.append(a, '\'');
        }
        argv.appendAssumeCapacity(line.items);
        return argv.items;
    }

    pub fn dupe(self: Connector, a: std.mem.Allocator) !Connector {
        const argv = try a.alloc([]const u8, self.argv.len);
        for (self.argv, argv) |arg, *slot| {
            if (arg.len == 0 or std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidArgument;
            slot.* = try a.dupe(u8, arg);
        }
        return .{ .argv = argv, .remote_shell = self.remote_shell };
    }
};

/// Where the agent comes from.
pub const Agent = struct {
    /// Preinstalled on the host; skips the deploy.
    path: ?[]const u8 = null,
    /// Bundle directory with `SHA256SUMS` and `linux-<arch>/hollow-agent`.
    /// Defaults to the release's `agents/` beside the executable.
    dir: ?[]const u8 = null,
    /// Explicit binaries; override the bundle.
    artifacts: std.EnumArray(Arch, ?Artifact) = .initFill(null),
    timeout_ms: u32 = 60_000,

    pub fn dupe(self: Agent, a: std.mem.Allocator) !Agent {
        var copy = self;
        if (self.path) |path| copy.path = try a.dupe(u8, path);
        if (self.dir) |dir| copy.dir = try a.dupe(u8, dir);
        for (std.enums.values(Arch)) |arch| if (self.artifacts.get(arch)) |artifact| {
            copy.artifacts.set(arch, .{ .path = try a.dupe(u8, artifact.path), .sha256 = try a.dupe(u8, artifact.sha256) });
        };
        return copy;
    }
};

/// Lets another thread abort a deploy: kills the running step.
pub const Control = struct {
    mutex: std.Io.Mutex = .init,
    child: ?std.process.Child.Id = null,
    cancelled: bool = false,
    step_done: bool = false,
    timed_out: bool = false,

    pub fn cancel(self: *Control, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.cancelled = true;
        if (self.child) |child| terminate(child);
    }

    pub fn isCancelled(self: *Control, io: std.Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.cancelled;
    }
};

/// Why a deploy failed with `error.DeployFailed`.
pub const Failure = struct {
    code: Code = .agent_install_unavailable,
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub const Code = enum { agent_install_unavailable, connector_unavailable, unsupported_arch, checksum_mismatch, timeout };

    pub fn set(self: *Failure, comptime fmt: []const u8, args: anytype) error{DeployFailed} {
        return self.setCode(.agent_install_unavailable, fmt, args);
    }

    pub fn setCode(self: *Failure, code: Code, comptime fmt: []const u8, args: anytype) error{DeployFailed} {
        self.code = code;
        _ = self.print(fmt, args);
        return error.DeployFailed;
    }

    pub fn print(self: *Failure, comptime fmt: []const u8, args: anytype) []const u8 {
        var writer: std.Io.Writer = .fixed(&self.buf);
        writer.print(fmt, args) catch {};
        self.len = writer.end;
        return self.text();
    }

    pub fn text(self: *const Failure) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Install = struct {
    /// Agent path on the host.
    path: []const u8,
    /// Came from the in-memory cache without touching the host. If the agent
    /// then fails to start, `forget(cache_key)` and deploy again.
    cached: bool = false,
    cache_key: ?[]const u8 = null,
};

pub const Options = struct {
    use_cache: bool = true,
};

/// Ensures the agent is installed on the host. Allocations go to `a`
/// (typically an arena). Fails with `error.DeployFailed` and a `failure`
/// message, or with `error.DeployCancelled`.
pub fn install(io: std.Io, a: std.mem.Allocator, control: *Control, connector: Connector, agent: Agent, failure: *Failure, options: Options) !Install {
    if (agent.path) |path| return .{ .path = path };
    const deadline = now(io) + @as(i128, agent.timeout_ms) * std.time.ns_per_ms;
    const artifacts = try bundledArtifacts(io, a, agent, failure);
    const key = try cacheKey(a, connector, artifacts);
    if (options.use_cache) if (cached(a, key)) |path| return .{ .path = path, .cached = true, .cache_key = key };

    var deployer: Deployer = .{ .io = io, .a = a, .control = control, .failure = failure, .deadline = deadline };
    const probe = try deployer.run(.probe, try connector.command(a, &.{ "/bin/sh", "-c", probe_script, "hollow-deploy", digestOrDash(artifacts, .x86_64), digestOrDash(artifacts, .aarch64) }), "");
    const report = try parseProbe(probe, failure);
    if (!report.installed) {
        const artifact = artifacts.get(report.arch) orelse
            return failure.set("no bundled agent for linux-{s}; configure artifacts or agent_path", .{@tagName(report.arch)});
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, artifact.path, gpa, .limited(artifact_limit)) catch |err|
            return failure.set("cannot read agent {s}: {s}", .{ artifact.path, @errorName(err) });
        defer gpa.free(bytes);
        _ = try deployer.run(.install, try connector.command(a, &.{ "/bin/sh", "-c", install_script, "hollow-deploy", report.path, artifact.sha256 }), bytes);
    }
    remember(key, report.path);
    return .{ .path = report.path, .cache_key = key };
}

// `$1`/`$2`: x86_64/aarch64 digests. Prints "<ok|missing> <arch> <path>".
const probe_script =
    \\set -eu; case "$(uname -m)" in x86_64|amd64) arch=x86_64 sum=$1 ;; aarch64|arm64) arch=aarch64 sum=$2 ;;
    \\ *) echo "unsupported host architecture: $(uname -m)" >&2; exit 3 ;; esac;
    \\ case "${HOME:-}" in /*) ;; *) echo "host user has no absolute HOME; configure agent_path" >&2; exit 4 ;; esac;
    \\ target="$HOME/.cache/hollow/agents/linux-$arch/$sum/hollow-agent"; state=missing;
    \\ if [ ! -L "$target" ] && [ -x "$target" ]; then got=$(sha256sum < "$target") && [ "${got%% *}" = "$sum" ] && state=ok; fi;
    \\ printf '%s %s %s\n' "$state" "$arch" "$target"
;
// Reads the agent from stdin into `$1`, verifying SHA-256 `$2`.
const install_script =
    \\set -eu; dir=${1%/*}; mkdir -p -- "$dir"; tmp=$(mktemp "$dir/.upload-XXXXXXXXXXXX");
    \\ trap 'rm -f -- "$tmp"' EXIT; cat > "$tmp"; got=$(sha256sum < "$tmp");
    \\ [ "${got%% *}" = "$2" ] || { echo "agent checksum mismatch after upload" >&2; exit 43; };
    \\ chmod 700 -- "$tmp"; mv -f -- "$tmp" "$1"; trap - EXIT
;
const output_limit = 16 * 1024;
const artifact_limit = 256 * 1024 * 1024;

const Probe = struct { installed: bool, arch: Arch, path: []const u8 };

fn parseProbe(output: []const u8, failure: *Failure) !Probe {
    const line = std.mem.trimEnd(u8, output, "\r\n");
    var fields = std.mem.splitScalar(u8, line, ' ');
    const state = fields.next() orelse "";
    const arch = std.meta.stringToEnum(Arch, fields.next() orelse "");
    const path = fields.rest();
    const installed = std.mem.eql(u8, state, "ok");
    if (arch == null or path.len == 0 or path[0] != '/' or !(installed or std.mem.eql(u8, state, "missing")))
        return failure.set("unexpected host probe output: {s}", .{line[0..@min(line.len, 200)]});
    return .{ .installed = installed, .arch = arch.?, .path = path };
}

fn digestOrDash(artifacts: std.EnumArray(Arch, ?Artifact), arch: Arch) []const u8 {
    return if (artifacts.get(arch)) |artifact| artifact.sha256 else "-";
}

/// Runs deploy steps through the connector, one process at a time.
const Deployer = struct {
    io: std.Io,
    a: std.mem.Allocator,
    control: *Control,
    failure: *Failure,
    deadline: i128,

    /// Runs `argv` to completion, feeding it `input`; returns its stdout.
    fn run(self: *Deployer, step: enum { probe, install }, argv: []const []const u8, input: []const u8) ![]const u8 {
        const io = self.io;
        const failure = self.failure;
        if (now(io) >= self.deadline) return failure.setCode(.timeout, "host agent deploy timed out", .{});
        var child = std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe, .create_no_window = true }) catch |err|
            return failure.setCode(.connector_unavailable, "cannot run {s}: {s}", .{ argv[0], @errorName(err) });
        if (!self.track(child.id.?)) {
            child.kill(io);
            return error.DeployCancelled;
        }
        const watchdog = std.Thread.spawn(.{}, watch, .{ self.control, io, self.deadline }) catch |err| {
            _ = self.untrack(null);
            child.kill(io);
            return err;
        };
        var output: Output = .{};
        const collected = output.collect(self.a, io, &child, input);
        // Pipe EOF is not process exit. Keep cancellation/deadline tracking
        // alive until exit is observed, but clear it before wait() reaps the PID.
        const exited = if (!std.meta.isError(collected)) awaitExit(io, child.id.?) else {};
        // Nobody drains its pipes any more; `wait` would hang on a blocked child.
        const outcome = self.untrack(if (std.meta.isError(collected) or std.meta.isError(exited)) child.id.? else null);
        watchdog.join();
        const term = child.wait(io) catch |err| {
            child.kill(io);
            return failure.setCode(.connector_unavailable, "{s}: {s}", .{ argv[0], @errorName(err) });
        };
        if (outcome.cancelled) return error.DeployCancelled;
        if (outcome.timed_out) return failure.setCode(.timeout, "host agent deploy timed out", .{});
        exited catch |err| return failure.setCode(.connector_unavailable, "{s}: {s}", .{ argv[0], @errorName(err) });
        collected catch |err| return switch (err) {
            error.StreamTooLong => failure.setCode(.connector_unavailable, "{s} printed too much output (shell startup files?)", .{argv[0]}),
            else => failure.setCode(.connector_unavailable, "{s}: {s}", .{ argv[0], @errorName(err) }),
        };

        const code: ?u8 = switch (term) {
            .exited => |value| value,
            else => null,
        };
        if (code == 0) return output.stdout;
        // Exit codes the scripts use to say why; any other probe failure
        // means the connector could not reach the host.
        const kind: Failure.Code = switch (step) {
            .probe => if (code == 3) .unsupported_arch else if (code == 4) .agent_install_unavailable else .connector_unavailable,
            .install => if (code == 43) .checksum_mismatch else .agent_install_unavailable,
        };
        const reason = lastLine(output.stderr);
        if (reason.len > 0) return failure.setCode(kind, "{s}", .{reason});
        if (code) |value| return failure.setCode(kind, "{s} exited with status {d}", .{ argv[0], value });
        return failure.setCode(kind, "{s} was terminated", .{argv[0]});
    }

    fn track(self: *Deployer, child: std.process.Child.Id) bool {
        const control = self.control;
        control.mutex.lockUncancelable(self.io);
        defer control.mutex.unlock(self.io);
        if (control.cancelled) return false;
        control.child = child;
        control.step_done = false;
        control.timed_out = false;
        return true;
    }

    /// Stops tracking the step before it is reaped, so neither `cancel()` nor
    /// the watchdog can hit a recycled pid.
    fn untrack(self: *Deployer, kill: ?std.process.Child.Id) struct { cancelled: bool, timed_out: bool } {
        const control = self.control;
        control.mutex.lockUncancelable(self.io);
        defer control.mutex.unlock(self.io);
        if (kill) |child| terminate(child);
        control.child = null;
        control.step_done = true;
        return .{ .cancelled = control.cancelled, .timed_out = control.timed_out };
    }
};

fn watch(control: *Control, io: std.Io, deadline: i128) void {
    while (true) {
        {
            control.mutex.lockUncancelable(io);
            defer control.mutex.unlock(io);
            if (control.step_done or control.cancelled) return;
            if (now(io) >= deadline) {
                control.timed_out = true;
                if (control.child) |child| terminate(child);
                return;
            }
        }
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch return;
    }
}

const Output = struct {
    stdout: []const u8 = "",
    stderr: []const u8 = "",

    fn collect(self: *Output, a: std.mem.Allocator, io: std.Io, child: *std.process.Child, input: []const u8) !void {
        if (child.stdin) |stdin| {
            child.stdin = null;
            // A step that fails early stops reading; its status explains why.
            stdin.writeStreamingAll(io, input) catch {};
            stdin.close(io);
        }
        var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var streams: std.Io.File.MultiReader = undefined;
        streams.init(gpa, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer streams.deinit();
        while (streams.fill(64, .none)) |_| {
            if (streams.reader(0).buffered().len > output_limit or streams.reader(1).buffered().len > output_limit) return error.StreamTooLong;
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => |e| return e,
        }
        try streams.checkAnyError();
        self.stdout = try a.dupe(u8, streams.reader(0).buffered());
        self.stderr = try a.dupe(u8, streams.reader(1).buffered());
    }
};

fn lastLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |i| i + 1 else 0;
    const line = std.mem.trim(u8, trimmed[start..], " \t\r");
    return line[0..@min(line.len, 300)];
}

/// Configured `artifacts`, else `SHA256SUMS` in `dir` or in the release's
/// `agents/` beside the executable (`../agents` for a `bin/` layout).
fn bundledArtifacts(io: std.Io, a: std.mem.Allocator, agent: Agent, failure: *Failure) !std.EnumArray(Arch, ?Artifact) {
    for (std.enums.values(Arch)) |arch| if (agent.artifacts.get(arch) != null) return agent.artifacts;
    if (agent.dir) |dir| return (try readManifest(io, a, dir, failure)) orelse
        failure.set("no agent bundle in {s}", .{dir});
    const exe_dir = std.process.executableDirPathAlloc(io, a) catch
        return failure.set("cannot locate the executable; configure artifacts, agent_dir, or agent_path", .{});
    if (try readManifest(io, a, try joinPath(a, exe_dir, "agents"), failure)) |found| return found;
    const trimmed = std.mem.trimEnd(u8, exe_dir, "/\\");
    const leaf = if (std.mem.lastIndexOfAny(u8, trimmed, "/\\")) |i| trimmed[i + 1 ..] else trimmed;
    if (std.ascii.eqlIgnoreCase(leaf, "bin")) if (try readManifest(io, a, try joinPath(a, exe_dir, "../agents"), failure)) |found| return found;
    return failure.set("no agent bundle found beside the executable; configure artifacts, agent_dir, or agent_path", .{});
}

fn readManifest(io: std.Io, a: std.mem.Allocator, root: []const u8, failure: *Failure) !?std.EnumArray(Arch, ?Artifact) {
    const path = try joinPath(a, root, "SHA256SUMS");
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return failure.set("cannot read {s}: {s}", .{ path, @errorName(err) }),
    };
    var result: std.EnumArray(Arch, ?Artifact) = .initFill(null);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const record = parseRecord(line) orelse return failure.set("invalid record in {s}", .{path});
        if (result.get(record.arch) != null) return failure.set("duplicate record in {s}", .{path});
        const digest = try std.ascii.allocLowerString(a, record.digest);
        result.set(record.arch, .{ .path = try joinPath(a, root, record.file), .sha256 = digest });
    }
    for (std.enums.values(Arch)) |arch| if (result.get(arch) != null) return result;
    return failure.set("empty {s}", .{path});
}

/// `<sha256>  linux-<arch>/hollow-agent`
fn parseRecord(line: []const u8) ?struct { arch: Arch, digest: []const u8, file: []const u8 } {
    if (line.len < 67 or !std.mem.eql(u8, line[64..66], "  ")) return null;
    const digest = line[0..64];
    for (digest) |ch| if (!std.ascii.isHex(ch)) return null;
    const file = line[66..];
    inline for (comptime std.enums.values(Arch)) |arch| {
        if (std.mem.eql(u8, file, "linux-" ++ @tagName(arch) ++ "/hollow-agent")) return .{ .arch = arch, .digest = digest, .file = file };
    }
    return null;
}

fn joinPath(a: std.mem.Allocator, root: []const u8, suffix: []const u8) ![]const u8 {
    if (root.len > 0 and (root[root.len - 1] == '/' or root[root.len - 1] == '\\')) return std.mem.concat(a, u8, &.{ root, suffix });
    return std.mem.concat(a, u8, &.{ root, "/", suffix });
}

var cache_mutex: std.atomic.Mutex = .unlocked;
var cache: std.StringHashMapUnmanaged([]const u8) = .empty;

fn lockCache() void {
    while (!cache_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn cacheKey(a: std.mem.Allocator, connector: Connector, artifacts: std.EnumArray(Arch, ?Artifact)) ![]const u8 {
    var key: std.ArrayList(u8) = .empty;
    for (connector.argv) |arg| {
        try key.appendSlice(a, arg);
        try key.append(a, 0);
    }
    try key.append(a, if (connector.remote_shell) 1 else 2);
    for (std.enums.values(Arch)) |arch| try key.appendSlice(a, digestOrDash(artifacts, arch));
    return key.items;
}

fn cached(a: std.mem.Allocator, key: []const u8) ?[]const u8 {
    lockCache();
    defer cache_mutex.unlock();
    const path = cache.get(key) orelse return null;
    return a.dupe(u8, path) catch null;
}

fn remember(key: []const u8, path: []const u8) void {
    lockCache();
    defer cache_mutex.unlock();
    const owned_path = gpa.dupe(u8, path) catch return;
    const entry = cache.getOrPut(gpa, key) catch {
        gpa.free(owned_path);
        return;
    };
    if (entry.found_existing) {
        gpa.free(entry.value_ptr.*);
    } else {
        entry.key_ptr.* = gpa.dupe(u8, key) catch {
            cache.removeByPtr(entry.key_ptr);
            gpa.free(owned_path);
            return;
        };
    }
    entry.value_ptr.* = owned_path;
}

/// Drops a remembered install that turned out to be gone.
pub fn forget(key: []const u8) void {
    lockCache();
    defer cache_mutex.unlock();
    const removed = cache.fetchRemove(key) orelse return;
    gpa.free(removed.key);
    gpa.free(removed.value);
}

extern "kernel32" fn TerminateProcess(hProcess: std.os.windows.HANDLE, uExitCode: std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn WaitForSingleObject(hHandle: std.os.windows.HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;

/// Observe exit without releasing the PID/handle while a watchdog can signal it.
fn awaitExit(io: std.Io, child: std.process.Child.Id) !void {
    while (true) {
        if (builtin.os.tag == .windows) {
            switch (WaitForSingleObject(child, 0)) {
                0 => return,
                258 => {}, // WAIT_TIMEOUT
                else => return error.WaitFailed,
            }
        } else {
            var info = std.mem.zeroes(posix.siginfo_t);
            if (posix.waitid(posix.P_PID, @intCast(child), &info, posix.WEXITED | posix.WNOHANG | posix.WNOWAIT) == 0) {
                if (info.si_signo != 0) return;
            } else if (std.c._errno().* != posix.EINTR) return error.WaitFailed;
        }
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
}

pub fn terminate(child: std.process.Child.Id) void {
    if (builtin.os.tag == .windows) {
        _ = TerminateProcess(child, 1);
    } else {
        std.posix.kill(child, .KILL) catch {};
    }
}

fn now(io: std.Io) i128 {
    return std.Io.Clock.awake.now(io).toNanoseconds();
}

test "remote shell connectors quote every argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ssh: Connector = .{ .argv = &.{ "ssh", "box" }, .remote_shell = true };
    const argv = try ssh.command(arena.allocator(), &.{ "/a b", "it's" });
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("exec '/a b' 'it'\"'\"'s'", argv[2]);
    const wsl: Connector = .{ .argv = &.{ "wsl.exe", "--exec" } };
    try std.testing.expectEqualStrings("pty", (try wsl.command(arena.allocator(), &.{ "/agent", "pty" }))[3]);
}

test "bundle manifest records" {
    const digest = &@as([64:0]u8, @splat('A'));
    const record = parseRecord(digest ++ "  linux-aarch64/hollow-agent").?;
    try std.testing.expectEqual(Arch.aarch64, record.arch);
    try std.testing.expect(parseRecord(digest ++ "  linux-arm/hollow-agent") == null);
    try std.testing.expect(parseRecord(digest ++ " linux-x86_64/hollow-agent") == null);
    try std.testing.expect(parseRecord(&@as([64:0]u8, @splat('g')) ++ "  linux-x86_64/hollow-agent") == null);
}

test "probe output" {
    var failure: Failure = .{};
    const probe = try parseProbe("missing x86_64 /home/me two/.cache/hollow-agent\n", &failure);
    try std.testing.expect(!probe.installed);
    try std.testing.expectEqualStrings("/home/me two/.cache/hollow-agent", probe.path);
    try std.testing.expectError(error.DeployFailed, parseProbe("Welcome!\n", &failure));
}

test "deploy deadline remains active after stdout and stderr EOF" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var control: Control = .{};
    var failure: Failure = .{};
    var agent: Agent = .{ .timeout_ms = 100 };
    agent.artifacts.set(.x86_64, .{ .path = "/unused", .sha256 = &@as([64:0]u8, @splat('a')) });
    const started = now(std.testing.io);
    try std.testing.expectError(error.DeployFailed, install(std.testing.io, arena.allocator(), &control, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'ok x86_64 /unused\\n'; exec 1>&- 2>&-; exec sleep 30" },
    }, agent, &failure, .{ .use_cache = false }));
    try std.testing.expectEqual(Failure.Code.timeout, failure.code);
    try std.testing.expect(now(std.testing.io) - started < 3 * std.time.ns_per_s);
}

test "deploy cancellation remains active after pipe EOF" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var control: Control = .{};
    var failure: Failure = .{};
    var agent: Agent = .{};
    agent.artifacts.set(.x86_64, .{ .path = "/unused", .sha256 = &@as([64:0]u8, @splat('a')) });
    const Cancel = struct {
        fn run(value: *Control) void {
            std.Io.sleep(std.testing.io, .fromMilliseconds(150), .awake) catch return;
            value.cancel(std.testing.io);
        }
    };
    const thread = try std.Thread.spawn(.{}, Cancel.run, .{&control});
    defer thread.join();
    const started = now(std.testing.io);
    try std.testing.expectError(error.DeployCancelled, install(std.testing.io, arena.allocator(), &control, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'ok x86_64 /unused\\n'; exec 1>&- 2>&-; exec sleep 30" },
    }, agent, &failure, .{ .use_cache = false }));
    try std.testing.expect(now(std.testing.io) - started < 3 * std.time.ns_per_s);
}

test "exit observation leaves child status available for the owner" {
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/d", "/c", "exit /b 7" }
    else
        &.{ "/bin/sh", "-c", "exit 7" };
    var child = try std.process.spawn(std.testing.io, .{ .argv = argv, .create_no_window = true });
    defer child.kill(std.testing.io);
    try awaitExit(std.testing.io, child.id.?);
    const term = try child.wait(std.testing.io);
    try std.testing.expectEqual(@as(u8, 7), term.exited);
}
