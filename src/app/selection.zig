const std = @import("std");
const c = @import("sokol_c");
const ghostty = @import("../term/ghostty.zig");
const GhosttyRuntime = ghostty.Runtime;
const selection = @import("../selection.zig");
const text_helpers = @import("text_helpers.zig");
const scroll = @import("scroll.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Pane = @import("../pane.zig").Pane;
const CLIPBOARD_EVENT_MAX = 8192;

pub fn pointTagForHistoryRow(row: usize, scrollback_rows: usize) ghostty.PointTag {
    return if (row < scrollback_rows) .history else .screen;
}

pub fn pointYForHistoryRow(row: usize, scrollback_rows: usize) u32 {
    _ = scrollback_rows;
    return @intCast(row);
}

pub fn gridRefForHistoryPoint(runtime: *GhosttyRuntime, terminal: ?*anyopaque, row: usize, col: usize, scrollback_rows: usize) ?ghostty.GridRef {
    var ref: ghostty.GridRef = undefined;
    const point = ghostty.Point{
        .tag = pointTagForHistoryRow(row, scrollback_rows),
        .value = .{ .coordinate = .{ .x = @intCast(col), .y = pointYForHistoryRow(row, scrollback_rows) } },
    };
    if (runtime.terminal_grid_ref(terminal, point, &ref) != ghostty.success) return null;
    return ref;
}

pub fn historySelectionRangeInViewport(history_range: selection.Range, visible_top: usize, visible_rows: usize) ?selection.Range {
    if (visible_rows == 0) return null;
    const visible_bottom = visible_top + visible_rows;
    if (history_range.start.row >= visible_bottom or history_range.end.row < visible_top) return null;

    const max_visible_row = visible_rows - 1;
    return .{
        .start = .{
            .row = if (history_range.start.row < visible_top) 0 else history_range.start.row - visible_top,
            .col = if (history_range.start.row < visible_top) 0 else history_range.start.col,
        },
        .end = .{
            .row = if (history_range.end.row >= visible_bottom) max_visible_row else history_range.end.row - visible_top,
            .col = if (history_range.end.row >= visible_bottom) std.math.maxInt(usize) else history_range.end.col,
        },
    };
}

pub fn selectionRange(self: *const App, pane: *const Pane) ?selection.Range {
    const history_range = selectionHistoryRange(self, pane) orelse return null;
    const scrollbar = if (self.ghostty) |*rt|
        @constCast(rt).terminalScrollbar(pane.terminal) orelse return null
    else
        pane.scrollbar();
    const visible_top: usize = @intCast(scroll.scrollbarTopRow(scrollbar));
    const visible_rows: usize = @intCast(@max(@as(u64, 1), @min(scrollbar.total, scrollbar.len)));
    return historySelectionRangeInViewport(history_range, visible_top, visible_rows);
}

pub fn selectionPointToHistory(self: *App, pane: *Pane, point: selection.CellPoint) selection.CellPoint {
    const scrollbar = if (self.ghostty) |*rt|
        scroll.refreshPaneScrollbar(self, rt, pane)
    else
        pane.scrollbar();
    return .{
        .row = @as(usize, @intCast(scroll.scrollbarTopRow(scrollbar))) + point.row,
        .col = point.col,
    };
}

pub fn gridRefForHistoryRow(self: *const App, pane: *Pane, history_row: usize) ?ghostty.GridRef {
    const runtime = if (self.ghostty) |*rt| @constCast(rt) else return null;
    const scrollbar = runtime.terminalScrollbar(pane.terminal) orelse return null;
    const scrollback_rows: usize = @intCast(scrollbar.total - @min(scrollbar.total, scrollbar.len));
    return gridRefForHistoryPoint(runtime, pane.terminal, history_row, 0, scrollback_rows);
}

pub fn gridRefForHistoryCell(self: *const App, pane: *Pane, history_row: usize, col: usize) ?ghostty.GridRef {
    const runtime = if (self.ghostty) |*rt| @constCast(rt) else return null;
    const scrollbar = runtime.terminalScrollbar(pane.terminal) orelse return null;
    const scrollback_rows: usize = @intCast(scrollbar.total - @min(scrollbar.total, scrollbar.len));
    return gridRefForHistoryPoint(runtime, pane.terminal, history_row, col, scrollback_rows);
}

pub fn selectionHistoryRange(self: *const App, pane: *const Pane) ?selection.Range {
    if (self.selection_pane != pane) return null;
    const anchor = self.selection_anchor orelse return null;
    const head = self.selection_head orelse return null;
    return selection.normalize(anchor, head);
}

pub fn selectionBegin(self: *App, pane: *Pane, point: selection.CellPoint, extend: bool) void {
    if (!self.hasPane(pane)) return;
    if (self.mux) |*mux| {
        const previous = mux.activePane();
        mux.setActivePane(pane);
        self.syncActivePaneChange(previous, pane);
    }
    const history_point = selectionPointToHistory(self, pane, point);
    const had_selection = hasSelection(self);
    const previous_selection_pane = self.selection_pane;
    if (!extend or self.selection_pane != pane or self.selection_anchor == null) {
        self.selection_pane = pane;
        self.selection_anchor = history_point;
    }
    self.selection_head = history_point;
    self.selection_drag_active = true;
    if (previous_selection_pane) |prev| {
        if (prev != pane) prev.render_dirty = .full;
    }
    pane.render_dirty = .full;
    self.selection_generation +%= 1;
    if (had_selection) {
        self.emitLuaBuiltInEvent("selection:cleared", .none);
    }
}

pub fn selectionUpdate(self: *App, pane: *Pane, point: selection.CellPoint) void {
    if (!self.selection_drag_active or self.selection_pane != pane or !self.hasPane(pane)) return;
    const history_point = selectionPointToHistory(self, pane, point);
    if (self.selection_head) |head| {
        if (head.row == history_point.row and head.col == history_point.col) return;
    }
    self.selection_head = history_point;
    pane.render_dirty = .full;
    self.selection_generation +%= 1;
}

pub fn selectionEnd(self: *App) void {
    self.selection_drag_active = false;
    if (hasSelection(self)) {
        self.emitLuaBuiltInEvent("selection:begin", .none);
    }
}

pub fn selectionBeginWord(self: *App, pane: *Pane, point: selection.CellPoint) void {
    if (!self.hasPane(pane)) return;
    if (self.mux) |*mux| {
        const previous = mux.activePane();
        mux.setActivePane(pane);
        self.syncActivePaneChange(previous, pane);
    }
    const history_point = selectionPointToHistory(self, pane, point);
    const had_selection = hasSelection(self);

    const runtime = if (self.ghostty) |*rt| rt else return;
    if (!runtime.populateRowIterator(pane.render_state, &pane.row_iterator)) return;

    var ascii_cols: [4096]u8 = [_]u8{0} ** 4096;
    var col_count: usize = 0;
    var row_index: usize = 0;
    var found_row = false;
    while (runtime.nextRow(pane.row_iterator)) : (row_index += 1) {
        if (row_index != point.row) continue;
        if (!runtime.populateRowCells(pane.row_iterator, &pane.row_cells)) break;
        while (runtime.nextCell(pane.row_cells) and col_count < ascii_cols.len) : (col_count += 1) {
            var cell_buf: [16]u8 = [_]u8{0} ** 16;
            var cell_len: usize = 0;
            text_helpers.appendCellText(runtime, pane.row_cells, &cell_buf, &cell_len);
            ascii_cols[col_count] = if (cell_len == 1 and cell_buf[0] != 0) cell_buf[0] else ' ';
        }
        found_row = true;
        break;
    }

    if (!found_row or col_count == 0 or point.col >= col_count) {
        selectionBegin(self, pane, point, false);
        return;
    }

    const isWordChar = struct {
        fn call(ch: u8) bool {
            return ch != ' ' and ch != '\t' and ch >= 0x21;
        }
    }.call;

    if (!isWordChar(ascii_cols[point.col])) {
        selectionBegin(self, pane, point, false);
        return;
    }

    var start = point.col;
    while (start > 0 and isWordChar(ascii_cols[start - 1])) : (start -= 1) {}
    var end = point.col;
    while (end + 1 < col_count and isWordChar(ascii_cols[end + 1])) : (end += 1) {}

    if (had_selection) {
        self.emitLuaBuiltInEvent("selection:cleared", .none);
    }
    self.selection_pane = pane;
    self.selection_anchor = .{ .row = history_point.row, .col = start };
    self.selection_head = .{ .row = history_point.row, .col = end };
    self.selection_drag_active = false;
    pane.render_dirty = .full;
    self.selection_generation +%= 1;
    self.emitLuaBuiltInEvent("selection:begin", .none);
}

pub fn selectionBeginLine(self: *App, pane: *Pane, point: selection.CellPoint) void {
    if (!self.hasPane(pane)) return;
    if (self.mux) |*mux| {
        const previous = mux.activePane();
        mux.setActivePane(pane);
        self.syncActivePaneChange(previous, pane);
    }
    const history_point = selectionPointToHistory(self, pane, point);
    const had_selection = hasSelection(self);

    const cols = @max(@as(usize, 1), @as(usize, pane.cols));
    if (had_selection) {
        self.emitLuaBuiltInEvent("selection:cleared", .none);
    }
    self.selection_pane = pane;
    self.selection_anchor = .{ .row = history_point.row, .col = 0 };
    self.selection_head = .{ .row = history_point.row, .col = cols - 1 };
    self.selection_drag_active = false;
    pane.render_dirty = .full;
    self.selection_generation +%= 1;
    self.emitLuaBuiltInEvent("selection:begin", .none);
}

pub fn clearSelection(self: *App) void {
    const pane = self.selection_pane;
    self.selection_pane = null;
    self.selection_anchor = null;
    self.selection_head = null;
    self.selection_drag_active = false;
    if (pane) |p| p.render_dirty = .full;
    self.selection_generation +%= 1;
    self.emitLuaBuiltInEvent("selection:cleared", .none);
}

pub fn hasSelection(self: *const App) bool {
    if (self.selection_pane == null) return false;
    return selectionHistoryRange(self, self.selection_pane.?) != null;
}

pub fn copySelectionToClipboard(self: *App) !void {
    const pane = self.selection_pane orelse return;
    if (!self.hasPane(pane)) {
        pruneSelectionIfInvalid(self);
        return;
    }
    const range = selectionHistoryRange(self, pane) orelse return;
    var text_buf: [CLIPBOARD_EVENT_MAX]u8 = undefined;
    const text = captureSelectionText(self, pane, range, text_buf[0 .. text_buf.len - 1]) orelse return;
    if (text.len == 0) return;
    text_buf[text.len] = 0;
    c.sapp_set_clipboard_string(@ptrCast(text_buf[0..text.len :0].ptr));
    clearSelection(self);
}

fn captureSelectionText(self: *App, pane: *Pane, range: selection.Range, out: []u8) ?[]const u8 {
    const runtime = if (self.ghostty) |*rt| rt else return null;
    if (self.selection_pane != pane) return null;

    var writer = std.io.fixedBufferStream(out);
    var row_index = range.start.row;
    while (row_index <= range.end.row) : (row_index += 1) {
        var row_text: [4096]u8 = undefined;
        var row_len: usize = 0;
        var col_index: usize = 0;

        while (true) : (col_index += 1) {
            const cell_ref = gridRefForHistoryCell(self, pane, row_index, col_index) orelse break;
            const raw_cell = runtime.gridRefCell(&cell_ref) orelse break;
            if (!selection.cellSelected(range, row_index, col_index)) continue;
            text_helpers.appendGridRefText(runtime, &cell_ref, raw_cell, row_text[0..], &row_len);
        }
        while (row_len > 0 and row_text[row_len - 1] == ' ') row_len -= 1;
        writer.writer().writeAll(row_text[0..row_len]) catch break;
        if (row_index == range.end.row) break;
        writer.writer().writeByte('\n') catch break;
    }

    return writer.getWritten();
}

pub fn pruneSelectionIfInvalid(self: *App) void {
    const pane = self.selection_pane orelse return;
    if (self.hasPane(pane) and self.isPaneVisible(pane)) return;
    self.selection_pane = null;
    self.selection_anchor = null;
    self.selection_head = null;
    self.selection_drag_active = false;
    self.selection_generation +%= 1;
    self.emitLuaBuiltInEvent("selection:cleared", .none);
}

pub fn syncDraggedSelectionToPointer(self: *App, pane: *Pane) void {
    if (!self.selection_drag_active or self.selection_pane != pane) return;
    const hit = self.hitTestPane(self.pointer_x, self.pointer_y) orelse return;
    if (hit.pane != pane) return;
    selectionUpdate(self, pane, cellPointFromPaneLocal(self, pane, hit.x, hit.y));
}

pub fn cellPointFromPaneLocal(self: *const App, pane: *const Pane, x: f32, y: f32) selection.CellPoint {
    const cols = @max(@as(usize, 1), @as(usize, pane.cols));
    const rows = @max(@as(usize, 1), @as(usize, pane.rows));
    const cell_w = @max(self.cell_width_px, @as(u32, 1));
    const cell_h = @max(self.cell_height_px, @as(u32, 1));
    const col = @min(cols - 1, @as(usize, @intFromFloat(@max(0, x) / @as(f32, @floatFromInt(cell_w)))));
    const row = @min(rows - 1, @as(usize, @intFromFloat(@max(0, y) / @as(f32, @floatFromInt(cell_h)))));
    return .{ .row = row, .col = col };
}

test "history selection range projects into viewport bounds" {
    const within = historySelectionRangeInViewport(.{
        .start = .{ .row = 8, .col = 3 },
        .end = .{ .row = 11, .col = 4 },
    }, 5, 10).?;
    try std.testing.expectEqual(@as(usize, 3), within.start.row);
    try std.testing.expectEqual(@as(usize, 3), within.start.col);
    try std.testing.expectEqual(@as(usize, 6), within.end.row);
    try std.testing.expectEqual(@as(usize, 4), within.end.col);
}
