const std = @import("std");
const builtin = @import("builtin");
const command = @import("command.zig");
const command_ipc = @import("command_ipc.zig");
const platform = @import("platform.zig");

const win32 = if (builtin.os.tag == .windows) struct {
    const BOOL = i32;
    const DWORD = u32;
    const HANDLE = ?*anyopaque;
    const ATTACH_PARENT_PROCESS: DWORD = 0xFFFF_FFFF;
    const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
    const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));
    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

    pub extern "kernel32" fn AttachConsole(dwProcessId: DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) HANDLE;
} else struct {};

const CliAbort = error{CliFailed};

const CommonOptions = struct {
    pretty: bool = false,
    quiet: bool = false,
    envelope: bool = false,
    timeout_ms: u64 = 1500,
};

const CliError = struct {
    message: []const u8,
    code: []const u8,
    status: u8,
    owned_message: bool = false,
};

const Reply = command.Response;

const JsonObjectBuilder = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    first: bool = true,

    fn init(allocator: std.mem.Allocator) !JsonObjectBuilder {
        var builder = JsonObjectBuilder{ .allocator = allocator };
        try builder.buf.append(allocator, '{');
        return builder;
    }

    fn deinit(self: *JsonObjectBuilder) void {
        self.buf.deinit(self.allocator);
    }

    fn finish(self: *JsonObjectBuilder) ![]u8 {
        try self.buf.append(self.allocator, '}');
        return try self.buf.toOwnedSlice(self.allocator);
    }

    fn beginField(self: *JsonObjectBuilder, key: []const u8) !void {
        if (!self.first) try self.buf.append(self.allocator, ',');
        self.first = false;
        try appendJsonString(self.allocator, &self.buf, key);
        try self.buf.append(self.allocator, ':');
    }

    fn fieldString(self: *JsonObjectBuilder, key: []const u8, value: []const u8) !void {
        try self.beginField(key);
        try appendJsonString(self.allocator, &self.buf, value);
    }

    fn fieldOptionalString(self: *JsonObjectBuilder, key: []const u8, value: ?[]const u8) !void {
        const text = value orelse return;
        try self.fieldString(key, text);
    }

    fn fieldInt(self: *JsonObjectBuilder, key: []const u8, value: anytype) !void {
        try self.beginField(key);
        var buf: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d}", .{value});
        try self.buf.appendSlice(self.allocator, text);
    }

    fn fieldOptionalInt(self: *JsonObjectBuilder, key: []const u8, value: ?usize) !void {
        const number = value orelse return;
        try self.fieldInt(key, number);
    }

    fn fieldFloat(self: *JsonObjectBuilder, key: []const u8, value: f64) !void {
        try self.beginField(key);
        var buf: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d}", .{value});
        try self.buf.appendSlice(self.allocator, text);
    }

    fn fieldOptionalFloat(self: *JsonObjectBuilder, key: []const u8, value: ?f64) !void {
        const number = value orelse return;
        try self.fieldFloat(key, number);
    }

    fn fieldBool(self: *JsonObjectBuilder, key: []const u8, value: bool) !void {
        try self.beginField(key);
        try self.buf.appendSlice(self.allocator, if (value) "true" else "false");
    }

    fn fieldRaw(self: *JsonObjectBuilder, key: []const u8, value: []const u8) !void {
        try self.beginField(key);
        try self.buf.appendSlice(self.allocator, value);
    }

    fn fieldStringArray(self: *JsonObjectBuilder, field_name: []const u8, values: []const []const u8) !void {
        try self.beginField(field_name);
        try self.buf.append(self.allocator, '[');
        for (values, 0..) |item, index| {
            if (index > 0) try self.buf.append(self.allocator, ',');
            try appendJsonString(self.allocator, &self.buf, item);
        }
        try self.buf.append(self.allocator, ']');
    }
};

pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) u8 {
    var runner = Runner.init(allocator, argv);
    defer runner.deinit();

    runner.execute() catch |err| switch (err) {
        error.CliFailed => {
            runner.writeCliError(runner.last_error orelse .{
                .message = "native cli failed",
                .code = "error",
                .status = 1,
            });
            return if (runner.last_error) |cli_error| cli_error.status else 1;
        },
        else => {
            runner.writeCliError(.{
                .message = @errorName(err),
                .code = "error",
                .status = 1,
            });
            return 1;
        },
    };

    return 0;
}

