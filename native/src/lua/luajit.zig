const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const platform = @import("../platform.zig");

pub const State = opaque {};

const LuaType = enum(c_int) {
    nil_type = 0,
    boolean = 1,
    lightuserdata = 2,
    number = 3,
    string = 4,
    table = 5,
};

const Api = struct {
    new_state: *const fn () callconv(.c) ?*State,
    close: *const fn (*State) callconv(.c) void,
    open_libs: *const fn (*State) callconv(.c) void,
    load_file: *const fn (*State, [*:0]const u8) callconv(.c) c_int,
    pcall: *const fn (*State, c_int, c_int, c_int) callconv(.c) c_int,
    get_top: *const fn (*State) callconv(.c) c_int,
    set_top: *const fn (*State, c_int) callconv(.c) void,
    create_table: *const fn (*State, c_int, c_int) callconv(.c) void,
    set_field: *const fn (*State, c_int, [*:0]const u8) callconv(.c) void,
    push_string: *const fn (*State, [*:0]const u8) callconv(.c) void,
    push_number: *const fn (*State, f64) callconv(.c) void,
    push_boolean: *const fn (*State, c_int) callconv(.c) void,
    push_nil: *const fn (*State) callconv(.c) void,
    push_light_userdata: *const fn (*State, ?*anyopaque) callconv(.c) void,
    push_cclosure: *const fn (*State, *const fn (*State) callconv(.c) c_int, c_int) callconv(.c) void,
    to_lstring: *const fn (*State, c_int, *usize) callconv(.c) ?[*]const u8,
    to_number: *const fn (*State, c_int) callconv(.c) f64,
    to_boolean: *const fn (*State, c_int) callconv(.c) c_int,
    to_userdata: *const fn (*State, c_int) callconv(.c) ?*anyopaque,
    value_type: *const fn (*State, c_int) callconv(.c) c_int,
    next: *const fn (*State, c_int) callconv(.c) c_int,
};

const BridgeContext = struct {
    api: Api,
    cfg: *config.Config,
};

