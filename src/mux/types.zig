const std = @import("std");
const Pane = @import("../pane.zig").Pane;

pub const FocusDirection = enum {
    left,
    right,
    up,
    down,
};

pub const SplitDirection = enum {
    horizontal,
    vertical,
};

/// Axis-aligned pixel rectangle for a single pane.
pub const PaneBounds = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// A single entry produced by layout traversal.
pub const LayoutLeaf = struct {
    pane: *Pane,
    bounds: PaneBounds,
};

/// Maximum number of panes that layout supports in one pass.
pub const MAX_LAYOUT_LEAVES = 64;

/// Result of a divider hit-test: the split node whose seam was hit, plus the
/// total bounds of that split node (needed to convert mouse position → ratio).
pub const DividerHit = struct {
    node: *SplitNode,
    /// Pixel rect that the split node occupies.
    bounds: PaneBounds,
};

pub const SplitNode = struct {
    kind: Kind,
    pane: ?*Pane = null,
    first: ?*SplitNode = null,
    second: ?*SplitNode = null,
    direction: SplitDirection = .vertical,
    ratio: f32 = 0.5,

    pub const Kind = enum {
        pane,
        split,
    };

    pub fn initPane(pane: *Pane) SplitNode {
        return .{
            .kind = .pane,
            .pane = pane,
        };
    }

    pub fn initSplit(first: *SplitNode, second: *SplitNode, direction: SplitDirection, ratio: f32) SplitNode {
        return .{
            .kind = .split,
            .first = first,
            .second = second,
            .direction = direction,
            .ratio = std.math.clamp(ratio, 0.05, 0.95),
        };
    }

    pub fn deinit(self: *SplitNode, allocator: std.mem.Allocator) void {
        if (self.first) |first| {
            first.deinit(allocator);
            allocator.destroy(first);
        }
        if (self.second) |second| {
            second.deinit(allocator);
            allocator.destroy(second);
        }
        self.* = undefined;
    }
};