const Runner = struct {
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    options: CommonOptions = .{},
    request_counter: u64 = 0,
    last_error: ?CliError = null,

    fn init(allocator: std.mem.Allocator, argv: []const []const u8) Runner {
        return .{ .allocator = allocator, .argv = argv };
    }

    fn deinit(self: *Runner) void {
        self.clearLastError();
    }

    fn execute(self: *Runner) !void {
        var filtered: std.ArrayListUnmanaged([]const u8) = .empty;
        defer filtered.deinit(self.allocator);

        var wants_help = false;
        var i: usize = 0;
        while (i < self.argv.len) : (i += 1) {
            const arg = self.argv[i];
            if (std.mem.eql(u8, arg, "--pretty")) {
                self.options.pretty = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--quiet")) {
                self.options.quiet = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--envelope")) {
                self.options.envelope = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--timeout")) {
                i += 1;
                if (i >= self.argv.len) return self.fail("missing timeout value", "invalid_args", 2);
                self.options.timeout_ms = try parseTimeoutMs(self.argv[i]);
                continue;
            }
            if (std.mem.eql(u8, arg, "--transport")) {
                i += 1;
                if (i >= self.argv.len) return self.fail("missing transport value", "invalid_args", 2);
                if (!std.mem.eql(u8, self.argv[i], "auto")) {
                    return self.fail("native cli currently supports only auto transport", "invalid_args", 2);
                }
                continue;
            }
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                wants_help = true;
                continue;
            }
            try filtered.append(self.allocator, arg);
        }

        if (wants_help) {
            try writeConsoleText(helpText(), false);
            return;
        }

        if (filtered.items.len == 0) {
            try writeConsoleText(helpText(), false);
            return self.fail("missing cli command", "invalid_args", 2);
        }

        const command_name = filtered.items[0];
        const args = filtered.items[1..];
        if (std.mem.eql(u8, command_name, "get")) return try self.executeGet(args);
        if (std.mem.eql(u8, command_name, "workspace")) return try self.executeWorkspace(args);
        if (std.mem.eql(u8, command_name, "tab")) return try self.executeTab(args);
        if (std.mem.eql(u8, command_name, "pane")) return try self.executePane(args);
        if (std.mem.eql(u8, command_name, "focus")) return try self.executeFocus(args);
        if (std.mem.eql(u8, command_name, "scroll")) return try self.executeScroll(args);
        if (std.mem.eql(u8, command_name, "config")) return try self.executeConfig(args);
        if (std.mem.eql(u8, command_name, "run")) return try self.executeRun(args);
        if (std.mem.eql(u8, command_name, "send-keys")) return try self.executeSendKeys(args);
        if (std.mem.eql(u8, command_name, "emit")) return try self.executeEmit(args);
        return self.failFmt("unknown command: {s}", .{command_name}, "invalid_args", 2);
    }

    fn executeGet(self: *Runner, args: []const []const u8) !void {
        if (args.len == 0) return self.fail("missing get command", "invalid_args", 2);
        const sub = args[0];
        const rest = args[1..];

        if (std.mem.eql(u8, sub, "pane")) {
            var id: ?usize = null;
            try self.parseOnlyId(rest, &id);
            return try self.printQuery(.{ .kind = .get_pane, .id = id });
        }
        if (std.mem.eql(u8, sub, "pane-text")) {
            var id: ?usize = null;
            try self.parseOnlyId(rest, &id);
            return try self.printQuery(.{ .kind = .get_pane_text, .id = id });
        }
        if (std.mem.eql(u8, sub, "current-pane")) {
            if (rest.len != 0) return self.fail("current-pane takes no arguments", "invalid_args", 2);
            return try self.printQuery(.{ .kind = .get_current_pane });
        }
        if (std.mem.eql(u8, sub, "tab")) {
            var id: ?usize = null;
            try self.parseOnlyId(rest, &id);
            return try self.printQuery(.{ .kind = .get_tab, .id = id });
        }
        if (std.mem.eql(u8, sub, "current-tab")) {
            if (rest.len != 0) return self.fail("current-tab takes no arguments", "invalid_args", 2);
            return try self.printQuery(.{ .kind = .get_current_tab });
        }
        if (std.mem.eql(u8, sub, "tabs")) {
            if (rest.len != 0) return self.fail("tabs takes no arguments", "invalid_args", 2);
            return try self.printQuery(.{ .kind = .get_tabs });
        }
        if (std.mem.eql(u8, sub, "panes")) {
            var tag: ?[]const u8 = null;
            try self.parseOnlyTag(rest, &tag);
            return try self.printQuery(.{ .kind = .get_panes, .tag = tag });
        }
        if (std.mem.eql(u8, sub, "workspace")) {
            var id: ?usize = null;
            var index: ?usize = null;
            try self.parseIdIndex(rest, &id, &index);
            const workspace_id = id orelse try self.resolveIndex(.get_workspaces, index);
            return try self.printQuery(.{ .kind = .get_workspace, .id = workspace_id });
        }
        if (std.mem.eql(u8, sub, "current-workspace")) {
            if (rest.len != 0) return self.fail("current-workspace takes no arguments", "invalid_args", 2);
            return try self.printQuery(.{ .kind = .get_current_workspace });
        }
        if (std.mem.eql(u8, sub, "workspaces")) {
            if (rest.len != 0) return self.fail("workspaces takes no arguments", "invalid_args", 2);
            return try self.printQuery(.{ .kind = .get_workspaces });
        }
        if (std.mem.eql(u8, sub, "domain")) {
            if (rest.len != 0) return self.fail("domain takes no arguments", "invalid_args", 2);
            return try self.printQuery(.{ .kind = .get_domain });
        }
        if (std.mem.eql(u8, sub, "htp")) {
            if (rest.len == 0 or rest.len > 2) return self.fail("usage: cli get htp <channel> [params-json]", "invalid_args", 2);
            const params = if (rest.len == 2) rest[1] else "{}";
            const parsed_params = try parseJsonObjectArg(self.allocator, params, "params");
            return try self.printQuery(.{ .kind = .get_htp, .channel = try self.allocator.dupe(u8, rest[0]), .params = parsed_params });
        }

        return self.failFmt("unknown get command: {s}", .{sub}, "invalid_args", 2);
    }

    fn executeWorkspace(self: *Runner, args: []const []const u8) !void {
        if (args.len == 0) return self.fail("missing workspace command", "invalid_args", 2);
        const sub = args[0];
        const rest = args[1..];

        if (std.mem.eql(u8, sub, "new")) {
            var cwd: ?[]const u8 = null;
            var domain: ?[]const u8 = null;
            var cmd: ?[]const u8 = null;
            var name: ?[]const u8 = null;
            try self.parseWorkspaceNewFlags(rest, &cwd, &domain, &cmd, &name);
            return try self.printEvent(.{ .kind = .workspace_new, .cwd = if (cwd) |v| try self.allocator.dupe(u8, v) else null, .domain = if (domain) |v| try self.allocator.dupe(u8, v) else null, .cmd = if (cmd) |v| try self.allocator.dupe(u8, v) else null, .name = if (name) |v| try self.allocator.dupe(u8, v) else null });
        }
        if (std.mem.eql(u8, sub, "close")) {
            var id: ?usize = null;
            var index: ?usize = null;
            try self.parseIdIndex(rest, &id, &index);
            const workspace_id = id orelse try self.resolveIndex(.get_workspaces, index);
            return try self.printEvent(.{ .kind = .workspace_close, .id = workspace_id });
        }
        if (std.mem.eql(u8, sub, "next")) {
            if (rest.len != 0) return self.fail("workspace next takes no arguments", "invalid_args", 2);
            return try self.printEvent(.{ .kind = .workspace_next });
        }
        if (std.mem.eql(u8, sub, "prev")) {
            if (rest.len != 0) return self.fail("workspace prev takes no arguments", "invalid_args", 2);
            return try self.printEvent(.{ .kind = .workspace_prev });
        }
        if (std.mem.eql(u8, sub, "select")) {
            if (rest.len != 1) return self.fail("usage: cli workspace select <index>", "invalid_args", 2);
            return try self.printEvent(.{ .kind = .workspace_select, .index = try parseIndex(rest[0]) });
        }
        if (std.mem.eql(u8, sub, "rename")) {
            if (rest.len == 0) return self.fail("usage: cli workspace rename <name> [--id ID|--index N]", "invalid_args", 2);
            var id: ?usize = null;
            var index: ?usize = null;
            try self.parseIdIndex(rest[1..], &id, &index);
            const workspace_id = id orelse try self.resolveIndex(.get_workspaces, index);
            return try self.printEvent(.{ .kind = .workspace_rename, .id = workspace_id, .name = try self.allocator.dupe(u8, rest[0]) });
        }

        return self.failFmt("unknown workspace command: {s}", .{sub}, "invalid_args", 2);
    }

    fn executeTab(self: *Runner, args: []const []const u8) !void {
        if (args.len == 0) return self.fail("missing tab command", "invalid_args", 2);
        const sub = args[0];
        const rest = args[1..];

        if (std.mem.eql(u8, sub, "new")) {
            var cmd: ?[]const u8 = null;
            var domain: ?[]const u8 = null;
            try self.parseTabNewFlags(rest, &cmd, &domain);
            return try self.printEvent(.{ .kind = .tab_new, .cmd = if (cmd) |v| try self.allocator.dupe(u8, v) else null, .domain = if (domain) |v| try self.allocator.dupe(u8, v) else null });
        }
        if (std.mem.eql(u8, sub, "close")) {
            var id: ?usize = null;
            var index: ?usize = null;
            try self.parseIdIndex(rest, &id, &index);
            const tab_id = id orelse try self.resolveIndex(.get_tabs, index);
            return try self.printEvent(.{ .kind = .tab_close, .id = tab_id });
        }
        if (std.mem.eql(u8, sub, "next")) {
            if (rest.len != 0) return self.fail("tab next takes no arguments", "invalid_args", 2);
            return try self.printEvent(.{ .kind = .tab_next });
        }
        if (std.mem.eql(u8, sub, "prev")) {
            if (rest.len != 0) return self.fail("tab prev takes no arguments", "invalid_args", 2);
            return try self.printEvent(.{ .kind = .tab_prev });
        }
        if (std.mem.eql(u8, sub, "select")) {
            if (rest.len != 1) return self.fail("usage: cli tab select <index>", "invalid_args", 2);
            const tab_id = (try self.resolveIndex(.get_tabs, try parseIndex(rest[0]))).?;
            return try self.printEvent(.{ .kind = .tab_select, .id = tab_id });
        }
        if (std.mem.eql(u8, sub, "rename")) {
            if (rest.len == 0) return self.fail("usage: cli tab rename <name> [--id ID|--index N]", "invalid_args", 2);
            var id: ?usize = null;
            var index: ?usize = null;
            try self.parseIdIndex(rest[1..], &id, &index);
            const tab_id = id orelse try self.resolveIndex(.get_tabs, index);
            return try self.printEvent(.{ .kind = .tab_rename, .id = tab_id, .name = try self.allocator.dupe(u8, rest[0]) });
        }

        return self.failFmt("unknown tab command: {s}", .{sub}, "invalid_args", 2);
    }

    fn executePane(self: *Runner, args: []const []const u8) !void {
        if (args.len == 0) return self.fail("missing pane command", "invalid_args", 2);
        const sub = args[0];
        const rest = args[1..];

        if (std.mem.eql(u8, sub, "split")) {
            if (rest.len == 0) return self.fail("usage: cli pane split vertical|horizontal [options]", "invalid_args", 2);
            if (!isOneOf(rest[0], &.{ "vertical", "horizontal" })) return self.fail("pane split direction must be vertical or horizontal", "invalid_args", 2);
            var cmd: ?[]const u8 = null;
            var cwd: ?[]const u8 = null;
            var domain: ?[]const u8 = null;
            var ratio: ?f64 = null;
            try self.parsePaneSplitFlags(rest[1..], &cmd, &cwd, &domain, &ratio);
            return try self.printEvent(.{
                .kind = .pane_split,
                .direction = try self.allocator.dupe(u8, rest[0]),
                .cmd = if (cmd) |value| try self.allocator.dupe(u8, value) else null,
                .cwd = if (cwd) |value| try self.allocator.dupe(u8, value) else null,
                .domain = if (domain) |value| try self.allocator.dupe(u8, value) else null,
                .ratio = ratio,
            });
        }
        if (std.mem.eql(u8, sub, "popup")) {
            if (rest.len == 0) return self.fail("usage: cli pane popup <cmd> [options]", "invalid_args", 2);
            var cwd: ?[]const u8 = null;
            var domain: ?[]const u8 = null;
            var x: ?f64 = null;
            var y: ?f64 = null;
            var width: ?f64 = null;
            var height: ?f64 = null;
            try self.parsePanePopupFlags(rest[1..], &cwd, &domain, &x, &y, &width, &height);
            return try self.printEvent(.{
                .kind = .pane_popup,
                .cmd = try self.allocator.dupe(u8, rest[0]),
                .cwd = if (cwd) |value| try self.allocator.dupe(u8, value) else null,
                .domain = if (domain) |value| try self.allocator.dupe(u8, value) else null,
                .x = x,
                .y = y,
                .width = width,
                .height = height,
            });
        }
        if (std.mem.eql(u8, sub, "close")) {
            var id: ?usize = null;
            var tag: ?[]const u8 = null;
            try self.parseIdTag(rest, &id, &tag);
            return try self.emitToMatchingPanes(.{ .kind = .pane_close }, id, tag);
        }
        if (std.mem.eql(u8, sub, "zoom")) {
            var id: ?usize = null;
            var tag: ?[]const u8 = null;
            try self.parseIdTag(rest, &id, &tag);
            return try self.emitToMatchingPanes(.{ .kind = .pane_zoom }, id, tag);
        }
        if (std.mem.eql(u8, sub, "float")) {
            var id: ?usize = null;
            var tag: ?[]const u8 = null;
            try self.parseIdTag(rest, &id, &tag);
            return try self.emitToMatchingPanes(.{ .kind = .pane_float }, id, tag);
        }
        if (std.mem.eql(u8, sub, "tile")) {
            var id: ?usize = null;
            var tag: ?[]const u8 = null;
            try self.parseIdTag(rest, &id, &tag);
            return try self.emitToMatchingPanes(.{ .kind = .pane_tile }, id, tag);
        }
        if (std.mem.eql(u8, sub, "move")) {
            if (rest.len == 0) return self.fail("usage: cli pane move <left|right|up|down> [options]", "invalid_args", 2);
            if (!isOneOf(rest[0], &.{ "left", "right", "up", "down" })) return self.fail("pane move direction must be left, right, up, or down", "invalid_args", 2);
            var id: ?usize = null;
            var tag: ?[]const u8 = null;
            var amount: ?f64 = null;
            try self.parseIdTagAmount(rest[1..], &id, &tag, &amount);
            return try self.emitToMatchingPanes(.{
                .kind = .pane_move,
                .direction = try self.allocator.dupe(u8, rest[0]),
                .amount = amount,
            }, id, tag);
        }
        if (std.mem.eql(u8, sub, "resize")) {
            if (rest.len == 0) return self.fail("usage: cli pane resize <left|right|up|down> [options]", "invalid_args", 2);
            if (!isOneOf(rest[0], &.{ "left", "right", "up", "down" })) return self.fail("pane resize direction must be left, right, up, or down", "invalid_args", 2);
            var id: ?usize = null;
            var tag: ?[]const u8 = null;
            var amount: ?f64 = 5.0;
            try self.parseIdTagAmount(rest[1..], &id, &tag, &amount);
            return try self.emitToMatchingPanes(.{
                .kind = .pane_resize,
                .direction = try self.allocator.dupe(u8, rest[0]),
                .amount = resizeDelta(rest[0], amount.?),
            }, id, tag);
        }
        if (std.mem.eql(u8, sub, "send-text")) {
            if (rest.len == 0) return self.fail("usage: cli pane send-text <text> [--id ID|--tag TAG]", "invalid_args", 2);
            var id: ?usize = null;
            var tag: ?[]const u8 = null;
            try self.parseIdTag(rest[1..], &id, &tag);
            return try self.emitToMatchingPanes(.{ .kind = .pane_send_text, .text = try self.allocator.dupe(u8, rest[0]) }, id, tag);
        }
        if (std.mem.eql(u8, sub, "set-tag")) {
            if (rest.len == 0) return self.fail("usage: cli pane set-tag <tag> [--id ID|--tag TAG]", "invalid_args", 2);
            var id: ?usize = null;
            var tag: ?[]const u8 = null;
            try self.parseIdTag(rest[1..], &id, &tag);
            return try self.emitToMatchingPanes(.{ .kind = .pane_set_tag, .tag = try self.allocator.dupe(u8, rest[0]) }, id, tag);
        }
        if (std.mem.eql(u8, sub, "remove-tag")) {
            if (rest.len == 0) return self.fail("usage: cli pane remove-tag <tag> [--id ID|--tag TAG]", "invalid_args", 2);
            var id: ?usize = null;
            var tag: ?[]const u8 = null;
            try self.parseIdTag(rest[1..], &id, &tag);
            return try self.emitToMatchingPanes(.{ .kind = .pane_remove_tag, .tag = try self.allocator.dupe(u8, rest[0]) }, id, tag);
        }
        if (std.mem.eql(u8, sub, "set-tags")) {
            const split_index = firstOptionIndex(rest);
            var id: ?usize = null;
            var tag: ?[]const u8 = null;
            try self.parseIdTag(rest[split_index..], &id, &tag);
            return try self.emitToMatchingPanes(.{ .kind = .pane_set_tags, .tags = try dupArgs(self.allocator, rest[0..split_index]) }, id, tag);
        }

        return self.failFmt("unknown pane command: {s}", .{sub}, "invalid_args", 2);
    }

    fn executeFocus(self: *Runner, args: []const []const u8) !void {
        if (args.len != 1) return self.fail("usage: cli focus <left|right|up|down>", "invalid_args", 2);
        if (!isOneOf(args[0], &.{ "left", "right", "up", "down" })) return self.fail("focus direction must be left, right, up, or down", "invalid_args", 2);
        return try self.printEvent(.{ .kind = .focus, .direction = try self.allocator.dupe(u8, args[0]) });
    }

    fn executeScroll(self: *Runner, args: []const []const u8) !void {
        if (args.len != 1) return self.fail("usage: cli scroll <top|bottom|page-up|page-down>", "invalid_args", 2);
        if (!isOneOf(args[0], &.{ "top", "bottom", "page-up", "page-down" })) return self.fail("scroll target must be top, bottom, page-up, or page-down", "invalid_args", 2);
        return try self.printEvent(.{ .kind = .scroll, .direction = try self.allocator.dupe(u8, args[0]) });
    }

    fn executeConfig(self: *Runner, args: []const []const u8) !void {
        if (args.len == 0) return self.fail("missing config command", "invalid_args", 2);
        if (std.mem.eql(u8, args[0], "reload")) {
            if (args.len != 1) return self.fail("config reload takes no arguments", "invalid_args", 2);
            return try self.printEvent(.{ .kind = .config_reload });
        }
        if (std.mem.eql(u8, args[0], "theme")) {
            if (args.len != 2) return self.fail("usage: cli config theme <name>", "invalid_args", 2);
            return try self.printEvent(.{ .kind = .config_theme, .name = try self.allocator.dupe(u8, args[1]) });
        }
        return self.failFmt("unknown config command: {s}", .{args[0]}, "invalid_args", 2);
    }

    fn executeRun(self: *Runner, args: []const []const u8) !void {
        if (args.len == 0) return self.fail("usage: cli run <cmd> [--domain NAME]", "invalid_args", 2);
        var domain: ?[]const u8 = null;
        try self.parseRunFlags(args[1..], &domain);
        return try self.printEvent(.{ .kind = .run, .cmd = try self.allocator.dupe(u8, args[0]), .domain = if (domain) |value| try self.allocator.dupe(u8, value) else null });
    }

    fn executeSendKeys(self: *Runner, args: []const []const u8) !void {
        if (args.len == 0) return self.fail("usage: cli send-keys <keys> [--id ID|--tag TAG]", "invalid_args", 2);
        const text = try decodeKeySequence(self.allocator, args[0]);
        defer self.allocator.free(text);
        var id: ?usize = null;
        var tag: ?[]const u8 = null;
        try self.parseIdTag(args[1..], &id, &tag);
        return try self.emitToMatchingPanes(.{ .kind = .send_keys, .text = try self.allocator.dupe(u8, text) }, id, tag);
    }

    fn executeEmit(self: *Runner, args: []const []const u8) !void {
        if (args.len == 0 or args.len > 2) return self.fail("usage: cli emit <channel> [payload-json]", "invalid_args", 2);
        const payload = if (args.len == 2) args[1] else "{}";
        return try self.printEvent(.{ .kind = .emit, .channel = try self.allocator.dupe(u8, args[0]), .payload = try parseJsonObjectArg(self.allocator, payload, "payload") });
    }

    fn printQuery(self: *Runner, request: command.Request) !void {
        var reply = try self.sendRequest(request);
        defer reply.deinit(self.allocator);
        try self.emitOutput(&reply, true);
    }

    fn printEvent(self: *Runner, request: command.Request) !void {
        var reply = try self.sendRequest(request);
        defer reply.deinit(self.allocator);
        try self.emitOutput(&reply, false);
    }

    fn emitOutput(self: *Runner, reply: *Reply, payload_only: bool) !void {
        if (self.options.quiet) return;
        if (self.options.envelope) {
            const text = try command.writeResultJson(self.allocator, reply.*);
            defer self.allocator.free(text);
            try writeJsonText(text, self.options.pretty, false);
            return;
        }
        if (!payload_only) return;
        if (reply.payload) |payload| {
            try writeJsonValue(payload, self.options.pretty, false);
            return;
        }
        try writeJsonValue(.null, self.options.pretty, false);
    }

    fn sendRequest(self: *Runner, request: command.Request) !Reply {
        return command_ipc.send(self.allocator, request, self.options.timeout_ms) catch |err| switch (err) {
            error.CommandAddrUnavailable => return self.fail("no running Hollow instance found", "transport_error", 1),
            error.Timeout => return self.fail("timed out waiting for command reply", "timeout", 1),
            else => return self.failFmt("command transport failed: {s}", .{@errorName(err)}, "transport_error", 1),
        };
    }

    fn resolveIndex(self: *Runner, kind: command.Kind, index: ?usize) !?usize {
        const idx = index orelse return null;
        if (idx < 1) return self.fail("index must be >= 1", "invalid_args", 2);

        var reply = try self.sendRequest(.{ .kind = kind });
        defer reply.deinit(self.allocator);
        const payload = reply.payload orelse return self.fail("command did not return a payload", "invalid_response", 1);
        const items = switch (payload) {
            .array => |arr| arr.items,
            else => return self.fail("command did not return addressable items", "invalid_response", 1),
        };
        if (idx > items.len) return self.failFmt("index out of range: {d}", .{idx}, "invalid_args", 2);
        const item_obj = switch (items[idx - 1]) {
            .object => |obj| obj,
            else => return self.fail("command did not return addressable items", "invalid_response", 1),
        };
        const item_id = item_obj.get("id") orelse return self.fail("command did not return addressable items", "invalid_response", 1);
        return switch (item_id) {
            .integer => |value| if (value >= 0) @as(usize, @intCast(value)) else return self.fail("command returned an invalid id", "invalid_response", 1),
            else => return self.fail("command did not return addressable items", "invalid_response", 1),
        };
    }

    fn resolveTargetPaneIds(self: *Runner, ident: ?usize, tag: ?[]const u8) !?[]usize {
        if (ident != null and tag != null) return self.fail("use either --id or --tag, not both", "invalid_args", 2);
        if (ident) |id| {
            const ids = try self.allocator.alloc(usize, 1);
            ids[0] = id;
            return ids;
        }
        if (tag == null) return null;

        var reply = try self.sendRequest(.{ .kind = .get_panes, .tag = tag });
        defer reply.deinit(self.allocator);
        const payload = reply.payload orelse return self.fail("command did not return a pane list", "invalid_response", 1);
        const items = switch (payload) {
            .array => |arr| arr.items,
            else => return self.fail("command did not return a pane list", "invalid_response", 1),
        };

        var pane_ids: std.ArrayListUnmanaged(usize) = .empty;
        defer pane_ids.deinit(self.allocator);
        for (items) |item| {
            const obj = switch (item) {
                .object => |value| value,
                else => continue,
            };
            const id_value = obj.get("id") orelse continue;
            if (id_value == .integer and id_value.integer >= 0) {
                try pane_ids.append(self.allocator, @intCast(id_value.integer));
            }
        }
        if (pane_ids.items.len == 0) return self.failFmt("no panes found with tag: {s}", .{tag.?}, "invalid_args", 2);
        return try pane_ids.toOwnedSlice(self.allocator);
    }

    fn emitToMatchingPanes(self: *Runner, request: command.Request, ident: ?usize, tag: ?[]const u8) !void {
        const pane_ids = try self.resolveTargetPaneIds(ident, tag);
        defer if (pane_ids) |ids| self.allocator.free(ids);

        if (pane_ids) |ids| {
            for (ids) |pane_id| {
                var targeted = request;
                targeted.id = pane_id;
                var reply = try self.sendRequest(targeted);
                defer reply.deinit(self.allocator);
                try self.emitOutput(&reply, false);
            }
            return;
        }

        var reply = try self.sendRequest(request);
        defer reply.deinit(self.allocator);
        try self.emitOutput(&reply, false);
    }

    fn parseOnlyId(self: *Runner, args: []const []const u8, id: *?usize) !void {
        var dummy_index: ?usize = null;
        try self.parseIdIndex(args, id, &dummy_index);
        if (dummy_index != null) return self.fail("unexpected --index", "invalid_args", 2);
    }

    fn parseOnlyTag(self: *Runner, args: []const []const u8, tag: *?[]const u8) !void {
        var dummy_id: ?usize = null;
        try self.parseIdTag(args, &dummy_id, tag);
        if (dummy_id != null) return self.fail("unexpected --id", "invalid_args", 2);
    }

    fn parseIdIndex(self: *Runner, args: []const []const u8, id: *?usize, index: *?usize) !void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--id")) {
                i += 1;
                if (i >= args.len) return self.fail("missing id value", "invalid_args", 2);
                if (id.* != null) return self.fail("duplicate --id", "invalid_args", 2);
                id.* = try parseUnsignedArg(args[i], "id");
                continue;
            }
            if (std.mem.eql(u8, arg, "--index")) {
                i += 1;
                if (i >= args.len) return self.fail("missing index value", "invalid_args", 2);
                if (index.* != null) return self.fail("duplicate --index", "invalid_args", 2);
                index.* = try parseIndex(args[i]);
                continue;
            }
            return self.failFmt("unexpected argument: {s}", .{arg}, "invalid_args", 2);
        }
    }

    fn parseIdTag(self: *Runner, args: []const []const u8, id: *?usize, tag: *?[]const u8) !void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--id")) {
                i += 1;
                if (i >= args.len) return self.fail("missing id value", "invalid_args", 2);
                if (id.* != null) return self.fail("duplicate --id", "invalid_args", 2);
                id.* = try parseUnsignedArg(args[i], "id");
                continue;
            }
            if (std.mem.eql(u8, arg, "--tag")) {
                i += 1;
                if (i >= args.len) return self.fail("missing tag value", "invalid_args", 2);
                if (tag.* != null) return self.fail("duplicate --tag", "invalid_args", 2);
                tag.* = args[i];
                continue;
            }
            return self.failFmt("unexpected argument: {s}", .{arg}, "invalid_args", 2);
        }
    }

    fn parseIdTagAmount(self: *Runner, args: []const []const u8, id: *?usize, tag: *?[]const u8, amount: *?f64) !void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--id")) {
                i += 1;
                if (i >= args.len) return self.fail("missing id value", "invalid_args", 2);
                if (id.* != null) return self.fail("duplicate --id", "invalid_args", 2);
                id.* = try parseUnsignedArg(args[i], "id");
                continue;
            }
            if (std.mem.eql(u8, arg, "--tag")) {
                i += 1;
                if (i >= args.len) return self.fail("missing tag value", "invalid_args", 2);
                if (tag.* != null) return self.fail("duplicate --tag", "invalid_args", 2);
                tag.* = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--amount")) {
                i += 1;
                if (i >= args.len) return self.fail("missing amount value", "invalid_args", 2);
                amount.* = try parseFloatArg(args[i], "amount");
                continue;
            }
            return self.failFmt("unexpected argument: {s}", .{arg}, "invalid_args", 2);
        }
    }

    fn parseWorkspaceNewFlags(self: *Runner, args: []const []const u8, cwd: *?[]const u8, domain: *?[]const u8, cmd: *?[]const u8, name: *?[]const u8) !void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--cwd")) {
                i += 1;
                if (i >= args.len) return self.fail("missing cwd value", "invalid_args", 2);
                cwd.* = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--domain")) {
                i += 1;
                if (i >= args.len) return self.fail("missing domain value", "invalid_args", 2);
                domain.* = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--cmd")) {
                i += 1;
                if (i >= args.len) return self.fail("missing cmd value", "invalid_args", 2);
                cmd.* = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--name")) {
                i += 1;
                if (i >= args.len) return self.fail("missing name value", "invalid_args", 2);
                name.* = args[i];
                continue;
            }
            return self.failFmt("unexpected argument: {s}", .{arg}, "invalid_args", 2);
        }
    }

    fn parseTabNewFlags(self: *Runner, args: []const []const u8, cmd: *?[]const u8, domain: *?[]const u8) !void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--cmd")) {
                i += 1;
                if (i >= args.len) return self.fail("missing cmd value", "invalid_args", 2);
                cmd.* = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--domain")) {
                i += 1;
                if (i >= args.len) return self.fail("missing domain value", "invalid_args", 2);
                domain.* = args[i];
                continue;
            }
            return self.failFmt("unexpected argument: {s}", .{arg}, "invalid_args", 2);
        }
    }

    fn parsePaneSplitFlags(self: *Runner, args: []const []const u8, cmd: *?[]const u8, cwd: *?[]const u8, domain: *?[]const u8, ratio: *?f64) !void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--cmd")) {
                i += 1;
                if (i >= args.len) return self.fail("missing cmd value", "invalid_args", 2);
                cmd.* = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--cwd")) {
                i += 1;
                if (i >= args.len) return self.fail("missing cwd value", "invalid_args", 2);
                cwd.* = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--domain")) {
                i += 1;
                if (i >= args.len) return self.fail("missing domain value", "invalid_args", 2);
                domain.* = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--ratio")) {
                i += 1;
                if (i >= args.len) return self.fail("missing ratio value", "invalid_args", 2);
                ratio.* = try parseFloatArg(args[i], "ratio");
                continue;
            }
            return self.failFmt("unexpected argument: {s}", .{arg}, "invalid_args", 2);
        }
    }

    fn parsePanePopupFlags(self: *Runner, args: []const []const u8, cwd: *?[]const u8, domain: *?[]const u8, x: *?f64, y: *?f64, width: *?f64, height: *?f64) !void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--cwd")) {
                i += 1;
                if (i >= args.len) return self.fail("missing cwd value", "invalid_args", 2);
                cwd.* = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--domain")) {
                i += 1;
                if (i >= args.len) return self.fail("missing domain value", "invalid_args", 2);
                domain.* = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--x")) {
                i += 1;
                if (i >= args.len) return self.fail("missing x value", "invalid_args", 2);
                x.* = try parseFloatArg(args[i], "x");
                continue;
            }
            if (std.mem.eql(u8, arg, "--y")) {
                i += 1;
                if (i >= args.len) return self.fail("missing y value", "invalid_args", 2);
                y.* = try parseFloatArg(args[i], "y");
                continue;
            }
            if (std.mem.eql(u8, arg, "--width")) {
                i += 1;
                if (i >= args.len) return self.fail("missing width value", "invalid_args", 2);
                width.* = try parseFloatArg(args[i], "width");
                continue;
            }
            if (std.mem.eql(u8, arg, "--height")) {
                i += 1;
                if (i >= args.len) return self.fail("missing height value", "invalid_args", 2);
                height.* = try parseFloatArg(args[i], "height");
                continue;
            }
            return self.failFmt("unexpected argument: {s}", .{arg}, "invalid_args", 2);
        }
    }

    fn parseRunFlags(self: *Runner, args: []const []const u8, domain: *?[]const u8) !void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (!std.mem.eql(u8, args[i], "--domain")) return self.failFmt("unexpected argument: {s}", .{args[i]}, "invalid_args", 2);
            i += 1;
            if (i >= args.len) return self.fail("missing domain value", "invalid_args", 2);
            domain.* = args[i];
        }
    }

    fn fail(self: *Runner, message: []const u8, code: []const u8, status: u8) CliAbort {
        self.clearLastError();
        self.last_error = .{ .message = message, .code = code, .status = status };
        return error.CliFailed;
    }

    fn failFmt(self: *Runner, comptime fmt: []const u8, args: anytype, code: []const u8, status: u8) CliAbort {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return self.fail("out of memory", "error", 1);
        self.clearLastError();
        self.last_error = .{ .message = message, .code = code, .status = status, .owned_message = true };
        return error.CliFailed;
    }

    fn clearLastError(self: *Runner) void {
        if (self.last_error) |err| {
            if (err.owned_message) self.allocator.free(err.message);
            self.last_error = null;
        }
    }

    fn writeCliError(self: *Runner, cli_error: CliError) void {
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();
        std.json.Stringify.value(.{
            .ok = false,
            .@"error" = cli_error.message,
            .code = cli_error.code,
        }, .{}, &writer.writer) catch return;
        writer.writer.writeByte('\n') catch return;
        writeConsoleText(writer.written(), true) catch {};
    }
};

