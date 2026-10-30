//! Running-version discovery and validation derived from the command union.
const std = @import("std");
const command = @import("../command.zig");
const Kind = command.Kind;
const results = @import("results.zig");
pub const version = 1;

pub fn choices(kind: Kind, field: []const u8) ?[]const []const u8 {
    if (kind == .get_activities and std.mem.eql(u8, field, "view")) return &.{ "inbox", "history", "running" };
    if (kind == .get_activities and std.mem.eql(u8, field, "activity_kind")) return &.{ "notification", "bell", "program" };
    if (std.mem.eql(u8, field, "direction")) return switch (kind) {
        .pane_split => &.{ "vertical", "horizontal" },
        .pane_resize => &.{ "left", "right", "up", "down", "vertical", "horizontal" },
        .scroll => &.{ "top", "bottom", "page-up", "page-down" },
        else => &.{ "left", "right", "up", "down" },
    };
    if (std.mem.eql(u8, field, "level")) return &.{ "info", "warn", "error", "success" };
    if (std.mem.eql(u8, field, "surface")) return &.{ "topbar", "bottombar", "sidebar", "overlay" };
    if (std.mem.eql(u8, field, "event")) return &.{ "command_started", "command_finished", "process_exited", "status_changed", "pane_closed" };
    return null;
}

/// Check JSON token kinds before std.json's permissive numeric coercions.
pub fn validateJson(comptime T: type, value: std.json.Value) !void {
    if (T == std.json.Value) return;
    switch (@typeInfo(T)) {
        .optional => |info| if (value != .null) {
            try validateJson(info.child, value);
        },
        .int => if (value != .integer) return error.InvalidArgumentType,
        .bool => if (value != .bool) return error.InvalidArgumentType,
        .float => if (value != .integer and value != .float) return error.InvalidArgumentType,
        .@"struct" => |info| {
            if (value != .object) return error.InvalidArgumentType;
            inline for (info.field_names, info.field_types) |name, Field| {
                if (value.object.get(name)) |v| try validateJson(Field, v);
            }
        },
        .pointer => |info| {
            if (info.child == u8) {
                if (value != .string) return error.InvalidArgumentType;
            } else {
                if (value != .array) return error.InvalidArgumentType;
                for (value.array.items) |item| try validateJson(info.child, item);
            }
        },
        else => {},
    }
}

pub fn validate(data: command.Command) !void {
    if (data == .job_spawn) {
        const args = data.job_spawn;
        if ((args.argv == null) == (args.cmd == null)) return error.InvalidArgumentValue;
        if (args.argv) |argv| {
            if (argv.len == 0 or argv.len > 256 or argv[0].len == 0) return error.InvalidArgumentValue;
            var bytes: usize = 0;
            for (argv) |arg| {
                if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidArgumentValue;
                bytes += arg.len;
            }
            if (bytes > 128 * 1024) return error.InvalidArgumentValue;
        }
        inline for (.{ "cmd", "cwd", "domain" }) |field| if (@field(args, field)) |text| {
            if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidArgumentValue;
        };
    }
    if (data == .job_get or data == .job_output or data == .job_cleanup) {
        const token = switch (data) {
            .job_get, .job_output, .job_cleanup => |args| args.token,
            else => unreachable,
        };
        if (token.len != 32) return error.InvalidArgumentValue;
        for (token) |c| if (!std.ascii.isHex(c)) return error.InvalidArgumentValue;
    }
    switch (data) {
        inline else => |args, kind| {
            inline for (@typeInfo(@TypeOf(args)).@"struct".field_names) |name| {
                const value = @field(args, name);
                switch (@typeInfo(@TypeOf(value))) {
                    .optional => if (value) |v| {
                        try validateField(kind, name, v);
                    },
                    else => try validateField(kind, name, value),
                }
            }
        },
    }
}

