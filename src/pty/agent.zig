//! Pane PTY served by `hollow-agent pty` behind a connector process (wsl.exe,
//! ssh, docker/podman exec, ...). Lua only describes the connector; the
//! worker thread installs the agent (`host/deploy.zig`) and then runs it.
//! Until the agent says hello, input and resizes are buffered. Dedicated mode
//! owns one connector per pane. Explicit mux hosts delegate connection ownership
//! to agent_mux.zig, retaining the same pane API and pre-spawn fallback rules.
const std = @import("std");
const io = @import("../io.zig");
const deploy = @import("../host/deploy.zig");
const wire = @import("../agent/pty_protocol.zig");
const LaunchCommand = @import("launch_command.zig").LaunchCommand;
const Wake = @import("wake.zig").Wake;
const mux = @import("agent_mux.zig");

pub const PathStyle = wire.PathStyle;

const output_high_water = 4 * 1024 * 1024;
const input_high_water = 4 * 1024 * 1024;
const input_chunk = 64 * 1024;
const shutdown_grace_ns = 3 * std.time.ns_per_s;
/// Exit status reported when the agent never delivered one.
pub const failure_status = 125;

const gpa = std.heap.smp_allocator;

const Phase = enum { bootstrapping, running, ended };

/// How to reach the agent on a host; built by Lua (`hollow.host.pty`).
pub const Host = struct {
    pub const Multiplex = struct { read_workers: u8 = 4, batch_jobs: u8 = 2 };
    multiplex: ?Multiplex = null,
    connector: deploy.Connector = .{},
    agent: deploy.Agent = .{},
    path_style: PathStyle = .posix,
    /// Implicit hosts (WSL inferred from the shell) fall back to native;
    /// explicitly configured hosts report failures in the pane.
    fallback: bool = false,
    /// Lua could not describe the host; reported in the pane.
    error_message: ?[]const u8 = null,

    pub fn dupe(self: Host, a: std.mem.Allocator) !Host {
        var copy = self;
        copy.connector = try self.connector.dupe(a);
        copy.agent = try self.agent.dupe(a);
        if (self.error_message) |text| copy.error_message = try a.dupe(u8, text[0..@min(text.len, 256)]);
        return copy;
    }
};

/// Shared between the pane (owner), the worker thread and the reader thread.
/// Freed by whichever drops the last reference.
pub const Session = struct {
    mux_connection: ?*mux.Connection = null,
    mux_state: mux.Stream = .{},
    arena: std.heap.ArenaAllocator,
    wake: Wake,
    mutex: io.Mutex = .{},
    changed: io.Condition = .{},
    refs: u8 = 2,

    // Spawn request; cols/rows track the latest resize.
    cols: u16,
    rows: u16,
    cwd: ?[]const u8,
    env: []const wire.EnvVar,
    shell_argv: []const []const u8,
    command: ?[]const u8,
    close_on_exit: bool,
    one_shot: bool = false,
    user_shell: bool = false,
    shell_integration: bool = true,
    fallback_allowed: bool,
    host: Host,

    phase: Phase = .bootstrapping,
    deploy: deploy.Control = .{},
    child_id: ?std.process.Child.Id = null,
    writing: bool = false,
    closing: bool = false,

    output: std.ArrayList(u8) = .empty,
    output_start: usize = 0,
    reader_compacted_bytes: u64 = 0,
    consumer_compacted_bytes: u64 = 0,
    empty_reads: u64 = 0,
    hello: bool = false,
    spawn_submitted: bool = false,
    reader_done: bool = false,
    exit_status: ?u32 = null,
    /// Set when the host could not be reached before anything ran and the
    /// owner may transparently fall back to a native PTY.
    fallback: bool = false,

    input: std.ArrayList(u8) = .empty,
    input_start: usize = 0,
    resize_pending: bool = false,

    pub fn unref(self: *Session) void {
        self.mutex.lock();
        self.refs -= 1;
        const last = self.refs == 0;
        self.mutex.unlock();
        if (!last) return;
        self.output.deinit(gpa);
        self.input.deinit(gpa);
        if (self.mux_connection) |connection| connection.unref();
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn isClosing(self: *Session) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.closing;
    }

    pub fn pendingOutputLocked(self: *const Session) usize {
        return self.output.items.len - self.output_start;
    }

    /// Ends the session before or after start. Caller holds the mutex.
    pub fn endLocked(self: *Session, message: ?[]const u8) void {
        if (self.phase == .ended) return;
        const started = self.spawn_submitted or self.mux_state.submitted;
        self.phase = .ended;
        if (!started and self.fallback_allowed and !self.closing) {
            self.fallback = true;
            if (message) |text| std.log.info("agent pty: host unavailable ({s}); using native PTY", .{text});
        } else if (message) |text| {
            std.log.warn("agent pty: {s}", .{text});
            if (!self.closing) {
                var buf: [512]u8 = undefined;
                const banner = std.fmt.bufPrint(&buf, "\r\n\x1b[31m[hollow] {s}\x1b[0m\r\n", .{text}) catch "\r\n[hollow] host agent failed\r\n";
                self.output.appendSlice(gpa, banner) catch {};
            }
        }
        if (self.exit_status == null) self.exit_status = failure_status;
        self.changed.broadcast();
    }
};

