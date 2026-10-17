//! Small Lua-5.1 API adapter. Workers never retain Lua values or enter Lua.
const std = @import("std");
const runtime_io = @import("../io.zig");
const host = @import("../host.zig");
const table_type = 5;
const string_type = 4;
const number_type = 3;

fn manager(ctx: anytype) *host.Manager {
    if (ctx.host_manager == null) ctx.host_manager = host.Manager.init(ctx.allocator, runtime_io.get());
    return &ctx.host_manager.?;
}

pub fn connect(ctx: anytype, state: anytype) c_int {
    const handle = connectInner(ctx, state) catch |err| return fail(ctx.api, state, err, false);
    pushHandle(ctx.api, state, handle);
    return 1;
}

fn connectInner(ctx: anytype, state: anytype) !host.Handle {
    const api = ctx.api;
    const top = api.get_top(state);
    defer api.set_top(state, top);
    if (api.value_type(state, 1) != table_type) return error.InvalidArgument;
    const id = try requiredStringField(api, state, 1, "id");
    const backend = try stringField(api, state, 1, "backend");
    if (backend) |name| {
        if (std.mem.eql(u8, name, "local")) {
            api.get_field(state, 1, "argv");
            if (api.value_type(state, -1) != 0) return error.InvalidArgument;
            return manager(ctx).connectLocal(id);
        }
        if (!std.mem.eql(u8, name, "agent")) return error.InvalidArgument;
    }
    api.get_field(state, 1, "argv");
    const argv = try readArgv(ctx.allocator, api, state, api.get_top(state));
    defer ctx.allocator.free(argv);
    return manager(ctx).connectAgent(id, argv);
}

pub fn status(ctx: anytype, state: anytype) c_int {
    const handle = readHandle(ctx.api, state, 1) catch |err| return disconnected(ctx.api, state, err);
    const value = manager(ctx).status(handle) catch |err| return disconnected(ctx.api, state, err);
    const name = @tagName(value);
    ctx.api.push_lstring(state, name.ptr, name.len);
    if (value == .disconnected) {
        const failure: ?anyerror = manager(ctx).failure(handle) catch @as(?anyerror, error.StaleHost);
        pushError(ctx.api, state, failure orelse error.Disconnected);
        return 2;
    }
    return 1;
}

fn disconnected(api: anytype, state: anytype, err: anyerror) c_int {
    api.push_string(state, "disconnected");
    pushError(api, state, err);
    return 2;
}

pub fn close(ctx: anytype, state: anytype) c_int {
    const handle = readHandle(ctx.api, state, 1) catch |err| return fail(ctx.api, state, err, false);
    manager(ctx).close(handle) catch |err| return fail(ctx.api, state, err, false);
    ctx.api.push_boolean(state, 1);
    return 1;
}

pub fn start(ctx: anytype, state: anytype) c_int {
    const ticket = startInner(ctx, state) catch |err| return fail(ctx.api, state, err, false);
    pushHandle(ctx.api, state, ticket.host);
    pushId(ctx.api, state, ticket.id);
    ctx.api.set_field(state, -2, "id");
    return 1;
}

