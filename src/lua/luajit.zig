const std = @import("std");
const config = @import("../config.zig");
const platform = @import("../platform.zig");
const ghostty = @import("../term/ghostty.zig");
const bar = @import("../ui/bar.zig");

extern fn luaL_newstate() callconv(.c) ?*State;
extern fn lua_close(*State) callconv(.c) void;
extern fn luaL_openlibs(*State) callconv(.c) void;
extern fn luaL_loadfile(*State, [*:0]const u8) callconv(.c) c_int;
extern fn luaL_loadbuffer(*State, [*]const u8, usize, [*:0]const u8) callconv(.c) c_int;
extern fn lua_pcall(*State, c_int, c_int, c_int) callconv(.c) c_int;
extern fn lua_gettop(*State) callconv(.c) c_int;
extern fn lua_settop(*State, c_int) callconv(.c) void;
extern fn lua_createtable(*State, c_int, c_int) callconv(.c) void;
extern fn lua_setfield(*State, c_int, [*:0]const u8) callconv(.c) void;
extern fn lua_getfield(*State, c_int, [*:0]const u8) callconv(.c) void;
extern fn lua_pushstring(*State, [*:0]const u8) callconv(.c) void;
extern fn lua_pushnumber(*State, f64) callconv(.c) void;
extern fn lua_pushboolean(*State, c_int) callconv(.c) void;
extern fn lua_pushnil(*State) callconv(.c) void;
extern fn lua_pushlightuserdata(*State, ?*anyopaque) callconv(.c) void;
extern fn lua_pushvalue(*State, c_int) callconv(.c) void;
extern fn lua_pushcclosure(*State, *const fn (*State) callconv(.c) c_int, c_int) callconv(.c) void;
extern fn lua_pushinteger(*State, isize) callconv(.c) void;
extern fn lua_rawseti(*State, c_int, c_int) callconv(.c) void;
extern fn lua_settable(*State, c_int) callconv(.c) void;
extern fn lua_gettable(*State, c_int) callconv(.c) void;
extern fn lua_tolstring(*State, c_int, *usize) callconv(.c) ?[*]const u8;
extern fn lua_tonumber(*State, c_int) callconv(.c) f64;
extern fn lua_toboolean(*State, c_int) callconv(.c) c_int;
extern fn lua_touserdata(*State, c_int) callconv(.c) ?*anyopaque;
extern fn lua_type(*State, c_int) callconv(.c) c_int;
extern fn lua_next(*State, c_int) callconv(.c) c_int;
extern fn luaL_ref(*State, c_int) callconv(.c) c_int;
extern fn lua_rawgeti(*State, c_int, c_int) callconv(.c) void;
extern fn luaL_unref(*State, c_int, c_int) callconv(.c) void;
extern fn luaL_error(*State, [*:0]const u8, ...) callconv(.c) c_int;

pub const State = opaque {};

pub const LuaType = enum(c_int) {
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

pub const Api = struct {
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
    push_value: *const fn (*State, c_int) callconv(.c) void,
    push_cclosure: *const fn (*State, *const fn (*State) callconv(.c) c_int, c_int) callconv(.c) void,
    push_integer: *const fn (*State, isize) callconv(.c) void,
    rawseti: *const fn (*State, c_int, c_int) callconv(.c) void,
    set_table: *const fn (*State, c_int) callconv(.c) void,
    get_table: *const fn (*State, c_int) callconv(.c) void,
    to_lstring: *const fn (*State, c_int, *usize) callconv(.c) ?[*]const u8,
    to_number: *const fn (*State, c_int) callconv(.c) f64,
    to_boolean: *const fn (*State, c_int) callconv(.c) c_int,
    to_userdata: *const fn (*State, c_int) callconv(.c) ?*anyopaque,
    value_type: *const fn (*State, c_int) callconv(.c) c_int,
    next: *const fn (*State, c_int) callconv(.c) c_int,
    ref: *const fn (*State, c_int) callconv(.c) c_int,
    rawgeti: *const fn (*State, c_int, c_int) callconv(.c) void,
    unref: *const fn (*State, c_int, c_int) callconv(.c) void,
    raise_error: *const fn (*State, [*:0]const u8, ...) callconv(.c) c_int,
};

const LuaModule = struct {
    name: []const u8,
    source: [:0]const u8,
};

const embedded_lua_modules = [_]LuaModule{
    .{ .name = "hollow.state", .source = @embedFile("hollow/state.lua") },
    .{ .name = "hollow.util", .source = @embedFile("hollow/util.lua") },
    .{ .name = "hollow.utils", .source = @embedFile("hollow/utils.lua") },
    .{ .name = "hollow.term", .source = @embedFile("hollow/term.lua") },
    .{ .name = "hollow.config", .source = @embedFile("hollow/config.lua") },
    .{ .name = "hollow.events", .source = @embedFile("hollow/events.lua") },
    .{ .name = "hollow.actions", .source = @embedFile("hollow/actions.lua") },
    .{ .name = "hollow.defaults", .source = @embedFile("hollow/defaults.lua") },
    .{ .name = "hollow.htp", .source = @embedFile("hollow/htp.lua") },
    .{ .name = "hollow.keymap", .source = @embedFile("hollow/keymap.lua") },
    .{ .name = "hollow.ui.shared", .source = @embedFile("hollow/ui/shared.lua") },
    .{ .name = "hollow.ui.primitives", .source = @embedFile("hollow/ui/primitives.lua") },
    .{ .name = "hollow.ui.widgets.core", .source = @embedFile("hollow/ui/widgets/core.lua") },
    .{ .name = "hollow.ui.widgets.bars", .source = @embedFile("hollow/ui/widgets/bars.lua") },
    .{ .name = "hollow.ui.widgets.overlay", .source = @embedFile("hollow/ui/widgets/overlay.lua") },
    .{ .name = "hollow.ui.widgets.notify", .source = @embedFile("hollow/ui/widgets/notify.lua") },
    .{ .name = "hollow.ui.widgets.input", .source = @embedFile("hollow/ui/widgets/input.lua") },
    .{ .name = "hollow.ui.widgets.select", .source = @embedFile("hollow/ui/widgets/select.lua") },
    .{ .name = "hollow.ui.runtime", .source = @embedFile("hollow/ui/runtime.lua") },
    .{ .name = "hollow.ui", .source = @embedFile("hollow/ui.lua") },
};

/// Callbacks from Lua into the App layer.
/// Using function pointers keeps luajit.zig free of App imports.
pub const AppCallbacks = struct {
    app: *anyopaque,
    split_pane: *const fn (app: *anyopaque, direction: []const u8, ratio: f32, domain_name: ?[]const u8, cwd: ?[]const u8, command: ?[]const u8, command_mode: []const u8, close_on_exit: bool, floating: bool, fullscreen: bool, x: f32, y: f32, width: f32, height: f32, has_bounds: bool) void,
    toggle_pane_maximized: *const fn (app: *anyopaque, pane_id: usize, show_background: bool) void,
    set_pane_floating: *const fn (app: *anyopaque, pane_id: usize, floating: bool) void,
    set_floating_pane_bounds: *const fn (app: *anyopaque, pane_id: usize, x: f32, y: f32, width: f32, height: f32) void,
    move_pane: *const fn (app: *anyopaque, pane_id: usize, direction: []const u8, amount: f32) void,
    new_tab: *const fn (app: *anyopaque, domain_name: ?[]const u8) void,
    close_tab: *const fn (app: *anyopaque) void,
    close_pane: *const fn (app: *anyopaque) void,
    next_tab: *const fn (app: *anyopaque) void,
    prev_tab: *const fn (app: *anyopaque) void,
    new_workspace: *const fn (app: *anyopaque) void,
    next_workspace: *const fn (app: *anyopaque) void,
    prev_workspace: *const fn (app: *anyopaque) void,
    switch_workspace: *const fn (app: *anyopaque, index: usize) void,
    focus_pane: *const fn (app: *anyopaque, direction: []const u8) void,
    resize_pane: *const fn (app: *anyopaque, direction: []const u8, delta: f32) void,
    switch_tab: *const fn (app: *anyopaque, index: usize) void,
    set_workspace_name: *const fn (app: *anyopaque, title: []const u8) void,
    set_tab_title: *const fn (app: *anyopaque, title: []const u8) void,
    set_tab_title_by_id: *const fn (app: *anyopaque, tab_id: usize, title: []const u8) bool,
    reload_config: *const fn (app: *anyopaque) bool,
    get_tab_count: *const fn (app: *anyopaque) usize,
    get_active_tab_index: *const fn (app: *anyopaque) usize,
    get_current_tab_id: *const fn (app: *anyopaque) usize,
    get_current_pane_id: *const fn (app: *anyopaque) usize,
    get_tab_id_at: *const fn (app: *anyopaque, index: usize) usize,
    get_tab_pane_count: *const fn (app: *anyopaque, tab_id: usize) usize,
    get_tab_pane_id_at: *const fn (app: *anyopaque, tab_id: usize, index: usize) usize,
    get_tab_active_pane_id: *const fn (app: *anyopaque, tab_id: usize) usize,
    get_tab_index_by_id: *const fn (app: *anyopaque, tab_id: usize) usize,
    get_workspace_count: *const fn (app: *anyopaque) usize,
    get_active_workspace_index: *const fn (app: *anyopaque) usize,
    get_workspace_name: *const fn (app: *anyopaque, index: usize, out_buf: []u8) []const u8,
    get_pane_pid: *const fn (app: *anyopaque, pane_id: usize) usize,
    get_pane_title: *const fn (app: *anyopaque, pane_id: usize, out_buf: []u8) []const u8,
    get_pane_cwd: *const fn (app: *anyopaque, pane_id: usize, out_buf: []u8) []const u8,
    get_pane_domain: *const fn (app: *anyopaque, pane_id: usize, out_buf: []u8) []const u8,
    get_pane_rows: *const fn (app: *anyopaque, pane_id: usize) usize,
    get_pane_cols: *const fn (app: *anyopaque, pane_id: usize) usize,
    get_pane_x: *const fn (app: *anyopaque, pane_id: usize) usize,
    get_pane_y: *const fn (app: *anyopaque, pane_id: usize) usize,
    get_pane_width: *const fn (app: *anyopaque, pane_id: usize) usize,
    get_pane_height: *const fn (app: *anyopaque, pane_id: usize) usize,
    pane_is_floating: *const fn (app: *anyopaque, pane_id: usize) bool,
    pane_is_maximized: *const fn (app: *anyopaque, pane_id: usize) bool,
    get_window_width: *const fn (app: *anyopaque) usize,
    get_window_height: *const fn (app: *anyopaque) usize,
    now_ms: *const fn (app: *anyopaque) i64,
    pane_is_focused: *const fn (app: *anyopaque, pane_id: usize) bool,
    pane_exists: *const fn (app: *anyopaque, pane_id: usize) bool,
    switch_tab_by_id: *const fn (app: *anyopaque, tab_id: usize) bool,
    close_tab_by_id: *const fn (app: *anyopaque, tab_id: usize) bool,
    send_text_to_pane: *const fn (app: *anyopaque, pane_id: usize, text: []const u8) bool,
    is_leader_active: *const fn (app: *anyopaque) bool,
    copy_selection: *const fn (app: *anyopaque) void,
    paste_clipboard: *const fn (app: *anyopaque) void,
    scroll_active: *const fn (app: *anyopaque, delta: isize) void,
    scroll_active_page: *const fn (app: *anyopaque, pages: isize) void,
    scroll_active_top: *const fn (app: *anyopaque) void,
    scroll_active_bottom: *const fn (app: *anyopaque) void,
};

const BridgeContext = struct {
    api: Api,
    cfg: *config.Config,
    app_callbacks: ?AppCallbacks = null,
    pending_workspace_name: ?[]u8 = null,
    /// LuaJIT registry ref for the on_key handler function (LUA_NOREF = -1).
    on_key_ref: c_int = -1,
    /// Lua callback for top bar title override.
    top_bar_ref: c_int = -1,
    workspace_title_ref: c_int = -1,
    status_ref: c_int = -1,
    gui_ready_ref: c_int = -1,
    gui_ready_fired: bool = false,
};

var active_context: ?*BridgeContext = null;

// LUA_REGISTRYINDEX / LUA_GLOBALSINDEX constants (match the LuaJIT 2.1 ABI)
const LUA_REGISTRYINDEX: c_int = -10000;
const LUA_ENVIRONINDEX: c_int = -10001;
const LUA_GLOBALSINDEX: c_int = -10002;
const LUA_NOREF: c_int = -1;

fn luaValueToJson(allocator: std.mem.Allocator, api: Api, state: *State, idx: c_int) anyerror!std.json.Value {
    const abs_idx = absoluteIndex(api, state, idx);
    const value_type: LuaType = @enumFromInt(api.value_type(state, abs_idx));
    switch (value_type) {
        .nil_type => return .null,
        .boolean => return .{ .bool = api.to_boolean(state, abs_idx) != 0 },
        .number => {
            const num = api.to_number(state, abs_idx);
            if (std.math.floor(num) == num and num >= @as(f64, @floatFromInt(std.math.minInt(i64))) and num <= @as(f64, @floatFromInt(std.math.maxInt(i64)))) {
                return .{ .integer = @intFromFloat(num) };
            }
            return .{ .float = num };
        },
        .string => {
            var len: usize = 0;
            const ptr = api.to_lstring(state, abs_idx, &len) orelse return .null;
            return .{ .string = try allocator.dupe(u8, ptr[0..len]) };
        },
        .table => return try luaTableToJson(allocator, api, state, abs_idx),
        else => return error.UnsupportedLuaType,
    }
}

fn luaTableToJson(allocator: std.mem.Allocator, api: Api, state: *State, table_idx: c_int) anyerror!std.json.Value {
    const abs_idx = absoluteIndex(api, state, table_idx);
    var max_numeric_key: usize = 0;
    var numeric_key_count: usize = 0;
    var has_non_numeric = false;

    api.push_nil(state);
    while (api.next(state, abs_idx) != 0) {
        defer pop(api, state, 1);
        const key_type: LuaType = @enumFromInt(api.value_type(state, -2));
        switch (key_type) {
            .number => {
                const n = api.to_number(state, -2);
                if (std.math.floor(n) != n or n < 1) {
                    has_non_numeric = true;
                } else {
                    const k: usize = @intFromFloat(n);
                    numeric_key_count += 1;
                    if (k > max_numeric_key) max_numeric_key = k;
                }
            },
            .string => has_non_numeric = true,
            else => return error.UnsupportedLuaTableKey,
        }
    }

    if (!has_non_numeric and numeric_key_count > 0 and max_numeric_key == numeric_key_count) {
        var array = std.json.Array.init(allocator);
        errdefer {
            for (array.items) |item| deinitJsonValue(allocator, item);
            array.deinit();
        }
        var index: usize = 1;
        while (index <= max_numeric_key) : (index += 1) {
            api.push_number(state, @floatFromInt(index));
            api.get_table(state, abs_idx);
            defer pop(api, state, 1);
            try array.append(try luaValueToJson(allocator, api, state, -1));
        }
        return .{ .array = array };
    }

    var object = std.json.ObjectMap.init(allocator);
    errdefer {
        var it = object.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            deinitJsonValue(allocator, entry.value_ptr.*);
        }
        object.deinit();
    }

    api.push_nil(state);
    while (api.next(state, abs_idx) != 0) {
        defer pop(api, state, 1);
        const key_type: LuaType = @enumFromInt(api.value_type(state, -2));
        const key = switch (key_type) {
            .string => blk: {
                var len: usize = 0;
                const ptr = api.to_lstring(state, -2, &len) orelse return error.UnsupportedLuaTableKey;
                break :blk try allocator.dupe(u8, ptr[0..len]);
            },
            .number => blk: {
                const num = api.to_number(state, -2);
                break :blk try std.fmt.allocPrint(allocator, "{d}", .{@as(i64, @intFromFloat(num))});
            },
            else => return error.UnsupportedLuaTableKey,
        };
        errdefer allocator.free(key);
        try object.put(key, try luaValueToJson(allocator, api, state, -1));
    }

    return .{ .object = object };
}

