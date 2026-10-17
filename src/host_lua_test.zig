//! Optional headless native/Lua integration test; links the Lua 5.1 C API.
const std = @import("std");
const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});
const bindings = @import("host/lua.zig");
const host = @import("host.zig");
const Api = struct {
    pub const get_top = c.lua_gettop;
    pub const set_top = c.lua_settop;
    pub const create_table = c.lua_createtable;
    pub const get_field = c.lua_getfield;
    pub const set_field = c.lua_setfield;
    pub const push_integer = c.lua_pushinteger;
    pub const push_number = c.lua_pushnumber;
    pub const push_string = c.lua_pushstring;
    pub const push_lstring = c.lua_pushlstring;
    pub const push_nil = c.lua_pushnil;
    pub const push_boolean = c.lua_pushboolean;
    pub const to_number = c.lua_tonumber;
    pub const to_lstring = c.lua_tolstring;
    pub const value_type = c.lua_type;
    pub const rawgeti = c.lua_rawgeti;
    pub const rawseti = c.lua_rawseti;
    pub const next = c.lua_next;
};
const Context = struct { comptime api: type = Api, allocator: std.mem.Allocator, host_manager: ?host.Manager = null };

fn Callback(comptime name: []const u8) type {
    return struct {
        fn call(maybe_state: ?*c.lua_State) callconv(.c) c_int {
            const state = maybe_state.?;
            const ctx: *Context = @ptrCast(@alignCast(c.lua_touserdata(state, -10003).?));
            return @field(bindings, name)(ctx, state);
        }
    };
}

fn run(state: *c.lua_State, source: []const u8) !void {
    if (c.luaL_loadbuffer(state, source.ptr, source.len, "host-test") != 0 or c.lua_pcall(state, 0, 0, 0) != 0) {
        var len: usize = 0;
        const text = c.lua_tolstring(state, -1, &len);
        std.debug.print("Lua: {s}\n", .{text[0..len]});
        c.lua_settop(state, -2);
        return error.LuaError;
    }
}

