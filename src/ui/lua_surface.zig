//! State owned by a GUI-only Lua pane. Terminal resources never live here.
const std = @import("std");
const lua = @import("../lua_bridge.zig");
const ClaySurface = @import("clay_surface.zig").Surface;

pub const LuaSurface = struct {
    ref: c_int = -1,
    runtime_generation: u64 = 0,
    dirty: bool = true,
    /// Native rendering storage is erased so headless pane consumers do not
    /// acquire a Clay/GUI link dependency merely by destroying a Lua node.
    clay: ?*anyopaque = null,
    on_clay_deinit: ?*const fn (*anyopaque, std.mem.Allocator) void = null,
    prepared: ?Viewport = null,
    revision: f64 = 0,
    hovered_id: ?[]u8 = null,
    pointer_x: f32 = -1,
    pointer_y: f32 = -1,
    context: ?*anyopaque = null,
    /// The host releases its Lua reference and runs unmount before storage dies.
    on_deinit: ?*const fn (*LuaSurface) void = null,

    pub const Viewport = struct {
        pane_id: usize,
        width: f32,
        height: f32,
        cols: u16,
        rows: u16,
        focused: bool,
        cell_w: f32,
        cell_h: f32,
    };

    /// Registry reference to an owned `ui.layout` surface. The host releases
    /// the reference; generation prevents using it after a Lua runtime reload.
    pub fn attach(self: *LuaSurface, ref: c_int, generation: u64) void {
        std.debug.assert(self.ref < 0);
        self.ref = ref;
        self.runtime_generation = generation;
        self.dirty = true;
    }

    pub fn clayState(self: *LuaSurface) ?*ClaySurface {
        return @ptrCast(@alignCast(self.clay orelse return null));
    }

    /// Called under the Lua lock, before atlas upload. Clean panes do not enter
    /// Lua. Snapshot parsing never changes standalone/overlay publication.
    pub fn prepare(self: *LuaSurface, allocator: std.mem.Allocator, runtime: *lua.Runtime, renderer: anytype, viewport: Viewport) bool {
        if (self.ref < 0) return false;
        if (self.runtime_generation != runtime.generation) {
            self.ref = -1;
            if (self.clayState()) |surface| surface.active = false;
            self.dirty = false;
            return true;
        }
        if (!self.dirty and self.prepared != null and std.meta.eql(self.prepared.?, viewport)) return false;
        if (self.clay == null) {
            const surface = allocator.create(ClaySurface) catch return false;
            surface.* = .{};
            self.clay = surface;
            self.on_clay_deinit = struct {
                fn destroy(context: *anyopaque, a: std.mem.Allocator) void {
                    const tree: *ClaySurface = @ptrCast(@alignCast(context));
                    tree.deinit();
                    a.destroy(tree);
                }
            }.destroy;
        }
        const surface = self.clayState().?;
        surface.active = false;
        // Consume this invalidation before Lua runs, preserving an invalidate()
        // called from render for the next frame.
        self.dirty = false;
        self.prepared = viewport;
        const api = runtime.context.api;
        const state = runtime.state;
        const top = api.get_top(state);
        defer api.set_top(state, top);
        api.rawgeti(state, -10000, self.ref);
        if (api.value_type(state, -1) != @backingInt(lua.LuaType.table)) return true;
        const owner = lua.absoluteIndex(api, state, -1);
        api.get_field(state, owner, "invalidate");
        api.push_value(state, owner);
        if (api.pcall(state, 1, 0, 0) != 0) {
            logError(runtime);
            return true;
        }
        api.get_field(state, owner, "snapshot");
        api.push_value(state, owner);
        pushContext(runtime, viewport);
        if (api.pcall(state, 2, 1, 0) != 0) {
            logError(runtime);
            return true;
        }
        self.revision += 1;
        surface.prepareSnapshot(runtime, renderer, -1, self.revision, @floatFromInt(viewport.pane_id));
        return true;
    }

    fn logError(runtime: *lua.Runtime) void {
        var len: usize = 0;
        if (runtime.context.api.to_lstring(runtime.state, -1, &len)) |ptr| std.log.err("Lua pane snapshot: {s}", .{ptr[0..len]});
    }

    pub fn pushContext(runtime: *lua.Runtime, viewport: Viewport) void {
        const api = runtime.context.api;
        const state = runtime.state;
        api.create_table(state, 0, 8);
        inline for (.{ "pane_id", "width", "height", "cols", "rows", "focused", "cell_w", "cell_h" }) |field| {
            const value = @field(viewport, field);
            if (@TypeOf(value) == bool) {
                api.push_boolean(state, @intFromBool(value));
            } else if (@TypeOf(value) == f32) {
                api.push_number(state, value);
            } else {
                api.push_number(state, @floatFromInt(value));
            }
            api.set_field(state, -2, field);
        }
    }

    pub fn deinit(self: *LuaSurface, allocator: std.mem.Allocator) void {
        if (self.on_deinit) |callback| {
            self.on_deinit = null;
            callback(self);
        }
        if (self.hovered_id) |id| allocator.free(id);
        if (self.clay) |surface| if (self.on_clay_deinit) |destroy| destroy(surface, allocator);
        self.* = .{};
    }
};