fn pushJsonValue(allocator: std.mem.Allocator, api: Api, state: *State, value: std.json.Value) !void {
    switch (value) {
        .null => api.push_nil(state),
        .bool => |v| api.push_boolean(state, if (v) 1 else 0),
        .integer => |v| api.push_number(state, @floatFromInt(v)),
        .float => |v| api.push_number(state, v),
        .number_string => |v| try pushOwnedString(allocator, api, state, v),
        .string => |v| try pushOwnedString(allocator, api, state, v),
        .array => |arr| {
            api.create_table(state, @intCast(arr.items.len), 0);
            for (arr.items, 0..) |item, idx| {
                try pushJsonValue(allocator, api, state, item);
                api.rawseti(state, -2, @intCast(idx + 1));
            }
        },
        .object => |obj| {
            api.create_table(state, 0, @intCast(obj.count()));
            var it = obj.iterator();
            while (it.next()) |entry| {
                try pushJsonValue(allocator, api, state, entry.value_ptr.*);
                const zkey = try allocator.dupeZ(u8, entry.key_ptr.*);
                defer allocator.free(zkey);
                api.set_field(state, -2, zkey);
            }
        },
    }
}

fn luaUpvalueIndex(i: c_int) c_int {
    return LUA_GLOBALSINDEX - i;
}

pub const BuiltInPayload = union(enum) {
    none,
    tab_id: usize,
    pane_id: usize,
    pane_layout_changed: struct {
        pane_id: usize,
    },
    pane_title_changed: struct {
        pane_id: usize,
        old_title: []const u8,
        new_title: []const u8,
    },
    pane_cwd_changed: struct {
        pane_id: usize,
        old_cwd: []const u8,
        new_cwd: []const u8,
    },
    window_size: struct {
        rows: usize,
        cols: usize,
        width: usize,
        height: usize,
    },
    key_unhandled: struct {
        key: []const u8,
        mods: u32,
    },
    topbar_node: struct {
        id: []const u8,
    },
    bottombar_node: struct {
        id: []const u8,
    },
};

pub const SidebarLayoutSide = enum {
    left,
    right,
};

pub const SidebarLayout = struct {
    side: SidebarLayoutSide = .left,
    width_cols: usize = 0,
    reserve: bool = false,
};

pub const BottomBarLayout = struct {
    height_px: u32 = 0,
};

fn deinitJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .number_string => |v| allocator.free(v),
        .string => |v| allocator.free(v),
        .array => |arr| {
            for (arr.items) |item| deinitJsonValue(allocator, item);
            var owned = arr;
            owned.deinit();
        },
        .object => |obj| {
            var owned = obj;
            var it = owned.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitJsonValue(allocator, entry.value_ptr.*);
            }
            owned.deinit();
        },
        else => {},
    }
}

pub const HtpQueryResult = struct {
    success: bool,
    value: ?std.json.Value = null,
    error_message: ?[]u8 = null,

    pub fn deinit(self: HtpQueryResult, allocator: std.mem.Allocator) void {
        if (self.value) |value| deinitJsonValue(allocator, value);
        if (self.error_message) |message| allocator.free(message);
    }
};

