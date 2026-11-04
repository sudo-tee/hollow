const std = @import("std");
const App = @import("../app.zig").App;
const Pane = @import("../pane.zig").Pane;
const search = @import("../term/search.zig");
const scroll = @import("scroll.zig");

pub const Operation = enum { query, next, prev, close };
pub const State = struct {
    pane_id: ?usize = null,
    session: usize = 0,
    query: []u8 = &.{},
    engine: search.Search = .{},
    index: ?usize = null,
    pending: ?bool = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.engine.deinit(allocator);
        allocator.free(self.query);
        self.* = .{};
    }
};

pub fn request(app: *App, pane_id: usize, session: usize, operation: Operation, query: []const u8) !void {
    if (operation == .close) {
        if (app.find.pane_id == pane_id and app.find.session == session) close(app);
        return;
    }
    if (session <= app.find_cancelled_session) return;
    const pane = app.findPaneById(pane_id) orelse {
        reject(app, pane_id, session);
        return;
    };
    if (!pane.isTerminal() or app.activePane() != pane or app.copy_mode_active) {
        reject(app, pane_id, session);
        return;
    }
    if (operation == .query) {
        const owned = try app.allocator.dupe(u8, query);
        errdefer app.allocator.free(owned);
        if (app.find.pane_id != pane_id or app.find.session != session) close(app);
        try app.find.engine.setNeedle(app.allocator, pane.asTerminal().?.terminal, query);
        app.allocator.free(app.find.query);
        app.find.query = owned;
        app.find.pane_id = pane_id;
        app.find.session = session;
        app.find.index = null;
        app.find.pending = if (query.len > 0) true else null;
        invalidate(app, pane);
        emit(app);
    } else if (app.find.pane_id == pane_id and app.find.session == session) {
        jump(app, operation == .next);
    }
}

fn reject(app: *App, pane_id: usize, session: usize) void {
    app.emitLuaBuiltInEvent("terminal_find:changed", .{ .terminal_find = .{ .pane_id = pane_id, .session = session, .active = false } });
}

pub fn close(app: *App) void {
    const pane_id = app.find.pane_id;
    const session = app.find.session;
    app.find.deinit(app.allocator);
    if (pane_id) |id| {
        if (app.findPaneById(id)) |pane| invalidate(app, pane);
        reject(app, id, session);
    }
}

fn invalidate(app: *App, pane: *Pane) void {
    pane.render_dirty = .full;
    if (app.renderer) |*renderer| renderer.invalidatePaneCache(pane);
}

fn emit(app: *App) void {
    const state = &app.find;
    app.emitLuaBuiltInEvent("terminal_find:changed", .{ .terminal_find = .{
        .pane_id = state.pane_id orelse return,
        .session = state.session,
        .active = true,
        .query = state.query,
        .match_count = state.engine.matches.items.len,
        .match_index = if (state.index) |i| state.engine.matches.items.len - i else null,
        .complete = state.engine.complete,
    } });
}

pub fn tick(app: *App) !void {
    const pane_id = app.find.pane_id orelse return;
    const pane = app.findPaneById(pane_id) orelse {
        close(app);
        return;
    };
    if (app.activePane() != pane or !pane.isTerminal() or app.copy_mode_active or app.find.session <= app.find_cancelled_session) {
        close(app);
        return;
    }
    const state = &app.find;
    const old_count = state.engine.matches.items.len;
    const old_complete = state.engine.complete;
    const old_index = state.index;
    const old_revision = state.engine.revision;
    const selected = if (old_index) |i| if (i < old_count) state.engine.matches.items[i] else null else null;
    try state.engine.step(app.allocator);
    state.index = null;
    if (selected) |old| {
        for (state.engine.matches.items, 0..) |match, i| {
            if (std.meta.eql(old, match)) {
                state.index = i;
                break;
            }
        }
    }
    if (state.pending) |forward| {
        if (state.engine.matches.items.len > 0) jump(app, forward);
        if (state.engine.complete) state.pending = null;
    }
    // Terminal writes can move highlights even when their count is unchanged.
    // Repaint the search pane, but only send Lua progress when it changes.
    if (old_revision != state.engine.revision) invalidate(app, pane);
    if (old_count != state.engine.matches.items.len or old_complete != state.engine.complete or old_index != state.index) emit(app);
}

fn jump(app: *App, forward: bool) void {
    const state = &app.find;
    const count = state.engine.matches.items.len;
    if (count == 0) {
        state.pending = if (!state.engine.complete) forward else null;
        return;
    }
    // Enter follows native search's direction: newest to oldest into history.
    const index = if (state.index) |i|
        if (forward) (i + count - 1) % count else (i + 1) % count
    else if (forward) count - 1 else 0;
    state.index = index;
    state.pending = null;
    const pane = app.findPaneById(state.pane_id orelse return) orelse return;
    const match = state.engine.matches.items[index];
    scroll.scrollPaneViewportToRow(app, pane, match.start.row -| (@as(usize, pane.rows) / 2));
    invalidate(app, pane);
    emit(app);
}

