//! Experimental pane-compatible PTY. Dedicated by default; explicitly shared
//! ownership is available to experiments, not inferred from pane configuration.
const std = @import("std");
const io = @import("../io.zig");
const transport = @import("../host/transport.zig");
const Wake = @import("wake.zig").Wake;

pub const Env = struct { key: []const u8, value: []const u8 };
pub const Config = struct {
    // Focus research only: caller's logical session, not PTY request/session ID.
    logical_session_id: ?u64 = null,
    // Connection options apply only to dedicated spawn(); shared sessions use
    // the already-created owner's transport and callback.
    telemetry: bool = false,
    connector_argv: []const []const u8 = &.{},
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: []const Env = &.{},
};

/// Owner-thread-only lifetime/admission wrapper. One wake covers all sessions;
/// caller must service every session after it fires. No per-pane callback fanout.
pub const SharedConnection = struct {
    allocator: std.mem.Allocator,
    connection: *transport.Connection,
    references: usize = 1,
    sessions: usize = 0,
    closed: bool = false,
    pub const max_sessions = 16;

    pub fn create(allocator: std.mem.Allocator, argv: []const []const u8, wake: Wake) !*SharedConnection {
        return createWithTelemetry(allocator, argv, wake, false);
    }

    pub fn createWithTelemetry(allocator: std.mem.Allocator, argv: []const []const u8, wake: Wake, telemetry: bool) !*SharedConnection {
        return createWithOptions(allocator, argv, wake, .{ .telemetry = telemetry });
    }

    pub const Options = struct { telemetry: bool = false, experimental_focus: bool = false, experimental_deficit: bool = false };
    pub fn createWithOptions(allocator: std.mem.Allocator, argv: []const []const u8, wake: Wake, options: Options) !*SharedConnection {
        const self = try allocator.create(SharedConnection);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .connection = try transport.Connection.createWithOptions(allocator, io.get(), argv, .{
            .experimental_pty = true,
            .context = wake.context,
            .notify = wake.callback,
            .telemetry = options.telemetry,
            .experimental_focus = options.experimental_focus,
            .experimental_deficit = options.experimental_deficit,
        }) };
        return self;
    }

    /// Explicit owner/UI metadata only. Completion remains owned by caller.
    pub fn updateFocus(self: *SharedConnection, sequence: u64, session: u64, stream: u64) !u64 {
        if (self.closed) return error.Disconnected;
        return self.connection.updateFocus(sequence, session, stream);
    }

    fn release(self: *SharedConnection) void {
        self.references -= 1;
        if (self.references == 0) {
            self.connection.destroy();
            self.allocator.destroy(self);
        }
    }

    /// Invalidates the owner's handle; live sessions retain transport storage
    /// until their own teardown, observe disconnect, and must still be closed.
    pub fn destroy(self: *SharedConnection) void {
        self.closed = true;
        self.connection.close();
        self.release();
    }
};

