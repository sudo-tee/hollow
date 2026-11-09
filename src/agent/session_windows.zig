//! Secured Windows owner transport. Live authority uses shared metadata,
//! attachment and delivery state; native GUI domains remain disabled.
const std = @import("std");
const windows = std.os.windows;
const pipe = @import("session_pipe_windows.zig");
const p = @import("session_protocol.zig");
const runtime = @import("session_runtime_windows.zig");
const vt = @import("session_vt.zig");
const identity = @import("session_identity_windows.zig");

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn WaitForSingleObject(windows.HANDLE, windows.DWORD) callconv(.winapi) windows.DWORD;
extern "kernel32" fn WaitForMultipleObjects(windows.DWORD, [*]const windows.HANDLE, windows.BOOL, windows.DWORD) callconv(.winapi) windows.DWORD;
extern "kernel32" fn Sleep(windows.DWORD) callconv(.winapi) void;
extern "kernel32" fn CreateEventW(?*windows.SECURITY_ATTRIBUTES, windows.BOOL, windows.BOOL, ?windows.LPCWSTR) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetEvent(windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CreateProcessW(?windows.LPCWSTR, windows.LPWSTR, ?*windows.SECURITY_ATTRIBUTES, ?*windows.SECURITY_ATTRIBUTES, windows.BOOL, windows.DWORD, ?*anyopaque, ?windows.LPCWSTR, *windows.STARTUPINFOW, *windows.PROCESS.INFORMATION) callconv(.winapi) windows.BOOL;

const timeout_ms = 5000;
const startup_grace_ms = 10_000;
const output_limit = 1024 * 1024;
const input_limit = p.control_limit + p.header_len + 64 * 1024;
const frame_batch = 64;

pub const Frame = struct { kind: p.Kind, stream: u32, payload: []const u8 };

/// Blocking, deadline-bounded fixture/command client over overlapped pipes.
/// Owns the handle, including on init failure. No request is ever replayed.
pub const Connection = struct {
    a: std.mem.Allocator,
    handle: windows.HANDLE,
    input: pipe.Operation,
    output: pipe.Operation,
    payload: std.ArrayList(u8) = .empty,

    pub fn init(a: std.mem.Allocator, handle: windows.HANDLE) !Connection {
        errdefer pipe.close(handle);
        var input = try pipe.Operation.init();
        errdefer input.deinit();
        return .{ .a = a, .handle = handle, .input = input, .output = try pipe.Operation.init() };
    }

    pub fn deinit(self: *Connection) void {
        self.input.cancel(self.handle);
        self.output.cancel(self.handle);
        pipe.close(self.handle);
        self.input.deinit();
        self.output.deinit();
        self.payload.deinit(self.a);
    }

    pub fn sendJson(self: *Connection, kind: p.Kind, value: anytype) !void {
        const bytes = try p.stringify(self.a, value);
        defer self.a.free(bytes);
        try self.send(kind, 0, bytes);
    }

    pub fn send(self: *Connection, kind: p.Kind, stream: u32, bytes: []const u8) !void {
        if (bytes.len > p.control_limit) return error.ResourceExhausted;
        _ = try p.validate(p.header(kind, stream, bytes.len), .to_owner);
        const deadline = nowMs() + timeout_ms;
        try self.writeUntil(&p.header(kind, stream, bytes.len).encode(), deadline);
        try self.writeUntil(bytes, deadline);
    }

    /// Raw writes are useful for testing malformed peers. Still bounded and
    /// never retried after a timeout or partial transmission.
    pub fn write(self: *Connection, bytes: []const u8, wait_ms: u32) !void {
        if (bytes.len > input_limit) return error.ResourceExhausted;
        try self.writeUntil(bytes, nowMs() + wait_ms);
    }

    fn writeUntil(self: *Connection, bytes: []const u8, deadline: u64) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            try self.output.write(self.handle, bytes[offset..]);
            const n = try complete(&self.output, self.handle, deadline);
            if (n == 0) return error.EndOfStream;
            offset += n;
        }
    }

    /// Payload is borrowed until the next call. Validate header before allocation.
    pub fn next(self: *Connection, wait_ms: u32) !Frame {
        const deadline = nowMs() + wait_ms;
        var raw: [p.header_len]u8 = undefined;
        try self.readExact(&raw, deadline);
        const header = try p.Header.decode(&raw);
        const kind = try p.validate(header, .to_client);
        try self.payload.resize(self.a, header.len);
        try self.readExact(self.payload.items, deadline);
        return .{ .kind = kind, .stream = header.stream, .payload = self.payload.items };
    }

    fn readExact(self: *Connection, bytes: []u8, deadline: u64) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            try self.input.read(self.handle, bytes[offset..]);
            const n = try complete(&self.input, self.handle, deadline);
            if (n == 0) return error.EndOfStream;
            offset += n;
        }
    }
};