pub const Request = struct {
    /// Native launch used when an implicit host turns out to be unavailable.
    shell: [:0]const u8,
    cols: u16,
    rows: u16,
    cwd: ?[]const u8,
    /// cwd for the native fallback launch (defaults to `cwd`).
    native_cwd: ?[]const u8 = null,
    env_block: ?[]const u8,
    launch_command: ?LaunchCommand,
    host: Host,
};

/// Native spawn parameters retained for fallback.
pub const Fallback = struct {
    shell: [:0]const u8,
    cwd: ?[]const u8,
    env_block: ?[]const u8,
    launch_command: ?LaunchCommand,
};

pub const AgentPty = struct {
    allocator: std.mem.Allocator,
    session: *Session,
    worker: ?std.Thread = null,
    fallback_spec: Fallback,
    started: bool = false,
    closed: bool = false,

    /// Buffers input until `start()` bootstraps and runs the agent.
    pub fn init(allocator: std.mem.Allocator, request: Request, wake: Wake) !AgentPty {
        const session = try gpa.create(Session);
        session.* = .{
            .arena = .init(gpa),
            .wake = wake,
            .cols = request.cols,
            .rows = request.rows,
            .cwd = null,
            .env = &.{},
            .shell_argv = &.{},
            .command = null,
            .close_on_exit = false,
            .fallback_allowed = request.host.fallback,
            .host = undefined,
        };
        var owned_session = true;
        errdefer if (owned_session) {
            session.arena.deinit();
            gpa.destroy(session);
        };
        const a = session.arena.allocator();
        session.host = try request.host.dupe(a);
        if (request.cwd) |cwd| session.cwd = try a.dupe(u8, cwd);
        if (request.env_block) |block| session.env = try parseEnvBlock(a, block);
        session.shell_argv = try wslInnerArgv(a, request.shell);
        if (request.launch_command) |cmd| {
            if (cmd.user_shell) {
                session.command = try cmd.userShellCommand(a, false);
                session.user_shell = true;
            } else if (cmd.argv) |args| {
                const owned = try a.alloc([]const u8, args.len);
                for (args, 0..) |arg, i| owned[i] = try a.dupe(u8, arg);
                session.shell_argv = owned;
                session.shell_integration = false;
            } else session.command = try a.dupe(u8, cmd.command);
            session.one_shot = cmd.one_shot;
            if (cmd.one_shot or cmd.argv != null) session.fallback_allowed = false;
            session.close_on_exit = cmd.close_on_exit;
        }

        var fallback_spec: Fallback = .{
            .shell = try allocator.dupeZ(u8, request.shell),
            .cwd = null,
            .env_block = null,
            .launch_command = null,
        };
        errdefer freeFallback(allocator, &fallback_spec);
        if (request.native_cwd orelse request.cwd) |cwd| fallback_spec.cwd = try allocator.dupe(u8, cwd);
        if (request.env_block) |block| fallback_spec.env_block = try allocator.dupe(u8, block);
        if (request.launch_command) |cmd| fallback_spec.launch_command = try cmd.clone(allocator);

        owned_session = false;
        return .{ .allocator = allocator, .session = session, .fallback_spec = fallback_spec };
    }

    pub fn fallbackAllowed(self: *AgentPty) bool {
        self.session.mutex.lock();
        defer self.session.mutex.unlock();
        return self.session.fallback_allowed;
    }

    /// Bootstraps and runs the agent in the background.
    pub fn start(self: *AgentPty) !void {
        std.debug.assert(!self.started and self.worker == null and !self.closed);
        if (self.session.host.multiplex != null and self.session.host.error_message == null) {
            try mux.attach(self.session);
        } else self.worker = try std.Thread.spawn(.{}, workerMain, .{self.session});
        self.started = true;
    }

    /// True once the host proved unavailable and the owner should replace
    /// this PTY with a native one launched from `fallback_spec`.
    pub fn wantsFallback(self: *AgentPty) bool {
        if (self.closed) return false;
        self.session.mutex.lock();
        defer self.session.mutex.unlock();
        return self.session.fallback;
    }

    pub fn wakeHandle(self: *const AgentPty) Wake {
        return self.session.wake;
    }

    /// The native fallback failed too; report the session as ended.
    pub fn abandonFallback(self: *AgentPty) void {
        self.session.mutex.lock();
        defer self.session.mutex.unlock();
        self.session.fallback = false;
    }

    /// Input queued before the fallback decision, for replay on the native PTY.
    pub fn takeQueuedInput(self: *AgentPty, allocator: std.mem.Allocator) ![]u8 {
        const s = self.session;
        s.mutex.lock();
        defer s.mutex.unlock();
        const bytes = try allocator.dupe(u8, s.input.items[s.input_start..]);
        s.input.clearRetainingCapacity();
        s.input_start = 0;
        return bytes;
    }

    pub fn size(self: *AgentPty) struct { cols: u16, rows: u16 } {
        self.session.mutex.lock();
        defer self.session.mutex.unlock();
        return .{ .cols = self.session.cols, .rows = self.session.rows };
    }

    pub fn read(self: *AgentPty, buffer: []u8) !usize {
        if (self.closed or buffer.len == 0) return 0;
        const s = self.session;
        var signal_mux = false;
        defer if (signal_mux) mux.notify(s);
        s.mutex.lock();
        defer s.mutex.unlock();
        const pending = s.pendingOutputLocked();
        const count = @min(buffer.len, pending);
        if (count == 0) {
            s.empty_reads += 1;
            return 0;
        }
        @memcpy(buffer[0..count], s.output.items[s.output_start..][0..count]);
        s.output_start += count;
        if (s.mux_connection != null) {
            signal_mux = !s.mux_state.reservation_released;
            s.mux_state.consumed(count);
        }
        if (s.output_start == s.output.items.len) {
            s.output.clearRetainingCapacity();
            s.output_start = 0;
        } else if (s.output_start >= 65536 and s.output_start * 2 >= s.output.items.len) {
            const rest = s.output.items.len - s.output_start;
            std.mem.copyForwards(u8, s.output.items[0..rest], s.output.items[s.output_start..]);
            s.consumer_compacted_bytes += rest;
            s.output.items.len = rest;
            s.output_start = 0;
        }
        s.changed.broadcast();
        return count;
    }

    pub fn isAlive(self: *AgentPty) bool {
        if (self.closed) return false;
        const s = self.session;
        s.mutex.lock();
        defer s.mutex.unlock();
        return s.fallback or s.phase != .ended or s.pendingOutputLocked() > 0;
    }

    pub fn exitStatus(self: *const AgentPty) ?u32 {
        if (self.closed) return null;
        const s = self.session;
        s.mutex.lock();
        defer s.mutex.unlock();
        return if (s.phase == .ended) s.exit_status else null;
    }

    pub fn pendingOutputBytes(self: *AgentPty) usize {
        if (self.closed) return 0;
        self.session.mutex.lock();
        defer self.session.mutex.unlock();
        return self.session.pendingOutputLocked();
    }

    pub fn hasPendingOutput(self: *AgentPty) bool {
        return self.pendingOutputBytes() > 0;
    }

    pub fn hasPendingOutputOrExit(self: *AgentPty) bool {
        if (self.closed) return true;
        const s = self.session;
        s.mutex.lock();
        defer s.mutex.unlock();
        return s.phase == .ended or s.pendingOutputLocked() > 0;
    }

    /// All-or-nothing admission, like the native backends.
    pub fn writeAll(self: *AgentPty, bytes: []const u8) !void {
        if (self.closed) return error.WriteFailed;
        const s = self.session;
        defer mux.notify(s);
        s.mutex.lock();
        defer s.mutex.unlock();
        if (s.closing or (s.phase == .ended and !s.fallback)) return error.WriteFailed;
        const pending = s.input.items.len - s.input_start;
        if (bytes.len > input_high_water - pending) return error.InputQueueFull;
        if (s.input_start > 0 and s.input.capacity - s.input.items.len < bytes.len) {
            std.mem.copyForwards(u8, s.input.items[0..pending], s.input.items[s.input_start..]);
            s.input.items.len = pending;
            s.input_start = 0;
        }
        try s.input.appendSlice(gpa, bytes);
        s.changed.broadcast();
    }

    pub fn writeAllUntil(self: *AgentPty, bytes: []const u8, deadline_ns: i128) !usize {
        if (io.nanoTimestamp() >= deadline_ns) return 0;
        self.writeAll(bytes) catch |err| {
            if (err == error.InputQueueFull) return 0;
            return err;
        };
        return bytes.len;
    }

    pub fn resize(self: *AgentPty, cols: u16, rows: u16) void {
        if (self.closed or cols == 0 or rows == 0) return;
        const s = self.session;
        defer mux.notify(s);
        s.mutex.lock();
        defer s.mutex.unlock();
        s.cols = cols;
        s.rows = rows;
        if (s.phase == .running) {
            s.resize_pending = true;
            s.changed.broadcast();
        }
    }

    /// Remote processes have no local PID.
    pub fn childPid(_: *const AgentPty) usize {
        return 0;
    }

    pub fn setFocused(self: *AgentPty, focused: bool) void {
        if (self.closed or self.session.mux_connection == null) return;
        const s = self.session;
        s.mutex.lock();
        const changed = s.mux_state.focused != focused;
        if (changed) {
            s.mux_state.focused = focused;
            s.mux_state.focus_pending = focused;
        }
        s.mutex.unlock();
        if (changed) mux.notify(s);
    }

    /// Non-blocking: the worker finishes a graceful shutdown (close frame,
    /// bounded wait, then kill) in the background and frees the session.
    pub fn close(self: *AgentPty) void {
        if (self.closed) return;
        self.closed = true;
        const s = self.session;
        s.mutex.lock();
        s.closing = true;
        if (s.mux_connection != null) s.wake = .{};
        // A deploy or a write blocked on a stalled host cannot observe
        // `closing`.
        if (s.phase == .bootstrapping) s.deploy.cancel(io.get());
        if (s.writing) if (s.child_id) |child| deploy.terminate(child);
        s.changed.broadcast();
        s.mutex.unlock();
        mux.notifyClose(s);
        if (self.worker) |thread| thread.detach();
        self.worker = null;
        // The worker's reference was never handed out.
        if (!self.started) s.unref();
        s.unref();
        freeFallback(self.allocator, &self.fallback_spec);
    }

    /// Test helper: close and wait until the background shutdown completes.
    pub fn closeAndJoin(self: *AgentPty) void {
        if (self.closed) return;
        if (self.session.mux_connection != null) {
            const s = self.session;
            s.mutex.lock();
            s.refs += 1;
            s.mutex.unlock();
            self.close();
            s.mutex.lock();
            while (!s.reader_done) s.changed.wait(&s.mutex);
            s.mutex.unlock();
            mux.joinIdle(s.mux_connection.?);
            s.unref();
            return;
        }
        const worker = self.worker;
        self.worker = null;
        self.close();
        if (worker) |thread| thread.join();
    }

    pub fn deinit(self: *AgentPty) void {
        self.close();
    }
};

