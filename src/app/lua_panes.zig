//! GUI-only pane creation is queued, like terminal layout operations.
const std = @import("std");
const App = @import("../app.zig").App;
const LuaSurface = @import("../ui/lua_surface.zig").LuaSurface;
const SplitDirection = @import("../mux.zig").SplitDirection;
const Pane = @import("../pane.zig").Pane;

pub const Pointer = struct {
    pane_id: usize,
    generation: u64,
    revision: f64,
    layout_generation: u32,
    kind: enum { click, hover },
    /// Owned by the input event, never borrowed from a retained Clay arena.
    id: ?[]const u8 = null,
    x: f32 = -1,
    y: f32 = -1,
};

pub fn pointer(app: *App, event: Pointer) void {
    const pane = app.findPaneById(event.pane_id) orelse return;
    const surface = pane.asLua() orelse return;
    const runtime = if (app.lua) |*r| r else return;
    if (surface.ref < 0 or runtime.generation != event.generation or surface.runtime_generation != event.generation) return;
    if (event.layout_generation != app.currentLayoutGeneration()) return;
    if (event.id != null and surface.revision != event.revision) return;
    if (event.kind == .hover) {
        surface.pointer_x = event.x;
        surface.pointer_y = event.y;
        const same = if (event.id) |id| (if (surface.hovered_id) |old| std.mem.eql(u8, id, old) else false) else surface.hovered_id == null;
        if (same) return;
        const owned = if (event.id) |id| pane.allocator.dupe(u8, id) catch return else null;
        if (surface.hovered_id) |old| pane.allocator.free(old);
        surface.hovered_id = owned;
    } else {
        if (!app.isPaneVisible(pane)) return;
        if (app.mux) |*mux| {
            const previous = mux.activePane();
            mux.setActivePane(pane);
            app.syncActivePaneChange(previous, pane);
            if (previous != pane) app.emitLuaBuiltInEvent("term:pane_focused", .{ .pane_id = pane.id });
        }
    }
    pane.invalidate();
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    const api = runtime.context.api;
    const state = runtime.state;
    const top = api.get_top(state);
    defer api.set_top(state, top);
    api.rawgeti(state, -10000, surface.ref);
    api.get_field(state, -1, "pointer");
    if (api.value_type(state, -1) != @backingInt(@import("../lua_bridge.zig").LuaType.function)) return;
    api.push_value(state, -2);
    const kind = @tagName(event.kind);
    api.push_lstring(state, kind.ptr, kind.len);
    if (event.id) |id| api.push_lstring(state, id.ptr, id.len) else api.push_nil(state);
    if (api.pcall(state, 3, 0, 0) != 0) {
        var len: usize = 0;
        const err = api.to_lstring(state, -1, &len);
        std.log.err("Lua pane pointer: {s}", .{if (err) |ptr| ptr[0..len] else "unknown error"});
    }
}

pub const Create = struct {
    id: usize,
    ref: c_int,
    generation: u64,
    direction: SplitDirection,
    ratio: f32,
    floating: bool,
};

pub fn create(context: *anyopaque, ref: c_int, direction: []const u8, ratio: f32, floating: bool) usize {
    if (!std.math.isFinite(ratio) or ratio <= 0 or ratio >= 1) return 0;
    const app: *App = @ptrCast(@alignCast(context));
    if (app.automation_shutting_down) return 0;
    const mux = if (app.mux) |*m| m else return 0;
    const runtime = if (app.lua) |*r| r else return 0;
    const id = mux.reservePaneId();
    if (!app.enqueueMouse(.{ .create_lua_pane = .{
        .id = id,
        .ref = ref,
        .generation = runtime.generation,
        .direction = if (std.mem.eql(u8, direction, "horizontal")) .horizontal else .vertical,
        .ratio = ratio,
        .floating = floating,
    } })) return 0;
    return id;
}

pub fn invalidate(context: *anyopaque, id: usize) void {
    const app: *App = @ptrCast(@alignCast(context));
    _ = app.enqueueMouse(.{ .invalidate_lua_pane = id });
}

