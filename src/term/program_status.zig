const std = @import("std");
const ghostty = @import("ghostty.zig");

pub const StateKind = enum(c_int) { idle, working, done, blocked, failure };
pub const BlockKind = enum(c_int) { none, permission, question, auth };

pub const Record = struct {
    id: []const u8,
    state: StateKind,
    kind: BlockKind,
    progress: i8,
    app: []const u8,
    title: []const u8,
    message: []const u8,
    attention: bool = false,

    fn deinit(self: Record, allocator: std.mem.Allocator) void {
        inline for (.{ "id", "app", "title", "message" }) |field| allocator.free(@field(self, field));
    }

    pub fn stateName(self: Record) []const u8 {
        return if (self.state == .failure) "error" else @tagName(self.state);
    }
};

/// Bounded, owned state. Parser callbacks never invoke Lua or retain borrowed bytes.
pub const State = struct {
    pub const max_records = 128;
    records: std.ArrayListUnmanaged(Record) = .empty,
    dirty: bool = false,
    focused: bool = false,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.records.items) |record| record.deinit(allocator);
        self.records.deinit(allocator);
        self.* = .{};
    }

    pub fn apply(self: *State, allocator: std.mem.Allocator, report: *const ghostty.ProgramStatus) !void {
        const id = report.id.slice();
        if (id.len > 256) return error.IdTooLong;
        if (report.state == 5) {
            var i: usize = 0;
            while (i < self.records.items.len) {
                if (isDescendant(self.records.items[i].id, id)) self.remove(allocator, i) else i += 1;
            }
            return;
        }
        const state = std.enums.fromInt(StateKind, report.state) orelse return;
        const owned_id = try allocator.dupe(u8, id);
        errdefer allocator.free(owned_id);
        const app = try displayText(allocator, report.app.slice(), 256);
        errdefer allocator.free(app);
        const title = try displayText(allocator, report.title.slice(), 512);
        errdefer allocator.free(title);
        const message = try displayText(allocator, report.message.slice(), 2048);
        errdefer allocator.free(message);
        // Reserve before changing existing state, including on replacement/eviction.
        try self.records.ensureUnusedCapacity(allocator, 1);
        for (self.records.items, 0..) |record, i| {
            if (std.mem.eql(u8, record.id, id)) {
                self.remove(allocator, i);
                break;
            }
        }
        if (self.records.items.len == max_records) self.remove(allocator, 0);
        self.records.appendAssumeCapacity(.{
            .id = owned_id,
            .state = state,
            .kind = if (state == .blocked) std.enums.fromInt(BlockKind, report.kind) orelse .none else .none,
            .progress = if ((state == .working or state == .blocked) and report.progress >= 0 and report.progress <= 100) report.progress else -1,
            .app = app,
            .title = title,
            .message = message,
            .attention = !self.focused and (state == .blocked or state == .failure),
        });
        self.dirty = true;
    }

    pub fn effectiveApp(self: *const State, record: Record) []const u8 {
        if (record.app.len > 0) return record.app;
        var best: []const u8 = "";
        var best_len: usize = 0;
        for (self.records.items) |parent| {
            if (parent.app.len > 0 and parent.id.len < record.id.len and
                isDescendant(record.id, parent.id) and (best.len == 0 or parent.id.len >= best_len))
            {
                best = parent.app;
                best_len = parent.id.len;
            }
        }
        return best;
    }

    /// Prompt return ends transient activity, not outstanding attention.
    /// Blocked reports must remain discoverable from other workspaces until
    /// the program replaces/clears them or the child exits.
    pub fn endCommand(self: *State, allocator: std.mem.Allocator) void {
        var i: usize = 0;
        while (i < self.records.items.len) {
            const state = self.records.items[i].state;
            if (state == .working or state == .idle) self.remove(allocator, i) else i += 1;
        }
    }

    pub fn childExited(self: *State, allocator: std.mem.Allocator) void {
        self.endCommand(allocator);
        var i: usize = 0;
        while (i < self.records.items.len) {
            if (self.records.items[i].state == .blocked) self.remove(allocator, i) else i += 1;
        }
    }

    /// Focus acknowledges unread attention, never the underlying task status.
    pub fn setFocused(self: *State, focused: bool) void {
        self.focused = focused;
        if (!focused) return;
        for (self.records.items) |*record| {
            if (record.attention) {
                record.attention = false;
                self.dirty = true;
            }
        }
    }

    pub fn needsAttention(self: *const State) bool {
        for (self.records.items) |record| if (record.attention) return true;
        return false;
    }

    fn remove(self: *State, allocator: std.mem.Allocator, index: usize) void {
        self.records.orderedRemove(index).deinit(allocator);
        self.dirty = true;
    }
};

fn isDescendant(id: []const u8, parent: []const u8) bool {
    return parent.len == 0 or std.mem.eql(u8, id, parent) or
        (id.len > parent.len and id[parent.len] == '/' and std.mem.startsWith(u8, id, parent));
}

fn displayText(allocator: std.mem.Allocator, text: []const u8, max_bytes: usize) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepointSlice()) |bytes| {
        const cp = try std.unicode.utf8Decode(bytes);
        // Strip controls and invisible formatting (including bidi spoofing).
        if (cp < 32 or (cp >= 127 and cp <= 159) or cp == 0x061c or
            (cp >= 0x200b and cp <= 0x200f) or (cp >= 0x202a and cp <= 0x202e) or
            (cp >= 0x2060 and cp <= 0x206f) or cp == 0xfeff) continue;
        if (out.items.len + bytes.len > max_bytes) break;
        try out.appendSlice(allocator, bytes);
    }
    return out.toOwnedSlice(allocator);
}