fn complete(operation: *pipe.Operation, handle: windows.HANDLE, deadline: u64) !usize {
    errdefer operation.cancel(handle);
    while (true) {
        if (try operation.result(handle)) |n| return n;
        const now = nowMs();
        if (now >= deadline) return error.Timeout;
        const result = WaitForSingleObject(operation.event, @intCast(@min(deadline - now, std.math.maxInt(u32))));
        if (result == 258) return error.Timeout;
        if (result != 0) return error.WaitFailed;
    }
}

const Slot = struct {
    a: std.mem.Allocator = undefined,
    client: runtime.Client = undefined,
    handle: ?windows.HANDLE = null,
    input: pipe.Operation = undefined,
    output: pipe.Operation = undefined,
    accepting: bool = true,
    reading: bool = false,
    writing: bool = false,
    greeted: bool = false,
    read_buffer: [64 * 1024]u8 = undefined,
    reader: p.Reader = .{},
    queued: std.ArrayList(u8) = .empty,
    // Active writes borrow this immutable allocation, never the growing queue.
    sending: []u8 = &.{},
    sent: usize = 0,
    read_deadline: u64 = 0,
    write_deadline: u64 = 0,

    fn init(self: *Slot, a: std.mem.Allocator, endpoint: *const pipe.Endpoint, first: bool) !void {
        self.input = try pipe.Operation.init();
        errdefer self.input.deinit();
        self.output = try pipe.Operation.init();
        errdefer self.output.deinit();
        const handle = try endpoint.server(first);
        errdefer pipe.close(handle);
        try self.input.accept(handle);
        self.handle = handle;
        self.a = a;
        self.client = .{ .context = self, .send_fn = enqueue };
    }

    /// An active OVERLAPPED write borrows `sending`, never this growing queue.
    fn enqueue(context: *anyopaque, kind: p.Kind, stream: u32, bytes: []const u8) !void {
        const self: *Slot = @ptrCast(@alignCast(context));
        if (self.accepting or self.client.dead) return error.Disconnected;
        _ = try p.validate(p.header(kind, stream, bytes.len), .to_client);
        const used = self.queued.items.len + self.sending.len - self.sent;
        if (used > output_limit - p.header_len or bytes.len > output_limit - p.header_len - used)
            return error.ResourceExhausted;
        try self.queued.ensureUnusedCapacity(self.a, p.header_len + bytes.len);
        self.queued.appendSliceAssumeCapacity(&p.header(kind, stream, bytes.len).encode());
        self.queued.appendSliceAssumeCapacity(bytes);
    }

    fn clear(self: *Slot, a: std.mem.Allocator, reuse: bool) void {
        const handle = self.handle orelse return;
        self.input.cancel(handle);
        self.output.cancel(handle);
        // Disconnect discards unread bytes. Reuse needs it; final handle close
        // must instead leave buffered replies available for a delayed reader.
        if (reuse) pipe.disconnect(handle);
        self.reader.deinit(a);
        self.reader = .{};
        self.queued.deinit(a);
        self.queued = .empty;
        a.free(self.sending);
        self.sending = &.{};
        self.sent = 0;
        self.accepting = true;
        self.reading = false;
        self.writing = false;
        self.greeted = false;
        self.client = .{ .context = self, .send_fn = enqueue };
    }

    fn deinit(self: *Slot, a: std.mem.Allocator) void {
        const handle = self.handle orelse return;
        self.clear(a, false);
        pipe.close(handle);
        self.input.deinit();
        self.output.deinit();
        self.handle = null;
    }
};