test "Lua surface releases its host reference and hover storage exactly once" {
    const Host = struct {
        calls: usize = 0,
        native_calls: usize = 0,
        fn release(surface: *LuaSurface) void {
            const self: *@This() = @ptrCast(@alignCast(surface.context.?));
            std.debug.assert(surface.ref == 42);
            self.calls += 1;
        }
        fn releaseNative(context: *anyopaque, _: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.native_calls += 1;
        }
    };
    const allocator = std.testing.allocator;
    var host: Host = .{};
    var surface: LuaSurface = .{
        .ref = 42,
        .context = &host,
        .on_deinit = Host.release,
        .clay = &host,
        .on_clay_deinit = Host.releaseNative,
        .hovered_id = try allocator.dupe(u8, "pane:1:button"),
    };
    surface.deinit(allocator);
    surface.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), host.calls);
    try std.testing.expectEqual(@as(usize, 1), host.native_calls);
    try std.testing.expect(surface.hovered_id == null);
}

test "Lua pane snapshots are owned isolated and prepared only when invalidated" {
    const allocator = std.testing.allocator;
    var cfg = @import("../config.zig").Config.init(allocator);
    defer cfg.deinit();
    var runtime = try lua.Runtime.init(allocator, &cfg);
    defer runtime.deinit();
    try runtime.runString(
        \\hollow = {ui = {_layout_tree = 'overlay sentinel'}}
        \\calls = 0
        \\pane_surface = {
        \\  invalidate = function(self) self.dirty = true end,
        \\  snapshot = function(self, ctx)
        \\    calls = calls + 1
        \\    assert(ctx.pane_id == 42 and ctx.cols == 20 and ctx.rows == 5)
        \\    return {{kind = 0, id = 'pane:42:root', width = -1, height = -1, children = 1},
        \\            {kind = 0, id = 'pane:42:button', width = 100, height = 20, clickable = true, children = 1},
        \\            {kind = 2, text = 'owned text'}}
        \\  end,
        \\}
    );
    const MockRenderer = struct {
        labels: usize = 0,
        pub fn preRasterizeLabelFace(self: *@This(), _: []const u8, _: u8) void {
            self.labels += 1;
        }
    };
    var renderer: MockRenderer = .{};
    const api = runtime.context.api;
    const top = api.get_top(runtime.state);
    api.get_field(runtime.state, -10002, "pane_surface");
    const ref = api.ref(runtime.state, -10000);
    defer api.unref(runtime.state, -10000, ref);
    var surface: LuaSurface = .{};
    defer surface.deinit(allocator);
    surface.attach(ref, runtime.generation);
    var viewport: LuaSurface.Viewport = .{ .pane_id = 42, .width = 200, .height = 100, .cols = 20, .rows = 5, .focused = true, .cell_w = 10, .cell_h = 20 };
    try std.testing.expect(surface.prepare(allocator, &runtime, &renderer, viewport));
    try std.testing.expect(!surface.prepare(allocator, &runtime, &renderer, viewport));
    try std.testing.expectEqual(@as(usize, 1), renderer.labels);
    const tree = surface.clayState().?;
    try std.testing.expect(tree.active);
    try std.testing.expectEqualStrings("owned text", tree.nodes[2].text.chars[0..10]);
    try std.testing.expect(tree.layout(200, 100, 10, 20, 0).length > 0);
    tree.area = .{ .x = 300, .y = 100, .width = 200, .height = 100 };
    try std.testing.expect(tree.hitTest(.clickable, 305, 105) != null);
    try std.testing.expect(tree.hitTest(.clickable, 5, 5) == null);
    try runtime.runString("pane_surface.snapshot_copy = pane_surface.snapshot; assert(calls == 1); assert(hollow.ui._layout_tree == 'overlay sentinel')");

    surface.dirty = true;
    try std.testing.expect(surface.prepare(allocator, &runtime, &renderer, viewport));
    viewport.focused = false;
    try std.testing.expect(surface.prepare(allocator, &runtime, &renderer, viewport));
    viewport.width = 180;
    try std.testing.expect(surface.prepare(allocator, &runtime, &renderer, viewport));
    try runtime.runString("assert(calls == 4)");
    api.rawgeti(runtime.state, -10000, ref);
    const second_ref = api.ref(runtime.state, -10000);
    defer api.unref(runtime.state, -10000, second_ref);
    var second: LuaSurface = .{};
    defer second.deinit(allocator);
    second.attach(second_ref, runtime.generation);
    try std.testing.expect(second.prepare(allocator, &runtime, &renderer, viewport));
    try std.testing.expect(second.clayState().?.context != tree.context);
    try std.testing.expect(second.clayState().?.nodes[2].text.chars != tree.nodes[2].text.chars);
    try runtime.runString("pane_surface = nil; collectgarbage('collect'); assert(hollow.ui._layout_tree == 'overlay sentinel')");
    try std.testing.expectEqualStrings("owned text", tree.nodes[2].text.chars[0..10]);
    try std.testing.expectEqual(top, api.get_top(runtime.state));
    // Never resolve an old registry index against a new Lua runtime.
    surface.runtime_generation +%= 1;
    try std.testing.expect(surface.prepare(allocator, &runtime, &renderer, viewport));
    try std.testing.expect(!tree.active);
    try std.testing.expectEqual(@as(c_int, -1), surface.ref);
    try std.testing.expect(!surface.prepare(allocator, &runtime, &renderer, viewport));
}
