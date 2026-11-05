//! Portable client layout blob. Pane references are owner IDs, never GUI IDs.
//! Revision checks and persistence policy belong to the caller, not this codec.
const std = @import("std");

pub const max_panes = 1024;
pub const max_tab_panes = 64;
pub const max_depth = 32;
pub const max_bytes = 256 * 1024;

pub const Layout = struct {
    version: u32 = 1,
    name: ?[]const u8 = null,
    active_tab: usize = 0,
    tabs: []const Tab,
};

pub const Tab = struct {
    active_pane: u32,
    root: ?usize = null,
    nodes: []const Node = &.{},
    floating: []const Floating = &.{},
    maximized_pane: ?u32 = null,
    maximized_show_background: bool = false,
};

pub const Node = struct {
    pane: ?u32 = null,
    first: ?usize = null,
    second: ?usize = null,
    direction: enum { horizontal, vertical } = .vertical,
    ratio: f32 = 0.5,
};

pub const Floating = struct {
    pane: u32,
    x: f32 = 0.15,
    y: f32 = 0.1,
    width: f32 = 0.7,
    height: f32 = 0.75,
    anchor: ?u32 = null,
    restore_ratio: f32 = 0.5,
    restore_horizontal: bool = false,
    restore_first: bool = false,
};

/// The returned arena owns all strings and arrays, independent of input bytes.
pub fn decode(a: std.mem.Allocator, bytes: []const u8, panes: []const u32) !std.json.Parsed(Layout) {
    if (bytes.len > max_bytes) return error.SessionLayoutTooLarge;
    const parsed = std.json.parseFromSlice(Layout, a, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionLayout,
    };
    errdefer parsed.deinit();
    try validate(parsed.value, panes);
    return parsed;
}

/// Caller owns the encoded bytes. A fixed writer bounds serialization memory.
pub fn encode(a: std.mem.Allocator, value: Layout, panes: []const u32) ![]u8 {
    try validate(value, panes);
    const buffer = try a.alloc(u8, max_bytes);
    errdefer a.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    std.json.Stringify.value(value, .{}, &writer) catch return error.SessionLayoutTooLarge;
    return a.realloc(buffer, writer.buffered().len);
}

const max_nodes = 2 * max_tab_panes - 1;
const Invalid = error{InvalidSessionLayout};

pub fn validate(value: Layout, panes: []const u32) !void {
    if (value.version != 1) return error.UnsupportedSessionLayout;
    if (panes.len == 0 or panes.len > max_panes or value.tabs.len == 0 or
        value.tabs.len > max_panes or value.active_tab >= value.tabs.len)
        return error.InvalidSessionLayout;
    for (panes, 0..) |id, i| {
        if (id == 0 or std.mem.indexOfScalar(u32, panes[0..i], id) != null)
            return error.InvalidSessionLayout;
    }

    var seen: [max_panes]bool = @splat(false);
    for (value.tabs) |tab| {
        if (tab.nodes.len > max_nodes or tab.floating.len > max_tab_panes or
            (tab.root == null) != (tab.nodes.len == 0))
            return error.InvalidSessionLayout;

        var members: [max_tab_panes]u32 = undefined;
        var count: usize = 0;
        var visited: [max_nodes]bool = @splat(false);
        if (tab.root) |root| try visit(tab.nodes, root, 1, &visited, &members, &count, panes, &seen);
        for (visited[0..tab.nodes.len]) |reached| {
            if (!reached) return error.InvalidSessionLayout;
        }
        for (tab.floating) |floating| {
            if (!inRange(floating.x, 0, 1) or !inRange(floating.y, 0, 1) or
                !inRange(floating.width, 0, 1) or floating.width == 0 or
                !inRange(floating.height, 0, 1) or floating.height == 0 or
                !inRange(floating.restore_ratio, 0.05, 0.95))
                return error.InvalidSessionLayout;
            try addPane(floating.pane, &members, &count, panes, &seen);
        }
        const ids = members[0..count];
        if (std.mem.indexOfScalar(u32, ids, tab.active_pane) == null)
            return error.InvalidSessionLayout;
        if (tab.maximized_pane) |id| {
            if (std.mem.indexOfScalar(u32, ids, id) == null) return error.InvalidSessionLayout;
        }
        for (tab.floating) |floating| {
            if (floating.anchor) |id| {
                if (id == floating.pane or std.mem.indexOfScalar(u32, ids, id) == null)
                    return error.InvalidSessionLayout;
            }
        }
    }
    for (seen[0..panes.len]) |present| {
        if (!present) return error.InvalidSessionLayout;
    }
}