fn validateField(kind: Kind, comptime name: []const u8, value: anytype) !void {
    const T = @TypeOf(value);
    if (T == std.json.Value) return;
    switch (@typeInfo(T)) {
        .int => {
            if (@as(u64, value) > std.math.maxInt(i64)) return error.InvalidArgumentValue;
            if ((std.mem.eql(u8, name, "id") or std.mem.eql(u8, name, "index")) and value == 0) return error.InvalidArgumentValue;
        },
        .float => {
            if (!std.math.isFinite(value) or @abs(value) > std.math.floatMax(f32)) return error.InvalidArgumentValue;
            if (std.mem.eql(u8, name, "ratio") or std.mem.eql(u8, name, "width") or std.mem.eql(u8, name, "height")) {
                if (value <= 0 or value > 1 or (value == 1 and std.mem.eql(u8, name, "ratio"))) return error.InvalidArgumentValue;
            }
            if (std.mem.eql(u8, name, "x") or std.mem.eql(u8, name, "y")) {
                if (value < 0 or value > 1) return error.InvalidArgumentValue;
            }
        },
        .pointer => |info| if (info.child == u8) {
            if (choices(kind, name)) |values| {
                for (values) |candidate| if (std.mem.eql(u8, candidate, value)) return;
                return error.InvalidArgumentValue;
            }
            if (std.mem.eql(u8, name, "color")) {
                if (value.len != 7 or value[0] != '#') return error.InvalidArgumentValue;
                for (value[1..]) |c| if (!std.ascii.isHex(c)) return error.InvalidArgumentValue;
            }
            if (!std.mem.eql(u8, name, "text") and value.len == 0) return error.InvalidArgumentValue;
        },
        else => {},
    }
}

pub fn description(kind: Kind) []const u8 {
    return switch (kind) {
        .get_pane => "Read a pane snapshot; defaults to caller pane, then active pane.",
        .get_pane_text => "Read pane scrollback text; defaults to caller pane, then active pane.",
        .get_screen => "Read the visible terminal viewport, cursor, and revision.",
        .pane_screenshot => "Save a visible pane as PNG on the GUI host.",
        .tab_screenshot => "Save the visible tab as PNG on the GUI host.",
        .get_ui_nodes => "Read semantic UI nodes from the last rendered frame.",
        .get_revision => "Read the current automation revision.",
        .get_current_pane => "Read the GUI's active pane, not the caller pane.",
        .get_tab => "Read a tab snapshot; defaults to the active tab.",
        .get_current_tab => "Read the active tab.",
        .get_tabs => "List tabs in the active workspace.",
        .get_panes => "List panes, optionally filtered by tag.",
        .get_activities => "List session Inbox (default), History, or Running activity without acknowledgement; optional filters use exact matches.",
        .get_workspace => "Read a workspace snapshot; defaults to the active workspace.",
        .get_current_workspace => "Read the active workspace.",
        .get_workspaces => "List workspaces.",
        .get_mux_tree => "Read the workspace, tab, and pane tree.",
        .get_domain => "Read the active pane's domain.",
        .get_htp => "Invoke a registered HTP query channel; channel defines params/result.",
        .workspace_new => "Queue creation of a workspace.",
        .workspace_close => "Queue closing a workspace; defaults to the active workspace.",
        .workspace_next => "Queue switching to the next workspace.",
        .workspace_prev => "Queue switching to the previous workspace.",
        .workspace_select => "Queue switching to a workspace by one-based index.",
        .workspace_rename => "Queue renaming the active workspace; a supplied id must match it.",
        .tab_new => "Queue creation of a tab.",
        .tab_close => "Queue closing a tab in the active workspace; defaults to the active tab.",
        .tab_next => "Queue switching to the next tab.",
        .tab_prev => "Queue switching to the previous tab.",
        .tab_select => "Queue selecting a tab by id in the active workspace.",
        .tab_rename => "Queue renaming a tab by id.",
        .pane_split => "Queue splitting the active pane; ratio is the new pane's share.",
        .pane_popup => "Queue creating a floating terminal running cmd.",
        .pane_close => "Queue closing a pane by id.",
        .pane_zoom => "Queue toggling pane maximization by id.",
        .pane_float => "Queue floating a pane by id.",
        .pane_tile => "Queue tiling a pane by id.",
        .pane_move => "Queue moving a pane by id; amount is normalized (default 0.08).",
        .pane_resize => "Queue resizing the active pane; amount is normalized; id is currently ignored.",
        .pane_send_text => "Queue sending literal text to a pane by id.",
        .pane_bell => "Queue visual attention for a pane; defaults to the active pane.",
        .pane_set_tag => "Queue adding a tag to a pane by id.",
        .pane_remove_tag => "Queue removing a tag from a pane by id.",
        .pane_set_tags => "Queue replacing pane tags; an empty list clears tags.",
        .send_keys => "Queue sending decoded key bytes to a pane; text is bytes, not key notation.",
        .ui_click => "Activate a semantic UI node, optionally guarded by generation.",
        .wait_revision => "Wait for revision to increase; server caps each wait at 250 ms.",
        .events_subscribe => "Capture an event cursor before launching work; no historical events are included.",
        .events_read => "Read events after cursor, optionally filtered by pane/event/command; capped at 250 ms. Overflow is an error, never completion.",
        .job_spawn => "Create a retained background tab without focus; exactly one of argv (literal executable arguments) or cmd (shell command) is required. user_shell opts into interactive target-shell startup. Return resource IDs, ownership token and pre-launch event cursor.",
        .job_get => "Read an owned job's retained running/exited state and process status.",
        .job_output => "Read an owned job's bounded raw PTY output tail as base64; truncation/allocation loss is explicit.",
        .job_cleanup => "Close only the matching automation-owned pane after exit; reject running jobs or wrong ownership tokens.",
        .focus => "Queue focusing a neighboring pane.",
        .scroll => "Queue scrolling the active pane.",
        .config_reload => "Queue reloading configuration.",
        .config_theme => "Queue changing theme by name.",
        .run => "Queue opening a new tab running cmd; does not wait for command completion.",
        .emit => "Queue an HTP event; the registered channel defines payload semantics.",
        .api_list => "List this running host's command contracts.",
        .api_describe => "Describe one command from this running host.",
        .capabilities => "Read command API version, platform, features, and method names.",
    };
}

