const std = @import("std");

pub const Kind = enum {
    get_pane,
    get_pane_text,
    get_screen,
    get_ui_nodes,
    get_revision,
    get_current_pane,
    get_tab,
    get_current_tab,
    get_tabs,
    get_panes,
    get_workspace,
    get_current_workspace,
    get_workspaces,
    get_domain,
    get_htp,
    workspace_new,
    workspace_close,
    workspace_next,
    workspace_prev,
    workspace_select,
    workspace_rename,
    tab_new,
    tab_close,
    tab_next,
    tab_prev,
    tab_select,
    tab_rename,
    pane_split,
    pane_popup,
    pane_close,
    pane_zoom,
    pane_float,
    pane_tile,
    pane_move,
    pane_resize,
    pane_send_text,
    pane_set_tag,
    pane_remove_tag,
    pane_set_tags,
    send_keys,
    ui_click,
    wait_revision,
    focus,
    scroll,
    config_reload,
    config_theme,
    run,
    emit,
};

pub const Target = struct {
    id: ?usize = null,
    tag: ?[]const u8 = null,
};

pub const PanePopup = struct {
    cmd: []const u8,
    cwd: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    x: ?f64 = null,
    y: ?f64 = null,
    width: ?f64 = null,
    height: ?f64 = null,
};

pub const Request = struct {
    kind: Kind,
    pane_id: usize = 0,

    id: ?usize = null,
    index: ?usize = null,
    name: ?[]const u8 = null,
    cmd: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    direction: ?[]const u8 = null,
    amount: ?f64 = null,
    ratio: ?f64 = null,
    x: ?f64 = null,
    y: ?f64 = null,
    width: ?f64 = null,
    height: ?f64 = null,
    text: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    tags: ?[]const []const u8 = null,
    channel: ?[]const u8 = null,
    surface: ?[]const u8 = null,
    node_id: ?[]const u8 = null,
    generation: ?u64 = null,
    revision: ?u64 = null,
    timeout_ms: ?u64 = null,
    params: ?std.json.Value = null,
    payload: ?std.json.Value = null,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        if (self.name) |value| allocator.free(value);
        if (self.cmd) |value| allocator.free(value);
        if (self.cwd) |value| allocator.free(value);
        if (self.domain) |value| allocator.free(value);
        if (self.direction) |value| allocator.free(value);
        if (self.text) |value| allocator.free(value);
        if (self.tag) |value| allocator.free(value);
        if (self.channel) |value| allocator.free(value);
        if (self.surface) |value| allocator.free(value);
        if (self.node_id) |value| allocator.free(value);
        if (self.tags) |values| {
            for (values) |value| allocator.free(value);
            allocator.free(values);
        }
        if (self.params) |value| deinitJsonValue(allocator, value);
        if (self.payload) |value| deinitJsonValue(allocator, value);
    }
};

pub const ParsedEnvelope = struct {
    request: Request,

    pub fn deinit(self: *ParsedEnvelope, allocator: std.mem.Allocator) void {
        self.request.deinit(allocator);
    }
};

pub const Response = struct {
    success: bool = true,
    status: []const u8 = "ok",
    error_message: ?[]u8 = null,
    payload: ?std.json.Value = null,
    owns_error_message: bool = false,
    owns_status: bool = false,

    pub fn ok(payload: ?std.json.Value) Response {
        return .{ .payload = payload };
    }

    pub fn fail(status: []const u8, message: []const u8) Response {
        return .{ .success = false, .status = status, .error_message = @constCast(message) };
    }

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        if (self.owns_status) allocator.free(self.status);
        if (self.owns_error_message) {
            if (self.error_message) |message| allocator.free(message);
        }
        if (self.payload) |value| deinitJsonValue(allocator, value);
    }
};

pub fn parseEnvelope(allocator: std.mem.Allocator, text: []const u8) !ParsedEnvelope {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidCommandEnvelope,
    };

    const kind_text = jsonObjectString(root, "kind") orelse return error.MissingCommandKind;
    const request = try requestFromObject(allocator, root, kind_text);
    errdefer {
        var cleanup = request;
        cleanup.deinit(allocator);
    }

    return .{
        .request = request,
    };
}

pub fn writeResultJson(allocator: std.mem.Allocator, response: Response) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    if (!response.success) {
        try std.json.Stringify.value(.{
            .kind = "error",
            .status = response.status,
            .@"error" = response.error_message orelse "command failed",
        }, .{}, &out.writer);
        return try allocator.dupe(u8, out.written());
    }

    try std.json.Stringify.value(.{
        .kind = "result",
        .status = response.status,
        .payload = response.payload,
    }, .{}, &out.writer);
    return try allocator.dupe(u8, out.written());
}

pub fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    switch (value) {
        .null => return .null,
        .bool => |v| return .{ .bool = v },
        .integer => |v| return .{ .integer = v },
        .float => |v| return .{ .float = v },
        .number_string => |v| return .{ .number_string = try allocator.dupe(u8, v) },
        .string => |v| return .{ .string = try allocator.dupe(u8, v) },
        .array => |arr| {
            var out = std.json.Array.init(allocator);
            errdefer {
                for (out.items) |item| deinitJsonValue(allocator, item);
                out.deinit();
            }
            for (arr.items) |item| try out.append(try cloneJsonValue(allocator, item));
            return .{ .array = out };
        },
        .object => |obj| {
            var out = std.json.ObjectMap.init(allocator);
            errdefer {
                var it = out.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    deinitJsonValue(allocator, entry.value_ptr.*);
                }
                out.deinit();
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                try out.put(try allocator.dupe(u8, entry.key_ptr.*), try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            return .{ .object = out };
        },
    }
}

