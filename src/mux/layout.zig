const std = @import("std");
const types = @import("types.zig");
const Pane = @import("../pane.zig").Pane;

const PaneBounds = types.PaneBounds;
const LayoutLeaf = types.LayoutLeaf;
const SplitNode = types.SplitNode;
const SplitDirection = types.SplitDirection;
const FocusDirection = types.FocusDirection;
const MAX_LAYOUT_LEAVES = types.MAX_LAYOUT_LEAVES;
const DividerHit = types.DividerHit;

// ── Layout math ──────────────────────────────────────────────────────────────

fn splitCellCount(total: u32, ratio: f32) u32 {
    if (total <= 1) return total;

    const clamped_ratio = std.math.clamp(ratio, 0.0, 1.0);
    return @max(1, @min(total - 1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(total)) * clamped_ratio)))));
}

fn splitSpan(usable: u32, cell: u32, ratio: f32) u32 {
    if (cell == 0) {
        return @as(u32, @intFromFloat(@as(f32, @floatFromInt(usable)) * std.math.clamp(ratio, 0.0, 1.0)));
    }

    const total = usable / cell;
    if (total == 0) return 0;

    return splitCellCount(total, ratio) * cell;
}

/// Walk the split tree rooted at `node` with the given pixel `bounds` and
/// return the first split seam within `radius` pixels of (`mx`, `my`).
/// Returns null when the cursor is not near any divider.
pub fn hitTestDivider(
    node: *SplitNode,
    bounds: PaneBounds,
    mx: f32,
    my: f32,
    radius: f32,
) ?DividerHit {
    if (node.kind != .split) return null;

    const first = node.first orelse return null;
    const second = node.second orelse return null;
    const ratio = std.math.clamp(node.ratio, 0.0, 1.0);

    var first_bounds: PaneBounds = undefined;
    var second_bounds: PaneBounds = undefined;

    switch (node.direction) {
        .vertical => {
            const first_w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(bounds.width)) * ratio));
            const second_w = if (bounds.width > first_w) bounds.width - first_w else 0;
            first_bounds = .{ .x = bounds.x, .y = bounds.y, .width = first_w, .height = bounds.height };
            second_bounds = .{ .x = bounds.x + first_w, .y = bounds.y, .width = second_w, .height = bounds.height };
            // Divider is the vertical seam at x = bounds.x + first_w.
            const seam_x: f32 = @floatFromInt(bounds.x + first_w);
            const in_y = my >= @as(f32, @floatFromInt(bounds.y)) and
                my < @as(f32, @floatFromInt(bounds.y + bounds.height));
            if (in_y and @abs(mx - seam_x) <= radius) {
                return .{ .node = node, .bounds = bounds };
            }
        },
        .horizontal => {
            const first_h = @as(u32, @intFromFloat(@as(f32, @floatFromInt(bounds.height)) * ratio));
            const second_h = if (bounds.height > first_h) bounds.height - first_h else 0;
            first_bounds = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = first_h };
            second_bounds = .{ .x = bounds.x, .y = bounds.y + first_h, .width = bounds.width, .height = second_h };
            // Divider is the horizontal seam at y = bounds.y + first_h.
            const seam_y: f32 = @floatFromInt(bounds.y + first_h);
            const in_x = mx >= @as(f32, @floatFromInt(bounds.x)) and
                mx < @as(f32, @floatFromInt(bounds.x + bounds.width));
            if (in_x and @abs(my - seam_y) <= radius) {
                return .{ .node = node, .bounds = bounds };
            }
        },
    }

    // Recurse into children (innermost split wins).
    if (hitTestDivider(first, first_bounds, mx, my, radius)) |hit| return hit;
    if (hitTestDivider(second, second_bounds, mx, my, radius)) |hit| return hit;
    return null;
}