pub const AgentPty = struct {
    allocator: std.mem.Allocator,
    connection: *transport.Connection,
    shared: ?*SharedConnection = null,
    spawn_json: []u8,
    session: ?u64 = null,
    output_stream: ?u64 = null,
    control: ?u64 = null,
    sent_input: usize = 0,
    input: std.ArrayList(u8) = .empty,
    rows: u16,
    cols: u16,
    resize_pending: bool = false,
    control_closed: bool = false,
    retry_at: i128 = 0,
    alive: bool = true,
    closed: bool = false,
    exit_status: ?u32 = null,

    pub fn spawn(allocator: std.mem.Allocator, config: Config, cols: u16, rows: u16, wake: Wake) !AgentPty {
        return init(allocator, config, cols, rows, wake, null);
    }

    pub fn spawnShared(allocator: std.mem.Allocator, shared: *SharedConnection, config: Config, cols: u16, rows: u16) !AgentPty {
        if (shared.closed) return error.Disconnected;
        if (shared.sessions == SharedConnection.max_sessions) return error.ResourceExhausted;
        return init(allocator, config, cols, rows, .{}, shared);
    }

    fn init(allocator: std.mem.Allocator, config: Config, cols: u16, rows: u16, wake: Wake, shared: ?*SharedConnection) !AgentPty {
        if (config.argv.len == 0 or config.argv.len > 4096 or rows == 0 or cols == 0 or config.env.len > 4096) return error.InvalidArgument;
        const focused = if (shared) |owner| owner.connection.options.experimental_focus else false;
        if (focused != (config.logical_session_id != null)) return error.InvalidArgument;
        if (config.logical_session_id) |id| if (id == 0 or id > std.math.maxInt(i64)) return error.InvalidArgument;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var json: std.Io.Writer.Allocating = .init(a);
        try json.writer.print("{{\"op\":\"PTY_SPAWN\",\"rows\":{d},\"cols\":{d},\"output_credit\":65536,\"timeout_ms\":86400000,\"argv_b64\":[", .{ rows, cols });
        for (config.argv, 0..) |arg, i| {
            if (arg.len > 131072 or std.mem.indexOfScalar(u8, arg, 0) != null or (i == 0 and arg.len == 0)) return error.InvalidArgument;
            if (i > 0) try json.writer.writeAll(",");
            try json.writer.print("\"{s}\"", .{try encode(a, arg)});
            if (json.written().len > 1024 * 1024) return error.InvalidArgument;
        }
        try json.writer.writeAll("],\"env_b64\":[");
        for (config.env, 0..) |env, i| {
            if (env.key.len == 0 or env.key.len > 131072 or env.value.len > 131072 or std.mem.indexOfAny(u8, env.key, "=\x00") != null or std.mem.indexOfScalar(u8, env.value, 0) != null) return error.InvalidArgument;
            if (i > 0) try json.writer.writeAll(",");
            try json.writer.print("{{\"key_b64\":\"{s}\",\"value_b64\":\"{s}\"}}", .{ try encode(a, env.key), try encode(a, env.value) });
            if (json.written().len > 1024 * 1024) return error.InvalidArgument;
        }
        try json.writer.writeAll("]");
        if (config.logical_session_id) |id| try json.writer.print(",\"logical_session_id\":{d}", .{id});
        if (config.cwd) |cwd| {
            if (cwd.len == 0 or cwd.len > 4096 or std.mem.indexOfScalar(u8, cwd, 0) != null) return error.InvalidArgument;
            try json.writer.print(",\"cwd_b64\":\"{s}\"", .{try encode(a, cwd)});
        }
        try json.writer.writeAll("}");
        if (json.written().len > 1024 * 1024) return error.InvalidArgument;
        const connection = if (shared) |owner| owner.connection else try transport.Connection.createWithOptions(allocator, io.get(), config.connector_argv, .{
            .experimental_pty = true,
            .telemetry = config.telemetry,
            .context = wake.context,
            .notify = wake.callback,
        });
        errdefer if (shared == null) connection.destroy();
        const spawn_json = try allocator.dupe(u8, json.written());
        if (shared) |owner| {
            owner.references += 1;
            owner.sessions += 1;
        }
        return .{ .allocator = allocator, .connection = connection, .shared = shared, .spawn_json = spawn_json, .rows = rows, .cols = cols };
    }

    fn fail(self: *AgentPty) void {
        self.alive = false;
        self.exit_status = 125;
        if (self.shared == null) self.connection.close() else {
            if (self.session) |id| self.connection.abandon(id);
            if (self.control) |id| self.connection.abandon(id);
        }
    }

    fn pump(self: *AgentPty) void {
        if (self.closed or !self.alive) return;
        if (self.session == null) {
            switch (self.connection.status()) {
                .connecting => return,
                .disconnected => {
                    self.fail();
                    return;
                },
                .ready => {
                    // Allocate IDs in submission order, not handle creation order.
                    const streams = self.connection.allocateStreams() catch {
                        self.fail();
                        return;
                    };
                    const json = std.fmt.allocPrint(self.allocator, "{{\"stdout_stream_id\":{d},\"stderr_stream_id\":{d},{s}", .{ streams.stdout, streams.stderr, self.spawn_json[1..] }) catch {
                        self.fail();
                        return;
                    };
                    defer self.allocator.free(json);
                    self.session = self.connection.request(json, 86400000) catch |err| {
                        if (err == error.ResourceExhausted) {
                            self.connection.wakeAfter(10);
                            return;
                        }
                        self.fail();
                        return;
                    };
                    self.output_stream = streams.stdout;
                },
            }
        }
        while (self.connection.pollFor(self.session.?) orelse if (self.control) |id| self.connection.pollFor(id) else null) |completion| {
            defer self.connection.freeCompletion(completion);
            if (completion.id == self.session.?) {
                self.alive = false;
                self.exit_status = 125;
                if (self.control) |id| self.connection.abandon(id);
                self.control = null;
                if (completion.failure == null) if (completion.metadata_json) |json| {
                    const result = std.json.parseFromSlice(struct { exit_code: u32 }, self.allocator, json, .{}) catch return;
                    defer result.deinit();
                    self.exit_status = result.value.exit_code;
                };
                return;
            }
            if (self.control != null and completion.id == self.control.?) {
                self.control = null;
                if (completion.failure) |failure| {
                    var retry = false;
                    if (failure == error.RemoteError) if (completion.metadata_json) |json| {
                        const result = std.json.parseFromSlice(struct { code: []const u8 }, self.allocator, json, .{ .ignore_unknown_fields = true }) catch {
                            self.fail();
                            return;
                        };
                        defer result.deinit();
                        retry = self.sent_input > 0 and std.mem.eql(u8, result.value.code, "resource_exhausted");
                        if (std.mem.eql(u8, result.value.code, "not_found")) {
                            self.control_closed = true;
                            retry = true;
                        }
                    };
                    if (!retry) {
                        self.fail();
                        return;
                    }
                    if (!self.control_closed) {
                        self.retry_at = io.nanoTimestamp() + 10 * std.time.ns_per_ms;
                        self.connection.wakeAfter(10);
                    }
                } else if (self.sent_input > 0) {
                    std.mem.copyForwards(u8, self.input.items, self.input.items[self.sent_input..]);
                    self.input.items.len -= self.sent_input;
                }
                self.sent_input = 0;
            }
        }
        if (self.control != null or !self.alive or self.control_closed) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        if (self.resize_pending) {
            const json = std.fmt.allocPrint(a, "{{\"op\":\"PTY_RESIZE\",\"session_id\":{d},\"rows\":{d},\"cols\":{d}}}", .{ self.session.?, self.rows, self.cols }) catch {
                self.fail();
                return;
            };
            self.control = self.connection.request(json, 5000) catch |err| {
                if (err == error.ResourceExhausted) {
                    self.connection.wakeAfter(10);
                    return;
                }
                self.fail();
                return;
            };
            self.resize_pending = false;
        } else if (self.input.items.len > 0) {
            if (io.nanoTimestamp() < self.retry_at) return;
            const count = @min(self.input.items.len, 16384);
            const data = encode(a, self.input.items[0..count]) catch {
                self.fail();
                return;
            };
            const json = std.fmt.allocPrint(a, "{{\"op\":\"PTY_INPUT\",\"session_id\":{d},\"bytes_b64\":\"{s}\"}}", .{ self.session.?, data }) catch {
                self.fail();
                return;
            };
            self.control = self.connection.request(json, 5000) catch |err| {
                if (err == error.ResourceExhausted) {
                    self.connection.wakeAfter(10);
                    return;
                }
                self.fail();
                return;
            };
            self.sent_input = count;
        }
    }

    pub fn read(self: *AgentPty, buffer: []u8) !usize {
        self.pump();
        if (self.closed or self.session == null or !self.alive) return 0;
        const count = self.connection.readPty(self.session.?, buffer) catch |err| switch (err) {
            error.ResourceExhausted => return 0,
            else => return err,
        };
        self.pump();
        return count;
    }
    pub fn isAlive(self: *AgentPty) bool {
        self.pump();
        return !self.closed and self.alive;
    }
    pub fn exitStatus(self: *const AgentPty) ?u32 {
        return self.exit_status;
    }
    pub fn pendingOutputBytes(self: *AgentPty) usize {
        self.pump();
        return if (!self.closed and self.session != null) self.connection.pendingPtyBytes(self.session.?) else 0;
    }
    pub fn hasPendingOutput(self: *AgentPty) bool {
        return self.pendingOutputBytes() > 0;
    }
    pub fn hasPendingOutputOrExit(self: *AgentPty) bool {
        return self.hasPendingOutput() or !self.isAlive();
    }
    pub fn writeAll(self: *AgentPty, bytes: []const u8) !void {
        self.pump();
        if (self.closed or !self.alive) return error.WriteFailed;
        if (bytes.len > 65536 - self.input.items.len) return error.InputQueueFull;
        try self.input.appendSlice(self.allocator, bytes);
        self.pump();
    }
    pub fn writeAllUntil(self: *AgentPty, bytes: []const u8, deadline_ns: i128) !usize {
        if (io.nanoTimestamp() >= deadline_ns) return 0;
        self.pump();
        if (self.closed or !self.alive) return error.WriteFailed;
        // Pane startup/paste chunks can exceed this backend's queue capacity.
        // Admit a prefix so their retained remainder can progress on later ticks.
        const count = @min(bytes.len, 65536 - self.input.items.len);
        self.writeAll(bytes[0..count]) catch |err| {
            if (err == error.InputQueueFull) return 0;
            return err;
        };
        return count;
    }
    pub fn resize(self: *AgentPty, cols: u16, rows: u16) void {
        if (cols == 0 or rows == 0) return;
        self.cols = cols;
        self.rows = rows;
        self.resize_pending = true;
        self.pump();
    }
    pub fn childPid(_: *const AgentPty) usize {
        return 0;
    } // Remote PID is not a local PID.
    pub fn close(self: *AgentPty) void {
        if (self.closed) return;
        self.closed = true;
        if (self.shared) |owner| {
            if (self.session) |id| self.connection.abandon(id);
            if (self.control) |id| self.connection.abandon(id);
            owner.sessions -= 1;
            owner.release();
        } else self.connection.destroy();
        self.allocator.free(self.spawn_json);
        self.input.deinit(self.allocator);
    }
    pub fn deinit(self: *AgentPty) void {
        self.close();
    }
};

fn encode(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    return encoder.encode(try a.alloc(u8, encoder.calcSize(bytes.len)), bytes);
}