const Owner = struct {
    a: std.mem.Allocator,
    slots: [pipe.max_clients]Slot = @splat(.{}),
    connected_once: bool = false,
    stopping: bool = false,
    stop_deadline: u64 = 0,
    startup_deadline: u64,
    wake_event: windows.HANDLE,
    sessions: runtime.Owner,
    host: [32]u8,

    fn create(a: std.mem.Allocator, endpoint: *const pipe.Endpoint) !*Owner {
        // Slot buffers and pending OVERLAPPED values have stable heap addresses.
        const self = try a.create(Owner);
        const wake_event = CreateEventW(null, .FALSE, .FALSE, null) orelse {
            a.destroy(self);
            return error.ResourceExhausted;
        };
        self.* = .{
            .a = a,
            .startup_deadline = nowMs() + startup_grace_ms,
            .wake_event = wake_event,
            .host = identity.random(@import("../io.zig").get()),
            .sessions = runtime.Owner.init(a, .{ .context = self, .callback = wake }),
        };
        errdefer self.destroy();
        for (&self.slots, 0..) |*slot, i| try slot.init(a, endpoint, i == 0);
        return self;
    }

    fn wake(context: *anyopaque) void {
        const self: *Owner = @ptrCast(@alignCast(context));
        _ = SetEvent(self.wake_event);
    }

    fn destroy(self: *Owner) void {
        self.sessions.deinit();
        for (&self.slots) |*slot| slot.deinit(self.a);
        pipe.close(self.wake_event);
        self.a.destroy(self);
    }

    fn queue(self: *Owner, slot: *Slot, kind: p.Kind, value: anytype) !void {
        const bytes = try p.stringify(self.a, value);
        defer self.a.free(bytes);
        try Slot.enqueue(slot, kind, 0, bytes);
    }

    fn frame(self: *Owner, slot: *Slot, header: p.Header, bytes: []const u8) !void {
        const kind = try p.validate(header, .to_owner);
        if (!slot.greeted and kind != .hello) return error.ExpectedHello;
        switch (kind) {
            .hello => {
                if (slot.greeted) return error.DuplicateHello;
                const hello = try p.parse(p.Hello, self.a, bytes);
                defer hello.deinit();
                if (!std.mem.eql(u8, hello.value.protocol, p.protocol) or hello.value.version != p.version) return error.ProtocolMismatch;
                slot.greeted = true;
                slot.client.binary = std.mem.eql(u8, hello.value.ghostty, vt.buildIdentity());
                slot.client.foreground_events = hello.value.foreground_events;
                try self.queue(slot, .welcome, p.Welcome{
                    .ghostty = vt.buildIdentity(),
                    .snapshot = if (slot.client.binary) .binary else .vt,
                    .owner_pid = windows.GetCurrentProcessId(),
                    .host = &self.host,
                    .features = &.{"create-id"},
                });
            },
            .request => {
                const request = try p.parse(p.Request, self.a, bytes);
                defer request.deinit();
                switch (request.value.op) {
                    .kill_server => {
                        // Admit the acknowledgement before irreversible process
                        // teardown; a failed admission must not become a partial
                        // "kill sessions but keep serving" operation.
                        try self.queue(slot, .reply, p.Reply{ .id = request.value.id });
                        self.stopping = true;
                        self.sessions.killAll();
                        self.stop_deadline = nowMs() + 2000;
                    },
                    else => self.sessions.request(&slot.client, &request.value),
                }
            },
            else => try self.sessions.frame(&slot.client, kind, header.stream, bytes),
        }
    }

    /// Budget parsing independently from reads; never wait on a pipe when a
    /// complete retained frame still needs work. Reject bad headers immediately.
    fn frames(self: *Owner, slot: *Slot) !bool {
        for (0..frame_batch) |_| {
            const available = slot.reader.buffer.items[slot.reader.start..];
            if (available.len < p.header_len) return false;
            const header = try p.Header.decode(available[0..p.header_len]);
            _ = try p.validate(header, .to_owner);
            const next = (try slot.reader.next()) orelse return false;
            try self.frame(slot, next.header, next.payload);
            if (slot.client.dead) return error.Disconnected;
            if (self.stopping) return false;
        }
        const rest = slot.reader.buffer.items[slot.reader.start..];
        if (rest.len < p.header_len) return false;
        const header = try p.Header.decode(rest[0..p.header_len]);
        _ = try p.validate(header, .to_owner);
        return rest.len - p.header_len >= header.len;
    }

    fn reset(self: *Owner, slot: *Slot) !void {
        self.sessions.disconnect(&slot.client);
        slot.clear(self.a, true);
        if (!self.stopping) try slot.input.accept(slot.handle.?);
    }

    fn pump(self: *Owner, slot: *Slot, now: u64) !bool {
        const handle = slot.handle.?;
        if (slot.accepting) {
            if (self.stopping) return false;
            if (try slot.input.result(handle)) |_| {
                slot.accepting = false;
                self.connected_once = true;
                slot.read_deadline = now + timeout_ms;
            } else return false;
        }
        if (!self.stopping and slot.reading) {
            if (try slot.input.result(handle)) |n| {
                slot.reading = false;
                if (n == 0) return error.EndOfStream;
                if (slot.reader.buffered() + n > input_limit) return error.ResourceExhausted;
                if (slot.greeted and slot.reader.buffered() == 0) slot.read_deadline = now + timeout_ms;
                try slot.reader.push(self.a, slot.read_buffer[0..n]);
            }
        }
        var more = false;
        if (!self.stopping and !slot.reading) {
            more = try self.frames(slot);
            if (!more and !self.stopping) {
                if (slot.reader.buffered() > 0 or !slot.greeted) {
                    if (now >= slot.read_deadline) return error.Timeout;
                } else slot.read_deadline = now + timeout_ms;
                try slot.input.read(handle, &slot.read_buffer);
                slot.reading = true;
            }
        }
        // Timeout stalled partial frames/hellos even while their read is pending.
        if (!self.stopping and (!slot.greeted or slot.reader.buffered() > 0) and now >= slot.read_deadline) return error.Timeout;
        if (slot.writing) {
            if (try slot.output.result(handle)) |n| {
                if (n == 0) return error.EndOfStream;
                slot.writing = false;
                slot.sent += n;
                // Runtime may retain a snapshot/output suffix behind this
                // transport limit. Completion releases capacity, so retry it
                // before sleeping even when no further PTY event will arrive.
                more = true;
                if (slot.sent == slot.sending.len) {
                    self.a.free(slot.sending);
                    slot.sending = &.{};
                    slot.sent = 0;
                }
            }
            if (slot.sending.len > 0 and now >= slot.write_deadline) return error.Timeout;
        }
        if (!slot.writing) {
            if (slot.sending.len == 0 and slot.queued.items.len > 0) {
                slot.sending = try slot.queued.toOwnedSlice(self.a);
                slot.write_deadline = nowMs() + timeout_ms;
            }
            if (slot.sending.len > 0) {
                try slot.output.write(handle, slot.sending[slot.sent..]);
                slot.writing = true;
            }
        }
        return more;
    }

    fn run(self: *Owner) !void {
        while (true) {
            const now = nowMs();
            var more = if (self.stopping) false else self.sessions.tick(now);
            for (&self.slots) |*slot| more = (self.pump(slot, now) catch blk: {
                try self.reset(slot);
                break :blk false;
            }) or more;
            var active: usize = 0;
            var writes: usize = 0;
            var events: [pipe.max_clients * 2 + 1]windows.HANDLE = undefined;
            events[0] = self.wake_event;
            var count: usize = 1;
            var deadline = if (self.stopping) self.stop_deadline else if (!self.connected_once) self.startup_deadline else std.math.maxInt(u64);
            if (!self.stopping) {
                if (self.sessions.deadline()) |next| deadline = @min(deadline, next);
            }
            for (&self.slots) |*slot| {
                if (slot.client.dead) try self.reset(slot);
                if (!slot.accepting) {
                    active += 1;
                    if (!slot.greeted or slot.reader.buffered() > 0) deadline = @min(deadline, slot.read_deadline);
                }
                if (self.stopping) {
                    slot.input.cancel(slot.handle.?);
                } else if (slot.accepting or slot.reading) {
                    events[count] = slot.input.event;
                    count += 1;
                }
                if (slot.writing) {
                    writes += 1;
                    deadline = @min(deadline, slot.write_deadline);
                    events[count] = slot.output.event;
                    count += 1;
                }
            }
            if (self.stopping and (writes == 0 or now >= self.stop_deadline)) return;
            if (!self.stopping and !self.sessions.hasSessions() and
                ((self.connected_once and active == 0) or (!self.connected_once and now >= self.startup_deadline))) return;
            if (more) continue;
            const wait_ms: u32 = @intCast(@min(deadline -| nowMs(), std.math.maxInt(u32)));
            const result = WaitForMultipleObjects(@intCast(count), &events, .FALSE, wait_ms);
            if (result == 0xffffffff) return error.WaitFailed;
        }
    }
};