pub fn isDeferred(kind: Kind) bool {
    return switch (kind) {
        .events_subscribe, .events_read, .job_spawn, .job_get, .job_output, .job_cleanup, .get_activities => false,
        .get_pane, .get_pane_text, .get_screen, .pane_screenshot, .tab_screenshot, .get_ui_nodes, .get_revision, .get_current_pane, .get_tab, .get_current_tab, .get_tabs, .get_panes, .get_workspace, .get_current_workspace, .get_workspaces, .get_mux_tree, .get_domain, .get_htp, .ui_click, .wait_revision, .api_list, .api_describe, .capabilities => false,
        else => true,
    };
}

fn schema(comptime T: type, kind: Kind, comptime name: []const u8, writer: *std.Io.Writer) anyerror!void {
    if (T == std.json.Value) {
        try writer.writeAll("{}");
        return;
    }
    if (@typeInfo(T) == .optional) {
        try writer.writeAll("{\"anyOf\":[");
        try schema(@typeInfo(T).optional.child, kind, name, writer);
        try writer.writeAll(",{\"type\":\"null\"}]}");
        return;
    }
    switch (@typeInfo(T)) {
        .bool => try writer.writeAll("{\"type\":\"boolean\"}"),
        .@"enum" => |info| {
            try writer.writeAll("{\"type\":\"string\",\"enum\":[");
            inline for (info.field_names, 0..) |field, i| {
                if (i != 0) try writer.writeByte(',');
                try std.json.Stringify.value(field, .{}, writer);
            }
            try writer.writeAll("]}");
        },
        .@"struct" => |info| {
            try writer.writeAll("{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{");
            inline for (info.field_names, info.field_types, 0..) |field, Field, i| {
                if (i != 0) try writer.writeByte(',');
                try std.json.Stringify.value(field, .{}, writer);
                try writer.writeByte(':');
                try schema(Field, kind, field, writer);
            }
            try writer.writeAll("},\"required\":[");
            var first = true;
            inline for (info.field_names, info.field_attrs) |field, attrs| {
                if (attrs.default_value_ptr == null) {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    try std.json.Stringify.value(field, .{}, writer);
                }
            }
            try writer.writeAll("]");
            if (T == command.JobSpawn) try writer.writeAll(",\"oneOf\":[{\"required\":[\"argv\"],\"properties\":{\"argv\":{\"type\":\"array\",\"minItems\":1,\"maxItems\":256},\"cmd\":{\"type\":\"null\"}}},{\"required\":[\"cmd\"],\"properties\":{\"cmd\":{\"type\":\"string\",\"minLength\":1},\"argv\":{\"type\":\"null\"}}}]");
            try writer.writeByte('}');
        },
        .int => {
            try writer.writeAll("{\"type\":\"integer\",\"minimum\":");
            try writer.writeAll(if (std.mem.eql(u8, name, "id") or std.mem.eql(u8, name, "index")) "1" else "0");
            try writer.writeAll(",\"maximum\":9223372036854775807}");
        },
        .float => {
            if (std.mem.eql(u8, name, "ratio")) try writer.writeAll("{\"type\":\"number\",\"exclusiveMinimum\":0,\"exclusiveMaximum\":1}") else if (std.mem.eql(u8, name, "width") or std.mem.eql(u8, name, "height")) try writer.writeAll("{\"type\":\"number\",\"exclusiveMinimum\":0,\"maximum\":1}") else if (std.mem.eql(u8, name, "x") or std.mem.eql(u8, name, "y")) try writer.writeAll("{\"type\":\"number\",\"minimum\":0,\"maximum\":1}") else try writer.writeAll("{\"type\":\"number\",\"minimum\":-3.4028234663852886e38,\"maximum\":3.4028234663852886e38}");
        },
        .pointer => |info| {
            if (info.child == u8) {
                try writer.writeAll("{\"type\":\"string\"");
                if (std.mem.eql(u8, name, "token")) {
                    try writer.writeAll(",\"minLength\":32,\"maxLength\":32,\"pattern\":\"^[0-9a-fA-F]{32}$\"");
                } else if (!std.mem.eql(u8, name, "text")) try writer.writeAll(",\"minLength\":1");
                if (choices(kind, name)) |values| {
                    try writer.writeAll(",\"enum\":");
                    try std.json.Stringify.value(values, .{}, writer);
                }
                if (std.mem.eql(u8, name, "color")) try writer.writeAll(",\"pattern\":\"^#[0-9a-fA-F]{6}$\"");
                try writer.writeByte('}');
            } else {
                try writer.writeAll("{\"type\":\"array\",\"items\":");
                try schema(info.child, kind, "text", writer);
                try writer.writeByte('}');
            }
        },
        else => @compileError("Unsupported command schema type: " ++ @typeName(T)),
    }
}

