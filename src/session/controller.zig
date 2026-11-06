//! GUI-thread workspace frame router. Owns no pane or connection: the app must
//! unbind views before freeing them and retain the connection through close
//! acknowledgements. A control frame is a barrier returned to the caller before
//! following data, so attach/create handlers can register views synchronously.
const std = @import("std");
const transport = @import("transport.zig");
const core = @import("client.zig");
const Pane = @import("../pane.zig").Pane;
const snapshots = @import("../term/session_snapshot_job.zig");
const Job = snapshots.Job;
const p = transport.p;

pub const Step = union(enum) {
    idle,
    blocked,
    dispatched,
    /// Caller owns the message. Do not pump past an attach/create reply before
    /// registering its panes. Controller.step has returned, so removing a
    /// workspace/controller in response to a close ACK cannot reenter it.
    control: transport.Message,
};

const Binding = struct {
    pane: u32,
    generation: u64,
    node: ?*Pane,
    local_id: usize,
    close_request: ?u64 = null,
    close_completed: bool = false,
    close_desired: bool = false,
    respawn_request: ?u64 = null,
    job: ?*Job = null,
    encoded_bytes: usize = 0,
};

pub const Controller = struct {
    allocator: std.mem.Allocator,
    connection: *transport.Connection,
    bindings: [core.max_panes]?Binding = @splat(null),
    pending: ?transport.Message = null,
    session_id: []u8 = &.{},
    /// Owner host ID at publication; empty when the owner sent none.
    host: []u8 = &.{},
    generation: u64 = 0,
    revision: u64 = 0,
    snapshot_bytes: usize = 0,
    /// Aggregate encoded input, not terminal scrollback or allocator overhead.
    snapshot_limit: usize = snapshots.max_snapshot_bytes,
    failure: ?anyerror = null,
    detached: bool = false,
    kill_request: ?u64 = null,
    close_work: bool = false,
    layout_request: ?u64 = null,
    layout_conflict: bool = false,
    layout_failure: ?anyerror = null,
    layout_dirty: bool = false,
    layout_due_ns: i128 = 0,
    spawn_active: bool = false,
    spawn_request: ?u64 = null,

    pub fn init(a: std.mem.Allocator, connection: *transport.Connection) Controller {
        return .{ .allocator = a, .connection = connection };
    }

    /// Views must already be unbound/deinitialized. This does not free them or
    /// destroy the borrowed connection. App teardown only detaches its bridge.
    pub fn deinit(self: *Controller) void {
        self.detachViews();
        self.clearViewLinks();
        if (self.pending) |message| message.deinit();
        self.allocator.free(self.session_id);
        self.allocator.free(self.host);
        self.connection.close();
        self.* = Controller.init(self.allocator, self.connection);
    }

    pub fn bind(self: *Controller, node: *Pane) !void {
        if (self.detached) return error.Detached;
        const term = node.asTerminal() orelse return error.NotSessionPane;
        if (term.session_view != null) return error.AlreadyBound;
        const pty = if (term.pty) |*value| value else return error.NotSessionPane;
        if (pty.* != .session or pty.session.connection != self.connection or pty.session.generation != self.generation) return error.WrongSession;
        if (node.id == 0 or self.byNode(node.id) != null or self.byPane(pty.session.pane) != null) return error.DuplicatePane;
        if (term.session_snapshot != null) return error.AlreadyRestoring;
        for (&self.bindings) |*entry| if (entry.* == null) {
            entry.* = .{ .pane = pty.session.pane, .generation = self.generation, .node = node, .local_id = node.id };
            term.session_view = .{ .context = self, .id = node.id, .unbind = unbindView };
            return;
        };
        return error.ResourceExhausted;
    }

    /// Unbind BEFORE pane destruction. A pending close keeps a metadata-only
    /// tombstone so output queued ahead of its ACK can be discarded safely.
    pub fn unbind(self: *Controller, id: usize) void {
        for (&self.bindings) |*slot| if (slot.*) |*entry| {
            if (entry.local_id != id) continue;
            if (entry.node) |node| node.content.terminal.session_view = null;
            self.cancelSnapshot(entry);
            entry.node = null;
            if (entry.close_request == null or entry.close_completed) slot.* = null;
            return;
        };
    }

    pub fn requestClose(self: *Controller, id: usize) !u64 {
        if (self.detached) return error.Detached;
        if (self.spawn_active) return error.SessionBusy;
        if (self.kill_request != null) return error.SessionClosing;
        const entry = self.byNode(id) orelse return error.PaneNotFound;
        const node = entry.node orelse return error.PaneNotFound;
        const request = try node.content.terminal.pty.?.session.requestClose();
        entry.close_request = request;
        entry.close_completed = false;
        return request;
    }

    pub fn scheduleClose(self: *Controller, id: usize) !void {
        if (self.detached) return error.Detached;
        if (self.kill_request != null) return error.SessionClosing;
        const entry = self.byNode(id) orelse return error.PaneNotFound;
        entry.close_desired = true;
        self.close_work = true;
    }

    /// Frame-thread batch admission; full request queues are retried next
    /// frame, without removing views or replaying an admitted request.
    pub fn flushCloses(self: *Controller) !void {
        if (!self.close_work or self.detached or self.kill_request != null or self.spawn_active) return;
        var submitted: usize = 0;
        for (&self.bindings) |*slot| if (slot.*) |*entry| {
            if (!entry.close_desired or entry.node == null) continue;
            if (submitted == 16) return;
            _ = self.requestClose(entry.local_id) catch |err| {
                if (err == error.ResourceExhausted or err == error.OutOfMemory) return;
                return err;
            };
            entry.close_desired = false;
            submitted += 1;
        };
        self.close_work = false;
    }

    pub fn requestKill(self: *Controller) !u64 {
        if (self.detached) return error.Detached;
        if (self.spawn_active) return error.SessionBusy;
        if (self.kill_request) |id| return id;
        const id = try self.connection.killAttached(self.generation);
        self.kill_request = id;
        return id;
    }

    /// Explicit, revision-checked geometry update. Never replay after a lost
    /// reply or automatically overwrite an owner revision conflict.
    pub fn requestLayout(self: *Controller, bytes: []const u8) !u64 {
        if (self.detached) return error.Detached;
        if (self.spawn_active) return error.SessionBusy;
        if (self.kill_request != null) return error.SessionClosing;
        if (self.layout_request != null) return error.LayoutPending;
        if (self.layout_conflict) return error.RevisionConflict;
        const codec = @import("layout.zig");
        var ids: [core.max_panes]u32 = undefined;
        var count: usize = 0;
        for (self.bindings) |slot| if (slot) |entry| {
            if (entry.node == null or (entry.close_request != null and !entry.close_completed) or entry.close_desired) return error.SessionClosing;
            ids[count] = entry.pane;
            count += 1;
        };
        const parsed = try codec.decode(self.allocator, bytes, ids[0..count]);
        defer parsed.deinit();
        const id = try self.connection.requestAttachedLayout(self.generation, self.revision, bytes);
        self.layout_request = id;
        return id;
    }

    /// Restarts an exited pane in place. Never replayed: a lost reply leaves
    /// the pane dead until the user retries.
    pub fn requestRespawn(self: *Controller, id: usize) !u64 {
        if (self.detached) return error.Detached;
        if (self.kill_request != null) return error.SessionClosing;
        const entry = self.byNode(id) orelse return error.PaneNotFound;
        const node = entry.node orelse return error.PaneNotFound;
        if (entry.respawn_request) |request| return request;
        if ((entry.close_request != null and !entry.close_completed) or entry.close_desired) return error.SessionClosing;
        const pty = &node.content.terminal.pty.?.session;
        if (pty.status == null) return error.PaneAlive;
        if (!self.connection.supportsRespawn()) return error.Unsupported;
        const request = try self.connection.respawnPane(self.generation, entry.pane);
        entry.respawn_request = request;
        return request;
    }

    /// Consumes the pending respawn for `request_id`, returning its pane.
    pub fn finishRespawn(self: *Controller, request_id: u64) ?usize {
        for (&self.bindings) |*slot| if (slot.*) |*entry| {
            if (entry.respawn_request != request_id) continue;
            entry.respawn_request = null;
            return entry.local_id;
        };
        return null;
    }

    pub fn requestSpawn(self: *Controller, spawn: p.Spawn) !u64 {
        if (self.detached) return error.Detached;
        if (self.kill_request != null) return error.SessionClosing;
        if (self.spawn_request != null or self.layout_request != null or self.pendingCloses() != 0) return error.SessionBusy;
        const id = try self.connection.spawnAttached(self.generation, spawn);
        self.spawn_active = true;
        self.spawn_request = id;
        return id;
    }

    /// Teardown only, after the GUI stopped consuming output: waits until
    /// `deadline_ns` for the reply to `id`. Replies are applied (revision,
    /// layout and close state); output and snapshots are discarded because
    /// the views are about to detach. A take-over or end event stops the wait.
    pub fn awaitReply(self: *Controller, id: u64, deadline_ns: i128) !void {
        if (self.pending) |message| message.deinit();
        self.pending = null;
        while (true) {
            const message = self.connection.pollUntil(deadline_ns) orelse return error.Timeout;
            defer message.deinit();
            switch (message.kind) {
                .reply => {
                    _ = try self.route(message);
                    if (message.request_id == id) return;
                },
                .event => {
                    const parsed = try p.parse(p.Event, self.allocator, message.payload);
                    defer parsed.deinit();
                    if (parsed.value.event != .resync) {
                        self.detachViews();
                        return error.Detached;
                    }
                },
                else => {},
            }
        }
    }

    pub fn finishSpawn(self: *Controller) void {
        self.spawn_active = false;
        self.spawn_request = null;
    }

    pub fn abort(self: *Controller, reason: anyerror) void {
        self.failure = reason;
        self.detachViews();
        self.connection.close();
    }

    pub fn closeTarget(self: *Controller, request_id: u64) ?usize {
        for (self.bindings) |slot| if (slot) |entry| {
            if (entry.close_request == request_id) return entry.local_id;
        };
        return null;
    }

    pub fn pendingCloses(self: *const Controller) usize {
        var count: usize = 0;
        for (self.bindings) |slot| if (slot) |entry| {
            if (entry.close_request != null and !entry.close_completed) count += 1;
        };
        return count;
    }

    pub fn hasBindings(self: *const Controller) bool {
        for (self.bindings) |slot| if (slot != null) return true;
        return false;
    }

    pub fn closesSettled(self: *Controller) bool {
        return self.pendingCloses() == 0 or self.connection.status().phase == .ended;
    }

    /// Release aggregate reservations after pane polling finishes a job.
    pub fn reconcile(self: *Controller) void {
        if (self.snapshot_bytes == 0) return;
        for (&self.bindings) |*slot| if (slot.*) |*entry| {
            const node = entry.node orelse continue;
            if (entry.job != null and node.content.terminal.session_snapshot != entry.job) self.releaseSnapshot(entry);
        };
    }

    pub fn step(self: *Controller) !Step {
        if (self.failure != null) return .idle;
        const message = self.pending orelse self.connection.poll() orelse return .idle;
        self.pending = null;
        const result = self.route(message) catch |err| {
            if (err == error.ResourceExhausted) {
                self.pending = message; // Ownership retained; retry after pane polling.
                return .blocked;
            }
            message.deinit();
            self.failure = err;
            self.detachViews();
            self.connection.close(); // Processes remain owned by the host.
            return err;
        };
        switch (result) {
            .control => return .{ .control = message },
            .consumed => message.deinit(),
            .transferred => {},
        }
        return .dispatched;
    }

    const Route = enum { consumed, transferred, control };

    fn route(self: *Controller, message: transport.Message) !Route {
        switch (message.kind) {
            .welcome => return .consumed,
            .reply => {
                const parsed = try p.parse(p.Reply, self.allocator, message.payload);
                defer parsed.deinit();
                if (self.layout_request == parsed.value.id) {
                    self.layout_request = null;
                    if (parsed.value.ok) {
                        self.revision = parsed.value.revision orelse return error.InvalidRevision;
                    } else {
                        self.layout_conflict = if (parsed.value.@"error") |reason| std.mem.eql(u8, reason, "RevisionConflict") else false;
                        self.layout_failure = if (self.layout_conflict) error.RevisionConflict else error.LayoutRejected;
                    }
                }
                if (parsed.value.ok) if (parsed.value.revision) |revision| {
                    self.revision = revision;
                };
                if (self.kill_request == parsed.value.id and !parsed.value.ok) self.kill_request = null;
                if (parsed.value.ok) if (parsed.value.session) |session| {
                    const id = try self.allocator.dupe(u8, session.id);
                    if (self.generation != 0 and self.generation != message.generation) {
                        self.detachViews();
                        self.clearViewLinks();
                        self.bindings = @splat(null);
                    }
                    self.allocator.free(self.session_id);
                    self.session_id = id;
                    self.generation = message.generation;
                    self.revision = session.revision;
                    self.detached = false;
                };
                for (&self.bindings) |*slot| if (slot.*) |*entry| {
                    if (entry.respawn_request != parsed.value.id) continue;
                    // Revive before any new output is read; the reply precedes it.
                    if (parsed.value.ok) if (entry.node) |node| {
                        node.content.terminal.pty.?.session.status = null;
                    };
                    break;
                };
                for (&self.bindings) |*slot| if (slot.*) |*entry| {
                    if (entry.close_request != parsed.value.id) continue;
                    entry.close_completed = true;
                    if (!parsed.value.ok) {
                        if (entry.node) |node| {
                            node.content.terminal.pty.?.session.close_request = null;
                        } else return error.RemoteCloseFailed;
                    }
                    if (entry.node == null) slot.* = null;
                    break;
                };
                return .control;
            },
            .event => {
                const parsed = try p.parse(p.Event, self.allocator, message.payload);
                defer parsed.deinit();
                if (parsed.value.event == .resync) {
                    const entry = self.byPane(parsed.value.pane orelse return error.InvalidPane) orelse return error.PaneNotFound;
                    if (entry.node) |node| {
                        const pty = &node.content.terminal.pty.?.session;
                        const dropped = pty.discardOutput();
                        if (dropped > 0) try self.connection.consumedBytes(pty.generation, pty.pane, dropped);
                        try self.beginSnapshot(entry);
                    }
                } else self.detachViews();
                return .control;
            },
            .output, .snapshot, .snapshot_end, .exit => {
                const entry = self.byPane(message.pane) orelse return error.PaneNotFound;
                if (entry.generation != message.generation) return .consumed;
                const node = entry.node orelse {
                    if (entry.close_request == null) return error.PaneNotFound;
                    return .consumed;
                };
                const term = &node.content.terminal;
                switch (message.kind) {
                    .output => {
                        try term.pty.?.session.offerOutput(message);
                        return .transferred;
                    },
                    .snapshot => {
                        if (entry.job != null and term.session_snapshot != entry.job) self.releaseSnapshot(entry);
                        if (message.payload.len > self.snapshot_limit -| entry.encoded_bytes) return error.SnapshotTooLarge;
                        if (message.payload.len > self.snapshot_limit -| self.snapshot_bytes) self.reconcile();
                        if (message.payload.len > self.snapshot_limit -| self.snapshot_bytes) return error.ResourceExhausted;
                        if (entry.job == null) try self.beginSnapshot(entry);
                        try entry.job.?.offer(message);
                        entry.encoded_bytes += message.payload.len;
                        self.snapshot_bytes += message.payload.len;
                        return .transferred;
                    },
                    .snapshot_end => {
                        if (entry.job == null) try self.beginSnapshot(entry);
                        entry.job.?.end();
                    },
                    .exit => {
                        term.pty.?.session.setExit(try p.decodeExit(message.payload));
                        node.invalidate(); // Shows the dead-pane footer.
                    },
                    else => unreachable,
                }
                return .consumed;
            },
            else => return error.InvalidKind,
        }
    }

    fn beginSnapshot(self: *Controller, entry: *Binding) !void {
        const node = entry.node orelse return;
        try node.content.terminal.beginSessionSnapshot(node, self.connection.status().format orelse return error.ExpectedWelcome);
        self.releaseSnapshot(entry);
        entry.job = node.content.terminal.session_snapshot;
    }

    fn releaseSnapshot(self: *Controller, entry: *Binding) void {
        self.snapshot_bytes -= entry.encoded_bytes;
        entry.encoded_bytes = 0;
        entry.job = null;
    }

    fn cancelSnapshot(self: *Controller, entry: *Binding) void {
        if (entry.node) |node| {
            const term = &node.content.terminal;
            if (term.session_snapshot) |job| job.destroy();
            term.session_snapshot = null;
        }
        self.releaseSnapshot(entry);
    }

    fn detachViews(self: *Controller) void {
        for (&self.bindings) |*slot| if (slot.*) |*entry| {
            self.cancelSnapshot(entry);
            if (entry.node) |node| {
                node.content.terminal.pty.?.session.detach();
                node.content.terminal.session_snapshot_waiting = true;
                node.invalidate();
            }
        };
        self.detached = true;
    }

    fn byNode(self: *Controller, id: usize) ?*Binding {
        for (&self.bindings) |*slot| if (slot.*) |*entry| if (entry.local_id == id) return entry;
        return null;
    }

    fn clearViewLinks(self: *Controller) void {
        for (self.bindings) |slot| if (slot) |entry| {
            if (entry.node) |node| node.content.terminal.session_view = null;
        };
    }

    fn unbindView(ctx: *anyopaque, id: usize) void {
        const self: *Controller = @ptrCast(@alignCast(ctx));
        self.unbind(id);
    }

    fn byPane(self: *Controller, id: u32) ?*Binding {
        for (&self.bindings) |*slot| if (slot.*) |*entry| if (entry.pane == id) return entry;
        return null;
    }
};