fn helpText() []const u8 {
    return
        "usage: hollow cli [--pretty] [--quiet] [--envelope] [--timeout seconds] [--transport auto] <command>\n" ++
        "commands: get, workspace, tab, pane, focus, scroll, config, run, send-keys, emit\n";
}

fn emptyObject(allocator: std.mem.Allocator) ![]u8 {
    return try allocator.dupe(u8, "{}");
}

fn dupArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, args.len);
    errdefer {
        for (out[0..args.len]) |value| allocator.free(value);
        allocator.free(out);
    }
    for (args, 0..) |arg, index| {
        out[index] = try allocator.dupe(u8, arg);
    }
    return out;
}

fn jsonIdPayload(allocator: std.mem.Allocator, id: ?usize) ![]u8 {
    if (id == null) return try emptyObject(allocator);
    var builder = try JsonObjectBuilder.init(allocator);
    defer builder.deinit();
    try builder.fieldInt("id", id.?);
    return try builder.finish();
}

fn jsonTagPayload(allocator: std.mem.Allocator, tag: ?[]const u8) ![]u8 {
    if (tag == null) return try emptyObject(allocator);
    var builder = try JsonObjectBuilder.init(allocator);
    defer builder.deinit();
    try builder.fieldString("tag", tag.?);
    return try builder.finish();
}