pub fn boundsForNode(
    node: *SplitNode,
    target: *const SplitNode,
    bounds: PaneBounds,
    cell_w: u32,
    cell_h: u32,
) ?PaneBounds {
    if (node == target) return bounds;
    if (node.kind != .split) return null;

    const first = node.first orelse return null;
    const second = node.second orelse return null;
    const ratio = std.math.clamp(node.ratio, 0.0, 1.0);
    var first_bounds: PaneBounds = undefined;
    var second_bounds: PaneBounds = undefined;

    switch (node.direction) {
        .vertical => {
            const divider: u32 = if (bounds.width > 1) 1 else 0;
            const usable_w = if (bounds.width > divider) bounds.width - divider else bounds.width;
            const first_w = splitSpan(usable_w, cell_w, ratio);
            const second_w = if (usable_w > first_w) usable_w - first_w else 0;
            first_bounds = .{ .x = bounds.x, .y = bounds.y, .width = first_w, .height = bounds.height };
            second_bounds = .{ .x = bounds.x + first_w + divider, .y = bounds.y, .width = second_w, .height = bounds.height };
        },
        .horizontal => {
            const divider: u32 = if (bounds.height > 1) 1 else 0;
            const usable_h = if (bounds.height > divider) bounds.height - divider else bounds.height;
            const first_h = splitSpan(usable_h, cell_h, ratio);
            const second_h = if (usable_h > first_h) usable_h - first_h else 0;
            first_bounds = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = first_h };
            second_bounds = .{ .x = bounds.x, .y = bounds.y + first_h + divider, .width = bounds.width, .height = second_h };
        },
    }

    if (boundsForNode(first, target, first_bounds, cell_w, cell_h)) |result| return result;
    if (boundsForNode(second, target, second_bounds, cell_w, cell_h)) |result| return result;
    return null;
}

/// Walk a SplitNode tree and fill `out` with one LayoutLeaf per pane leaf.
/// Returns the number of entries written.
/// `bounds` is the pixel rectangle available to `node`.
pub fn layoutSplitTree(
    node: *SplitNode,
    bounds: PaneBounds,
    out: []LayoutLeaf,
    written: *usize,
    cell_w: u32,
    cell_h: u32,
) void {
    switch (node.kind) {
        .pane => {
            const pane = node.pane orelse return;
            if (written.* >= out.len) return;
            out[written.*] = .{ .pane = pane, .bounds = bounds };
            written.* += 1;
        },
        .split => {
            const first = node.first orelse return;
            const second = node.second orelse return;
            const ratio = std.math.clamp(node.ratio, 0.0, 1.0);
            var first_bounds: PaneBounds = undefined;
            var second_bounds: PaneBounds = undefined;
            switch (node.direction) {
                .vertical => {
                    const divider: u32 = if (bounds.width > 1) 1 else 0;
                    const usable_w = if (bounds.width > divider) bounds.width - divider else bounds.width;
                    if (cell_w > 0) {
                        const first_w = splitSpan(usable_w, cell_w, ratio);
                        const second_w = if (usable_w > first_w) usable_w - first_w else 0;
                        first_bounds = .{ .x = bounds.x, .y = bounds.y, .width = first_w, .height = bounds.height };
                        second_bounds = .{ .x = bounds.x + first_w + divider, .y = bounds.y, .width = second_w, .height = bounds.height };
                    } else {
                        const first_w = splitSpan(usable_w, cell_w, ratio);
                        const second_w = if (usable_w > first_w) usable_w - first_w else 0;
                        first_bounds = .{ .x = bounds.x, .y = bounds.y, .width = first_w, .height = bounds.height };
                        second_bounds = .{ .x = bounds.x + first_w + divider, .y = bounds.y, .width = second_w, .height = bounds.height };
                    }
                },
                .horizontal => {
                    const divider: u32 = if (bounds.height > 1) 1 else 0;
                    const usable_h = if (bounds.height > divider) bounds.height - divider else bounds.height;
                    if (cell_h > 0) {
                        const first_h = splitSpan(usable_h, cell_h, ratio);
                        const second_h = if (usable_h > first_h) usable_h - first_h else 0;
                        first_bounds = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = first_h };
                        second_bounds = .{ .x = bounds.x, .y = bounds.y + first_h + divider, .width = bounds.width, .height = second_h };
                    } else {
                        const first_h = splitSpan(usable_h, cell_h, ratio);
                        const second_h = if (usable_h > first_h) usable_h - first_h else 0;
                        first_bounds = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = first_h };
                        second_bounds = .{ .x = bounds.x, .y = bounds.y + first_h + divider, .width = bounds.width, .height = second_h };
                    }
                },
            }
            layoutSplitTree(first, first_bounds, out, written, cell_w, cell_h);
            layoutSplitTree(second, second_bounds, out, written, cell_w, cell_h);
        },
    }
}

