const std = @import("std");
const ghostty = @import("../term/ghostty.zig");
const GhosttyRuntime = ghostty.Runtime;
const selection_mod = @import("selection.zig");
const PaneBounds = @import("../mux.zig").PaneBounds;
const LayoutLeaf = @import("../mux.zig").LayoutLeaf;
const MAX_LAYOUT_LEAVES = @import("../mux.zig").MAX_LAYOUT_LEAVES;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Pane = @import("../pane.zig").Pane;

pub const ScrollbarMetrics = struct {
    pane: *Pane,
    outer_bounds: PaneBounds,
    track_x: f32,
    track_y: f32,
    track_w: f32,
    track_h: f32,
    thumb_y: f32,
    thumb_h: f32,
    total: u64,
    offset: u64,
    len: u64,
};

pub fn scrollbarVisible(self: *const App, scrollbar: ghostty.TerminalScrollbar) bool {
    return self.config.scrollbar.enabled and scrollbar.len > 0 and scrollbar.total > scrollbar.len;
}

pub fn paneScrollbarGutter(self: *const App, pane: *const Pane) u32 {
    return if (scrollbarVisible(self, pane.scrollbar())) self.config.scrollbar.gutterWidth() else 0;
}

pub fn scrollbarMaxTopRow(scrollbar: ghostty.TerminalScrollbar) u64 {
    return if (scrollbar.total > scrollbar.len) scrollbar.total - scrollbar.len else 0;
}

pub fn scrollbarTopRow(scrollbar: ghostty.TerminalScrollbar) u64 {
    return @min(scrollbar.offset, scrollbarMaxTopRow(scrollbar));
}

pub fn pageScrollRows(pane: *const Pane) isize {
    return @max(@as(isize, 1), @as(isize, @intCast(@max(@as(u16, 1), pane.rows))) - 1);
}

pub fn refreshPaneScrollbar(self: *App, runtime: *GhosttyRuntime, pane: *Pane) ghostty.TerminalScrollbar {
    const was_visible = scrollbarVisible(self, pane.scrollbar());
    if (runtime.terminalScrollbar(pane.terminal)) |scrollbar| {
        pane.scrollbar_total = scrollbar.total;
        pane.scrollbar_offset = scrollbar.offset;
        pane.scrollbar_len = scrollbar.len;
        if (was_visible != scrollbarVisible(self, scrollbar)) self.requestLayoutResize(false);
        return scrollbar;
    }
    pane.scrollbar_total = @max(@as(u64, 1), @as(u64, pane.rows));
    pane.scrollbar_offset = 0;
    pane.scrollbar_len = @max(@as(u64, 1), pane.rows);
    const fallback = pane.scrollbar();
    if (was_visible != scrollbarVisible(self, fallback)) self.requestLayoutResize(false);
    return fallback;
}

pub fn scrollPaneViewport(self: *App, pane: *Pane, delta: isize) void {
    if (delta == 0) return;
    const runtime = if (self.ghostty) |*rt| rt else return;
    runtime.terminalScroll(pane.terminal, delta);
    pane.render_dirty = .full;
    pane.last_render_state_update_ns = 0;
    pane.pty_received_data = true;
    self.scroll_accum = 0;
    _ = refreshPaneScrollbar(self, runtime, pane);
    selection_mod.syncDraggedSelectionToPointer(self, pane);
}

fn forceScrollPaneViewportToRow(self: *App, pane: *Pane, top_row: u64) void {
    const runtime = if (self.ghostty) |*rt| rt else return;
    const scrollbar = refreshPaneScrollbar(self, runtime, pane);
    const max_top = scrollbarMaxTopRow(scrollbar);
    const clamped_target = @min(top_row, max_top);

    if (clamped_target == 0) {
        runtime.terminalScrollTop(pane.terminal);
    } else if (clamped_target == max_top) {
        runtime.terminalScrollBottom(pane.terminal);
    } else {
        runtime.terminalScrollTop(pane.terminal);
        const delta_i64: i64 = @intCast(clamped_target);
        const delta: isize = std.math.cast(isize, delta_i64) orelse std.math.maxInt(isize);
        runtime.terminalScroll(pane.terminal, delta);
    }

    pane.render_dirty = .full;
    pane.render_state_fresh = false;
    pane.last_render_state_update_ns = 0;
    pane.pty_received_data = true;
    self.scroll_accum = 0;
    _ = refreshPaneScrollbar(self, runtime, pane);
}

fn restorePaneViewportFromBottom(self: *App, pane: *Pane, top_row: usize) void {
    const runtime = if (self.ghostty) |*rt| rt else return;
    const scrollbar = refreshPaneScrollbar(self, runtime, pane);
    const max_top: usize = @intCast(scrollbarMaxTopRow(scrollbar));
    const clamped_target = @min(top_row, max_top);

    runtime.terminalScrollBottom(pane.terminal);
    if (clamped_target < max_top) {
        const delta_i64: i64 = -@as(i64, @intCast(max_top - clamped_target));
        const delta: isize = std.math.cast(isize, delta_i64) orelse std.math.minInt(isize);
        runtime.terminalScroll(pane.terminal, delta);
    }

    pane.render_dirty = .full;
    pane.render_state_fresh = false;
    pane.last_render_state_update_ns = 0;
    pane.pty_received_data = true;
    self.scroll_accum = 0;
    _ = refreshPaneScrollbar(self, runtime, pane);
}

