const App = @import("../app.zig").App;
const lua = @import("../lua_bridge.zig");
const mux_ops = @import("session_controller.zig");
const selection = @import("selection.zig");
const Pane = @import("../pane.zig").Pane;
const Action = lua.MenuAction;
const log = @import("std").log;

pub const Request = struct {
    pane: usize,
    action: Action,
    expected: ?usize,
    workspace: ?usize,
    tab: ?usize,
    generation: u64,
};

fn target(app: *App, id: usize) ?*Pane {
    if (!app.window_focused) return null;
    const mux = if (app.mux) |*value| value else return null;
    const pane = app.findPaneById(id) orelse return null;
    if (!pane.isTerminal() or pane.is_hidden) return null;
    if (!mux.activeTabContainsPane(pane) and !mux.dockIsShown(pane)) return null;
    if (mux.activeTab()) |tab| {
        if (tab.maximized_pane != null and tab.maximized_pane != pane and !tab.maximized_show_background and !mux.dockIsShown(pane)) return null;
    }
    return pane;
}

fn query(app: *App, id: usize, action: Action) ?usize {
    const pane = target(app, id) orelse return null;
    const mux = &app.mux.?;
    const tab = mux.activeTab();
    const dock = mux.paneDock(pane);
    const controller = mux.controllerForPane(id);
    const can_write = if (controller) |owner| !owner.taken and !owner.detached else true;
    return switch (action) {
        .target, .close => 1,
        .paste => if (can_write) 1 else null,
        .copy => if (selection.selectionHistoryRange(app, pane) != null) @intCast(app.selection_generation) else null,
        .split_right, .split_down => if (dock == null and can_write) 1 else null,
        .float => if (dock == null) (if (pane.is_floating) 2 else 1) else null,
        .zoom => if (dock == null) (if (mux.paneIsMaximized(pane)) 2 else 1) else null,
        .hide => blk: {
            if (dock != null) break :blk 1;
            for ((tab orelse break :blk null).panes.items) |other| {
                if (other != pane and !other.is_hidden) break :blk 1;
            }
            break :blk null;
        },
        .dock => blk: {
            const ws = mux.activeWorkspace() orelse break :blk null;
            if (dock != null) break :blk if (tab != null and mux.controllerForPane(id) == ws.session_controller) 2 else null;
            break :blk if ((tab orelse break :blk null).panes.items.len > 1) 1 else null;
        },
        .dock_left, .dock_right, .dock_top, .dock_bottom => if (dock == null and
            (tab orelse return null).panes.items.len > 1 and mux.dockOccupant(.workspace, action.dockEdge().?) == null) 1 else null,
    };
}

pub fn queryCallback(ptr: *anyopaque, id: usize, action: Action) ?usize {
    return query(@ptrCast(@alignCast(ptr)), id, action);
}

pub fn actionCallback(ptr: *anyopaque, id: usize, action: Action, expected: ?usize) bool {
    const app: *App = @ptrCast(@alignCast(ptr));
    const mux = if (app.mux) |*value| value else return false;
    return app.enqueueMouse(.{ .menu_action = .{
        .pane = id,
        .action = action,
        .expected = expected,
        .workspace = if (mux.activeWorkspace()) |ws| ws.id else null,
        .tab = if (mux.activeTab()) |tab| tab.id else null,
        .generation = if (app.lua) |runtime| runtime.generation else return false,
    } });
}

pub fn dispatch(app: *App, request: Request) void {
    const mux = if (app.mux) |*value| value else return;
    if ((if (mux.activeWorkspace()) |ws| @as(?usize, ws.id) else null) != request.workspace or
        (if (mux.activeTab()) |tab| @as(?usize, tab.id) else null) != request.tab) return;
    if (app.lua == null or app.lua.?.generation != request.generation) return;
    const id = request.pane;
    const value = query(app, id, request.action) orelse return;
    if (request.expected) |expected| if (expected != value) return;
    switch (request.action) {
        .target => {},
        .copy => selection.copySelectionToClipboard(app) catch |err| log.err("copy selection failed: {s}", .{@errorName(err)}),
        .paste => mux_ops.sendPasteToPane(app, id, app.readClipboard()) catch |err| {
            if (err != error.UnsafePaste) log.err("paste failed: {s}", .{@errorName(err)});
        },
        .split_right, .split_down => mux_ops.splitPaneTarget(app, id, if (request.action == .split_right) .vertical else .horizontal, 0.5, null, null, null, .send, false, false, false, null, null, null, null, -2, null, null),
        .float => mux_ops.setPaneFloatingById(app, id, value == 1),
        .hide => mux_ops.setPaneVisibleById(app, id, false),
        .zoom => mux_ops.togglePaneMaximizedById(app, id, false),
        .dock => if (value == 2) mux_ops.undockPaneById(app, id),
        .dock_left, .dock_right, .dock_top, .dock_bottom => mux_ops.dockPaneById(app, id, request.action.dockEdge().?, .workspace, 0.3),
        .close => mux_ops.closePaneById(app, id),
    }
}