fn freeFallback(allocator: std.mem.Allocator, spec: *Fallback) void {
    allocator.free(spec.shell);
    if (spec.cwd) |cwd| allocator.free(cwd);
    if (spec.env_block) |block| allocator.free(block);
    if (spec.launch_command) |cmd| cmd.deinit(allocator);
    spec.* = .{ .shell = "", .cwd = null, .env_block = null, .launch_command = null };
}

const terminate = deploy.terminate;

fn workerMain(s: *Session) void {
    defer s.unref();
    var failure: deploy.Failure = .{};
    const message = serve(s, &failure) catch |err| switch (err) {
        error.DeployFailed => failure.text(),
        error.DeployCancelled => null,
        else => failure.print("host agent failed: {s}", .{@errorName(err)}),
    };
    s.mutex.lock();
    s.endLocked(message);
    s.mutex.unlock();
    s.wake.signal();
}

/// Returns the message that ends the session, or null after a clean exit.
fn serve(s: *Session, failure: *deploy.Failure) !?[]const u8 {
    if (s.host.error_message) |text| return text;
    const a = s.arena.allocator();
    var options: deploy.Options = .{};
    while (true) {
        const install = try deploy.install(io.get(), a, &s.deploy, s.host.connector, s.host.agent, failure, options);
        if (s.isClosing()) return null;
        if (try run(s, try s.host.connector.command(a, &.{ install.path, "pty" }))) {
            s.mutex.lock();
            defer s.mutex.unlock();
            return if (s.exit_status == null) "host agent connection lost" else null;
        }
        if (install.cache_key) |key| deploy.forget(key);
        // A cached install can vanish (container recreated, cache wiped);
        // nothing was sent yet, so bootstrap once more.
        if (!install.cached) return "host agent did not start (connector exited)";
        options.use_cache = false;
        // Same lock as the check, so `close()` sees `.bootstrapping` and
        // cancels the redeploy.
        s.mutex.lock();
        defer s.mutex.unlock();
        if (s.closing) return null;
        s.phase = .bootstrapping;
    }
}