fn inRange(value: f32, min: f32, max: f32) bool {
    return std.math.isFinite(value) and value >= min and value <= max;
}

fn addPane(id: u32, members: *[max_tab_panes]u32, count: *usize, panes: []const u32, seen: *[max_panes]bool) Invalid!void {
    if (count.* == max_tab_panes) return error.InvalidSessionLayout;
    const index = std.mem.indexOfScalar(u32, panes, id) orelse return error.InvalidSessionLayout;
    if (seen[index]) return error.InvalidSessionLayout;
    seen[index] = true;
    members[count.*] = id;
    count.* += 1;
}

fn visit(nodes: []const Node, index: usize, depth: usize, visited: *[max_nodes]bool, members: *[max_tab_panes]u32, count: *usize, panes: []const u32, seen: *[max_panes]bool) Invalid!void {
    // Check bounds and depth before indexing or recursing, including cycles.
    if (index >= nodes.len or depth > max_depth or visited[index]) return error.InvalidSessionLayout;
    visited[index] = true;
    const node = nodes[index];
    if (!inRange(node.ratio, 0.05, 0.95)) return error.InvalidSessionLayout;
    if (node.pane) |id| {
        if (node.first != null or node.second != null) return error.InvalidSessionLayout;
        try addPane(id, members, count, panes, seen);
    } else {
        const first = node.first orelse return error.InvalidSessionLayout;
        const second = node.second orelse return error.InvalidSessionLayout;
        try visit(nodes, first, depth + 1, visited, members, count, panes, seen);
        try visit(nodes, second, depth + 1, visited, members, count, panes, seen);
    }
}

test "session pane layout roundtrip nested splits floating and tabs" {
    const a = std.testing.allocator;
    const panes = [_]u32{ 11, 22, 33, 44, 55, 0xffffffff };
    const value: Layout = .{ .name = "work \"🌙\"", .active_tab = 1, .tabs = &.{
        .{
            .active_pane = 44,
            .root = 0,
            .nodes = &.{
                .{ .first = 1, .second = 2, .direction = .horizontal, .ratio = 0.3 },
                .{ .pane = 11 },
                .{ .first = 3, .second = 4 },
                .{ .pane = 22 },
                .{ .pane = 33 },
            },
            .floating = &.{.{ .pane = 44, .anchor = 22, .restore_horizontal = true, .restore_first = true }},
            .maximized_pane = 33,
            .maximized_show_background = true,
        },
        .{ .active_pane = 55, .floating = &.{ .{ .pane = 55, .anchor = 0xffffffff }, .{ .pane = 0xffffffff, .anchor = 55 } } },
    } };
    const bytes = try encode(a, value, &panes);
    defer a.free(bytes);
    const parsed = try decode(a, bytes, &panes);
    defer parsed.deinit();
    try std.testing.expectEqualDeep(value, parsed.value);
    const again = try encode(a, parsed.value, &panes);
    defer a.free(again);
    try std.testing.expectEqualStrings(bytes, again);
}

fn singleTab(nodes: []const Node) Tab {
    // Also used for malformed shapes, with the same declared owner membership.
    return .{ .active_pane = 1, .root = 0, .nodes = nodes };
}

test "session pane layout malformed trees" {
    const bad = [_][]const Node{
        &.{.{ .pane = 1, .first = 0 }},
        &.{.{ .pane = 1, .second = 0 }},
        &.{.{}},
        &.{.{ .first = 0 }},
        &.{.{ .second = 0 }},
        &.{ .{ .first = 1, .second = 99 }, .{ .pane = 1 } },
        &.{ .{ .first = 1, .second = 1 }, .{ .pane = 1 } },
        &.{ .{ .first = 0, .second = 1 }, .{ .pane = 1 } },
        &.{ .{ .first = 1, .second = 2 }, .{ .first = 0, .second = 2 }, .{ .pane = 1 } },
        &.{ .{ .pane = 1 }, .{ .pane = 2 } },
    };
    for (bad) |nodes| try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = &.{singleTab(nodes)} }, &.{1}));
    try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = &.{.{ .active_pane = 1, .root = 0 }} }, &.{1}));
    try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = &.{.{ .active_pane = 1, .nodes = &.{.{ .pane = 1 }} }} }, &.{1}));
    try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = &.{.{ .active_pane = 1, .root = 1, .nodes = &.{.{ .pane = 1 }} }} }, &.{1}));
}