var active_context: ?*BridgeContext = null;

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    lib: std.DynLib,
    state: *State,
    loaded_path: []u8,
    context: *BridgeContext,

    pub fn init(allocator: std.mem.Allocator, cfg: *config.Config) !Runtime {
        if (cfg.luajitLibrary()) |preferred| {
            if (loadFromCandidate(allocator, cfg, preferred)) |runtime| {
                return runtime;
            } else |err| switch (err) {
                error.LibraryOpenFailed => {},
                else => return err,
            }
        }

        for (platform.luajitLibraryCandidates()) |candidate| {
            return loadFromCandidate(allocator, cfg, candidate) catch |err| switch (err) {
                error.LibraryOpenFailed => continue,
                else => return err,
            };
        }

        return error.LibraryOpenFailed;
    }

    fn loadFromCandidate(allocator: std.mem.Allocator, cfg: *config.Config, candidate: []const u8) !Runtime {
        if (loadFromPath(allocator, cfg, candidate)) |runtime| {
            return runtime;
        } else |err| switch (err) {
            error.LibraryOpenFailed => {},
            else => return err,
        }

        if (platform.resolveRelativeToExe(allocator, candidate)) |maybe_resolved| {
            if (maybe_resolved) |resolved| {
                defer allocator.free(resolved);
                return loadFromPath(allocator, cfg, resolved);
            }
        } else |_| {}

        return error.LibraryOpenFailed;
    }

    fn loadFromPath(allocator: std.mem.Allocator, cfg: *config.Config, path: []const u8) !Runtime {
        var lib = std.DynLib.open(path) catch return error.LibraryOpenFailed;
        errdefer lib.close();

        const api = Api{
            .new_state = lookup(&lib, *const fn () callconv(.c) ?*State, "luaL_newstate"),
            .close = lookup(&lib, *const fn (*State) callconv(.c) void, "lua_close"),
            .open_libs = lookup(&lib, *const fn (*State) callconv(.c) void, "luaL_openlibs"),
            .load_file = lookup(&lib, *const fn (*State, [*:0]const u8) callconv(.c) c_int, "luaL_loadfile"),
            .pcall = lookup(&lib, *const fn (*State, c_int, c_int, c_int) callconv(.c) c_int, "lua_pcall"),
            .get_top = lookup(&lib, *const fn (*State) callconv(.c) c_int, "lua_gettop"),
            .set_top = lookup(&lib, *const fn (*State, c_int) callconv(.c) void, "lua_settop"),
            .create_table = lookup(&lib, *const fn (*State, c_int, c_int) callconv(.c) void, "lua_createtable"),
            .set_field = lookup(&lib, *const fn (*State, c_int, [*:0]const u8) callconv(.c) void, "lua_setfield"),
            .push_string = lookup(&lib, *const fn (*State, [*:0]const u8) callconv(.c) void, "lua_pushstring"),
            .push_number = lookup(&lib, *const fn (*State, f64) callconv(.c) void, "lua_pushnumber"),
            .push_boolean = lookup(&lib, *const fn (*State, c_int) callconv(.c) void, "lua_pushboolean"),
            .push_nil = lookup(&lib, *const fn (*State) callconv(.c) void, "lua_pushnil"),
            .push_light_userdata = lookup(&lib, *const fn (*State, ?*anyopaque) callconv(.c) void, "lua_pushlightuserdata"),
            .push_cclosure = lookup(&lib, *const fn (*State, *const fn (*State) callconv(.c) c_int, c_int) callconv(.c) void, "lua_pushcclosure"),
            .to_lstring = lookup(&lib, *const fn (*State, c_int, *usize) callconv(.c) ?[*]const u8, "lua_tolstring"),
            .to_number = lookup(&lib, *const fn (*State, c_int) callconv(.c) f64, "lua_tonumber"),
            .to_boolean = lookup(&lib, *const fn (*State, c_int) callconv(.c) c_int, "lua_toboolean"),
            .to_userdata = lookup(&lib, *const fn (*State, c_int) callconv(.c) ?*anyopaque, "lua_touserdata"),
            .value_type = lookup(&lib, *const fn (*State, c_int) callconv(.c) c_int, "lua_type"),
            .next = lookup(&lib, *const fn (*State, c_int) callconv(.c) c_int, "lua_next"),
        };

        const state = api.new_state() orelse return error.LuaStateInitFailed;
        api.open_libs(state);

        const ctx = try allocator.create(BridgeContext);
        errdefer allocator.destroy(ctx);
        ctx.* = .{ .api = api, .cfg = cfg };

        var runtime = Runtime{
            .allocator = allocator,
            .lib = lib,
            .state = state,
            .loaded_path = try allocator.dupe(u8, path),
            .context = ctx,
        };

        active_context = ctx;

        try runtime.exposeHollowTable();
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        self.context.api.close(self.state);
        active_context = null;
        self.allocator.destroy(self.context);
        self.allocator.free(self.loaded_path);
        self.lib.close();
    }

    pub fn runFile(self: *Runtime, path: []const u8) !void {
        const zpath = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(zpath);

        if (self.context.api.load_file(self.state, zpath) != 0) {
            return error.LuaLoadFailed;
        }

        if (self.context.api.pcall(self.state, 0, 0, 0) != 0) {
            return error.LuaRuntimeFailed;
        }
    }

    fn exposeHollowTable(self: *Runtime) !void {
        const api = self.context.api;

        api.create_table(self.state, 0, 6);

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_set_config, 1);
        api.set_field(self.state, -2, "set_config");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_log, 1);
        api.set_field(self.state, -2, "log");

        api.create_table(self.state, 0, 5);
        try pushOwnedString(self.allocator, api, self.state, platform.name());
        api.set_field(self.state, -2, "os");
        api.push_boolean(self.state, if (platform.isWindows()) 1 else 0);
        api.set_field(self.state, -2, "is_windows");
        api.push_boolean(self.state, if (platform.isLinux()) 1 else 0);
        api.set_field(self.state, -2, "is_linux");
        api.push_boolean(self.state, if (platform.isMacos()) 1 else 0);
        api.set_field(self.state, -2, "is_macos");
        try pushOwnedString(self.allocator, api, self.state, platform.defaultShell());
        api.set_field(self.state, -2, "default_shell");
        api.set_field(self.state, -2, "platform");

        api.set_field(self.state, -10002, "hollow");
    }
};

fn lookup(lib: *std.DynLib, comptime T: type, symbol: [:0]const u8) T {
    return lib.lookup(T, symbol) orelse @panic("missing required luajit symbol");
}

