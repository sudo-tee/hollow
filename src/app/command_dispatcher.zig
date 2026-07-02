const std = @import("std");
const builtin = @import("builtin");
const command_ipc = @import("../ipc.zig");
const command_mod = @import("../command.zig");
const mux_mod = @import("../mux.zig");
const SplitDirection = mux_mod.SplitDirection;
const FocusDirection = mux_mod.FocusDirection;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const htp = @import("htp.zig");
const SplitCommandMode = app_mod.SplitCommandMode;
const mux_ops = @import("mux_ops.zig");

const LUA_NOREF: c_int = -1;

const libc = if (builtin.os.tag == .windows) void else @cImport({
    @cInclude("stdlib.h");
});

const win32_env = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) i32;
} else struct {};

pub const PaneTagEntry = struct {
    pane_id: usize,
    tags: std.StringArrayHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *PaneTagEntry, allocator: std.mem.Allocator) void {
        var it = self.tags.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.tags.deinit(allocator);
    }
};

pub const PendingCommandRequest = struct {
    request: command_mod.Request,
    response: ?command_mod.Response = null,
    done: bool = false,
};

pub const CommandExecutionMode = enum {
    sync,
    deferred,
};

fn setProcessEnvVar(name: []const u8, value: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const name_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, name);
        defer std.heap.page_allocator.free(name_w);
        const value_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, value);
        defer std.heap.page_allocator.free(value_w);
        if (win32_env.SetEnvironmentVariableW(name_w.ptr, value_w.ptr) == 0) return error.SetEnvironmentVariableFailed;
        return;
    }

    const name_z = try std.heap.page_allocator.dupeZ(u8, name);
    defer std.heap.page_allocator.free(name_z);
    const value_z = try std.heap.page_allocator.dupeZ(u8, value);
    defer std.heap.page_allocator.free(value_z);
    if (libc.setenv(name_z.ptr, value_z.ptr, 1) != 0) return error.SetEnvironmentVariableFailed;
}

fn unsetProcessEnvVar(name: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const name_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, name);
        defer std.heap.page_allocator.free(name_w);
        if (win32_env.SetEnvironmentVariableW(name_w.ptr, null) == 0) return error.SetEnvironmentVariableFailed;
        return;
    }

    const name_z = try std.heap.page_allocator.dupeZ(u8, name);
    defer std.heap.page_allocator.free(name_z);
    if (libc.unsetenv(name_z.ptr) != 0) return error.SetEnvironmentVariableFailed;
}

