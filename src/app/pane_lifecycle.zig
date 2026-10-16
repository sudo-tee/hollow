const App = @import("../app.zig").App;
const Pane = @import("../pane.zig").Pane;

pub fn created(context: *anyopaque, pane: *Pane) void {
    const app: *App = @ptrCast(@alignCast(context));
    app.emitLuaBuiltInEvent("term:pane_created", .{ .pane_id = @intFromPtr(pane) });
}

pub fn exited(app: *App, pane: *Pane) void {
    if (pane.exit_event_emitted or pane.hasLiveChild()) return;
    pane.exit_event_emitted = true;
    const status = if (pane.pty) |*pty| pty.exitStatus() else null;
    app.emitLuaBuiltInEvent("term:pane_exited", .{ .pane_exited = .{
        .pane_id = @intFromPtr(pane),
        .status = status,
    } });
}

pub fn closing(context: *anyopaque, pane: *Pane) void {
    const app: *App = @ptrCast(@alignCast(context));
    // A user close may reach an exited child before the next cleanup tick.
    exited(app, pane);
    app.emitLuaBuiltInEvent("term:pane_closed", .{ .pane_id = @intFromPtr(pane) });
}

test "pane lifecycle emits observed exit once before closing across Lua reloads" {
    const std = @import("std");
    const Runtime = @import("../lua_bridge.zig").Runtime;
    const app = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app);
    app.* = App.init(std.testing.allocator);
    defer app.config.deinit();
    app.lua = try Runtime.init(std.testing.allocator, &app.config);
    defer if (app.lua) |*lua| lua.deinit();
    var pane = Pane.init(std.testing.allocator);
    // A pane with no PTY models an unavailable OS exit status.
    try app.lua.?.runString(
        \\received = {}
        \\hollow = {_emit_builtin_event = function(name, payload)
        \\  received[#received + 1] = name
        \\  assert(type(payload.pane_id) == "number")
        \\  assert(payload.status == nil)
        \\end}
    );
    created(app, &pane);
    exited(app, &pane);
    exited(app, &pane);
    try app.lua.?.runString(
        \\assert(#received == 2)
        \\assert(received[1] == "term:pane_created" and received[2] == "term:pane_exited")
    );
    app.lua.?.deinit();
    app.lua = null;
    app.lua = try Runtime.init(std.testing.allocator, &app.config);
    try app.lua.?.runString(
        \\received = {}
        \\hollow = {_emit_builtin_event = function(name)
        \\  received[#received + 1] = name
        \\end}
    );
    exited(app, &pane);
    closing(app, &pane);
    try app.lua.?.runString(
        \\assert(#received == 1 and received[1] == "term:pane_closed")
    );
}