pub fn highlightForCell(app: *const App, pane: *const Pane, row: usize, col: usize) ?bool {
    if (app.find.pane_id != pane.id) return null;
    const term = pane.asTerminalConst() orelse return null;
    const top: usize = @intCast(scroll.scrollbarTopRow(term.scrollbar()));
    const point = search.Point{ .row = top + row, .col = col };
    // Prefer selected match when a match overlaps another range.
    if (app.find.index) |i| {
        if (i < app.find.engine.matches.items.len and contains(app.find.engine.matches.items[i], point)) return true;
    }
    const matches = app.find.engine.matches.items;
    // Locate the last match starting at/before this cell, then test its end.
    var left: usize = 0;
    var right = matches.len;
    while (left < right) {
        const mid = left + (right - left) / 2;
        if (before(point, matches[mid].start)) right = mid else left = mid + 1;
    }
    if (left > 0 and contains(matches[left - 1], point)) return false;
    return null;
}

fn before(a: search.Point, b: search.Point) bool {
    return a.row < b.row or (a.row == b.row and a.col < b.col);
}

fn contains(match: search.Match, point: search.Point) bool {
    return !before(point, match.start) and before(point, match.end);
}

test "terminal find ranges cover wrapped matches with exclusive endpoints" {
    const match = search.Match{ .start = .{ .row = 1, .col = 5 }, .end = .{ .row = 3, .col = 2 } };
    try std.testing.expect(!contains(match, .{ .row = 1, .col = 4 }));
    try std.testing.expect(contains(match, .{ .row = 1, .col = 5 }));
    try std.testing.expect(contains(match, .{ .row = 2, .col = 0 }));
    try std.testing.expect(contains(match, .{ .row = 3, .col = 1 }));
    try std.testing.expect(!contains(match, .{ .row = 3, .col = 2 }));
}

test "terminal find navigates without copy snapshots highlights all matches and cancels stale sessions" {
    const allocator = std.testing.allocator;
    const app = try allocator.create(App);
    defer allocator.destroy(app);
    app.* = App.init(allocator);
    defer app.deinit();
    app.ghostty = try @import("../term/ghostty.zig").Runtime.init(allocator, null);
    const runtime = &app.ghostty.?;
    app.mux = @import("../mux.zig").Mux.init(allocator);
    const mux = &app.mux.?;
    const Workspace = @import("../mux/workspace.zig").Workspace;
    const workspace = try allocator.create(Workspace);
    workspace.* = Workspace.init(allocator, 1);
    try mux.workspaces.append(allocator, workspace);
    mux.active_workspace = workspace;
    const tab = try workspace.newTab(2, false);
    const pane = try allocator.create(Pane);
    pane.* = Pane.init(allocator);
    pane.id = 3;
    pane.cols = 20;
    pane.rows = 3;
    pane.content.terminal.terminal = try runtime.createTerminal(20, 3, 0);
    try tab.appendPane(pane);
    runtime.terminalWrite(pane.content.terminal.terminal, "foo foo");
    try request(app, pane.id, 1, .query, "foo");
    for (0..1000) |_| {
        try tick(app);
        if (app.find.engine.complete) break;
    }
    try std.testing.expect(!app.copy_mode_active);
    try std.testing.expectEqual(@as(usize, 0), app.copy_mode_history.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.find.engine.matches.items.len);
    try std.testing.expectEqual(@as(?usize, 1), app.find.index);
    try std.testing.expectEqual(@as(?bool, false), highlightForCell(app, pane, 0, 0));
    try std.testing.expectEqual(@as(?bool, true), highlightForCell(app, pane, 0, 4));
    try std.testing.expectEqual(@as(?bool, null), highlightForCell(app, pane, 0, 3));
    try request(app, pane.id, 1, .next, "");
    try std.testing.expectEqual(@as(?usize, 0), app.find.index);
    try request(app, pane.id, 1, .next, "");
    try std.testing.expectEqual(@as(?usize, 1), app.find.index);
    try request(app, pane.id, 1, .prev, "");
    try std.testing.expectEqual(@as(?usize, 0), app.find.index);

    try request(app, pane.id, 2, .query, "foo");
    try request(app, pane.id, 1, .close, "");
    try std.testing.expectEqual(@as(usize, 2), app.find.session);
    // Cancellation is an allocation-free barrier against already queued edits.
    try std.testing.expect(@import("lua_callbacks.zig").luaTerminalFindCallback(app, pane.id, 2, "close", ""));
    try tick(app);
    try std.testing.expect(app.find.pane_id == null);
    try request(app, pane.id, 2, .query, "stale edit");
    try std.testing.expect(app.find.pane_id == null);
    try request(app, pane.id, 3, .query, "");
    try tick(app);
    try std.testing.expectEqual(@as(usize, 0), app.find.engine.matches.items.len);
    tab.active_pane = null;
    try tick(app);
    try std.testing.expect(app.find.pane_id == null);
    tab.active_pane = pane;
    try request(app, pane.id, 4, .query, "foo");
    app.copy_mode_active = true;
    try tick(app);
    try std.testing.expect(app.find.pane_id == null);
}
