// Facade re-exporting the split mux modules. Existing imports of
// `@import("mux.zig")` continue to work unchanged.
const types = @import("mux/types.zig");
const layout = @import("mux/layout.zig");
const tab_mod = @import("mux/tab.zig");
const workspace_mod = @import("mux/workspace.zig");
const mux_mod = @import("mux/mux.zig");

// Pull test definitions into the build's test discovery graph.
pub const tests = @import("mux/tests.zig");

pub const FocusDirection = types.FocusDirection;
pub const SplitDirection = types.SplitDirection;
pub const PaneBounds = types.PaneBounds;
pub const LayoutLeaf = types.LayoutLeaf;
pub const MAX_LAYOUT_LEAVES = types.MAX_LAYOUT_LEAVES;
pub const DividerHit = types.DividerHit;
pub const SplitNode = types.SplitNode;

pub const Tab = tab_mod.Tab;
pub const Workspace = workspace_mod.Workspace;
pub const Mux = mux_mod.Mux;

pub const layoutSplitTree = layout.layoutSplitTree;
pub const hitTestDivider = layout.hitTestDivider;
pub const boundsForNode = layout.boundsForNode;
pub const nodeIsInTree = layout.nodeIsInTree;