const HtpDispatchResult = struct {
    success: bool,
    error_message: ?[]u8 = null,

    pub fn deinit(self: HtpDispatchResult, allocator: std.mem.Allocator) void {
        if (self.error_message) |message| allocator.free(message);
    }
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    state: *State,
    context: *BridgeContext,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, cfg: *config.Config) !Runtime {
        const api = Api{
            .new_state = luaL_newstate,
            .close = lua_close,
            .open_libs = luaL_openlibs,
            .load_file = luaL_loadfile,
            .load_buffer = luaL_loadbuffer,
            .pcall = lua_pcall,
            .get_top = lua_gettop,
            .set_top = lua_settop,
            .create_table = lua_createtable,
            .set_field = lua_setfield,
            .get_field = lua_getfield,
            .push_string = lua_pushstring,
            .push_number = lua_pushnumber,
            .push_boolean = lua_pushboolean,
            .push_nil = lua_pushnil,
            .push_light_userdata = lua_pushlightuserdata,
            .push_value = lua_pushvalue,
            .push_cclosure = lua_pushcclosure,
            .push_integer = lua_pushinteger,
            .rawseti = lua_rawseti,
            .set_table = lua_settable,
            .get_table = lua_gettable,
            .to_lstring = lua_tolstring,
            .to_number = lua_tonumber,
            .to_boolean = lua_toboolean,
            .to_userdata = lua_touserdata,
            .value_type = lua_type,
            .next = lua_next,
            .ref = luaL_ref,
            .rawgeti = lua_rawgeti,
            .unref = luaL_unref,
            .raise_error = luaL_error,
        };

        const state = api.new_state() orelse return error.LuaStateInitFailed;
        api.open_libs(state);

        const ctx = try allocator.create(BridgeContext);
        errdefer allocator.destroy(ctx);
        ctx.* = .{ .api = api, .cfg = cfg };

        var runtime = Runtime{
            .allocator = allocator,
            .state = state,
            .context = ctx,
        };

        active_context = ctx;

        try runtime.exposeHollowTable();
        try runtime.preloadLuaModules();
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        if (self.context.pending_workspace_name) |name| self.allocator.free(name);
        if (self.context.on_key_ref != LUA_NOREF) self.context.api.unref(self.state, LUA_REGISTRYINDEX, self.context.on_key_ref);
        if (self.context.top_bar_ref != LUA_NOREF) self.context.api.unref(self.state, LUA_REGISTRYINDEX, self.context.top_bar_ref);
        if (self.context.workspace_title_ref != LUA_NOREF) self.context.api.unref(self.state, LUA_REGISTRYINDEX, self.context.workspace_title_ref);
        if (self.context.status_ref != LUA_NOREF) self.context.api.unref(self.state, LUA_REGISTRYINDEX, self.context.status_ref);
        if (self.context.gui_ready_ref != LUA_NOREF) self.context.api.unref(self.state, LUA_REGISTRYINDEX, self.context.gui_ready_ref);
        self.context.api.close(self.state);
        active_context = null;
        self.allocator.destroy(self.context);
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
        self.mutex.lock();
        defer self.mutex.unlock();
        self.context.app_callbacks = callbacks;
        if (self.context.pending_workspace_name) |name| {
            callbacks.set_workspace_name(callbacks.app, name);
            self.allocator.free(name);
            self.context.pending_workspace_name = null;
        }
    }

    pub fn fireGuiReady(self: *Runtime) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ctx = self.context;
        if (ctx.gui_ready_fired) return;
        ctx.gui_ready_fired = true;

        const ref = ctx.gui_ready_ref;
        if (ref == LUA_NOREF) return;

        const api = ctx.api;
        api.rawgeti(self.state, LUA_REGISTRYINDEX, ref);
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .function) {
            pop(api, self.state, 1);
            return;
        }

        if (api.pcall(self.state, 0, 0, 0) != 0) {
            logLuaError(api, self.state, "on_gui_ready");
        }
    }

    /// Fire the Lua on_key handler (if registered).
    /// Returns true if the key was consumed by Lua (handler returned true).
    pub fn fireOnKey(self: *Runtime, key: []const u8, mods: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
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

    pub fn isLeaderActive(self: *Runtime) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ctx = self.context;
        const api = ctx.api;

        api.get_field(self.state, LUA_GLOBALSINDEX, "hollow");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .table) {
            pop(api, self.state, 1);
            return false;
        }

        api.get_field(self.state, -1, "keymap");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .table) {
            pop(api, self.state, 2);
            return false;
        }

        api.get_field(self.state, -1, "is_leader_active");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .function) {
            pop(api, self.state, 3);
            return false;
        }

        if (api.pcall(self.state, 0, 1, 0) != 0) {
            logLuaError(api, self.state, "keymap.is_leader_active");
            pop(api, self.state, 2);
            return false;
        }

        const active = api.to_boolean(self.state, -1) != 0;
        pop(api, self.state, 3);
        return active;
    }

    pub fn emitBuiltInEvent(self: *Runtime, name: []const u8, payload: BuiltInPayload) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const api = self.context.api;
        api.get_field(self.state, LUA_GLOBALSINDEX, "hollow");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .table) {
            pop(api, self.state, 1);
            return;
        }

        api.get_field(self.state, -1, "_emit_builtin_event");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .function) {
            pop(api, self.state, 2);
            return;
        }

        pushOwnedString(self.allocator, api, self.state, name) catch {
            pop(api, self.state, 3);
            return;
        };
        pushBuiltInPayload(self.allocator, api, self.state, payload) catch {
            pop(api, self.state, 4);
            return;
        };

        if (api.pcall(self.state, 2, 0, 0) != 0) {
            logLuaError(api, self.state, "emit_builtin_event");
            pop(api, self.state, 1);
            return;
        }

        pop(api, self.state, 1);
    }

    pub fn withLockedState(self: *Runtime, comptime T: type, callback: fn (*Runtime) T) T {
        self.mutex.lock();
        defer self.mutex.unlock();
        return callback(self);
    }

    pub fn dispatchHtpEvent(self: *Runtime, pane_id: usize, channel: []const u8, payload: ?std.json.Value) !HtpDispatchResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const api = self.context.api;
        api.get_field(self.state, LUA_GLOBALSINDEX, "hollow");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .table) {
            pop(api, self.state, 1);
            return .{ .success = false, .error_message = try self.allocator.dupe(u8, "missing hollow global") };
        }
        api.get_field(self.state, -1, "htp");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .table) {
            pop(api, self.state, 2);
            return .{ .success = false, .error_message = try self.allocator.dupe(u8, "missing hollow.htp namespace") };
        }
        api.get_field(self.state, -1, "_handle_emit");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .function) {
            pop(api, self.state, 3);
            return .{ .success = false, .error_message = try self.allocator.dupe(u8, "missing htp emit handler") };
        }

        try pushOwnedString(self.allocator, api, self.state, channel);
        if (payload) |value| {
            try pushJsonValue(self.allocator, api, self.state, value);
        } else {
            api.push_nil(self.state);
        }
        api.push_number(self.state, @floatFromInt(pane_id));

        if (api.pcall(self.state, 3, 2, 0) != 0) {
            const message = luaErrorToOwnedString(self.allocator, api, self.state);
            pop(api, self.state, 2);
            return .{ .success = false, .error_message = message };
        }

        const success = api.to_boolean(self.state, -2) != 0;
        const error_message = if (!success) luaValueToOwnedString(self.allocator, api, self.state, -1) else null;
        pop(api, self.state, 4);
        return .{ .success = success, .error_message = error_message };
    }

    pub fn dispatchHtpQuery(self: *Runtime, pane_id: usize, channel: []const u8, params: ?std.json.Value) !HtpQueryResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const api = self.context.api;
        api.get_field(self.state, LUA_GLOBALSINDEX, "hollow");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .table) {
            pop(api, self.state, 1);
            return .{ .success = false, .error_message = try self.allocator.dupe(u8, "missing hollow global") };
        }
        api.get_field(self.state, -1, "htp");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .table) {
            pop(api, self.state, 2);
            return .{ .success = false, .error_message = try self.allocator.dupe(u8, "missing hollow.htp namespace") };
        }
        api.get_field(self.state, -1, "_handle_query");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .function) {
            pop(api, self.state, 3);
            return .{ .success = false, .error_message = try self.allocator.dupe(u8, "missing htp query handler") };
        }

        try pushOwnedString(self.allocator, api, self.state, channel);
        if (params) |value| {
            try pushJsonValue(self.allocator, api, self.state, value);
        } else {
            api.push_nil(self.state);
        }
        api.push_number(self.state, @floatFromInt(pane_id));

        if (api.pcall(self.state, 3, 2, 0) != 0) {
            const message = luaErrorToOwnedString(self.allocator, api, self.state);
            pop(api, self.state, 2);
            return .{ .success = false, .error_message = message };
        }

        const success = api.to_boolean(self.state, -2) != 0;
        const result = if (success)
            HtpQueryResult{ .success = true, .value = try luaValueToJson(self.allocator, api, self.state, -1) }
        else
            HtpQueryResult{ .success = false, .error_message = luaValueToOwnedString(self.allocator, api, self.state, -1) };
        pop(api, self.state, 4);
        return result;
    }

    pub fn resolveTopBarTitle(self: *Runtime, index: usize, is_active: bool, is_hovered: bool, hover_close: bool, fallback: []const u8, out_buf: []u8) bar.Segment {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ctx = self.context;
        const api = ctx.api;
        const ref = ctx.top_bar_ref;
        var segment = bar.Segment{ .text = fallback };
        if (ref == LUA_NOREF) return segment;

        api.rawgeti(self.state, LUA_REGISTRYINDEX, ref);
        const fn_type: LuaType = @enumFromInt(api.value_type(self.state, -1));
        if (fn_type != .function) {
            pop(api, self.state, 1);
            return segment;
        }

        api.push_number(self.state, @floatFromInt(index));
        api.push_boolean(self.state, if (is_active) 1 else 0);
        api.push_boolean(self.state, if (is_hovered) 1 else 0);
        api.push_boolean(self.state, if (hover_close) 1 else 0);

        const zfallback = std.heap.page_allocator.dupeZ(u8, fallback) catch {
            pop(api, self.state, 1);
            return segment;
        };
        defer std.heap.page_allocator.free(zfallback);
        api.push_string(self.state, zfallback);

        const rc = api.pcall(self.state, 5, 1, 0);
        if (rc != 0) {
            std.log.err("resolveTopBarTitle: pcall failed rc={d}", .{rc});
            pop(api, self.state, 1);
            return segment;
        }

        segment = parseLabelResult(api, self.state, out_buf, fallback);
        pop(api, self.state, 1);
        return segment;
    }

    pub fn resolveWorkspaceTitle(self: *Runtime, index: usize, is_active: bool, active_workspace_index: usize, workspace_count: usize, fallback: []const u8, out_buf: []u8) bar.Segment {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ctx = self.context;
        const api = ctx.api;
        const ref = ctx.workspace_title_ref;
        var segment = bar.Segment{ .text = fallback };
        if (ref == LUA_NOREF) return segment;

        api.rawgeti(self.state, LUA_REGISTRYINDEX, ref);
        const fn_type: LuaType = @enumFromInt(api.value_type(self.state, -1));
        if (fn_type != .function) {
            pop(api, self.state, 1);
            return segment;
        }

        api.push_number(self.state, @floatFromInt(index));
        api.push_boolean(self.state, if (is_active) 1 else 0);
        api.push_number(self.state, @floatFromInt(active_workspace_index));
        api.push_number(self.state, @floatFromInt(workspace_count));

        const zfallback = std.heap.page_allocator.dupeZ(u8, fallback) catch {
            pop(api, self.state, 1);
            return segment;
        };
        defer std.heap.page_allocator.free(zfallback);
        api.push_string(self.state, zfallback);

        const rc = api.pcall(self.state, 5, 1, 0);
        if (rc != 0) {
            std.log.err("resolveWorkspaceTitle: pcall failed rc={d}", .{rc});
            pop(api, self.state, 1);
            return segment;
        }

        segment = parseLabelResult(api, self.state, out_buf, fallback);
        pop(api, self.state, 1);
        return segment;
    }

    pub fn hasTopBarFormatter(self: *Runtime) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.context.top_bar_ref != LUA_NOREF;
    }

    pub fn hasWorkspaceTitleFormatter(self: *Runtime) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.context.workspace_title_ref != LUA_NOREF;
    }

    pub fn resolveTopBarStatus(self: *Runtime, side: bar.Side, seg_buf: []bar.Segment, text_buf: []u8, active_tab_index: usize, tab_count: usize) []bar.Segment {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ctx = self.context;
        const api = ctx.api;
        const ref = ctx.status_ref;
        if (ref == LUA_NOREF or seg_buf.len == 0 or text_buf.len == 0) return seg_buf[0..0];

        api.rawgeti(self.state, LUA_REGISTRYINDEX, ref);
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .function) {
            pop(api, self.state, 1);
            return seg_buf[0..0];
        }

        const side_text = switch (side) {
            .left => "left",
            .right => "right",
        };
        const zside = std.heap.page_allocator.dupeZ(u8, side_text) catch {
            pop(api, self.state, 1);
            return seg_buf[0..0];
        };
        defer std.heap.page_allocator.free(zside);

        api.push_string(self.state, zside);
        api.push_integer(self.state, @intCast(active_tab_index));
        api.push_integer(self.state, @intCast(tab_count));

        if (api.pcall(self.state, 3, 1, 0) != 0) {
            logLuaError(api, self.state, "on_status");
            return seg_buf[0..0];
        }

        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .table) {
            pop(api, self.state, 1);
            return seg_buf[0..0];
        }

        var seg_count: usize = 0;
        var text_used: usize = 0;
        api.push_nil(self.state);
        while (api.next(self.state, -2) != 0) {
            defer pop(api, self.state, 1);
            if (seg_count >= seg_buf.len) break;
            if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .table) continue;

            var seg = bar.Segment{ .text = "" };

            api.get_field(self.state, -1, "text");
            if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) == .string) {
                var len: usize = 0;
                if (api.to_lstring(self.state, -1, &len)) |ptr| {
                    if (text_used + len <= text_buf.len) {
                        @memcpy(text_buf[text_used .. text_used + len], ptr[0..len]);
                        seg.text = text_buf[text_used .. text_used + len];
                        text_used += len;
                    }
                }
            }
            pop(api, self.state, 1);

            api.get_field(self.state, -1, "bold");
            seg.bold = api.to_boolean(self.state, -1) != 0;
            pop(api, self.state, 1);

            seg.fg = parseColorField(api, self.state, -1, "fg");
            seg.bg = parseColorField(api, self.state, -1, "bg");

            if (seg.text.len > 0) {
                seg_buf[seg_count] = seg;
                seg_count += 1;
            }
        }

        pop(api, self.state, 1);
        return seg_buf[0..seg_count];
    }

    pub fn resolveSidebarLayout(self: *Runtime) ?SidebarLayout {
        self.mutex.lock();
        defer self.mutex.unlock();

        const api = self.context.api;
        api.get_field(self.state, LUA_GLOBALSINDEX, "hollow");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .table) {
            pop(api, self.state, 1);
            return null;
        }

        api.get_field(self.state, -1, "ui");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .table) {
            pop(api, self.state, 2);
            return null;
        }

        api.get_field(self.state, -1, "_sidebar_state");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .function) {
            pop(api, self.state, 3);
            return null;
        }

        if (api.pcall(self.state, 0, 1, 0) != 0) {
            logLuaError(api, self.state, "sidebar_state");
            pop(api, self.state, 3);
            return null;
        }

        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .table) {
            pop(api, self.state, 3);
            return null;
        }

        const sidebar_idx = absoluteIndex(api, self.state, -1);
        var layout = SidebarLayout{};

        api.get_field(self.state, sidebar_idx, "width");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) == .number) {
            const width = api.to_number(self.state, -1);
            if (width > 0) layout.width_cols = @as(usize, @intFromFloat(width));
        }
        pop(api, self.state, 1);

        api.get_field(self.state, sidebar_idx, "reserve");
        layout.reserve = api.to_boolean(self.state, -1) != 0;
        pop(api, self.state, 1);

        api.get_field(self.state, sidebar_idx, "side");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) == .string) {
            var side_len: usize = 0;
            if (api.to_lstring(self.state, -1, &side_len)) |ptr| {
                const side = ptr[0..side_len];
                if (std.mem.eql(u8, side, "right")) layout.side = .right;
            }
        }
        pop(api, self.state, 1);

        pop(api, self.state, 3);
        if (layout.width_cols == 0) return null;
        return layout;
    }

    pub fn resolveBottomBarLayout(self: *Runtime) ?BottomBarLayout {
        self.mutex.lock();
        defer self.mutex.unlock();

        const api = self.context.api;
        api.get_field(self.state, LUA_GLOBALSINDEX, "hollow");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .table) {
            pop(api, self.state, 1);
            return null;
        }

        api.get_field(self.state, -1, "ui");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .table) {
            pop(api, self.state, 2);
            return null;
        }

        api.get_field(self.state, -1, "_bottombar_layout");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .function) {
            pop(api, self.state, 3);
            return null;
        }

        if (api.pcall(self.state, 0, 1, 0) != 0) {
            logLuaError(api, self.state, "bottombar_layout");
            pop(api, self.state, 3);
            return null;
        }

        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .table) {
            pop(api, self.state, 3);
            return null;
        }

        const layout_idx = absoluteIndex(api, self.state, -1);
        var layout = BottomBarLayout{};

        api.get_field(self.state, layout_idx, "height");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) == .number) {
            const height = api.to_number(self.state, -1);
            if (height > 0) layout.height_px = asInt(u32, height) catch 0;
        }
        pop(api, self.state, 1);

        pop(api, self.state, 3);
        if (layout.height_px == 0) return null;
        return layout;
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
        api.push_cclosure(self.state, l_strftime, 1);
        api.set_field(self.state, -2, "strftime");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_split_pane, 1);
        api.set_field(self.state, -2, "split_pane");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_toggle_pane_maximized, 1);
        api.set_field(self.state, -2, "toggle_pane_maximized");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_set_pane_floating, 1);
        api.set_field(self.state, -2, "set_pane_floating");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_set_floating_pane_bounds, 1);
        api.set_field(self.state, -2, "set_floating_pane_bounds");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_move_pane, 1);
        api.set_field(self.state, -2, "move_pane");

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
        api.push_cclosure(self.state, l_new_workspace, 1);
        api.set_field(self.state, -2, "new_workspace");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_next_workspace, 1);
        api.set_field(self.state, -2, "next_workspace");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_prev_workspace, 1);
        api.set_field(self.state, -2, "prev_workspace");

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
        api.push_cclosure(self.state, l_on_top_bar, 1);
        api.set_field(self.state, -2, "on_top_bar");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_on_workspace_title, 1);
        api.set_field(self.state, -2, "on_workspace_title");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_on_status, 1);
        api.set_field(self.state, -2, "on_status");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_on_gui_ready, 1);
        api.set_field(self.state, -2, "on_gui_ready");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_is_leader_active, 1);
        api.set_field(self.state, -2, "is_leader_active");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_switch_tab, 1);
        api.set_field(self.state, -2, "switch_tab");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_switch_workspace, 1);
        api.set_field(self.state, -2, "switch_workspace");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_set_workspace_name, 1);
        api.set_field(self.state, -2, "set_workspace_name");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_workspace_name, 1);
        api.set_field(self.state, -2, "get_workspace_name");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_set_tab_title, 1);
        api.set_field(self.state, -2, "set_tab_title");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_tab_count, 1);
        api.set_field(self.state, -2, "get_tab_count");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_active_tab_index, 1);
        api.set_field(self.state, -2, "get_active_tab_index");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_workspace_count, 1);
        api.set_field(self.state, -2, "get_workspace_count");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_active_workspace_index, 1);
        api.set_field(self.state, -2, "get_active_workspace_index");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_system_metrics, 1);
        api.set_field(self.state, -2, "get_system_metrics");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_copy_selection, 1);
        api.set_field(self.state, -2, "copy_selection");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_paste_clipboard, 1);
        api.set_field(self.state, -2, "paste_clipboard");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_scroll_active, 1);
        api.set_field(self.state, -2, "scroll_active");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_scroll_active_page, 1);
        api.set_field(self.state, -2, "scroll_active_page");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_scroll_active_top, 1);
        api.set_field(self.state, -2, "scroll_active_top");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_scroll_active_bottom, 1);
        api.set_field(self.state, -2, "scroll_active_bottom");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_current_tab_id, 1);
        api.set_field(self.state, -2, "current_tab_id");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_current_pane_id, 1);
        api.set_field(self.state, -2, "current_pane_id");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_tab_id_at, 1);
        api.set_field(self.state, -2, "get_tab_id_at");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_tab_pane_count, 1);
        api.set_field(self.state, -2, "get_tab_pane_count");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_tab_pane_id_at, 1);
        api.set_field(self.state, -2, "get_tab_pane_id_at");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_tab_active_pane_id, 1);
        api.set_field(self.state, -2, "get_tab_active_pane_id");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_tab_index_by_id, 1);
        api.set_field(self.state, -2, "get_tab_index_by_id");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_pane_pid, 1);
        api.set_field(self.state, -2, "get_pane_pid");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_pane_title, 1);
        api.set_field(self.state, -2, "get_pane_title");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_pane_cwd, 1);
        api.set_field(self.state, -2, "get_pane_cwd");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_pane_rows, 1);
        api.set_field(self.state, -2, "get_pane_rows");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_pane_cols, 1);
        api.set_field(self.state, -2, "get_pane_cols");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_pane_x, 1);
        api.set_field(self.state, -2, "get_pane_x");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_pane_y, 1);
        api.set_field(self.state, -2, "get_pane_y");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_pane_width, 1);
        api.set_field(self.state, -2, "get_pane_width");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_pane_height, 1);
        api.set_field(self.state, -2, "get_pane_height");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_window_width, 1);
        api.set_field(self.state, -2, "get_window_width");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_window_height, 1);
        api.set_field(self.state, -2, "get_window_height");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_now_ms, 1);
        api.set_field(self.state, -2, "now_ms");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_pane_is_floating, 1);
        api.set_field(self.state, -2, "pane_is_floating");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_pane_is_maximized, 1);
        api.set_field(self.state, -2, "pane_is_maximized");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_pane_is_focused, 1);
        api.set_field(self.state, -2, "pane_is_focused");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_pane_exists, 1);
        api.set_field(self.state, -2, "pane_exists");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_switch_tab_by_id, 1);
        api.set_field(self.state, -2, "switch_tab_by_id");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_close_tab_by_id, 1);
        api.set_field(self.state, -2, "close_tab_by_id");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_set_tab_title_by_id, 1);
        api.set_field(self.state, -2, "set_tab_title_by_id");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_send_text_to_pane, 1);
        api.set_field(self.state, -2, "send_text_to_pane");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_get_pane_domain, 1);
        api.set_field(self.state, -2, "get_pane_domain");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_send_text, 1);
        api.set_field(self.state, -2, "send_text");

        api.push_light_userdata(self.state, self.context);
        api.push_cclosure(self.state, l_reload_config, 1);
        api.set_field(self.state, -2, "reload_config");

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

        api.set_field(self.state, LUA_GLOBALSINDEX, "host_api");
    }

    fn preloadLuaModules(self: *Runtime) !void {
        for (embedded_lua_modules) |module| {
            try self.preloadLuaModule(module.name, module.source);
        }
    }

    fn preloadLuaModule(self: *Runtime, name: []const u8, source: [:0]const u8) !void {
        const api = self.context.api;

        api.get_field(self.state, LUA_GLOBALSINDEX, "package");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .table) {
            pop(api, self.state, 1);
            return error.LuaRuntimeFailed;
        }

        api.get_field(self.state, -1, "preload");
        if (@as(LuaType, @enumFromInt(api.value_type(self.state, -1))) != .table) {
            pop(api, self.state, 2);
            return error.LuaRuntimeFailed;
        }

        try pushOwnedString(self.allocator, api, self.state, name);
        api.push_light_userdata(self.state, @ptrCast(@constCast(source.ptr)));
        api.push_integer(self.state, @as(isize, @intCast(source.len)));
        api.push_cclosure(self.state, l_preloaded_module_loader, 3);

        const zname = try self.allocator.dupeZ(u8, name);
        defer self.allocator.free(zname);
        api.set_field(self.state, -2, zname);
        pop(api, self.state, 2);
    }
};

