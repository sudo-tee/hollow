const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const platform = @import("../platform.zig");
const ghostty = @import("../term/ghostty.zig");
const bar = @import("../ui/bar.zig");

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
    push_value: *const fn (*State, c_int) callconv(.c) void,
    push_cclosure: *const fn (*State, *const fn (*State) callconv(.c) c_int, c_int) callconv(.c) void,
    push_integer: *const fn (*State, isize) callconv(.c) void,
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
    new_workspace: *const fn (app: *anyopaque) void,
    next_workspace: *const fn (app: *anyopaque) void,
    prev_workspace: *const fn (app: *anyopaque) void,
    switch_workspace: *const fn (app: *anyopaque, index: usize) void,
    focus_pane: *const fn (app: *anyopaque, direction: []const u8) void,
    resize_pane: *const fn (app: *anyopaque, direction: []const u8, delta: f32) void,
    switch_tab: *const fn (app: *anyopaque, index: usize) void,
    set_workspace_name: *const fn (app: *anyopaque, title: []const u8) void,
    set_tab_title: *const fn (app: *anyopaque, title: []const u8) void,
    get_tab_count: *const fn (app: *anyopaque) usize,
    get_active_tab_index: *const fn (app: *anyopaque) usize,
    get_workspace_count: *const fn (app: *anyopaque) usize,
    get_active_workspace_index: *const fn (app: *anyopaque) usize,
    get_workspace_name: *const fn (app: *anyopaque, index: usize, out_buf: []u8) []const u8,
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
            .push_value = lookup(&lib, *const fn (*State, c_int) callconv(.c) void, "lua_pushvalue"),
            .push_cclosure = lookup(&lib, *const fn (*State, *const fn (*State) callconv(.c) c_int, c_int) callconv(.c) void, "lua_pushcclosure"),
            .push_integer = lookup(&lib, *const fn (*State, isize) callconv(.c) void, "lua_pushinteger"),
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
        if (self.context.pending_workspace_name) |name| self.allocator.free(name);
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
        if (self.context.pending_workspace_name) |name| {
            callbacks.set_workspace_name(callbacks.app, name);
            self.allocator.free(name);
            self.context.pending_workspace_name = null;
        }
    }

    pub fn fireGuiReady(self: *Runtime) void {
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

    pub fn resolveTopBarTitle(self: *Runtime, index: usize, is_active: bool, hover_close: bool, fallback: []const u8, out_buf: []u8) bar.Segment {
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
        api.push_boolean(self.state, if (hover_close) 1 else 0);

        const zfallback = std.heap.page_allocator.dupeZ(u8, fallback) catch {
            pop(api, self.state, 1);
            return segment;
        };
        defer std.heap.page_allocator.free(zfallback);
        api.push_string(self.state, zfallback);

        const rc = api.pcall(self.state, 4, 1, 0);
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
        return self.context.top_bar_ref != LUA_NOREF;
    }

    pub fn hasWorkspaceTitleFormatter(self: *Runtime) bool {
        return self.context.workspace_title_ref != LUA_NOREF;
    }

    pub fn resolveTopBarStatus(self: *Runtime, side: bar.Side, seg_buf: []bar.Segment, text_buf: []u8, active_tab_index: usize, tab_count: usize) []bar.Segment {
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

fn l_strftime(state: *State) callconv(.c) c_int {
    const ctx = bridgeContext(state);
    const api = ctx.api;

    var fmt_len: usize = 0;
    const fmt_ptr = if (@as(LuaType, @enumFromInt(api.value_type(state, 1))) == .string)
        api.to_lstring(state, 1, &fmt_len)
    else
        null;
    const fmt = if (fmt_ptr) |p| p[0..fmt_len] else "%B %e, %H:%M";

    const now = std.time.timestamp();
    const secs: i64 = @intCast(now);
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const day = epoch.getEpochDay();
    const day_secs = epoch.getDaySeconds();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

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
            'H' => w.print("{d:0>2}", .{day_secs.getHoursIntoDay()}) catch break,
            'M' => w.print("{d:0>2}", .{day_secs.getMinutesIntoHour()}) catch break,
            'e' => w.print("{d}", .{month_day.day_index + 1}) catch break,
            'B' => w.writeAll(monthName(month_day.month.numeric())) catch break,
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

fn monthName(month: u4) []const u8 {
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
    if (std.mem.eql(u8, key, "ghostty_library")) return cfg.setGhosttyLibrary(value);
    if (std.mem.eql(u8, key, "luajit_library")) return cfg.setLuajitLibrary(value);
    if (std.mem.eql(u8, key, "window_title")) return cfg.setWindowTitle(value);
    if (std.mem.eql(u8, key, "lib_dir")) return cfg.setLibDir(value);
    if (std.mem.eql(u8, key, "font_path")) return cfg.setFontRegular(value);
    if (std.mem.eql(u8, key, "font_bold_path")) return cfg.setFontBold(value);
    if (std.mem.eql(u8, key, "font_italic_path")) return cfg.setFontItalic(value);
    if (std.mem.eql(u8, key, "font_bold_italic_path")) return cfg.setFontBoldItalic(value);
    if (std.mem.eql(u8, key, "font_smoothing")) return cfg.setFontSmoothing(value);
    if (std.mem.eql(u8, key, "font_hinting")) return cfg.setFontHinting(value);
}

fn applyNumber(cfg: *config.Config, key: []const u8, value: f64) !void {
    if (std.mem.eql(u8, key, "font_size")) {
        cfg.fonts.size = @floatCast(value);
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
        cfg.scrollback = try asInt(u32, value);
        return;
    }

    if (std.mem.eql(u8, key, "top_bar_height")) {
        cfg.top_bar_height = try asInt(u32, value);
        return;
    }

    if (std.mem.eql(u8, key, "scroll_multiplier")) {
        cfg.scroll_multiplier = @floatCast(value);
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
    return false;
}

fn parseColorField(api: Api, state: *State, table_idx: c_int, field: [*:0]const u8) ?ghostty.ColorRgb {
    api.get_field(state, table_idx, field);
    defer pop(api, state, 1);
    if (@as(LuaType, @enumFromInt(api.value_type(state, -1))) != .string) return null;
    var len: usize = 0;
    const ptr = api.to_lstring(state, -1, &len) orelse return null;
    return parseHexColor(ptr[0..len]);
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

fn pop(api: Api, state: *State, count: c_int) void {
    api.set_top(state, -count - 1);
}

fn absoluteIndex(api: Api, state: *State, idx: c_int) c_int {
    if (idx > 0 or idx <= LUA_REGISTRYINDEX) return idx;
    return api.get_top(state) + idx + 1;
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

/// hollow.on_top_bar(fn(index, is_active, hover_close, fallback_title) -> string|nil)
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