pub fn layoutVisibleTree(
    node: *SplitNode,
    bounds: PaneBounds,
    out: []LayoutLeaf,
    written: *usize,
    skip_pane: ?*Pane,
    cell_w: u32,
    cell_h: u32,
) void {
    switch (node.kind) {
        .pane => {
            const pane = node.pane orelse return;
            if (skip_pane == pane or pane.is_floating) return;
            if (written.* >= out.len) return;
            out[written.*] = .{ .pane = pane, .bounds = bounds };
            written.* += 1;
        },
        .split => {
            const first = node.first orelse return;
            const second = node.second orelse return;
            const ratio = std.math.clamp(node.ratio, 0.0, 1.0);
            var first_bounds: PaneBounds = undefined;
            var second_bounds: PaneBounds = undefined;
            switch (node.direction) {
                .vertical => {
                    const divider: u32 = if (bounds.width > 1) 1 else 0;
                    const usable_w = if (bounds.width > divider) bounds.width - divider else bounds.width;
                    if (cell_w > 0) {
                        const first_w = splitSpan(usable_w, cell_w, ratio);
                        const second_w = if (usable_w > first_w) usable_w - first_w else 0;
                        first_bounds = .{ .x = bounds.x, .y = bounds.y, .width = first_w, .height = bounds.height };
                        second_bounds = .{ .x = bounds.x + first_w + divider, .y = bounds.y, .width = second_w, .height = bounds.height };
                    } else {
                        const first_w = splitSpan(usable_w, cell_w, ratio);
                        const second_w = if (usable_w > first_w) usable_w - first_w else 0;
                        first_bounds = .{ .x = bounds.x, .y = bounds.y, .width = first_w, .height = bounds.height };
                        second_bounds = .{ .x = bounds.x + first_w + divider, .y = bounds.y, .width = second_w, .height = bounds.height };
                    }
                },
                .horizontal => {
                    const divider: u32 = if (bounds.height > 1) 1 else 0;
                    const usable_h = if (bounds.height > divider) bounds.height - divider else bounds.height;
                    if (cell_h > 0) {
                        const first_h = splitSpan(usable_h, cell_h, ratio);
                        const second_h = if (usable_h > first_h) usable_h - first_h else 0;
                        first_bounds = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = first_h };
                        second_bounds = .{ .x = bounds.x, .y = bounds.y + first_h + divider, .width = bounds.width, .height = second_h };
                    } else {
                        const first_h = splitSpan(usable_h, cell_h, ratio);
                        const second_h = if (usable_h > first_h) usable_h - first_h else 0;
                        first_bounds = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = first_h };
                        second_bounds = .{ .x = bounds.x, .y = bounds.y + first_h + divider, .width = bounds.width, .height = second_h };
                    }
                },
            }
            layoutVisibleTree(first, first_bounds, out, written, skip_pane, cell_w, cell_h);
            layoutVisibleTree(second, second_bounds, out, written, skip_pane, cell_w, cell_h);
        },
    }
}

pub fn floatingPaneBounds(bounds: PaneBounds, pane: *const Pane) PaneBounds {
    const max_w: f32 = @floatFromInt(bounds.width);
    const max_h: f32 = @floatFromInt(bounds.height);
    const width = std.math.clamp(pane.floating_width, 0.2, 1.0);
    const height = std.math.clamp(pane.floating_height, 0.15, 1.0);
    const x = std.math.clamp(pane.floating_x, 0.0, 1.0 - width);
    const y = std.math.clamp(pane.floating_y, 0.0, 1.0 - height);
    const pane_w = @max(@as(u32, 1), @as(u32, @intFromFloat(max_w * width)));
    const pane_h = @max(@as(u32, 1), @as(u32, @intFromFloat(max_h * height)));
    const pane_x = bounds.x + @as(u32, @intFromFloat(max_w * x));
    const pane_y = bounds.y + @as(u32, @intFromFloat(max_h * y));
    return .{
        .x = pane_x,
        .y = pane_y,
        .width = @min(bounds.width, pane_w),
        .height = @min(bounds.height, pane_h),
    };
}

