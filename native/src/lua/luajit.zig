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
    function = 6,
    userdata = 7,
    thread = 8,
    _,
};

const Api = struct {
    new_state: *const fn () callconv(.c) ?*State,
    close: *const fn (*State) callconv(.c) void,
    open_libs: *const fn (*State) callconv(.c) void,
    load_file: *const fn (*State, [*:0]const u8) callconv(.c) c_int,
    load_buffer: *const fn (*State, [*]const u8, usize, [*:0]const u8) callconv(.c) c_int,
    pcall: *const fn (*State, c_int, c_int, c_int) callconv(.c) c_int,
    get_top: *const fn (*State) callconv(.c) c_int,
    set_top: *const fn (*State, c_int) callconv(.c) void,
    create_table: *const fn (*State, c_int, c_int) callconv(.c) void,
    set_field: *const fn (*State, c_int, [*:0]const u8) callconv(.c) void,
    get_field: *const fn (*State, c_int, [*:0]const u8) callconv(.c) void,
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
    ref: *const fn (*State, c_int) callconv(.c) c_int,
    rawgeti: *const fn (*State, c_int, c_int) callconv(.c) void,
    unref: *const fn (*State, c_int, c_int) callconv(.c) void,
};

/// Callbacks from Lua into the App layer.
/// Using function pointers keeps luajit.zig free of App imports.
pub const AppCallbacks = struct {
    app: *anyopaque,
    split_pane: *const fn (app: *anyopaque, direction: []const u8, ratio: f32) void,
    new_tab: *const fn (app: *anyopaque) void,
    close_tab: *const fn (app: *anyopaque) void,
    close_pane: *const fn (app: *anyopaque) void,
    next_tab: *const fn (app: *anyopaque) void,
    prev_tab: *const fn (app: *anyopaque) void,
    focus_pane: *const fn (app: *anyopaque, direction: []const u8) void,
    resize_pane: *const fn (app: *anyopaque, direction: []const u8, delta: f32) void,
    switch_tab: *const fn (app: *anyopaque, index: usize) void,
    set_tab_title: *const fn (app: *anyopaque, title: []const u8) void,
    get_tab_count: *const fn (app: *anyopaque) usize,
    get_active_tab_index: *const fn (app: *anyopaque) usize,
};

const BridgeContext = struct {
    api: Api,
    cfg: *config.Config,
    app_callbacks: ?AppCallbacks = null,
    /// LuaJIT registry ref for the on_key handler function (LUA_NOREF = -1).
    on_key_ref: c_int = -1,
};

var active_context: ?*BridgeContext = null;