/// Kills a connector that neither starts the agent nor exits in time.
fn helloWatchdog(s: *Session, deadline: i128) void {
    s.mutex.lock();
    defer s.mutex.unlock();
    while (!s.hello and !s.reader_done and !s.closing) {
        const now = io.nanoTimestamp();
        if (now >= deadline) {
            std.log.warn("agent pty: host agent did not start within {d} ms", .{s.host.agent.timeout_ms});
            if (s.child_id) |child| terminate(child);
            return;
        }
        io.waitTimeout(&s.changed.inner, &s.mutex.inner, @intCast(deadline - now)) catch {};
    }
}

/// Runs the agent through `argv` until it exits. Returns false when it never
/// said hello; nothing but the spawn request was sent then.
fn run(s: *Session, argv: []const []const u8) !bool {
    const runtime = io.get();
    var child = try std.process.spawn(runtime, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore, .create_no_window = true });
    s.mutex.lock();
    s.child_id = child.id;
    s.phase = .running;
    s.hello = false;
    s.reader_done = false;
    s.exit_status = null;
    s.mutex.unlock();

    var reader = runtime.concurrent(readerMain, .{ s, child.stdout.? }) catch |err| {
        s.mutex.lock();
        s.child_id = null;
        s.mutex.unlock();
        child.kill(runtime);
        return err;
    };
    const hello_deadline = io.nanoTimestamp() + @as(i128, s.host.agent.timeout_ms) * std.time.ns_per_ms;
    const watchdog = std.Thread.spawn(.{}, helloWatchdog, .{ s, hello_deadline }) catch |err| {
        s.mutex.lock();
        terminate(child.id.?);
        s.child_id = null;
        s.mutex.unlock();
        reader.cancel(runtime);
        child.kill(runtime);
        return err;
    };

    sendLoop(s, child.stdin.?) catch {};
    child.stdin.?.close(runtime);
    child.stdin = null;

    {
        s.mutex.lock();
        defer s.mutex.unlock();
        const deadline = io.nanoTimestamp() + shutdown_grace_ns;
        while (!s.reader_done) {
            const now = io.nanoTimestamp();
            if (now >= deadline) break;
            io.waitTimeout(&s.changed.inner, &s.mutex.inner, @intCast(deadline - now)) catch {};
        }
        if (!s.reader_done) terminate(child.id.?);
        s.child_id = null;
    }
    // A connector's descendants (or WSL relay) can retain stdout after the
    // connector dies. Cancel the read itself rather than relying on pipe EOF.
    reader.cancel(runtime);
    watchdog.join();
    _ = child.wait(runtime) catch child.kill(runtime);

    s.mutex.lock();
    defer s.mutex.unlock();
    return s.hello;
}

