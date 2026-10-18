//! Bounded, asynchronous RPC over one persistent subprocess connection.
//! Connectors supply argv only. No workspace, platform, or terminal policy.
const std = @import("std");
const protocol = @import("../agent/protocol.zig");

pub const max_requests = 32;
pub const max_stream_bytes = 1024 * 1024;
pub const max_metadata = 128 * 1024;
pub const max_queued_bytes = 4 * 1024 * 1024;
const control_reserve = 65536;
const queue_capacity = max_requests * 2 + 8;
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
    pty: bool = false,
    pty_budget: usize = 0,
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

const Outbound = struct {
    kind: protocol.Kind,
    id: u64,
    stream: u64 = 0,
    bytes: []u8 = &.{},
    credit: ?[8]u8 = null,
    enqueued_ns: i128 = 0,
    fn payload(self: *const Outbound) []const u8 {
        return if (self.credit) |*credit| credit else self.bytes;
    }
};
pub const Options = struct {
    experimental_pty: bool = false,
    telemetry: bool = false,
    context: ?*anyopaque = null,
    notify: ?*const fn (*anyopaque) void = null,
};

/// Fixed-size optional counters. Durations include blocking, not CPU time.
pub const Metrics = struct {
    pipe_reads: u64 = 0,
    pipe_read_bytes: u64 = 0,
    pipe_read_ns: u64 = 0,
    pipe_writes: u64 = 0,
    pipe_write_ns: u64 = 0,
    data_frames: u64 = 0,
    data_bytes: u64 = 0,
    short_data_frames: u64 = 0,
    credit_frames: u64 = 0,
    credit_bytes: u64 = 0,
    queue_wait_ns: u64 = 0,
    max_queue_wait_ns: u64 = 0,
    max_queued_bytes: u64 = 0,
    max_pty_buffered: u64 = 0,
    pty_shift_bytes: u64 = 0,
    notifications: u64 = 0,
};
const Counters = struct {
    values: [@typeInfo(Metrics).@"struct".fields.len]std.atomic.Value(u64) = @splat(.init(0)),
    fn add(self: *Counters, comptime field: std.meta.FieldEnum(Metrics), amount: u64) void {
        _ = self.values[std.meta.fieldIndex(Metrics, @tagName(field)).?].fetchAdd(amount, .monotonic);
    }
    fn max(self: *Counters, comptime field: std.meta.FieldEnum(Metrics), value: u64) void {
        _ = self.values[std.meta.fieldIndex(Metrics, @tagName(field)).?].fetchMax(value, .monotonic);
    }
    fn snapshot(self: *const Counters) Metrics {
        var result: Metrics = .{};
        inline for (@typeInfo(Metrics).@"struct".fields, 0..) |field, index| @field(result, field.name) = self.values[index].load(.monotonic);
        return result;
    }
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    argv: []const []const u8,
    generation: u64,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    slots: [max_requests]Slot = [_]Slot{.{}} ** max_requests,
    queue: [queue_capacity]?Outbound = .{null} ** queue_capacity,
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
    options: Options = .{},
    counters: Counters = .{},
    notify_deadline_ns: i128 = 0,

    /// Returns immediately after scheduling connection work. No launch, HELLO,
    /// remote reads or pipe writes happen on the caller's thread.
    pub fn create(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !*Connection {
        return createWithOptions(allocator, io, argv, .{});
    }

    pub fn createWithOptions(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, options: Options) !*Connection {
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
        self.* = .{ .allocator = allocator, .io = io, .arena = arena, .argv = owned, .generation = generation, .connect_deadline_ns = now(io) + 5000 * std.time.ns_per_ms, .options = options };
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

    pub fn metrics(self: *const Connection) Metrics {
        return self.counters.snapshot();
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
        const pty = std.mem.eql(u8, op.string, "PTY_SPAWN");
        if (pty and !self.options.experimental_pty) return error.InvalidArgument;
        const exec = std.mem.eql(u8, op.string, "EXEC") or pty;
        var credit: usize = 0;
        if (pty) {
            const v = parsed.value.object.get("output_credit") orelse return error.InvalidPayload;
            if (v != .integer or v.integer < 0 or v.integer > 65536) return error.InvalidPayload;
            credit = @intCast(v.integer);
        }
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
        slot.* = .{ .id = id, .deadline_ns = now(self.io) + @as(i128, timeout_ms) * std.time.ns_per_ms, .stdout_id = out, .stderr_id = err, .file_read = file_read, .pty = pty, .pty_budget = credit };
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
            if (slot.pty and slot.stdout.items.len > 0) continue;
            const completion = Completion{ .id = slot.id, .generation = self.generation, .failure = slot.failure, .metadata_json = slot.metadata, .stdout_stream_id = slot.stdout_id, .stderr_stream_id = slot.stderr_id, .stdout = slot.stdout.items, .stderr = slot.stderr.items, .stdout_storage = slot.stdout, .stderr_storage = slot.stderr };
            slot.metadata = null;
            slot.stdout = .empty;
            slot.stderr = .empty;
            if (slot.remote_terminal) slot.* = .{} else slot.published = true;
            return completion;
        }
        return null;
    }

    /// Nonblocking owner-thread consumption. Credit follows consumption, never
    /// network receipt. Terminal completions cannot overtake buffered output.
    pub fn readPty(self: *Connection, id: u64, buffer: []u8) !usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const slot = self.find(id) orelse return error.Disconnected;
        if (!slot.pty) return error.InvalidArgument;
        const count = @min(buffer.len, slot.stdout.items.len);
        if (count == 0) return 0;
        if (!slot.remote_terminal and !self.closing and self.state == .ready) {
            try self.enqueueCredit(id, slot.stdout_id, count);
            slot.pty_budget += count;
            self.changed.signal(self.io);
            if (self.options.telemetry) {
                self.counters.add(.credit_frames, 1);
                self.counters.add(.credit_bytes, count);
            }
        }
        @memcpy(buffer[0..count], slot.stdout.items[0..count]);
        if (self.options.telemetry) self.counters.add(.pty_shift_bytes, slot.stdout.items.len - count);
        std.mem.copyForwards(u8, slot.stdout.items, slot.stdout.items[count..]);
        slot.stdout.items.len -= count;
        return count;
    }

    pub fn pendingPtyBytes(self: *Connection, id: u64) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const slot = self.find(id) orelse return 0;
        return if (slot.pty) slot.stdout.items.len else 0;
    }

    fn notify(self: *Connection) void {
        if (self.options.telemetry) self.counters.add(.notifications, 1);
        if (self.options.notify) |callback| if (self.options.context) |context| callback(context);
    }

    /// Owner requests a single future wake without polling or doing transport I/O.
    pub fn wakeAfter(self: *Connection, milliseconds: u32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const deadline = now(self.io) + @as(i128, milliseconds) * std.time.ns_per_ms;
        if (self.notify_deadline_ns == 0 or deadline < self.notify_deadline_ns) self.notify_deadline_ns = deadline;
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
        self.notify();
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
        self.queue[(self.queue_start + self.queue_len) % queue_capacity] = .{ .kind = kind, .id = id, .bytes = owned, .enqueued_ns = if (self.options.telemetry) now(self.io) else 0 };
        self.queue_len += 1;
        self.queued_bytes += bytes.len + protocol.header_len;
        if (self.options.telemetry) self.counters.max(.max_queued_bytes, self.queued_bytes);
    }

    fn enqueueCredit(self: *Connection, id: u64, stream: u64, count: usize) !void {
        const size = protocol.header_len + 8;
        if (self.queue_len == queue_capacity or self.queued_bytes + size > max_queued_bytes - control_reserve) return error.ResourceExhausted;
        var credit: [8]u8 = undefined;
        std.mem.writeInt(u64, &credit, count, .little);
        self.queue[(self.queue_start + self.queue_len) % queue_capacity] = .{
            .kind = .window_update,
            .id = id,
            .stream = stream,
            .credit = credit,
            .enqueued_ns = if (self.options.telemetry) now(self.io) else 0,
        };
        self.queue_len += 1;
        self.queued_bytes += size;
        if (self.options.telemetry) self.counters.max(.max_queued_bytes, self.queued_bytes);
    }

    fn run(self: *Connection) void {
        self.runInner() catch |err| {
            self.failAll(switch (err) {
                error.ProtocolMismatch => error.ProtocolMismatch,
                error.Timeout => error.Timeout,
                else => error.Disconnected,
            });
            return;
        };
        self.failAll(error.Disconnected);
    }

    fn runInner(self: *Connection) !void {
        self.child = try std.process.spawn(self.io, .{ .argv = self.argv, .stdin = .pipe, .stdout = .pipe, .stderr = if (self.options.telemetry) .inherit else .ignore, .create_no_window = true });
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
        self.notify();
    }

    fn writeLoop(self: *Connection) !void {
        try self.writeFrame(.hello, 0, 0, if (self.options.experimental_pty) "{\"major\":1,\"minor\":0,\"experimental_pty\":true,\"max_payload\":1048576,\"max_data\":16384,\"max_streams\":64,\"max_in_flight\":32}" else "{\"major\":1,\"minor\":0,\"max_payload\":1048576,\"max_data\":16384,\"max_streams\":64,\"max_in_flight\":32}");
        while (true) {
            try self.mutex.lock(self.io);
            var locked = true;
            defer if (locked) self.mutex.unlock(self.io);
            while (!self.closing and (self.state != .ready or self.queue_len == 0)) try self.changed.wait(self.io, &self.mutex);
            if (self.closing) return error.Disconnected;
            const frame = self.queue[self.queue_start].?;
            if (self.options.telemetry) {
                const delay: u64 = @intCast(now(self.io) - frame.enqueued_ns);
                self.counters.add(.queue_wait_ns, delay);
                self.counters.max(.max_queue_wait_ns, delay);
            }
            self.queue[self.queue_start] = null;
            self.queue_start = (self.queue_start + 1) % queue_capacity;
            self.queue_len -= 1;
            self.queued_bytes -= frame.payload().len + protocol.header_len;
            self.mutex.unlock(self.io);
            locked = false;
            defer self.allocator.free(frame.bytes);
            try self.writeFrame(frame.kind, frame.id, frame.stream, frame.payload());
        }
    }

    fn watchdog(self: *Connection) !void {
        while (true) {
            try std.Io.sleep(self.io, .fromMilliseconds(10), .awake);
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            if (self.closing) return error.Disconnected;
            const timestamp = now(self.io);
            if (self.notify_deadline_ns != 0 and timestamp >= self.notify_deadline_ns) {
                self.notify_deadline_ns = 0;
                self.notify();
            }
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
                    self.notify();
                }
            }
        }
    }

    const Frame = struct { header: protocol.Header, payload: []u8, owned: bool };
    fn frameStorage(self: *Connection, header: protocol.Header, data_buffer: []u8) !Frame {
        if (header.payload_len > self.peer_payload or (header.kind == .data and header.payload_len > self.peer_data)) return error.ProtocolMismatch;
        if (header.kind != .data and header.payload_len > max_metadata) return error.ProtocolMismatch;
        const owned = header.kind != .data;
        const payload = if (owned) try self.allocator.alloc(u8, header.payload_len) else if (header.payload_len <= data_buffer.len) data_buffer[0..header.payload_len] else return error.ProtocolMismatch;
        return .{ .header = header, .payload = payload, .owned = owned };
    }

    fn readFrame(self: *Connection, data_buffer: []u8) !Frame {
        var bytes: [protocol.header_len]u8 = undefined;
        try self.readExact(&bytes);
        const header = protocol.Header.decode(&bytes) catch return error.ProtocolMismatch;
        const frame = try self.frameStorage(header, data_buffer);
        errdefer if (frame.owned) self.allocator.free(frame.payload);
        try self.readExact(frame.payload);
        if (self.options.telemetry and header.kind == .data) {
            self.counters.add(.data_frames, 1);
            self.counters.add(.data_bytes, frame.payload.len);
            if (frame.payload.len < 4096) self.counters.add(.short_data_frames, 1);
        }
        return frame;
    }

    fn readLoop(self: *Connection) !void {
        // One negotiated-frame-sized scratch buffer, not read-ahead. accept()
        // copies DATA into bounded owner storage before this buffer is reused.
        var data_buffer: [protocol.max_data]u8 = undefined;
        const ack = try self.readFrame(&data_buffer);
        defer if (ack.owned) self.allocator.free(ack.payload);
        if (ack.header.kind != .hello_ack or ack.header.request_id != 0 or ack.header.stream_id != 0) return error.ProtocolMismatch;
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, ack.payload, .{}) catch return error.ProtocolMismatch;
        defer parsed.deinit();
        if (parsed.value != .object) return error.ProtocolMismatch;
        const object = parsed.value.object;
        if (self.options.experimental_pty) {
            const capabilities = object.get("capabilities") orelse return error.ProtocolMismatch;
            if (capabilities != .array) return error.ProtocolMismatch;
            var found = false;
            for (capabilities.array.items) |value| if (value == .string and std.mem.eql(u8, value.string, "experimental.pty")) {
                found = true;
            };
            if (!found) return error.ProtocolMismatch;
        }
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
            self.notify();
        }
        while (true) {
            const frame = try self.readFrame(&data_buffer);
            defer if (frame.owned) self.allocator.free(frame.payload);
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
                if (slot.pty) {
                    if (header.stream_id != slot.stdout_id or frame.payload.len > slot.pty_budget or slot.stdout.items.len + frame.payload.len > 65536) return error.ProtocolMismatch;
                    slot.pty_budget -= frame.payload.len;
                }
                if (slot.stdout.items.len + slot.stderr.items.len + frame.payload.len > max_stream_bytes) {
                    try self.cancelLocked(slot);
                    slot.done = true;
                    slot.abandoned = true;
                    slot.failure = error.OutputLimit;
                    slot.stdout.clearRetainingCapacity();
                    slot.stderr.clearRetainingCapacity();
                } else try destination.appendSlice(self.allocator, frame.payload);
                if (slot.pty and self.options.telemetry) self.counters.max(.max_pty_buffered, slot.stdout.items.len);
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
        self.notify();
    }

    fn find(self: *Connection, id: u64) ?*Slot {
        if (id == 0) return null;
        for (&self.slots) |*slot| if (slot.id == id) return slot;
        return null;
    }

    fn writeFrame(self: *Connection, kind: protocol.Kind, id: u64, sid: u64, bytes: []const u8) !void {
        const header = try (protocol.Header{ .kind = kind, .request_id = id, .stream_id = sid, .payload_len = @intCast(bytes.len) }).encode();
        const start = if (self.options.telemetry) now(self.io) else 0;
        try self.child.?.stdin.?.writeStreamingAll(self.io, &header);
        try self.child.?.stdin.?.writeStreamingAll(self.io, bytes);
        if (self.options.telemetry) {
            self.counters.add(.pipe_writes, 2);
            self.counters.add(.pipe_write_ns, @intCast(now(self.io) - start));
        }
    }

    fn readExact(self: *Connection, destination: []u8) !void {
        var offset: usize = 0;
        while (offset < destination.len) {
            const start = if (self.options.telemetry) now(self.io) else 0;
            const count = try self.child.?.stdout.?.readStreaming(self.io, &.{destination[offset..]});
            if (self.options.telemetry) {
                self.counters.add(.pipe_reads, 1);
                self.counters.add(.pipe_read_bytes, count);
                self.counters.add(.pipe_read_ns, @intCast(now(self.io) - start));
            }
            if (count == 0) return error.EndOfStream;
            offset += count;
        }
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

test "DATA frame storage uses bounded scratch without allocation" {
    const a = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var connection: Connection = .{ .allocator = failing.allocator(), .io = std.testing.io, .arena = arena, .argv = &.{}, .generation = 1, .connect_deadline_ns = 0 };
    var scratch: [protocol.max_data]u8 = undefined;
    const header: protocol.Header = .{ .kind = .data, .request_id = 1, .stream_id = 2, .payload_len = protocol.max_data };
    const frame = try connection.frameStorage(header, &scratch);
    try std.testing.expect(!frame.owned);
    try std.testing.expectEqual(scratch[0..].ptr, frame.payload.ptr);
    try std.testing.expectEqual(scratch.len, frame.payload.len);
    try std.testing.expectError(error.ProtocolMismatch, connection.frameStorage(header, scratch[0..1024]));
    connection.peer_data = 1024;
    try std.testing.expectError(error.ProtocolMismatch, connection.frameStorage(header, &scratch));
}

test "consumed PTY credit is inline, bounded and allocation-free" {
    const a = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var connection: Connection = .{ .allocator = failing.allocator(), .io = std.testing.io, .arena = arena, .argv = &.{}, .generation = 1, .connect_deadline_ns = 0, .state = .ready, .options = .{ .telemetry = true } };
    const slot = &connection.slots[0];
    slot.* = .{ .id = 1, .pty = true, .stdout_id = 2 };
    defer slot.deinit(a);
    try slot.stdout.appendSlice(a, "hello");
    var buffer: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try connection.readPty(1, &buffer));
    try std.testing.expectEqualStrings("he", &buffer);
    const queued = connection.queue[0].?;
    try std.testing.expectEqual(protocol.Kind.window_update, queued.kind);
    try std.testing.expectEqual(@as(u64, 2), queued.stream);
    try std.testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, queued.credit.?[0..8], .little));
    try std.testing.expectEqual(@as(u64, 2), connection.metrics().credit_bytes);
    try std.testing.expectEqualStrings("llo", slot.stdout.items);
    connection.queue_len = queue_capacity;
    try std.testing.expectError(error.ResourceExhausted, connection.readPty(1, &buffer));
    try std.testing.expectEqualStrings("llo", slot.stdout.items);
}
