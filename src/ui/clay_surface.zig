//! Active surface adapter. Parsed native trees are retained until Lua snapshot revision changes.
const std = @import("std");
const c = @import("clay_c");
const lua = @import("../lua_bridge.zig");

/// Snapshot node fields. Lua omits defaults, so absent keys keep their zero value
/// except `alpha` (255) and `scrollbar_thumb_size` (1).
const Field = enum {
    id,
    text,
    label,
    reveal,
    scrollbar_id,
    scrollbar_thumb_ratio,
    scrollbar_thumb_size,
    scrollbar_track_color,
    scrollbar_thumb_color,
    kind,
    children,
    width,
    height,
    gap,
    radius,
    border_size,
    value,
    fg,
    bg,
    alpha,
    border,
    hover_bg,
    bold,
    scroll,
    scroll_x,
    reveal_start,
    list_item,
    measure,
    full_bleed_x,
    align_y,
    wrap,
    clickable,
    padding,
};
const fields = std.StaticStringMap(Field).initComptime(blk: {
    const values = std.enums.values(Field);
    var entries: [values.len]struct { []const u8, Field } = undefined;
    for (values, 0..) |value, i| entries[i] = .{ @tagName(value), value };
    break :blk entries;
});

pub const Surface = struct {
    context: ?*c.HollowClay = null,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    nodes: [c.HOLLOW_CLAY_MAX_NODES]c.HollowClayNode = undefined,
    len: usize = 0,
    active: bool = false,
    mouse_x: f32 = -1,
    mouse_y: f32 = -1,
    scroll_y: f32 = 0,
    pressed_id: [128]u8 = undefined,
    pressed_len: usize = 0,
    click_id: [128]u8 = undefined,
    click_len: usize = 0,
    close: bool = false,
    revision: f64 = -1,
    surface_id: f64 = -1,
    error_logged_revision: f64 = -1,
    owner_index: usize = 0,
    runtime_generation: u64 = 0,
    frame: c.HollowClayFrame = std.mem.zeroes(c.HollowClayFrame),

    pub fn deinit(self: *Surface) void {
        c.hollow_clay_destroy(self.context);
        self.context = null;
        self.arena.deinit();
    }

    fn string(self: *Surface, api: lua.Api, state: *lua.State, index: c_int) !c.Clay_String {
        var len: usize = 0;
        const ptr = api.to_lstring(state, index, &len) orelse return std.mem.zeroes(c.Clay_String);
        const owned = try self.arena.allocator().dupe(u8, ptr[0..len]);
        return .{ .chars = owned.ptr, .length = @intCast(len), .isStaticallyAllocated = false };
    }

    fn numberAt(api: lua.Api, state: *lua.State, index: c_int) f32 {
        const n = api.to_number(state, index);
        return @floatCast(std.math.clamp(if (std.math.isFinite(n)) n else 0, -65535, 65535));
    }

    fn number(api: lua.Api, state: *lua.State, table: c_int, key: [:0]const u8) f32 {
        return @floatCast(std.math.clamp(counter(api, state, table, key), -65535, 65535));
    }

    fn counter(api: lua.Api, state: *lua.State, table: c_int, key: [:0]const u8) f64 {
        api.get_field(state, table, key);
        defer lua.pop(api, state, 1);
        const n = api.to_number(state, -1);
        return if (std.math.isFinite(n)) n else 0;
    }

    fn boolean(api: lua.Api, state: *lua.State, table: c_int, key: [:0]const u8) bool {
        api.get_field(state, table, key);
        defer lua.pop(api, state, 1);
        return api.to_boolean(state, -1) != 0;
    }

    fn colorAt(api: lua.Api, state: *lua.State, index: c_int) c.Clay_Color {
        var len: usize = 0;
        const ptr = api.to_lstring(state, index, &len) orelse return std.mem.zeroes(c.Clay_Color);
        if (len != 7 or ptr[0] != '#') return std.mem.zeroes(c.Clay_Color);
        const rgb = std.fmt.parseInt(u32, ptr[1..len], 16) catch return std.mem.zeroes(c.Clay_Color);
        return .{ .r = @floatFromInt((rgb >> 16) & 255), .g = @floatFromInt((rgb >> 8) & 255), .b = @floatFromInt(rgb & 255), .a = 255 };
    }

    fn call(api: lua.Api, state: *lua.State, field: [:0]const u8, id: ?[]const u8) void {
        const top = api.get_top(state);
        defer api.set_top(state, top);
        api.get_field(state, -1, field);
        if (api.value_type(state, -1) != @backingInt(lua.LuaType.function)) return;
        if (id) |value| api.push_lstring(state, value.ptr, value.len);
        if (api.pcall(state, if (id != null) 1 else 0, 0, 0) != 0) {
            var len: usize = 0;
            if (api.to_lstring(state, -1, &len)) |ptr| std.log.err("Clay surface callback: {s}", .{ptr[0..len]});
        }
    }

    /// Parses one sparse snapshot node table at absolute index `idx`, visiting only present keys.
    fn parseNode(self: *Surface, api: lua.Api, state: *lua.State, idx: c_int) !c.HollowClayNode {
        var node = std.mem.zeroes(c.HollowClayNode);
        node.scrollbar_thumb_size = 1;
        var alpha: f32 = 255;
        api.push_nil(state);
        while (api.next(state, idx) != 0) {
            defer lua.pop(api, state, 1);
            // Never coerce non-string keys: lua_tolstring would break lua_next.
            if (api.value_type(state, -2) != @backingInt(lua.LuaType.string)) continue;
            var key_len: usize = 0;
            const key_ptr = api.to_lstring(state, -2, &key_len) orelse continue;
            const field = fields.get(key_ptr[0..key_len]) orelse continue;
            switch (field) {
                .id => node.id = try self.string(api, state, -1),
                .text => node.text = try self.string(api, state, -1),
                .label => node.label = try self.string(api, state, -1),
                .reveal => node.reveal = try self.string(api, state, -1),
                .scrollbar_id => node.scrollbar_id = try self.string(api, state, -1),
                .scrollbar_thumb_ratio => node.scrollbar_thumb_ratio = std.math.clamp(numberAt(api, state, -1), 0, 1),
                .scrollbar_thumb_size => node.scrollbar_thumb_size = std.math.clamp(numberAt(api, state, -1), 0, 1),
                .scrollbar_track_color => node.scrollbar_track_color = colorAt(api, state, -1),
                .scrollbar_thumb_color => node.scrollbar_thumb_color = colorAt(api, state, -1),
                .kind => node.kind = @intFromFloat(numberAt(api, state, -1)),
                .children => node.children = @intFromFloat(@max(0, numberAt(api, state, -1))),
                .width => node.width = numberAt(api, state, -1),
                .height => node.height = numberAt(api, state, -1),
                .gap => node.gap = @intFromFloat(@max(0, numberAt(api, state, -1))),
                .radius => node.radius = @max(0, numberAt(api, state, -1)),
                .border_size => node.border_size = @intFromFloat(@max(0, numberAt(api, state, -1))),
                .value => node.value = std.math.clamp(numberAt(api, state, -1), 0, 1),
                .fg => node.fg = colorAt(api, state, -1),
                .bg => node.bg = colorAt(api, state, -1),
                .alpha => alpha = std.math.clamp(numberAt(api, state, -1), 0, 255),
                .border => node.border = colorAt(api, state, -1),
                .hover_bg => node.hover_bg = colorAt(api, state, -1),
                .bold => node.bold = api.to_boolean(state, -1) != 0,
                .scroll => node.scroll = api.to_boolean(state, -1) != 0,
                .scroll_x => node.scroll_x = api.to_boolean(state, -1) != 0,
                .reveal_start => node.reveal_start = api.to_boolean(state, -1) != 0,
                .list_item => node.list_item = api.to_boolean(state, -1) != 0,
                .measure => node.measure = api.to_boolean(state, -1) != 0,
                .full_bleed_x => node.full_bleed_x = api.to_boolean(state, -1) != 0,
                .clickable => node.clickable = api.to_boolean(state, -1) != 0,
                .align_y => node.align_y = @intFromFloat(std.math.clamp(numberAt(api, state, -1), 0, 2)),
                .wrap => node.wrap = @intFromFloat(std.math.clamp(numberAt(api, state, -1), 0, 2)),
                .padding => if (api.value_type(state, -1) == @backingInt(lua.LuaType.table)) {
                    const padding = lua.absoluteIndex(api, state, -1);
                    inline for (.{ "top", "right", "bottom", "left" }) |side| {
                        @field(node.padding, side) = @intFromFloat(@max(0, number(api, state, padding, side)));
                    }
                },
            }
        }
        if (node.bg.a > 0) node.bg.a = alpha;
        return node;
    }

    /// Must run before atlas upload / swapchain rendering. Own all Lua strings until next prepare.
    pub fn prepare(self: *Surface, runtime: *lua.Runtime, renderer: anytype, width: f32, height: f32) void {
        if (self.runtime_generation != runtime.generation) {
            self.deinit();
            self.* = .{ .runtime_generation = runtime.generation };
        }
        const api = runtime.context.api;
        const state = runtime.state;
        const top = api.get_top(state);
        defer api.set_top(state, top);
        api.get_field(state, -10002, "hollow");
        api.get_field(state, -1, "ui");
        const ui_idx = lua.absoluteIndex(api, state, -1);
        if (self.close) {
            self.close = false;
            self.click_len = 0;
            call(api, state, "_layout_hide", null);
        } else if (self.click_len > 0) {
            const len = self.click_len;
            self.click_len = 0;
            call(api, state, "_layout_click", self.click_id[0..len]);
        }
        api.get_field(state, ui_idx, "_layout_prepare");
        api.push_number(state, width);
        api.push_number(state, height);
        api.push_number(state, renderer.cell_w);
        api.push_number(state, renderer.cell_h);
        if (api.pcall(state, 4, 0, 0) != 0) {
            self.active = false;
            var error_len: usize = 0;
            if (api.to_lstring(state, -1, &error_len)) |ptr| std.log.err("Clay snapshot: {s}", .{ptr[0..error_len]});
            return;
        }
        self.owner_index = @intFromFloat(@max(0, number(api, state, ui_idx, "_layout_owner")));
        const revision = counter(api, state, ui_idx, "_layout_revision");
        const surface_id = counter(api, state, ui_idx, "_layout_surface_id");
        self.frame = std.mem.zeroes(c.HollowClayFrame);
        api.get_field(state, ui_idx, "_layout_frame");
        if (api.value_type(state, -1) == @backingInt(lua.LuaType.table)) {
            const frame_idx = lua.absoluteIndex(api, state, -1);
            self.frame.enabled = true;
            self.frame.width = @max(0, number(api, state, frame_idx, "width")) * renderer.cell_w;
            self.frame.height = @max(0, number(api, state, frame_idx, "height")) * renderer.cell_h;
            self.frame.align_x = @intFromFloat(number(api, state, frame_idx, "align_x"));
            self.frame.align_y = @intFromFloat(number(api, state, frame_idx, "align_y"));
            self.frame.margin = .{ .left = @intFromFloat(renderer.cell_w), .right = @intFromFloat(renderer.cell_w), .top = @intFromFloat(renderer.cell_h), .bottom = @intFromFloat(renderer.cell_h) };
            api.get_field(state, frame_idx, "margin");
            if (api.value_type(state, -1) == @backingInt(lua.LuaType.table)) {
                const margin_idx = lua.absoluteIndex(api, state, -1);
                inline for (.{ "top", "right", "bottom", "left" }) |side| {
                    @field(self.frame.margin, side) +|= @intFromFloat(@max(0, number(api, state, margin_idx, side)));
                }
            }
            lua.pop(api, state, 1);
        }
        lua.pop(api, state, 1);
        api.get_field(state, -1, "_layout_tree");
        self.active = false;
        if (api.value_type(state, -1) != @backingInt(lua.LuaType.table)) {
            self.pressed_len = 0;
            self.scroll_y = 0;
            return;
        }
        if (revision == self.revision and surface_id == self.surface_id and self.context != null) {
            self.active = self.len > 0;
            self.preRasterize(renderer);
            return;
        }
        // One Clay context serves every surface. IDs are namespaced per surface,
        // so retired scroll state is pruned by Clay instead of reallocating the arena.
        if (surface_id != self.surface_id) self.pressed_len = 0;
        self.len = 0;
        _ = self.arena.reset(.retain_capacity);
        const tree = lua.absoluteIndex(api, state, -1);
        while (self.len < self.nodes.len) {
            api.rawgeti(state, tree, @intCast(self.len + 1));
            if (api.value_type(state, -1) != @backingInt(lua.LuaType.table)) break;
            const idx = lua.absoluteIndex(api, state, -1);
            self.nodes[self.len] = self.parseNode(api, state, idx) catch return;
            lua.pop(api, state, 1);
            self.len += 1;
        }
        if (self.context == null) self.context = c.hollow_clay_create();
        self.active = self.context != null and self.len > 0;
        self.revision = revision;
        self.surface_id = surface_id;
        self.preRasterize(renderer);
    }

    fn preRasterize(self: *Surface, renderer: anytype) void {
        for (self.nodes[0..self.len]) |node| {
            if (node.text.length > 0) renderer.preRasterizeLabelFace(node.text.chars[0..@intCast(node.text.length)], if (node.bold) 1 else 0);
        }
    }

    pub fn layout(self: *Surface, width: f32, height: f32, cell_w: f32, cell_h: f32, dt: f32) c.Clay_RenderCommandArray {
        c.hollow_clay_frame(self.context, self.frame);
        // Clay scales wheel deltas by 10 px; one notch scrolls one cell row.
        const scroll = self.scroll_y * cell_h / 10;
        const commands = c.hollow_clay_layout(self.context, &self.nodes, @intCast(self.len), width, height, cell_w, cell_h, self.mouse_x, self.mouse_y, scroll, dt);
        self.scroll_y = 0;
        if (c.hollow_clay_failed(self.context)) {
            if (self.error_logged_revision != self.revision) {
                self.error_logged_revision = self.revision;
                const message = c.hollow_clay_error(self.context);
                const text = if (message.length > 0) message.chars[0..@intCast(message.length)] else "exceeded limits or received invalid layout";
                std.log.err("Clay surface {d} revision {d}: {s}", .{ self.surface_id, self.revision, text });
            }
            return std.mem.zeroes(c.Clay_RenderCommandArray);
        }
        return commands;
    }

    pub fn pointerButton(self: *Surface, down: bool, x: f32, y: f32) void {
        const index = c.hollow_clay_hit(self.context, &self.nodes, @intCast(self.len), x, y);
        const hit: ?usize = if (index >= 0) @intCast(index) else null;
        const id: []const u8 = if (hit) |i| self.nodes[i].id.chars[0..@intCast(self.nodes[i].id.length)] else "";
        if (down) {
            self.pressed_len = @min(id.len, self.pressed_id.len);
            @memcpy(self.pressed_id[0..self.pressed_len], id[0..self.pressed_len]);
        } else {
            defer self.pressed_len = 0;
            if (id.len == 0 or id.len > self.click_id.len or !std.mem.eql(u8, id, self.pressed_id[0..self.pressed_len])) return;
            self.click_len = id.len;
            @memcpy(self.click_id[0..self.click_len], id);
        }
    }
};