pub fn serve(a: std.mem.Allocator, _: std.Io, namespace: ?[]const u8) !void {
    var endpoint = try pipe.Endpoint.init(a, namespace);
    defer endpoint.deinit(a);
    const owner = try Owner.create(a, &endpoint);
    defer owner.destroy();
    // Private fixture namespaces never read or mutate production host state.
    if (namespace == null) owner.host = try identity.loadDefault(a, @import("../io.zig").get(), @import("../io.zig").environ(), &endpoint);
    try owner.run();
}

/// Starts only the owner, never a create/spawn request. Access/security failures
/// are not mistaken for absence; busy owners are waited for, not replaced.
pub fn connectOrStart(a: std.mem.Allocator, _: std.Io, namespace: ?[]const u8, exe_path: []const u8) !windows.HANDLE {
    var endpoint = try pipe.Endpoint.init(a, namespace);
    defer endpoint.deinit(a);
    var busy = false;
    if (endpoint.connect() catch |err| switch (err) {
        error.PipeBusy => blk: {
            busy = true;
            break :blk null;
        },
        else => return err,
    }) |handle| return handle;
    if (!busy) try startOwner(a, namespace, exe_path);
    const deadline = nowMs() + timeout_ms;
    while (nowMs() < deadline) {
        if (endpoint.connect() catch |err| switch (err) {
            error.PipeBusy => null,
            else => return err,
        }) |handle| return handle;
        Sleep(10);
    }
    return error.OwnerStartTimeout;
}

