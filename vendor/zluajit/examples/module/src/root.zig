const std = @import("std");
const zluajit = @import("zluajit");

fn greet(name: []const u8) void {
    std.debug.print("Hello {s} from Zig module!\n", .{name});
}

// This function will be called when `require("module")` is called from Lua.
export fn luaopen_module(lua: ?*zluajit.c.lua_State) callconv(.c) c_int {
    const state = zluajit.State.initFromCPointer(lua.?);

    state.newTable();
    state.pushAnyType(greet);
    state.setField(-2, "greet");

    return 1;
}