pub fn deinitJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .number_string => |v| allocator.free(v),
        .string => |v| allocator.free(v),
        .array => |arr| {
            for (arr.items) |item| deinitJsonValue(allocator, item);
            arr.deinit();
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

fn requestFromObject(allocator: std.mem.Allocator, root: std.json.ObjectMap, kind_text: []const u8) !Request {
    var request = Request{ .kind = try parseKind(kind_text) };
    errdefer request.deinit(allocator);
    request.pane_id = jsonObjectIndex(root, "pane_id") orelse 0;
    request.id = jsonObjectIndex(root, "id");
    request.index = jsonObjectIndex(root, "index");
    request.name = try jsonObjectStringOwned(allocator, root, "name");
    request.cmd = try jsonObjectStringOwned(allocator, root, "cmd");
    if (request.cmd == null) request.cmd = try jsonObjectStringOwned(allocator, root, "command");
    request.cwd = try jsonObjectStringOwned(allocator, root, "cwd");
    request.domain = try jsonObjectStringOwned(allocator, root, "domain");
    request.direction = try jsonObjectStringOwned(allocator, root, "direction");
    request.amount = jsonObjectFloat(root, "amount");
    request.ratio = jsonObjectFloat(root, "ratio");
    request.x = jsonObjectFloat(root, "x");
    request.y = jsonObjectFloat(root, "y");
    request.width = jsonObjectFloat(root, "width");
    request.height = jsonObjectFloat(root, "height");
    request.text = try jsonObjectStringOwned(allocator, root, "text");
    request.tag = try jsonObjectStringOwned(allocator, root, "tag");
    request.channel = try jsonObjectStringOwned(allocator, root, "channel");
    request.surface = try jsonObjectStringOwned(allocator, root, "surface");
    request.node_id = try jsonObjectStringOwned(allocator, root, "node_id");
    request.generation = try jsonObjectU64(root, "generation");
    request.revision = try jsonObjectU64(root, "revision");
    request.timeout_ms = try jsonObjectU64(root, "timeout_ms");
    request.params = try jsonObjectValueClone(allocator, root, "params");
    request.payload = try jsonObjectValueClone(allocator, root, "payload");
    request.tags = try jsonObjectStringArrayClone(allocator, root, "tags");
    return request;
}

fn parseKind(text: []const u8) !Kind {
    inline for (std.meta.fields(Kind)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(Kind, field.name);
    }
    return error.UnknownCommandKind;
}

fn jsonObjectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonObjectStringOwned(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = jsonObjectString(object, key) orelse return null;
    return try allocator.dupe(u8, value);
}

fn jsonObjectValueClone(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !?std.json.Value {
    const value = object.get(key) orelse return null;
    return try cloneJsonValue(allocator, value);
}

fn jsonObjectStringArrayClone(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !?[]const []const u8 {
    const value = object.get(key) orelse return null;
    const items = switch (value) {
        .array => |arr| arr.items,
        else => return null,
    };

    var out = try allocator.alloc([]const u8, items.len);
    var initialized_len: usize = 0;
    errdefer {
        for (out[0..initialized_len]) |item| allocator.free(item);
        allocator.free(out);
    }

    for (items, 0..) |item, index| {
        switch (item) {
            .string => |text| {
                out[index] = try allocator.dupe(u8, text);
                initialized_len += 1;
            },
            else => return error.InvalidCommandEnvelope,
        }
    }
    return out;
}

fn jsonObjectIndex(object: std.json.ObjectMap, key: []const u8) ?usize {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .float => |n| if (n >= 0 and std.math.floor(n) == n) @intFromFloat(n) else null,
        else => null,
    };
}

fn jsonObjectU64(object: std.json.ObjectMap, key: []const u8) !?u64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .integer => |n| if (n >= 0) @intCast(n) else error.InvalidCommandEnvelope,
        else => error.InvalidCommandEnvelope,
    };
}

fn jsonObjectFloat(object: std.json.ObjectMap, key: []const u8) ?f64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        else => null,
    };
}

test "parseEnvelope loads command envelope" {
    const text =
        "{" ++
        "\"kind\":\"pane_send_text\"," ++
        "\"pane_id\":7," ++
        "\"text\":\"ls\\n\"" ++
        "}";
    var parsed = try parseEnvelope(std.testing.allocator, text);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(.pane_send_text, parsed.request.kind);
    try std.testing.expectEqual(@as(usize, 7), parsed.request.pane_id);
    try std.testing.expectEqualStrings("ls\n", parsed.request.text.?);
}

test "parseEnvelope rejects mixed tags without invalid cleanup" {
    const text = "{\"kind\":\"pane_set_tags\",\"tags\":[\"one\",1]}";
    try std.testing.expectError(error.InvalidCommandEnvelope, parseEnvelope(std.testing.allocator, text));
}

test "parseEnvelope requires integer automation fields" {
    try std.testing.expectError(error.InvalidCommandEnvelope, parseEnvelope(std.testing.allocator, "{\"kind\":\"wait_revision\",\"revision\":1.0,\"timeout_ms\":100}"));
}

test "parseEnvelope accepts null optional automation fields" {
    var parsed = try parseEnvelope(std.testing.allocator, "{\"kind\":\"get_revision\",\"revision\":null,\"generation\":null,\"timeout_ms\":null}");
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.request.revision == null);
    try std.testing.expect(parsed.request.generation == null);
    try std.testing.expect(parsed.request.timeout_ms == null);
}