fn jsonWorkspaceNewPayload(allocator: std.mem.Allocator, cwd: ?[]const u8, domain: ?[]const u8, cmd: ?[]const u8, name: ?[]const u8) ![]u8 {
    var builder = try JsonObjectBuilder.init(allocator);
    defer builder.deinit();
    try builder.fieldOptionalString("cwd", cwd);
    try builder.fieldOptionalString("domain", domain);
    try builder.fieldOptionalString("command", cmd);
    try builder.fieldOptionalString("name", name);
    return try builder.finish();
}

fn jsonTabNewPayload(allocator: std.mem.Allocator, cmd: ?[]const u8, domain: ?[]const u8) ![]u8 {
    var builder = try JsonObjectBuilder.init(allocator);
    defer builder.deinit();
    try builder.fieldOptionalString("command", cmd);
    try builder.fieldOptionalString("domain", domain);
    return try builder.finish();
}

fn jsonWithPaneId(allocator: std.mem.Allocator, payload_json: []const u8, pane_id: usize) ![]u8 {
    if (std.mem.eql(u8, payload_json, "{}")) {
        return try std.fmt.allocPrint(allocator, "{{\"id\":{d}}}", .{pane_id});
    }
    if (payload_json.len < 2 or payload_json[0] != '{' or payload_json[payload_json.len - 1] != '}') return error.InvalidJson;
    return try std.fmt.allocPrint(allocator, "{s},\"id\":{d}}}", .{ payload_json[0 .. payload_json.len - 1], pane_id });
}