fn writeExample(comptime kind: Kind, writer: *std.Io.Writer) !void {
    if (kind == .job_spawn) {
        try writer.writeAll("{\"kind\":\"job_spawn\",\"argv\":[\"echo\",\"hello\"]}");
        return;
    }
    try writer.writeAll("{\"kind\":");
    try std.json.Stringify.value(@tagName(kind), .{}, writer);
    const info = @typeInfo(command.Args(kind)).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |field, Field, attrs| {
        if (attrs.default_value_ptr == null) {
            try writer.writeByte(',');
            try std.json.Stringify.value(field, .{}, writer);
            try writer.writeByte(':');
            switch (@typeInfo(Field)) {
                .int => try writer.writeAll(if (std.mem.eql(u8, field, "revision")) "0" else "1"),
                .pointer => {
                    const value = if (choices(kind, field)) |values| values[0] else if (std.mem.eql(u8, field, "token")) "0123456789abcdef0123456789abcdef" else if (std.mem.eql(u8, field, "path")) "hollow.png" else if (std.mem.eql(u8, field, "name") and kind == .api_describe) "get_screen" else "example";
                    try std.json.Stringify.value(value, .{}, writer);
                },
                else => unreachable,
            }
        }
    }
    try writer.writeByte('}');
}

fn writeDescription(comptime kind: Kind, writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"name\":");
    try std.json.Stringify.value(@tagName(kind), .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(description(kind), .{}, writer);
    try writer.writeAll(",\"input_schema\":");
    try schema(command.Args(kind), kind, "", writer);
    try writer.writeAll(",\"output_schema\":");
    try results.schema(Result(kind), writer);
    try writer.writeAll(",\"completion\":");
    try std.json.Stringify.value(if (isDeferred(kind)) "queued" else "completed", .{}, writer);
    try writer.writeAll(",\"transports\":");
    try std.json.Stringify.value(switch (kind) {
        .pane_screenshot, .tab_screenshot, .wait_revision, .events_read => @as([]const []const u8, &.{"socket"}),
        else => @as([]const []const u8, &.{ "socket", "file", "osc" }),
    }, .{}, writer);
    try writer.writeAll(",\"validation_notes\":\"Input schema describes command arguments, excluding kind and ctx. The legacy field command is an alias for cmd; both together are rejected. Known legacy null fields are ignored. Snapshots are extensible; HTP channels define their own nested contracts. Queued success means accepted, not completed. Context is metadata, not authorization.\",\"request_example\":");
    try writeExample(kind, writer);
    try writer.writeByte('}');
}