// LUA_REGISTRYINDEX / LUA_GLOBALSINDEX constants (match the LuaJIT 2.1 ABI)
const LUA_REGISTRYINDEX: c_int = -10000;
const LUA_ENVIRONINDEX: c_int = -10001;
const LUA_GLOBALSINDEX: c_int = -10002;
const LUA_NOREF: c_int = -1;

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
            .load_buffer = lookup(&lib, *const fn (*State, [*]const u8, usize, [*:0]const u8) callconv(.c) c_int, "luaL_loadbuffer"),
            .pcall = lookup(&lib, *const fn (*State, c_int, c_int, c_int) callconv(.c) c_int, "lua_pcall"),
            .get_top = lookup(&lib, *const fn (*State) callconv(.c) c_int, "lua_gettop"),
            .set_top = lookup(&lib, *const fn (*State, c_int) callconv(.c) void, "lua_settop"),
            .create_table = lookup(&lib, *const fn (*State, c_int, c_int) callconv(.c) void, "lua_createtable"),
            .set_field = lookup(&lib, *const fn (*State, c_int, [*:0]const u8) callconv(.c) void, "lua_setfield"),
            .get_field = lookup(&lib, *const fn (*State, c_int, [*:0]const u8) callconv(.c) void, "lua_getfield"),
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
            .ref = lookup(&lib, *const fn (*State, c_int) callconv(.c) c_int, "luaL_ref"),
            .rawgeti = lookup(&lib, *const fn (*State, c_int, c_int) callconv(.c) void, "lua_rawgeti"),
            .unref = lookup(&lib, *const fn (*State, c_int, c_int) callconv(.c) void, "luaL_unref"),
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

    pub fn runString(self: *Runtime, code: [:0]const u8) !void {
        if (self.context.api.load_buffer(self.state, code.ptr, code.len, "core.lua") != 0) {
            logLuaError(self.context.api, self.state, "load_string");
            return error.LuaLoadFailed;
        }
        if (self.context.api.pcall(self.state, 0, 0, 0) != 0) {
            logLuaError(self.context.api, self.state, "pcall");
            return error.LuaRuntimeFailed;
        }
    }

    pub fn runFile(self: *Runtime, path: []const u8) !void {
        const zpath = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(zpath);

        if (self.context.api.load_file(self.state, zpath) != 0) {
            logLuaError(self.context.api, self.state, "load_file");
            return error.LuaLoadFailed;
        }

        if (self.context.api.pcall(self.state, 0, 0, 0) != 0) {
            logLuaError(self.context.api, self.state, "pcall");
            return error.LuaRuntimeFailed;
        }
    }

    /// Register app-level action callbacks so Lua can call split_pane etc.
    pub fn registerAppCallbacks(self: *Runtime, callbacks: AppCallbacks) void {
        self.context.app_callbacks = callbacks;
    }

    /// Fire the Lua on_key handler (if registered).
    /// Returns true if the key was consumed by Lua (handler returned true).
    pub fn fireOnKey(self: *Runtime, key: []const u8, mods: u32) bool {
        const ctx = self.context;
        const api = ctx.api;
        const ref = ctx.on_key_ref;
        if (ref == LUA_NOREF) return false;

        // Push the handler function from the registry.
        api.rawgeti(self.state, LUA_REGISTRYINDEX, ref);
        const fn_type: LuaType = @enumFromInt(api.value_type(self.state, -1));
        if (fn_type == .function) {
            const zkey = std.heap.page_allocator.dupeZ(u8, key) catch {
                pop(api, self.state, 1);
                return false;
            };
            defer std.heap.page_allocator.free(zkey);
            api.push_string(self.state, zkey);
            api.push_number(self.state, @floatFromInt(mods));
            const rc = api.pcall(self.state, 2, 1, 0);
            if (rc != 0) {
                std.log.err("fireOnKey: pcall failed rc={d}", .{rc});
                pop(api, self.state, 1);
                return false;
            }
            const consumed = api.to_boolean(self.state, -1) != 0;
            pop(api, self.state, 1);
            return consumed;
        }
        pop(api, self.state, 1);
        return false;
    }

    fn exposeHollowTable(self: *Runtime) !void {
        const api = self.context.api;

        api.create_table(self.state, 0, 8);

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_set_config, 1);
        api.set_field(self.state, -2, "set_config");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_log, 1);
        api.set_field(self.state, -2, "log");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_split_pane, 1);
        api.set_field(self.state, -2, "split_pane");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_new_tab, 1);
        api.set_field(self.state, -2, "new_tab");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_close_tab, 1);
        api.set_field(self.state, -2, "close_tab");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_close_pane, 1);
        api.set_field(self.state, -2, "close_pane");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_next_tab, 1);
        api.set_field(self.state, -2, "next_tab");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_prev_tab, 1);
        api.set_field(self.state, -2, "prev_tab");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_focus_pane, 1);
        api.set_field(self.state, -2, "focus_pane");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_resize_pane, 1);
        api.set_field(self.state, -2, "resize_pane");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_on_key, 1);
        api.set_field(self.state, -2, "on_key");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_switch_tab, 1);
        api.set_field(self.state, -2, "switch_tab");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_set_tab_title, 1);
        api.set_field(self.state, -2, "set_tab_title");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_tab_count, 1);
        api.set_field(self.state, -2, "get_tab_count");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_active_tab_index, 1);
        api.set_field(self.state, -2, "get_active_tab_index");

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

        api.set_field(self.state, LUA_GLOBALSINDEX, "hollow");
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

    if (std.mem.eql(u8, key, "font_embolden")) {
        cfg.font_embolden = @floatCast(value);
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

fn logLuaError(api: Api, state: *State, ctx_label: []const u8) void {
    var len: usize = 0;
    if (api.to_lstring(state, -1, &len)) |ptr| {
        std.log.err("lua {s} error: {s}", .{ ctx_label, ptr[0..len] });
    } else {
        std.log.err("lua {s} error: (no message)", .{ctx_label});
    }
    pop(api, state, 1);
}

fn pop(api: Api, state: *State, count: c_int) void {
    api.set_top(state, -count - 1);
}

/// hollow.split_pane(direction)
/// direction: "vertical" (left/right) or "horizontal" (top/bottom)
fn l_new_tab(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    if (ctx.app_callbacks) |cbs| cbs.new_tab(cbs.app);
    return 0;
}

fn l_close_tab(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    if (ctx.app_callbacks) |cbs| cbs.close_tab(cbs.app);
    return 0;
}

fn l_close_pane(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    if (ctx.app_callbacks) |cbs| cbs.close_pane(cbs.app);
    return 0;
}

fn l_next_tab(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    if (ctx.app_callbacks) |cbs| cbs.next_tab(cbs.app);
    return 0;
}

fn l_prev_tab(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    if (ctx.app_callbacks) |cbs| cbs.prev_tab(cbs.app);
    return 0;
}

fn l_split_pane(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;

    const cbs = ctx.app_callbacks orelse {
        std.log.warn("lua: split_pane called before app callbacks registered", .{});
        return 0;
    };

    var dir_len: usize = 0;
    const dir_ptr = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .string)
        api.to_lstring(state, 1, &dir_len)
    else
        null;

    const direction: []const u8 = if (dir_ptr) |p| p[0..dir_len] else "vertical";

    // Optional second argument: ratio in (0, 1). Defaults to 0.5.
    const ratio: f32 = if (@as(LuaType, @enumFromInt(api.value_type(state, 2))) == .number)
        @as(f32, @floatCast(api.to_number(state, 2)))
    else
        0.5;

    cbs.split_pane(cbs.app, direction, ratio);
    return 0;
}

