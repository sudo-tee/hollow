//! GUI geometry uses owner pane IDs, never process-local mux IDs. The portable
//! codec validates the entire blob before these helpers touch a workspace.
const std = @import("std");
const codec = @import("../session/layout.zig");
const Pane = @import("../pane.zig").Pane;
const Tab = @import("tab.zig").Tab;
const Workspace = @import("workspace.zig").Workspace;
const SplitNode = @import("types.zig").SplitNode;

pub fn ownerId(pane: *const Pane) !u32 {
    const term = pane.asTerminalConst() orelse return error.InvalidSessionLayout;
    const pty = term.pty orelse return error.InvalidSessionLayout;
    return if (pty == .session) pty.session.pane else error.InvalidSessionLayout;
}

fn find(tab: *Tab, id: u32) !*Pane {
    for (tab.panes.items) |pane| if (try ownerId(pane) == id) return pane;
    return error.InvalidSessionLayout;
}

/// Called only for a newly allocated tab with no root and all its views owned
/// by tab.panes. Failure cleanup is therefore ordinary Tab.deinit.
pub fn restoreTab(tab: *Tab, value: codec.Tab) !void {
    if (value.root) |root| tab.root_split = try restoreNode(tab, value.nodes, root);
    for (value.floating) |floating| {
        const pane = try find(tab, floating.pane);
        pane.is_floating = true;
        pane.floating_x = floating.x;
        pane.floating_y = floating.y;
        pane.floating_width = floating.width;
        pane.floating_height = floating.height;
        pane.restore_anchor_id = if (floating.anchor) |id| (try find(tab, id)).id else 0;
        pane.restore_ratio = floating.restore_ratio;
        pane.restore_split_horizontal = floating.restore_horizontal;
        pane.restore_place_first = floating.restore_first;
    }
    tab.active_pane = try find(tab, value.active_pane);
    tab.maximized_pane = if (value.maximized_pane) |id| try find(tab, id) else null;
    tab.maximized_show_background = value.maximized_show_background;
}

fn restoreNode(tab: *Tab, nodes: []const codec.Node, index: usize) anyerror!*SplitNode {
    const value = nodes[index];
    const node = try tab.allocator.create(SplitNode);
    node.* = .{ .kind = .pane };
    errdefer {
        node.deinit(tab.allocator);
        tab.allocator.destroy(node);
    }
    if (value.pane) |id| {
        node.pane = try find(tab, id);
    } else {
        node.kind = .split;
        node.direction = if (value.direction == .horizontal) .horizontal else .vertical;
        node.ratio = value.ratio;
        node.first = try restoreNode(tab, nodes, value.first.?);
        node.second = try restoreNode(tab, nodes, value.second.?);
    }
    return node;
}

/// Explicit capture only: never run geometry serialization per output frame.
/// Intermediate allocations are arena-owned; caller owns only returned bytes.
pub fn capture(a: std.mem.Allocator, workspace: *Workspace) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    if (workspace.session_controller == null) return error.InvalidSessionLayout;
    var ids: std.ArrayList(u32) = .empty;
    var tabs: std.ArrayList(codec.Tab) = .empty;
    for (workspace.tabs.items) |tab| {
        var nodes: std.ArrayList(codec.Node) = .empty;
        var floating: std.ArrayList(codec.Floating) = .empty;
        const root = if (tab.root_split) |node| try captureNode(temp, &nodes, node, 0) else null;
        for (tab.panes.items) |pane| {
            const id = try ownerId(pane);
            try ids.append(temp, id);
            if (!pane.is_floating) continue;
            const anchor: ?u32 = if (pane.restore_anchor_id == 0) null else blk: {
                for (tab.panes.items) |candidate| {
                    if (candidate.id == pane.restore_anchor_id) break :blk try ownerId(candidate);
                }
                // Closing an anchor need not prevent saving a floating pane.
                break :blk null;
            };
            try floating.append(temp, .{
                .pane = id,
                .x = pane.floating_x,
                .y = pane.floating_y,
                .width = pane.floating_width,
                .height = pane.floating_height,
                .anchor = anchor,
                .restore_ratio = pane.restore_ratio,
                .restore_horizontal = pane.restore_split_horizontal,
                .restore_first = pane.restore_place_first,
            });
        }
        try tabs.append(temp, .{
            .active_pane = try ownerId(tab.active_pane orelse return error.InvalidSessionLayout),
            .root = root,
            .nodes = nodes.items,
            .floating = floating.items,
            .maximized_pane = if (tab.maximized_pane) |pane| try ownerId(pane) else null,
            .maximized_show_background = tab.maximized_show_background,
        });
    }
    return codec.encode(a, .{ .name = workspace.name, .active_tab = workspace.activeTabIndex(), .tabs = tabs.items }, ids.items);
}

fn captureNode(a: std.mem.Allocator, nodes: *std.ArrayList(codec.Node), node: *SplitNode, depth: usize) anyerror!usize {
    if (depth >= codec.max_depth or nodes.items.len >= codec.max_panes * 2) return error.InvalidSessionLayout;
    const index = nodes.items.len;
    try nodes.append(a, .{});
    if (node.kind == .pane) {
        nodes.items[index].pane = try ownerId(node.pane orelse return error.InvalidSessionLayout);
    } else {
        const first = try captureNode(a, nodes, node.first orelse return error.InvalidSessionLayout, depth + 1);
        const second = try captureNode(a, nodes, node.second orelse return error.InvalidSessionLayout, depth + 1);
        nodes.items[index] = .{
            .first = first,
            .second = second,
            .direction = if (node.direction == .horizontal) .horizontal else .vertical,
            .ratio = node.ratio,
        };
    }
    return index;
}