pub fn Result(comptime kind: Kind) type {
    return switch (kind) {
        .get_htp => std.json.Value,
        .get_pane_text => []const u8,
        .get_tabs => []const results.Tab,
        .get_panes => []const results.Pane,
        .get_activities => []const results.Activity,
        .get_workspaces => []const results.Workspace,
        .get_mux_tree => []const results.TreeWorkspace,
        .api_list => []const results.Method,
        .get_revision, .wait_revision, .ui_click => results.Revision,
        .events_subscribe => struct { cursor: u64, capacity: usize },
        .events_read => struct { cursor: u64, events: []const @import("../automation_events.zig").Event },
        .job_spawn => struct { pane_id: usize, tab_id: usize, workspace_id: usize, token: []const u8, cursor: u64 },
        .job_get => struct { pane_id: usize, state: []const u8, status: ?u32, cursor: u64, output_bytes: usize, output_truncated: bool, output_incomplete: bool },
        .job_output => struct { encoding: []const u8, data: []const u8, truncated: bool, incomplete: bool, capacity_bytes: usize },
        .pane_screenshot, .tab_screenshot => results.Screenshot,
        .get_ui_nodes => results.UiNodes,
        .api_describe => results.Method,
        .capabilities => struct { api_version: usize, platform: []const u8, methods: []const []const u8, features: []const []const u8, context: std.json.Value, context_schema: std.json.Value, transport: []const u8 },
        .get_screen => ?results.Screen,
        .get_pane, .get_current_pane => ?results.Pane,
        .get_tab, .get_current_tab => ?results.Tab,
        .get_workspace, .get_current_workspace => ?results.Workspace,
        .get_domain => ?results.Domain,
        else => void,
    };
}

pub fn describeValue(allocator: std.mem.Allocator, kind: Kind) !std.json.Value {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    switch (kind) {
        inline else => |tag| writeDescription(tag, &out.writer) catch |err| {
            // The allocating writer's only write failure is allocation failure.
            return if (err == error.WriteFailed) error.OutOfMemory else err;
        },
    }
    return jsonValue(allocator, out.written());
}

pub fn listValue(allocator: std.mem.Allocator) !std.json.Value {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeByte('[');
    inline for (@typeInfo(Kind).@"enum".field_names, 0..) |field, i| {
        if (i != 0) try out.writer.writeByte(',');
        try writeDescription(@field(Kind, field), &out.writer);
    }
    try out.writer.writeByte(']');
    return jsonValue(allocator, out.written());
}

pub fn capabilitiesValue(allocator: std.mem.Allocator) !std.json.Value {
    var context_schema: std.Io.Writer.Allocating = .init(allocator);
    defer context_schema.deinit();
    try schema(command.Context, .capabilities, "", &context_schema.writer);
    var context = try std.json.parseFromSlice(std.json.Value, allocator, context_schema.written(), .{});
    defer context.deinit();
    const names = comptime blk: {
        var out: [@typeInfo(Kind).@"enum".field_names.len][]const u8 = undefined;
        for (@typeInfo(Kind).@"enum".field_names, 0..) |field, i| out[i] = field;
        break :blk out;
    };
    const text = try std.json.Stringify.valueAlloc(allocator, .{
        .api_version = version,
        .platform = @tagName(@import("builtin").os.tag),
        .methods = names,
        .features = .{ "command_discovery", "typed_arguments", "strict_validation", "invocation_context", "htp_command_bridge", "external_events", "completion_waits", "background_jobs" },
        .context = .{ .pane_id = "Caller pane id; 0 means unknown. Not a target or credential.", .origin = "cli | api | internal; advisory, supplied by caller." },
        .context_schema = context.value,
        .transport = "command socket and HTP command_api bridge; file requires an external consumer; no new listener or arbitrary code execution",
    }, .{});
    defer allocator.free(text);
    return jsonValue(allocator, text);
}

fn jsonValue(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    return command.cloneJsonValue(allocator, parsed.value);
}