fn validateJsonObject(allocator: std.mem.Allocator, text: []const u8, kind: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{ .ignore_unknown_fields = true }) catch |err| {
        return switch (err) {
            else => error.InvalidJson,
        };
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;
    _ = kind;
}

fn parseJsonObjectArg(allocator: std.mem.Allocator, text: []const u8, kind: []const u8) !std.json.Value {
    try validateJsonObject(allocator, text, kind);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return try command.cloneJsonValue(allocator, parsed.value);
}

fn writeJsonText(text: []const u8, pretty: bool, stderr: bool) !void {
    if (!pretty) {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(std.heap.page_allocator);
        try out.appendSlice(std.heap.page_allocator, text);
        try out.append(std.heap.page_allocator, '\n');
        return try writeConsoleText(out.items, stderr);
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try writeJsonValue(parsed.value, true, stderr);
}

fn parseUnsignedArg(text: []const u8, _: []const u8) !usize {
    return std.fmt.parseInt(usize, text, 10);
}

fn parseIndex(text: []const u8) !usize {
    const index = try std.fmt.parseInt(usize, text, 10);
    if (index < 1) return error.InvalidIndex;
    return index;
}

fn parseFloatArg(text: []const u8, _: []const u8) !f64 {
    return try std.fmt.parseFloat(f64, text);
}

fn parseTimeoutMs(text: []const u8) !u64 {
    const seconds = try std.fmt.parseFloat(f64, text);
    if (seconds < 0) return error.InvalidTimeout;
    return @intFromFloat(seconds * 1000.0);
}

fn isOneOf(value: []const u8, options: []const []const u8) bool {
    for (options) |option| {
        if (std.mem.eql(u8, value, option)) return true;
    }
    return false;
}

fn firstOptionIndex(args: []const []const u8) usize {
    for (args, 0..) |arg, index| {
        if (std.mem.startsWith(u8, arg, "--")) return index;
    }
    return args.len;
}

fn resizeDelta(direction: []const u8, amount: f64) f64 {
    const magnitude = @abs(amount);
    if (std.mem.eql(u8, direction, "left") or std.mem.eql(u8, direction, "up")) return -magnitude;
    return magnitude;
}

fn jsonObjectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn appendJsonString(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    try list.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '"' => try list.appendSlice(allocator, "\\\""),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            0...8, 11, 12, 14...31 => {
                var buf: [6]u8 = undefined;
                _ = try std.fmt.bufPrint(&buf, "\\u{X:0>4}", .{ch});
                try list.appendSlice(allocator, &buf);
            },
            else => try list.append(allocator, ch),
        }
    }
    try list.append(allocator, '"');
}