fn l_preloaded_module_loader(state: *State) callconv(.c) c_int {
    const api = active_context.?.api;

    const module_name_index = luaUpvalueIndex(1);
    const source_ptr = api.to_userdata(state, luaUpvalueIndex(2)) orelse {
        _ = api.raise_error(state, "missing embedded module source");
        return 0;
    };
    const source_len = @as(usize, @intFromFloat(api.to_number(state, luaUpvalueIndex(3))));
    const source: [*]const u8 = @ptrCast(source_ptr);

    if (api.load_buffer(state, source, source_len, "embedded-module") != 0) {
        return api.raise_error(state, "failed to load embedded module");
    }

    api.push_value(state, 1);
    if (api.pcall(state, 1, 1, 0) != 0) {
        var module_name_len: usize = 0;
        const module_name_ptr = api.to_lstring(state, module_name_index, &module_name_len);
        const module_name = if (module_name_ptr) |ptr| ptr[0..module_name_len] else "(unknown)";
        std.log.err("lua preload error in {s}", .{module_name});
        return api.raise_error(state, "failed to run embedded module");
    }
    return 1;
}

fn pushOwnedString(allocator: std.mem.Allocator, api: Api, state: *State, value: []const u8) !void {
    const zvalue = try allocator.dupeZ(u8, value);
    defer allocator.free(zvalue);
    api.push_string(state, zvalue);
}

fn pushBuiltInPayload(allocator: std.mem.Allocator, api: Api, state: *State, payload: BuiltInPayload) !void {
    switch (payload) {
        .none => api.create_table(state, 0, 0),
        .tab_id => |tab_id| {
            api.create_table(state, 0, 1);
            api.push_number(state, @floatFromInt(tab_id));
            api.set_field(state, -2, "tab_id");
        },
        .pane_id => |pane_id| {
            api.create_table(state, 0, 1);
            api.push_number(state, @floatFromInt(pane_id));
            api.set_field(state, -2, "pane_id");
        },
        .pane_layout_changed => |value| {
            api.create_table(state, 0, 1);
            api.push_number(state, @floatFromInt(value.pane_id));
            api.set_field(state, -2, "pane_id");
        },
        .pane_title_changed => |value| {
            api.create_table(state, 0, 3);
            api.push_number(state, @floatFromInt(value.pane_id));
            api.set_field(state, -2, "pane_id");
            try pushOwnedString(allocator, api, state, value.old_title);
            api.set_field(state, -2, "old_title");
            try pushOwnedString(allocator, api, state, value.new_title);
            api.set_field(state, -2, "new_title");
        },
        .pane_cwd_changed => |value| {
            api.create_table(state, 0, 3);
            api.push_number(state, @floatFromInt(value.pane_id));
            api.set_field(state, -2, "pane_id");
            try pushOwnedString(allocator, api, state, value.old_cwd);
            api.set_field(state, -2, "old_cwd");
            try pushOwnedString(allocator, api, state, value.new_cwd);
            api.set_field(state, -2, "new_cwd");
        },
        .window_size => |value| {
            api.create_table(state, 0, 4);
            api.push_number(state, @floatFromInt(value.rows));
            api.set_field(state, -2, "rows");
            api.push_number(state, @floatFromInt(value.cols));
            api.set_field(state, -2, "cols");
            api.push_number(state, @floatFromInt(value.width));
            api.set_field(state, -2, "width");
            api.push_number(state, @floatFromInt(value.height));
            api.set_field(state, -2, "height");
        },
        .key_unhandled => |value| {
            api.create_table(state, 0, 2);
            try pushOwnedString(allocator, api, state, value.key);
            api.set_field(state, -2, "key");
            api.push_number(state, @floatFromInt(value.mods));
            api.set_field(state, -2, "mods");
        },
        .topbar_node => |value| {
            api.create_table(state, 0, 1);
            try pushOwnedString(allocator, api, state, value.id);
            api.set_field(state, -2, "id");
        },
        .bottombar_node => |value| {
            api.create_table(state, 0, 1);
            try pushOwnedString(allocator, api, state, value.id);
            api.set_field(state, -2, "id");
        },
    }
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

fn l_strftime(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;

    var fmt_len: usize = 0;
    const fmt_ptr = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .string)
        api.to_lstring(state, 1, &fmt_len)
    else
        null;
    const fmt = if (fmt_ptr) |p| p[0..fmt_len] else "%B %e, %H:%M:%S";

    const lt = platform.getLocalTime();

    var out: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out);
    const w = fbs.writer();

    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] != '%' or i + 1 >= fmt.len) {
            w.writeByte(fmt[i]) catch break;
            continue;
        }
        i += 1;
        switch (fmt[i]) {
            '%' => w.writeByte('%') catch break,
            'H' => w.print("{d:0>2}", .{lt.hour}) catch break,
            'M' => w.print("{d:0>2}", .{lt.minute}) catch break,
            'S' => w.print("{d:0>2}", .{lt.second}) catch break,
            'e' => w.print("{d}", .{lt.day}) catch break,
            'Y' => w.print("{d}", .{lt.year}) catch break,
            'B' => w.writeAll(monthName(@intCast(lt.month))) catch break,
            else => {
                w.writeByte('%') catch break;
                w.writeByte(fmt[i]) catch break;
            },
        }
    }

    const zvalue = std.heap.page_allocator.dupeZ(u8, fbs.getWritten()) catch return 0;
    defer std.heap.page_allocator.free(zvalue);
    api.push_string(state, zvalue);
    return 1;
}

