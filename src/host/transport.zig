//! Bounded, asynchronous RPC over one persistent subprocess connection.
//! Connectors supply argv only. No workspace, platform, or terminal policy.
const std = @import("std");
const protocol = @import("../agent/protocol.zig");
const deploy = @import("deploy.zig");

pub const max_requests = 32;
pub const max_stream_bytes = 1024 * 1024;
pub const max_metadata = 128 * 1024;
pub const max_queued_bytes = 4 * 1024 * 1024;
const control_reserve = 65536;
const queue_capacity = max_requests * 2 + 8;
const connect_timeout_ns = 5000 * std.time.ns_per_ms;
var next_generation: std.atomic.Value(u64) = .init(1);

/// Shared by native-local and agent backends so handles never alias across
/// backend switches or Lua runtime reloads in this process.
pub fn newGeneration() !u64 {
    const generation = next_generation.fetchAdd(1, .monotonic);
    if (generation == 0 or generation == std.math.maxInt(u64)) return error.IdExhausted;
    return generation;
}

pub const State = enum { connecting, ready, disconnected };
pub const Streams = struct { stdout: u64, stderr: u64 };
const Slot = struct {
    id: u64 = 0,
    deadline_ns: i128 = 0,
    cancel_deadline_ns: i128 = 0,
    done: bool = false,
    published: bool = false,
    remote_terminal: bool = false,
    abandoned: bool = false,
    cancel_sent: bool = false,
    failure: ?anyerror = null,
    metadata: ?[]u8 = null,
    stdout_id: u64 = 0,
    stderr_id: u64 = 0,
    file_read: bool = false,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,

    fn deinit(self: *Slot, allocator: std.mem.Allocator) void {
        if (self.metadata) |bytes| allocator.free(bytes);
        self.stdout.deinit(allocator);
        self.stderr.deinit(allocator);
        self.* = .{};
    }
};

pub const Completion = struct {
    id: u64,
    generation: u64,
    failure: ?anyerror,
    metadata_json: ?[]const u8,
    stdout_stream_id: u64,
    stderr_stream_id: u64,
    stdout: []const u8,
    stderr: []const u8,
    stdout_storage: std.ArrayList(u8),
    stderr_storage: std.ArrayList(u8),
};

const Outbound = struct { kind: protocol.Kind, id: u64, bytes: []u8 };