fn writeJsonValue(value: std.json.Value, pretty: bool, stderr: bool) !void {
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = if (pretty) .indent_2 else .minified }, &out.writer);
    try out.writer.writeByte('\n');
    try writeConsoleText(out.written(), stderr);
}

fn writeConsoleText(text: []const u8, stderr: bool) !void {
    if (builtin.os.tag != .windows) {
        try (if (stderr) std.fs.File.stderr() else std.fs.File.stdout()).writeAll(text);
        return;
    }

    // Prefer the process parameter std handles first. Under WSL interop these
    // can be valid redirected pipes even when GetStdHandle/AttachConsole do not
    // describe a usable console relationship.
    const inherited = if (stderr) std.fs.File.stderr() else std.fs.File.stdout();
    if (inherited.writeAll(text)) |_| {
        return;
    } else |_| {}

    const stream_id = if (stderr) win32.STD_ERROR_HANDLE else win32.STD_OUTPUT_HANDLE;
    if (tryWriteWindowsStdHandle(stream_id, text)) return;
    _ = win32.AttachConsole(win32.ATTACH_PARENT_PROCESS);
    if (tryWriteWindowsStdHandle(stream_id, text)) return;

    return error.NoConsoleOutput;
}

fn ensureConsoleStream(stderr: bool) ?std.fs.File {
    if (builtin.os.tag != .windows) return if (stderr) std.fs.File.stderr() else std.fs.File.stdout();

    const stream_id = if (stderr) win32.STD_ERROR_HANDLE else win32.STD_OUTPUT_HANDLE;
    return windowsStdHandle(stream_id);
}