fn monthName(month: u8) []const u8 {
    return switch (month) {
        1 => "January",
        2 => "February",
        3 => "March",
        4 => "April",
        5 => "May",
        6 => "June",
        7 => "July",
        8 => "August",
        9 => "September",
        10 => "October",
        11 => "November",
        12 => "December",
        else => "",
    };
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

        if (std.mem.eql(u8, key, "fonts") and value_type == .table) {
            const fonts_idx = absoluteIndex(api, state, -1);
            applyFontsTable(ctx.cfg, api, state, fonts_idx) catch |err| std.log.err("config fonts field failed: {s}", .{@errorName(err)});
            continue;
        }

        if (std.mem.eql(u8, key, "theme") and value_type == .table) {
            const theme_idx = absoluteIndex(api, state, -1);
            applyThemeTable(ctx.cfg, api, state, theme_idx) catch |err| std.log.err("config theme field failed: {s}", .{@errorName(err)});
            continue;
        }

        if (std.mem.eql(u8, key, "terminal_theme") and value_type == .table) {
            const theme_idx = absoluteIndex(api, state, -1);
            applyThemeTable(ctx.cfg, api, state, theme_idx) catch |err| std.log.err("config terminal_theme field failed: {s}", .{@errorName(err)});
            continue;
        }

        if (std.mem.eql(u8, key, "ui_theme") and value_type == .table) {
            continue;
        }

        if (std.mem.eql(u8, key, "scrollbar") and value_type == .table) {
            const scrollbar_idx = absoluteIndex(api, state, -1);
            applyScrollbarThemeTable(ctx.cfg, api, state, scrollbar_idx) catch |err| std.log.err("config scrollbar field failed: {s}", .{@errorName(err)});
            continue;
        }

        if (std.mem.eql(u8, key, "hyperlinks") and value_type == .table) {
            const hyperlinks_idx = absoluteIndex(api, state, -1);
            applyHyperlinksTable(ctx.cfg, api, state, hyperlinks_idx) catch |err| std.log.err("config hyperlinks field failed: {s}", .{@errorName(err)});
            continue;
        }

        if (std.mem.eql(u8, key, "domains") and value_type == .table) {
            const domains_idx = absoluteIndex(api, state, -1);
            applyDomainsTable(ctx.cfg, api, state, domains_idx) catch |err| std.log.err("config domains field failed: {s}", .{@errorName(err)});
            continue;
        }

        if (std.mem.eql(u8, key, "ansi") and value_type == .table) {
            const ansi_idx = absoluteIndex(api, state, -1);
            applyPaletteArray(ctx.cfg, api, state, ansi_idx, 0, 8) catch |err| std.log.err("config ansi field failed: {s}", .{@errorName(err)});
            continue;
        }

        if (std.mem.eql(u8, key, "brights") and value_type == .table) {
            const brights_idx = absoluteIndex(api, state, -1);
            applyPaletteArray(ctx.cfg, api, state, brights_idx, 8, 8) catch |err| std.log.err("config brights field failed: {s}", .{@errorName(err)});
            continue;
        }

        if (std.mem.eql(u8, key, "indexed") and value_type == .table) {
            const indexed_idx = absoluteIndex(api, state, -1);
            applyIndexedPalette(ctx.cfg, api, state, indexed_idx) catch |err| std.log.err("config indexed field failed: {s}", .{@errorName(err)});
            continue;
        }

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
    if (applyHexColor(cfg, key, value)) return;
    if (std.mem.eql(u8, key, "backend")) return cfg.setBackend(value);
    if (std.mem.eql(u8, key, "shell")) return cfg.setShell(value);
    if (std.mem.eql(u8, key, "default_domain")) return cfg.setDefaultDomain(value);
    if (std.mem.eql(u8, key, "htp_transport")) return cfg.setHtpTransport(value);
    if (std.mem.eql(u8, key, "window_title")) return cfg.setWindowTitle(value);
    if (std.mem.eql(u8, key, "lib_dir")) return cfg.setLibDir(value);
    if (std.mem.eql(u8, key, "font_path")) return cfg.setFontRegular(value);
    if (std.mem.eql(u8, key, "font_bold_path")) return cfg.setFontBold(value);
    if (std.mem.eql(u8, key, "font_italic_path")) return cfg.setFontItalic(value);
    if (std.mem.eql(u8, key, "font_bold_italic_path")) return cfg.setFontBoldItalic(value);
    if (std.mem.eql(u8, key, "font_smoothing")) return cfg.setFontSmoothing(value);
    if (std.mem.eql(u8, key, "font_hinting")) return cfg.setFontHinting(value);
    if (std.mem.eql(u8, key, "hyperlink_prefixes")) return cfg.setHyperlinkPrefixes(value);
    if (std.mem.eql(u8, key, "hyperlink_delimiters")) return cfg.setHyperlinkDelimiters(value);
    if (std.mem.eql(u8, key, "hyperlink_trim_trailing")) return cfg.setHyperlinkTrimTrailing(value);
    if (std.mem.eql(u8, key, "hyperlink_trim_leading")) return cfg.setHyperlinkTrimLeading(value);
}

fn applyNumber(cfg: *config.Config, key: []const u8, value: f64) !void {
    if (std.mem.eql(u8, key, "font_size")) {
        cfg.fonts.size = @floatCast(value);
        return;
    }

    if (std.mem.eql(u8, key, "font_line_height")) {
        cfg.fonts.line_height = @floatCast(value);
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
        cfg.fonts.embolden = @floatCast(value);
        return;
    }

    if (std.mem.eql(u8, key, "font_padding_x")) {
        cfg.fonts.padding_x = @floatCast(value);
        return;
    }

    if (std.mem.eql(u8, key, "font_padding_y")) {
        cfg.fonts.padding_y = @floatCast(value);
        return;
    }

    if (std.mem.eql(u8, key, "font_coverage_boost")) {
        cfg.fonts.coverage_boost = @floatCast(value);
        return;
    }

    if (std.mem.eql(u8, key, "font_coverage_add")) {
        cfg.fonts.coverage_add = @floatCast(value);
        return;
    }

    if (std.mem.eql(u8, key, "scrollback")) {
        cfg.scrollback = try asInt(usize, value);
        return;
    }

    if (std.mem.eql(u8, key, "padding")) {
        const pad = try asInt(u32, value);
        cfg.terminal_padding = .{ .left = pad, .right = pad, .top = pad, .bottom = pad };
        return;
    }

    if (std.mem.eql(u8, key, "padding_x")) {
        const pad = try asInt(u32, value);
        cfg.terminal_padding.left = pad;
        cfg.terminal_padding.right = pad;
        return;
    }

    if (std.mem.eql(u8, key, "padding_y")) {
        const pad = try asInt(u32, value);
        cfg.terminal_padding.top = pad;
        cfg.terminal_padding.bottom = pad;
        return;
    }

    if (std.mem.eql(u8, key, "padding_left")) {
        cfg.terminal_padding.left = try asInt(u32, value);
        return;
    }

    if (std.mem.eql(u8, key, "padding_right")) {
        cfg.terminal_padding.right = try asInt(u32, value);
        return;
    }

    if (std.mem.eql(u8, key, "padding_top")) {
        cfg.terminal_padding.top = try asInt(u32, value);
        return;
    }

    if (std.mem.eql(u8, key, "padding_bottom")) {
        cfg.terminal_padding.bottom = try asInt(u32, value);
        return;
    }

    if (std.mem.eql(u8, key, "top_bar_height")) {
        cfg.top_bar_height = try asInt(u32, value);
        return;
    }

    if (std.mem.eql(u8, key, "bottom_bar_height")) {
        cfg.bottom_bar_height = try asInt(u32, value);
        return;
    }

    if (std.mem.eql(u8, key, "scroll_multiplier")) {
        cfg.scroll_multiplier = @floatCast(value);
        return;
    }

    if (std.mem.eql(u8, key, "max_fps")) {
        cfg.max_fps = try asInt(u32, value);
        return;
    }
}

fn applyBoolean(cfg: *config.Config, key: []const u8, value: bool) !void {
    if (std.mem.eql(u8, key, "font_lcd")) {
        cfg.fonts.smoothing = if (value) .subpixel else .grayscale;
        return;
    }
    if (std.mem.eql(u8, key, "top_bar_show")) {
        cfg.top_bar_show = value;
        return;
    }
    if (std.mem.eql(u8, key, "bottom_bar_show")) {
        cfg.bottom_bar_show = value;
        return;
    }
    if (std.mem.eql(u8, key, "window_titlebar_show")) {
        cfg.window_titlebar_show = value;
        return;
    }
    if (std.mem.eql(u8, key, "top_bar_show_when_single_tab")) {
        cfg.top_bar_show_when_single_tab = value;
        return;
    }
    if (std.mem.eql(u8, key, "top_bar_draw_tabs")) {
        cfg.top_bar_draw_tabs = value;
        return;
    }
    if (std.mem.eql(u8, key, "top_bar_draw_status")) {
        cfg.top_bar_draw_status = value;
        return;
    }
    if (std.mem.eql(u8, key, "bottom_bar_draw_status")) {
        cfg.bottom_bar_draw_status = value;
        return;
    }
    if (std.mem.eql(u8, key, "debug_overlay")) {
        cfg.debug_overlay = value;
        return;
    }
    if (std.mem.eql(u8, key, "vsync")) {
        cfg.vsync = value;
        return;
    }
    if (std.mem.eql(u8, key, "renderer_single_pane_direct")) {
        cfg.renderer_single_pane_direct = value;
        return;
    }
    if (std.mem.eql(u8, key, "renderer_safe_mode")) {
        cfg.renderer_safe_mode = value;
        return;
    }
    if (std.mem.eql(u8, key, "renderer_disable_swapchain_glyphs")) {
        cfg.renderer_disable_swapchain_glyphs = value;
        return;
    }
    if (std.mem.eql(u8, key, "renderer_disable_multi_pane_cache")) {
        cfg.renderer_disable_multi_pane_cache = value;
        return;
    }
    if (std.mem.eql(u8, key, "scrollbar")) {
        cfg.scrollbar.enabled = value;
        return;
    }
    if (std.mem.eql(u8, key, "hyperlinks")) {
        cfg.hyperlinks.enabled = value;
        return;
    }
}

fn applyHyperlinksTable(cfg: *config.Config, api: Api, state: *State, table_idx: c_int) !void {
    api.push_nil(state);
    while (api.next(state, table_idx) != 0) {
        defer pop(api, state, 1);

        var key_len: usize = 0;
        const key_ptr = api.to_lstring(state, -2, &key_len) orelse continue;
        const key = key_ptr[0..key_len];
        const value_type: LuaType = @enumFromInt(api.value_type(state, -1));

        if (value_type == .boolean) {
            const value = api.to_boolean(state, -1) != 0;
            if (std.mem.eql(u8, key, "enabled")) {
                cfg.hyperlinks.enabled = value;
                continue;
            }
            if (std.mem.eql(u8, key, "shift_click_only")) {
                cfg.hyperlinks.shift_click_only = value;
                continue;
            }
            if (std.mem.eql(u8, key, "match_www")) {
                cfg.hyperlinks.match_www = value;
                continue;
            }
        }

        if (value_type != .string) continue;
        var value_len: usize = 0;
        const value_ptr = api.to_lstring(state, -1, &value_len) orelse continue;
        const value = value_ptr[0..value_len];

        if (std.mem.eql(u8, key, "prefixes")) {
            try cfg.setHyperlinkPrefixes(value);
            continue;
        }
        if (std.mem.eql(u8, key, "delimiters")) {
            try cfg.setHyperlinkDelimiters(value);
            continue;
        }
        if (std.mem.eql(u8, key, "trim_trailing")) {
            try cfg.setHyperlinkTrimTrailing(value);
            continue;
        }
        if (std.mem.eql(u8, key, "trim_leading")) {
            try cfg.setHyperlinkTrimLeading(value);
            continue;
        }
    }
}

fn applyDomainsTable(cfg: *config.Config, api: Api, state: *State, table_idx: c_int) !void {
    api.push_nil(state);
    while (api.next(state, table_idx) != 0) {
        defer pop(api, state, 1);

        var key_len: usize = 0;
        const key_ptr = api.to_lstring(state, -2, &key_len) orelse continue;
        const key = key_ptr[0..key_len];
        const value_type: LuaType = @enumFromInt(api.value_type(state, -1));
        if (value_type == .string) {
            var value_len: usize = 0;
            const value_ptr = api.to_lstring(state, -1, &value_len) orelse continue;
            try cfg.setDomainShell(key, value_ptr[0..value_len]);
            continue;
        }

        if (value_type == .table) {
            const domain_idx = absoluteIndex(api, state, -1);
            try applyDomainTable(cfg, api, state, key, domain_idx);
        }
    }
}

fn applyDomainTable(cfg: *config.Config, api: Api, state: *State, domain_name: []const u8, table_idx: c_int) !void {
    api.push_nil(state);
    while (api.next(state, table_idx) != 0) {
        defer pop(api, state, 1);

        var key_len: usize = 0;
        const key_ptr = api.to_lstring(state, -2, &key_len) orelse continue;
        const key = key_ptr[0..key_len];
        if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) != .string) continue;

        var value_len: usize = 0;
        const value_ptr = api.to_lstring(state, -1, &value_len) orelse continue;
        const value = value_ptr[0..value_len];

        if (std.mem.eql(u8, key, "shell")) {
            try cfg.setDomainShell(domain_name, value);
            continue;
        }

        if (std.mem.eql(u8, key, "default_cwd")) {
            try cfg.setDomainDefaultCwd(domain_name, value);
            continue;
        }
    }
}

fn luaStringField(api: Api, state: *State, table_idx: c_int, field: [*:0]const u8) ?[]const u8 {
    api.get_field(state, table_idx, field);
    defer pop(api, state, 1);
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) != .string) return null;
    var len: usize = 0;
    const ptr = api.to_lstring(state, -1, &len) orelse return null;
    return ptr[0..len];
}