fn until(state: *c.lua_State, predicate: []const u8) !void {
    const deadline = std.Io.Clock.awake.now(std.testing.io).toNanoseconds() + 60000 * std.time.ns_per_ms;
    while (std.Io.Clock.awake.now(std.testing.io).toNanoseconds() < deadline) {
        try run(state, "local q=deferred;deferred={};for _,fn in ipairs(q) do fn() end");
        try run(state, predicate);
        c.lua_getfield(state, c.LUA_GLOBALSINDEX, "DONE");
        const done = c.lua_toboolean(state, -1) != 0;
        c.lua_settop(state, -2);
        if (done) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.Timeout;
}

fn nowMs(maybe_state: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushnumber(maybe_state, @floatFromInt(@divTrunc(std.Io.Clock.awake.now(std.testing.io).toNanoseconds(), std.time.ns_per_ms)));
    return 1;
}

test "Lua host promises execute native concurrent RPCs and cancel on runtime teardown" {
    const state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(state);
    c.luaL_openlibs(state);
    var ctx: Context = .{ .allocator = std.testing.allocator };
    defer if (ctx.host_manager) |*manager| manager.deinit();
    c.lua_createtable(state, 0, 6);
    inline for (.{ "connect", "status", "close", "start", "poll", "cancel" }) |name| {
        c.lua_pushlightuserdata(state, &ctx);
        c.lua_pushcclosure(state, Callback(name).call, 1);
        c.lua_setfield(state, -2, "host_" ++ name);
    }
    c.lua_pushcclosure(state, nowMs, 0);
    c.lua_setfield(state, -2, "now_ms");
    c.lua_setfield(state, c.LUA_GLOBALSINDEX, "host_api");
    const agent = std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_AGENT") catch try std.testing.allocator.dupe(u8, "zig-out/bin/hollow-agent");
    defer std.testing.allocator.free(agent);
    c.lua_createtable(state, 2, 0);
    const configured_argv = std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_CONNECTOR_ARGV") catch null;
    defer if (configured_argv) |bytes| std.testing.allocator.free(bytes);
    if (configured_argv) |bytes| {
        const parsed = try std.json.parseFromSlice([]const []const u8, std.testing.allocator, bytes, .{});
        defer parsed.deinit();
        for (parsed.value, 0..) |arg, i| {
            c.lua_pushlstring(state, arg.ptr, arg.len);
            c.lua_rawseti(state, -2, @intCast(i + 1));
        }
    } else {
        c.lua_pushlstring(state, agent.ptr, agent.len);
        c.lua_rawseti(state, -2, 1);
        c.lua_pushstring(state, "stdio");
        c.lua_rawseti(state, -2, 2);
    }
    c.lua_setfield(state, c.LUA_GLOBALSINDEX, "CONNECTOR_ARGV");
    try run(state,
        \\package.path='src/lua/?.lua;'..package.path
        \\deferred={}; host_api.defer=function(fn) deferred[#deferred+1]=fn end
        \\hollow={async=require('hollow.async'),host=require('hollow.host')}
        \\connected=hollow.host.connect({id='test',argv=CONNECTOR_ARGV})
        \\assert(connected:status()=='pending')
    );
    try until(state, "DONE=connected:status()~='pending'");
    try run(state,
        \\assert(connected:status()=='fulfilled', tostring(connected:error() and connected:error().message))
        \\h=connected:value()
        \\p=h:exec({argv={'/bin/sh','-c','sleep 0.1; printf abc; printf err >&2; exit 7'},env={TEST='bytes\255'}})
        \\info=h:info()
        \\assert(p:status()=='pending' and info:status()=='pending')
    );
    try until(state, "DONE=p:status()~='pending' and info:status()~='pending'");
    try run(state,
        \\assert(info:status()=='fulfilled',info:error() and info:error().message)
        \\assert(info:value().os=='linux')
        \\assert(p:status()=='fulfilled',p:error() and p:error().message)
        \\assert(p:value().exit_code==7 and p:value().stdout=='abc' and p:value().stderr=='err')
        \\read=h.fs.read('/etc/os-release')
        \\list=h.fs.list('/tmp',{limit=5})
        \\missing=h.fs.stat('/hollow-missing-test-file')
        \\canceled=h:exec({argv={'/bin/sh','-c','sleep 30'}})
        \\assert(canceled:cancel());assert(not canceled:cancel())
    );
    try until(state, "DONE=read:status()~='pending' and list:status()~='pending' and missing:status()~='pending' and canceled:status()~='pending'");
    try run(state,
        \\assert(read:status()=='fulfilled' and #read:value().bytes>0)
        \\assert(list:status()=='fulfilled' and #list:value().entries<=5)
        \\assert(missing:error().code=='not_found')
        \\assert(canceled:error().code=='cancelled')
        \\-- Native entry points reject malformed/dense-hole argv without launch.
        \\raw=assert(host_api.host_connect({id='bad',argv=CONNECTOR_ARGV}))
        \\local bad,err=host_api.host_start(raw,'exec',{argv={[1]='x',[3]='y'}})
        \\assert(not bad and err.code=='invalid_argument')
        \\h:close();closed=h:info();assert(closed:status()=='rejected')
    );
    try until(state, "DONE=host_api.host_status(raw)=='ready'");
    try run(state,
        \\oldticket=assert(host_api.host_start(raw,'exec',{argv={'/bin/sh','-c','sleep 30'}}))
        \\assert(type(oldticket.id)=='string' and type(oldticket.generation)=='string')
        \\-- IDs outside Lua's exact-number range remain exact opaque strings.
        \\local stale={slot=raw.slot,generation='18446744073709551615'}
        \\local status,err=host_api.host_status(stale)
        \\assert(status=='disconnected' and err.code=='session_gone')
    );
    // Simulate reload's native manager replacement while keeping this test Lua
    // state to deliberately invoke a stale callback. Real Runtime closes Lua.
    ctx.host_manager.?.deinit();
    ctx.host_manager = null;
    try run(state,
        \\assert(host_api.host_poll(oldticket).error.code=='session_gone')
        \\native=hollow.host.local_host()
        \\assert(native==hollow.host.local_host())
    );
    try until(state, "DONE=native:status()~='pending'");
    try run(state,
        \\assert(native:status()=='fulfilled',native:error() and native:error().message)
        \\nh=native:value(); assert(type(nh.generation)=='string')
        \\ni=nh:info(); ns=nh.fs.stat('.')
        \\ne=nh:exec({argv={'/bin/sh','-c','printf native; exit 4'}})
        \\nc=nh:exec({argv={'/bin/sh','-c','exec sleep 30'}})
        \\assert(nc:cancel())
    );
    try until(state, "DONE=ni:status()~='pending' and ns:status()~='pending' and ne:status()~='pending' and nc:status()~='pending'");
    try run(state,
        \\assert(ni:value().os=='linux' and ni:value().build=='local')
        \\assert(ns:value().kind=='directory')
        \\assert(ne:value().stdout=='native' and ne:value().exit_code==4)
        \\assert(nc:error().code=='cancelled')
        \\assert(nh:close())
        \\again=hollow.host.local_host()
    );
    try until(state, "DONE=again:status()~='pending'");
    try run(state, "assert(again:value().generation~=nh.generation)");
    const container = std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_PODMAN_CONTAINER") catch null;
    defer if (container) |bytes| std.testing.allocator.free(bytes);
    if (container) |name| {
        c.lua_pushlstring(state, name.ptr, name.len);
        c.lua_setfield(state, c.LUA_GLOBALSINDEX, "PODMAN_CONTAINER");
        inline for (.{ "ARTIFACT", "SHA256", "UID" }) |suffix| {
            const bytes = try std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_PODMAN_" ++ suffix);
            defer std.testing.allocator.free(bytes);
            c.lua_pushlstring(state, bytes.ptr, bytes.len);
            c.lua_setfield(state, c.LUA_GLOBALSINDEX, "PODMAN_" ++ suffix);
        }
        try run(state,
            \\bootstrap_opts={id='podman-production',container=PODMAN_CONTAINER,artifacts={x86_64={path=PODMAN_ARTIFACT,sha256=PODMAN_SHA256}}}
            \\bootstrap=hollow.host.podman(bootstrap_opts)
        );
        try until(state, "DONE=bootstrap:status()~='pending'");
        try run(state,
            \\assert(bootstrap:status()=='fulfilled',bootstrap:error() and bootstrap:error().message)
            \\bh=bootstrap:value(); bi=bh:info(); bl=bh.fs.list('/tmp'); be=bh:exec({argv={'/bin/sh','-c','printf deployed'}}); bu=bh:exec({argv={'id','-u'}})
        );
        try until(state, "DONE=bi:status()~='pending' and bl:status()~='pending' and be:status()~='pending' and bu:status()~='pending'");
        try run(state,
            \\assert(bi:value().os=='linux' and be:value().stdout=='deployed' and bl:value().eof~=nil)
            \\assert(bu:value().stdout==PODMAN_UID..'\n')
            \\bc=bh:exec({argv={'/bin/sh','-c','exec sleep 30'}}); assert(bc:cancel())
        );
        try until(state, "DONE=bc:status()~='pending'");
        try run(state,
            \\assert(bc:error().code=='cancelled'); assert(bh:close())
            \\bootstrap_opts.id='podman-reuse'; reuse=hollow.host.podman(bootstrap_opts)
        );
        try until(state, "DONE=reuse:status()~='pending'");
        try run(state,
            \\assert(reuse:status()=='fulfilled',reuse:error() and reuse:error().message)
            \\rh=reuse:value(); assert(rh.generation~=bh.generation)
            \\corrupt=rh:exec({argv={'/bin/sh','-c','p="$HOME/.cache/hollow/agents/linux-x86_64/$1/hollow-agent"; printf broken > "$p.bad" && mv -f "$p.bad" "$p"','test',PODMAN_SHA256}})
        );
        try until(state, "DONE=corrupt:status()~='pending'");
        try run(state,
            \\assert(corrupt:value().exit_code==0); assert(rh:close())
            \\bootstrap_opts.id='podman-repair'; repair=hollow.host.podman(bootstrap_opts)
        );
        try until(state, "DONE=repair:status()~='pending'");
        try run(state,
            \\assert(repair:status()=='fulfilled',repair:error() and repair:error().message)
            \\assert(repair:value():close())
            \\preinstalled=hollow.host.podman({id='podman-preinstalled',container=PODMAN_CONTAINER,agent_path=bi:value().home..'/.cache/hollow/agents/linux-x86_64/'..PODMAN_SHA256..'/hollow-agent'})
        );
        try until(state, "DONE=preinstalled:status()~='pending'");
        try run(state,
            \\assert(preinstalled:status()=='fulfilled',preinstalled:error() and preinstalled:error().message)
            \\assert(preinstalled:value():close())
            \\wrong=hollow.host.podman({id='podman-bad-checksum',container=PODMAN_CONTAINER,artifacts={x86_64={path=PODMAN_ARTIFACT,sha256=string.rep('0',64)}}})
        );
        try until(state, "DONE=wrong:status()~='pending'");
        try run(state, "assert(wrong:error().code=='checksum_mismatch',wrong:error() and wrong:error().message)");
    }
}