fn tryWriteWindowsStdHandle(stream_id: win32.DWORD, text: []const u8) bool {
    const file = windowsStdHandle(stream_id) orelse return false;
    file.writeAll(text) catch return false;
    return true;
}

fn windowsStdHandle(stream_id: win32.DWORD) ?std.fs.File {
    const handle = win32.GetStdHandle(stream_id) orelse return null;
    if (handle == win32.INVALID_HANDLE_VALUE) return null;
    return std.fs.File{ .handle = handle };
}

fn decodeKeySequence(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '{') {
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, '}') orelse return error.InvalidKeySequence;
            const token = try decodeKeyToken(allocator, text[i + 1 .. end]);
            defer allocator.free(token);
            try out.appendSlice(allocator, token);
            i = end + 1;
            continue;
        }
        if (ch == '\\') {
            const decoded = try decodeEscape(text, i);
            try out.appendSlice(allocator, decoded.value);
            i = decoded.next_index;
            continue;
        }
        try out.append(allocator, ch);
        i += 1;
    }

    return try out.toOwnedSlice(allocator);
}

const DecodedEscape = struct {
    value: []const u8,
    next_index: usize,
};

fn decodeEscape(text: []const u8, index: usize) !DecodedEscape {
    if (index + 1 >= text.len) return error.InvalidKeySequence;
    return switch (text[index + 1]) {
        'n' => .{ .value = "\n", .next_index = index + 2 },
        'r' => .{ .value = "\r", .next_index = index + 2 },
        't' => .{ .value = "\t", .next_index = index + 2 },
        'e' => .{ .value = "\x1b", .next_index = index + 2 },
        '\\' => .{ .value = "\\", .next_index = index + 2 },
        '"' => .{ .value = "\"", .next_index = index + 2 },
        '\'' => .{ .value = "'", .next_index = index + 2 },
        '{' => .{ .value = "{", .next_index = index + 2 },
        '}' => .{ .value = "}", .next_index = index + 2 },
        'x' => blk: {
            if (index + 3 >= text.len) return error.InvalidKeySequence;
            const byte = try std.fmt.parseInt(u8, text[index + 2 .. index + 4], 16);
            break :blk .{ .value = &[_]u8{byte}, .next_index = index + 4 };
        },
        else => error.InvalidKeySequence,
    };
}