fn startOwner(a: std.mem.Allocator, namespace: ?[]const u8, exe_path: []const u8) !void {
    if (exe_path.len == 0 or exe_path.len > 32 * 1024) return error.InvalidArgument;
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(a);
    try appendArg(a, &command, exe_path);
    try command.appendSlice(a, " session serve");
    if (namespace) |name| {
        try command.appendSlice(a, " --namespace ");
        try appendArg(a, &command, name);
    }
    const application = try std.unicode.utf8ToUtf16LeAllocZ(a, exe_path);
    defer a.free(application);
    const line = try std.unicode.utf8ToUtf16LeAllocZ(a, command.items);
    defer a.free(line);
    var startup = std.mem.zeroes(windows.STARTUPINFOW);
    startup.cb = @sizeOf(windows.STARTUPINFOW);
    var process = std.mem.zeroes(windows.PROCESS.INFORMATION);
    // Do not silently retry without BREAKAWAY: that owner would die with GUI.
    if (CreateProcessW(application.ptr, line.ptr, null, null, .FALSE, 0x00000008 | 0x01000000 | 0x00000400, null, null, &startup, &process) == .FALSE) {
        std.log.warn("session owner startup failed: {t} ({s})", .{ windows.GetLastError(), exe_path });
        return error.OwnerStartFailed;
    }
    pipe.close(process.hThread);
    pipe.close(process.hProcess);
}

fn appendArg(a: std.mem.Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
    try out.append(a, '"');
    var slashes: usize = 0;
    for (arg) |ch| switch (ch) {
        '\\' => slashes += 1,
        '"' => {
            try out.appendNTimes(a, '\\', slashes * 2 + 1);
            try out.append(a, '"');
            slashes = 0;
        },
        else => {
            try out.appendNTimes(a, '\\', slashes);
            try out.append(a, ch);
            slashes = 0;
        },
    };
    try out.appendNTimes(a, '\\', slashes * 2);
    try out.append(a, '"');
}

pub fn nowMs() u64 {
    return GetTickCount64();
}

test "Windows owner launcher quotes paths and trailing backslashes" {
    const a = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    try appendArg(a, &text, "C:\\Program Files\\Hollow\\");
    try std.testing.expectEqualStrings("\"C:\\Program Files\\Hollow\\\\\"", text.items);
    text.clearRetainingCapacity();
    try appendArg(a, &text, "a\"b");
    try std.testing.expectEqualStrings("\"a\\\"b\"", text.items);
}

test "Windows frame admission includes active write and never queues a partial header" {
    const a = std.testing.allocator;
    var slot: Slot = .{ .a = a, .accepting = false };
    slot.client = .{ .context = &slot, .send_fn = Slot.enqueue };
    slot.sending = try a.alloc(u8, output_limit - p.header_len);
    defer a.free(slot.sending);
    defer slot.queued.deinit(a);
    try std.testing.expectError(error.ResourceExhausted, Slot.enqueue(&slot, .output, 1, "x"));
    try std.testing.expectEqual(@as(usize, 0), slot.queued.items.len);
    // Credit for completed bytes permits new admission, without changing the
    // immutable buffer still borrowed by the overlapped write.
    slot.sent = 1;
    try Slot.enqueue(&slot, .output, 1, "x");
    try std.testing.expectEqual(p.header_len + 1, slot.queued.items.len);

    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var rejected: Slot = .{ .a = failing.allocator(), .accepting = false };
    rejected.client = .{ .context = &rejected, .send_fn = Slot.enqueue };
    defer rejected.queued.deinit(failing.allocator());
    try std.testing.expectError(error.OutOfMemory, Slot.enqueue(&rejected, .output, 1, "x"));
    try std.testing.expectEqual(@as(usize, 0), rejected.queued.items.len);
}
