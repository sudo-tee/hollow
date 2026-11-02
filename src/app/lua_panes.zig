//! GUI-only pane creation is queued, like terminal layout operations.
const std = @import("std");
const App = @import("../app.zig").App;
const LuaSurface = @import("../ui/lua_surface.zig").LuaSurface;
const SplitDirection = @import("../mux.zig").SplitDirection;
const Pane = @import("../pane.zig").Pane;
const bridge = @import("../lua_bridge.zig");

pub fn contentInfo(context: *anyopaque, id: usize) ?bridge.PaneContentInfo {
    const app: *App = @ptrCast(@alignCast(context));
    const pane = app.findPaneById(id) orelse return null;
    const surface = pane.asLua() orelse return .{ .kind = .terminal };
    return .{ .kind = .lua, .descriptor_json = surface.descriptor_json, .floating = pane.is_floating, .x = pane.floating_x, .y = pane.floating_y, .width = pane.floating_width, .height = pane.floating_height };
}

pub const Pointer = struct {
    pane_id: usize,
    generation: u64,
    revision: f64,
    layout_generation: u32,
    kind: enum { click, hover, scroll },
    /// Owned by the input event, never borrowed from a retained Clay arena.
    id: ?[]const u8 = null,
    x: f32 = -1,
    y: f32 = -1,
    button: Button = .left,
    /// Wheel notches for `scroll`; positive scrolls toward earlier content.
    delta: f32 = 0,

    pub const Button = enum { left, right, middle };
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
    } else if (event.kind == .click) {
        if (!app.isPaneVisible(pane)) return;
        if (app.mux) |*mux| {
            const previous = mux.activePane();
            mux.setActivePane(pane);
            app.syncActivePaneChange(previous, pane);
            if (previous != pane) app.emitLuaBuiltInEvent("term:pane_focused", .{ .pane_id = pane.id });
        }
    }
    pane.invalidate();
    // Lua may consume the wheel; otherwise native Clay scroll containers move.
    if (!callPointer(runtime, surface, event) and event.kind == .scroll) {
        if (surface.clayState()) |tree| tree.scroll_y += event.delta;
    }
}

fn callPointer(runtime: anytype, surface: *LuaSurface, event: Pointer) bool {
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    const api = runtime.context.api;
    const state = runtime.state;
    const top = api.get_top(state);
    defer api.set_top(state, top);
    api.rawgeti(state, -10000, surface.ref);
    api.get_field(state, -1, "pointer");
    if (api.value_type(state, -1) != @backingInt(bridge.LuaType.function)) return false;
    api.push_value(state, -2);
    const kind = @tagName(event.kind);
    api.push_lstring(state, kind.ptr, kind.len);
    if (event.id) |id| api.push_lstring(state, id.ptr, id.len) else api.push_nil(state);
    switch (event.kind) {
        .click => {
            const button = @tagName(event.button);
            api.push_lstring(state, button.ptr, button.len);
        },
        .scroll => api.push_number(state, event.delta),
        .hover => api.push_nil(state),
    }
    if (api.pcall(state, 4, 1, 0) != 0) {
        var len: usize = 0;
        const err = api.to_lstring(state, -1, &len);
        std.log.err("Lua pane pointer: {s}", .{if (err) |ptr| ptr[0..len] else "unknown error"});
        return false;
    }
    return api.to_boolean(state, -1) != 0;
}

pub const Create = struct {
    id: usize,
    ref: c_int,
    generation: u64,
    direction: SplitDirection,
    ratio: f32,
    floating: bool,
    descriptor_json: []const u8,
};

