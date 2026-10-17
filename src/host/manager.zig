//! Runtime-owned, owner-thread dispatch. No Lua, workspace or connector policy.
const std = @import("std");
const transport = @import("transport.zig");
pub const operations = @import("operations.zig");

pub const max_hosts = 8;
pub const max_pending = 64;
pub const Handle = struct { slot: u8, generation: u64 };
pub const Ticket = struct { host: Handle, id: u64 };
const Entry = struct { id: []u8, connection: *transport.Connection };
const Pending = struct {
    ticket: Ticket,
    wire_id: u64,
    kind: operations.Kind,
    completion: ?transport.Completion = null,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    hosts: [max_hosts]?Entry = .{null} ** max_hosts,
    pending: [max_pending]?Pending = .{null} ** max_pending,
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Manager {
        return .{ .allocator = allocator, .io = io };
    }

    /// Launches exactly one connector subprocess asynchronously. Reconnection
    /// is explicit; pending work from the previous generation is never replayed.
    pub fn connectAgent(self: *Manager, id: []const u8, argv: []const []const u8) !Handle {
        if (id.len == 0 or id.len > 256 or std.mem.indexOfScalar(u8, id, 0) != null) return error.InvalidArgument;
        self.drain();
        var available: ?usize = null;
        for (&self.hosts, 0..) |*entry, index| {
            if (entry.*) |*host| {
                if (!std.mem.eql(u8, host.id, id)) continue;
                if (host.connection.status() != .disconnected) return error.AlreadyConnected;
                // Disconnect may race the initial drain. All terminal slots
                // are now stable; capture them before replacing their owner.
                self.drain();
                // drain() transferred every old result into a generation-tagged
                // pending slot before destroying its transport allocation owner.
                const connection = try transport.Connection.create(self.allocator, self.io, argv);
                host.connection.destroy();
                host.connection = connection;
                return .{ .slot = @intCast(index), .generation = connection.generation };
            } else if (available == null) available = index;
        }
        const index = available orelse return error.ResourceExhausted;
        const owned_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned_id);
        const connection = try transport.Connection.create(self.allocator, self.io, argv);
        self.hosts[index] = .{ .id = owned_id, .connection = connection };
        return .{ .slot = @intCast(index), .generation = connection.generation };
    }

    pub fn status(self: *Manager, handle: Handle) !transport.State {
        return (try self.get(handle)).connection.status();
    }

    pub fn failure(self: *Manager, handle: Handle) !?anyerror {
        return (try self.get(handle)).connection.connectionFailure();
    }

    pub fn hostId(self: *Manager, handle: Handle) ![]const u8 {
        return (try self.get(handle)).id;
    }

    pub fn request(self: *Manager, handle: Handle, operation: operations.Operation, timeout_ms: u64) !Ticket {
        const host = try self.get(handle);
        const entry = for (&self.pending) |*entry| {
            if (entry.* == null) break entry;
        } else return error.ResourceExhausted;
        if (self.next_id == std.math.maxInt(u64)) return error.IdExhausted;
        const streams = if (operation == .exec) try host.connection.allocateStreams() else null;
        const bytes = try operations.encode(self.allocator, operation, streams);
        defer self.allocator.free(bytes);
        const wire_id = try host.connection.request(bytes, timeout_ms);
        const ticket: Ticket = .{ .host = handle, .id = self.next_id };
        self.next_id += 1;
        entry.* = .{ .ticket = ticket, .wire_id = wire_id, .kind = std.meta.activeTag(operation) };
        return ticket;
    }

    pub fn cancel(self: *Manager, ticket: Ticket) !void {
        self.drain();
        const pending = self.find(ticket) orelse return error.StaleRequest;
        if (pending.completion != null) return;
        const host = try self.get(ticket.host);
        try host.connection.cancel(pending.wire_id);
    }

    /// Transfers one owned typed result. Allocation failure preserves its wire
    /// completion for retry; malformed replies fail this generation, not Lua.
    pub fn poll(self: *Manager, ticket: Ticket) !?operations.Result {
        self.drain();
        const pending = self.find(ticket) orelse return error.StaleRequest;
        const completion = pending.completion orelse return null;
        const result = operations.decode(self.allocator, pending.kind, completion) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => blk: {
                if (self.get(ticket.host)) |host| host.connection.close() else |_| {}
                break :blk operations.Result{ .arena = std.heap.ArenaAllocator.init(self.allocator), .value = .{ .failure = .{ .code = "protocol_mismatch", .message = "Malformed agent response" } } };
            },
        };
        freeWire(self.allocator, completion);
        // Ticket ids never repeat; stale Lua pollers cannot consume a reused
        // slot even after closing/reconnecting a host or recreating a runtime.
        for (&self.pending) |*entry| if (entry.*) |value| {
            if (sameTicket(value.ticket, ticket)) {
                entry.* = null;
                break;
            }
        };
        return result;
    }

    pub fn close(self: *Manager, handle: Handle) !void {
        (try self.get(handle)).connection.close();
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
        if (host.connection.status() != .disconnected) return error.HostBusy;
        for (self.pending) |entry| if (entry) |pending| {
            if (pending.ticket.host.slot == handle.slot) return error.HostBusy;
        };
        host.connection.destroy();
        self.allocator.free(host.id);
        self.hosts[handle.slot] = null;
    }

    pub fn deinit(self: *Manager) void {
        for (self.hosts) |entry| if (entry) |host| host.connection.close();
        for (&self.pending) |*entry| {
            if (entry.*) |pending| if (pending.completion) |completion| freeWire(self.allocator, completion);
            entry.* = null;
        }
        for (&self.hosts) |*entry| {
            if (entry.*) |host| {
                host.connection.destroy();
                self.allocator.free(host.id);
            }
            entry.* = null;
        }
    }

    fn get(self: *Manager, handle: Handle) !*Entry {
        if (handle.slot >= max_hosts) return error.StaleHost;
        const entry = if (self.hosts[handle.slot]) |*entry| entry else return error.StaleHost;
        if (entry.connection.generation != handle.generation) return error.StaleHost;
        return entry;
    }

    fn find(self: *Manager, ticket: Ticket) ?*Pending {
        for (&self.pending) |*entry| if (entry.*) |*pending| {
            if (sameTicket(pending.ticket, ticket)) return pending;
        };
        return null;
    }

    fn drain(self: *Manager) void {
        for (&self.hosts, 0..) |*entry, index| if (entry.*) |*host| {
            var count: usize = 0;
            while (count < transport.max_requests) : (count += 1) {
                const completion = host.connection.poll() orelse break;
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
                    host.connection.close();
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