fn sortStringsAsc(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn appendOwnedJsonString(array: *std.json.Array, allocator: std.mem.Allocator, value: []const u8) !void {
    try array.append(.{ .string = try allocator.dupe(u8, value) });
}

pub fn parseFocusDirection(direction: []const u8) ?FocusDirection {
    if (std.mem.eql(u8, direction, "left")) return .left;
    if (std.mem.eql(u8, direction, "right")) return .right;
    if (std.mem.eql(u8, direction, "up")) return .up;
    if (std.mem.eql(u8, direction, "down")) return .down;
    return null;
}

pub fn parseSplitDirection(direction: []const u8) ?SplitDirection {
    if (std.mem.eql(u8, direction, "vertical") or std.mem.eql(u8, direction, "horizontal")) {
        return if (std.mem.eql(u8, direction, "horizontal")) .horizontal else .vertical;
    }
    if (std.mem.eql(u8, direction, "left") or std.mem.eql(u8, direction, "right")) return .horizontal;
    if (std.mem.eql(u8, direction, "up") or std.mem.eql(u8, direction, "down")) return .vertical;
    return null;
}

fn okNull() command_mod.Response {
    return .ok(null);
}

pub fn startCommandTransport(self: *App) void {
    if (self.command_ipc_server != null) return;
    self.command_ipc_server = command_ipc.Server.init(self.allocator, self, commandIpcHandler);
    self.command_ipc_server.?.start() catch |err| {
        std.log.warn("command-ipc: failed to start: {s}", .{@errorName(err)});
        self.command_ipc_server.?.deinit();
        self.command_ipc_server = null;
        return;
    };
    if (self.command_ipc_server.?.address()) |addr| {
        std.log.info("command-ipc: listening on {s}", .{addr});
        setProcessEnvVar(command_ipc.EnvVar, addr) catch |err| {
            std.log.warn("command-ipc: failed to export {s}: {s}", .{ command_ipc.EnvVar, @errorName(err) });
        };
    }
    syncCommandTimingEnv(self);
}

pub fn syncCommandTimingEnv(self: *App) void {
    if (self.config.command_timing) {
        std.log.info("command-ipc: command_timing enabled", .{});
        setProcessEnvVar(command_ipc.TimingEnvVar, "1") catch |err| {
            std.log.warn("command-ipc: failed to export {s}: {s}", .{ command_ipc.TimingEnvVar, @errorName(err) });
        };
        return;
    }

    std.log.info("command-ipc: command_timing disabled", .{});
    unsetProcessEnvVar(command_ipc.TimingEnvVar) catch |err| {
        std.log.warn("command-ipc: failed to clear {s}: {s}", .{ command_ipc.TimingEnvVar, @errorName(err) });
    };
}

pub fn drainPendingCommand(self: *App) void {
    self.command_mutex.lock();
    defer self.command_mutex.unlock();

    const pending = self.pending_command orelse return;
    if (pending.done) return;

    const timing_enabled = self.config.command_timing;
    const start_ns = if (timing_enabled) std.time.nanoTimestamp() else 0;
    pending.response = switch (commandExecutionMode(pending.request.kind)) {
        .sync => executeCommand(self, pending.request) catch |err| command_mod.Response.fail("internal", @errorName(err)),
        .deferred => enqueueDeferredCommand(self, pending.request),
    };
    if (timing_enabled) {
        std.log.info("command-ipc: dispatch_ms={d:.3} kind={s}", .{ elapsedMs(start_ns), @tagName(pending.request.kind) });
    }
    pending.done = true;
    self.command_done.signal();
}

pub fn runCommandSync(self: *App, request: command_mod.Request) command_mod.Response {
    var pending = PendingCommandRequest{ .request = request };

    self.command_mutex.lock();
    defer self.command_mutex.unlock();

    while (self.pending_command != null) {
        self.command_done.wait(&self.command_mutex);
    }

    self.pending_command = &pending;
    self.signalWake();
    self.command_ready.signal();

    while (!pending.done) {
        self.command_done.wait(&self.command_mutex);
    }

    self.pending_command = null;
    self.command_done.broadcast();
    return pending.response orelse command_mod.Response.fail("internal", "missing command response");
}

pub fn hasPendingCommand(self: *App) bool {
    self.command_mutex.lock();
    defer self.command_mutex.unlock();

    const pending = self.pending_command orelse return false;
    return !pending.done;
}

fn elapsedMs(start_ns: i128) f64 {
    return @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
}

fn commandExecutionMode(kind: command_mod.Kind) CommandExecutionMode {
    return switch (kind) {
        .get_pane,
        .get_pane_text,
        .get_current_pane,
        .get_tab,
        .get_current_tab,
        .get_tabs,
        .get_panes,
        .get_workspace,
        .get_current_workspace,
        .get_workspaces,
        .get_domain,
        .get_htp,
            => .sync,
        else => .deferred,
    };
}

fn enqueueDeferredCommand(self: *App, request: command_mod.Request) command_mod.Response {
    switch (request.kind) {
        .workspace_new => return enqueueWorkspaceNewCommand(self, request),
        .workspace_close => {
            if (!self.enqueueMouse(.{ .close_workspace = request.id })) return command_mod.Response.fail("error", "command queue full");
            return okNull();
        },
        .workspace_next => {
            if (!self.enqueueMouse(.next_workspace)) return command_mod.Response.fail("error", "command queue full");
            return okNull();
        },
        .workspace_prev => {
            if (!self.enqueueMouse(.prev_workspace)) return command_mod.Response.fail("error", "command queue full");
            return okNull();
        },
        .workspace_select => {
            const index = request.index orelse return command_mod.Response.fail("invalid_args", "missing workspace index");
            if (!self.enqueueMouse(.{ .switch_workspace = index -| 1 })) return command_mod.Response.fail("error", "command queue full");
            return okNull();
        },
        .workspace_rename => return enqueueWorkspaceRenameCommand(self, request),
        .tab_new => return enqueueTabNewCommand(self, request),
        .tab_close => return enqueueTabCloseCommand(self, request),
        .tab_next => {
            if (!self.enqueueMouse(.next_tab)) return command_mod.Response.fail("error", "command queue full");
            return okNull();
        },
        .tab_prev => {
            if (!self.enqueueMouse(.prev_tab)) return command_mod.Response.fail("error", "command queue full");
            return okNull();
        },
        .tab_select => return enqueueTabSelectCommand(self, request),
        .tab_rename => return enqueueCommandRequest(self, request),
        .pane_split => return enqueuePaneSplitCommand(self, request),
        .pane_popup => return enqueuePanePopupCommand(self, request),
        .pane_close => return enqueueCommandRequest(self, request),
        .pane_zoom => return enqueuePaneZoomCommand(self, request),
        .pane_float => return enqueuePaneFloatingCommand(self, request, true),
        .pane_tile => return enqueuePaneFloatingCommand(self, request, false),
        .pane_move => return enqueuePaneMoveCommand(self, request),
        .pane_resize => return enqueuePaneResizeCommand(self, request),
        .pane_send_text, .send_keys => return enqueueCommandRequest(self, request),
        .pane_set_tag => return enqueueCommandRequest(self, request),
        .pane_remove_tag => return enqueueCommandRequest(self, request),
        .pane_set_tags => return enqueueCommandRequest(self, request),
        .focus => return enqueueFocusCommand(self, request),
        .scroll => return enqueueScrollCommand(self, request),
        .config_reload => {
            if (!self.enqueueMouse(.reload_config)) return command_mod.Response.fail("error", "command queue full");
            return okNull();
        },
        .config_theme => return enqueueCommandRequest(self, request),
        .run => return enqueueTabNewCommand(self, request),
        .emit => return enqueueCommandRequest(self, request),
        else => return enqueueCommandRequest(self, request),
    }
}

fn enqueueCommandRequest(self: *App, request: command_mod.Request) command_mod.Response {
    var cloned = cloneCommandRequest(self, request) catch return command_mod.Response.fail("internal", "oom");
    errdefer cloned.deinit(self.allocator);
    if (!self.enqueueMouse(.{ .command_request = cloned })) {
        cloned.deinit(self.allocator);
        return command_mod.Response.fail("error", "command queue full");
    }
    return okNull();
}

fn cloneOwnedOptionalString(self: *App, value: ?[]const u8) !?[]u8 {
    return if (value) |text| try self.allocator.dupe(u8, text) else null;
}

fn cloneOwnedOptionalJson(self: *App, value: ?std.json.Value) !?std.json.Value {
    return if (value) |json| try command_mod.cloneJsonValue(self.allocator, json) else null;
}

fn cloneOwnedOptionalStringSlice(self: *App, value: ?[]const []const u8) !?[]const []const u8 {
    const items = value orelse return null;
    var out = try self.allocator.alloc([]const u8, items.len);
    errdefer {
        for (out[0..items.len]) |item| self.allocator.free(item);
        self.allocator.free(out);
    }
    for (items, 0..) |item, index| {
        out[index] = try self.allocator.dupe(u8, item);
    }
    return out;
}

fn cloneCommandRequest(self: *App, request: command_mod.Request) !command_mod.Request {
    return .{
        .kind = request.kind,
        .pane_id = request.pane_id,
        .id = request.id,
        .index = request.index,
        .name = try cloneOwnedOptionalString(self, request.name),
        .cmd = try cloneOwnedOptionalString(self, request.cmd),
        .cwd = try cloneOwnedOptionalString(self, request.cwd),
        .domain = try cloneOwnedOptionalString(self, request.domain),
        .direction = try cloneOwnedOptionalString(self, request.direction),
        .amount = request.amount,
        .ratio = request.ratio,
        .x = request.x,
        .y = request.y,
        .width = request.width,
        .height = request.height,
        .text = try cloneOwnedOptionalString(self, request.text),
        .tag = try cloneOwnedOptionalString(self, request.tag),
        .tags = try cloneOwnedOptionalStringSlice(self, request.tags),
        .channel = try cloneOwnedOptionalString(self, request.channel),
        .params = try cloneOwnedOptionalJson(self, request.params),
        .payload = try cloneOwnedOptionalJson(self, request.payload),
    };
}

fn enqueueTabNewCommand(self: *App, request: command_mod.Request) command_mod.Response {
    const owned_domain = if (request.domain) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
    errdefer if (owned_domain) |value| self.allocator.free(value);
    const owned_command = if (request.cmd) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
    errdefer if (owned_command) |value| self.allocator.free(value);
    if (!self.enqueueMouse(.{ .new_tab = .{ .domain_name = owned_domain, .command = owned_command, .callback_ref = LUA_NOREF } })) {
        if (owned_command) |value| self.allocator.free(value);
        if (owned_domain) |value| self.allocator.free(value);
        return command_mod.Response.fail("error", "command queue full");
    }
    return okNull();
}

fn enqueueWorkspaceNewCommand(self: *App, request: command_mod.Request) command_mod.Response {
    const owned_cwd = if (request.cwd) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
    errdefer if (owned_cwd) |value| self.allocator.free(value);
    const owned_domain = if (request.domain) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
    errdefer if (owned_domain) |value| self.allocator.free(value);
    const owned_command = if (request.cmd) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
    errdefer if (owned_command) |value| self.allocator.free(value);
    const owned_name = if (request.name) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
    errdefer if (owned_name) |value| self.allocator.free(value);
    if (!self.enqueueMouse(.{ .new_workspace = .{ .cwd = owned_cwd, .domain_name = owned_domain, .command = owned_command, .name = owned_name, .callback_ref = LUA_NOREF, .queued_at_ms = std.time.milliTimestamp() } })) {
        if (owned_name) |value| self.allocator.free(value);
        if (owned_command) |value| self.allocator.free(value);
        if (owned_domain) |value| self.allocator.free(value);
        if (owned_cwd) |value| self.allocator.free(value);
        return command_mod.Response.fail("error", "command queue full");
    }
    return okNull();
}

fn enqueueWorkspaceRenameCommand(self: *App, request: command_mod.Request) command_mod.Response {
    const name = request.name orelse return command_mod.Response.fail("invalid_args", "missing workspace name");
    if (request.id) |workspace_id| {
        const active_id = self.currentWorkspaceIdValue() orelse return command_mod.Response.fail("invalid_args", "no active workspace");
        if (active_id != workspace_id) return command_mod.Response.fail("invalid_args", "workspace rename only supports the active workspace");
    }
    const owned_name = self.allocator.dupe(u8, name) catch return command_mod.Response.fail("internal", "oom");
    if (!self.enqueueMouse(.{ .set_workspace_name = owned_name })) {
        self.allocator.free(owned_name);
        return command_mod.Response.fail("error", "command queue full");
    }
    return okNull();
}

fn enqueueTabCloseCommand(self: *App, request: command_mod.Request) command_mod.Response {
    if (request.id) |tab_id| {
        const index = mux_ops.tabIndexById(self, tab_id) orelse return command_mod.Response.fail("invalid_args", "unknown tab id");
        if (!self.enqueueMouse(.{ .close_tab_at = index })) return command_mod.Response.fail("error", "command queue full");
        return okNull();
    }
    if (!self.enqueueMouse(.close_tab)) return command_mod.Response.fail("error", "command queue full");
    return okNull();
}

fn enqueueTabSelectCommand(self: *App, request: command_mod.Request) command_mod.Response {
    const tab_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing tab id");
    const index = mux_ops.tabIndexById(self, tab_id) orelse return command_mod.Response.fail("invalid_args", "unknown tab id");
    if (!self.enqueueMouse(.{ .switch_tab = index })) return command_mod.Response.fail("error", "command queue full");
    return okNull();
}

fn enqueuePaneSplitCommand(self: *App, request: command_mod.Request) command_mod.Response {
    const direction_text = request.direction orelse return command_mod.Response.fail("invalid_args", "missing pane direction");
    const direction = parseSplitDirection(direction_text) orelse return command_mod.Response.fail("invalid_args", "invalid pane direction");
    const owned_domain = if (request.domain) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
    errdefer if (owned_domain) |value| self.allocator.free(value);
    const owned_cwd = if (request.cwd) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
    errdefer if (owned_cwd) |value| self.allocator.free(value);
    const owned_command = if (request.cmd) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
    errdefer if (owned_command) |value| self.allocator.free(value);
    if (!self.enqueueMouse(.{ .split_pane = .{
        .direction = direction,
        .ratio = @floatCast(request.ratio orelse 0.5),
        .domain_name = owned_domain,
        .cwd = owned_cwd,
        .command = owned_command,
        .command_mode = .spawn,
        .close_on_exit = false,
        .floating = false,
        .fullscreen = false,
        .x = null,
        .y = null,
        .width = null,
        .height = null,
        .callback_ref = LUA_NOREF,
    } })) {
        if (owned_command) |value| self.allocator.free(value);
        if (owned_cwd) |value| self.allocator.free(value);
        if (owned_domain) |value| self.allocator.free(value);
        return command_mod.Response.fail("error", "command queue full");
    }
    return okNull();
}

fn enqueuePanePopupCommand(self: *App, request: command_mod.Request) command_mod.Response {
    const cmd = request.cmd orelse return command_mod.Response.fail("invalid_args", "missing popup command");
    const owned_domain = if (request.domain) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
    errdefer if (owned_domain) |value| self.allocator.free(value);
    const owned_cwd = if (request.cwd) |value| self.allocator.dupe(u8, value) catch return command_mod.Response.fail("internal", "oom") else null;
    errdefer if (owned_cwd) |value| self.allocator.free(value);
    const owned_command = self.allocator.dupe(u8, cmd) catch return command_mod.Response.fail("internal", "oom");
    errdefer self.allocator.free(owned_command);
    if (!self.enqueueMouse(.{ .split_pane = .{
        .direction = .vertical,
        .ratio = 0.5,
        .domain_name = owned_domain,
        .cwd = owned_cwd,
        .command = owned_command,
        .command_mode = .spawn,
        .close_on_exit = false,
        .floating = true,
        .fullscreen = false,
        .x = if (request.x) |value| @floatCast(value) else null,
        .y = if (request.y) |value| @floatCast(value) else null,
        .width = if (request.width) |value| @floatCast(value) else null,
        .height = if (request.height) |value| @floatCast(value) else null,
        .callback_ref = LUA_NOREF,
    } })) {
        self.allocator.free(owned_command);
        if (owned_cwd) |value| self.allocator.free(value);
        if (owned_domain) |value| self.allocator.free(value);
        return command_mod.Response.fail("error", "command queue full");
    }
    return okNull();
}

fn enqueuePaneZoomCommand(self: *App, request: command_mod.Request) command_mod.Response {
    const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
    if (!self.enqueueMouse(.{ .toggle_pane_maximized = .{ .pane_id = pane_id, .show_background = false } })) return command_mod.Response.fail("error", "command queue full");
    return okNull();
}

fn enqueuePaneFloatingCommand(self: *App, request: command_mod.Request, floating: bool) command_mod.Response {
    const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
    if (!self.enqueueMouse(.{ .set_pane_floating = .{ .pane_id = pane_id, .floating = floating } })) return command_mod.Response.fail("error", "command queue full");
    return okNull();
}

fn enqueuePaneMoveCommand(self: *App, request: command_mod.Request) command_mod.Response {
    const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
    const direction = request.direction orelse return command_mod.Response.fail("invalid_args", "missing pane direction");
    const focus_direction = parseFocusDirection(direction) orelse return command_mod.Response.fail("invalid_args", "invalid pane direction");
    if (!self.enqueueMouse(.{ .move_pane = .{ .pane_id = pane_id, .direction = focus_direction, .amount = @floatCast(request.amount orelse 0.08) } })) return command_mod.Response.fail("error", "command queue full");
    return okNull();
}

fn enqueuePaneResizeCommand(self: *App, request: command_mod.Request) command_mod.Response {
    const direction = request.direction orelse return command_mod.Response.fail("invalid_args", "missing pane direction");
    const split_direction = parseSplitDirection(direction) orelse return command_mod.Response.fail("invalid_args", "invalid pane direction");
    const amount = @as(f32, @floatCast(request.amount orelse 0));
    const delta: f32 = if (std.mem.eql(u8, direction, "left") or std.mem.eql(u8, direction, "up")) -@abs(amount) else @abs(amount);
    if (!self.enqueueMouse(.{ .resize_pane = .{ .direction = split_direction, .delta = delta } })) return command_mod.Response.fail("error", "command queue full");
    return okNull();
}

fn enqueueFocusCommand(self: *App, request: command_mod.Request) command_mod.Response {
    const direction = request.direction orelse return command_mod.Response.fail("invalid_args", "missing focus direction");
    const focus_direction = parseFocusDirection(direction) orelse return command_mod.Response.fail("invalid_args", "invalid focus direction");
    if (!self.enqueueMouse(.{ .focus_pane = focus_direction })) return command_mod.Response.fail("error", "command queue full");
    return okNull();
}

fn enqueueScrollCommand(self: *App, request: command_mod.Request) command_mod.Response {
    const target = request.direction orelse return command_mod.Response.fail("invalid_args", "missing scroll target");
    if (std.mem.eql(u8, target, "top")) {
        if (!self.enqueueMouse(.scroll_active_top)) return command_mod.Response.fail("error", "command queue full");
    } else if (std.mem.eql(u8, target, "bottom")) {
        if (!self.enqueueMouse(.scroll_active_bottom)) return command_mod.Response.fail("error", "command queue full");
    } else if (std.mem.eql(u8, target, "page-up")) {
        if (!self.enqueueMouse(.{ .scroll_active_page = -1 })) return command_mod.Response.fail("error", "command queue full");
    } else if (std.mem.eql(u8, target, "page-down")) {
        if (!self.enqueueMouse(.{ .scroll_active_page = 1 })) return command_mod.Response.fail("error", "command queue full");
    } else {
        return command_mod.Response.fail("invalid_args", "invalid scroll target");
    }
    return okNull();
}

pub fn findPaneTagEntry(self: *App, pane_id: usize) ?*PaneTagEntry {
    for (self.pane_tags.items) |*entry| {
        if (entry.pane_id == pane_id) return entry;
    }
    return null;
}

fn ensurePaneTagEntry(self: *App, pane_id: usize) !*PaneTagEntry {
    if (findPaneTagEntry(self, pane_id)) |entry| return entry;
    try self.pane_tags.append(self.allocator, .{ .pane_id = pane_id });
    return &self.pane_tags.items[self.pane_tags.items.len - 1];
}

fn normalizePaneTag(tag: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, tag, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

pub fn getPaneTags(self: *App, pane_id: usize) !std.json.Value {
    var array = std.json.Array.init(self.allocator);
    errdefer {
        for (array.items) |item| app_mod.deinitJsonValue(self.allocator, item);
        array.deinit();
    }

    const entry = findPaneTagEntry(self, pane_id) orelse return .{ .array = array };
    var tags: std.ArrayListUnmanaged([]const u8) = .empty;
    defer tags.deinit(self.allocator);

    var it = entry.tags.iterator();
    while (it.next()) |item| try tags.append(self.allocator, item.key_ptr.*);
    std.mem.sort([]const u8, tags.items, {}, sortStringsAsc);
    for (tags.items) |tag| try appendOwnedJsonString(&array, self.allocator, tag);
    return .{ .array = array };
}

pub fn setPaneTags(self: *App, pane_id: usize, tags: []const []const u8) !void {
    const entry = try ensurePaneTagEntry(self, pane_id);
    entry.deinit(self.allocator);
    entry.* = .{ .pane_id = pane_id };

    for (tags) |tag| {
        const normalized = normalizePaneTag(tag) orelse continue;
        const gop = try entry.tags.getOrPut(self.allocator, normalized);
        if (!gop.found_existing) gop.key_ptr.* = try self.allocator.dupe(u8, normalized);
    }

    if (entry.tags.count() == 0) clearPaneTags(self, pane_id);
}

pub fn addPaneTag(self: *App, pane_id: usize, tag: []const u8) !void {
    const normalized = normalizePaneTag(tag) orelse return;
    const entry = try ensurePaneTagEntry(self, pane_id);
    const gop = try entry.tags.getOrPut(self.allocator, normalized);
    if (!gop.found_existing) gop.key_ptr.* = try self.allocator.dupe(u8, normalized);
}

pub fn removePaneTag(self: *App, pane_id: usize, tag: []const u8) void {
    const normalized = normalizePaneTag(tag) orelse return;
    const entry = findPaneTagEntry(self, pane_id) orelse return;
    const removed = entry.tags.fetchSwapRemove(normalized) orelse return;
    self.allocator.free(removed.key);
    if (entry.tags.count() == 0) clearPaneTags(self, pane_id);
}

pub fn clearPaneTags(self: *App, pane_id: usize) void {
    var index: usize = 0;
    while (index < self.pane_tags.items.len) : (index += 1) {
        if (self.pane_tags.items[index].pane_id != pane_id) continue;
        self.pane_tags.items[index].deinit(self.allocator);
        _ = self.pane_tags.swapRemove(index);
        return;
    }
}

pub fn deinitPaneTags(self: *App) void {
    for (self.pane_tags.items) |*entry| entry.deinit(self.allocator);
    self.pane_tags.deinit(self.allocator);
}

pub fn executeCommand(self: *App, request: command_mod.Request) !command_mod.Response {
    return switch (request.kind) {
        .get_pane => .ok(try self.snapshotPaneValue(request.id orelse request.pane_id)),
        .get_pane_text => .ok(try self.paneTextValue(request.id orelse request.pane_id)),
        .get_current_pane => .ok(try self.currentPaneValue()),
        .get_tab => .ok(try self.snapshotTabValue(request.id)),
        .get_current_tab => .ok(try self.currentTabValue()),
        .get_tabs => .ok(try self.tabsValue()),
        .get_panes => .ok(try self.panesValue(request.tag)),
        .get_workspace => .ok(try self.snapshotWorkspaceValue(request.id)),
        .get_current_workspace => .ok(try self.currentWorkspaceValue()),
        .get_workspaces => .ok(try self.workspacesValue()),
        .get_domain => .ok(try self.currentDomainValue()),
        .workspace_new => execWorkspaceNew(self, request),
        .workspace_close => execWorkspaceClose(self, request),
        .workspace_next => execWorkspaceNext(self),
        .workspace_prev => execWorkspacePrev(self),
        .workspace_select => execWorkspaceSelect(self, request),
        .workspace_rename => execWorkspaceRename(self, request),
        .tab_new => execTabNew(self, request),
        .tab_close => execTabClose(self, request),
        .tab_next => execTabNext(self),
        .tab_prev => execTabPrev(self),
        .tab_select => execTabSelect(self, request),
        .tab_rename => execTabRename(self, request),
        .pane_split => execPaneSplit(self, request),
        .pane_popup => execPanePopup(self, request),
        .pane_close => execPaneClose(self, request),
        .pane_zoom => execPaneZoom(self, request),
        .pane_float => execPaneFloating(self, request, true),
        .pane_tile => execPaneFloating(self, request, false),
        .pane_move => execPaneMove(self, request),
        .pane_resize => execPaneResize(self, request),
        .pane_send_text, .send_keys => execPaneSendText(self, request),
        .pane_set_tag => execPaneSetTag(self, request),
        .pane_remove_tag => execPaneRemoveTag(self, request),
        .pane_set_tags => execPaneSetTags(self, request),
        .focus => execFocus(self, request),
        .scroll => execScroll(self, request),
        .get_htp => execGetHtp(self, request),
        .config_reload => execConfigReload(self),
        .config_theme => execConfigTheme(self, request),
        .run => execRun(self, request),
        .emit => execEmit(self, request),
    };
}

fn commandIpcHandler(app_ptr: *anyopaque, request: command_mod.Request) command_mod.Response {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return runCommandSync(app, request);
}

fn execWorkspaceNew(self: *App, request: command_mod.Request) command_mod.Response {
    mux_ops.newWorkspace(self, request.cwd, request.domain, request.cmd, request.name, LUA_NOREF);
    return okNull();
}

fn execWorkspaceClose(self: *App, request: command_mod.Request) command_mod.Response {
    mux_ops.closeWorkspace(self, request.id);
    return okNull();
}

fn execWorkspaceNext(self: *App) command_mod.Response {
    mux_ops.nextWorkspace(self, );
    return okNull();
}

fn execWorkspacePrev(self: *App) command_mod.Response {
    mux_ops.prevWorkspace(self, );
    return okNull();
}

fn execWorkspaceSelect(self: *App, request: command_mod.Request) command_mod.Response {
    const index = request.index orelse return command_mod.Response.fail("invalid_args", "missing workspace index");
    mux_ops.switchWorkspace(self, index -| 1);
    return okNull();
}

fn execWorkspaceRename(self: *App, request: command_mod.Request) command_mod.Response {
    const name = request.name orelse return command_mod.Response.fail("invalid_args", "missing workspace name");
    if (request.id) |workspace_id| {
        const active_id = self.currentWorkspaceIdValue() orelse return command_mod.Response.fail("invalid_args", "no active workspace");
        if (active_id != workspace_id) return command_mod.Response.fail("invalid_args", "workspace rename only supports the active workspace");
    }
    mux_ops.setWorkspaceName(self, name);
    return okNull();
}

fn execTabNew(self: *App, request: command_mod.Request) command_mod.Response {
    mux_ops.newTab(self, request.domain, request.cmd, LUA_NOREF);
    return okNull();
}

fn execTabClose(self: *App, request: command_mod.Request) command_mod.Response {
    if (request.id) |tab_id| {
        const index = mux_ops.tabIndexById(self, tab_id) orelse return command_mod.Response.fail("invalid_args", "unknown tab id");
        mux_ops.closeTabAt(self, index);
    } else {
        mux_ops.closeTab(self, );
    }
    return okNull();
}

fn execTabNext(self: *App) command_mod.Response {
    mux_ops.nextTab(self, );
    return okNull();
}

fn execTabPrev(self: *App) command_mod.Response {
    mux_ops.prevTab(self, );
    return okNull();
}

fn execTabSelect(self: *App, request: command_mod.Request) command_mod.Response {
    const tab_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing tab id");
    const index = mux_ops.tabIndexById(self, tab_id) orelse return command_mod.Response.fail("invalid_args", "unknown tab id");
    mux_ops.switchTab(self, index);
    return okNull();
}

fn execTabRename(self: *App, request: command_mod.Request) command_mod.Response {
    const title = request.name orelse return command_mod.Response.fail("invalid_args", "missing tab title");
    const tab_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing tab id");
    if (!mux_ops.setTabTitleById(self, tab_id, title)) return command_mod.Response.fail("invalid_args", "unknown tab id");
    return okNull();
}

fn execPaneClose(self: *App, request: command_mod.Request) command_mod.Response {
    const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
    mux_ops.closePaneById(self, pane_id);
    clearPaneTags(self, pane_id);
    return okNull();
}

fn execPaneSplit(self: *App, request: command_mod.Request) command_mod.Response {
    const direction_text = request.direction orelse return command_mod.Response.fail("invalid_args", "missing pane direction");
    const direction = parseSplitDirection(direction_text) orelse return command_mod.Response.fail("invalid_args", "invalid pane direction");
    mux_ops.splitPane(self, 
        direction,
        @floatCast(request.ratio orelse 0.5),
        request.domain,
        request.cwd,
        request.cmd,
        .spawn,
        false,
        false,
        false,
        null,
        null,
        null,
        null,
        LUA_NOREF,
    );
    return okNull();
}

fn execPanePopup(self: *App, request: command_mod.Request) command_mod.Response {
    const cmd = request.cmd orelse return command_mod.Response.fail("invalid_args", "missing popup command");
    mux_ops.splitPane(self, 
        .vertical,
        0.5,
        request.domain,
        request.cwd,
        cmd,
        .spawn,
        false,
        true,
        false,
        if (request.x) |value| @floatCast(value) else null,
        if (request.y) |value| @floatCast(value) else null,
        if (request.width) |value| @floatCast(value) else null,
        if (request.height) |value| @floatCast(value) else null,
        LUA_NOREF,
    );
    return okNull();
}

fn execPaneZoom(self: *App, request: command_mod.Request) command_mod.Response {
    const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
    mux_ops.togglePaneMaximizedById(self, pane_id, false);
    return okNull();
}

fn execPaneFloating(self: *App, request: command_mod.Request, floating: bool) command_mod.Response {
    const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
    mux_ops.setPaneFloatingById(self, pane_id, floating);
    return okNull();
}

fn execPaneMove(self: *App, request: command_mod.Request) command_mod.Response {
    const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
    const direction = request.direction orelse return command_mod.Response.fail("invalid_args", "missing pane direction");
    const focus_direction = parseFocusDirection(direction) orelse return command_mod.Response.fail("invalid_args", "invalid pane direction");
    mux_ops.movePaneById(self, pane_id, focus_direction, @floatCast(request.amount orelse 0.08));
    return okNull();
}

fn execPaneResize(self: *App, request: command_mod.Request) command_mod.Response {
    const direction = request.direction orelse return command_mod.Response.fail("invalid_args", "missing pane direction");
    const split_direction = parseSplitDirection(direction) orelse return command_mod.Response.fail("invalid_args", "invalid pane direction");
    const amount = @as(f32, @floatCast(request.amount orelse 0));
    const delta: f32 = if (std.mem.eql(u8, direction, "left") or std.mem.eql(u8, direction, "up")) -@abs(amount) else @abs(amount);
    mux_ops.resizePane(self, split_direction, delta);
    return okNull();
}

fn execPaneSendText(self: *App, request: command_mod.Request) command_mod.Response {
    const text = request.text orelse return command_mod.Response.fail("invalid_args", "missing pane text");
    const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
    if (!mux_ops.sendTextToPane(self, pane_id, text)) return command_mod.Response.fail("invalid_args", "unknown pane id");
    return okNull();
}

fn execPaneSetTag(self: *App, request: command_mod.Request) command_mod.Response {
    const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
    const tag = request.tag orelse return command_mod.Response.fail("invalid_args", "missing pane tag");
    addPaneTag(self, pane_id, tag) catch return command_mod.Response.fail("internal", "failed to add pane tag");
    return okNull();
}

fn execPaneRemoveTag(self: *App, request: command_mod.Request) command_mod.Response {
    const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
    const tag = request.tag orelse return command_mod.Response.fail("invalid_args", "missing pane tag");
    removePaneTag(self, pane_id, tag);
    return okNull();
}

fn execPaneSetTags(self: *App, request: command_mod.Request) command_mod.Response {
    const pane_id = request.id orelse return command_mod.Response.fail("invalid_args", "missing pane id");
    setPaneTags(self, pane_id, request.tags orelse &.{}) catch return command_mod.Response.fail("internal", "failed to set pane tags");
    return okNull();
}

fn execFocus(self: *App, request: command_mod.Request) command_mod.Response {
    const direction = request.direction orelse return command_mod.Response.fail("invalid_args", "missing focus direction");
    const focus_direction = parseFocusDirection(direction) orelse return command_mod.Response.fail("invalid_args", "invalid focus direction");
    mux_ops.focusPane(self, focus_direction);
    return okNull();
}

fn execScroll(self: *App, request: command_mod.Request) command_mod.Response {
    const target = request.direction orelse return command_mod.Response.fail("invalid_args", "missing scroll target");
    if (std.mem.eql(u8, target, "top")) {
        mux_ops.scrollActiveViewportTop(self, );
    } else if (std.mem.eql(u8, target, "bottom")) {
        mux_ops.scrollActiveViewportBottom(self, );
    } else if (std.mem.eql(u8, target, "page-up")) {
        mux_ops.scrollActiveViewportPage(self, -1);
    } else if (std.mem.eql(u8, target, "page-down")) {
        mux_ops.scrollActiveViewportPage(self, 1);
    } else {
        return command_mod.Response.fail("invalid_args", "invalid scroll target");
    }
    return okNull();
}

fn execConfigReload(self: *App) command_mod.Response {
    if (!self.reloadConfig()) return command_mod.Response.fail("error", "reload_config failed");
    return okNull();
}

fn execConfigTheme(self: *App, request: command_mod.Request) command_mod.Response {
    const name = request.name orelse return command_mod.Response.fail("invalid_args", "missing theme name");
    const theme_payload = std.json.Value{ .object = blk: {
        var object = std.json.ObjectMap.init(self.allocator);
        errdefer app_mod.deinitJsonValue(self.allocator, .{ .object = object });
        object.put(self.allocator.dupe(u8, "name") catch return command_mod.Response.fail("internal", "oom"), .{ .string = self.allocator.dupe(u8, name) catch return command_mod.Response.fail("internal", "oom") }) catch return command_mod.Response.fail("internal", "oom");
        break :blk object;
    } };
    defer app_mod.deinitJsonValue(self.allocator, theme_payload);

    const result = htp.dispatchHtpEventSync(self, self.currentPaneIdValue(), "set_theme", theme_payload) catch |err| {
        return command_mod.Response.fail("internal", @errorName(err));
    };
    defer result.deinit(self.allocator);
    if (!result.success) return command_mod.Response.fail("error", result.error_message orelse "set_theme failed");
    return okNull();
}

fn execRun(self: *App, request: command_mod.Request) command_mod.Response {
    mux_ops.newTab(self, request.domain, request.cmd, LUA_NOREF);
    return okNull();
}

fn execGetHtp(self: *App, request: command_mod.Request) command_mod.Response {
    const channel = request.channel orelse return command_mod.Response.fail("invalid_args", "missing htp channel");
    const pane_id = request.id orelse request.pane_id;
    const result = htp.dispatchHtpQuerySync(self, pane_id, channel, request.params) catch |err| {
        return command_mod.Response.fail("internal", @errorName(err));
    };
    defer result.deinit(self.allocator);
    if (!result.success) return command_mod.Response.fail("error", result.error_message orelse "htp query failed");
    if (result.value) |value| {
        const cloned = command_mod.cloneJsonValue(self.allocator, value) catch return command_mod.Response.fail("internal", "failed to clone htp payload");
        return .ok(cloned);
    }
    return .ok(null);
}

fn execEmit(self: *App, request: command_mod.Request) command_mod.Response {
    const channel = request.channel orelse return command_mod.Response.fail("invalid_args", "missing emit channel");
    const pane_id = request.id orelse request.pane_id;
    const result = htp.dispatchHtpEventSync(self, pane_id, channel, request.payload) catch |err| {
        return command_mod.Response.fail("internal", @errorName(err));
    };
    defer result.deinit(self.allocator);
    if (!result.success) return command_mod.Response.fail("error", result.error_message orelse "htp emit failed");
    return okNull();
}
