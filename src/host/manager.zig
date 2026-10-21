//! Runtime-owned, owner-thread dispatch. No Lua, workspace or connector policy.
const std = @import("std");
const transport = @import("transport.zig");
const native = @import("local.zig");
pub const deploy = @import("deploy.zig");
pub const operations = @import("operations.zig");

pub const max_hosts = 8;
pub const max_pending = 64;
pub const Handle = struct { slot: u8, generation: u64 };
pub const Ticket = struct { host: Handle, id: u64 };
const Backend = union(enum) {
    agent: *transport.Connection,
    native: struct { generation: u64, closed: bool = false },

    fn generation(self: Backend) u64 {
        return switch (self) {
            .agent => |connection| connection.generation,
            .native => |value| value.generation,
        };
    }
    fn status(self: Backend) transport.State {
        return switch (self) {
            .agent => |connection| connection.status(),
            .native => |value| if (value.closed) .disconnected else .ready,
        };
    }
    fn close(self: *Backend) void {
        switch (self.*) {
            .agent => |connection| connection.close(),
            .native => |*value| value.closed = true,
        }
    }
    fn deinit(self: *Backend) void {
        switch (self.*) {
            .agent => |connection| connection.destroy(),
            .native => {},
        }
    }
};
const Entry = struct { id: []u8, backend: Backend };
const Pending = struct {
    ticket: Ticket,
    wire_id: u64,
    kind: operations.Kind,
    completion: ?transport.Completion = null,
    local_job: ?*native.Job = null,
    local_disconnected: bool = false,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    hosts: [max_hosts]?Entry = .{null} ** max_hosts,
    pending: [max_pending]?Pending = .{null} ** max_pending,
    next_id: u64 = 1,
    environ: std.process.Environ,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Manager {
        return initWithEnviron(allocator, io, @import("../io.zig").environ());
    }

    pub fn initWithEnviron(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) Manager {
        return .{ .allocator = allocator, .io = io, .environ = environ };
    }

    /// Launches exactly one connector subprocess asynchronously. Reconnection
    /// is explicit; pending work from the previous generation is never replayed.
    pub fn connectAgent(self: *Manager, id: []const u8, argv: []const []const u8) !Handle {
        return self.connectWith(id, .{ .argv = argv });
    }

    /// Like `connectAgent`, but installs the agent through `connector` first.
    pub fn connectDeployed(self: *Manager, id: []const u8, connector: deploy.Connector, agent: deploy.Agent) !Handle {
        return self.connectWith(id, .{ .deployed = .{ .connector = connector, .agent = agent } });
    }

    const Launch = union(enum) {
        argv: []const []const u8,
        deployed: struct { connector: deploy.Connector, agent: deploy.Agent },

        fn create(self: Launch, allocator: std.mem.Allocator, io: std.Io) !*transport.Connection {
            return switch (self) {
                .argv => |argv| transport.Connection.create(allocator, io, argv),
                .deployed => |target| transport.Connection.createDeployed(allocator, io, target.connector, target.agent),
            };
        }
    };

    fn connectWith(self: *Manager, id: []const u8, launch: Launch) !Handle {
        if (id.len == 0 or id.len > 256 or std.mem.indexOfScalar(u8, id, 0) != null) return error.InvalidArgument;
        self.drain();
        var available: ?usize = null;
        for (&self.hosts, 0..) |*entry, index| {
            if (entry.*) |*host| {
                if (!std.mem.eql(u8, host.id, id)) continue;
                if (host.backend.status() != .disconnected) return error.AlreadyConnected;
                // Disconnect may race the initial drain. All terminal slots
                // are now stable; capture them before replacing their owner.
                self.drain();
                // drain() transferred every old result into a generation-tagged
                // pending slot before destroying its transport allocation owner.
                const connection = try launch.create(self.allocator, self.io);
                host.backend.deinit();
                host.backend = .{ .agent = connection };
                return .{ .slot = @intCast(index), .generation = connection.generation };
            } else if (available == null) available = index;
        }
        const index = available orelse try self.reclaimSlot();
        const owned_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned_id);
        const connection = try launch.create(self.allocator, self.io);
        self.hosts[index] = .{ .id = owned_id, .backend = .{ .agent = connection } };
        return .{ .slot = @intCast(index), .generation = connection.generation };
    }

    /// Native filesystem/process work runs on cancellable workers. It never
    /// launches a connector or routes Windows operations through Linux.
    pub fn connectLocal(self: *Manager, id: []const u8) !Handle {
        if (id.len == 0 or id.len > 256 or std.mem.indexOfScalar(u8, id, 0) != null) return error.InvalidArgument;
        self.drain();
        var available: ?usize = null;
        for (&self.hosts, 0..) |*entry, index| {
            if (entry.*) |*host| {
                if (!std.mem.eql(u8, host.id, id)) continue;
                if (host.backend.status() != .disconnected) return error.AlreadyConnected;
                self.drain();
                const generation = try transport.newGeneration();
                host.backend.deinit();
                host.backend = .{ .native = .{ .generation = generation } };
                return .{ .slot = @intCast(index), .generation = generation };
            } else if (available == null) available = index;
        }
        const index = available orelse try self.reclaimSlot();
        const owned_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned_id);
        const generation = try transport.newGeneration();
        self.hosts[index] = .{ .id = owned_id, .backend = .{ .native = .{ .generation = generation } } };
        return .{ .slot = @intCast(index), .generation = generation };
    }

    pub fn status(self: *Manager, handle: Handle) !transport.State {
        return (try self.get(handle)).backend.status();
    }

    /// At capacity, recycle only disconnected hosts with no retained tickets
    /// from any generation. Fresh generations keep old handles safely stale.
    fn reclaimSlot(self: *Manager) !usize {
        for (self.hosts, 0..) |entry, index| {
            const host = entry orelse continue;
            if (host.backend.status() != .disconnected) continue;
            var retained = false;
            for (self.pending) |pending| if (pending) |value| {
                if (value.ticket.host.slot == index) retained = true;
            };
            if (retained) continue;
            try self.forget(.{ .slot = @intCast(index), .generation = host.backend.generation() });
            return index;
        }
        return error.ResourceExhausted;
    }

    pub fn failure(self: *Manager, handle: Handle) !?anyerror {
        return switch ((try self.get(handle)).backend) {
            .agent => |connection| connection.connectionFailure(),
            .native => |value| if (value.closed) @as(?anyerror, error.Disconnected) else null,
        };
    }

    pub fn deployFailure(self: *Manager, handle: Handle) !?*const deploy.Failure {
        return switch ((try self.get(handle)).backend) {
            .agent => |connection| connection.deployFailure(),
            .native => null,
        };
    }

    pub fn hostId(self: *Manager, handle: Handle) ![]const u8 {
        return (try self.get(handle)).id;
    }

    pub fn request(self: *Manager, handle: Handle, operation: operations.Operation, timeout_ms: u64) !Ticket {
        const host = try self.get(handle);
        if (host.backend.status() == .disconnected) return error.Disconnected;
        const entry = for (&self.pending) |*entry| {
            if (entry.* == null) break entry;
        } else return error.ResourceExhausted;
        if (self.next_id == std.math.maxInt(u64)) return error.IdExhausted;
        if (host.backend == .native) {
            var count: usize = 0;
            for (self.pending) |pending| if (pending) |value| {
                if (value.ticket.host.slot == handle.slot) count += 1;
            };
            if (count >= 16) return error.ResourceExhausted;
            const job = try native.Job.create(self.allocator, self.io, self.environ, operation, timeout_ms);
            const ticket: Ticket = .{ .host = handle, .id = self.next_id };
            self.next_id += 1;
            entry.* = .{ .ticket = ticket, .wire_id = 0, .kind = std.meta.activeTag(operation), .local_job = job };
            return ticket;
        }
        const connection = host.backend.agent;
        const streams = if (operation == .exec) try connection.allocateStreams() else null;
        const bytes = try operations.encode(self.allocator, operation, streams);
        defer self.allocator.free(bytes);
        const wire_id = try connection.request(bytes, timeout_ms);
        const ticket: Ticket = .{ .host = handle, .id = self.next_id };
        self.next_id += 1;
        entry.* = .{ .ticket = ticket, .wire_id = wire_id, .kind = std.meta.activeTag(operation) };
        return ticket;
    }

    pub fn cancel(self: *Manager, ticket: Ticket) !void {
        self.drain();
        const pending = self.find(ticket) orelse return error.StaleRequest;
        if (pending.local_job) |job| {
            job.cancel();
            return;
        }
        if (pending.completion != null) return;
        const host = try self.get(ticket.host);
        try host.backend.agent.cancel(pending.wire_id);
    }

    /// Transfers one owned typed result. Allocation failure preserves its wire
    /// completion for retry; malformed replies fail this generation, not Lua.
    pub fn poll(self: *Manager, ticket: Ticket) !?operations.Result {
        self.drain();
        const pending = self.find(ticket) orelse return error.StaleRequest;
        if (pending.local_job) |job| {
            var result = job.takeResult() orelse return null;
            // Close invalidates the host immediately, but work is still joined
            // off-thread. Preserve explicit disconnect semantics for old work.
            if (pending.local_disconnected) {
                result.deinit();
                result = .{ .arena = std.heap.ArenaAllocator.init(self.allocator), .value = .{ .failure = .{ .code = "transport_disconnected", .message = "Host closed" } } };
            }
            job.destroy();
            self.clearPending(ticket);
            return result;
        }
        const completion = pending.completion orelse return null;
        const result = operations.decode(self.allocator, pending.kind, completion) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => blk: {
                if (self.get(ticket.host)) |host| host.backend.close() else |_| {}
                break :blk operations.Result{ .arena = std.heap.ArenaAllocator.init(self.allocator), .value = .{ .failure = .{ .code = "protocol_mismatch", .message = "Malformed agent response" } } };
            },
        };
        freeWire(self.allocator, completion);
        // Ticket ids never repeat; stale Lua pollers cannot consume a reused
        // slot even after closing/reconnecting a host or recreating a runtime.
        self.clearPending(ticket);
        return result;
    }

    pub fn close(self: *Manager, handle: Handle) !void {
        (try self.get(handle)).backend.close();
        for (&self.pending) |*entry| if (entry.*) |*pending| {
            if (pending.ticket.host.slot == handle.slot and pending.ticket.host.generation == handle.generation) {
                if (pending.local_job) |job| {
                    if (!job.ready()) pending.local_disconnected = true;
                    job.cancel();
                }
            }
        };
    }

    /// Release a retained wire result if a consumer rejects decoding (for
    /// example, Lua reports allocation failure instead of retrying its poll).
    pub fn discardCompleted(self: *Manager, ticket: Ticket) void {
        for (&self.pending) |*entry| if (entry.*) |pending| {
            if (sameTicket(pending.ticket, ticket)) {
                if (pending.completion) |completion| {
                    freeWire(self.allocator, completion);
                    entry.* = null;
                }
                return;
            }
        };
    }

    /// Forget only an already-disconnected host with no retained generations.
    pub fn forget(self: *Manager, handle: Handle) !void {
        self.drain();
        const host = try self.get(handle);
        if (host.backend.status() != .disconnected) return error.HostBusy;
        for (self.pending) |entry| if (entry) |pending| {
            if (pending.ticket.host.slot == handle.slot) return error.HostBusy;
        };
        host.backend.deinit();
        self.allocator.free(host.id);
        self.hosts[handle.slot] = null;
    }

    pub fn deinit(self: *Manager) void {
        for (&self.hosts) |*entry| if (entry.*) |*host| host.backend.close();
        for (&self.pending) |*entry| if (entry.*) |pending| {
            if (pending.local_job) |job| job.cancel();
        };
        for (&self.pending) |*entry| {
            if (entry.*) |pending| {
                if (pending.completion) |completion| freeWire(self.allocator, completion);
                if (pending.local_job) |job| job.destroy();
            }
            entry.* = null;
        }
        for (&self.hosts) |*entry| {
            if (entry.*) |host| {
                var backend = host.backend;
                backend.deinit();
                self.allocator.free(host.id);
            }
            entry.* = null;
        }
    }

    fn get(self: *Manager, handle: Handle) !*Entry {
        if (handle.slot >= max_hosts) return error.StaleHost;
        const entry = if (self.hosts[handle.slot]) |*entry| entry else return error.StaleHost;
        if (entry.backend.generation() != handle.generation) return error.StaleHost;
        return entry;
    }

    fn find(self: *Manager, ticket: Ticket) ?*Pending {
        for (&self.pending) |*entry| if (entry.*) |*pending| {
            if (sameTicket(pending.ticket, ticket)) return pending;
        };
        return null;
    }

    fn clearPending(self: *Manager, ticket: Ticket) void {
        for (&self.pending) |*entry| if (entry.*) |pending| {
            if (sameTicket(pending.ticket, ticket)) {
                entry.* = null;
                return;
            }
        };
    }

    fn drain(self: *Manager) void {
        for (&self.hosts, 0..) |*entry, index| if (entry.*) |*host| {
            if (host.backend != .agent) continue;
            const connection = host.backend.agent;
            var count: usize = 0;
            while (count < transport.max_requests) : (count += 1) {
                const completion = connection.poll() orelse break;
                var found = false;
                for (&self.pending) |*pending_entry| if (pending_entry.*) |*pending| {
                    if (pending.ticket.host.slot == index and pending.ticket.host.generation == completion.generation and pending.wire_id == completion.id and pending.completion == null) {
                        pending.completion = completion;
                        found = true;
                        break;
                    }
                };
                if (!found) {
                    freeWire(self.allocator, completion);
                    connection.close();
                }
            }
        };
    }
};

fn sameTicket(a: Ticket, b: Ticket) bool {
    return a.id == b.id and a.host.slot == b.host.slot and a.host.generation == b.host.generation;
}

fn freeWire(allocator: std.mem.Allocator, completion: transport.Completion) void {
    if (completion.metadata_json) |bytes| allocator.free(bytes);
    var stdout = completion.stdout_storage;
    var stderr = completion.stderr_storage;
    stdout.deinit(allocator);
    stderr.deinit(allocator);
}

test "manager rejects unknown host handles before allocating" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const stale: Handle = .{ .slot = 255, .generation = 1 };
    try std.testing.expectError(error.StaleHost, manager.status(stale));
    try std.testing.expectError(error.StaleHost, manager.request(stale, .{ .info = {} }, 1000));
    try std.testing.expectError(error.InvalidArgument, manager.connectAgent("", &.{"unused"}));
    try std.testing.expectError(error.InvalidArgument, manager.connectAgent("host\x00", &.{"unused"}));
}