pub fn create(context: *anyopaque, ref: c_int, direction: []const u8, ratio: f32, floating: bool, descriptor: []const u8) usize {
    if (!std.math.isFinite(ratio) or ratio <= 0 or ratio >= 1) return 0;
    const app: *App = @ptrCast(@alignCast(context));
    if (app.automation_shutting_down) return 0;
    const mux = if (app.mux) |*m| m else return 0;
    const runtime = if (app.lua) |*r| r else return 0;
    if (descriptor.len > 65536) return 0;
    const owned = app.allocator.dupe(u8, descriptor) catch return 0;
    const id = mux.reservePaneId();
    if (!app.enqueueMouse(.{ .create_lua_pane = .{
        .id = id,
        .ref = ref,
        .generation = runtime.generation,
        .direction = if (std.mem.eql(u8, direction, "horizontal")) .horizontal else .vertical,
        .ratio = ratio,
        .floating = floating,
        .descriptor_json = owned,
    } })) {
        app.allocator.free(owned);
        return 0;
    }
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
    defer api.unref(state, -10000, ref);
    if (api.value_type(state, -1) != @backingInt(bridge.LuaType.table)) return;
    api.get_field(state, -1, "destroy");
    if (api.value_type(state, -1) != @backingInt(bridge.LuaType.function)) return;
    api.push_value(state, -2);
    if (api.pcall(state, 1, 0, 0) != 0) {
        var len: usize = 0;
        const err = api.to_lstring(state, -1, &len);
        std.log.err("Lua pane destroy: {s}", .{if (err) |ptr| ptr[0..len] else "unknown error"});
    }
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

fn complete(app: *App, payload: Create, success: bool) void {
    const runtime = if (app.lua) |*r| r else return;
    if (runtime.generation != payload.generation) return;
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    const api = runtime.context.api;
    const state = runtime.state;
    const top = api.get_top(state);
    defer api.set_top(state, top);
    api.rawgeti(state, -10000, payload.ref);
    api.get_field(state, -1, "complete");
    if (api.value_type(state, -1) != @backingInt(bridge.LuaType.function)) return;
    api.push_value(state, -2);
    api.push_boolean(state, @intFromBool(success));
    if (api.pcall(state, 2, 0, 0) != 0) std.log.err("Lua pane completion failed", .{});
}

pub fn restoreAll(app: *App) void {
    const mux = if (app.mux) |*m| m else return;
    const runtime = if (app.lua) |*r| r else return;
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    const api = runtime.context.api;
    const state = runtime.state;
    var panes = mux.paneIterator();
    while (panes.next()) |pane| {
        const surface = pane.asLua() orelse continue;
        if (surface.ref >= 0) continue;
        const descriptor = surface.descriptor_json orelse continue;
        const parsed = std.json.parseFromSlice(std.json.Value, app.allocator, descriptor, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object or parsed.value.object.get("module") == null) continue;
        const top = api.get_top(state);
        defer api.set_top(state, top);
        api.get_field(state, -10002, "hollow");
        if (api.value_type(state, -1) != @backingInt(bridge.LuaType.table)) continue;
        api.get_field(state, -1, "ui");
        if (api.value_type(state, -1) != @backingInt(bridge.LuaType.table)) continue;
        api.get_field(state, -1, "pane");
        if (api.value_type(state, -1) != @backingInt(bridge.LuaType.table)) continue;
        api.get_field(state, -1, "_restore");
        if (api.value_type(state, -1) != @backingInt(bridge.LuaType.function)) continue;
        api.push_number(state, @floatFromInt(pane.id));
        api.push_lstring(state, descriptor.ptr, descriptor.len);
        if (api.pcall(state, 2, 1, 0) != 0) {
            var len: usize = 0;
            const err = api.to_lstring(state, -1, &len);
            std.log.warn("Lua pane restore id={d}: {s}", .{ pane.id, if (err) |ptr| ptr[0..len] else "unknown error" });
            continue;
        }
        if (api.value_type(state, -1) != @backingInt(bridge.LuaType.table)) continue;
        surface.attach(api.ref(state, -10000), runtime.generation);
        surface.context = app;
        surface.on_deinit = unmount;
        pane.invalidate();
    }
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
        complete(app, payload, false);
        release(app, payload.ref, payload.generation);
        return;
    };
    if (app.lua == null or app.lua.?.generation != payload.generation) return;
    const runtime = if (app.ghostty) |*r| r else {
        complete(app, payload, false);
        release(app, payload.ref, payload.generation);
        return;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, app.allocator, payload.descriptor_json, .{}) catch {
        complete(app, payload, false);
        release(app, payload.ref, payload.generation);
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        complete(app, payload, false);
        release(app, payload.ref, payload.generation);
        return;
    }
    const object = parsed.value.object;
    const placement = if (object.get("placement")) |value| (if (value == .string) value.string else "invalid") else "split";
    const pane = mux.createLuaPaneWithId(payload.id) catch {
        complete(app, payload, false);
        release(app, payload.ref, payload.generation);
        return;
    };
    const surface = pane.asLua().?;
    surface.attach(payload.ref, payload.generation);
    surface.context = app;
    surface.on_deinit = unmount;
    surface.descriptor_json = pane.allocator.dupe(u8, payload.descriptor_json) catch {
        complete(app, payload, false);
        pane.deinit(runtime);
        mux.allocator.destroy(pane);
        return;
    };
    const previous = mux.activePane();
    const insertion = if (std.mem.eql(u8, placement, "split"))
        mux.splitActivePaneWith(pane, payload.direction, payload.ratio, payload.floating)
    else if (std.mem.eql(u8, placement, "tab"))
        mux.newTabWithPane(runtime, pane)
    else if (std.mem.eql(u8, placement, "workspace"))
        mux.newWorkspaceWithPane(runtime, pane, if (object.get("name")) |value| (if (value == .string) value.string else null) else null)
    else
        error.InvalidPlacement;
    insertion catch {
        complete(app, payload, false);
        pane.deinit(runtime);
        mux.allocator.destroy(pane);
        return;
    };
    if (payload.floating) {
        if (!pane.is_floating) _ = mux.setPaneFloating(pane, true);
        _ = mux.setFloatingPaneBounds(pane, number(object.get("x"), pane.floating_x), number(object.get("y"), pane.floating_y), number(object.get("width"), pane.floating_width), number(object.get("height"), pane.floating_height));
    }
    if (object.get("fullscreen")) |value| if (value == .bool and value.bool) {
        _ = mux.togglePaneMaximized(pane, false);
    };
    app.syncActivePaneChange(previous, pane);
    app.requestLayoutResize(false);
    if (!std.mem.eql(u8, placement, "split")) {
        app.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = mux.activeTab().?.id });
        app.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
    }
    complete(app, payload, true);
}

fn number(value: ?std.json.Value, fallback: f32) f32 {
    const n = switch (value orelse return fallback) {
        .integer => |n| @as(f64, @floatFromInt(n)),
        .float => |n| n,
        else => return fallback,
    };
    return if (std.math.isFinite(n)) @floatCast(std.math.clamp(n, 0, 1)) else fallback;
}
