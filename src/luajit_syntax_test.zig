//! Exercise the exact LuaJIT library embedded in Hollow, not a system interpreter.
const std = @import("std");
const State = opaque {};
extern fn luaL_newstate() ?*State;
extern fn luaL_openlibs(*State) void;
extern fn lua_close(*State) void;
extern fn luaL_loadbuffer(*State, [*]const u8, usize, [*:0]const u8) c_int;
extern fn lua_pcall(*State, c_int, c_int, c_int) c_int;
extern fn lua_tolstring(*State, c_int, *usize) ?[*]const u8;

test "bundled LuaJIT supports backported syntax in interpreter and JIT" {
    const state = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(state);
    luaL_openlibs(state);
    const source =
        \\local function check()
        \\  local present = {something = {value = 42}, disabled = false}
        \\  local absent
        \\  assert(present?.something.value == 42)
        \\  assert(absent?.something.value == nil)
        \\  assert(present?.disabled == false)
        \\  assert((absent?.something ?? 99) == 99)
        \\  assert((present?.disabled ?? true) == false)
        \\  local calls = 0
        \\  local function side_effect() calls += 1; return 'something' end
        \\  assert(absent?.[side_effect()] == nil)
        \\  absent?.something = side_effect()
        \\  assert(calls == 0)
        \\  assert((true ? false : 42) == false)
        \\  assert((5 & 3) == 1)
        \\end
        \\jit.off(check)
        \\check()
        \\jit.on(check)
        \\jit.opt.start('hotloop=1')
        \\for i = 1, 200 do check() end
        \\assert(loadstring(string.dump(check)))()
    ;
    if (luaL_loadbuffer(state, source.ptr, source.len, "syntax-test") != 0 or lua_pcall(state, 0, 0, 0) != 0) {
        var len: usize = 0;
        if (lua_tolstring(state, -1, &len)) |message| std.debug.print("LuaJIT: {s}\n", .{message[0..len]});
        return error.LuaError;
    }
}