test "session pane layout depth boundary" {
    var nodes: [2 * max_depth + 1]Node = undefined;
    var panes: [max_depth + 1]u32 = undefined;
    for (&panes, 0..) |*id, i| id.* = @intCast(i + 1);
    // A comb tree: each internal node adds one leaf and extends the spine.
    for (0..max_depth) |i| {
        nodes[2 * i] = .{ .first = 2 * i + 1, .second = 2 * i + 2 };
        nodes[2 * i + 1] = .{ .pane = panes[i] };
    }
    nodes[2 * max_depth] = .{ .pane = panes[max_depth] };
    try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = &.{singleTab(&nodes)} }, &panes));
    nodes[2 * (max_depth - 1)] = .{ .pane = panes[max_depth - 1] };
    try validate(.{ .tabs = &.{singleTab(nodes[0 .. 2 * max_depth - 1])} }, panes[0..max_depth]);
}

test "session pane layout owner membership and references" {
    const value: Layout = .{ .tabs = &.{singleTab(&.{.{ .pane = 1 }})} };
    for ([_][]const u32{ &.{}, &.{0}, &.{ 1, 1 }, &.{2}, &.{ 1, 2 } }) |panes|
        try std.testing.expectError(error.InvalidSessionLayout, validate(value, panes));
    try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = &.{singleTab(&.{.{ .pane = 0 }})} }, &.{1}));
    try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = &.{} }, &.{1}));
    try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .active_tab = 1, .tabs = value.tabs }, &.{1}));
    try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = &.{ value.tabs[0], value.tabs[0] } }, &.{1}));
    var tab = value.tabs[0];
    tab.active_pane = 2;
    try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = &.{tab} }, &.{1}));
    tab.active_pane = 1;
    tab.maximized_pane = 2;
    try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = &.{tab} }, &.{1}));
    for ([_]u32{ 2, 3, 99 }) |anchor| {
        try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = &.{
            .{ .active_pane = 1, .root = 0, .nodes = &.{.{ .pane = 1 }}, .floating = &.{.{ .pane = 2, .anchor = anchor }} },
            .{ .active_pane = 3, .floating = &.{.{ .pane = 3 }} },
        } }, &.{ 1, 2, 3 }));
    }
    // Active and maximized references cannot cross tab boundaries either.
    for ([_]bool{ false, true }) |maximized| {
        try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = &.{
            .{ .active_pane = if (maximized) 1 else 2, .floating = &.{.{ .pane = 1 }}, .maximized_pane = if (maximized) 2 else null },
            .{ .active_pane = 2, .floating = &.{.{ .pane = 2 }} },
        } }, &.{ 1, 2 }));
    }
}

test "session pane layout finite geometry and ratios" {
    const invalid = [_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), -0.01, 1.01 };
    inline for (.{ "x", "y", "width", "height", "restore_ratio" }) |field| {
        for (invalid) |number| {
            var floating: Floating = .{ .pane = 1 };
            @field(floating, field) = number;
            try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = &.{.{ .active_pane = 1, .floating = &.{floating} }} }, &.{1}));
        }
    }
    inline for (.{ "width", "height" }) |field| {
        var floating: Floating = .{ .pane = 1 };
        @field(floating, field) = 0;
        try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = &.{.{ .active_pane = 1, .floating = &.{floating} }} }, &.{1}));
    }
    for (invalid ++ [_]f32{ 0.049, 0.951 }) |number| {
        try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = &.{singleTab(&.{.{ .pane = 1, .ratio = number }})} }, &.{1}));
        try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = &.{.{ .active_pane = 1, .floating = &.{.{ .pane = 1, .restore_ratio = number }} }} }, &.{1}));
    }
    try validate(.{ .tabs = &.{.{ .active_pane = 1, .root = 0, .nodes = &.{.{ .pane = 1, .ratio = 0.05 }}, .floating = &.{.{ .pane = 2, .x = 0, .y = 1, .width = 1, .height = 1, .restore_ratio = 0.95 }} }} }, &.{ 1, 2 });
}

