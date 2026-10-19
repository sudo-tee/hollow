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
        std.debug.print("Lua: {s}\nLua source:\n{s}\n", .{ text[0..len], source });
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
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
        \\fixture=h:exec({argv={'/bin/sh','-c',[[p=$(mktemp /tmp/hollow-workspace-XXXXXX) || exit 1; printf '%s' '{"tabs":[]}' > "$p"; head -c 20000 /dev/zero | tr '\000' ' ' >> "$p"; printf '%s' "$p"]]}})
    );
    try until(state, "DONE=fixture:status()~='pending'");
    try run(state,
        \\assert(fixture:status()=='fulfilled' and fixture:value().exit_code==0)
        \\fixture_path=fixture:value().stdout
        \\-- The GUI JSON bridge is outside this headless harness; check exact
        \\-- document bytes here while exercising real paged host I/O.
        \\host_api.json_decode=function(text) assert(text=='{"tabs":[]}'..string.rep(' ',20000)); return {tabs={}} end
        \\workspace=require('hollow.workspace')
        \\loaded=workspace.load_host(h,fixture_path)
        \\limited=workspace.load_host(h,fixture_path,{max_bytes=10})
    );
    try until(state, "DONE=loaded:status()~='pending' and limited:status()~='pending'");
    try run(state,
        \\assert(loaded:status()=='fulfilled',loaded:error() and loaded:error().message)
        \\assert(loaded:value()._path==fixture_path and type(loaded:value().tabs)=='table')
        \\assert(limited:error().code=='resource_exhausted')
        \\removed=h:exec({argv={'/bin/rm','--',fixture_path}})
    );
    try until(state, "DONE=removed:status()~='pending'");
    try run(state,
        \\assert(removed:status()=='fulfilled' and removed:value().exit_code==0)
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
        \\nf=nh:exec({argv={'/bin/sh','-c',[[p=$(mktemp /tmp/hollow-workspace-local-XXXXXX) || exit 1; printf '%s' '{"tabs":[]}' > "$p"; head -c 20000 /dev/zero | tr '\000' ' ' >> "$p"; printf '%s' "$p"]]}})
    );
    try until(state, "DONE=nf:status()~='pending'");
    try run(state,
        \\assert(nf:status()=='fulfilled' and nf:value().exit_code==0)
        \\nl=workspace.load_host(nh,nf:value().stdout)
    );
    try until(state, "DONE=nl:status()~='pending'");
    try run(state,
        \\assert(nl:status()=='fulfilled',nl:error() and nl:error().message)
        \\nr=nh:exec({argv={'/bin/rm','--',nf:value().stdout}})
    );
    try until(state, "DONE=nr:status()~='pending'");
    try run(state,
        \\assert(nr:status()=='fulfilled' and nr:value().exit_code==0)
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
    inline for (.{ "PODMAN", "DOCKER" }) |engine| {
        const container = std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_" ++ engine ++ "_CONTAINER") catch null;
        defer if (container) |bytes| std.testing.allocator.free(bytes);
        if (container) |name| {
            c.lua_pushlstring(state, name.ptr, name.len);
            c.lua_setfield(state, c.LUA_GLOBALSINDEX, "TEST_CONTAINER");
            const uid = try std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_" ++ engine ++ "_UID");
            defer std.testing.allocator.free(uid);
            c.lua_pushlstring(state, uid.ptr, uid.len);
            c.lua_setfield(state, c.LUA_GLOBALSINDEX, "CONTAINER_UID");
            const engine_name = if (comptime std.mem.eql(u8, engine, "PODMAN")) "podman" else "docker";
            c.lua_pushstring(state, engine_name);
            c.lua_setfield(state, c.LUA_GLOBALSINDEX, "CONTAINER_ENGINE");
            inline for (.{ "EXE", "CONTEXT" }) |suffix| {
                const bytes = std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_" ++ engine ++ "_" ++ suffix) catch null;
                defer if (bytes) |value| std.testing.allocator.free(value);
                if (bytes) |value| c.lua_pushlstring(state, value.ptr, value.len) else c.lua_pushnil(state);
                c.lua_setfield(state, c.LUA_GLOBALSINDEX, "CONTAINER_" ++ suffix);
            }
            // Linux-hosted integration runs can exercise the Windows-client-shaped
            // WSL nesting path with an explicit UNC artifact override.
            const via_distro = std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_" ++ engine ++ "_VIA_WSL_DISTRO") catch null;
            defer if (via_distro) |value| std.testing.allocator.free(value);
            if (via_distro) |value| c.lua_pushlstring(state, value.ptr, value.len) else c.lua_pushnil(state);
            c.lua_setfield(state, c.LUA_GLOBALSINDEX, "CONTAINER_VIA_WSL_DISTRO");
            const via_user = std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_" ++ engine ++ "_VIA_WSL_USER") catch null;
            defer if (via_user) |value| std.testing.allocator.free(value);
            if (via_user) |value| c.lua_pushlstring(state, value.ptr, value.len) else c.lua_pushstring(state, "");
            c.lua_setfield(state, c.LUA_GLOBALSINDEX, "CONTAINER_VIA_WSL_USER");
            const via_artifact = std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_" ++ engine ++ "_VIA_WSL_ARTIFACT") catch null;
            defer if (via_artifact) |value| std.testing.allocator.free(value);
            if (via_artifact) |value| c.lua_pushlstring(state, value.ptr, value.len) else c.lua_pushnil(state);
            c.lua_setfield(state, c.LUA_GLOBALSINDEX, "CONTAINER_VIA_WSL_ARTIFACT");
            try run(state,
                \\CONTAINER_ARTIFACT=assets:value().x86_64.path; CONTAINER_SHA256=assets:value().x86_64.sha256
                \\function boot_container(opts)
                \\  opts[CONTAINER_ENGINE]=CONTAINER_EXE; opts.context=CONTAINER_CONTEXT
                \\  if CONTAINER_VIA_WSL_DISTRO then opts.via={type='wsl',distro=CONTAINER_VIA_WSL_DISTRO,user=CONTAINER_VIA_WSL_USER~='' and CONTAINER_VIA_WSL_USER or nil} end
                \\  if CONTAINER_VIA_WSL_ARTIFACT and not opts.agent_path and not opts.artifacts then opts.artifacts={x86_64={path=CONTAINER_VIA_WSL_ARTIFACT,sha256=CONTAINER_SHA256}} end
                \\  return hollow.host[CONTAINER_ENGINE](opts)
                \\end
                \\bootstrap_opts={id=CONTAINER_ENGINE..'-production',container=TEST_CONTAINER}
                \\bootstrap=boot_container(bootstrap_opts)
            );
            try until(state, "DONE=bootstrap:status()~='pending'");
            try run(state,
                \\assert(bootstrap:status()=='fulfilled',bootstrap:error() and bootstrap:error().message)
                \\bh=bootstrap:value(); bi=bh:info(); bl=bh.fs.list('/tmp'); be=bh:exec({argv={'/bin/sh','-c','printf deployed'}}); bu=bh:exec({argv={'id','-u'}})
            );
            try until(state, "DONE=bi:status()~='pending' and bl:status()~='pending' and be:status()~='pending' and bu:status()~='pending'");
            try run(state,
                \\assert(bi:value().os=='linux' and be:value().stdout=='deployed' and bl:value().eof~=nil)
                \\assert(bu:value().stdout==CONTAINER_UID..'\n','container uid mismatch: '..string.format('%q',bu:value().stdout)..' ~= '..string.format('%q',CONTAINER_UID..'\n'))
                \\bc=bh:exec({argv={'/bin/sh','-c','exec sleep 30'}}); assert(bc:cancel())
            );
            try until(state, "DONE=bc:status()~='pending'");
            try run(state,
                \\assert(bc:error().code=='cancelled'); assert(bh:close())
                \\bootstrap_opts.id=CONTAINER_ENGINE..'-reuse'; reuse=boot_container(bootstrap_opts)
            );
            try until(state, "DONE=reuse:status()~='pending'");
            try run(state,
                \\assert(reuse:status()=='fulfilled',reuse:error() and reuse:error().message)
                \\rh=reuse:value(); assert(rh.generation~=bh.generation)
                \\corrupt=rh:exec({argv={'/bin/sh','-c','p="$HOME/.cache/hollow/agents/linux-x86_64/$1/hollow-agent"; printf broken > "$p.bad" && mv -f "$p.bad" "$p"','test',CONTAINER_SHA256}})
            );
            try until(state, "DONE=corrupt:status()~='pending'");
            try run(state,
                \\assert(corrupt:value().exit_code==0); assert(rh:close())
                \\bootstrap_opts.id=CONTAINER_ENGINE..'-repair'; repair=boot_container(bootstrap_opts)
            );
            try until(state, "DONE=repair:status()~='pending'");
            try run(state,
                \\assert(repair:status()=='fulfilled',repair:error() and repair:error().message)
                \\assert(repair:value():close())
                \\preinstalled=boot_container({id=CONTAINER_ENGINE..'-preinstalled',container=TEST_CONTAINER,agent_path=bi:value().home..'/.cache/hollow/agents/linux-x86_64/'..CONTAINER_SHA256..'/hollow-agent'})
            );
            try until(state, "DONE=preinstalled:status()~='pending'");
            try run(state,
                \\assert(preinstalled:status()=='fulfilled',preinstalled:error() and preinstalled:error().message)
                \\assert(preinstalled:value():close())
                \\wrong=boot_container({id=CONTAINER_ENGINE..'-bad-checksum',container=TEST_CONTAINER,artifacts={x86_64={path=CONTAINER_VIA_WSL_ARTIFACT or CONTAINER_ARTIFACT,sha256=string.rep('0',64)}}})
            );
            try until(state, "DONE=wrong:status()~='pending'");
            try run(state, "assert(wrong:error().code=='checksum_mismatch',wrong:error() and wrong:error().message)");
        }
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

test "native Windows public Lua WSL bootstrap discovers installed agent bundle" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const distro = std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_WSL_DISTRO") catch return error.SkipZigTest;
    defer std.testing.allocator.free(distro);
    const state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(state);
    c.luaL_openlibs(state);
    const require_jit = std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_REQUIRE_LUAJIT") catch null;
    defer if (require_jit) |bytes| std.testing.allocator.free(bytes);
    if (require_jit) |value| {
        if (!std.mem.eql(u8, value, "1")) return error.InvalidArgument;
        try run(state,
            \\assert(jit and jit.version and jit.status(), 'LuaJIT with enabled JIT required')
            \\jit.flush(); jit.opt.start('hotloop=1')
            \\local function sum(n) local s=0; for i=1,n do s=s+i end; return s end
            \\assert(sum(10000)==50005000)
            \\assert(require('jit.util').traceinfo(1), 'expected an actual compiled JIT trace')
            \\print('WINDOWS_LUA_ENGINE '..jit.version..' '..jit.arch..' '..jit.os..' compiled-trace')
            \\jit.opt.start('hotloop=56')
        );
    }
    var ctx: Context = .{ .allocator = std.testing.allocator };
    defer if (ctx.host_manager) |*manager| manager.deinit();
    c.lua_createtable(state, 0, 7);
    inline for (.{ "connect", "status", "close", "start", "poll", "cancel" }) |name| {
        c.lua_pushlightuserdata(state, &ctx);
        c.lua_pushcclosure(state, Callback(name).call, 1);
        c.lua_setfield(state, -2, "host_" ++ name);
    }
    c.lua_pushcclosure(state, nowMs, 0);
    c.lua_setfield(state, -2, "now_ms");
    c.lua_setfield(state, c.LUA_GLOBALSINDEX, "host_api");
    c.lua_pushlstring(state, distro.ptr, distro.len);
    c.lua_setfield(state, c.LUA_GLOBALSINDEX, "WSL_DISTRO");
    const root = try std.testing.environ.getAlloc(std.testing.allocator, "SystemRoot");
    defer std.testing.allocator.free(root);
    const launcher = try std.fs.path.join(std.testing.allocator, &.{ root, "System32", "wsl.exe" });
    defer std.testing.allocator.free(launcher);
    const fixture = std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_WSL_FIXTURE") catch null;
    defer if (fixture) |bytes| std.testing.allocator.free(bytes);
    const selected_launcher = fixture orelse launcher;
    c.lua_pushlstring(state, selected_launcher.ptr, selected_launcher.len);
    c.lua_setfield(state, c.LUA_GLOBALSINDEX, "WSL_EXE");
    if (fixture != null) {
        const home = try std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_WSL_HOME");
        defer std.testing.allocator.free(home);
        const prefix = "/tmp/hollow-wsl-home-";
        if (!std.mem.startsWith(u8, home, prefix) or home.len != prefix.len + 12) return error.InvalidFixtureHome;
        for (home[prefix.len..]) |byte| if (!std.ascii.isAlphanumeric(byte)) return error.InvalidFixtureHome;
        c.lua_pushlstring(state, home.ptr, home.len);
        c.lua_setfield(state, c.LUA_GLOBALSINDEX, "FIXTURE_HOME");
    }
    try run(state,
        \\package.path='src/lua/?.lua;'..package.path
        \\deferred={}; host_api.defer=function(fn) deferred[#deferred+1]=fn end
        \\hollow={async=require('hollow.async'),host=require('hollow.host')}
        \\local_p=hollow.host.local_host()
    );
    try until(state, "DONE=local_p:status()~='pending'");
    try run(state,
        \\assert(local_p:status()=='fulfilled',local_p:error() and local_p:error().message)
        \\native=local_p:value(); ni=native:info()
        \\assets=require('hollow.host.artifacts').discover(native)
    );
    try until(state, "DONE=assets:status()~='pending' and ni:status()~='pending'");
    const missing = std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_EXPECT_NO_BUNDLE") catch null;
    defer if (missing) |bytes| std.testing.allocator.free(bytes);
    if (missing) |value| {
        if (!std.mem.eql(u8, value, "1")) return error.InvalidArgument;
        try run(state,
            \\assert(ni:value().os=='windows')
            \\assert(assets:status()=='rejected' and assets:error().code=='agent_install_unavailable')
            \\print('WINDOWS_LUA_MISSING_BUNDLE_REJECTED '..ni:value().executable_dir)
        );
        return;
    }
    try run(state,
        \\assert(ni:value().os=='windows')
        \\assert(assets:status()=='fulfilled',assets:error() and assets:error().message)
        \\assert(assets:value().x86_64 and assets:value().aarch64)
        \\print('WINDOWS_LUA_BUNDLE '..assets:value().x86_64.path)
        \\-- No artifact, agent_dir or agent_path override: public default discovery.
        \\opts={id='windows-lua-wsl',distro=WSL_DISTRO,wsl=WSL_EXE}
        \\connected=hollow.host.wsl(opts)
    );
    try until(state, "DONE=connected:status()~='pending'");
    try run(state,
        \\assert(connected:status()=='fulfilled',connected:error() and connected:error().message)
        \\remote=connected:value(); info=remote:info()
        \\read=remote.fs.read('/etc/os-release',{limit=64}); list=remote.fs.list('/tmp',{limit=2})
        \\exec=remote:exec({argv={'/bin/sh','-c','printf "\\000%s" "$1"; printf err >&2; exit 7','probe'," a'\255\n"},cwd='/tmp'})
        \\cancel=remote:exec({argv={'/bin/sleep','30'}}); assert(cancel:cancel())
    );
    try until(state, "DONE=info:status()~='pending' and read:status()~='pending' and list:status()~='pending' and exec:status()~='pending' and cancel:status()~='pending'");
    try run(state,
        \\assert(info:value().os=='linux' and #read:value().bytes>0 and #list:value().entries<=2)
        \\assert(exec:value().exit_code==7 and exec:value().stdout=="\000 a'\255\n" and exec:value().stderr=='err')
        \\assert(cancel:error().code=='cancelled')
        \\assert(remote:close()); opts.id='windows-lua-wsl-reuse'; reused=hollow.host.wsl(opts)
    );
    try until(state, "DONE=reused:status()~='pending'");
    try run(state,
        \\assert(reused:status()=='fulfilled',reused:error() and reused:error().message)
        \\assert(reused:value().generation~=remote.generation); assert(reused:value():close())
        \\opts.id='windows-lua-wsl-preinstalled'
        \\opts.agent_path=info:value().home..'/.cache/hollow/agents/linux-'..info:value().arch..'/'..assets:value()[info:value().arch].sha256..'/hollow-agent'
        \\pre=hollow.host.wsl(opts)
    );
    try until(state, "DONE=pre:status()~='pending'");
    try run(state,
        \\assert(pre:status()=='fulfilled',pre:error() and pre:error().message); assert(pre:value():close())
    );
    if (fixture != null) {
        try run(state,
            \\assert(info:value().home==FIXTURE_HOME)
            \\-- Only modify the agent installed inside this validated owned HOME.
            \\repair_host=hollow.host.wsl(opts)
        );
        try until(state, "DONE=repair_host:status()~='pending'");
        try run(state,
            \\assert(repair_host:status()=='fulfilled',repair_host:error() and repair_host:error().message)
            \\owned=repair_host:value()
            \\corrupt=owned:exec({argv={'/bin/sh','-c','printf broken > "$1.bad" && mv -fT -- "$1.bad" "$1"','test',opts.agent_path}})
        );
        try until(state, "DONE=corrupt:status()~='pending'");
        try run(state,
            \\assert(corrupt:value().exit_code==0); assert(owned:close())
            \\opts.agent_path=nil; opts.id='windows-lua-wsl-repair'; repaired=hollow.host.wsl(opts)
        );
        try until(state, "DONE=repaired:status()~='pending'");
        try run(state,
            \\assert(repaired:status()=='fulfilled',repaired:error() and repaired:error().message)
            \\assert(repaired:value():close()); print('WINDOWS_LUA_COLD_REPAIR '..FIXTURE_HOME)
        );
    }
    try run(state,
        \\opts.agent_path=nil; opts.id='windows-lua-wsl-bad-checksum'
        \\opts.artifacts={[info:value().arch]={path=assets:value()[info:value().arch].path,sha256=string.rep('0',64)}}
        \\wrong=hollow.host.wsl(opts)
    );
    try until(state, "DONE=wrong:status()~='pending'");
    try run(state, "assert(wrong:status()=='rejected' and wrong:error().code=='checksum_mismatch',wrong:error() and wrong:error().message)");
    if (fixture != null) {
        try run(state,
            \\-- Rejection precedes best-effort cleanup. Keep runtime alive to drain it.
            \\opts.artifacts=nil; opts.agent_path=FIXTURE_HOME..'/.cache/hollow/agents/linux-'..info:value().arch..'/'..assets:value()[info:value().arch].sha256..'/hollow-agent'
            \\opts.id='windows-lua-wsl-cleanup'; cleanup_host=hollow.host.wsl(opts)
        );
        try until(state, "DONE=cleanup_host:status()~='pending'");
        try run(state,
            \\assert(cleanup_host:status()=='fulfilled',cleanup_host:error() and cleanup_host:error().message)
            \\zero_dir=FIXTURE_HOME..'/.cache/hollow/agents/linux-'..info:value().arch..'/'..string.rep('0',64)
            \\cleaned=cleanup_host:value():exec({argv={'/bin/sh','-c','dir=$1; n=0; while [ "$n" -lt 100 ]; do set -- "$dir"/.upload-*; [ -e "$1" ] || exit 0; n=$((n+1)); sleep 0.05; done; exit 1','test',zero_dir},timeout_ms=8000})
        );
        try until(state, "DONE=cleaned:status()~='pending'");
        try run(state,
            \\assert(cleaned:value().exit_code==0,'asynchronous upload cleanup did not finish')
            \\assert(cleanup_host:value():close()); print('WINDOWS_LUA_UPLOAD_CLEANUP '..FIXTURE_HOME)
        );
    }
    const teardown = std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_WSL_TEARDOWN") catch null;
    defer if (teardown) |bytes| std.testing.allocator.free(bytes);
    if (teardown) |value| {
        if (!std.mem.eql(u8, value, "1") or fixture == null) return error.InvalidArgument;
        try run(state,
            \\opts.id='windows-lua-wsl-teardown'; teardown_host=hollow.host.wsl(opts)
        );
        try until(state, "DONE=teardown_host:status()~='pending'");
        try run(state,
            \\assert(teardown_host:status()=='fulfilled',teardown_host:error() and teardown_host:error().message)
            \\th=teardown_host:value()
            \\teardown_pending=th:exec({argv={'/bin/sh','-c','printf "%s\\n" "$$" > "$HOME/teardown.pid"; exec /bin/sleep 120'},timeout_ms=150000})
            \\witness=th:exec({argv={'/bin/sh','-c','set -eu; n=0; while [ ! -s "$HOME/teardown.pid" ]; do n=$((n+1)); [ "$n" -lt 100 ] || exit 1; sleep 0.02; done; pid=$(cat "$HOME/teardown.pid"); cat "/proc/$pid/stat"; guardian=$(cut -d " " -f 4 "/proc/$pid/stat"); printf "WINDOWS_LUA_GUARDIAN_BEFORE "; cat "/proc/$guardian/stat"; agent=$(cut -d " " -f 4 "/proc/$guardian/stat"); printf "WINDOWS_LUA_AGENT_BEFORE "; cat "/proc/$agent/stat"'},timeout_ms=5000})
        );
        try until(state, "DONE=witness:status()~='pending'");
        try run(state,
            \\assert(witness:status()=='fulfilled' and witness:value().exit_code==0)
            \\assert(teardown_pending:status()=='pending')
            \\print('WINDOWS_LUA_TEARDOWN_BEFORE '..witness:value().stdout)
        );
        const started = std.Io.Clock.awake.now(std.testing.io).toNanoseconds();
        ctx.host_manager.?.deinit();
        ctx.host_manager = null;
        const elapsed = std.Io.Clock.awake.now(std.testing.io).toNanoseconds() - started;
        std.debug.print("WINDOWS_LUA_MANAGER_DEINIT_NS {d}\n", .{elapsed});
        try std.testing.expect(elapsed < 8000 * std.time.ns_per_ms);
        try until(state, "DONE=teardown_pending:status()~='pending'");
        try run(state,
            \\assert(teardown_pending:status()=='rejected' and teardown_pending:error().code=='session_gone')
            \\fresh_local=hollow.host.local_host()
        );
        try until(state, "DONE=fresh_local:status()~='pending'");
        try run(state,
            \\assert(fresh_local:status()=='fulfilled')
            \\fresh_info=fresh_local:value():info()
        );
        try until(state, "DONE=fresh_info:status()~='pending'");
        try run(state,
            \\assert(fresh_info:value().os=='windows')
            \\assert(teardown_pending:error().code=='session_gone')
            \\print('WINDOWS_LUA_TEARDOWN_STALE_REJECTED '..FIXTURE_HOME)
        );
    }
}
