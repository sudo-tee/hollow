//! Bounded session protocol state. No I/O or threads; transport serializes
//! access. A request is marked submitted BEFORE its first write, never retried.
const std = @import("std");
pub const p = @import("../agent/session_protocol.zig");

pub const max_requests = 64;
// This is a workspace-wide metadata bound, not the per-tab split-leaf limit.
pub const max_panes = 1024;
pub const queue_bytes = 8 * 1024 * 1024;
pub const queue_frames = 512;

pub const Message = struct {
    kind: p.Kind,
    pane: u32 = 0,
    request_id: ?u64 = null,
    generation: u64 = 0,
    payload: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Message) void {
        self.allocator.free(self.payload);
    }
};

pub const Queue = struct {
    items: std.ArrayList(Message) = .empty,
    start: usize = 0,
    bytes: usize = 0,

    pub fn fits(self: *const Queue, len: usize) bool {
        return self.count() < queue_frames and len <= queue_bytes - self.bytes;
    }

    pub fn count(self: *const Queue) usize {
        return self.items.items.len - self.start;
    }

    fn prepare(self: *Queue, a: std.mem.Allocator, len: usize) !void {
        if (!self.fits(len)) return error.ResourceExhausted;
        if (self.start > 0 and self.start * 2 >= self.items.items.len) {
            const rest = self.items.items.len - self.start;
            std.mem.copyForwards(Message, self.items.items[0..rest], self.items.items[self.start..]);
            self.items.items.len = rest;
            self.start = 0;
        }
        try self.items.ensureUnusedCapacity(a, 1);
    }

    fn appendPrepared(self: *Queue, message: Message) void {
        self.items.appendAssumeCapacity(message);
        self.bytes += message.payload.len;
    }

    pub fn append(self: *Queue, a: std.mem.Allocator, message: Message) !void {
        try self.prepare(a, message.payload.len);
        self.appendPrepared(message);
    }

    pub fn pop(self: *Queue) ?Message {
        if (self.start == self.items.items.len) return null;
        const result = self.items.items[self.start];
        self.start += 1;
        self.bytes -= result.payload.len;
        return result;
    }

    pub fn deinit(self: *Queue, a: std.mem.Allocator) void {
        while (self.pop()) |message| message.deinit();
        self.items.deinit(a);
    }
};