fn startInner(ctx: anytype, state: anytype) !host.Ticket {
    const api = ctx.api;
    const top = api.get_top(state);
    defer api.set_top(state, top);
    const handle = try readHandle(api, state, 1);
    const op = try readString(api, state, 2);
    if (api.value_type(state, 3) != table_type) return error.InvalidArgument;
    if (std.mem.eql(u8, op, "info")) return manager(ctx).request(handle, .{ .info = {} }, 30000);
    if (std.mem.eql(u8, op, "stat")) return manager(ctx).request(handle, .{ .stat = try requiredStringField(api, state, 3, "path") }, 30000);
    if (std.mem.eql(u8, op, "list")) return manager(ctx).request(handle, .{ .list = .{
        .path = try requiredStringField(api, state, 3, "path"),
        .offset = try integerField(api, state, 3, "offset", 0, 1000000),
        .limit = @intCast(try integerField(api, state, 3, "limit", 128, 256)),
    } }, 30000);
    if (std.mem.eql(u8, op, "read")) return manager(ctx).request(handle, .{ .read = .{
        .path = try requiredStringField(api, state, 3, "path"),
        .offset = try integerField(api, state, 3, "offset", 0, 9007199254740991),
        .limit = @intCast(try integerField(api, state, 3, "limit", 16384, 16384)),
    } }, 30000);
    if (!std.mem.eql(u8, op, "exec")) return error.InvalidArgument;
    api.get_field(state, 3, "argv");
    const argv = try readArgv(ctx.allocator, api, state, api.get_top(state));
    defer ctx.allocator.free(argv);
    pop(api, state);
    const cwd = try stringField(api, state, 3, "cwd");
    const timeout = try integerField(api, state, 3, "timeout_ms", 30000, 86400000);
    const limit = try integerField(api, state, 3, "output_limit", 1048576, 1048576);
    api.get_field(state, 3, "env");
    var env: std.ArrayList(host.operations.Env) = .empty;
    defer env.deinit(ctx.allocator);
    if (api.value_type(state, -1) != 0) {
        if (api.value_type(state, -1) != table_type) return error.InvalidArgument;
        const index = api.get_top(state);
        api.push_nil(state);
        while (api.next(state, index) != 0) {
            if (env.items.len == 4096) return error.InvalidArgument;
            try env.append(ctx.allocator, .{ .key = try readString(api, state, -2), .value = try readString(api, state, -1) });
            pop(api, state);
        }
    }
    return manager(ctx).request(handle, .{ .exec = .{ .argv = argv, .cwd = cwd, .env = env.items, .timeout_ms = timeout, .output_limit = @intCast(limit) } }, @min(timeout + 3000, 86400000));
}

pub fn poll(ctx: anytype, state: anytype) c_int {
    const ticket = readTicket(ctx.api, state, 1) catch |err| return fail(ctx.api, state, err, true);
    var result = (manager(ctx).poll(ticket) catch |err| {
        manager(ctx).discardCompleted(ticket);
        return fail(ctx.api, state, err, true);
    }) orelse return 0;
    defer result.deinit();
    switch (result.value) {
        .failure => |value| {
            ctx.api.create_table(state, 0, 1);
            pushValue(ctx.api, state, value);
            ctx.api.set_field(state, -2, "error");
        },
        inline else => |value| pushValue(ctx.api, state, value),
    }
    return 1;
}

pub fn cancel(ctx: anytype, state: anytype) c_int {
    const ticket = readTicket(ctx.api, state, 1) catch |err| return fail(ctx.api, state, err, false);
    manager(ctx).cancel(ticket) catch |err| return fail(ctx.api, state, err, false);
    ctx.api.push_boolean(state, 1);
    return 1;
}

fn readArgv(allocator: std.mem.Allocator, api: anytype, state: anytype, index: c_int) ![]const []const u8 {
    if (api.value_type(state, index) != table_type) return error.InvalidArgument;
    var count: usize = 0;
    api.push_nil(state);
    while (api.next(state, index) != 0) {
        if (api.value_type(state, -2) != number_type) return error.InvalidArgument;
        const key = api.to_number(state, -2);
        if (!std.math.isFinite(key) or key != @floor(key) or key < 1 or key > 4096) return error.InvalidArgument;
        _ = try readString(api, state, -1);
        count += 1;
        if (count > 4096) return error.InvalidArgument;
        pop(api, state);
    }
    if (count == 0) return error.InvalidArgument;
    const argv = try allocator.alloc([]const u8, count);
    errdefer allocator.free(argv);
    for (argv, 0..) |*item, i| {
        api.rawgeti(state, index, @intCast(i + 1));
        item.* = try readString(api, state, -1);
        pop(api, state);
    }
    return argv;
}

fn readString(api: anytype, state: anytype, index: c_int) ![]const u8 {
    if (api.value_type(state, index) != string_type) return error.InvalidArgument;
    var len: usize = 0;
    const bytes = api.to_lstring(state, index, &len) orelse return error.InvalidArgument;
    return bytes[0..len];
}

fn stringField(api: anytype, state: anytype, index: c_int, name: [:0]const u8) !?[]const u8 {
    api.get_field(state, index, name);
    defer pop(api, state);
    if (api.value_type(state, -1) == 0) return null;
    return try readString(api, state, -1);
}

fn requiredStringField(api: anytype, state: anytype, index: c_int, name: [:0]const u8) ![]const u8 {
    return try stringField(api, state, index, name) orelse error.InvalidArgument;
}