// ── Split-tree helpers ───────────────────────────────────────────────────────

pub fn findPaneLeafNode(node: *SplitNode, pane: *Pane) ?*SplitNode {
    switch (node.kind) {
        .pane => {
            if (node.pane == pane) return node;
            return null;
        },
        .split => {
            if (node.first) |first| {
                if (findPaneLeafNode(first, pane)) |match| return match;
            }
            if (node.second) |second| {
                if (findPaneLeafNode(second, pane)) |match| return match;
            }
            return null;
        },
    }
}

pub fn subtreeContainsPane(node: *SplitNode, pane: *Pane) bool {
    return findPaneLeafNode(node, pane) != null;
}

/// Returns true if `target` is reachable from `root` (i.e. `target` is a node
/// in the split tree rooted at `root`).  Used to validate cached node pointers
/// (`g_drag_node`, `pending_split_ratio_node`) that may become dangling after
/// tree mutations like `removePaneFromTree`.
pub fn nodeIsInTree(root: *SplitNode, target: *const SplitNode) bool {
    if (root == target) return true;
    if (root.kind != .split) return false;
    if (root.first) |first| {
        if (nodeIsInTree(first, target)) return true;
    }
    if (root.second) |second| {
        if (nodeIsInTree(second, target)) return true;
    }
    return false;
}

pub fn splitDirectionForFocus(direction: FocusDirection) SplitDirection {
    return switch (direction) {
        .left, .right => .vertical,
        .up, .down => .horizontal,
    };
}

pub fn findFocusTargetSubtree(node: *SplitNode, pane: *Pane, direction: FocusDirection) ?*SplitNode {
    if (node.kind != .split) return null;

    const first = node.first orelse return null;
    const second = node.second orelse return null;
    const wants_first = direction == .left or direction == .up;
    const wants_second = direction == .right or direction == .down;
    const matching_axis = node.direction == splitDirectionForFocus(direction);

    if (subtreeContainsPane(first, pane)) {
        if (findFocusTargetSubtree(first, pane, direction)) |target| return target;
        if (matching_axis and wants_second) return second;
        return null;
    }

    if (subtreeContainsPane(second, pane)) {
        if (findFocusTargetSubtree(second, pane, direction)) |target| return target;
        if (matching_axis and wants_first) return first;
        return null;
    }

    return null;
}

pub fn intervalOverlap(a_start: u32, a_len: u32, b_start: u32, b_len: u32) u32 {
    const a_end = a_start + a_len;
    const b_end = b_start + b_len;
    const start = @max(a_start, b_start);
    const end = @min(a_end, b_end);
    return if (end > start) end - start else 0;
}

pub fn intervalGap(a_start: u32, a_len: u32, b_start: u32, b_len: u32) u32 {
    const a_end = a_start + a_len;
    const b_end = b_start + b_len;
    if (a_end < b_start) return b_start - a_end;
    if (b_end < a_start) return a_start - b_end;
    return 0;
}

pub fn primaryAxisGap(current: PaneBounds, candidate: PaneBounds, direction: FocusDirection) u32 {
    return switch (direction) {
        .left => intervalGap(candidate.x, candidate.width, current.x, current.width),
        .right => intervalGap(current.x, current.width, candidate.x, candidate.width),
        .up => intervalGap(candidate.y, candidate.height, current.y, current.height),
        .down => intervalGap(current.y, current.height, candidate.y, candidate.height),
    };
}

pub fn secondaryAxisGap(current: PaneBounds, candidate: PaneBounds, direction: FocusDirection) u32 {
    return switch (direction) {
        .left, .right => intervalGap(current.y, current.height, candidate.y, candidate.height),
        .up, .down => intervalGap(current.x, current.width, candidate.x, candidate.width),
    };
}

