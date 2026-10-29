//! Active surface adapter. Parsed native trees are retained until Lua snapshot revision changes.
const std = @import("std");
const c = @import("clay_c");
const lua = @import("../lua_bridge.zig");

pub const Surface = struct {
    context: ?*c.HollowClay = null,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    nodes: [512]c.HollowClayNode = undefined,
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
    owner_index: usize = 0,
    frame: c.HollowClayFrame = std.mem.zeroes(c.HollowClayFrame),

    pub fn deinit(self: *Surface) void {
        c.hollow_clay_destroy(self.context);
        self.context = null;
        self.arena.deinit();
    }

    fn string(self: *Surface, api: lua.Api, state: *lua.State, table: c_int, key: [:0]const u8) !c.Clay_String {
        api.get_field(state, table, key);
        defer lua.pop(api, state, 1);
        var len: usize = 0;
        const ptr = api.to_lstring(state, -1, &len) orelse return std.mem.zeroes(c.Clay_String);
        const owned = try self.arena.allocator().dupe(u8, ptr[0..len]);
        return .{ .chars = owned.ptr, .length = @intCast(len), .isStaticallyAllocated = false };
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

    fn color(api: lua.Api, state: *lua.State, table: c_int, key: [:0]const u8) c.Clay_Color {
        api.get_field(state, table, key);
        defer lua.pop(api, state, 1);
        var len: usize = 0;
        const ptr = api.to_lstring(state, -1, &len) orelse return std.mem.zeroes(c.Clay_Color);
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

    /// Must run before atlas upload / swapchain rendering. Own all Lua strings until next prepare.
    pub fn prepare(self: *Surface, runtime: *lua.Runtime, renderer: anytype, width: f32, height: f32) void {
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
        if (surface_id != self.surface_id) {
            c.hollow_clay_destroy(self.context);
            self.context = null;
            self.pressed_len = 0;
        }
        self.len = 0;
        _ = self.arena.reset(.retain_capacity);
        const tree = lua.absoluteIndex(api, state, -1);
        while (self.len < self.nodes.len) {
            api.rawgeti(state, tree, @intCast(self.len + 1));
            if (api.value_type(state, -1) != @backingInt(lua.LuaType.table)) break;
            const idx = lua.absoluteIndex(api, state, -1);
            var node = std.mem.zeroes(c.HollowClayNode);
            node.id = self.string(api, state, idx, "id") catch return;
            node.text = self.string(api, state, idx, "text") catch return;
            node.label = self.string(api, state, idx, "label") catch return;
            node.kind = @intFromFloat(number(api, state, idx, "kind"));
            node.children = @intFromFloat(@max(0, number(api, state, idx, "children")));
            node.width = number(api, state, idx, "width");
            node.height = number(api, state, idx, "height");
            node.gap = @intFromFloat(@max(0, number(api, state, idx, "gap")));
            node.radius = @max(0, number(api, state, idx, "radius"));
            node.border_size = @intFromFloat(@max(0, number(api, state, idx, "border_size")));
            node.value = std.math.clamp(number(api, state, idx, "value"), 0, 1);
            node.fg = color(api, state, idx, "fg");
            node.bg = color(api, state, idx, "bg");
            if (node.bg.a > 0) node.bg.a = std.math.clamp(number(api, state, idx, "alpha"), 0, 255);
            node.border = color(api, state, idx, "border");
            node.hover_bg = color(api, state, idx, "hover_bg");
            node.bold = boolean(api, state, idx, "bold");
            node.scroll = boolean(api, state, idx, "scroll");
            node.clickable = boolean(api, state, idx, "clickable");
            api.get_field(state, idx, "padding");
            if (api.value_type(state, -1) == @backingInt(lua.LuaType.table)) {
                const padding = lua.absoluteIndex(api, state, -1);
                inline for (.{ "top", "right", "bottom", "left" }) |side| {
                    @field(node.padding, side) = @intFromFloat(@max(0, number(api, state, padding, side)));
                }
            }
            lua.pop(api, state, 2);
            self.nodes[self.len] = node;
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
        const commands = c.hollow_clay_layout(self.context, &self.nodes, @intCast(self.len), width, height, cell_w, cell_h, self.mouse_x, self.mouse_y, self.scroll_y, dt);
        self.scroll_y = 0;
        if (c.hollow_clay_failed(self.context)) {
            std.log.err("Clay surface exceeded limits or received invalid layout", .{});
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