fn applyFontsTable(cfg: *config.Config, api: Api, state: *State, table_idx: c_int) !void {
    cfg.clearFontFallbacks();

    api.push_nil(state);
    while (api.next(state, table_idx) != 0) {
        defer pop(api, state, 1);

        var key_len: usize = 0;
        const key_ptr = api.to_lstring(state, -2, &key_len) orelse continue;
        const key = key_ptr[0..key_len];
        const value_type: LuaType = @enumFromInt(api.value_type(state, -1));

        if (std.mem.eql(u8, key, "fallbacks") and value_type == .table) {
            const fallbacks_idx = absoluteIndex(api, state, -1);
            try applyFontFallbacksTable(cfg, api, state, fallbacks_idx);
            continue;
        }

        if (value_type == .string) {
            var value_len: usize = 0;
            const value_ptr = api.to_lstring(state, -1, &value_len) orelse continue;
            const value = value_ptr[0..value_len];

            if (std.mem.eql(u8, key, "regular")) {
                try cfg.setFontRegular(value);
                continue;
            }
            if (std.mem.eql(u8, key, "bold")) {
                try cfg.setFontBold(value);
                continue;
            }
            if (std.mem.eql(u8, key, "italic")) {
                try cfg.setFontItalic(value);
                continue;
            }
            if (std.mem.eql(u8, key, "bold_italic")) {
                try cfg.setFontBoldItalic(value);
                continue;
            }
            if (std.mem.eql(u8, key, "smoothing")) {
                try cfg.setFontSmoothing(value);
                continue;
            }
            if (std.mem.eql(u8, key, "hinting")) {
                try cfg.setFontHinting(value);
                continue;
            }
        }

        if (value_type == .number) {
            const value = api.to_number(state, -1);
            if (std.mem.eql(u8, key, "size")) {
                cfg.fonts.size = @floatCast(value);
                continue;
            }
            if (std.mem.eql(u8, key, "line_height")) {
                cfg.fonts.line_height = @floatCast(value);
                continue;
            }
            if (std.mem.eql(u8, key, "padding_x")) {
                cfg.fonts.padding_x = @floatCast(value);
                continue;
            }
            if (std.mem.eql(u8, key, "padding_y")) {
                cfg.fonts.padding_y = @floatCast(value);
                continue;
            }
            if (std.mem.eql(u8, key, "coverage_boost")) {
                cfg.fonts.coverage_boost = @floatCast(value);
                continue;
            }
            if (std.mem.eql(u8, key, "coverage_add")) {
                cfg.fonts.coverage_add = @floatCast(value);
                continue;
            }
            if (std.mem.eql(u8, key, "embolden")) {
                cfg.fonts.embolden = @floatCast(value);
                continue;
            }
        }

        if (value_type == .boolean) {
            const value = api.to_boolean(state, -1) != 0;
            if (std.mem.eql(u8, key, "lcd")) {
                cfg.fonts.smoothing = if (value) .subpixel else .grayscale;
                continue;
            }
            if (std.mem.eql(u8, key, "ligatures")) {
                cfg.fonts.ligatures = value;
                continue;
            }
        }
    }
}

fn applyFontFallbacksTable(cfg: *config.Config, api: Api, state: *State, table_idx: c_int) !void {
    api.push_nil(state);
    while (api.next(state, table_idx) != 0) {
        defer pop(api, state, 1);
        if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) != .string) continue;

        var value_len: usize = 0;
        const value_ptr = api.to_lstring(state, -1, &value_len) orelse continue;
        try cfg.addFontFallback(value_ptr[0..value_len]);
    }
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

fn luaValueToOwnedString(allocator: std.mem.Allocator, api: Api, state: *State, idx: c_int) ?[]u8 {
    const value_type: LuaType = @enumFromInt(api.value_type(state, idx));
    if (value_type == .string) {
        var len: usize = 0;
        const ptr = api.to_lstring(state, idx, &len) orelse return null;
        return allocator.dupe(u8, ptr[0..len]) catch null;
    }
    if (value_type == .number) {
        return std.fmt.allocPrint(allocator, "{d}", .{api.to_number(state, idx)}) catch null;
    }
    if (value_type == .boolean) {
        return allocator.dupe(u8, if (api.to_boolean(state, idx) != 0) "true" else "false") catch null;
    }
    if (value_type == .nil_type) {
        return allocator.dupe(u8, "nil") catch null;
    }
    return allocator.dupe(u8, "<non-string lua value>") catch null;
}

fn luaErrorToOwnedString(allocator: std.mem.Allocator, api: Api, state: *State) ?[]u8 {
    const message = luaValueToOwnedString(allocator, api, state, -1);
    pop(api, state, 1);
    return message;
}

fn parseHexColor(text: []const u8) ?ghostty.ColorRgb {
    if (text.len != 7 or text[0] != '#') return null;
    const r = std.fmt.parseInt(u8, text[1..3], 16) catch return null;
    const g = std.fmt.parseInt(u8, text[3..5], 16) catch return null;
    const b = std.fmt.parseInt(u8, text[5..7], 16) catch return null;
    return .{ .r = r, .g = g, .b = b };
}

fn applyHexColor(cfg: *config.Config, key: []const u8, value: []const u8) bool {
    const color = parseHexColor(value) orelse return false;
    if (std.mem.eql(u8, key, "top_bar_bg")) {
        cfg.top_bar_bg = color;
        return true;
    }
    if (std.mem.eql(u8, key, "bottom_bar_bg")) {
        cfg.bottom_bar_bg = color;
        return true;
    }
    if (std.mem.eql(u8, key, "foreground")) {
        cfg.terminal_theme.enabled = true;
        cfg.terminal_theme.foreground = color;
        return true;
    }
    if (std.mem.eql(u8, key, "background")) {
        cfg.terminal_theme.enabled = true;
        cfg.terminal_theme.background = color;
        return true;
    }
    if (std.mem.eql(u8, key, "cursor_bg")) {
        cfg.terminal_theme.enabled = true;
        cfg.terminal_theme.cursor = color;
        return true;
    }
    if (std.mem.eql(u8, key, "selection_fg")) {
        cfg.terminal_theme.enabled = true;
        cfg.terminal_theme.selection_fg = color;
        return true;
    }
    if (std.mem.eql(u8, key, "selection_bg")) {
        cfg.terminal_theme.enabled = true;
        cfg.terminal_theme.selection_bg = color;
        return true;
    }
    if (std.mem.eql(u8, key, "scrollbar_thumb")) {
        cfg.scrollbar.thumb_color = color;
        cfg.scrollbar.thumb_hover_color = color;
        return true;
    }
    return false;
}

fn applyPaletteArray(cfg: *config.Config, api: Api, state: *State, table_idx: c_int, start: usize, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        api.rawgeti(state, table_idx, @intCast(i + 1));
        defer pop(api, state, 1);
        if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) != .string) continue;

        var value_len: usize = 0;
        const value_ptr = api.to_lstring(state, -1, &value_len) orelse continue;
        const color = parseHexColor(value_ptr[0..value_len]) orelse continue;
        cfg.terminal_theme.enabled = true;
        cfg.terminal_theme.palette[start + i] = color;
    }
}

fn applyIndexedPalette(cfg: *config.Config, api: Api, state: *State, table_idx: c_int) !void {
    api.push_nil(state);
    while (api.next(state, table_idx) != 0) {
        defer pop(api, state, 1);

        const key_type: LuaType = @enumFromInt(api.value_type(state, -2));
        const value_type: LuaType = @enumFromInt(api.value_type(state, -1));
        if (key_type != .number or value_type != .string) continue;

        const key_num = api.to_number(state, -2);
        const palette_index = asInt(u8, key_num) catch continue;

        var value_len: usize = 0;
        const value_ptr = api.to_lstring(state, -1, &value_len) orelse continue;
        const color = parseHexColor(value_ptr[0..value_len]) orelse continue;
        cfg.terminal_theme.enabled = true;
        cfg.terminal_theme.palette[palette_index] = color;
    }
}

fn applyThemeTable(cfg: *config.Config, api: Api, state: *State, table_idx: c_int) !void {
    api.push_nil(state);
    while (api.next(state, table_idx) != 0) {
        defer pop(api, state, 1);

        var key_len: usize = 0;
        const key_ptr = api.to_lstring(state, -2, &key_len) orelse continue;
        const key = key_ptr[0..key_len];
        const value_type: LuaType = @enumFromInt(api.value_type(state, -1));

        if (std.mem.eql(u8, key, "ansi") and value_type == .table) {
            const ansi_idx = absoluteIndex(api, state, -1);
            try applyPaletteArray(cfg, api, state, ansi_idx, 0, 8);
            continue;
        }

        if (std.mem.eql(u8, key, "brights") and value_type == .table) {
            const brights_idx = absoluteIndex(api, state, -1);
            try applyPaletteArray(cfg, api, state, brights_idx, 8, 8);
            continue;
        }

        if (std.mem.eql(u8, key, "indexed") and value_type == .table) {
            const indexed_idx = absoluteIndex(api, state, -1);
            try applyIndexedPalette(cfg, api, state, indexed_idx);
            continue;
        }

        if (std.mem.eql(u8, key, "scrollbar") and value_type == .table) {
            const scrollbar_idx = absoluteIndex(api, state, -1);
            try applyScrollbarThemeTable(cfg, api, state, scrollbar_idx);
            continue;
        }

        if (value_type != .string) continue;

        var value_len: usize = 0;
        const value_ptr = api.to_lstring(state, -1, &value_len) orelse continue;
        _ = applyHexColor(cfg, key, value_ptr[0..value_len]);
    }
}

fn applyScrollbarThemeTable(cfg: *config.Config, api: Api, state: *State, table_idx: c_int) !void {
    api.push_nil(state);
    while (api.next(state, table_idx) != 0) {
        defer pop(api, state, 1);

        var key_len: usize = 0;
        const key_ptr = api.to_lstring(state, -2, &key_len) orelse continue;
        const key = key_ptr[0..key_len];
        const value_type: LuaType = @enumFromInt(api.value_type(state, -1));

        if (value_type == .boolean) {
            const value = api.to_boolean(state, -1) != 0;
            if (std.mem.eql(u8, key, "enabled")) {
                cfg.scrollbar.enabled = value;
                continue;
            }
            if (std.mem.eql(u8, key, "jump_to_click")) {
                cfg.scrollbar.jump_to_click = value;
                continue;
            }
        }

        if (value_type == .number) {
            const value = api.to_number(state, -1);
            if (std.mem.eql(u8, key, "width")) {
                cfg.scrollbar.width = try asInt(u32, value);
                continue;
            }
            if (std.mem.eql(u8, key, "min_thumb_size")) {
                cfg.scrollbar.min_thumb_size = try asInt(u32, value);
                continue;
            }
            if (std.mem.eql(u8, key, "margin")) {
                cfg.scrollbar.margin = try asInt(u32, value);
                continue;
            }
        }

        if (value_type != .string) continue;

        var value_len: usize = 0;
        const value_ptr = api.to_lstring(state, -1, &value_len) orelse continue;
        const color = parseHexColor(value_ptr[0..value_len]) orelse continue;
        if (std.mem.eql(u8, key, "track")) {
            cfg.scrollbar.track_color = color;
            continue;
        }
        if (std.mem.eql(u8, key, "thumb")) {
            cfg.scrollbar.thumb_color = color;
            continue;
        }
        if (std.mem.eql(u8, key, "thumb_hover")) {
            cfg.scrollbar.thumb_hover_color = color;
            continue;
        }
        if (std.mem.eql(u8, key, "thumb_active")) {
            cfg.scrollbar.thumb_active_color = color;
            continue;
        }
        if (std.mem.eql(u8, key, "border")) {
            cfg.scrollbar.border_color = color;
            continue;
        }
    }
}

pub fn parseColorField(api: Api, state: *State, table_idx: c_int, field: [*:0]const u8) ?ghostty.ColorRgb {
    api.get_field(state, table_idx, field);
    defer pop(api, state, 1);
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) != .string) return null;
    var len: usize = 0;
    const ptr = api.to_lstring(state, -1, &len) orelse return null;
    return parseHexColor(ptr[0..len]);
}

pub fn parseSegmentArray(api: Api, state: *State, seg_buf: []bar.Segment, text_buf: []u8, table_idx: c_int) []bar.Segment {
    var seg_count: usize = 0;
    var text_used: usize = 0;

    api.push_nil(state);
    while (api.next(state, table_idx) != 0) {
        defer pop(api, state, 1);
        if (seg_count >= seg_buf.len) break;
        if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) != .table) continue;

        var seg = bar.Segment{ .text = "" };
        api.get_field(state, -1, "text");
        if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .string) {
            var len: usize = 0;
            if (api.to_lstring(state, -1, &len)) |ptr| {
                if (text_used + len <= text_buf.len) {
                    @memcpy(text_buf[text_used .. text_used + len], ptr[0..len]);
                    seg.text = text_buf[text_used .. text_used + len];
                    text_used += len;
                }
            }
        }
        pop(api, state, 1);

        api.get_field(state, -1, "bold");
        seg.bold = api.to_boolean(state, -1) != 0;
        pop(api, state, 1);

        seg.fg = parseColorField(api, state, -1, "fg");
        seg.bg = parseColorField(api, state, -1, "bg");

        if (seg.text.len > 0) {
            seg_buf[seg_count] = seg;
            seg_count += 1;
        }
    }

    return seg_buf[0..seg_count];
}

