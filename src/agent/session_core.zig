//! Portable metadata/admission. Runtime arrays remain borrowed; this does not
//! globally bound existing owners' session or pane counts.
const std = @import("std");
const p = @import("session_protocol.zig");

pub fn reservedId(bytes: []const u8) ![32]u8 {
    if (!p.validCreateId(bytes)) return error.InvalidSessionId;
    return bytes[0..32].*;
}

/// Entropy acquisition stays per-platform.
pub fn randomId(random: [16]u8) [32]u8 {
    return std.fmt.bytesToHex(random, .lower);
}

/// Includes ended entries until collection; no tombstone policy.
pub fn checkCollision(sessions: anytype, id: []const u8) !void {
    for (sessions) |s| if (std.mem.eql(u8, &s.meta.id, id)) return error.SessionExists;
}

pub fn findSession(sessions: anytype, id: []const u8) ?@TypeOf(sessions[0]) {
    for (sessions) |s| if (!s.meta.ended and std.mem.eql(u8, &s.meta.id, id)) return s;
    return null;
}

pub const Metadata = struct {
    id: [32]u8,
    /// Wide cursor represents exhaustion after the last u32 wire ID.
    next_pane: u64 = 1,
    revision: u64 = 0,
    layout: []u8 = &.{},
    ended: bool = false,

    pub fn deinit(self: *Metadata, a: std.mem.Allocator) void {
        a.free(self.layout);
    }

    /// Synchronous, non-reentrant operations only, not asynchronous handles.
    /// Prepare all resources before spawn; commit must follow without failure.
    pub const PreparedPane = struct {
        id: u32,
        next_pane: u64,
        revision: u64,

        pub fn commit(self: PreparedPane, meta: *Metadata) void {
            meta.next_pane = self.next_pane;
            meta.revision = self.revision;
        }
    };

    pub fn preparePane(self: *const Metadata, membership_change: bool) !PreparedPane {
        if (self.next_pane == 0 or self.next_pane > std.math.maxInt(u32)) return error.ResourceExhausted;
        return .{
            .id = @intCast(self.next_pane),
            .next_pane = self.next_pane + 1,
            .revision = if (membership_change) try self.prepareMembershipChange() else self.revision,
        };
    }

    /// Membership changes retain opaque geometry for client reconciliation.
    pub fn prepareMembershipChange(self: *const Metadata) !u64 {
        if (self.revision == std.math.maxInt(u64)) return error.ResourceExhausted;
        return self.revision + 1;
    }

    pub fn setInitialLayout(self: *Metadata, a: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len > p.control_limit) return error.ResourceExhausted;
        const copy = try a.dupe(u8, bytes);
        a.free(self.layout);
        self.layout = copy;
    }

    pub fn replaceLayout(self: *Metadata, a: std.mem.Allocator, expected: ?u64, bytes: []const u8) !void {
        if (expected == null or expected.? != self.revision) return error.RevisionConflict;
        const revision = try self.prepareMembershipChange();
        try self.setInitialLayout(a, bytes);
        self.revision = revision;
    }
};

test "identity encoding, retained ended collision and collection reuse" {
    const id = try reservedId("0123456789abcdef0123456789abcdef");
    try std.testing.expectError(error.InvalidSessionId, reservedId("invalid"));
    try std.testing.expectError(error.InvalidSessionId, reservedId("ABCDEF0123456789abcdef0123456789"));
    try std.testing.expectEqualStrings("abababababababababababababababab", &randomId(@splat(0xab)));
    const Runtime = struct { meta: Metadata };
    var entry: Runtime = .{ .meta = .{ .id = id, .ended = true } };
    var entries = [_]*Runtime{&entry};
    try std.testing.expectError(error.SessionExists, checkCollision(entries[0..], &id));
    try std.testing.expect(findSession(entries[0..], &id) == null);
    entry.meta.ended = false;
    try std.testing.expect(findSession(entries[0..], &id) == &entry);
    try checkCollision(entries[0..0], &id);
}

test "layout CAS and membership preserve opaque geometry" {
    const a = std.testing.allocator;
    var meta: Metadata = .{ .id = @splat('0') };
    defer meta.deinit(a);
    try meta.setInitialLayout(a, "geometry");
    const initial = try meta.preparePane(false);
    initial.commit(&meta);
    try std.testing.expectEqual(@as(u64, 0), meta.revision);
    try std.testing.expectError(error.RevisionConflict, meta.replaceLayout(a, null, "other"));
    try std.testing.expectError(error.RevisionConflict, meta.replaceLayout(a, 1, "other"));
    try meta.replaceLayout(a, 0, "geometry");
    try std.testing.expectEqual(@as(u64, 1), meta.revision);
    const next = try meta.preparePane(true);
    try std.testing.expectEqual(@as(u32, 2), next.id);
    next.commit(&meta);
    meta.revision = try meta.prepareMembershipChange();
    try std.testing.expectEqual(@as(u64, 3), meta.revision);
    try std.testing.expectEqualStrings("geometry", meta.layout);
}

test "layout OOM preserves bytes and revision" {
    const a = std.testing.allocator;
    var meta: Metadata = .{ .id = @splat('0'), .revision = 7 };
    defer meta.deinit(a);
    try meta.setInitialLayout(a, "old");
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, meta.replaceLayout(failing.allocator(), 7, "replacement"));
    try std.testing.expectError(error.OutOfMemory, meta.setInitialLayout(failing.allocator(), "initial"));
    const oversized = try a.alloc(u8, p.control_limit + 1);
    defer a.free(oversized);
    try std.testing.expectError(error.ResourceExhausted, meta.setInitialLayout(a, oversized));
    try std.testing.expectError(error.ResourceExhausted, meta.replaceLayout(a, 7, oversized));
    try std.testing.expectEqualStrings("old", meta.layout);
    try std.testing.expectEqual(@as(u64, 7), meta.revision);
}

test "pane and revision exhaustion are nonmutating" {
    var meta: Metadata = .{ .id = @splat('0'), .next_pane = std.math.maxInt(u32) };
    const last = try meta.preparePane(true);
    last.commit(&meta);
    try std.testing.expectError(error.ResourceExhausted, meta.preparePane(false));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u32)) + 1, meta.next_pane);
    meta.next_pane = std.math.maxInt(u64);
    try std.testing.expectError(error.ResourceExhausted, meta.preparePane(false));
    meta.next_pane = 12;
    meta.revision = std.math.maxInt(u64);
    try std.testing.expectError(error.ResourceExhausted, meta.preparePane(true));
    try std.testing.expectError(error.ResourceExhausted, meta.prepareMembershipChange());
    try std.testing.expectError(error.ResourceExhausted, meta.replaceLayout(std.testing.allocator, meta.revision, "x"));
    try std.testing.expectEqual(@as(u64, 12), meta.next_pane);
    try std.testing.expectEqual(std.math.maxInt(u64), meta.revision);
    try std.testing.expectEqualStrings("", meta.layout);
}