pub fn scrollPaneViewportToRow(self: *App, pane: *Pane, top_row: u64) void {
    const runtime = if (self.ghostty) |*rt| rt else return;
    const scrollbar = refreshPaneScrollbar(self, runtime, pane);
    const max_top = scrollbarMaxTopRow(scrollbar);
    const clamped_target = @min(top_row, max_top);
    const current_top = scrollbarTopRow(scrollbar);
    if (clamped_target == current_top) return;

    if (clamped_target == 0) {
        runtime.terminalScrollTop(pane.terminal);
        pane.render_dirty = .full;
        pane.last_render_state_update_ns = 0;
        pane.pty_received_data = true;
        self.scroll_accum = 0;
        _ = refreshPaneScrollbar(self, runtime, pane);
        return;
    }

    if (clamped_target == max_top) {
        runtime.terminalScrollBottom(pane.terminal);
        pane.render_dirty = .full;
        pane.last_render_state_update_ns = 0;
        pane.pty_received_data = true;
        self.scroll_accum = 0;
        _ = refreshPaneScrollbar(self, runtime, pane);
        return;
    }

    const target_i64: i64 = @intCast(clamped_target);
    const current_i64: i64 = @intCast(current_top);
    const delta_i64 = target_i64 - current_i64;
    const delta: isize = std.math.cast(isize, delta_i64) orelse if (delta_i64 < 0)
        std.math.minInt(isize)
    else
        std.math.maxInt(isize);
    scrollPaneViewport(self, pane, delta);
}

pub fn paneScrollbarMetrics(self: *App, pane: *Pane, outer_bounds: PaneBounds) ?ScrollbarMetrics {
    if (!self.config.scrollbar.enabled) return null;
    const gutter = paneScrollbarGutter(self, pane);
    if (gutter == 0 or outer_bounds.width <= gutter) return null;

    const scrollbar = pane.scrollbar();
    if (scrollbar.len == 0 or scrollbar.total <= scrollbar.len) return null;
    const track_len = scrollbar.len;
    const total = scrollbar.total;

    const margin_f: f32 = @floatFromInt(self.config.scrollbar.margin);
    const width_f: f32 = @floatFromInt(@max(@as(u32, 1), self.config.scrollbar.width));
    const gutter_f: f32 = @floatFromInt(gutter);
    const track_x = @as(f32, @floatFromInt(outer_bounds.x)) + @as(f32, @floatFromInt(outer_bounds.width)) - gutter_f + margin_f;
    const track_y = @as(f32, @floatFromInt(outer_bounds.y)) + margin_f;
    const track_h = @max(@as(f32, 1.0), @as(f32, @floatFromInt(outer_bounds.height)) - margin_f * 2.0);
    const min_thumb_h: f32 = @floatFromInt(@max(@as(u32, 1), self.config.scrollbar.min_thumb_size));
    const visible_ratio = @as(f32, @floatFromInt(track_len)) / @as(f32, @floatFromInt(total));
    const thumb_h = @min(track_h, @max(min_thumb_h, track_h * visible_ratio));
    const max_top = if (total > track_len) total - track_len else 0;
    const travel = @max(@as(f32, 0.0), track_h - thumb_h);
    const ui_offset = scrollbarTopRow(scrollbar);
    const thumb_y = track_y + if (max_top == 0)
        0.0
    else
        travel * (@as(f32, @floatFromInt(ui_offset)) / @as(f32, @floatFromInt(max_top)));

    return .{
        .pane = pane,
        .outer_bounds = outer_bounds,
        .track_x = track_x,
        .track_y = track_y,
        .track_w = width_f,
        .track_h = track_h,
        .thumb_y = thumb_y,
        .thumb_h = thumb_h,
        .total = total,
        .offset = ui_offset,
        .len = track_len,
    };
}

pub fn scrollbarMetricsForPane(self: *App, pane: *Pane) ?ScrollbarMetrics {
    var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
    const leaves = self.computeActiveLayout(&layout_buf);
    for (leaves) |leaf| {
        if (leaf.pane == pane) return paneScrollbarMetrics(self, pane, leaf.bounds);
    }

    if (self.activePane() == pane) {
        const tbh = self.tabBarHeight();
        const bbh = self.bottomBarHeight();
        const pane_h = if (self.config.window_height > tbh + bbh) self.config.window_height - tbh - bbh else 1;
        return paneScrollbarMetrics(self, pane, .{
            .x = 0,
            .y = tbh,
            .width = self.config.window_width,
            .height = pane_h,
        });
    }

    return null;
}
