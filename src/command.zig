const std = @import("std");

pub const Kind = enum {
    get_pane,
    get_pane_text,
    get_screen,
    pane_screenshot,
    tab_screenshot,
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
    get_mux_tree,
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
    pane_bell,
    pane_set_tag,
    pane_remove_tag,
    pane_set_tags,
    send_keys,
    ui_click,
    wait_revision,
    events_subscribe,
    events_read,
    job_spawn,
    job_get,
    job_output,
    job_cleanup,
    focus,
    scroll,
    config_reload,
    config_theme,
    run,
    emit,
    api_list,
    api_describe,
    capabilities,
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

/// Invocation metadata, never an explicit target or an authorization credential.
pub const Context = struct {
    pane_id: usize = 0,
    origin: enum { cli, api, internal } = .internal,
};

pub const Empty = struct {};
pub const Id = struct { id: ?usize = null };
pub const RequiredId = struct { id: usize };
pub const Rename = struct { id: ?usize = null, name: []const u8 };
pub const Launch = struct { cmd: ?[]const u8 = null, cwd: ?[]const u8 = null, domain: ?[]const u8 = null };
pub const Run = struct { cmd: []const u8, cwd: ?[]const u8 = null, domain: ?[]const u8 = null };
pub const WorkspaceNew = struct { cmd: ?[]const u8 = null, cwd: ?[]const u8 = null, domain: ?[]const u8 = null, name: ?[]const u8 = null };
pub const Screenshot = struct { id: ?usize = null, path: []const u8 };
pub const Split = struct { direction: []const u8, cmd: ?[]const u8 = null, cwd: ?[]const u8 = null, domain: ?[]const u8 = null, ratio: ?f64 = null };
pub const Move = struct { id: ?usize = null, direction: []const u8, amount: ?f64 = null };
pub const PaneMove = struct { id: usize, direction: []const u8, amount: ?f64 = null };
pub const Text = struct { id: usize, text: []const u8 };
pub const Tag = struct { id: usize, tag: []const u8 };
pub const Direction = struct { direction: []const u8 };
pub const JobSpawn = struct { argv: ?[]const []const u8 = null, cmd: ?[]const u8 = null, cwd: ?[]const u8 = null, domain: ?[]const u8 = null, user_shell: bool = false };
pub const JobHandle = struct { id: usize, token: []const u8 };

/// Only fields belonging to the selected command can be represented.
pub const Command = union(Kind) {
    get_pane: Id,
    get_pane_text: Id,
    get_screen: Id,
    pane_screenshot: Screenshot,
    tab_screenshot: Screenshot,
    get_ui_nodes: Empty,
    get_revision: Empty,
    get_current_pane: Empty,
    get_tab: Id,
    get_current_tab: Empty,
    get_tabs: Empty,
    get_panes: struct { tag: ?[]const u8 = null },
    get_workspace: Id,
    get_current_workspace: Empty,
    get_workspaces: Empty,
    get_mux_tree: Empty,
    get_domain: Empty,
    get_htp: struct { id: ?usize = null, channel: []const u8, params: ?std.json.Value = null },
    workspace_new: WorkspaceNew,
    workspace_close: Id,
    workspace_next: Empty,
    workspace_prev: Empty,
    workspace_select: struct { index: usize },
    workspace_rename: Rename,
    tab_new: Launch,
    tab_close: Id,
    tab_next: Empty,
    tab_prev: Empty,
    tab_select: RequiredId,
    tab_rename: struct { id: usize, name: []const u8 },
    pane_split: Split,
    pane_popup: PanePopup,
    pane_close: RequiredId,
    pane_zoom: RequiredId,
    pane_float: RequiredId,
    pane_tile: RequiredId,
    pane_move: PaneMove,
    pane_resize: Move,
    pane_send_text: Text,
    pane_bell: struct { id: ?usize = null, level: ?[]const u8 = null, color: ?[]const u8 = null },
    pane_set_tag: Tag,
    pane_remove_tag: Tag,
    pane_set_tags: struct { id: usize, tags: []const []const u8 = &.{} },
    send_keys: Text,
    ui_click: struct { node_id: []const u8, surface: ?[]const u8 = null, generation: ?u64 = null },
    wait_revision: struct { revision: u64, timeout_ms: ?u64 = null },
    events_subscribe: Empty,
    events_read: struct { after: u64, id: ?usize = null, event: ?[]const u8 = null, command_id: ?u64 = null, timeout_ms: ?u64 = null },
    job_spawn: JobSpawn,
    job_get: JobHandle,
    job_output: JobHandle,
    job_cleanup: JobHandle,
    focus: Direction,
    scroll: Direction,
    config_reload: Empty,
    config_theme: struct { name: []const u8 },
    run: Run,
    emit: struct { id: ?usize = null, channel: []const u8, payload: ?std.json.Value = null },
    api_list: Empty,
    api_describe: struct { name: []const u8 },
    capabilities: Empty,
};

pub fn Args(comptime kind: Kind) type {
    return @FieldType(Command, @tagName(kind));
}

pub const Request = struct {
    ctx: Context = .{},
    data: Command,
    // Constructed requests borrow arguments. Parsed/cloned requests own an arena.
    arena: ?*std.heap.ArenaAllocator = null,

    pub fn kind(self: Request) Kind {
        return std.meta.activeTag(self.data);
    }

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        if (self.arena) |arena| {
            arena.deinit();
            allocator.destroy(arena);
            self.arena = null;
        }
    }

    pub fn clone(self: Request, allocator: std.mem.Allocator) !Request {
        const text = try encodeRequest(allocator, self);
        defer allocator.free(text);
        return (try parseEnvelope(allocator, text)).request;
    }

    pub fn setTargetId(self: *Request, id: usize) void {
        switch (self.data) {
            inline else => |*args| if (@hasField(@TypeOf(args.*), "id")) {
                args.id = id;
            },
        }
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
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const a = arena.allocator();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .allocate = .alloc_always });
    if (root != .object) return error.InvalidCommandEnvelope;
    var object = root.object;
    const kind_value = object.get("kind") orelse return error.MissingCommandKind;
    if (kind_value != .string) return error.InvalidCommandEnvelope;
    const kind = try parseKind(kind_value.string);
    _ = object.swapRemove("kind");
    var ctx: Context = .{};
    if (object.fetchSwapRemove("ctx")) |entry| {
        try contract.validateJson(Context, entry.value);
        ctx = try std.json.parseFromValueLeaky(Context, a, entry.value, .{});
    }
    // Legacy flat caller metadata remains accepted at the transport boundary.
    if (object.fetchSwapRemove("pane_id")) |entry| {
        if (ctx.pane_id != 0) return error.ConflictingContext;
        try contract.validateJson(usize, entry.value);
        ctx.pane_id = try std.json.parseFromValueLeaky(usize, a, entry.value, .{});
    }
    if (object.fetchSwapRemove("command")) |entry| {
        if (object.contains("cmd")) return error.ConflictingCommandAlias;
        try object.put(a, "cmd", entry.value);
    }
    // Older native clients serialized unrelated optional fields as null. Ignore
    // only those nulls; non-null unknown fields are always rejected.
    var i: usize = 0;
    while (i < object.count()) {
        if (object.values()[i] == .null and isLegacyField(object.keys()[i])) {
            _ = object.swapRemove(object.keys()[i]);
        } else i += 1;
    }
    const data: Command = switch (kind) {
        inline else => |tag| blk: {
            try contract.validateJson(Args(tag), .{ .object = object });
            break :blk @unionInit(Command, @tagName(tag), try std.json.parseFromValueLeaky(Args(tag), a, .{ .object = object }, .{}));
        },
    };
    try validate(data);
    return .{ .request = .{ .ctx = ctx, .data = data, .arena = arena } };
}

