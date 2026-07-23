const std = @import("std");

pub const max_nodes = 384;
pub const max_id_len = 128;
pub const max_label_len = 256;

pub const Surface = enum {
    topbar,
    bottombar,
    overlay,

    pub fn parse(value: []const u8) ?Surface {
        if (std.mem.eql(u8, value, "topbar")) return .topbar;
        if (std.mem.eql(u8, value, "bottombar")) return .bottombar;
        if (std.mem.eql(u8, value, "overlay")) return .overlay;
        return null;
    }
};

pub const Bounds = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

pub const Role = enum {
    button,
    dialog,
    listitem,
};

pub const Node = struct {
    surface: Surface = .overlay,
    role: Role = .button,
    clickable: bool = false,
    bounds: Bounds = .{},
    id_buf: [max_id_len]u8 = [_]u8{0} ** max_id_len,
    id_len: u16 = 0,
    label_buf: [max_label_len]u8 = [_]u8{0} ** max_label_len,
    label_len: u16 = 0,

    pub fn id(self: *const Node) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    pub fn label(self: *const Node) []const u8 {
        return self.label_buf[0..self.label_len];
    }
};

pub const Snapshot = struct {
    generation: u64 = 0,
    valid: bool = false,
    truncated: bool = false,
    nodes: [max_nodes]Node = [_]Node{.{}} ** max_nodes,
    len: usize = 0,
};

pub const Store = struct {
    building: Snapshot = .{},
    published: Snapshot = .{},
    next_generation: u64 = 1,

    pub fn begin(self: *Store) void {
        self.building = .{ .valid = true };
    }

    pub fn append(self: *Store, surface: Surface, role: Role, clickable: bool, id: []const u8, label: []const u8, bounds: Bounds) void {
        if (id.len == 0) return;
        if (id.len > max_id_len or self.building.len >= self.building.nodes.len) {
            self.building.truncated = true;
            return;
        }

        const node = &self.building.nodes[self.building.len];
        node.* = .{ .surface = surface, .role = role, .clickable = clickable, .bounds = bounds, .id_len = @intCast(id.len) };
        @memcpy(node.id_buf[0..id.len], id);
        const trimmed_label = std.mem.trim(u8, label, " \t\r\n");
        const label_len = @min(trimmed_label.len, max_label_len);
        node.label_len = @intCast(label_len);
        @memcpy(node.label_buf[0..label_len], trimmed_label[0..label_len]);
        self.building.len += 1;
    }

    pub fn publish(self: *Store) bool {
        if (snapshotsEqual(&self.building, &self.published)) return false;
        self.building.generation = self.next_generation;
        if (self.next_generation < std.math.maxInt(i64)) self.next_generation += 1;
        self.published = self.building;
        return true;
    }

    pub fn invalidate(self: *Store) bool {
        self.building = .{};
        return self.publish();
    }
};

fn snapshotsEqual(a: *const Snapshot, b: *const Snapshot) bool {
    if (a.valid != b.valid or a.truncated != b.truncated or a.len != b.len) return false;
    for (a.nodes[0..a.len], b.nodes[0..b.len]) |left, right| {
        if (left.surface != right.surface or left.role != right.role or left.clickable != right.clickable or left.id_len != right.id_len) return false;
        if (!std.mem.eql(u8, left.id(), right.id())) return false;
        if (!std.mem.eql(u8, left.label(), right.label())) return false;
        if (left.bounds.x != right.bounds.x or
            left.bounds.y != right.bounds.y or
            left.bounds.width != right.bounds.width or
            left.bounds.height != right.bounds.height) return false;
    }
    return true;
}

test "semantic store publishes only changed snapshots" {
    var store = Store{};
    store.begin();
    store.append(.topbar, .button, true, "tabs.new", "New tab", .{ .x = 4, .width = 20, .height = 24 });
    try std.testing.expect(store.publish());
    const generation = store.published.generation;
    try std.testing.expectEqual(Role.button, store.published.nodes[0].role);
    try std.testing.expect(store.published.nodes[0].clickable);
    try std.testing.expectEqualStrings("New tab", store.published.nodes[0].label());

    store.begin();
    store.append(.topbar, .button, true, "tabs.new", "New tab", .{ .x = 4, .width = 20, .height = 24 });
    try std.testing.expect(!store.publish());
    try std.testing.expectEqual(generation, store.published.generation);

    store.begin();
    store.append(.topbar, .button, true, "tabs.new", "New tab", .{ .x = 5, .width = 20, .height = 24 });
    try std.testing.expect(store.publish());
    try std.testing.expect(store.published.generation > generation);

    const changed_generation = store.published.generation;
    try std.testing.expect(store.invalidate());
    try std.testing.expect(!store.published.valid);
    try std.testing.expect(store.published.generation > changed_generation);
    try std.testing.expect(!store.invalidate());
}