fn pushOwnedString(allocator: std.mem.Allocator, api: Api, state: *State, value: []const u8) !void {
    const zvalue = try allocator.dupeZ(u8, value);
    defer allocator.free(zvalue);
    api.push_string(state, zvalue);
}

fn bridgeContext(state: *State) *BridgeContext {
    _ = state;
    return active_context orelse @panic("missing bridge context");
}

fn upvalueIndex(i: c_int) c_int {
    return -10002 - i;
}

fn l_log(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const argc = api.get_top(state);
    if (argc < 1) {
        std.log.info("lua: <empty>", .{});
        return 0;
    }

    const value_type: LuaType = @enumFromInt(api.value_type(state, 1));
    switch (value_type) {
        .string => {
            var len: usize = 0;
            const ptr = api.to_lstring(state, 1, &len) orelse return 0;
            std.log.info("lua: {s}", .{ptr[0..len]});
        },
        .number => std.log.info("lua: {d}", .{api.to_number(state, 1)}),
        .boolean => std.log.info("lua: {s}", .{if (api.to_boolean(state, 1) != 0) "true" else "false"}),
        else => std.log.info("lua: <type {d}>", .{@intFromEnum(value_type)}),
    }

    return 0;
}

fn l_set_config(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) != .table) {
        std.log.err("set_config expects a Lua table", .{});
        return 0;
    }

    api.push_nil(state);
    while (api.next(state, 1) != 0) {
        defer pop(api, state, 1);

        var key_len: usize = 0;
        const key_ptr = api.to_lstring(state, -2, &key_len) orelse continue;
        const key = key_ptr[0..key_len];
        const value_type: LuaType = @enumFromInt(api.value_type(state, -1));

        if (value_type == .string) {
            var value_len: usize = 0;
            const value_ptr = api.to_lstring(state, -1, &value_len) orelse continue;
            const value = value_ptr[0..value_len];
            applyString(ctx.cfg, key, value) catch |err| std.log.err("config string field {s} failed: {s}", .{ key, @errorName(err) });
            continue;
        }

        if (value_type == .number) {
            const value = api.to_number(state, -1);
            applyNumber(ctx.cfg, key, value) catch |err| std.log.err("config numeric field {s} failed: {s}", .{ key, @errorName(err) });
            continue;
        }

        if (value_type == .boolean) {
            const value = api.to_boolean(state, -1) != 0;
            applyBoolean(ctx.cfg, key, value) catch |err| std.log.err("config boolean field {s} failed: {s}", .{ key, @errorName(err) });
        }
    }

    return 0;
}

fn applyString(cfg: *config.Config, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "backend")) return cfg.setBackend(value);
    if (std.mem.eql(u8, key, "shell")) return cfg.setShell(value);
    if (std.mem.eql(u8, key, "ghostty_library")) return cfg.setGhosttyLibrary(value);
    if (std.mem.eql(u8, key, "luajit_library")) return cfg.setLuajitLibrary(value);
    if (std.mem.eql(u8, key, "window_title")) return cfg.setWindowTitle(value);
    if (std.mem.eql(u8, key, "lib_dir")) return cfg.setLibDir(value);
}

fn applyNumber(cfg: *config.Config, key: []const u8, value: f64) !void {
    if (std.mem.eql(u8, key, "font_size")) {
        cfg.font_size = @floatCast(value);
        return;
    }

    if (std.mem.eql(u8, key, "window_width")) {
        cfg.window_width = try asInt(u32, value);
        return;
    }

    if (std.mem.eql(u8, key, "window_height")) {
        cfg.window_height = try asInt(u32, value);
        return;
    }

    if (std.mem.eql(u8, key, "cols")) {
        cfg.cols = try asInt(u16, value);
        return;
    }

    if (std.mem.eql(u8, key, "rows")) {
        cfg.rows = try asInt(u16, value);
        return;
    }

    if (std.mem.eql(u8, key, "scrollback")) {
        cfg.scrollback = try asInt(u32, value);
        return;
    }
}

fn applyBoolean(cfg: *config.Config, key: []const u8, value: bool) !void {
    _ = cfg;
    _ = key;
    _ = value;
}

fn asInt(comptime T: type, value: f64) !T {
    if (value < 0 or value > @as(f64, @floatFromInt(std.math.maxInt(T)))) {
        return error.OutOfRange;
    }
    return @intFromFloat(value);
}

fn pop(api: Api, state: *State, count: c_int) void {
    api.set_top(state, -count - 1);
}