fn parseLabelResult(api: Api, state: *State, out_buf: []u8, fallback: []const u8) bar.Segment {
    const value_type: LuaType = @enumFromInt(api.value_type(state, -1));
    if (value_type == .string) {
        var len: usize = 0;
        if (api.to_lstring(state, -1, &len)) |ptr| {
            const n = @min(len, out_buf.len);
            @memcpy(out_buf[0..n], ptr[0..n]);
            return .{ .text = out_buf[0..n] };
        }
        return .{ .text = fallback };
    }

    if (value_type != .table) return .{ .text = fallback };

    var seg = bar.Segment{ .text = fallback };

    api.get_field(state, -1, "text");
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .string) {
        var len: usize = 0;
        if (api.to_lstring(state, -1, &len)) |ptr| {
            const n = @min(len, out_buf.len);
            @memcpy(out_buf[0..n], ptr[0..n]);
            seg.text = out_buf[0..n];
        }
    }
    pop(api, state, 1);

    api.get_field(state, -1, "bold");
    seg.bold = api.to_boolean(state, -1) != 0;
    pop(api, state, 1);

    seg.fg = parseColorField(api, state, -1, "fg");
    seg.bg = parseColorField(api, state, -1, "bg");
    return seg;
}

pub fn pop(api: Api, state: *State, count: c_int) void {
    api.set_top(state, -count - 1);
}

pub fn absoluteIndex(api: Api, state: *State, idx: c_int) c_int {
    if (idx > 0 or idx <= LUA_REGISTRYINDEX) return idx;
    return api.get_top(state) + idx + 1;
}

/// hollow.new_tab([domain|string|opts])
fn l_new_tab(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    var domain_name: ?[]const u8 = null;

    switch (@as(LuaType, @enumFromInt(api.value_type(state, 1)))) {
        .string => {
            var len: usize = 0;
            if (api.to_lstring(state, 1, &len)) |ptr| domain_name = ptr[0..len];
        },
        .table => {
            domain_name = luaStringField(api, state, absoluteIndex(api, state, 1), "domain");
        },
        else => {},
    }

    if (ctx.app_callbacks) |cbs| cbs.new_tab(cbs.app, domain_name);
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

fn l_new_workspace(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    if (ctx.app_callbacks) |cbs| cbs.new_workspace(cbs.app);
    return 0;
}

fn l_next_workspace(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    if (ctx.app_callbacks) |cbs| cbs.next_workspace(cbs.app);
    return 0;
}

fn l_prev_workspace(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    if (ctx.app_callbacks) |cbs| cbs.prev_workspace(cbs.app);
    return 0;
}

/// hollow.split_pane(direction|opts, ratio?, domain?)
/// direction: "vertical" (left/right) or "horizontal" (top/bottom)
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

    var direction: []const u8 = if (dir_ptr) |p| p[0..dir_len] else "vertical";

    // Optional second argument: ratio in (0, 1). Defaults to 0.5.
    var ratio: f32 = if (@as(LuaType, @enumFromInt(api.value_type(state, 2))) == .number)
        @as(f32, @floatCast(api.to_number(state, 2)))
    else
        0.5;

    var domain_name: ?[]const u8 = null;
    var cwd: ?[]const u8 = null;
    var command: ?[]const u8 = null;
    var command_mode: []const u8 = "send";
    var close_on_exit = false;
    var floating = false;
    var fullscreen = false;
    var x: f32 = 0.15;
    var y: f32 = 0.1;
    var width: f32 = 0.7;
    var height: f32 = 0.75;
    var has_bounds = false;
    if (@as(LuaType, @enumFromInt(api.value_type(state, 3))) == .string) {
        var domain_len: usize = 0;
        if (api.to_lstring(state, 3, &domain_len)) |ptr| domain_name = ptr[0..domain_len];
    } else if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .table) {
        const opts_idx = absoluteIndex(api, state, 1);
        domain_name = luaStringField(api, state, opts_idx, "domain");
        cwd = luaStringField(api, state, opts_idx, "cwd");
        command = luaStringField(api, state, opts_idx, "command");
        if (luaStringField(api, state, opts_idx, "command_mode")) |mode| command_mode = mode;
        api.get_field(state, opts_idx, "close_on_exit");
        if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .boolean) {
            close_on_exit = api.to_boolean(state, -1) != 0;
        }
        pop(api, state, 1);
        if (luaStringField(api, state, opts_idx, "direction")) |opt_direction| {
            dir_len = opt_direction.len;
            direction = opt_direction;
        }
        api.get_field(state, opts_idx, "floating");
        if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .boolean) {
            floating = api.to_boolean(state, -1) != 0;
        }
        pop(api, state, 1);
        api.get_field(state, opts_idx, "fullscreen");
        if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .boolean) {
            fullscreen = api.to_boolean(state, -1) != 0;
        }
        pop(api, state, 1);
        api.get_field(state, opts_idx, "ratio");
        if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .number) {
            ratio = @as(f32, @floatCast(api.to_number(state, -1)));
        }
        pop(api, state, 1);
        api.get_field(state, opts_idx, "x");
        if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .number) {
            x = @as(f32, @floatCast(api.to_number(state, -1)));
            has_bounds = true;
        }
        pop(api, state, 1);
        api.get_field(state, opts_idx, "y");
        if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .number) {
            y = @as(f32, @floatCast(api.to_number(state, -1)));
            has_bounds = true;
        }
        pop(api, state, 1);
        api.get_field(state, opts_idx, "width");
        if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .number) {
            width = @as(f32, @floatCast(api.to_number(state, -1)));
            has_bounds = true;
        }
        pop(api, state, 1);
        api.get_field(state, opts_idx, "height");
        if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) == .number) {
            height = @as(f32, @floatCast(api.to_number(state, -1)));
            has_bounds = true;
        }
        pop(api, state, 1);
    }

    cbs.split_pane(cbs.app, direction, ratio, domain_name, cwd, command, command_mode, close_on_exit, floating, fullscreen, x, y, width, height, has_bounds);
    return 0;
}

fn l_toggle_pane_maximized(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse return 0;

    const pane_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        cbs.get_current_pane_id(cbs.app);
    const show_background = if (@as(LuaType, @enumFromInt(api.value_type(state, 2))) == .boolean)
        api.to_boolean(state, 2) != 0
    else
        false;
    cbs.toggle_pane_maximized(cbs.app, pane_id, show_background);
    return 0;
}

fn l_set_pane_floating(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse return 0;

    const pane_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        cbs.get_current_pane_id(cbs.app);
    const floating = if (@as(LuaType, @enumFromInt(api.value_type(state, 2))) == .boolean)
        api.to_boolean(state, 2) != 0
    else
        true;
    cbs.set_pane_floating(cbs.app, pane_id, floating);
    return 0;
}

fn l_set_floating_pane_bounds(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse return 0;

    const pane_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        cbs.get_current_pane_id(cbs.app);
    const x: f32 = if (@as(LuaType, @enumFromInt(api.value_type(state, 2))) == .number) @floatCast(api.to_number(state, 2)) else 0.15;
    const y: f32 = if (@as(LuaType, @enumFromInt(api.value_type(state, 3))) == .number) @floatCast(api.to_number(state, 3)) else 0.1;
    const width: f32 = if (@as(LuaType, @enumFromInt(api.value_type(state, 4))) == .number) @floatCast(api.to_number(state, 4)) else 0.7;
    const height: f32 = if (@as(LuaType, @enumFromInt(api.value_type(state, 5))) == .number) @floatCast(api.to_number(state, 5)) else 0.75;
    cbs.set_floating_pane_bounds(cbs.app, pane_id, x, y, width, height);
    return 0;
}

fn l_move_pane(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse return 0;

    const pane_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        cbs.get_current_pane_id(cbs.app);
    var dir_len: usize = 0;
    const dir_ptr = if (@as(LuaType, @enumFromInt(api.value_type(state, 2))) == .string)
        api.to_lstring(state, 2, &dir_len)
    else
        null;
    const direction = if (dir_ptr) |ptr| ptr[0..dir_len] else "right";
    const amount: f32 = if (@as(LuaType, @enumFromInt(api.value_type(state, 3))) == .number)
        @floatCast(api.to_number(state, 3))
    else
        0.08;
    cbs.move_pane(cbs.app, pane_id, direction, amount);
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

/// hollow.on_top_bar(fn(index, is_active, is_hovered, hover_close, fallback_title) -> string|nil)
fn l_on_top_bar(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const arg_type: LuaType = @enumFromInt(api.value_type(state, 1));

    if (arg_type == .nil_type) {
        if (ctx.top_bar_ref != LUA_NOREF) {
            api.unref(state, LUA_REGISTRYINDEX, ctx.top_bar_ref);
            ctx.top_bar_ref = LUA_NOREF;
        }
        return 0;
    }

    if (arg_type != .function) {
        std.log.err("lua: on_top_bar expects a function, got type {d}", .{@intFromEnum(arg_type)});
        return 0;
    }

    if (ctx.top_bar_ref != LUA_NOREF) {
        api.unref(state, LUA_REGISTRYINDEX, ctx.top_bar_ref);
    }

    api.push_value(state, 1);
    ctx.top_bar_ref = api.ref(state, LUA_REGISTRYINDEX);
    std.log.info("lua: top bar handler registered", .{});
    return 0;
}

/// hollow.on_workspace_title(fn(index, is_active, fallback_title) -> string|nil)
fn l_on_workspace_title(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const arg_type: LuaType = @enumFromInt(api.value_type(state, 1));

    if (arg_type == .nil_type) {
        if (ctx.workspace_title_ref != LUA_NOREF) {
            api.unref(state, LUA_REGISTRYINDEX, ctx.workspace_title_ref);
            ctx.workspace_title_ref = LUA_NOREF;
        }
        return 0;
    }

    if (arg_type != .function) {
        std.log.err("lua: on_workspace_title expects a function, got type {d}", .{@intFromEnum(arg_type)});
        return 0;
    }

    if (ctx.workspace_title_ref != LUA_NOREF) {
        api.unref(state, LUA_REGISTRYINDEX, ctx.workspace_title_ref);
    }

    api.push_value(state, 1);
    ctx.workspace_title_ref = api.ref(state, LUA_REGISTRYINDEX);
    std.log.info("lua: workspace title handler registered", .{});
    return 0;
}

/// hollow.on_gui_ready(fn())
fn l_on_gui_ready(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const arg_type: LuaType = @enumFromInt(api.value_type(state, 1));

    if (arg_type == .nil_type) {
        if (ctx.gui_ready_ref != LUA_NOREF) {
            api.unref(state, LUA_REGISTRYINDEX, ctx.gui_ready_ref);
            ctx.gui_ready_ref = LUA_NOREF;
        }
        return 0;
    }

    if (arg_type != .function) {
        std.log.err("lua: on_gui_ready expects a function, got type {d}", .{@intFromEnum(arg_type)});
        return 0;
    }

    if (ctx.gui_ready_ref != LUA_NOREF) {
        api.unref(state, LUA_REGISTRYINDEX, ctx.gui_ready_ref);
    }

    api.push_value(state, 1);
    ctx.gui_ready_ref = api.ref(state, LUA_REGISTRYINDEX);
    return 0;
}

/// hollow.on_status(fn(side, active_tab_index, tab_count) -> { segments... } | nil)
fn l_on_status(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const arg_type: LuaType = @enumFromInt(api.value_type(state, 1));

    if (arg_type == .nil_type) {
        if (ctx.status_ref != LUA_NOREF) {
            api.unref(state, LUA_REGISTRYINDEX, ctx.status_ref);
            ctx.status_ref = LUA_NOREF;
        }
        return 0;
    }

    if (arg_type != .function) {
        std.log.err("lua: on_status expects a function, got type {d}", .{@intFromEnum(arg_type)});
        return 0;
    }

    if (ctx.status_ref != LUA_NOREF) {
        api.unref(state, LUA_REGISTRYINDEX, ctx.status_ref);
    }

    api.push_value(state, 1);
    ctx.status_ref = api.ref(state, LUA_REGISTRYINDEX);
    std.log.info("lua: status handler registered", .{});
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

/// hollow.switch_workspace(index)  — 0-based index
fn l_switch_workspace(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse return 0;
    const idx: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    cbs.switch_workspace(cbs.app, idx);
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

fn l_set_tab_title_by_id(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_boolean(state, 0);
        return 1;
    };

    const tab_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;

    var len: usize = 0;
    const ptr = if (@as(LuaType, @enumFromInt(api.value_type(state, 2))) == .string)
        api.to_lstring(state, 2, &len)
    else
        null;
    const title: []const u8 = if (ptr) |p| p[0..len] else "";

    api.push_boolean(state, if (cbs.set_tab_title_by_id(cbs.app, tab_id, title)) 1 else 0);
    return 1;
}

fn l_is_leader_active(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse return 0;
    api.push_boolean(state, if (cbs.is_leader_active(cbs.app)) 1 else 0);
    return 1;
}

/// hollow.set_workspace_name(title)  — override the active workspace name
fn l_set_workspace_name(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    var len: usize = 0;
    const ptr = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .string)
        api.to_lstring(state, 1, &len)
    else
        null;
    const title: []const u8 = if (ptr) |p| p[0..len] else "";

    if (ctx.app_callbacks) |cbs| {
        cbs.set_workspace_name(cbs.app, title);
        return 0;
    }

    if (ctx.pending_workspace_name) |existing| ctx.cfg.allocator.free(existing);
    ctx.pending_workspace_name = if (title.len > 0) ctx.cfg.allocator.dupe(u8, title) catch null else null;
    return 0;
}

/// hollow.get_workspace_name(index) → string
fn l_get_workspace_name(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_string(state, "");
        return 1;
    };
    var out_buf: [128]u8 = undefined;
    const idx: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;

    const title = cbs.get_workspace_name(cbs.app, idx, &out_buf);

    const ztitle = std.heap.page_allocator.dupeZ(u8, title) catch {
        api.push_string(state, "");
        return 1;
    };
    defer std.heap.page_allocator.free(ztitle);
    api.push_string(state, ztitle);
    return 1;
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

fn l_current_tab_id(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_nil(state);
        return 1;
    };
    const id = cbs.get_current_tab_id(cbs.app);
    if (id == 0) {
        api.push_nil(state);
    } else {
        api.push_number(state, @floatFromInt(id));
    }
    return 1;
}