fn testReport(id: []const u8, state: c_int, app: []const u8) ghostty.ProgramStatus {
    return .{
        .state = state,
        .kind = 0,
        .progress = -1,
        .id = .{ .ptr = id.ptr, .len = id.len },
        .app = .{ .ptr = app.ptr, .len = app.len },
        .title = .{ .ptr = null, .len = 0 },
        .message = .{ .ptr = null, .len = 0 },
    };
}

test "program status replaces records, inherits app, and clears subtrees only" {
    const a = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(a);
    try state.apply(a, &testReport("", 1, "deploy"));
    try state.apply(a, &testReport("build", 1, "compiler"));
    try state.apply(a, &testReport("build/test", 3, ""));
    try state.apply(a, &testReport("builder", 1, ""));
    try std.testing.expectEqualStrings("compiler", state.effectiveApp(state.records.items[2]));
    try state.apply(a, &testReport("build", 2, ""));
    try std.testing.expectEqualStrings("deploy", state.effectiveApp(state.records.items[1]));
    try state.apply(a, &testReport("build", 5, ""));
    try std.testing.expectEqual(@as(usize, 2), state.records.items.len);
    try std.testing.expectEqualStrings("builder", state.records.items[1].id);
    try state.apply(a, &testReport("", 5, ""));
    try std.testing.expectEqual(@as(usize, 0), state.records.items.len);
}

test "program status lifecycle and untrusted labels" {
    const a = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(a);
    var r = testReport("work", 3, "tool\xe2\x80\xae\n");
    r.kind = 1;
    r.progress = 25;
    try state.apply(a, &r);
    try state.apply(a, &testReport("done", 2, ""));
    try state.apply(a, &testReport("error", 4, ""));
    try std.testing.expectEqualStrings("tool", state.records.items[0].app);
    try std.testing.expectEqual(BlockKind.permission, state.records.items[0].kind);
    state.endCommand(a);
    try std.testing.expectEqual(@as(usize, 3), state.records.items.len);
    state.setFocused(true);
    try std.testing.expectEqual(@as(usize, 3), state.records.items.len);
    try std.testing.expectEqual(StateKind.blocked, state.records.items[0].state);
    try std.testing.expect(!state.needsAttention());
    state.childExited(a);
    try std.testing.expectEqual(@as(usize, 2), state.records.items.len);
}

test "attention is independent of records and re-arms only on inactive reports" {
    const a = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(a);
    try state.apply(a, &testReport("approval", 3, "demo"));
    try state.apply(a, &testReport("failed", 4, "demo"));
    try state.apply(a, &testReport("done", 2, "demo"));
    try std.testing.expect(state.needsAttention());
    state.dirty = false;
    state.setFocused(true);
    try std.testing.expect(state.dirty);
    try std.testing.expect(!state.needsAttention());
    try std.testing.expectEqual(@as(usize, 3), state.records.items.len);
    try std.testing.expectEqual(StateKind.blocked, state.records.items[0].state);
    try std.testing.expectEqual(StateKind.failure, state.records.items[1].state);
    state.dirty = false;
    state.setFocused(true);
    try std.testing.expect(!state.dirty);
    try state.apply(a, &testReport("approval", 3, "updated"));
    try state.apply(a, &testReport("failed", 4, "updated"));
    try std.testing.expect(!state.needsAttention());
    state.setFocused(false);
    try std.testing.expect(!state.needsAttention()); // Leaving does not re-arm old reports.
    try state.apply(a, &testReport("approval", 3, "new report"));
    try std.testing.expect(state.needsAttention());
    try state.apply(a, &testReport("approval", 1, "resolved"));
    try std.testing.expect(!state.needsAttention());
    try state.apply(a, &testReport("failed", 4, "new failure"));
    try std.testing.expect(state.needsAttention());
    try state.apply(a, &testReport("failed", 5, ""));
    try std.testing.expect(!state.needsAttention());
}

test "prompt return preserves blocked and error attention until explicit replacement or clear" {
    const a = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(a);
    try state.apply(a, &testReport("work", 1, ""));
    try state.apply(a, &testReport("idle", 0, ""));
    try state.apply(a, &testReport("permission", 3, ""));
    try state.apply(a, &testReport("error", 4, ""));
    state.endCommand(a);
    state.endCommand(a); // Prompt redraws must not dismiss attention either.
    try std.testing.expectEqual(@as(usize, 2), state.records.items.len);
    try std.testing.expectEqual(StateKind.blocked, state.records.items[0].state);
    try std.testing.expectEqual(StateKind.failure, state.records.items[1].state);
    try state.apply(a, &testReport("permission", 2, ""));
    try std.testing.expectEqual(StateKind.done, state.records.items[1].state);
    try state.apply(a, &testReport("", 5, ""));
    try std.testing.expectEqual(@as(usize, 0), state.records.items.len);
}

test "program status evicts least recently updated record" {
    const a = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(a);
    for (0..State.max_records) |i| {
        var buf: [32]u8 = undefined;
        try state.apply(a, &testReport(try std.fmt.bufPrint(&buf, "{d}", .{i}), 1, ""));
    }
    try state.apply(a, &testReport("0", 2, ""));
    try state.apply(a, &testReport("new", 1, ""));
    try std.testing.expectEqual(State.max_records, state.records.items.len);
    try std.testing.expectEqualStrings("2", state.records.items[0].id);
}

test "program status remains valid under allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            var state: State = .{};
            defer state.deinit(a);
            try state.apply(a, &testReport("", 1, "build"));
            state.apply(a, &testReport("", 2, "done")) catch |err| {
                try std.testing.expectEqualStrings("build", state.records.items[0].app);
                return err;
            };
            try std.testing.expectEqualStrings("done", state.records.items[0].app);
        }
    }.run, .{});
}