fn integerField(api: anytype, state: anytype, index: c_int, name: [:0]const u8, default: u64, max: u64) !u64 {
    api.get_field(state, index, name);
    defer pop(api, state);
    if (api.value_type(state, -1) == 0) return default;
    if (api.value_type(state, -1) != number_type) return error.InvalidArgument;
    const value = api.to_number(state, -1);
    if (!std.math.isFinite(value) or value < 0 or value != @floor(value) or value > @as(f64, @floatFromInt(max))) return error.InvalidArgument;
    return @intFromFloat(value);
}

fn readHandle(api: anytype, state: anytype, index: c_int) !host.Handle {
    if (api.value_type(state, index) != table_type) return error.StaleHost;
    const slot = try integerField(api, state, index, "slot", 0, host.max_hosts);
    if (slot == 0) return error.StaleHost;
    const generation = try readIdField(api, state, index, "generation");
    return .{ .slot = @intCast(slot - 1), .generation = generation };
}

fn readTicket(api: anytype, state: anytype, index: c_int) !host.Ticket {
    return .{ .host = try readHandle(api, state, index), .id = try readIdField(api, state, index, "id") };
}

fn readIdField(api: anytype, state: anytype, index: c_int, name: [:0]const u8) !u64 {
    const bytes = try requiredStringField(api, state, index, name);
    if (bytes.len == 0 or bytes.len > 20) return error.InvalidArgument;
    for (bytes) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidArgument;
    const id = std.fmt.parseInt(u64, bytes, 10) catch return error.InvalidArgument;
    if (id == 0) return error.InvalidArgument;
    return id;
}

fn pushHandle(api: anytype, state: anytype, handle: host.Handle) void {
    api.create_table(state, 0, 2);
    api.push_integer(state, @as(isize, handle.slot) + 1);
    api.set_field(state, -2, "slot");
    pushId(api, state, handle.generation);
    api.set_field(state, -2, "generation");
}

fn pushId(api: anytype, state: anytype, id: u64) void {
    var buffer: [24]u8 = undefined;
    const bytes = std.fmt.bufPrint(&buffer, "{d}", .{id}) catch unreachable;
    api.push_lstring(state, bytes.ptr, bytes.len);
}

fn pop(api: anytype, state: anytype) void {
    api.set_top(state, -2);
}

fn fail(api: anytype, state: anytype, err: anyerror, result: bool) c_int {
    if (result) {
        api.create_table(state, 0, 1);
        pushError(api, state, err);
        api.set_field(state, -2, "error");
        return 1;
    }
    api.push_nil(state);
    pushError(api, state, err);
    return 2;
}

fn pushError(api: anytype, state: anytype, err: anyerror) void {
    const code: []const u8 = switch (err) {
        error.StaleHost, error.StaleRequest => "session_gone",
        error.Disconnected => "transport_disconnected",
        error.Timeout => "timeout",
        error.ProtocolMismatch => "protocol_mismatch",
        error.ResourceExhausted, error.OutOfMemory => "resource_exhausted",
        error.NotReady => "not_ready",
        error.InvalidArgument, error.InvalidPayload => "invalid_argument",
        error.AlreadyConnected => "already_connected",
        else => "io_error",
    };
    pushValue(api, state, host.operations.Failure{ .code = code, .message = @errorName(err) });
}

fn pushValue(api: anytype, state: anytype, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => |fields| {
            api.create_table(state, 0, fields.fields.len);
            inline for (fields.fields) |field| {
                pushValue(api, state, @field(value, field.name));
                api.set_field(state, -2, field.name);
            }
        },
        .pointer => |pointer| {
            if (pointer.child == u8) api.push_lstring(state, value.ptr, value.len) else {
                api.create_table(state, @intCast(value.len), 0);
                for (value, 0..) |item, i| {
                    pushValue(api, state, item);
                    api.rawseti(state, -2, @intCast(i + 1));
                }
            }
        },
        .optional => if (value) |item| pushValue(api, state, item) else api.push_nil(state),
        .bool => api.push_boolean(state, @intFromBool(value)),
        .int => {
            // Lua 5.1 numbers cannot exactly represent all u64 filesystem sizes.
            // Preserve oversized integers as decimal strings, never round them.
            const wide: i128 = value;
            if (wide > 9007199254740991 or wide < -9007199254740991) {
                var buffer: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
                api.push_lstring(state, text.ptr, text.len);
            } else api.push_number(state, @floatFromInt(value));
        },
        else => @compileError("unsupported host Lua value"),
    }
}
