//! GUI-thread pane adapter. Workspace controller owns the connection and routes
//! output/exit/snapshot messages. Deinit releases the local view only; explicit
//! requestClose must be accepted before removing a pane. Keep the connection
//! alive until that close reply (or terminal connection failure) is observed.
const std = @import("std");
const io = @import("../io.zig");
const transport = @import("../session/transport.zig");
const frames = @import("../session/client.zig");
const p = transport.p;

pub const SessionPty = struct {
    allocator: std.mem.Allocator,
    connection: *transport.Connection, // borrowed from workspace controller
    pane: u32,
    generation: u64,
    output: frames.Queue = .{},
    current: ?transport.Message = null,
    offset: usize = 0,
    unparsed: usize = 0,
    status: ?i32 = null,
    close_on_exit: bool = false,
    detached: bool = false,
    close_request: ?u64 = null,
    pending_resize: ?struct { cols: u16, rows: u16 } = null,

    pub fn init(a: std.mem.Allocator, connection: *transport.Connection, pane: u32, generation: u64, status: ?i32) SessionPty {
        return .{ .allocator = a, .connection = connection, .pane = pane, .generation = generation, .status = status };
    }

    /// On success this adapter owns output messages. Other kinds are only
    /// inspected; caller retains them. Old attachment messages are rejected.
    pub fn offerOutput(self: *SessionPty, message: transport.Message) !void {
        if (message.kind != .output) return error.InvalidKind;
        if (message.payload.len > p.max_data) return error.PayloadTooLarge;
        if (message.pane != self.pane or message.generation != self.generation or self.detached) return error.Detached;
        if (self.pendingOutputBytes() + self.unparsed + message.payload.len > frames.pane_receive_ahead) return error.ResourceExhausted;
        try self.output.append(self.allocator, message);
    }

    /// Drops output queued before a resync: the owner's snapshot already
    /// contains it, and parsing it after READY would replay stale screens.
    /// Returns the dropped byte count so receive-ahead can be released.
    pub fn discardOutput(self: *SessionPty) usize {
        const dropped = self.pendingOutputBytes();
        if (self.current) |message| message.deinit();
        self.current = null;
        self.offset = 0;
        while (self.output.pop()) |message| message.deinit();
        return dropped;
    }

    pub fn setExit(self: *SessionPty, status: i32) void {
        self.status = status;
    }

    pub fn detach(self: *SessionPty) void {
        self.detached = true;
    }

    pub fn requestClose(self: *SessionPty) !u64 {
        if (self.detached) return error.Detached;
        if (self.close_request) |id| return id;
        const id = try self.connection.closePane(self.generation, self.pane);
        self.close_request = id;
        return id;
    }

    /// PTY facade compatibility. Controllers should use requestClose so queue
    /// pressure is surfaced and the pane is not removed before admission.
    pub fn close(self: *SessionPty) void {
        _ = self.requestClose() catch |err| {
            std.log.warn("session pane close was not queued: {s}", .{@errorName(err)});
        };
    }

    pub fn deinit(self: *SessionPty) void {
        if (self.current) |message| message.deinit();
        self.output.deinit(self.allocator);
        self.current = null;
        self.output = .{};
        self.detached = true;
    }

    pub fn read(self: *SessionPty, buffer: []u8) !usize {
        self.flushResize();
        if (buffer.len == 0) return 0;
        // Transport frame boundaries are not parser work boundaries. Small
        // PTY reads must not turn the GUI's bounded read-loop count into a
        // much smaller byte quota than an ordinary PTY's contiguous buffer.
        var copied: usize = 0;
        while (copied < buffer.len) {
            if (self.current == null) self.current = self.output.pop();
            const message = self.current orelse break;
            const n = @min(buffer.len - copied, message.payload.len - self.offset);
            @memcpy(buffer[copied..][0..n], message.payload[self.offset..][0..n]);
            self.offset += n;
            copied += n;
            if (self.offset == message.payload.len) {
                message.deinit();
                self.current = null;
                self.offset = 0;
            }
        }
        self.unparsed += copied;
        if (copied > 0) return copied;
        if (!self.isAlive()) return error.EndOfStream;
        return 0;
    }

    /// Return credit after the bytes have passed through the terminal parser.
    /// Admission failure is retryable: unparsed remains unchanged.
    pub fn parsed(self: *SessionPty, count: usize) !void {
        if (count > self.unparsed) return error.InvalidCredit;
        if (self.detached) {
            self.unparsed -= count;
            return;
        }
        try self.connection.consumedBytes(self.generation, self.pane, count);
        self.unparsed -= count;
    }

    pub fn isAlive(self: *SessionPty) bool {
        return !self.detached and self.status == null and self.connection.status().phase != .ended;
    }

    pub fn exitStatus(self: *const SessionPty) ?u32 {
        const status = self.status orelse return null;
        return @intCast(if (status >= 0) @as(i64, status) else 128 - @as(i64, status));
    }

    pub fn childPid(_: *const SessionPty) usize {
        return 0;
    }

    pub fn hasPendingOutput(self: *SessionPty) bool {
        return self.pendingOutputBytes() > 0;
    }

    pub fn pendingOutputBytes(self: *SessionPty) usize {
        return self.output.bytes + if (self.current) |message| message.payload.len - self.offset else 0;
    }

    pub fn hasPendingOutputOrExit(self: *SessionPty) bool {
        return self.hasPendingOutput() or !self.isAlive();
    }

    pub fn writeAll(self: *SessionPty, bytes: []const u8) !void {
        if (!self.isAlive() or self.close_request != null) return error.EndOfStream;
        self.flushResize();
        try self.connection.input(self.generation, self.pane, bytes);
    }

    pub fn writeAllUntil(self: *SessionPty, bytes: []const u8, deadline: i128) !usize {
        if (io.nanoTimestamp() >= deadline) return 0;
        try self.writeAll(bytes);
        return bytes.len;
    }

    pub fn resize(self: *SessionPty, cols: u16, rows: u16) void {
        if (self.detached) return;
        self.pending_resize = .{ .cols = cols, .rows = rows };
        self.flushResize();
    }

    fn flushResize(self: *SessionPty) void {
        if (self.detached) {
            self.pending_resize = null;
            return;
        }
        const size = self.pending_resize orelse return;
        self.connection.resize(self.generation, self.pane, size.cols, size.rows) catch |err| {
            if (err != error.ResourceExhausted and err != error.OutOfMemory) self.pending_resize = null;
            return;
        };
        self.pending_resize = null;
    }
};