test "every command has a discoverable contract and a parseable example" {
    const a = std.testing.allocator;
    const list = try listValue(a);
    defer command.deinitJsonValue(a, list);
    try std.testing.expectEqual(@typeInfo(Kind).@"enum".field_names.len, list.array.items.len);
    for (list.array.items) |entry| {
        var method = try std.json.parseFromValue(results.Method, a, entry, .{});
        method.deinit();
        const example = entry.object.get("request_example").?;
        const text = try std.json.Stringify.valueAlloc(a, example, .{});
        defer a.free(text);
        var parsed = try command.parseEnvelope(a, text);
        defer parsed.deinit(a);
        try std.testing.expectEqualStrings(entry.object.get("name").?.string, @tagName(parsed.request.kind()));
        try std.testing.expect(!entry.object.get("input_schema").?.object.get("additionalProperties").?.bool);
    }
}

test "strict command parsing rejects malformed and cross-command arguments" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "{\"kind\":\"pane_send_text\"}",
        "{\"kind\":\"pane_send_text\",\"text\":42}",
        "{\"kind\":\"get_revision\",\"text\":\"ignored before\"}",
        "{\"kind\":\"get_pane\",\"id\":-1}",
        "{\"kind\":\"get_pane\",\"id\":1.0}",
        "{\"kind\":\"pane_split\",\"direction\":\"diagonal\"}",
        "{\"kind\":\"pane_split\",\"direction\":\"vertical\",\"ratio\":1}",
        "{\"kind\":\"pane_set_tags\",\"tags\":[\"one\",1]}",
        "{\"kind\":\"wait_revision\",\"revision\":1.0}",
        "{\"kind\":\"pane_bell\",\"color\":\"red\"}",
        "{\"kind\":\"get_pane\",\"ctx\":{\"typo\":1}}",
        "{\"kind\":\"get_pane\",\"ctx\":{\"pane_id\":1.0}}",
        "{\"kind\":\"get_revision\",\"typo\":null}",
        "{\"kind\":\"pane_close\"}",
        "{\"kind\":\"run\"}",
        "{\"kind\":\"pane_popup\",\"cmd\":\"top\",\"width\":1e300}",
    }) |text| {
        if (command.parseEnvelope(a, text)) |value| {
            var parsed = value;
            parsed.deinit(a);
            std.debug.print("unexpected valid command: {s}\n", .{text});
            return error.ExpectedInvalidCommand;
        } else |_| {}
    }
}

test "command parsing and discovery clean up every allocation failure" {
    const Probe = struct {
        fn parse(a: std.mem.Allocator) !void {
            var parsed = try command.parseEnvelope(a, "{\"kind\":\"emit\",\"ctx\":{\"pane_id\":7,\"origin\":\"api\"},\"channel\":\"example\",\"payload\":{\"nested\":[\"one\",{\"two\":2}]}}");
            defer parsed.deinit(a);
        }
        fn describe(a: std.mem.Allocator) !void {
            const value = try describeValue(a, .pane_split);
            defer command.deinitJsonValue(a, value);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.parse, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.describe, .{});
}

test "context and command aliases survive clone without borrowed memory" {
    const a = std.testing.allocator;
    var parsed = try command.parseEnvelope(a, "{\"kind\":\"pane_split\",\"pane_id\":7,\"direction\":\"vertical\",\"command\":\"echo hello\",\"generation\":null}");
    var cloned = try parsed.request.clone(a);
    parsed.deinit(a);
    defer cloned.deinit(a);
    try std.testing.expectEqual(@as(usize, 7), cloned.ctx.pane_id);
    try std.testing.expectEqualStrings("echo hello", cloned.data.pane_split.cmd.?);
}

test "capabilities enumerate the same methods and publish the context contract" {
    const a = std.testing.allocator;
    const value = try capabilitiesValue(a);
    defer command.deinitJsonValue(a, value);
    var parsed = try std.json.parseFromValue(Result(.capabilities), a, value, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, version), parsed.value.api_version);
    try std.testing.expectEqual(@typeInfo(Kind).@"enum".field_names.len, parsed.value.methods.len);
    const context_schema = value.object.get("context_schema").?.object;
    try std.testing.expect(!context_schema.get("additionalProperties").?.bool);
    try std.testing.expectEqual(@as(usize, 3), context_schema.get("properties").?.object.get("origin").?.object.get("enum").?.array.items.len);
}
