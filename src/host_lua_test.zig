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
    try run(state, "assets=require('hollow.host.artifacts').discover(again:value())");
    try until(state, "DONE=assets:status()~='pending'");
    try run(state,
        \\assert(assets:status()=='fulfilled',assets:error() and assets:error().message)
        \\assert(assets:value().x86_64 and assets:value().aarch64)
    );
    const container = std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_PODMAN_CONTAINER") catch null;
    defer if (container) |bytes| std.testing.allocator.free(bytes);
    if (container) |name| {
        c.lua_pushlstring(state, name.ptr, name.len);
        c.lua_setfield(state, c.LUA_GLOBALSINDEX, "PODMAN_CONTAINER");
        const uid = try std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_PODMAN_UID");
        defer std.testing.allocator.free(uid);
        c.lua_pushlstring(state, uid.ptr, uid.len);
        c.lua_setfield(state, c.LUA_GLOBALSINDEX, "PODMAN_UID");
        try run(state,
            \\PODMAN_ARTIFACT=assets:value().x86_64.path; PODMAN_SHA256=assets:value().x86_64.sha256
            \\bootstrap_opts={id='podman-production',container=PODMAN_CONTAINER}
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
    const distro = std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_WSL_DISTRO") catch null;
    defer if (distro) |bytes| std.testing.allocator.free(bytes);
    if (distro) |name| {
        c.lua_pushlstring(state, name.ptr, name.len);
        c.lua_setfield(state, c.LUA_GLOBALSINDEX, "WSL_DISTRO");
        inline for (.{ "EXE", "USER", "EXPECTED_USER", "ARTIFACT" }) |suffix| {
            const bytes = try std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_WSL_" ++ suffix);
            defer std.testing.allocator.free(bytes);
            c.lua_pushlstring(state, bytes.ptr, bytes.len);
            c.lua_setfield(state, c.LUA_GLOBALSINDEX, "WSL_" ++ suffix);
        }
        try run(state,
            \\wopts={id='wsl-production',distro=WSL_DISTRO,wsl=WSL_EXE,user=WSL_USER~='' and WSL_USER or nil}
            \\if WSL_ARTIFACT~='' then wopts.artifacts={x86_64={path=WSL_ARTIFACT,sha256=assets:value().x86_64.sha256}} end
            \\wconnected=hollow.host.wsl(wopts)
        );
        try until(state, "DONE=wconnected:status()~='pending'");
        try run(state,
            \\assert(wconnected:status()=='fulfilled',wconnected:error() and wconnected:error().message)
            \\wh=wconnected:value(); wi=wh:info(); wr=wh.fs.read('/etc/os-release'); wl=wh.fs.list('/tmp',{limit=3})
            \\we=wh:exec({argv={'/bin/sh','-c','printf "%s" "$1"; printf err >&2; exit 5','test'," a'\255\n"}})
            \\wu=wh:exec({argv={'id','-un'}})
            \\wc=wh:exec({argv={'/bin/sh','-c','exec sleep 30'}}); assert(wc:cancel())
        );
        try until(state, "DONE=wi:status()~='pending' and wr:status()~='pending' and wl:status()~='pending' and we:status()~='pending' and wu:status()~='pending' and wc:status()~='pending'");
        try run(state,
            \\assert(wi:value().os=='linux' and #wr:value().bytes>0 and #wl:value().entries<=3)
            \\assert(we:value().exit_code==5 and we:value().stdout==" a'\255\n" and we:value().stderr=='err')
            \\assert(wu:value().stdout==WSL_EXPECTED_USER..'\n' and wc:error().code=='cancelled')
            \\assert(wh:close()); wopts.id='wsl-reuse'; wreuse=hollow.host.wsl(wopts)
        );
        try until(state, "DONE=wreuse:status()~='pending'");
        try run(state,
            \\assert(wreuse:status()=='fulfilled',wreuse:error() and wreuse:error().message)
            \\assert(wreuse:value().generation~=wh.generation); assert(wreuse:value():close())
            \\wopts.id='wsl-preinstalled'; wopts.agent_path=wi:value().home..'/.cache/hollow/agents/linux-'..wi:value().arch..'/'..assets:value()[wi:value().arch].sha256..'/hollow-agent'
            \\wpre=hollow.host.wsl(wopts)
        );
        try until(state, "DONE=wpre:status()~='pending'");
        try run(state,
            \\assert(wpre:status()=='fulfilled',wpre:error() and wpre:error().message)
            \\assert(wpre:value():close())
        );
    }
    const ssh_destination = std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_SSH_DESTINATION") catch null;
    defer if (ssh_destination) |bytes| std.testing.allocator.free(bytes);
    if (ssh_destination) |name| {
        c.lua_pushlstring(state, name.ptr, name.len);
        c.lua_setfield(state, c.LUA_GLOBALSINDEX, "SSH_DESTINATION");
        inline for (.{ "PORT", "USER", "IDENTITY_FILE", "KNOWN_HOSTS", "CONFIG_FILE", "BAD_KNOWN_HOSTS", "EMPTY_KNOWN_HOSTS", "BAD_IDENTITY" }) |suffix| {
            const bytes = try std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_SSH_" ++ suffix);
            defer std.testing.allocator.free(bytes);
            c.lua_pushlstring(state, bytes.ptr, bytes.len);
            c.lua_setfield(state, c.LUA_GLOBALSINDEX, "SSH_" ++ suffix);
        }
        try run(state,
            \\shopts={id='ssh-production',destination=SSH_DESTINATION,port=tonumber(SSH_PORT),user=SSH_USER,identity_file=SSH_IDENTITY_FILE,known_hosts=SSH_KNOWN_HOSTS,config_file=SSH_CONFIG_FILE}
            \\shconnected=hollow.host.ssh(shopts)
        );
        try until(state, "DONE=shconnected:status()~='pending'");
        try run(state,
            \\assert(shconnected:status()=='fulfilled',shconnected:error() and shconnected:error().message)
            \\sh=shconnected:value(); si=sh:info(); sr=sh.fs.read('/etc/os-release'); sl=sh.fs.list('/tmp',{limit=3})
            \\se=sh:exec({argv={'/bin/sh','-c','printf "%s" "$1"; printf err >&2; exit 6','test'," a'\255\n"}})
            \\su=sh:exec({argv={'id','-un'}}); sc=sh:exec({argv={'/bin/sh','-c','exec sleep 30'}}); assert(sc:cancel())
        );
        try until(state, "DONE=si:status()~='pending' and sr:status()~='pending' and sl:status()~='pending' and se:status()~='pending' and su:status()~='pending' and sc:status()~='pending'");
        try run(state,
            \\assert(si:value().os=='linux' and #sr:value().bytes>0 and #sl:value().entries<=3)
            \\assert(se:value().exit_code==6 and se:value().stdout==" a'\255\n" and se:value().stderr=='err')
            \\assert(su:value().stdout==SSH_USER..'\n' and sc:error().code=='cancelled')
            \\assert(sh:close()); shopts.id='ssh-reuse'; shreuse=hollow.host.ssh(shopts)
        );
        try until(state, "DONE=shreuse:status()~='pending'");
        try run(state,
            \\assert(shreuse:status()=='fulfilled',shreuse:error() and shreuse:error().message)
            \\assert(shreuse:value().generation~=sh.generation); assert(shreuse:value():close())
            \\shopts.id='ssh-preinstalled'; shopts.agent_path=si:value().home..'/.cache/hollow/agents/linux-'..si:value().arch..'/'..assets:value()[si:value().arch].sha256..'/hollow-agent'
            \\shpre=hollow.host.ssh(shopts)
        );
        try until(state, "DONE=shpre:status()~='pending'");
        try run(state,
            \\assert(shpre:status()=='fulfilled',shpre:error() and shpre:error().message)
            \\assert(shpre:value():close())
            \\shopts.id='ssh-bad-checksum'; shopts.agent_path=nil; shopts.artifacts={[si:value().arch]={path=assets:value()[si:value().arch].path,sha256=string.rep('0',64)}}
            \\shwrong=hollow.host.ssh(shopts)
        );
        try until(state, "DONE=shwrong:status()~='pending'");
        try run(state, "assert(shwrong:error().code=='checksum_mismatch',shwrong:error() and shwrong:error().message)");
        try run(state,
            \\shopts.artifacts=nil; shopts.agent_path=si:value().home..'/.cache/hollow/agents/linux-'..si:value().arch..'/'..assets:value()[si:value().arch].sha256..'/hollow-agent'
            \\shopts.id='ssh-host-key-mismatch'; shopts.known_hosts=SSH_BAD_KNOWN_HOSTS; badkey=hollow.host.ssh(shopts)
        );
        try until(state, "DONE=badkey:status()~='pending'");
        try run(state,
            \\assert(badkey:status()=='rejected' and badkey:error().code=='ssh_unavailable')
            \\shopts.id='ssh-unknown-host'; shopts.known_hosts=SSH_EMPTY_KNOWN_HOSTS; unknown=hollow.host.ssh(shopts)
        );
        try until(state, "DONE=unknown:status()~='pending'");
        try run(state,
            \\assert(unknown:status()=='rejected' and unknown:error().code=='ssh_unavailable')
            \\shopts.id='ssh-auth-rejected'; shopts.known_hosts=SSH_KNOWN_HOSTS; shopts.identity_file=SSH_BAD_IDENTITY; badauth=hollow.host.ssh(shopts)
        );
        try until(state, "DONE=badauth:status()~='pending'");
        try run(state, "assert(badauth:status()=='rejected' and badauth:error().code=='ssh_unavailable')");
    }
}