fn sendLoop(s: *Session, stdin: std.Io.File) !void {
    const runtime = io.get();
    const payload = blk: {
        s.mutex.lock();
        defer s.mutex.unlock();
        // A spawn can execute even if its reply is lost. Never submit one
        // before hello, and irrevocably disable fallback before the write.
        while (!s.hello and !s.reader_done and !s.closing) s.changed.wait(&s.mutex);
        if (s.reader_done or s.closing) return;
        const spawn: wire.Spawn = .{
            .cols = s.cols,
            .rows = s.rows,
            .cwd = s.cwd,
            .argv = s.shell_argv,
            .env = s.env,
            .command = s.command,
            .close_on_exit = s.close_on_exit,
            .one_shot = s.one_shot,
            .user_shell = s.user_shell,
            .shell_integration = s.shell_integration,
            .path_style = s.host.path_style,
        };
        break :blk try std.json.Stringify.valueAlloc(gpa, spawn, .{});
    };
    defer gpa.free(payload);
    s.mutex.lock();
    if (s.closing or s.reader_done) {
        s.mutex.unlock();
        return;
    }
    s.spawn_submitted = true;
    s.writing = true;
    s.mutex.unlock();
    const sent = writeFrame(runtime, stdin, .spawn, payload);
    s.mutex.lock();
    s.writing = false;
    s.mutex.unlock();
    try sent;

    var chunk: [input_chunk]u8 = undefined;
    while (true) {
        s.mutex.lock();
        // Hold input until hello: a connector that never starts the agent
        // leaves it queued for a retry or the native fallback.
        while (!s.closing and !s.reader_done and !(s.hello and (s.resize_pending or s.input_start < s.input.items.len))) s.changed.wait(&s.mutex);
        if (s.reader_done) {
            s.mutex.unlock();
            return;
        }
        var kind: wire.Kind = undefined;
        var count: usize = 0;
        var resize_payload: [4]u8 = undefined;
        if (s.closing) {
            // Pending input is moot; ask the agent to hang up the shell. The
            // watchdog bounds this write if the host stopped reading stdin.
            s.refs += 1;
            s.mutex.unlock();
            if (std.Thread.spawn(.{}, closeWatchdog, .{s})) |thread| thread.detach() else |_| s.unref();
            writeFrame(runtime, stdin, .close, "") catch {};
            return;
        } else if (s.resize_pending) {
            s.resize_pending = false;
            resize_payload = wire.encodeResize(s.cols, s.rows);
            kind = .resize;
        } else if (s.input_start < s.input.items.len) {
            count = @min(chunk.len, s.input.items.len - s.input_start);
            @memcpy(chunk[0..count], s.input.items[s.input_start..][0..count]);
            kind = .input;
        } else unreachable;
        s.writing = true;
        s.mutex.unlock();
        const result = writeFrame(runtime, stdin, kind, if (kind == .resize) &resize_payload else chunk[0..count]);
        s.mutex.lock();
        s.writing = false;
        if (kind == .input) {
            s.input_start += count;
            if (s.input_start == s.input.items.len) {
                s.input.clearRetainingCapacity();
                s.input_start = 0;
            }
        }
        s.mutex.unlock();
        try result;
    }
}