/// Keep the established flat wire names while encoding only this command's args.
pub fn encodeRequest(allocator: std.mem.Allocator, request: Request) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.writeAll("{\"kind\":");
    try std.json.Stringify.value(@tagName(request.kind()), .{}, &writer.writer);
    try writer.writer.writeAll(",\"ctx\":");
    try std.json.Stringify.value(request.ctx, .{}, &writer.writer);
    const args_json = switch (request.data) {
        inline else => |args| try std.json.Stringify.valueAlloc(allocator, args, .{ .emit_null_optional_fields = false }),
    };
    defer allocator.free(args_json);
    if (args_json.len > 2) {
        try writer.writer.writeByte(',');
        try writer.writer.writeAll(args_json[1 .. args_json.len - 1]);
    }
    try writer.writer.writeByte('}');
    return allocator.dupe(u8, writer.written());
}

fn isLegacyField(name: []const u8) bool {
    inline for (std.meta.fields(Command)) |variant| {
        inline for (std.meta.fields(variant.type)) |field| {
            if (std.mem.eql(u8, name, field.name)) return true;
        }
    }
    return false;
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
            for (arr.items) |item| {
                const value_copy = try cloneJsonValue(allocator, item);
                errdefer deinitJsonValue(allocator, value_copy);
                try out.append(value_copy);
            }
            return .{ .array = out };
        },
        .object => |obj| {
            var out: std.json.ObjectMap = .empty;
            errdefer {
                var it = out.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    deinitJsonValue(allocator, entry.value_ptr.*);
                }
                out.deinit(allocator);
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);
                const value_copy = try cloneJsonValue(allocator, entry.value_ptr.*);
                errdefer deinitJsonValue(allocator, value_copy);
                try out.put(allocator, key, value_copy);
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
            owned.deinit(allocator);
        },
        else => {},
    }
}

pub fn parseKind(text: []const u8) !Kind {
    return std.meta.stringToEnum(Kind, text) orelse error.UnknownCommandKind;
}

pub const contract = @import("command/contract.zig");
pub const validate = contract.validate;

test {
    _ = contract;
}