fn decodeKeyToken(allocator: std.mem.Allocator, token_text: []const u8) ![]u8 {
    const raw = std.mem.trim(u8, token_text, " \t\r\n");
    if (raw.len == 0) return error.InvalidKeySequence;

    var normalized = try allocator.alloc(u8, raw.len);
    defer allocator.free(normalized);
    for (raw, 0..) |ch, index| {
        normalized[index] = switch (ch) {
            '_', ' ' => '-',
            else => std.ascii.toLower(ch),
        };
    }

    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer parts.deinit(allocator);
    var start: usize = 0;
    var index: usize = 0;
    while (index <= normalized.len) : (index += 1) {
        if (index == normalized.len or normalized[index] == '-') {
            if (index > start) try parts.append(allocator, normalized[start..index]);
            start = index + 1;
        }
    }
    if (parts.items.len == 0) return error.InvalidKeySequence;
    if (parts.items.len == 1) return try allocator.dupe(u8, try namedKeySequence(parts.items[0]));

    const key_name = parts.items[parts.items.len - 1];
    const key_text = modifiedKeyText(key_name) orelse return error.InvalidKeySequence;
    var ctrl = false;
    var alt = false;
    var shift = false;
    for (parts.items[0 .. parts.items.len - 1]) |part| {
        if (std.mem.eql(u8, part, "ctrl") or std.mem.eql(u8, part, "control")) {
            ctrl = true;
            continue;
        }
        if (std.mem.eql(u8, part, "alt") or std.mem.eql(u8, part, "meta")) {
            alt = true;
            continue;
        }
        if (std.mem.eql(u8, part, "shift")) {
            shift = true;
            continue;
        }
        return error.InvalidKeySequence;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    if (alt) try out.append(allocator, 0x1b);

    if (ctrl) {
        if (key_text.len != 1) return error.InvalidKeySequence;
        const upper = std.ascii.toUpper(key_text[0]);
        if (!(upper > '@' and upper < '`')) return error.InvalidKeySequence;
        try out.append(allocator, upper - '@');
        return try out.toOwnedSlice(allocator);
    }

    if (shift and key_text.len == 1 and key_text[0] >= 'a' and key_text[0] <= 'z') {
        try out.append(allocator, std.ascii.toUpper(key_text[0]));
        return try out.toOwnedSlice(allocator);
    }

    try out.appendSlice(allocator, key_text);
    return try out.toOwnedSlice(allocator);
}

fn modifiedKeyText(key_name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, key_name, "enter")) return "\r";
    if (std.mem.eql(u8, key_name, "tab")) return "\t";
    if (std.mem.eql(u8, key_name, "escape") or std.mem.eql(u8, key_name, "esc")) return "\x1b";
    if (std.mem.eql(u8, key_name, "space")) return " ";
    if (std.mem.eql(u8, key_name, "backspace")) return "\x7f";
    if (key_name.len == 1) return key_name;
    return null;
}

fn namedKeySequence(key_name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, key_name, "up")) return "\x1b[A";
    if (std.mem.eql(u8, key_name, "down")) return "\x1b[B";
    if (std.mem.eql(u8, key_name, "right")) return "\x1b[C";
    if (std.mem.eql(u8, key_name, "left")) return "\x1b[D";
    if (std.mem.eql(u8, key_name, "home")) return "\x1b[H";
    if (std.mem.eql(u8, key_name, "end")) return "\x1b[F";
    if (std.mem.eql(u8, key_name, "pgup") or std.mem.eql(u8, key_name, "pageup")) return "\x1b[5~";
    if (std.mem.eql(u8, key_name, "pgdn") or std.mem.eql(u8, key_name, "pagedown")) return "\x1b[6~";
    if (std.mem.eql(u8, key_name, "enter")) return "\r";
    if (std.mem.eql(u8, key_name, "tab")) return "\t";
    if (std.mem.eql(u8, key_name, "escape") or std.mem.eql(u8, key_name, "esc")) return "\x1b";
    if (std.mem.eql(u8, key_name, "backspace")) return "\x7f";
    if (std.mem.eql(u8, key_name, "delete")) return "\x1b[3~";
    if (std.mem.eql(u8, key_name, "insert")) return "\x1b[2~";
    if (std.mem.eql(u8, key_name, "space")) return " ";
    if (std.mem.eql(u8, key_name, "f1")) return "\x1bOP";
    if (std.mem.eql(u8, key_name, "f2")) return "\x1bOQ";
    if (std.mem.eql(u8, key_name, "f3")) return "\x1bOR";
    if (std.mem.eql(u8, key_name, "f4")) return "\x1bOS";
    if (std.mem.eql(u8, key_name, "f5")) return "\x1b[15~";
    if (std.mem.eql(u8, key_name, "f6")) return "\x1b[17~";
    if (std.mem.eql(u8, key_name, "f7")) return "\x1b[18~";
    if (std.mem.eql(u8, key_name, "f8")) return "\x1b[19~";
    if (std.mem.eql(u8, key_name, "f9")) return "\x1b[20~";
    if (std.mem.eql(u8, key_name, "f10")) return "\x1b[21~";
    if (std.mem.eql(u8, key_name, "f11")) return "\x1b[23~";
    if (std.mem.eql(u8, key_name, "f12")) return "\x1b[24~";
    if (key_name.len == 1) return key_name;
    return error.InvalidKeySequence;
}

test "jsonWithPaneId appends pane id" {
    const payload = try jsonWithPaneId(std.testing.allocator, "{\"text\":\"hi\"}", 42);
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqualStrings("{\"text\":\"hi\",\"id\":42}", payload);
}

test "decodeKeySequence handles modifiers and escapes" {
    const decoded = try decodeKeySequence(std.testing.allocator, "{ctrl-c}{alt-x}\\n{f5}");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("\x03\x1bx\n\x1b[15~", decoded);
}