fn l_current_pane_id(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_nil(state);
        return 1;
    };
    const id = cbs.get_current_pane_id(cbs.app);
    if (id == 0) {
        api.push_nil(state);
    } else {
        api.push_number(state, @floatFromInt(id));
    }
    return 1;
}

fn l_get_tab_id_at(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_nil(state);
        return 1;
    };
    const index: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    const id = cbs.get_tab_id_at(cbs.app, index);
    if (id == 0) {
        api.push_nil(state);
    } else {
        api.push_number(state, @floatFromInt(id));
    }
    return 1;
}

fn l_get_tab_pane_count(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_number(state, 0);
        return 1;
    };
    const tab_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    api.push_number(state, @floatFromInt(cbs.get_tab_pane_count(cbs.app, tab_id)));
    return 1;
}

fn l_get_tab_pane_id_at(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_nil(state);
        return 1;
    };
    const tab_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    const index: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 2))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 2)))
    else
        0;
    const pane_id = cbs.get_tab_pane_id_at(cbs.app, tab_id, index);
    if (pane_id == 0) {
        api.push_nil(state);
    } else {
        api.push_number(state, @floatFromInt(pane_id));
    }
    return 1;
}

fn l_get_tab_active_pane_id(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_nil(state);
        return 1;
    };
    const tab_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    const pane_id = cbs.get_tab_active_pane_id(cbs.app, tab_id);
    if (pane_id == 0) {
        api.push_nil(state);
    } else {
        api.push_number(state, @floatFromInt(pane_id));
    }
    return 1;
}

fn l_get_tab_index_by_id(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_nil(state);
        return 1;
    };
    const tab_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    const index = cbs.get_tab_index_by_id(cbs.app, tab_id);
    if (index == std.math.maxInt(usize)) {
        api.push_nil(state);
    } else {
        api.push_number(state, @floatFromInt(index));
    }
    return 1;
}

fn l_get_workspace_count(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_number(state, 0);
        return 1;
    };
    const count = cbs.get_workspace_count(cbs.app);
    api.push_number(state, @floatFromInt(count));
    return 1;
}

fn l_get_active_workspace_index(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_number(state, 0);
        return 1;
    };
    const idx = cbs.get_active_workspace_index(cbs.app);
    api.push_number(state, @floatFromInt(idx));
    return 1;
}

fn l_get_pane_pid(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_number(state, 0);
        return 1;
    };
    const pane_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    api.push_number(state, @floatFromInt(cbs.get_pane_pid(cbs.app, pane_id)));
    return 1;
}

fn l_get_pane_title(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_string(state, "");
        return 1;
    };
    const pane_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    var out_buf: [256]u8 = undefined;
    const title = cbs.get_pane_title(cbs.app, pane_id, &out_buf);
    const ztitle = std.heap.page_allocator.dupeZ(u8, title) catch {
        api.push_string(state, "");
        return 1;
    };
    defer std.heap.page_allocator.free(ztitle);
    api.push_string(state, ztitle);
    return 1;
}

fn l_get_pane_cwd(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_string(state, "");
        return 1;
    };
    const pane_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    var out_buf: [512]u8 = undefined;
    const cwd = cbs.get_pane_cwd(cbs.app, pane_id, &out_buf);
    const zcwd = std.heap.page_allocator.dupeZ(u8, cwd) catch {
        api.push_string(state, "");
        return 1;
    };
    defer std.heap.page_allocator.free(zcwd);
    api.push_string(state, zcwd);
    return 1;
}

fn l_get_pane_domain(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_string(state, "");
        return 1;
    };
    const pane_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    var out_buf: [128]u8 = undefined;
    const domain = cbs.get_pane_domain(cbs.app, pane_id, &out_buf);
    const zdomain = std.heap.page_allocator.dupeZ(u8, domain) catch {
        api.push_string(state, "");
        return 1;
    };
    defer std.heap.page_allocator.free(zdomain);
    api.push_string(state, zdomain);
    return 1;
}

fn l_get_pane_rows(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_number(state, 0);
        return 1;
    };
    const pane_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    api.push_number(state, @floatFromInt(cbs.get_pane_rows(cbs.app, pane_id)));
    return 1;
}

fn l_get_pane_cols(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_number(state, 0);
        return 1;
    };
    const pane_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    api.push_number(state, @floatFromInt(cbs.get_pane_cols(cbs.app, pane_id)));
    return 1;
}

fn l_get_pane_x(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_number(state, 0);
        return 1;
    };
    const pane_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    api.push_number(state, @floatFromInt(cbs.get_pane_x(cbs.app, pane_id)));
    return 1;
}

fn l_get_pane_y(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_number(state, 0);
        return 1;
    };
    const pane_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    api.push_number(state, @floatFromInt(cbs.get_pane_y(cbs.app, pane_id)));
    return 1;
}

fn l_get_pane_width(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_number(state, 0);
        return 1;
    };
    const pane_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    api.push_number(state, @floatFromInt(cbs.get_pane_width(cbs.app, pane_id)));
    return 1;
}

fn l_get_pane_height(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_number(state, 0);
        return 1;
    };
    const pane_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    api.push_number(state, @floatFromInt(cbs.get_pane_height(cbs.app, pane_id)));
    return 1;
}

fn l_get_window_width(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_number(state, 0);
        return 1;
    };
    api.push_number(state, @floatFromInt(cbs.get_window_width(cbs.app)));
    return 1;
}

fn l_get_window_height(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_number(state, 0);
        return 1;
    };
    api.push_number(state, @floatFromInt(cbs.get_window_height(cbs.app)));
    return 1;
}

fn l_now_ms(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_number(state, 0);
        return 1;
    };
    api.push_number(state, @floatFromInt(cbs.now_ms(cbs.app)));
    return 1;
}

fn l_pane_is_floating(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_boolean(state, 0);
        return 1;
    };
    const pane_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    api.push_boolean(state, if (cbs.pane_is_floating(cbs.app, pane_id)) 1 else 0);
    return 1;
}

fn l_pane_is_maximized(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_boolean(state, 0);
        return 1;
    };
    const pane_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    api.push_boolean(state, if (cbs.pane_is_maximized(cbs.app, pane_id)) 1 else 0);
    return 1;
}

fn l_pane_is_focused(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_boolean(state, 0);
        return 1;
    };
    const pane_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    api.push_boolean(state, if (cbs.pane_is_focused(cbs.app, pane_id)) 1 else 0);
    return 1;
}

fn l_pane_exists(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_boolean(state, 0);
        return 1;
    };
    const pane_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    api.push_boolean(state, if (cbs.pane_exists(cbs.app, pane_id)) 1 else 0);
    return 1;
}

fn l_switch_tab_by_id(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_boolean(state, 0);
        return 1;
    };
    const tab_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    api.push_boolean(state, if (cbs.switch_tab_by_id(cbs.app, tab_id)) 1 else 0);
    return 1;
}

fn l_close_tab_by_id(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_boolean(state, 0);
        return 1;
    };
    const tab_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    api.push_boolean(state, if (cbs.close_tab_by_id(cbs.app, tab_id)) 1 else 0);
    return 1;
}

fn l_send_text_to_pane(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_boolean(state, 0);
        return 1;
    };
    const pane_id: usize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @as(usize, @intFromFloat(api.to_number(state, 1)))
    else
        0;
    var len: usize = 0;
    const ptr = if (@as(LuaType, @enumFromInt(api.value_type(state, 2))) == .string)
        api.to_lstring(state, 2, &len)
    else
        null;
    const text: []const u8 = if (ptr) |p| p[0..len] else "";
    api.push_boolean(state, if (cbs.send_text_to_pane(cbs.app, pane_id, text)) 1 else 0);
    return 1;
}

fn l_send_text(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_boolean(state, 0);
        return 1;
    };
    var len: usize = 0;
    const ptr = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .string)
        api.to_lstring(state, 1, &len)
    else
        null;
    const text: []const u8 = if (ptr) |p| p[0..len] else "";
    api.push_boolean(state, if (cbs.send_text_to_pane(cbs.app, cbs.get_current_pane_id(cbs.app), text)) 1 else 0);
    return 1;
}

fn l_reload_config(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse {
        api.push_boolean(state, 0);
        return 1;
    };
    api.push_boolean(state, if (cbs.reload_config(cbs.app)) 1 else 0);
    return 1;
}

fn l_copy_selection(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    if (ctx.app_callbacks) |cbs| cbs.copy_selection(cbs.app);
    return 0;
}

fn l_paste_clipboard(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    if (ctx.app_callbacks) |cbs| cbs.paste_clipboard(cbs.app);
    return 0;
}

fn l_scroll_active(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse return 0;
    const delta: isize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @intFromFloat(api.to_number(state, 1))
    else
        0;
    cbs.scroll_active(cbs.app, delta);
    return 0;
}

fn l_scroll_active_page(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;
    const cbs = ctx.app_callbacks orelse return 0;
    const pages: isize = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .number)
        @intFromFloat(api.to_number(state, 1))
    else
        0;
    cbs.scroll_active_page(cbs.app, pages);
    return 0;
}

fn l_scroll_active_top(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    if (ctx.app_callbacks) |cbs| cbs.scroll_active_top(cbs.app);
    return 0;
}

fn l_scroll_active_bottom(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    if (ctx.app_callbacks) |cbs| cbs.scroll_active_bottom(cbs.app);
    return 0;
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

/// hollow.get_system_metrics() → table with CPU/GPU/memory stats
fn l_get_system_metrics(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;

    api.create_table(state, 0, 12);

    const metrics = platform.getSystemMetrics(ctx.cfg.allocator) catch {
        api.push_string(state, "error");
        api.set_field(state, -2, "error");
        return 1;
    };

    api.push_number(state, metrics.cpu_usage);
    api.set_field(state, -2, "cpu_usage");

    api.push_number(state, @floatFromInt(metrics.memory_used_mb));
    api.set_field(state, -2, "memory_used_mb");

    api.push_number(state, @floatFromInt(metrics.memory_total_mb));
    api.set_field(state, -2, "memory_total_mb");

    api.push_number(state, metrics.gpu_usage);
    api.set_field(state, -2, "gpu_usage");

    api.push_number(state, @floatFromInt(metrics.gpu_memory_used_mb));
    api.set_field(state, -2, "gpu_memory_used_mb");

    api.push_number(state, @floatFromInt(metrics.gpu_memory_total_mb));
    api.set_field(state, -2, "gpu_memory_total_mb");

    return 1;
}
