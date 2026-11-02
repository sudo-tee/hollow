//! GUI-only pane creation is queued, like terminal layout operations.
const std = @import("std");
const App = @import("../app.zig").App;
const LuaSurface = @import("../ui/lua_surface.zig").LuaSurface;
const SplitDirection = @import("../mux.zig").SplitDirection;

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