pub const Connection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    argv: []const []const u8,
    /// Install the agent through this connector first, then run
    /// `<connector> <agent> stdio` instead of `argv`.
    deploy: ?struct { connector: deploy.Connector, agent: deploy.Agent } = null,
    deploy_control: deploy.Control = .{},
    deploy_failure: deploy.Failure = .{},
    generation: u64,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    slots: [max_requests]Slot = @splat(.{}),
    queue: [queue_capacity]?Outbound = @splat(null),
    queue_start: usize = 0,
    queue_len: usize = 0,
    queued_bytes: usize = 0,
    future: ?std.Io.Future(void) = null,
    child: ?std.process.Child = null,
    state: State = .connecting,
    closing: bool = false,
    failure: ?anyerror = null,
    nonce: [64]u8 = undefined,
    nonce_len: usize = 0,
    next_id: u64 = 1,
    next_stream: u64 = 2,
    last_stream: u64 = 0,
    peer_requests: usize = max_requests,
    peer_streams: usize = max_requests * 2,
    peer_payload: usize = protocol.max_payload,
    peer_data: usize = protocol.max_data,
    connect_deadline_ns: i128,

    /// Returns immediately after scheduling connection work. No launch, HELLO,
    /// remote reads or pipe writes happen on the caller's thread.
    pub fn create(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !*Connection {
        if (argv.len == 0 or argv[0].len == 0 or argv.len > 4096) return error.InvalidArgument;
        const generation = try newGeneration();
        const self = try allocator.create(Connection);
        errdefer allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = try arena.allocator().alloc([]const u8, argv.len);
        var total: usize = 0;
        for (argv, 0..) |arg, i| {
            total += arg.len;
            if (total > protocol.max_payload or std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidArgument;
            owned[i] = try arena.allocator().dupe(u8, arg);
        }
        self.* = .{ .allocator = allocator, .io = io, .arena = arena, .argv = owned, .generation = generation, .connect_deadline_ns = now(io) + connect_timeout_ns };
        self.future = try io.concurrent(run, .{self});
        return self;
    }

    /// Like `create`, but deploys the agent through `connector` first.
    pub fn createDeployed(allocator: std.mem.Allocator, io: std.Io, connector: deploy.Connector, agent: deploy.Agent) !*Connection {
        if (connector.argv.len == 0 or connector.argv.len > 4096) return error.InvalidArgument;
        const generation = try newGeneration();
        const self = try allocator.create(Connection);
        errdefer allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned_connector = try connector.dupe(arena.allocator());
        const owned_agent = try agent.dupe(arena.allocator());
        self.* = .{
            .allocator = allocator,
            .io = io,
            .arena = arena,
            .argv = &.{},
            .deploy = .{ .connector = owned_connector, .agent = owned_agent },
            .generation = generation,
            .connect_deadline_ns = 0,
        };
        self.future = try io.concurrent(run, .{self});
        return self;
    }

    pub fn status(self: *Connection) State {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state;
    }

    pub fn connectionFailure(self: *Connection) ?anyerror {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.failure;
    }

    /// Why the agent deploy failed (`error.DeployFailed`).
    pub fn deployFailure(self: *Connection) ?*const deploy.Failure {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const failure = self.failure orelse return null;
        return if (failure == error.DeployFailed) &self.deploy_failure else null;
    }

    pub fn allocateStreams(self: *Connection) !Streams {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.next_stream > std.math.maxInt(i64) - 4) return error.IdExhausted;
        const result: Streams = .{ .stdout = self.next_stream, .stderr = self.next_stream + 2 };
        self.next_stream += 4;
        return result;
    }

    /// Submit opaque wire JSON. The public host API's byte encoding belongs in
    /// its typed adapter, not this transport. Completed slots are never reused
    /// before poll transfers their owned result to the consumer.
    pub fn request(self: *Connection, json: []const u8, timeout_ms: u64) !u64 {
        if (json.len == 0 or json.len > protocol.max_payload or timeout_ms == 0 or timeout_ms > 86400000) return error.InvalidArgument;
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json, .{}) catch return error.InvalidPayload;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidPayload;
        const op = parsed.value.object.get("op") orelse return error.InvalidPayload;
        if (op != .string) return error.InvalidPayload;
        const exec = std.mem.eql(u8, op.string, "EXEC");
        const file_read = std.mem.eql(u8, op.string, "FS_READ");
        var out: u64 = 0;
        var err: u64 = 0;
        if (exec) {
            out = try jsonPositive(parsed.value, "stdout_stream_id");
            err = try jsonPositive(parsed.value, "stderr_stream_id");
            if (out % 2 != 0 or err % 2 != 0 or out == err) return error.InvalidPayload;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state == .disconnected or self.closing) return error.Disconnected;
        if (self.state != .ready) return error.NotReady;
        if (json.len > self.peer_payload) return error.InvalidPayload;
        if (exec and @min(out, err) <= self.last_stream) return error.InvalidPayload;
        var active: usize = 0;
        var streams: usize = 0;
        var available: ?*Slot = null;
        for (&self.slots) |*slot| {
            if (slot.id == 0) available = slot else active += 1;
            if (slot.id != 0 and slot.stdout_id != 0) streams += 2;
        }
        if (active >= self.peer_requests) return error.ResourceExhausted;
        if (exec and streams + 2 > self.peer_streams) return error.ResourceExhausted;
        const slot = available orelse return error.ResourceExhausted;
        if (self.next_id == std.math.maxInt(u64)) return error.IdExhausted;
        const id = self.next_id;
        try self.enqueue(.request, id, json);
        slot.* = .{ .id = id, .deadline_ns = now(self.io) + @as(i128, timeout_ms) * std.time.ns_per_ms, .stdout_id = out, .stderr_id = err, .file_read = file_read };
        self.next_id += 1;
        if (exec) {
            self.last_stream = @max(out, err);
            self.next_stream = @max(self.next_stream, self.last_stream + 2);
        }
        self.changed.signal(self.io);
        return id;
    }

    pub fn cancel(self: *Connection, id: u64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.find(id)) |slot| if (!slot.done) try self.cancelLocked(slot);
    }

    fn cancelLocked(self: *Connection, slot: *Slot) !void {
        if (slot.cancel_sent or slot.remote_terminal) return;
        try self.enqueue(.cancel, slot.id, "");
        slot.cancel_sent = true;
        slot.cancel_deadline_ns = now(self.io) + 5000 * std.time.ns_per_ms;
        self.changed.signal(self.io);
    }

    pub fn poll(self: *Connection) ?Completion {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (&self.slots) |*slot| {
            if (slot.id == 0 or !slot.done or slot.published) continue;
            const completion = Completion{ .id = slot.id, .generation = self.generation, .failure = slot.failure, .metadata_json = slot.metadata, .stdout_stream_id = slot.stdout_id, .stderr_stream_id = slot.stderr_id, .stdout = slot.stdout.items, .stderr = slot.stderr.items, .stdout_storage = slot.stdout, .stderr_storage = slot.stderr };
            slot.metadata = null;
            slot.stdout = .empty;
            slot.stderr = .empty;
            if (slot.remote_terminal) slot.* = .{} else slot.published = true;
            return completion;
        }
        return null;
    }

    pub fn freeCompletion(self: *Connection, completion: Completion) void {
        if (completion.metadata_json) |bytes| self.allocator.free(bytes);
        var stdout = completion.stdout_storage;
        var stderr = completion.stderr_storage;
        stdout.deinit(self.allocator);
        stderr.deinit(self.allocator);
    }

    /// Request asynchronous shutdown; owner can keep polling failed work.
    pub fn close(self: *Connection) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closing = true;
        self.changed.broadcast(self.io);
        self.deploy_control.cancel(self.io);
    }

    /// Owner teardown only. All task cancellation joins before memory is freed.
    pub fn destroy(self: *Connection) void {
        self.close();
        if (self.future) |*future| future.cancel(self.io);
        for (&self.slots) |*slot| slot.deinit(self.allocator);
        for (self.queue) |entry| if (entry) |frame| self.allocator.free(frame.bytes);
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn enqueue(self: *Connection, kind: protocol.Kind, id: u64, bytes: []const u8) !void {
        const limit: usize = if (kind == .cancel) max_queued_bytes else max_queued_bytes - control_reserve;
        if (self.queue_len == queue_capacity or self.queued_bytes + bytes.len + protocol.header_len > limit) return error.ResourceExhausted;
        const owned = try self.allocator.dupe(u8, bytes);
        self.queue[(self.queue_start + self.queue_len) % queue_capacity] = .{ .kind = kind, .id = id, .bytes = owned };
        self.queue_len += 1;
        self.queued_bytes += bytes.len + protocol.header_len;
    }

    fn run(self: *Connection) void {
        self.runInner() catch |err| {
            self.failAll(switch (err) {
                error.ProtocolMismatch => error.ProtocolMismatch,
                error.Timeout => error.Timeout,
                error.DeployFailed => error.DeployFailed,
                else => error.Disconnected,
            });
            return;
        };
        self.failAll(error.Disconnected);
    }

    fn runInner(self: *Connection) !void {
        const argv = if (self.deploy) |target| try self.deployAgent(target.connector, target.agent) else self.argv;
        self.child = try std.process.spawn(self.io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore, .create_no_window = true });
        defer self.child.?.kill(self.io);
        const Tasks = union(enum) { reader: anyerror!void, writer: anyerror!void, watchdog: anyerror!void };
        var results: [3]Tasks = undefined;
        var select = std.Io.Select(Tasks).init(self.io, &results);
        defer select.cancelDiscard();
        try select.concurrent(.reader, readLoop, .{self});
        try select.concurrent(.writer, writeLoop, .{self});
        try select.concurrent(.watchdog, watchdog, .{self});
        const result = try select.await();
        switch (result) {
            inline else => |value| try value,
        }
    }

    fn deployAgent(self: *Connection, connector: deploy.Connector, agent: deploy.Agent) ![]const []const u8 {
        // Deploy messages are written before `failure` is published.
        var failure: deploy.Failure = .{};
        const a = self.arena.allocator();
        // Always probe: a stale cached install would only show up as a failed
        // handshake, which this connection does not retry.
        const installed = deploy.install(self.io, a, &self.deploy_control, connector, agent, &failure, .{ .use_cache = false }) catch |err| {
            if (err == error.DeployFailed) {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                self.deploy_failure = failure;
            }
            return err;
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closing) return error.Disconnected;
        self.connect_deadline_ns = now(self.io) + connect_timeout_ns;
        return connector.command(a, &.{ installed.path, "stdio" });
    }

    fn failAll(self: *Connection, failure: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.state = .disconnected;
        self.failure = failure;
        for (&self.slots) |*slot| {
            if (slot.id == 0) continue;
            if (!slot.done) {
                slot.failure = failure;
                slot.done = true;
            }
            slot.remote_terminal = true;
            if (slot.published) slot.deinit(self.allocator);
        }
        self.changed.broadcast(self.io);
    }

    fn writeLoop(self: *Connection) !void {
        try self.writeFrame(.hello, 0, "{\"major\":1,\"minor\":0,\"max_payload\":1048576,\"max_data\":16384,\"max_streams\":64,\"max_in_flight\":32}");
        while (true) {
            try self.mutex.lock(self.io);
            var locked = true;
            defer if (locked) self.mutex.unlock(self.io);
            while (!self.closing and (self.state != .ready or self.queue_len == 0)) try self.changed.wait(self.io, &self.mutex);
            if (self.closing) return error.Disconnected;
            const frame = self.queue[self.queue_start].?;
            self.queue[self.queue_start] = null;
            self.queue_start = (self.queue_start + 1) % queue_capacity;
            self.queue_len -= 1;
            self.queued_bytes -= frame.bytes.len + protocol.header_len;
            self.mutex.unlock(self.io);
            locked = false;
            defer self.allocator.free(frame.bytes);
            try self.writeFrame(frame.kind, frame.id, frame.bytes);
        }
    }

    fn watchdog(self: *Connection) !void {
        while (true) {
            try std.Io.sleep(self.io, .fromMilliseconds(10), .awake);
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            if (self.closing) return error.Disconnected;
            const timestamp = now(self.io);
            if (self.state == .connecting and timestamp >= self.connect_deadline_ns) return error.Timeout;
            for (&self.slots) |*slot| {
                if (slot.id == 0 or slot.remote_terminal) continue;
                if (slot.cancel_deadline_ns != 0 and timestamp >= slot.cancel_deadline_ns) return error.Timeout;
                if (!slot.done and timestamp >= slot.deadline_ns) {
                    try self.cancelLocked(slot);
                    slot.done = true;
                    slot.abandoned = true;
                    slot.failure = error.Timeout;
                    slot.stdout.clearRetainingCapacity();
                    slot.stderr.clearRetainingCapacity();
                }
            }
        }
    }

    const Frame = struct { header: protocol.Header, payload: []u8 };
    fn readFrame(self: *Connection) !Frame {
        var bytes: [protocol.header_len]u8 = undefined;
        try readExact(self.io, self.child.?.stdout.?, &bytes);
        const header = protocol.Header.decode(&bytes) catch return error.ProtocolMismatch;
        if (header.payload_len > self.peer_payload or (header.kind == .data and header.payload_len > self.peer_data)) return error.ProtocolMismatch;
        if (header.kind != .data and header.payload_len > max_metadata) return error.ProtocolMismatch;
        const payload = try self.allocator.alloc(u8, header.payload_len);
        errdefer self.allocator.free(payload);
        try readExact(self.io, self.child.?.stdout.?, payload);
        return .{ .header = header, .payload = payload };
    }

    fn readLoop(self: *Connection) !void {
        const ack = try self.readFrame();
        defer self.allocator.free(ack.payload);
        if (ack.header.kind != .hello_ack or ack.header.request_id != 0 or ack.header.stream_id != 0) return error.ProtocolMismatch;
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, ack.payload, .{}) catch return error.ProtocolMismatch;
        defer parsed.deinit();
        if (parsed.value != .object) return error.ProtocolMismatch;
        const object = parsed.value.object;
        const major = object.get("major") orelse return error.ProtocolMismatch;
        if (major != .integer or major.integer != 1) return error.ProtocolMismatch;
        const nonce = object.get("connection_nonce") orelse return error.ProtocolMismatch;
        if (nonce != .string or nonce.string.len != 32) return error.ProtocolMismatch;
        for (nonce.string) |byte| if (!std.ascii.isHex(byte)) return error.ProtocolMismatch;
        const requests = jsonPositive(parsed.value, "max_in_flight") catch return error.ProtocolMismatch;
        if (requests > max_requests) return error.ProtocolMismatch;
        const payload = jsonPositive(parsed.value, "max_payload") catch return error.ProtocolMismatch;
        const data = jsonPositive(parsed.value, "max_data") catch return error.ProtocolMismatch;
        const streams = jsonPositive(parsed.value, "max_streams") catch return error.ProtocolMismatch;
        const jobs = jsonPositive(parsed.value, "max_exec") catch return error.ProtocolMismatch;
        const monotonic = object.get("monotonic_ids") orelse return error.ProtocolMismatch;
        if (payload < 1024 or payload > protocol.max_payload or data < 1024 or data > protocol.max_data or data > payload or
            streams < 2 or streams > max_requests * 2 or jobs > max_requests or monotonic != .bool or !monotonic.bool)
            return error.ProtocolMismatch;
        {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            @memcpy(self.nonce[0..nonce.string.len], nonce.string);
            self.nonce_len = nonce.string.len;
            self.peer_requests = @intCast(@min(requests, jobs));
            self.peer_streams = @intCast(streams);
            self.peer_payload = @intCast(payload);
            self.peer_data = @intCast(data);
            self.state = .ready;
            self.changed.broadcast(self.io);
        }
        while (true) {
            const frame = try self.readFrame();
            defer self.allocator.free(frame.payload);
            try self.accept(frame);
        }
    }

    fn accept(self: *Connection, frame: Frame) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const header = frame.header;
        const slot = self.find(header.request_id) orelse return error.ProtocolMismatch;
        if (slot.remote_terminal) return error.ProtocolMismatch;
        switch (header.kind) {
            .data => {
                const destination = if ((slot.file_read and header.stream_id == 0) or
                    (slot.stdout_id != 0 and header.stream_id == slot.stdout_id)) &slot.stdout else if (slot.stderr_id != 0 and header.stream_id == slot.stderr_id) &slot.stderr else return error.ProtocolMismatch;
                if (slot.abandoned) return;
                if (slot.stdout.items.len + slot.stderr.items.len + frame.payload.len > max_stream_bytes) {
                    try self.cancelLocked(slot);
                    slot.done = true;
                    slot.abandoned = true;
                    slot.failure = error.OutputLimit;
                    slot.stdout.clearRetainingCapacity();
                    slot.stderr.clearRetainingCapacity();
                } else try destination.appendSlice(self.allocator, frame.payload);
            },
            .response, .error_response => {
                if (header.stream_id != 0) return error.ProtocolMismatch;
                const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame.payload, .{}) catch return error.ProtocolMismatch;
                defer parsed.deinit();
                if (parsed.value != .object) return error.ProtocolMismatch;
                if (!slot.abandoned) {
                    slot.metadata = try self.allocator.dupe(u8, frame.payload);
                    if (header.kind == .error_response) slot.failure = error.RemoteError;
                }
                slot.done = true;
                slot.remote_terminal = true;
                if (slot.published) slot.deinit(self.allocator);
            },
            else => return error.ProtocolMismatch,
        }
    }

    fn find(self: *Connection, id: u64) ?*Slot {
        if (id == 0) return null;
        for (&self.slots) |*slot| if (slot.id == id) return slot;
        return null;
    }

    fn writeFrame(self: *Connection, kind: protocol.Kind, id: u64, bytes: []const u8) !void {
        const header = try (protocol.Header{ .kind = kind, .request_id = id, .payload_len = @intCast(bytes.len) }).encode();
        try self.child.?.stdin.?.writeStreamingAll(self.io, &header);
        try self.child.?.stdin.?.writeStreamingAll(self.io, bytes);
    }
};

fn jsonPositive(value: std.json.Value, key: []const u8) !u64 {
    const item = value.object.get(key) orelse return error.InvalidPayload;
    if (item != .integer or item.integer <= 0) return error.InvalidPayload;
    return @intCast(item.integer);
}

fn now(io: std.Io) i128 {
    return std.Io.Clock.awake.now(io).toNanoseconds();
}

fn readExact(io: std.Io, file: std.Io.File, destination: []u8) !void {
    var offset: usize = 0;
    while (offset < destination.len) {
        const count = try file.readStreaming(io, &.{destination[offset..]});
        if (count == 0) return error.EndOfStream;
        offset += count;
    }
}