pub fn title(context: *anyopaque, id: usize, text: []const u8) void {
    const app: *App = @ptrCast(@alignCast(context));
    const owned = app.allocator.dupe(u8, text) catch return;
    if (!app.enqueueMouse(.{ .title_lua_pane = .{ .id = id, .text = owned } })) app.allocator.free(owned);
}

pub fn release(app: *App, ref: c_int, generation: u64) void {
    if (ref < 0) return;
    const runtime = if (app.lua) |*r| r else return;
    if (runtime.generation != generation) return;
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    const api = runtime.context.api;
    const state = runtime.state;
    const top = api.get_top(state);
    defer api.set_top(state, top);
    api.rawgeti(state, -10000, ref);
    api.get_field(state, -1, "destroy");
    api.push_value(state, -2);
    if (api.pcall(state, 1, 0, 0) != 0) std.log.err("Lua pane destroy failed", .{});
    api.unref(state, -10000, ref);
}

/// Unmount against the old runtime, never against a recycled registry index.
pub fn beforeReload(app: *App) void {
    const mux = if (app.mux) |*m| m else return;
    var panes = mux.paneIterator();
    while (panes.next()) |pane| {
        const surface = pane.asLua() orelse continue;
        release(app, surface.ref, surface.runtime_generation);
        surface.ref = -1;
        surface.dirty = false;
        if (surface.hovered_id) |id| pane.allocator.free(id);
        surface.hovered_id = null;
        surface.pointer_x = -1;
        surface.pointer_y = -1;
        if (surface.clay) |tree| if (surface.on_clay_deinit) |free| free(tree, app.allocator);
        surface.clay = null;
        surface.on_clay_deinit = null;
        pane.render_dirty = .full;
    }
}

fn unmount(surface: *LuaSurface) void {
    const app: *App = @ptrCast(@alignCast(surface.context.?));
    release(app, surface.ref, surface.runtime_generation);
}

pub fn focus(app: *App, pane: *Pane, focused: bool) void {
    pane.invalidate();
    const surface = pane.asLua() orelse return;
    const runtime = if (app.lua) |*r| r else return;
    if (surface.ref < 0 or surface.runtime_generation != runtime.generation) return;
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    const api = runtime.context.api;
    const state = runtime.state;
    const top = api.get_top(state);
    defer api.set_top(state, top);
    api.rawgeti(state, -10000, surface.ref);
    api.get_field(state, -1, "focus");
    if (api.value_type(state, -1) != @backingInt(@import("../lua_bridge.zig").LuaType.function)) return;
    api.push_value(state, -2);
    LuaSurface.pushContext(runtime, .{
        .pane_id = pane.id,
        .width = @floatFromInt(pane.width_px),
        .height = @floatFromInt(pane.height_px),
        .cols = pane.cols,
        .rows = pane.rows,
        .cell_w = @floatFromInt(app.cell_width_px),
        .cell_h = @floatFromInt(app.cell_height_px),
        .focused = focused,
    });
    api.push_boolean(state, @intFromBool(focused));
    if (api.pcall(state, 3, 0, 0) != 0) {
        var len: usize = 0;
        const err = api.to_lstring(state, -1, &len);
        std.log.err("Lua pane focus: {s}", .{if (err) |ptr| ptr[0..len] else "unknown error"});
    }
}

pub fn process(app: *App, payload: Create) void {
    const mux = if (app.mux) |*m| m else {
        release(app, payload.ref, payload.generation);
        return;
    };
    if (app.lua == null or app.lua.?.generation != payload.generation) return;
    const pane = mux.createLuaPaneWithId(payload.id) catch {
        release(app, payload.ref, payload.generation);
        return;
    };
    const surface = pane.asLua().?;
    surface.attach(payload.ref, payload.generation);
    surface.context = app;
    surface.on_deinit = unmount;
    const previous = mux.activePane();
    mux.splitActivePaneWith(pane, payload.direction, payload.ratio, payload.floating) catch {
        surface.deinit(app.allocator);
        app.allocator.destroy(surface);
        app.allocator.destroy(pane);
        return;
    };
    app.syncActivePaneChange(previous, pane);
    app.requestLayoutResize(false);
}