fn closeWatchdog(s: *Session) void {
    defer s.unref();
    s.mutex.lock();
    defer s.mutex.unlock();
    const deadline = io.nanoTimestamp() + shutdown_grace_ns;
    while (!s.reader_done) {
        const now = io.nanoTimestamp();
        if (now >= deadline) break;
        io.waitTimeout(&s.changed.inner, &s.mutex.inner, @intCast(deadline - now)) catch {};
    }
    // `child_id` is cleared before the child is reaped, so this never hits a
    // recycled pid.
    if (!s.reader_done) if (s.child_id) |child| terminate(child);
}

fn writeFrame(runtime: std.Io, file: std.Io.File, kind: wire.Kind, payload: []const u8) !void {
    const header = (wire.Header{ .kind = kind, .len = @intCast(payload.len) }).encode();
    try file.writeStreamingAll(runtime, &header);
    if (payload.len > 0) try file.writeStreamingAll(runtime, payload);
}

fn readerMain(s: *Session, stdout: std.Io.File) void {
    const runtime = io.get();
    var frames: wire.Reader = .{};
    defer frames.deinit(gpa);
    var buf: [64 * 1024]u8 = undefined;
    outer: while (true) {
        const n = stdout.readStreaming(runtime, &.{&buf}) catch break;
        if (n == 0) break;
        frames.push(gpa, buf[0..n]) catch break;
        while (true) {
            const frame = (frames.next() catch break :outer) orelse break;
            if (!acceptFrame(s, frame.header.kind, frame.payload)) break :outer;
        }
    }
    s.mutex.lock();
    // Nobody drains stdout any more; kill the connector so the worker's wait
    // cannot hang on a child blocked writing to it.
    // EOF also ends transport ownership: a wrapper may close stdout while
    // remaining alive forever. Kill before publishing completion or reaping.
    if (s.child_id) |child| terminate(child);
    s.reader_done = true;
    s.changed.broadcast();
    s.mutex.unlock();
    s.wake.signal();
}