pub fn findAdjacentPane(leaves: []const LayoutLeaf, pane: *Pane, direction: FocusDirection) ?*Pane {
    var current_bounds: ?PaneBounds = null;
    for (leaves) |leaf| {
        if (leaf.pane == pane) {
            current_bounds = leaf.bounds;
            break;
        }
    }
    const cb = current_bounds orelse return null;

    var best_pane: ?*Pane = null;
    var best_overlap: u32 = 0;
    var best_primary_gap: u32 = std.math.maxInt(u32);
    var best_secondary_gap: u32 = std.math.maxInt(u32);

    for (leaves) |leaf| {
        if (leaf.pane == pane) continue;
        if (pane.is_floating != leaf.pane.is_floating) continue;

        const is_in_direction = switch (direction) {
            .left => leaf.bounds.x + leaf.bounds.width <= cb.x,
            .right => leaf.bounds.x >= cb.x + cb.width,
            .up => leaf.bounds.y + leaf.bounds.height <= cb.y,
            .down => leaf.bounds.y >= cb.y + cb.height,
        };
        if (!is_in_direction) continue;

        const overlap = switch (direction) {
            .left, .right => intervalOverlap(cb.y, cb.height, leaf.bounds.y, leaf.bounds.height),
            .up, .down => intervalOverlap(cb.x, cb.width, leaf.bounds.x, leaf.bounds.width),
        };
        const primary_gap = primaryAxisGap(cb, leaf.bounds, direction);
        const secondary_gap = secondaryAxisGap(cb, leaf.bounds, direction);

        if (best_pane == null or
            overlap > best_overlap or
            (overlap == best_overlap and primary_gap < best_primary_gap) or
            (overlap == best_overlap and primary_gap == best_primary_gap and secondary_gap < best_secondary_gap))
        {
            best_overlap = overlap;
            best_primary_gap = primary_gap;
            best_secondary_gap = secondary_gap;
            best_pane = leaf.pane;
        }
    }

    return best_pane;
}

/// Returns the innermost split node with the given direction that contains `pane`
/// somewhere in its subtree.
pub fn findSplitContaining(node: *SplitNode, pane: *Pane, direction: SplitDirection) ?*SplitNode {
    if (node.kind != .split) return null;
    // Only consider this node if it has `pane` in its subtree.
    if (findPaneLeafNode(node, pane) == null) return null;

    // Try children first (innermost wins).
    if (node.first) |first| {
        if (findSplitContaining(first, pane, direction)) |found| return found;
    }
    if (node.second) |second| {
        if (findSplitContaining(second, pane, direction)) |found| return found;
    }

    // This node contains `pane` and no child does — use it if direction matches.
    if (node.direction == direction) return node;
    return null;
}

/// Walk the split tree rooted at `node` looking for the split that directly
/// contains a leaf for `pane`. When found, replace that split node in-place
/// with the sibling subtree (collapsing the split) and free the dead leaf
/// and the split node shell.
///
/// Returns the *Pane pointer from the sibling leaf if the sibling is a plain
/// pane leaf, otherwise null (the caller falls back to pane-list iteration).
pub fn removePaneFromTree(allocator: std.mem.Allocator, node: *SplitNode, pane: *Pane) ?*Pane {
    if (node.kind != .split) return null;

    const first = node.first orelse return null;
    const second = node.second orelse return null;

    // Check if first child is the target leaf.
    if (first.kind == .pane and first.pane == pane) {
        // Replace *node in-place with the contents of `second`, then free
        // the now-detached first leaf and the old second node shell.
        const sibling_pane: ?*Pane = if (second.kind == .pane) second.pane else null;
        allocator.destroy(first); // dead leaf (pane itself freed by caller)
        const second_copy = second.*;
        allocator.destroy(second); // free the shell; its children live on via copy
        node.* = second_copy;
        return sibling_pane;
    }

    // Check if second child is the target leaf.
    if (second.kind == .pane and second.pane == pane) {
        const sibling_pane: ?*Pane = if (first.kind == .pane) first.pane else null;
        allocator.destroy(second);
        const first_copy = first.*;
        allocator.destroy(first);
        node.* = first_copy;
        return sibling_pane;
    }

    // Recurse into children.
    if (removePaneFromTree(allocator, first, pane)) |p| return p;
    if (removePaneFromTree(allocator, second, pane)) |p| return p;
    return null;
}
