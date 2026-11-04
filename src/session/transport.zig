//! One asynchronous connector per attached workspace. Filesystem/RPC and
//! nonpersistent PTYs remain separate. Destroying this connection closes only
//! the bridge: the host owner and its panes remain alive.
const std = @import("std");
const deploy = @import("../host/deploy.zig");
const protocol = @import("client.zig");
const Wake = @import("../pty/wake.zig").Wake;
pub const p = protocol.p;
pub const Message = protocol.Message;
pub const RequestState = protocol.RequestState;
const write_timeout_ns = 3 * std.time.ns_per_s;

pub const Options = struct {
    connector: deploy.Connector = .{},
    agent: deploy.Agent = .{},
    ghostty_identity: []const u8,
    wake: Wake = .{},
};

pub const Status = struct {
    phase: enum { connecting, ready, closing, ended },
    format: ?p.SnapshotFormat,
    failure: ?anyerror,
    queued_frames: usize,
    queued_bytes: usize,
    watchdog_turns: u64,
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    options: Options,
    client: protocol.Client,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    watch: std.Io.Condition = .init,
    future: ?std.Io.Future(void) = null,
    control: deploy.Control = .{},
    child: ?std.process.Child = null, // owner task only, borrowed by its tasks
    closing: bool = false,
    finished: bool = false,
    failure: ?anyerror = null,
    deploy_failure: deploy.Failure = .{},
    connect_deadline: i128 = 0,
    writing_since: ?i128 = null,
    watch_deadline: ?i128 = null,
    write_probe_until: ?i128 = null,
    watchdog_turns: u64 = 0,

    /// Copies all configuration before starting any background work.
    pub fn create(a: std.mem.Allocator, io: std.Io, options: Options) !*Connection {
        if (options.agent.timeout_ms == 0) return error.InvalidArgument;
        const self = try a.create(Connection);
        errdefer a.destroy(self);
        self.* = .{
            .allocator = a,
            .io = io,
            .arena = .init(a),
            .options = options,
            .client = .{ .allocator = a, .identity = undefined },
        };
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        self.options.connector = try options.connector.dupe(arena);
        self.options.agent = try options.agent.dupe(arena);
        self.client.identity = try arena.dupe(u8, options.ghostty_identity);
        self.options.ghostty_identity = self.client.identity;
        self.future = try io.concurrent(run, .{self});
        return self;
    }

    /// Nonblocking cancellation. No kill request is sent to the host owner.
    pub fn close(self: *Connection) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closing = true;
        self.changed.broadcast(self.io);
        self.watch.signal(self.io);
        self.control.cancel(self.io);
    }

    /// Teardown only: joins all I/O before freeing shared state. Returned
    /// Messages own their payload and may outlive the connection.
    pub fn destroy(self: *Connection) void {
        self.close();
        if (self.future) |*future| future.cancel(self.io);
        self.client.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn status(self: *Connection) Status {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .phase = if (self.finished) .ended else if (self.closing) .closing else if (self.client.ready) .ready else .connecting,
            .format = self.client.format,
            .failure = self.failure,
            .queued_frames = self.client.incoming.count(),
            .queued_bytes = self.client.incoming.bytes,
            .watchdog_turns = self.watchdog_turns,
        };
    }

    pub fn request(self: *Connection, value: p.Request) !u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closing) return error.Disconnected;
        const id = try self.client.request(value);
        self.changed.broadcast(self.io);
        return id;
    }

    pub fn requestState(self: *Connection, id: u64) RequestState {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.client.requestState(id);
    }

    pub fn deploymentFailure(self: *Connection) ?deploy.Failure {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return if (self.failure != null and self.failure.? == error.DeployFailed) self.deploy_failure else null;
    }

    /// Returned frame is owned; call deinit after use. Reply dequeue releases
    /// its pending-request slot. Output requires consumed AFTER terminal parse.
    pub fn poll(self: *Connection) ?Message {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const message = self.client.poll() orelse return null;
        self.changed.broadcast(self.io); // receive queue may have been full
        return message;
    }

    pub fn send(self: *Connection, kind: p.Kind, pane: u32, bytes: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closing) return error.Disconnected;
        try self.client.send(kind, pane, bytes);
        self.changed.broadcast(self.io);
    }

    pub fn consumed(self: *Connection, message: Message) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closing) return;
        try self.client.consumed(message);
        self.changed.broadcast(self.io);
    }

    fn run(self: *Connection) void {
        const failure: ?anyerror = if (self.runInner()) |_| error.Disconnected else |err| err;
        self.mutex.lockUncancelable(self.io);
        self.client.ended = true;
        self.failure = if (self.closing) null else failure;
        self.finished = true;
        self.changed.broadcast(self.io);
        self.options.wake.signal();
        self.mutex.unlock(self.io);
    }

    fn runInner(self: *Connection) !void {
        var failure: deploy.Failure = .{};
        const arena = self.arena.allocator();
        const installed = deploy.install(self.io, arena, &self.control, self.options.connector, self.options.agent, &failure, .{}) catch |err| {
            self.mutex.lockUncancelable(self.io);
            self.deploy_failure = failure;
            self.mutex.unlock(self.io);
            return err;
        };
        const argv = try self.options.connector.command(arena, &.{ installed.path, "session", "connect" });
        self.mutex.lockUncancelable(self.io);
        const closing = self.closing;
        self.connect_deadline = now(self.io) + @as(i128, self.options.agent.timeout_ms) * std.time.ns_per_ms;
        self.mutex.unlock(self.io);
        if (closing) return error.Disconnected;
        self.child = try std.process.spawn(self.io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore, .create_no_window = true });
        defer self.child.?.kill(self.io);
        // Cancellation joins both blocked pipe I/O and condition waits. In
        // particular a descendant retaining stdout cannot hang GUI teardown.
        const Tasks = union(enum) { reader: anyerror!void, writer: anyerror!void, watchdog: anyerror!void };
        var results: [3]Tasks = undefined;
        var tasks = std.Io.Select(Tasks).init(self.io, &results);
        defer tasks.cancelDiscard();
        try tasks.concurrent(.reader, readLoop, .{self});
        try tasks.concurrent(.writer, writeLoop, .{self});
        try tasks.concurrent(.watchdog, watchdog, .{self});
        const result = try tasks.await();
        switch (result) {
            inline else => |value| try value,
        }
    }

    fn writeLoop(self: *Connection) !void {
        const hello = try self.client.hello();
        defer self.allocator.free(hello);
        try self.writeFrame(.hello, 0, hello);
        while (true) {
            try self.mutex.lock(self.io);
            var locked = true;
            defer if (locked) self.mutex.unlock(self.io);
            var next: ?Message = null;
            while (!self.closing and !self.client.ended) {
                next = self.client.nextWrite();
                if (next != null) break;
                try self.changed.wait(self.io, &self.mutex);
            }
            const message = next orelse return error.Disconnected;
            if (message.request_id) |id| {
                self.client.submittedAt(id, now(self.io));
                self.watch.signal(self.io);
            }
            self.mutex.unlock(self.io);
            locked = false;
            defer message.deinit();
            try self.writeFrame(message.kind, message.pane, message.payload);
        }
    }

    fn writeFrame(self: *Connection, kind: p.Kind, pane: u32, bytes: []const u8) !void {
        try self.mutex.lock(self.io);
        self.writing_since = now(self.io);
        // Do not wake the watchdog per output-credit frame. An already armed
        // earlier deadline covers new writes too; wake only to arm/advance it.
        const deadline = self.writing_since.? + write_timeout_ns;
        if (self.watch_deadline == null or deadline < self.watch_deadline.?) {
            self.write_probe_until = if (self.write_probe_until) |previous| @min(previous, deadline) else deadline;
            self.watch.signal(self.io);
        }
        self.mutex.unlock(self.io);
        defer {
            self.mutex.lockUncancelable(self.io);
            self.writing_since = null;
            self.mutex.unlock(self.io);
        }
        const file = self.child.?.stdin.?;
        try file.writeStreamingAll(self.io, &p.header(kind, pane, bytes.len).encode());
        try file.writeStreamingAll(self.io, bytes);
    }

    fn readLoop(self: *Connection) !void {
        const file = self.child.?.stdout.?;
        while (true) {
            var header_bytes: [p.header_len]u8 = undefined;
            try readExact(self.io, file, &header_bytes);
            const header = try p.Header.decode(&header_bytes);
            _ = try p.validate(header, .to_client); // before payload allocation
            const body = try self.allocator.alloc(u8, header.len);
            defer self.allocator.free(body);
            try readExact(self.io, file, body);
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            while (!self.closing and !self.client.incoming.fits(body.len)) try self.changed.wait(self.io, &self.mutex);
            if (self.closing) return error.Disconnected;
            try self.client.receive(header, body);
            self.changed.broadcast(self.io);
            const kind = try p.validate(header, .to_client);
            if (kind == .welcome or kind == .reply) self.watch.signal(self.io);
            self.options.wake.signal();
        }
    }

    fn watchdog(self: *Connection) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            self.watchdog_turns += 1;
            if (self.closing) return error.Disconnected;
            const timestamp = now(self.io);
            if (!self.client.ready and timestamp >= self.connect_deadline) return error.Timeout;
            if (self.writing_since) |since| if (timestamp - since >= write_timeout_ns) return error.WriteTimeout;
            const request_deadline = self.client.requestDeadline(@as(i128, self.options.agent.timeout_ms) * std.time.ns_per_ms);
            if (request_deadline) |deadline| if (timestamp >= deadline) return error.RequestTimeout;
            var next: ?i128 = if (!self.client.ready) self.connect_deadline else request_deadline;
            if (self.writing_since) |since| next = if (next) |deadline| @min(deadline, since + write_timeout_ns) else since + write_timeout_ns;
            if (self.write_probe_until) |deadline| {
                if (deadline <= timestamp) {
                    self.write_probe_until = null;
                } else next = if (next) |previous| @min(previous, deadline) else deadline;
            }
            self.watch_deadline = next;
            const timeout: std.Io.Timeout = if (next) |deadline| .{ .deadline = .{
                .clock = .awake,
                .raw = .fromNanoseconds(@intCast(deadline)),
            } } else .none;
            self.watch.waitTimeout(self.io, &self.mutex, timeout) catch |err| switch (err) {
                error.Timeout => {},
                else => return err,
            };
        }
    }
};

fn now(io: std.Io) i128 {
    return std.Io.Clock.awake.now(io).toNanoseconds();
}

fn readExact(io: std.Io, file: std.Io.File, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = try file.readStreaming(io, &.{bytes[offset..]});
        if (count == 0) return error.EndOfStream;
        offset += count;
    }
}