/// Returns false when the stream must stop (protocol violation or closing).
fn acceptFrame(s: *Session, kind: wire.Kind, payload: []const u8) bool {
    s.mutex.lock();
    defer s.mutex.unlock();
    if (!s.hello) {
        if (kind != .hello) return false;
        const parsed = std.json.parseFromSlice(struct { version: u32, one_shot: bool = false, user_shell: bool = false }, gpa, payload, .{ .ignore_unknown_fields = true }) catch return false;
        defer parsed.deinit();
        if (parsed.value.version != wire.version) return false;
        if (s.user_shell and !parsed.value.user_shell) {
            s.endLocked("agent lacks user-shell job support; update agent");
            return false;
        }
        if (s.one_shot and !parsed.value.one_shot) {
            s.endLocked("agent lacks one-shot job support; update agent");
            return false;
        }
        s.hello = true;
        s.changed.broadcast();
        return true;
    }
    switch (kind) {
        .output => {
            while (!s.closing and s.pendingOutputLocked() > 0 and s.pendingOutputLocked() + payload.len > output_high_water) s.changed.wait(&s.mutex);
            if (s.closing) return true; // keep draining so the agent can exit
            if (s.output_start > 0 and s.output.capacity - s.output.items.len < payload.len) {
                const rest = s.pendingOutputLocked();
                std.mem.copyForwards(u8, s.output.items[0..rest], s.output.items[s.output_start..]);
                s.reader_compacted_bytes += rest;
                s.output.items.len = rest;
                s.output_start = 0;
            }
            s.output.appendSlice(gpa, payload) catch return false;
            s.mutex.unlock();
            s.wake.signal();
            s.mutex.lock();
        },
        .exit => {
            if (payload.len == 4) s.exit_status = std.mem.readInt(u32, payload[0..4], .little);
        },
        .@"error" => {
            var buf: [512]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "\r\n\x1b[31m[hollow-agent] {s}\x1b[0m\r\n", .{payload[0..@min(payload.len, 256)]}) catch return true;
            std.log.warn("agent pty error: {s}", .{payload[0..@min(payload.len, 256)]});
            if (!s.closing) s.output.appendSlice(gpa, text) catch {};
        },
        else => {},
    }
    return true;
}

test "one-shot jobs refuse old agent hello before submitting work" {
    const a = std.testing.allocator;
    var pty = try AgentPty.init(a, .{ .shell = "/bin/sh", .cols = 80, .rows = 24, .cwd = null, .env_block = null, .launch_command = .{ .command = "false", .one_shot = true }, .host = .{} }, .{});
    defer pty.closeAndJoin();
    try std.testing.expect(!acceptFrame(pty.session, .hello, "{\"version\":1}"));
    try std.testing.expect(!pty.session.spawn_submitted);
    try std.testing.expectEqual(@as(?u32, failure_status), pty.exitStatus());
}