pub const RequestState = enum { unknown, queued, submitted, reply_pending, not_sent, uncertain };
const Pending = struct { id: u64, op: p.Op, pane: ?u32, state: RequestState = .queued, submitted_at: ?i128 = null };
/// Received output one pane may hold before its parse returns credit. Credit
/// is granted on receipt below this, so throughput follows the transport round
/// trip instead of the GUI frame rate. The owner never has more than
/// `p.window` in flight either way.
pub const pane_receive_ahead = 4 * 1024 * 1024;
/// Received-ahead output across all panes of one connection.
pub const receive_ahead = 16 * 1024 * 1024;
const Pane = struct {
    id: u32,
    /// Received and not yet granted back to the owner.
    uncredited: u32 = 0,
    /// Granted, waiting for the writer. Kept here rather than in `outgoing`
    /// so credit coalesces and never competes with input for queue space.
    /// `uncredited + granted` never exceeds `p.window`.
    granted: u32 = 0,
    /// Received and not yet reported parsed by the GUI.
    buffered: usize = 0,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    identity: []const u8,
    ready: bool = false,
    ended: bool = false,
    format: ?p.SnapshotFormat = null,
    /// Owner host ID from the welcome; empty from older or invalid owners.
    host_buf: [p.max_host_len]u8 = undefined,
    host_len: u8 = 0,
    /// The owner advertised the optional respawn op.
    respawn_supported: bool = false,
    create_id_supported: bool = false,
    generation: u64 = 0,
    next_id: u64 = 1,
    pending: [max_requests]?Pending = @splat(null),
    panes: [max_panes]?Pane = @splat(null),
    outgoing: Queue = .{},
    incoming: Queue = .{},
    /// Sum of `Pane.buffered` for the current attachment.
    buffered: usize = 0,
    /// A grant was withheld only because of the aggregate bound.
    ahead_blocked: bool = false,
    /// Panes with a nonzero `granted`.
    grants_pending: usize = 0,

    pub fn deinit(self: *Client) void {
        self.outgoing.deinit(self.allocator);
        self.incoming.deinit(self.allocator);
    }

    pub fn host(self: *const Client) []const u8 {
        return self.host_buf[0..self.host_len];
    }

    /// Always sent first, independently of queued requests.
    pub fn hello(self: *Client) ![]u8 {
        return p.stringify(self.allocator, p.Hello{
            .protocol = p.protocol,
            .version = p.version,
            .ghostty = self.identity,
            .client = "hollow",
        });
    }

    pub fn request(self: *Client, value: p.Request) !u64 {
        if (self.ended) return error.Disconnected;
        // These ops target the implicitly attached workspace. Do not let UI
        // actions for the old workspace queue behind a new attach/create and
        // accidentally mutate panes with the same IDs in that new session.
        // Unknown ops make an owner drop the connection.
        if (value.op == .respawn and !self.respawn_supported) return error.Unsupported;
        if (value.create_id != null and !self.create_id_supported) return error.Unsupported;
        const attached_op = switch (value.op) {
            .spawn, .close, .layout, .detach, .respawn => true,
            .kill => value.session == null,
            else => false,
        };
        if (attached_op and self.attachmentPending()) return error.AttachmentPending;
        if (self.next_id == std.math.maxInt(u64)) return error.ResourceExhausted;
        var slot: ?*?Pending = null;
        for (&self.pending) |*entry| if (entry.* == null) {
            slot = entry;
            break;
        };
        const vacant = slot orelse return error.ResourceExhausted;
        var copy = value;
        copy.id = self.next_id;
        const body = try p.stringify(self.allocator, copy);
        errdefer self.allocator.free(body);
        if (body.len > p.control_limit) return error.PayloadTooLarge;
        try self.outgoing.append(self.allocator, .{ .kind = .request, .request_id = copy.id, .payload = body, .allocator = self.allocator });
        vacant.* = .{ .id = copy.id, .op = copy.op, .pane = copy.pane };
        self.next_id += 1;
        return copy.id;
    }

    fn pendingRequest(self: *Client, id: u64) ?*Pending {
        for (&self.pending) |*entry| if (entry.*) |*value| if (value.id == id) return value;
        return null;
    }

    fn attachmentPending(self: *const Client) bool {
        for (self.pending) |entry| if (entry) |pending| {
            // Receipt alone is not enough: the GUI must dequeue the reply
            // before its pane IDs can safely target the new workspace.
            if (pending.op == .attach or pending.op == .create) return true;
        };
        return false;
    }

    fn attachmentSubmitted(self: *const Client) bool {
        for (self.pending) |entry| if (entry) |pending| {
            if ((pending.op == .attach or pending.op == .create) and pending.state == .submitted) return true;
        };
        return false;
    }

    pub fn requestState(self: *Client, id: u64) RequestState {
        const entry = self.pendingRequest(id) orelse return .unknown;
        return if (self.ended) switch (entry.state) {
            .queued => .not_sent,
            .submitted => .uncertain,
            else => entry.state,
        } else entry.state;
    }

    pub fn submittedAt(self: *Client, id: u64, timestamp: i128) void {
        if (self.pendingRequest(id)) |entry| entry.submitted_at = timestamp;
    }

    pub fn requestDeadline(self: *const Client, timeout: i128) ?i128 {
        var result: ?i128 = null;
        for (self.pending) |slot| if (slot) |entry| {
            if (entry.state == .submitted) if (entry.submitted_at) |since| {
                const deadline = since + timeout;
                result = if (result) |previous| @min(previous, deadline) else deadline;
            };
        };
        return result;
    }

    /// Dequeue before writing. Connection loss afterwards means uncertain,
    /// even when the pipe reports a failure before confirming any bytes.
    pub fn nextWrite(self: *Client) ?Message {
        if (!self.ready or self.ended) return null;
        // Credit generated for the old attachment after an attach request
        // must not refill the new session. Hold it until the reply, which
        // either keeps the panes (attach failed) or drops them with it.
        if (self.grants_pending > 0 and !self.attachmentSubmitted()) {
            if (self.takeGrant()) |message| return message;
        }
        while (self.outgoing.count() > 0) {
            const head = self.outgoing.items.items[self.outgoing.start];
            // Credit generated for the old attachment after an attach request
            // must not refill the new session. Wait for the reply, then either
            // send it (attach failed) or discard it (new generation).
            if (head.request_id == null and self.attachmentSubmitted()) return null;
            const message = self.outgoing.pop().?;
            if (message.request_id) |id| {
                if (self.pendingRequest(id)) |entry| entry.state = .submitted;
            } else if (message.generation != self.generation) {
                message.deinit(); // Stale input/resize/credit after take-over.
                continue;
            }
            return message;
        }
        return null;
    }

    pub fn poll(self: *Client) ?Message {
        const message = self.incoming.pop() orelse return null;
        if (message.request_id) |id| for (&self.pending) |*entry| {
            if (entry.* != null and entry.*.?.id == id) {
                entry.* = null;
                break;
            }
        };
        return message;
    }

    fn pane(self: *Client, id: u32) ?*Pane {
        for (&self.panes) |*entry| if (entry.*) |*value| if (value.id == id) return value;
        return null;
    }

    fn addPane(self: *Client, id: u32) !void {
        if (id == 0 or self.pane(id) != null) return error.InvalidPane;
        for (&self.panes) |*entry| if (entry.* == null) {
            entry.* = .{ .id = id };
            return;
        };
        return error.ResourceExhausted;
    }

    pub fn send(self: *Client, kind: p.Kind, id: u32, bytes: []const u8) !void {
        if (self.ended) return error.Disconnected;
        if (self.attachmentPending()) return error.AttachmentPending;
        if (self.pane(id) == null) return error.NotAttached;
        if (bytes.len > p.max_data) return error.PayloadTooLarge;
        switch (kind) {
            .input => {},
            .resize => _ = try p.decodeResize(bytes),
            else => return error.InvalidKind,
        }
        _ = try p.validate(p.header(kind, id, bytes.len), .to_owner);
        try self.enqueue(kind, id, bytes);
    }

    /// Call once, only AFTER the GUI parsed output. Received-ahead bounds are
    /// released here; credit itself may already have been granted on receipt.
    /// Old queued output cannot grant credit to a newly attached session.
    pub fn consumed(self: *Client, message: Message) !void {
        if (message.kind == .output) try self.consumedBytes(message.pane, message.generation, message.payload.len);
    }

    pub fn consumedBytes(self: *Client, id: u32, generation: u64, count: usize) !void {
        if (generation != self.generation or self.ended) return;
        const entry = self.pane(id) orelse return;
        if (count == 0) return;
        if (count > entry.buffered) return error.InvalidCredit;
        entry.buffered -= count;
        self.buffered -= count;
        self.grant(entry);
        if (self.ahead_blocked) self.retryBlockedGrants();
    }

    /// Returns received bytes to the owner while the GUI's buffered output
    /// stays within both receive-ahead bounds; otherwise parsing grants later.
    fn grant(self: *Client, entry: *Pane) void {
        if (entry.uncredited == 0) return;
        if (entry.buffered > pane_receive_ahead - p.window) return;
        if (self.buffered > receive_ahead - p.window) {
            self.ahead_blocked = true;
            return;
        }
        if (entry.granted == 0) self.grants_pending += 1;
        entry.granted += entry.uncredited;
        entry.uncredited = 0;
    }

    /// A pane withheld by the aggregate bound may have nothing left to parse,
    /// so another pane's consumption must retry it.
    fn retryBlockedGrants(self: *Client) void {
        if (self.buffered > receive_ahead - p.window) return;
        self.ahead_blocked = false;
        for (&self.panes) |*slot| if (slot.*) |*entry| self.grant(entry);
    }

    /// Allocation failure leaves the grant for the next write.
    fn takeGrant(self: *Client) ?Message {
        for (&self.panes) |*slot| if (slot.*) |*entry| if (entry.granted > 0) {
            const body = self.allocator.alloc(u8, 4) catch return null;
            std.mem.writeInt(u32, body[0..4], entry.granted, .little);
            entry.granted = 0;
            self.grants_pending -= 1;
            return .{ .kind = .credit, .pane = entry.id, .generation = self.generation, .payload = body, .allocator = self.allocator };
        };
        return null;
    }

    fn clearPanes(self: *Client) void {
        self.panes = @splat(null);
        self.buffered = 0;
        self.ahead_blocked = false;
        self.grants_pending = 0;
    }

    /// Atomic admission for large user pastes. Either every chunk is queued or
    /// none is; allocation failure cannot submit half a bracketed paste.
    pub fn input(self: *Client, id: u32, bytes: []const u8) !void {
        if (self.ended) return error.Disconnected;
        if (self.attachmentPending()) return error.AttachmentPending;
        if (self.pane(id) == null) return error.NotAttached;
        if (bytes.len > 4 * 1024 * 1024) return error.ResourceExhausted;
        if (bytes.len == 0) return;
        const frames = std.math.divCeil(usize, bytes.len, p.max_data) catch unreachable;
        if (frames > queue_frames - self.outgoing.count() or bytes.len > queue_bytes - self.outgoing.bytes) return error.ResourceExhausted;
        try self.outgoing.prepare(self.allocator, bytes.len);
        try self.outgoing.items.ensureUnusedCapacity(self.allocator, frames);
        const start = self.outgoing.items.items.len;
        const old_bytes = self.outgoing.bytes;
        errdefer {
            for (self.outgoing.items.items[start..]) |message| message.deinit();
            self.outgoing.items.items.len = start;
            self.outgoing.bytes = old_bytes;
        }
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = @min(p.max_data, bytes.len - offset);
            const body = try self.allocator.dupe(u8, bytes[offset..][0..n]);
            self.outgoing.appendPrepared(.{ .kind = .input, .pane = id, .generation = self.generation, .payload = body, .allocator = self.allocator });
            offset += n;
        }
    }

    fn enqueue(self: *Client, kind: p.Kind, id: u32, bytes: []const u8) !void {
        const body = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(body);
        try self.outgoing.append(self.allocator, .{ .kind = kind, .pane = id, .generation = self.generation, .payload = body, .allocator = self.allocator });
    }

    /// Header validated before reading the body by transport. This validates
    /// handshake/control/credit state before publishing owned bytes to the GUI.
    /// Caller first waits until incoming.fits(header.len); no state is mutated
    /// by queue-pressure waits.
    pub fn receive(self: *Client, h: p.Header, bytes: []const u8) !void {
        if (self.ended) return error.Disconnected;
        const kind = try p.validate(h, .to_client);
        if (bytes.len != h.len) return error.InvalidPayload;
        if (!self.incoming.fits(bytes.len)) return error.ResourceExhausted;
        if (!self.ready and kind != .welcome) return error.ExpectedWelcome;
        // Admission must be guaranteed before marking a reply completed. OOM
        // must not leave reply_pending without a message the GUI can retrieve.
        try self.incoming.prepare(self.allocator, bytes.len);
        const body = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(body);
        var request_id: ?u64 = null;
        switch (kind) {
            .welcome => {
                if (self.ready) return error.DuplicateWelcome;
                const welcome = try p.parse(p.Welcome, self.allocator, bytes);
                defer welcome.deinit();
                const w = welcome.value;
                if (!std.mem.eql(u8, w.protocol, p.protocol) or w.version != p.version) return error.ProtocolMismatch;
                if (w.snapshot == .binary and !std.mem.eql(u8, w.ghostty, self.identity)) return error.IdentityMismatch;
                self.ready = true;
                self.format = w.snapshot;
                // An unusable host ID only disables host matching.
                if (p.validHost(w.host)) {
                    @memcpy(self.host_buf[0..w.host.len], w.host);
                    self.host_len = @intCast(w.host.len);
                }
                self.respawn_supported = p.hasFeature(w.features, "respawn");
                self.create_id_supported = p.hasFeature(w.features, "create-id");
            },
            .reply => {
                const reply = try p.parse(p.Reply, self.allocator, bytes);
                defer reply.deinit();
                const entry = self.pendingRequest(reply.value.id) orelse return error.UnexpectedReply;
                if (entry.state != .submitted) return error.UnexpectedReply;
                if (reply.value.ok) switch (entry.op) {
                    .create, .attach => {
                        const session = reply.value.session orelse return error.InvalidReply;
                        if (session.panes.len > max_panes) return error.ResourceExhausted;
                        self.clearPanes();
                        self.generation += 1;
                        for (session.panes) |info| try self.addPane(info.id);
                    },
                    .spawn => try self.addPane(reply.value.pane orelse return error.InvalidReply),
                    .close => for (&self.panes) |*slot| {
                        if (slot.* != null and slot.*.?.id == entry.pane) {
                            self.buffered -= slot.*.?.buffered;
                            if (slot.*.?.granted > 0) self.grants_pending -= 1;
                            slot.* = null;
                        }
                    },
                    .detach => {
                        self.clearPanes();
                        self.generation += 1;
                    },
                    else => {},
                };
                entry.state = .reply_pending;
                request_id = entry.id;
            },
            .event => {
                const event = try p.parse(p.Event, self.allocator, bytes);
                defer event.deinit();
                switch (event.value.event) {
                    .taken, .session_end => {
                        self.clearPanes();
                        self.generation += 1;
                    },
                    .resync => if (self.pane(event.value.pane orelse return error.InvalidPane) == null) return error.InvalidPane,
                }
            },
            .output, .snapshot, .snapshot_end, .exit => {
                const entry = self.pane(h.stream) orelse return error.InvalidPane;
                if (kind == .exit) _ = try p.decodeExit(bytes);
                if (kind == .output) {
                    if (bytes.len > p.window - entry.uncredited - entry.granted) return error.InvalidCredit;
                    entry.uncredited += @intCast(bytes.len);
                    entry.buffered += bytes.len;
                    self.buffered += bytes.len;
                }
            },
            else => unreachable,
        }
        self.incoming.appendPrepared(.{
            .kind = kind,
            .pane = h.stream,
            .request_id = request_id,
            .generation = self.generation,
            .payload = body,
            .allocator = self.allocator,
        });
        if (kind == .output) if (self.pane(h.stream)) |entry| self.grant(entry);
    }
};