/// hollow.focus_pane(direction)
/// direction: "left", "right", "up", or "down"
fn l_focus_pane(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;

    const cbs = ctx.app_callbacks orelse return 0;

    var dir_len: usize = 0;
    const dir_ptr = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .string)
        api.to_lstring(state, 1, &dir_len)
    else
        null;

    const direction: []const u8 = if (dir_ptr) |p| p[0..dir_len] else "right";
    cbs.focus_pane(cbs.app, direction);
    return 0;
}

/// hollow.resize_pane(direction, delta)
/// direction: "vertical" or "horizontal" (which split axis to adjust)
/// delta: fraction to move divider, e.g. 0.05 grows the first child by 5%
fn l_resize_pane(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;

    const cbs = ctx.app_callbacks orelse return 0;

    var dir_len: usize = 0;
    const dir_ptr = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .string)
        api.to_lstring(state, 1, &dir_len)
    else
        null;

    const direction: []const u8 = if (dir_ptr) |p| p[0..dir_len] else "vertical";

    const delta: f32 = if (@as(LuaType, @enumFromInt(api.value_type(state, 2))) == .number)
        @as(f32, @floatCast(api.to_number(state, 2)))
    else
        0.05;

    cbs.resize_pane(cbs.app, direction, delta);
    return 0;
}

/// hollow.switch_tab(index)  — 0-based index
fn l_switch_tab(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse return 0;
    const idx: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    cbs.switch_tab(cbs.app, idx);
    return 0;
}

/// hollow.set_tab_title(title)  — override the active tab's title string
fn l_set_tab_title(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse return 0;
    var len: usize = 0;
    const ptr = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .string)
        api.to_lstring(state, 1, &len)
    else
        null;
    const title: []const u8 = if (ptr) |p| p[0..len] else "";
    cbs.set_tab_title(cbs.app, title);
    return 0;
}

/// hollow.get_tab_count() → number  — number of open tabs (0-based count)
fn l_get_tab_count(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_number(state, 0);
        return 1;
    };
    const count = cbs.get_tab_count(cbs.app);
    api.push_number(state, @floatFromInt(count));
    return 1;
}

/// hollow.get_active_tab_index() → number  — 0-based index of active tab
fn l_get_active_tab_index(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_number(state, 0);
        return 1;
    };
    const idx = cbs.get_active_tab_index(cbs.app);
    api.push_number(state, @floatFromInt(idx));
    return 1;
}

/// hollow.on_key(fn(key, mods) -> bool)
/// Registers a Lua function that is called for every key event before the
/// terminal sees it. Return true to consume the key.
fn l_on_key(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;

    const arg_type: LuaType = @enumFromInt(api.value_type(state, 1));

    // nil argument → unregister handler
    if (arg_type == .nil_type) {
        if (ctx.on_key_ref != LUA_NOREF) {
            api.unref(state, LUA_REGISTRYINDEX, ctx.on_key_ref);
            ctx.on_key_ref = LUA_NOREF;
        }
        return 0;
    }

    if (arg_type != .function) {
        std.log.err("lua: on_key expects a function, got type {d}", .{@intFromEnum(arg_type)});
        return 0;
    }

    // Unregister old handler if any.
    if (ctx.on_key_ref != LUA_NOREF) {
        api.unref(state, LUA_REGISTRYINDEX, ctx.on_key_ref);
    }

    // The function is at stack index 1 (top). luaL_ref pops it and returns a ref.
    ctx.on_key_ref = api.ref(state, LUA_REGISTRYINDEX);
    std.log.info("lua: on_key handler registered", .{});
    return 0;
}