test "user shell jobs refuse agents advertising only one-shot support" {
    var pty = try AgentPty.init(std.testing.allocator, .{ .shell = "/bin/sh", .cols = 80, .rows = 24, .cwd = null, .env_block = null, .launch_command = .{ .command = "false", .one_shot = true, .user_shell = true }, .host = .{} }, .{});
    defer pty.closeAndJoin();
    try std.testing.expect(!acceptFrame(pty.session, .hello, "{\"version\":1,\"one_shot\":true}"));
    try std.testing.expect(!pty.session.spawn_submitted);
    try std.testing.expectEqual(@as(?u32, failure_status), pty.exitStatus());
}

fn parseEnvBlock(a: std.mem.Allocator, block: []const u8) ![]const wire.EnvVar {
    var list: std.ArrayList(wire.EnvVar) = .empty;
    var entries = std.mem.splitScalar(u8, block, 0);
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (eq == 0) continue;
        try list.append(a, .{ .key = try a.dupe(u8, entry[0..eq]), .value = try a.dupe(u8, entry[eq + 1 ..]) });
    }
    return list.toOwnedSlice(a);
}

fn tokenize(a: std.mem.Allocator, command: []const u8) ![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    var quote: ?u8 = null;
    var in_word = false;
    for (command) |ch| {
        if (quote) |q| {
            if (ch == q) quote = null else try current.append(a, ch);
        } else if (ch == '"' or ch == '\'') {
            quote = ch;
            in_word = true;
        } else if (std.ascii.isWhitespace(ch)) {
            if (in_word) try parts.append(a, try current.toOwnedSlice(a));
            in_word = false;
        } else {
            try current.append(a, ch);
            in_word = true;
        }
    }
    if (in_word) try parts.append(a, try current.toOwnedSlice(a));
    return parts.toOwnedSlice(a);
}

fn isWslProgram(arg: []const u8) bool {
    const base = if (std.mem.lastIndexOfAny(u8, arg, "/\\")) |i| arg[i + 1 ..] else arg;
    return std.ascii.eqlIgnoreCase(base, "wsl") or std.ascii.eqlIgnoreCase(base, "wsl.exe");
}

/// The command a `wsl.exe [options] [--exec|--] cmd...` launcher runs inside
/// the distro. Empty for any other shell, selecting the host's login shell.
fn wslInnerArgv(a: std.mem.Allocator, shell: []const u8) ![]const []const u8 {
    const argv = try tokenize(a, shell);
    if (argv.len == 0 or !isWslProgram(argv[0])) return &.{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--exec") or std.mem.eql(u8, arg, "--")) return argv[i + 1 ..];
        // `~` only selects the start directory.
        if (std.mem.eql(u8, arg, "~")) continue;
        if (arg.len == 0 or arg[0] != '-') return argv[i..];
        inline for (.{ "-d", "--distribution", "-u", "--user", "--cd", "--shell-type" }) |option| {
            if (std.mem.eql(u8, arg, option)) i += 1;
        }
    }
    return &.{};
}

test "wsl launcher inner argv" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(usize, 0), (try wslInnerArgv(a, "wsl.exe -d Ubuntu")).len);
    try std.testing.expectEqual(@as(usize, 0), (try wslInnerArgv(a, "/bin/zsh -l")).len);
    const exec = try wslInnerArgv(a, "\"C:\\Windows\\System32\\wsl.exe\" --distribution Ubuntu --user me --exec zsh -l");
    try std.testing.expectEqual(@as(usize, 2), exec.len);
    try std.testing.expectEqualStrings("zsh", exec[0]);
    try std.testing.expectEqual(@as(usize, 0), (try wslInnerArgv(a, "wsl.exe -d Ubuntu ~ --shell-type login")).len);
    const bare = try wslInnerArgv(a, "wsl -d Arch -- fish");
    try std.testing.expectEqualStrings("fish", bare[0]);
}

test "env block parses into spawn env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const env = try parseEnvBlock(arena.allocator(), "A=1\x00B=x=y\x00\x00");
    try std.testing.expectEqual(@as(usize, 2), env.len);
    try std.testing.expectEqualStrings("x=y", env[1].value);
}