test "session pane layout strict JSON version and length" {
    const a = std.testing.allocator;
    const bad = [_][]const u8{
        "",
        "null",
        "{}",
        "[]",
        "{",
        "{\"tabs\":[],\"future\":1}",
        "{\"tabs\":[{\"active_pane\":1,\"floating\":[{\"pane\":1,\"future\":1}]}]}",
        "{\"tabs\":[{\"active_pane\":1,\"root\":0,\"nodes\":[{\"pane\":1,\"future\":1}]}]}",
        "{\"tabs\":[{\"active_pane\":1,\"future\":1}]}",
        "{\"tabs\":[{\"active_pane\":1,\"root\":0,\"nodes\":[{\"pane\":1,\"direction\":\"diagonal\"}]}]}",
        "{\"tabs\":[{\"active_pane\":1,\"floating\":[{\"pane\":1}]}],\"active_tab\":-1}",
        "{\"tabs\":[],\"tabs\":[]}",
    };
    for (bad) |bytes| try std.testing.expectError(error.InvalidSessionLayout, decode(a, bytes, &.{1}));
    try std.testing.expectError(error.UnsupportedSessionLayout, decode(a, "{\"version\":2,\"tabs\":[]}", &.{1}));
    var value: Layout = .{ .tabs = &.{singleTab(&.{.{ .pane = 1 }})} };
    value.version = 2;
    try std.testing.expectError(error.UnsupportedSessionLayout, encode(a, value, &.{1}));
    value.version = 1;
    const huge = try a.alloc(u8, max_bytes + 1);
    defer a.free(huge);
    @memset(huge, 'x');
    try std.testing.expectError(error.SessionLayoutTooLarge, decode(a, huge, &.{1}));
    value.name = huge;
    try std.testing.expectError(error.SessionLayoutTooLarge, encode(a, value, &.{1}));
    // Escaping can exceed the limit even when the source name is shorter.
    @memset(huge, '\n');
    value.name = huge[0 .. max_bytes / 2];
    try std.testing.expectError(error.SessionLayoutTooLarge, encode(a, value, &.{1}));
}

test "session pane layout pane tab and node count bounds" {
    var panes: [max_panes + 1]u32 = undefined;
    for (&panes, 0..) |*id, i| id.* = @intCast(i + 1);
    var floating: [max_tab_panes + 1]Floating = undefined;
    for (&floating, 0..) |*item, i| item.* = .{ .pane = panes[i] };
    try validate(.{ .tabs = &.{.{ .active_pane = 1, .floating = floating[0..max_tab_panes] }} }, panes[0..max_tab_panes]);
    try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = &.{.{ .active_pane = 1, .floating = &floating }} }, panes[0..floating.len]));
    // The cap includes both tiled and floating panes.
    try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = &.{.{ .active_pane = 1, .root = 0, .nodes = &.{.{ .pane = 65 }}, .floating = floating[0..max_tab_panes] }} }, panes[0 .. max_tab_panes + 1]));
    var tabs: [max_panes + 1]Tab = undefined;
    var all_floating: [max_panes + 1]Floating = undefined;
    for (&tabs, &all_floating, &panes) |*tab, *item, id| {
        item.* = .{ .pane = id };
        tab.* = .{ .active_pane = id, .floating = @as(*[1]Floating, item) };
    }
    try validate(.{ .tabs = tabs[0..max_panes] }, panes[0..max_panes]);
    try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = &tabs }, panes[0..max_panes]));
    try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = tabs[0..max_panes] }, &panes));
    const nodes: [max_nodes + 1]Node = @splat(.{ .pane = 1 });
    try std.testing.expectError(error.InvalidSessionLayout, validate(.{ .tabs = &.{singleTab(&nodes)} }, &.{1}));
}

test "session pane layout exact byte boundary and owned decoding" {
    const a = std.testing.allocator;
    var value: Layout = .{ .tabs = &.{singleTab(&.{.{ .pane = 1 }})} };
    value.name = "";
    const empty = try encode(a, value, &.{1});
    defer a.free(empty);
    const name = try a.alloc(u8, max_bytes - empty.len);
    defer a.free(name);
    @memset(name, 'a');
    value.name = name;
    const bytes = try encode(a, value, &.{1});
    defer a.free(bytes);
    try std.testing.expectEqual(max_bytes, bytes.len);
    const parsed = try decode(a, bytes, &.{1});
    defer parsed.deinit();
    @memset(bytes, ' ');
    try std.testing.expectEqualStrings(name, parsed.value.name.?);
    try validate(parsed.value, &.{1});
}

fn allocationRoundtrip(a: std.mem.Allocator) !void {
    const value: Layout = .{ .name = "allocation test", .tabs = &.{singleTab(&.{.{ .pane = 1 }})} };
    const bytes = try encode(a, value, &.{1});
    defer a.free(bytes);
    const parsed = try decode(a, bytes, &.{1});
    defer parsed.deinit();
    try std.testing.expectEqualDeep(value, parsed.value);
    // Failed semantic validation must also release the parser arena.
    const invalid = decode(a, bytes, &.{2}) catch |err| switch (err) {
        error.InvalidSessionLayout => return,
        else => return err,
    };
    invalid.deinit();
    return error.TestUnexpectedResult;
}

test "session pane layout allocation rollback" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationRoundtrip, .{});
}
