//! Clay inspector over Hollow's own window geometry. Bars, sidebar, the active
//! tab's split tree and floating panes are mirrored into a dedicated Clay
//! context each frame; they are never painted, only the inspector is.
const std = @import("std");
const c = @import("clay_c");
const App = @import("../app.zig").App;
const mux = @import("../mux.zig");
const Pane = @import("../pane.zig").Pane;
const lua = @import("../lua_bridge.zig");
const input = @import("clay_inspector_input.zig");

const max_bar_items = 64;
const max_rects = 2 * mux.MAX_LAYOUT_LEAVES + 2 * (max_bar_items + 1) + 16;
const text_capacity = 16 * 1024;

/// Printable ASCII; pre-rasterized while the inspector is open because its
/// labels are generated during the swapchain pass.
pub const inspector_glyphs = blk: {
    var glyphs: [95]u8 = undefined;
    for (&glyphs, 0..) |*glyph, i| glyph.* = @intCast(' ' + i);
    break :blk glyphs;
};

pub const Rgb = struct { r: u8, g: u8, b: u8 };

/// Paint as resolved by the renderer, shown in the inspector's element info.
pub const Style = struct {
    bg: ?Rgb = null,
    fg: ?Rgb = null,
    border: ?Rgb = null,
    /// Alpha the border is drawn with.
    border_alpha: u8 = 255,
    radius: f32 = 0,
    bold: bool = false,
    /// top, right, bottom, left
    padding: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const Box = struct { x: f32 = 0, y: f32 = 0, width: f32 = 0, height: f32 = 0 };

/// Bar geometry recorded by the bar renderer while the inspector is open.
/// Item boxes are margin boxes spanning the bar content height; `bg` is the
/// painted box inside them.
pub const BarRecord = struct {
    pub const Kind = enum { segment, tab };
    pub const Item = struct {
        kind: Kind,
        x: f32,
        width: f32,
        bg: Box,
        style: Style,
        index: u32,
        active: bool = false,
        text: []const u8,
    };

    recorded: bool = false,
    frame: Box = .{},
    frame_style: Style = .{},
    content_y: f32 = 0,
    content_h: f32 = 0,
    len: usize = 0,
    items: [max_bar_items]Item = undefined,
    text: [4096]u8 = undefined,
    text_len: usize = 0,

    pub fn begin(self: *BarRecord, frame: Box, frame_style: Style, content_y: f32, content_h: f32) void {
        self.* = .{ .recorded = true, .frame = frame, .frame_style = frame_style, .content_y = content_y, .content_h = content_h };
    }

    pub fn add(self: *BarRecord, kind: Kind, index: usize, x: f32, width: f32, bg: Box, style: Style, active: bool, text: []const u8) void {
        if (self.len >= self.items.len or width <= 0) return;
        const n = @min(text.len, 64, self.text.len - self.text_len);
        @memcpy(self.text[self.text_len..][0..n], text[0..n]);
        self.items[self.len] = .{ .kind = kind, .x = x, .width = width, .bg = bg, .style = style, .index = @intCast(index), .active = active, .text = self.text[self.text_len..][0..n] };
        self.text_len += n;
        self.len += 1;
    }
};

fn color(rgb: ?Rgb, alpha: u8) c.Clay_Color {
    const value = rgb orelse return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    return .{ .r = @floatFromInt(value.r), .g = @floatFromInt(value.g), .b = @floatFromInt(value.b), .a = @floatFromInt(alpha) };
}

fn edge(value: f32) u16 {
    return @intFromFloat(std.math.clamp(@round(value), 0, std.math.maxInt(u16)));
}

/// Copies `style` into a mirrored rect.
pub fn applyStyle(rect: *c.HollowClayDebugRect, style: Style) void {
    rect.background = color(style.bg, 255);
    rect.border_color = color(style.border, style.border_alpha);
    rect.border_width = if (style.border != null) 1 else 0;
    rect.corner_radius = style.radius;
    rect.padding = .{ .top = edge(style.padding[0]), .right = edge(style.padding[1]), .bottom = edge(style.padding[2]), .left = edge(style.padding[3]) };
    rect.text_color = color(style.fg, 255);
    rect.font_id = if (style.bold) 1 else 0;
}

fn same(a: ?*Pane, b: *Pane) bool {
    return if (a) |pane| pane == b else false;
}

pub const GridDebug = struct {
    enabled: bool = false,
    /// Set when the inspector's own close button was pressed; Lua clears its flag.
    closed: bool = false,
    context: ?*c.HollowClay = null,
    rects: [max_rects]c.HollowClayDebugRect = undefined,
    len: usize = 0,
    text: [text_capacity]u8 = undefined,
    text_len: usize = 0,
    split_index: u32 = 0,
    mouse_x: f32 = -1,
    mouse_y: f32 = -1,
    button: input.Latch = .{},
    scroll_y: f32 = 0,
    /// Top and bottom bars, filled by the renderer each frame while enabled.
    bars: [2]BarRecord = .{ .{}, .{} },

    pub fn deinit(self: *GridDebug) void {
        c.hollow_clay_destroy(self.context);
        self.context = null;
    }

    pub fn setEnabled(self: *GridDebug, enabled: bool) void {
        if (self.enabled == enabled) return;
        self.enabled = enabled;
        self.button = .{};
        self.scroll_y = 0;
    }

    /// Reads `hollow.ui._layout_debug_grid` and, after the inspector closed
    /// itself, clears that flag. Call with the Lua state locked.
    pub fn sync(self: *GridDebug, runtime: *lua.Runtime) void {
        const api = runtime.context.api;
        const state = runtime.state;
        const top = api.get_top(state);
        defer api.set_top(state, top);
        api.get_field(state, -10002, "hollow");
        if (api.value_type(state, -1) != @backingInt(lua.LuaType.table)) return self.setEnabled(false);
        api.get_field(state, -1, "ui");
        if (api.value_type(state, -1) != @backingInt(lua.LuaType.table)) return self.setEnabled(false);
        const ui_idx = lua.absoluteIndex(api, state, -1);
        if (self.closed) {
            self.closed = false;
            api.push_boolean(state, 0);
            api.set_field(state, ui_idx, "_layout_debug_grid");
        }
        api.get_field(state, ui_idx, "_layout_debug_grid");
        self.setEnabled(api.to_boolean(state, -1) != 0);
    }

    fn string(self: *GridDebug, comptime fmt: []const u8, args: anytype) c.Clay_String {
        const written = std.fmt.bufPrint(self.text[self.text_len..], fmt, args) catch return std.mem.zeroes(c.Clay_String);
        self.text_len += written.len;
        return .{ .chars = written.ptr, .length = @intCast(written.len), .isStaticallyAllocated = false };
    }

    fn label(text: []const u8) c.Clay_String {
        return .{ .chars = text.ptr, .length = @intCast(text.len), .isStaticallyAllocated = true };
    }

    /// Appends a rect under `parent`; null when the bounded buffer is full.
    fn push(self: *GridDebug, parent: ?usize, id: c.Clay_String, index: u32, x: f32, y: f32, width: f32, height: f32) ?usize {
        if (self.len >= self.rects.len) return null;
        if (parent) |p| self.rects[p].children += 1;
        var rect = std.mem.zeroes(c.HollowClayDebugRect);
        rect.id = id;
        rect.index = index;
        rect.x = x;
        rect.y = y;
        rect.width = @max(0, width);
        rect.height = @max(0, height);
        self.rects[self.len] = rect;
        self.len += 1;
        return self.len - 1;
    }

    fn pushBounds(self: *GridDebug, parent: ?usize, id: c.Clay_String, index: u32, bounds: mux.PaneBounds) ?usize {
        return self.push(parent, id, index, @floatFromInt(bounds.x), @floatFromInt(bounds.y), @floatFromInt(bounds.width), @floatFromInt(bounds.height));
    }

    fn pushPane(self: *GridDebug, parent: usize, tab: *mux.Tab, pane: *Pane, bounds: mux.PaneBounds, floating: bool) void {
        const id = self.string("pane:{d}", .{@intFromPtr(pane)});
        const index = self.pushBounds(parent, id, 0, bounds) orelse return;
        self.rects[index].floating = floating;
        const title = pane.title[0..@min(pane.title.len, 48)];
        self.rects[index].detail = self.string("{d}x{d}{s}{s}{s}{s}{s}", .{
            pane.cols,
            pane.rows,
            if (same(tab.active_pane, pane)) " active" else "",
            if (pane.is_floating) " floating" else "",
            if (same(tab.maximized_pane, pane)) " maximized" else "",
            if (title.len > 0) " | " else "",
            title,
        });
    }

    fn pushTree(self: *GridDebug, parent: usize, tab: *mux.Tab, node: *mux.SplitNode, bounds: mux.PaneBounds, cell_w: u32, cell_h: u32) void {
        switch (node.kind) {
            .pane => {
                const pane = node.pane orelse return;
                if (!pane.is_floating) self.pushPane(parent, tab, pane, bounds, false);
            },
            .split => {
                const first = node.first orelse return;
                const second = node.second orelse return;
                const id = label(if (node.direction == .vertical) "split.vertical" else "split.horizontal");
                self.split_index += 1;
                const index = self.pushBounds(parent, id, self.split_index, bounds) orelse return;
                const first_bounds, const second_bounds = mux.splitChildBounds(node, bounds, cell_w, cell_h);
                self.pushTree(index, tab, first, first_bounds, cell_w, cell_h);
                self.pushTree(index, tab, second, second_bounds, cell_w, cell_h);
            },
        }
    }

    /// Mirrors the current window geometry. Call outside the Lua lock: bar
    /// layouts may be refreshed through Lua.
    pub fn collect(self: *GridDebug, app: *App, width: f32, height: f32, cell_w: f32) void {
        self.len = 0;
        self.text_len = 0;
        self.split_index = 0;
        const top_h: f32 = @floatFromInt(app.tabBarHeight());
        const bottom_h: f32 = @floatFromInt(app.bottomBarHeight());
        const root = self.push(null, label("window"), 0, 0, 0, width, height).?;
        if (top_h > 0) if (self.push(root, label("topbar"), 0, 0, 0, width, top_h)) |index| self.pushBar(index, 0, "topbar");
        const body_h = @max(0, height - top_h - bottom_h);
        const body = self.push(root, label("body"), 0, 0, top_h, width, body_h) orelse return;
        const sidebar = app.sidebarLayout();
        const sidebar_w: f32 = if (sidebar) |s| @as(f32, @floatFromInt(s.width_cols)) * cell_w + cell_w else 0;
        const sidebar_right = if (sidebar) |s| s.side == .right else false;
        const reserved = if (sidebar) |s| s.reserve and s.width_cols > 0 else false;
        if (reserved and !sidebar_right) _ = self.push(body, label("sidebar"), 0, 0, top_h, sidebar_w, body_h);
        const bounds = app.activeLayoutBounds();
        if (self.pushBounds(body, label("tab"), 0, bounds)) |tab_index| {
            if (app.mux) |*m| if (m.activeTab()) |tab| {
                const cell_w_px = app.cell_width_px;
                const cell_h_px = app.cell_height_px;
                if (tab.maximized_pane) |pane| {
                    if (tab.maximized_show_background) if (tab.root_split) |node| self.pushTree(tab_index, tab, node, bounds, cell_w_px, cell_h_px);
                    self.pushPane(tab_index, tab, pane, bounds, tab.maximized_show_background);
                } else if (tab.root_split) |node| self.pushTree(tab_index, tab, node, bounds, cell_w_px, cell_h_px);
                for (tab.panes.items) |pane| {
                    if (!pane.is_floating or same(tab.maximized_pane, pane)) continue;
                    self.pushPane(tab_index, tab, pane, mux.floatingPaneBounds(bounds, pane), true);
                }
            };
        }
        if (reserved and sidebar_right) _ = self.push(body, label("sidebar"), 0, width - sidebar_w, top_h, sidebar_w, body_h);
        if (sidebar != null and !reserved and sidebar.?.width_cols > 0) {
            const x = if (sidebar_right) width - sidebar_w else 0;
            if (self.push(body, label("sidebar"), 0, x, top_h, sidebar_w, body_h)) |index| self.rects[index].floating = true;
        }
        if (bottom_h > 0) if (self.push(root, label("bottombar"), 0, 0, height - bottom_h, width, bottom_h)) |index| self.pushBar(index, 1, "bottombar");
        for (&self.bars) |*record| record.recorded = false;
    }

    fn pushBar(self: *GridDebug, parent: usize, which: usize, comptime name: []const u8) void {
        const record = &self.bars[which];
        if (!record.recorded) return;
        const f = record.frame;
        const frame = self.push(parent, label(name ++ ".frame"), 0, f.x, f.y, f.width, f.height) orelse return;
        applyStyle(&self.rects[frame], record.frame_style);
        for (record.items[0..record.len]) |item| {
            const tab = item.kind == .tab;
            const id = label(if (tab) name ++ ".tab" else name ++ ".segment");
            const margin = self.push(frame, id, item.index, item.x, record.content_y, item.width, record.content_h) orelse return;
            const b = item.bg;
            // Left/top margins are inferred from the box offset.
            self.rects[margin].padding.right = edge(item.x + item.width - b.x - b.width);
            self.rects[margin].padding.bottom = edge(record.content_y + record.content_h - b.y - b.height);
            const box = self.push(margin, label(if (tab) name ++ ".tab.box" else name ++ ".segment.box"), item.index, b.x, b.y, b.width, b.height) orelse return;
            applyStyle(&self.rects[box], item.style);
            self.rects[box].detail = if (tab)
                self.string("{s}{s}", .{ if (item.active) "active | " else "", item.text })
            else
                self.string("{s}", .{item.text});
        }
    }

    pub fn layout(self: *GridDebug, width: f32, height: f32, cell_w: f32, cell_h: f32, dt: f32) c.Clay_RenderCommandArray {
        if (self.context == null) self.context = c.hollow_clay_create();
        const context = self.context orelse return std.mem.zeroes(c.Clay_RenderCommandArray);
        // Clay scales wheel deltas by 10 px; one notch scrolls one 30 px inspector row.
        const commands = c.hollow_clay_debug_layout(context, &self.rects, @intCast(self.len), width, height, cell_w, cell_h, self.mouse_x, self.mouse_y, self.button.down, self.scroll_y * 3, dt);
        self.scroll_y = 0;
        self.button.advance();
        if (c.hollow_clay_failed(context)) {
            const message = c.hollow_clay_error(context);
            if (message.length > 0) std.log.err("Clay grid inspector: {s}", .{message.chars[0..@intCast(message.length)]});
            return std.mem.zeroes(c.Clay_RenderCommandArray);
        }
        if (c.hollow_clay_debug_closed(context)) {
            self.closed = true;
            self.setEnabled(false);
        }
        return commands;
    }

    pub const Event = enum { move, down, up, scroll };

    /// Records pointer input; true when the event lands on the inspector panel
    /// and must not reach panes or bars.
    pub fn pointer(self: *GridDebug, kind: Event, x: f32, y: f32, scroll: f32, area: input.Rect) bool {
        if (!self.enabled) return false;
        self.mouse_x = x;
        self.mouse_y = y;
        const over = input.inPanel(area, x, y);
        switch (kind) {
            .move => {},
            .down => if (over) self.button.press(),
            .up => if (self.button.release()) return true,
            .scroll => if (over) {
                self.scroll_y += scroll;
            },
        }
        return over;
    }
};
