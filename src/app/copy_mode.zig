const std = @import("std");
const builtin = @import("builtin");
const fastmem = @import("../fastmem.zig");
const c = @import("sokol_c");
const ghostty = @import("../term/ghostty.zig");
const GhosttyRuntime = ghostty.Runtime;
const selection = @import("../selection.zig");
const Pane = @import("../pane.zig").Pane;
const text_helpers = @import("text_helpers.zig");
const selection_mod = @import("selection.zig");
const scroll = @import("scroll.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const CopyModeMoveKind = app_mod.CopyModeMoveKind;
const PromptJumpDir = app_mod.PromptJumpDir;

pub const PromptJumpSource = union(enum) {
    live: struct {
        runtime: *GhosttyRuntime,
        terminal: ?*anyopaque,
    },
    copy_mode: []const CopyModeLine,
};

pub const CopyModePoint = struct {
    row: usize = 0,
    col: usize = 0,
};

pub const copy_mode_default_style_color = ghostty.StyleColor{ .tag = .none, .value = .{ .palette = 0 } };

pub const CopyModeCell = struct {
    text: []u8 = &.{},
    fg: ghostty.ColorRgb = .{ .r = 0, .g = 0, .b = 0 },
    bg: ?ghostty.ColorRgb = null,
    fg_style: ghostty.StyleColor = copy_mode_default_style_color,
    bg_style: ghostty.StyleColor = copy_mode_default_style_color,
    face_idx: u8 = 0,
};

pub const CopyModeLine = struct {
    text: []u8 = &.{},
    col_offsets: []u32 = &.{},
    cells: []CopyModeCell = &.{},
    cols: usize = 0,
    is_prompt: bool = false,
};

pub const CopyModeMatch = struct {
    row: usize,
    start_col: usize,
    end_col: usize,
};

pub const CopyModeSnapshotLine = struct {
    text: []const u8,
    cells: []const CopyModeCell,
    cols: usize,
};

pub const SearchHighlight = struct {
    row: usize,
    start_col: usize,
    end_col: usize,
    active: bool = false,
};

fn copyModeRowIndexInViewport(target_row: usize, visible_top: usize, visible_rows: usize) ?usize {
    if (target_row < visible_top) return null;
    const row_index = target_row - visible_top;
    if (row_index >= visible_rows) return null;
    return row_index;
}

pub fn copyModeSelectionRange(self: *const App, pane: *const Pane) ?selection.Range {
    if (!self.copy_mode_active or self.copy_mode_pane != pane) return null;
    const range = copyModeVisibleRange(self) orelse return null;
    if (range.start.row == range.end.row and range.start.col == range.end.col) return null;
    return range;
}

pub fn copyModeActiveForPane(self: *const App, pane: ?*const Pane) bool {
    const value = pane orelse return false;
    return self.copy_mode_active and self.copy_mode_pane == value;
}

pub fn copyModeCursorColForRow(self: *const App, pane: *const Pane, row: usize) ?usize {
    if (!self.copy_mode_active or self.copy_mode_pane != pane) return null;
    const visible_top = copyModeVisibleTopRow(self) orelse return null;
    if (self.copy_mode_cursor.row != visible_top + row) return null;
    return self.copy_mode_cursor.col;
}

pub fn copyModeActive(self: *const App) bool {
    return self.copy_mode_active;
}

pub fn copyModeSnapshotLineForRow(self: *const App, pane: *const Pane, row: usize) ?CopyModeSnapshotLine {
    if (!self.copy_mode_active or self.copy_mode_pane != pane) return null;
    const visible_top = copyModeVisibleTopRow(self) orelse return null;
    const history_row = visible_top + row;
    if (history_row >= self.copy_mode_history.items.len) return null;
    const line = self.copy_mode_history.items[history_row];
    return .{ .text = line.text, .cells = line.cells, .cols = line.cols };
}

pub fn searchHighlightForRow(self: *const App, pane: *const Pane, row: usize) ?SearchHighlight {
    if (!self.copy_mode_active or self.copy_mode_pane != pane) return null;
    if (self.copy_mode_matches.items.len == 0) return null;
    const visible_top = copyModeVisibleTopRow(self) orelse return null;
    const history_row = visible_top + row;
    const active_idx = self.copy_mode_match_index;
    var fallback: ?SearchHighlight = null;
    for (self.copy_mode_matches.items, 0..) |match, index| {
        if (match.row != history_row) continue;
        const highlight = SearchHighlight{
            .row = row,
            .start_col = match.start_col,
            .end_col = match.end_col,
            .active = active_idx != null and active_idx.? == index,
        };
        if (highlight.active) return highlight;
        if (fallback == null) fallback = highlight;
    }
    return fallback;
}

fn copyModeVisibleRows(self: *const App, pane: *const Pane) usize {
    const fallback = @max(@as(usize, 1), @as(usize, pane.rows));
    const runtime = if (self.ghostty) |*rt| @constCast(rt) else return fallback;
    if (runtime.terminalScrollbar(pane.terminal)) |scrollbar| {
        return @max(@as(usize, 1), @as(usize, @intCast(scrollbar.len)));
    }
    if (!pane.render_state_ready or pane.render_state == null) return fallback;
    const rows = runtime.renderStateRows(pane.render_state) orelse return fallback;
    return @max(@as(usize, 1), @as(usize, @intCast(rows)));
}

fn syncCopyModeTopRowFromViewport(self: *App, pane: *Pane) void {
    const runtime = if (self.ghostty) |*rt| rt else return;
    const scrollbar = scroll.refreshPaneScrollbar(self, runtime, pane);
    self.copy_mode_top_row = @intCast(scroll.scrollbarTopRow(scrollbar));
}

fn copyModeVisibleTopRow(self: *const App) ?usize {
    const pane = self.copy_mode_pane orelse return null;
    const visible_rows = copyModeVisibleRows(self, pane);
    const max_top = self.copy_mode_history.items.len -| visible_rows;
    return @min(self.copy_mode_top_row, max_top);
}

fn copyModeVisibleRange(self: *const App) ?selection.Range {
    const pane = self.copy_mode_pane orelse return null;
    const anchor = self.copy_mode_anchor orelse return null;
    const top = copyModeVisibleTopRow(self) orelse return null;
    const cursor = self.copy_mode_cursor;
    const start_row = anchor.row -| top;
    const end_row = cursor.row -| top;
    if (anchor.row < top and cursor.row < top) return null;
    const max_visible_row = copyModeVisibleRows(self, pane) - 1;
    if (start_row > max_visible_row and end_row > max_visible_row) return null;
    const start = selection.CellPoint{ .row = @min(max_visible_row, start_row), .col = anchor.col };
    const end_ = selection.CellPoint{ .row = @min(max_visible_row, end_row), .col = cursor.col };
    if (self.copy_mode_block_selection) return selection.normalizeBlock(start, end_);
    return selection.normalize(start, end_);
}

fn copyModeAlignTopRowForCursor(self: *App, target_row: usize) void {
    const pane = self.copy_mode_pane orelse return;
    const visible_rows = copyModeVisibleRows(self, pane);
    const top = copyModeVisibleTopRow(self) orelse 0;
    const aligned_top = alignedTopRowForTarget(top, visible_rows, target_row);
    self.copy_mode_top_row = aligned_top;
    scroll.scrollPaneViewportToRow(self, pane, aligned_top);
    syncCopyModeTopRowFromViewport(self, pane);
    refreshCopyModeVisibleSlice(self, pane) catch {};
}

pub fn enterCopyMode(self: *App) void {
    const pane = self.activePane() orelse return;
    const runtime = if (self.ghostty) |*rt| rt else null;
    const top = if (runtime) |rt|
        blk: {
            const scrollbar = scroll.refreshPaneScrollbar(self, rt, pane);
            break :blk @as(usize, @intCast(scroll.scrollbarTopRow(scrollbar)));
        }
    else
        0;
    self.copy_mode_pane = pane;
    self.copy_mode_active = true;
    self.copy_mode_anchor = null;
    self.copy_mode_block_selection = false;
    self.copy_mode_match_index = null;
    self.copy_mode_restore_top_row = top;
    self.copy_mode_top_row = top;
    self.copy_mode_needs_refresh = true;
    const visible_rows = copyModeVisibleRows(self, pane);
    self.copy_mode_top_row = top;
    self.copy_mode_cursor = .{
        .row = top + visible_rows - 1,
        .col = 0,
    };
    pane.render_dirty = .full;
    emitCopyModeChanged(self);
}

pub fn exitCopyMode(self: *App) void {
    const pane = self.copy_mode_pane;
    self.copy_mode_active = false;
    self.copy_mode_pane = null;
    self.copy_mode_anchor = null;
    self.copy_mode_top_row = 0;
    const restore_top = self.copy_mode_restore_top_row;
    self.copy_mode_restore_top_row = 0;
    self.copy_mode_match_index = null;
    selection_mod.clearSelection(self);
    if (pane) |value| {
        if (self.renderer) |*renderer| renderer.invalidatePaneCache(value);
        scroll.scrollPaneViewportToRow(self, value, restore_top);
        value.render_state_fresh = false;
        value.last_render_state_update_ns = 0;
        value.pty_received_data = true;
        value.render_dirty = .full;
    }
    emitCopyModeChanged(self);
}

fn emitCopyModeChanged(self: *App) void {
    self.emitLuaBuiltInEvent("copy_mode:changed", .{ .copy_mode = .{
        .active = self.copy_mode_active,
        .query = self.copy_mode_query,
        .match_count = self.copy_mode_matches.items.len,
        .match_index = self.copy_mode_match_index,
        .selecting = self.copy_mode_anchor != null,
        .block = self.copy_mode_block_selection,
    } });
}

fn refreshCopyModeSnapshot(self: *App) !void {
    const pane = self.copy_mode_pane orelse return;
    const runtime = if (self.ghostty) |*rt| rt else return;
    if (!self.hasPane(pane)) return;

    for (self.copy_mode_history.items) |line| freeCopyModeLine(self, line);
    self.copy_mode_history.clearRetainingCapacity();
    self.copy_mode_matches.clearRetainingCapacity();
    self.copy_mode_match_index = null;

    const scrollbar = scroll.refreshPaneScrollbar(self, runtime, pane);
    const total_rows: usize = @intCast(scrollbar.total);
    var history_row: usize = 0;
    while (history_row < total_rows) : (history_row += 1) {
        const line = try captureCopyModeLine(self, pane, history_row);
        try self.copy_mode_history.append(self.allocator, line);
    }

    try refreshCopyModeVisibleSlice(self, pane);

    self.copy_mode_needs_refresh = false;
    if (self.copy_mode_query.len > 0) try rebuildCopyModeMatches(self);
}

fn freeCopyModeLine(self: *App, line: CopyModeLine) void {
    if (line.text.len > 0) self.allocator.free(line.text);
    for (line.cells) |cell| {
        if (cell.text.len > 0) self.allocator.free(cell.text);
    }
    if (line.cells.len > 0) self.allocator.free(line.cells);
    if (line.col_offsets.len > 0) self.allocator.free(line.col_offsets);
}

pub fn refreshCopyModeVisibleSlice(self: *App, pane: *Pane) !void {
    const runtime = if (self.ghostty) |*rt| rt else return;
    try syncPaneRenderState(self, runtime, pane);
    const scrollbar = scroll.refreshPaneScrollbar(self, runtime, pane);
    const start_row: usize = @intCast(scroll.scrollbarTopRow(scrollbar));
    const visible_rows: usize = @intCast(@min(scrollbar.total, scrollbar.len));
    if (start_row >= self.copy_mode_history.items.len or visible_rows == 0) return;
    if (!pane.render_state_ready or pane.render_state == null) return;
    if (!runtime.populateRowIterator(pane.render_state, &pane.row_iterator)) return;

    var row_index: usize = 0;
    while (runtime.nextRow(pane.row_iterator) and row_index < visible_rows and start_row + row_index < self.copy_mode_history.items.len) : (row_index += 1) {
        const target_row = start_row + row_index;
        freeCopyModeLine(self, self.copy_mode_history.items[target_row]);
        self.copy_mode_history.items[target_row] = try captureCopyModeVisibleLine(self, pane, target_row, runtime, pane.row_iterator, &pane.row_cells);
    }

    if (self.copy_mode_query.len > 0) {
        const previous_index = self.copy_mode_match_index;
        try rebuildCopyModeMatches(self);
        if (previous_index) |index| {
            if (self.copy_mode_matches.items.len > 0) {
                const next_index = @min(index, self.copy_mode_matches.items.len - 1);
                const match = self.copy_mode_matches.items[next_index];
                self.copy_mode_match_index = next_index;
                self.copy_mode_cursor = .{ .row = match.row, .col = match.start_col };
                self.copy_mode_anchor = .{ .row = match.row, .col = match.end_col -| 1 };
            }
        }
    }
}

fn syncPaneRenderState(self: *App, runtime: *GhosttyRuntime, pane: *Pane) !void {
    if (!pane.render_state_ready or pane.render_state == null) return;
    runtime.clearRenderStateDirty(pane.render_state);
    try runtime.updateRenderState(pane.render_state, pane.terminal);
    pane.last_render_state_update_ns = std.time.nanoTimestamp();
    pane.pty_received_data = false;
    pane.render_state_fresh = false;
    _ = scroll.refreshPaneScrollbar(self, runtime, pane);
}

fn captureCopyModeLine(self: *App, pane: *Pane, history_row: usize) !CopyModeLine {
    const runtime = if (self.ghostty) |*rt| rt else return .{};
    var row_text: [4096]u8 = undefined;
    var offsets: [4097]u32 = [_]u32{0} ** 4097;
    var cell_buf: [512]CopyModeCell = undefined;
    var row_cols: usize = 0;
    const row_ref = selection_mod.gridRefForHistoryRow(self, pane, history_row) orelse return .{};
    const row = runtime.gridRefRow(&row_ref) orelse return .{};

    var len: usize = 0;
    while (row_cols < cell_buf.len) : (row_cols += 1) {
        offsets[row_cols] = @intCast(len);
        const cell_ref = selection_mod.gridRefForHistoryCell(self, pane, history_row, row_cols) orelse break;
        const raw_cell = runtime.gridRefCell(&cell_ref) orelse break;
        const cell_text = try captureCopyModeGridRefText(self.allocator, runtime, &cell_ref, raw_cell);
        var style: ghostty.Style = undefined;
        const has_style = runtime.gridRefStyleInto(&cell_ref, &style);
        cell_buf[row_cols] = .{
            .text = cell_text,
            .fg = colorFromGridRefCell(runtime, &cell_ref, raw_cell, true) orelse ghostty.ColorRgb{ .r = 220, .g = 220, .b = 220 },
            .bg = colorFromGridRefCell(runtime, &cell_ref, raw_cell, false),
            .fg_style = if (has_style) style.fg_color else copy_mode_default_style_color,
            .bg_style = if (has_style) style.bg_color else copy_mode_default_style_color,
            .face_idx = if (has_style)
                (if (style.bold and style.italic) 2 else if (style.bold) 1 else if (style.italic) 3 else 0)
            else
                0,
        };
        text_helpers.appendCopyModeCellBytes(row_text[0..], &len, cell_text);
    }
    offsets[@min(offsets.len - 1, row_cols)] = @intCast(len);
    while (len > 0 and row_text[len - 1] == ' ') len -= 1;
    while (row_cols > 0 and offsets[row_cols] > len) row_cols -= 1;
    const owned_offsets = try self.allocator.alloc(u32, row_cols + 1);
    const owned_cells = try self.allocator.alloc(CopyModeCell, row_cols);
    for (owned_offsets, 0..) |*dst, idx| dst.* = offsets[idx];
    for (owned_cells, 0..) |*dst, idx| dst.* = cell_buf[idx];
    return .{
        .text = try self.allocator.dupe(u8, row_text[0..len]),
        .col_offsets = owned_offsets,
        .cells = owned_cells,
        .cols = row_cols,
        .is_prompt = runtime.rowSemanticPrompt(row) == .prompt,
    };
}

fn captureCopyModeVisibleLine(
    self: *App,
    _: *Pane,
    history_row: usize,
    runtime: *GhosttyRuntime,
    row_iterator: ?*anyopaque,
    row_cells: *?*anyopaque,
) !CopyModeLine {
    var row_text: [4096]u8 = undefined;
    var offsets: [4097]u32 = [_]u32{0} ** 4097;
    var cell_buf: [512]CopyModeCell = undefined;
    var row_cols: usize = 0;
    var row: u64 = 0;
    if (row_iterator != null) row = runtime.rowRaw(row_iterator);

    var len: usize = 0;
    if (!runtime.populateRowCells(row_iterator, row_cells)) return .{};
    while (runtime.nextCell(row_cells.*) and row_cols < cell_buf.len) : (row_cols += 1) {
        offsets[row_cols] = @intCast(len);

        var cell_text_buf: [32]u8 = undefined;
        var cell_len: usize = 0;
        text_helpers.appendCellText(runtime, row_cells.*, cell_text_buf[0..], &cell_len);
        const cell_text = try self.allocator.dupe(u8, cell_text_buf[0..cell_len]);

        var style: ghostty.Style = undefined;
        const has_style = runtime.cellStyleInto(row_cells.*, &style);
        cell_buf[row_cols] = .{
            .text = cell_text,
            .fg = runtime.cellForeground(row_cells.*) orelse ghostty.ColorRgb{ .r = 220, .g = 220, .b = 220 },
            .bg = runtime.cellBackground(row_cells.*),
            .fg_style = if (has_style) style.fg_color else copy_mode_default_style_color,
            .bg_style = if (has_style) style.bg_color else copy_mode_default_style_color,
            .face_idx = if (has_style)
                (if (style.bold and style.italic) 2 else if (style.bold) 1 else if (style.italic) 3 else 0)
            else
                0,
        };
        text_helpers.appendCopyModeCellBytes(row_text[0..], &len, cell_text);
    }

    offsets[@min(offsets.len - 1, row_cols)] = @intCast(len);
    while (len > 0 and row_text[len - 1] == ' ') len -= 1;
    while (row_cols > 0 and offsets[row_cols] > len) row_cols -= 1;
    const owned_offsets = try self.allocator.alloc(u32, row_cols + 1);
    const owned_cells = try self.allocator.alloc(CopyModeCell, row_cols);
    for (owned_offsets, 0..) |*dst, idx| dst.* = offsets[idx];
    for (owned_cells, 0..) |*dst, idx| dst.* = cell_buf[idx];
    return .{
        .text = try self.allocator.dupe(u8, row_text[0..len]),
        .col_offsets = owned_offsets,
        .cells = owned_cells,
        .cols = row_cols,
        .is_prompt = runtime.rowSemanticPrompt(@intCast(history_row)) == .prompt or runtime.rowSemanticPrompt(row) == .prompt,
    };
}

fn rebuildCopyModeMatches(self: *App) !void {
    self.copy_mode_matches.clearRetainingCapacity();
    self.copy_mode_match_index = null;
    if (self.copy_mode_query.len == 0) return;
    if (self.copy_mode_query.len == 0) return;
    for (self.copy_mode_history.items, 0..) |line, row| {
        var start: usize = 0;
        while (true) {
            const match = copyModeRegexFind(self.copy_mode_query, line.text, start) orelse break;
            const start_col = copyModeColumnForByteOffset(line, match.start);
            const end_col = copyModeColumnForByteOffset(line, match.end);
            try self.copy_mode_matches.append(self.allocator, .{
                .row = row,
                .start_col = start_col,
                .end_col = end_col,
            });
            start = match.start + @max(@as(usize, 1), match.end - match.start);
        }
    }
    emitCopyModeChanged(self);
}

pub fn copyModeSetSearchQuery(self: *App, query: []const u8) !void {
    if (self.copy_mode_query.len > 0) self.allocator.free(self.copy_mode_query);
    self.copy_mode_query = try self.allocator.dupe(u8, query);
    if (self.copy_mode_needs_refresh) try refreshCopyModeSnapshot(self);
    try rebuildCopyModeMatches(self);
    copyModeJumpMatch(self, true);
    if (self.copy_mode_matches.items.len == 0) {
        if (self.copy_mode_pane) |pane| pane.render_dirty = .full;
        emitCopyModeChanged(self);
    }
}

pub fn copyModeJumpMatch(self: *App, forward: bool) void {
    if (self.copy_mode_matches.items.len == 0) return;
    const next_index = if (self.copy_mode_match_index) |current|
        if (forward)
            (current + 1) % self.copy_mode_matches.items.len
        else
            (current + self.copy_mode_matches.items.len - 1) % self.copy_mode_matches.items.len
    else if (forward)
        0
    else
        self.copy_mode_matches.items.len - 1;
    self.copy_mode_match_index = next_index;
    const match = self.copy_mode_matches.items[next_index];
    self.copy_mode_cursor = .{ .row = match.row, .col = match.start_col };
    self.copy_mode_anchor = .{ .row = match.row, .col = match.end_col -| 1 };
    if (self.copy_mode_pane) |pane| {
        const visible_rows = copyModeVisibleRows(self, pane);
        const top_target = if (match.row >= visible_rows / 2) match.row - visible_rows / 2 else 0;
        self.copy_mode_top_row = top_target;
        scroll.scrollPaneViewportToRow(self, pane, top_target);
        syncCopyModeTopRowFromViewport(self, pane);
        refreshCopyModeVisibleSlice(self, pane) catch {};
        pane.render_dirty = .full;
    }
    emitCopyModeChanged(self);
}

pub fn copyModeMove(self: *App, kind: CopyModeMoveKind, extend: bool) void {
    const pane = self.copy_mode_pane orelse return;
    if (self.copy_mode_needs_refresh) refreshCopyModeSnapshot(self) catch return;
    if (self.copy_mode_history.items.len == 0) return;

    const previous_cursor = self.copy_mode_cursor;
    var cursor = self.copy_mode_cursor;
    switch (kind) {
        .left => {
            if (cursor.col > 0) cursor.col -= 1;
        },
        .right => cursor.col += 1,
        .up => {
            if (cursor.row > 0) cursor.row -= 1;
        },
        .down => {
            if (cursor.row + 1 < self.copy_mode_history.items.len) cursor.row += 1;
        },
        .page_up => cursor.row -|= copyModeVisibleRows(self, pane) - 1,
        .page_down => cursor.row = @min(self.copy_mode_history.items.len - 1, cursor.row + copyModeVisibleRows(self, pane) - 1),
        .line_start => cursor.col = 0,
        .line_end => cursor.col = self.copy_mode_history.items[cursor.row].cols,
        .top => cursor.row = 0,
        .bottom => cursor.row = self.copy_mode_history.items.len - 1,
    }
    const cols = @max(1, @as(usize, pane.cols));
    cursor.col = @min(cursor.col, cols - 1);
    self.copy_mode_cursor = cursor;
    if (extend) {
        if (self.copy_mode_anchor == null) self.copy_mode_anchor = previous_cursor;
    } else {
        self.copy_mode_anchor = null;
        self.copy_mode_block_selection = false;
    }

    copyModeAlignTopRowForCursor(self, cursor.row);
    pane.render_dirty = .full;
    emitCopyModeChanged(self);
}

pub fn copyModeScrollDelta(self: *App, delta: isize) void {
    const pane = self.copy_mode_pane orelse return;
    if (self.copy_mode_needs_refresh) refreshCopyModeSnapshot(self) catch return;
    const visible_rows = copyModeVisibleRows(self, pane);
    const max_top = self.copy_mode_history.items.len -| visible_rows;
    const current_top: isize = @intCast(copyModeVisibleTopRow(self) orelse 0);
    const min_top: isize = 0;
    const max_top_i: isize = @intCast(max_top);
    const next_top = std.math.clamp(current_top + delta, min_top, max_top_i);
    self.copy_mode_top_row = @intCast(next_top);
    scroll.scrollPaneViewportToRow(self, pane, self.copy_mode_top_row);
    syncCopyModeTopRowFromViewport(self, pane);
    refreshCopyModeVisibleSlice(self, pane) catch {};
    pane.render_dirty = .full;
    emitCopyModeChanged(self);
}

pub fn copyModeScrollToRow(self: *App, top_row: u64) void {
    const pane = self.copy_mode_pane orelse return;
    if (self.copy_mode_needs_refresh) refreshCopyModeSnapshot(self) catch return;
    const visible_rows = copyModeVisibleRows(self, pane);
    const max_top = self.copy_mode_history.items.len -| visible_rows;
    self.copy_mode_top_row = @min(@as(usize, @intCast(top_row)), max_top);
    scroll.scrollPaneViewportToRow(self, pane, self.copy_mode_top_row);
    syncCopyModeTopRowFromViewport(self, pane);
    refreshCopyModeVisibleSlice(self, pane) catch {};
    pane.render_dirty = .full;
    emitCopyModeChanged(self);
}

pub fn copyModeScrollToBottom(self: *App) void {
    const pane = self.copy_mode_pane orelse return;
    if (self.copy_mode_needs_refresh) refreshCopyModeSnapshot(self) catch return;
    const visible_rows = copyModeVisibleRows(self, pane);
    self.copy_mode_top_row = self.copy_mode_history.items.len -| visible_rows;
    scroll.scrollPaneViewportToRow(self, pane, self.copy_mode_top_row);
    syncCopyModeTopRowFromViewport(self, pane);
    refreshCopyModeVisibleSlice(self, pane) catch {};
    pane.render_dirty = .full;
    emitCopyModeChanged(self);
}

pub fn copyModePromptJump(self: *App, direction: PromptJumpDir) void {
    const pane = self.copy_mode_pane orelse return;
    const runtime = if (self.ghostty) |*rt| rt else return;
    const scrollbar = scroll.refreshPaneScrollbar(self, runtime, pane);
    const total: usize = @intCast(scrollbar.total);
    if (total == 0) return;
    const start_row = switch (direction) {
        .next => self.copy_mode_cursor.row +| 1,
        .prev => self.copy_mode_cursor.row -| 1,
    };
    const target_row = findPromptJumpTarget(.{ .live = .{ .runtime = runtime, .terminal = pane.terminal } }, direction, start_row, total) orelse return;
    self.copy_mode_cursor = .{ .row = target_row, .col = 0 };
    self.copy_mode_anchor = null;
    self.copy_mode_block_selection = false;
    copyModeAlignTopRowForCursor(self, target_row);
    pane.render_dirty = .full;
    emitCopyModeChanged(self);
}

pub fn copyModeClearSelection(self: *App) void {
    const pane = self.copy_mode_pane orelse return;
    self.copy_mode_anchor = null;
    self.copy_mode_block_selection = false;
    pane.render_dirty = .full;
    emitCopyModeChanged(self);
}

pub fn copyModeBeginSelection(self: *App) void {
    copyModeBeginSelectionWithBlock(self, false);
}

pub fn copyModeBeginSelectionWithBlock(self: *App, block: bool) void {
    const pane = self.copy_mode_pane orelse return;
    if (self.copy_mode_anchor == null) self.copy_mode_anchor = self.copy_mode_cursor;
    self.copy_mode_block_selection = block;
    pane.render_dirty = .full;
    emitCopyModeChanged(self);
}

pub fn copyModeCopy(self: *App) !void {
    _ = self.copy_mode_pane orelse return;
    if (self.copy_mode_needs_refresh) try refreshCopyModeSnapshot(self);
    const anchor = self.copy_mode_anchor orelse self.copy_mode_cursor;
    const range = normalizeCopyModeRange(anchor, self.copy_mode_cursor);
    var text_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer text_buf.deinit(self.allocator);
    var row = range.start.row;
    while (row <= range.end.row and row < self.copy_mode_history.items.len) : (row += 1) {
        const line = self.copy_mode_history.items[row];
        const start_col = if (row == range.start.row) @min(range.start.col, line.cols) else 0;
        const end_col = if (row == range.end.row) @min(range.end.col + 1, line.cols) else line.cols;
        const start_byte = copyModeByteOffsetForColumn(line, start_col);
        const end_byte = copyModeByteOffsetForColumn(line, end_col);
        if (end_byte > start_byte) try text_buf.appendSlice(self.allocator, line.text[start_byte..end_byte]);
        if (row < range.end.row) try text_buf.append(self.allocator, '\n');
    }
    if (text_buf.items.len == 0) return;
    var clipboard = try self.allocator.alloc(u8, text_buf.items.len + 1);
    defer self.allocator.free(clipboard);
    fastmem.copy(u8, clipboard[0..text_buf.items.len], text_buf.items);
    clipboard[text_buf.items.len] = 0;
    c.sapp_set_clipboard_string(@ptrCast(clipboard[0..text_buf.items.len :0].ptr));
    exitCopyMode(self);
}

fn normalizeCopyModeRange(a: CopyModePoint, b: CopyModePoint) struct { start: CopyModePoint, end: CopyModePoint } {
    if (a.row < b.row or (a.row == b.row and a.col <= b.col)) {
        return .{ .start = a, .end = b };
    }
    return .{ .start = b, .end = a };
}

fn copyModeByteOffsetForColumn(line: CopyModeLine, col: usize) usize {
    if (line.col_offsets.len == 0) return @min(col, line.text.len);
    return @min(@as(usize, line.col_offsets[@min(col, line.col_offsets.len - 1)]), line.text.len);
}

fn copyModeColumnForByteOffset(line: CopyModeLine, byte_offset: usize) usize {
    if (line.col_offsets.len == 0) return @min(byte_offset, line.cols);
    const target: u32 = @intCast(@min(byte_offset, line.text.len));
    var col: usize = 0;
    while (col + 1 < line.col_offsets.len and line.col_offsets[col + 1] <= target) : (col += 1) {}
    return @min(col, line.cols);
}

fn copyModeRegexAtomLen(pattern: []const u8, index: usize) ?usize {
    if (index >= pattern.len) return null;
    if (pattern[index] == '\\') {
        if (index + 1 >= pattern.len) return null;
        return 2;
    }
    return 1;
}

fn copyModeRegexCharMatches(token: []const u8, ch: u8) bool {
    if (token.len == 0) return false;
    if (token.len == 1) return token[0] == '.' or token[0] == ch;
    if (token.len == 2 and token[0] == '\\') {
        return switch (token[1]) {
            'd' => std.ascii.isDigit(ch),
            's' => std.ascii.isWhitespace(ch),
            'w' => std.ascii.isAlphanumeric(ch) or ch == '_',
            't' => ch == '\t',
            'n' => ch == '\n',
            '\\' => ch == '\\',
            '.' => ch == '.',
            '*' => ch == '*',
            '+' => ch == '+',
            '?' => ch == '?',
            '^' => ch == '^',
            '$' => ch == '$',
            else => ch == token[1],
        };
    }
    return false;
}

fn copyModeRegexQuantifier(pattern: []const u8, next_index: usize) ?u8 {
    if (next_index >= pattern.len) return null;
    return switch (pattern[next_index]) {
        '*', '+', '?' => pattern[next_index],
        else => null,
    };
}

fn copyModeRegexMatchFrom(pattern: []const u8, pattern_index: usize, text: []const u8, text_index: usize) ?usize {
    if (pattern_index >= pattern.len) return text_index;
    if (pattern[pattern_index] == '$') {
        if (pattern_index + 1 != pattern.len) return null;
        return if (text_index == text.len) text_index else null;
    }

    const atom_len = copyModeRegexAtomLen(pattern, pattern_index) orelse return null;
    const atom = pattern[pattern_index .. pattern_index + atom_len];
    const quant = copyModeRegexQuantifier(pattern, pattern_index + atom_len);
    const quant_len: usize = if (quant != null) 1 else 0;
    const rest_index = pattern_index + atom_len + quant_len;

    if (quant) |value| {
        var max_count: usize = 0;
        while (text_index + max_count < text.len and copyModeRegexCharMatches(atom, text[text_index + max_count])) : (max_count += 1) {}
        const min_count: usize = if (value == '+') 1 else 0;
        if (value == '?' and max_count > 1) max_count = 1;
        if (max_count < min_count) return null;

        var count = max_count + 1;
        while (count > min_count) {
            count -= 1;
            if (copyModeRegexMatchFrom(pattern, rest_index, text, text_index + count)) |end| return end;
        }
        if (min_count == 0) {
            return copyModeRegexMatchFrom(pattern, rest_index, text, text_index);
        }
        return null;
    }

    if (text_index >= text.len or !copyModeRegexCharMatches(atom, text[text_index])) return null;
    return copyModeRegexMatchFrom(pattern, rest_index, text, text_index + 1);
}

fn copyModeRegexFind(pattern: []const u8, text: []const u8, start: usize) ?struct { start: usize, end: usize } {
    if (pattern.len == 0 or start > text.len) return null;
    if (pattern[0] == '^') {
        if (start != 0) return null;
        const end = copyModeRegexMatchFrom(pattern, 1, text, 0) orelse return null;
        return .{ .start = 0, .end = end };
    }

    var index = start;
    while (index <= text.len) : (index += 1) {
        const end = copyModeRegexMatchFrom(pattern, 0, text, index) orelse continue;
        return .{ .start = index, .end = end };
    }
    return null;
}

pub fn deinitCopyModeState(self: *App) void {
    for (self.copy_mode_history.items) |line| {
        if (line.text.len > 0) self.allocator.free(line.text);
        for (line.cells) |cell| {
            if (cell.text.len > 0) self.allocator.free(cell.text);
        }
        if (line.cells.len > 0) self.allocator.free(line.cells);
        if (line.col_offsets.len > 0) self.allocator.free(line.col_offsets);
    }
    self.copy_mode_history.deinit(self.allocator);
    self.copy_mode_matches.deinit(self.allocator);
    if (self.copy_mode_query.len > 0) {
        self.allocator.free(self.copy_mode_query);
        self.copy_mode_query = &.{};
    }
    self.copy_mode_pane = null;
    self.copy_mode_anchor = null;
    self.copy_mode_match_index = null;
    self.copy_mode_active = false;
    self.copy_mode_needs_refresh = false;
}

pub fn pruneCopyModeIfInvalid(self: *App) void {
    const pane = self.copy_mode_pane orelse return;
    if (self.hasPane(pane) and self.isPaneVisible(pane)) return;
    exitCopyMode(self);
}

pub fn handlePromptJump(self: *App, direction: PromptJumpDir) void {
    const pane = self.activePane() orelse return;
    const runtime = if (self.ghostty) |*rt| rt else return;
    const scrollbar = scroll.refreshPaneScrollbar(self, runtime, pane);
    const total: usize = @intCast(scrollbar.total);
    if (total == 0) return;
    const visible = @max(@as(usize, 1), @as(usize, pane.rows));
    const current_top: usize = @intCast(scroll.scrollbarTopRow(scrollbar));
    const start_row = switch (direction) {
        .next => current_top +| visible,
        .prev => current_top -| 1,
    };
    const target_row = findPromptJumpTarget(.{ .live = .{ .runtime = runtime, .terminal = pane.terminal } }, direction, start_row, total) orelse return;
    scroll.scrollPaneViewportToRow(self, pane, target_row);
}

fn isPromptRow(runtime: *ghostty.Runtime, terminal: ?*anyopaque, row: u64) bool {
    var ref: ghostty.GridRef = undefined;
    const point = ghostty.Point{
        .tag = .screen,
        .value = .{ .coordinate = .{ .x = 0, .y = @intCast(row) } },
    };
    if (runtime.terminal_grid_ref(terminal, point, &ref) != ghostty.success) return false;
    const g_row = runtime.gridRefRow(&ref) orelse return false;
    return runtime.rowSemanticPrompt(g_row) == .prompt;
}

fn alignedTopRowForTarget(current_top: usize, visible_rows: usize, target_row: usize) usize {
    if (target_row < current_top) return target_row;
    if (target_row >= current_top + visible_rows) return target_row - (visible_rows - 1);
    return current_top;
}

fn promptRowAt(source: PromptJumpSource, row: usize) bool {
    return switch (source) {
        .live => |live| isPromptRow(live.runtime, live.terminal, row),
        .copy_mode => |history| row < history.len and history[row].is_prompt,
    };
}

fn findPromptJumpTarget(source: PromptJumpSource, direction: PromptJumpDir, start_row: usize, total_rows: usize) ?usize {
    if (total_rows == 0) return null;
    switch (direction) {
        .next => {
            var row = start_row;
            while (row < total_rows) : (row += 1) {
                if (promptRowAt(source, row)) return row;
            }
        },
        .prev => {
            var row = @min(start_row, total_rows - 1);
            while (true) {
                if (promptRowAt(source, row)) return row;
                if (row == 0) break;
                row -= 1;
            }
        },
    }
    return null;
}

fn captureCopyModeGridRefText(allocator: std.mem.Allocator, runtime: *GhosttyRuntime, ref: *const ghostty.GridRef, raw_cell: u64) ![]u8 {
    var cps: [16]u32 = [_]u32{0} ** 16;
    const grapheme_len = @min(runtime.gridRefGraphemesInto(ref, cps[0..]) orelse 0, cps.len);
    var buf: [32]u8 = undefined;
    var len: usize = 0;

    if (grapheme_len == 0) {
        if (!runtime.cellHasText(raw_cell)) {
            buf[0] = ' ';
            return try allocator.dupe(u8, buf[0..1]);
        }
        const cp = runtime.cellCodepoint(raw_cell);
        if (text_helpers.encodeCodepointInto(cp, &buf[0..4].*)) |encoded_len| {
            return try allocator.dupe(u8, buf[0..encoded_len]);
        }
        buf[0] = ' ';
        return try allocator.dupe(u8, buf[0..1]);
    }

    var idx: usize = 0;
    while (idx < grapheme_len and cps[idx] != 0) : (idx += 1) {
        var utf8_buf: [4]u8 = undefined;
        const encoded_len = text_helpers.encodeCodepointInto(cps[idx], &utf8_buf) orelse continue;
        if (len + encoded_len > buf.len) break;
        fastmem.copy(u8, buf[len .. len + encoded_len], utf8_buf[0..encoded_len]);
        len += encoded_len;
    }
    if (len == 0) {
        buf[0] = ' ';
        len = 1;
    }
    return try allocator.dupe(u8, buf[0..len]);
}

fn colorFromGridRefCell(runtime: *GhosttyRuntime, ref: *const ghostty.GridRef, raw_cell: u64, foreground: bool) ?ghostty.ColorRgb {
    const tag = runtime.cellContentTag(raw_cell);
    if (!foreground and tag != .bg_color_palette and tag != .bg_color_rgb) return null;

    var style: ghostty.Style = undefined;
    if (runtime.gridRefStyleInto(ref, &style)) {
        if (foreground and style.fg_color.tag == .rgb) return style.fg_color.value.rgb;
        if (!foreground and style.bg_color.tag == .rgb) return style.bg_color.value.rgb;
    }

    if (foreground) return null;
    return switch (runtime.cellContentTag(raw_cell)) {
        .bg_color_rgb => blk: {
            var rgb: ghostty.ColorRgb = undefined;
            if (runtime.cell_get(raw_cell, @intFromEnum(ghostty.CellDataV.color_rgb), &rgb) == ghostty.success) break :blk rgb;
            break :blk null;
        },
        else => null,
    };
}

test "copy mode viewport row mapping handles unclamped and clamped scroll positions" {
    try std.testing.expectEqual(@as(?usize, 0), copyModeRowIndexInViewport(0, 0, 10));
    try std.testing.expectEqual(@as(?usize, 5), copyModeRowIndexInViewport(5, 0, 10));
    try std.testing.expectEqual(@as(?usize, 3), copyModeRowIndexInViewport(8, 5, 10));
    try std.testing.expectEqual(@as(?usize, 9), copyModeRowIndexInViewport(14, 5, 10));
    try std.testing.expectEqual(@as(?usize, null), copyModeRowIndexInViewport(15, 5, 10));
    try std.testing.expectEqual(@as(?usize, null), copyModeRowIndexInViewport(4, 5, 10));
}

test "copy mode regex finder supports simple regexp operators" {
    const exact = copyModeRegexFind("foo", "xxfooyy", 0).?;
    try std.testing.expectEqual(@as(usize, 2), exact.start);
    try std.testing.expectEqual(@as(usize, 5), exact.end);

    const wildcard = copyModeRegexFind("f.o", "xxfoo", 0).?;
    try std.testing.expectEqual(@as(usize, 2), wildcard.start);
    try std.testing.expectEqual(@as(usize, 5), wildcard.end);

    const digits = copyModeRegexFind("\\d+", "abc123def", 0).?;
    try std.testing.expectEqual(@as(usize, 3), digits.start);
    try std.testing.expectEqual(@as(usize, 6), digits.end);

    const optional = copyModeRegexFind("colou?r", "color colour", 0).?;
    try std.testing.expectEqual(@as(usize, 0), optional.start);
    try std.testing.expectEqual(@as(usize, 5), optional.end);

    const anchored_start = copyModeRegexFind("^foo", "foobar", 0).?;
    try std.testing.expectEqual(@as(usize, 0), anchored_start.start);
    try std.testing.expectEqual(@as(usize, 3), anchored_start.end);

    const anchored_end = copyModeRegexFind("foo$", "barfoo", 0).?;
    try std.testing.expectEqual(@as(usize, 3), anchored_end.start);
    try std.testing.expectEqual(@as(usize, 6), anchored_end.end);

    const anchored_both = copyModeRegexFind("^foo$", "foo", 0).?;
    try std.testing.expectEqual(@as(usize, 0), anchored_both.start);
    try std.testing.expectEqual(@as(usize, 3), anchored_both.end);

    try std.testing.expectEqual(@as(?struct { start: usize, end: usize }, null), copyModeRegexFind("^foo", "xxfoo", 0));
    try std.testing.expectEqual(@as(?struct { start: usize, end: usize }, null), copyModeRegexFind("foo$", "foobar", 0));
}