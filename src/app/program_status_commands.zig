const std = @import("std");
const App = @import("../app.zig").App;
const command = @import("../command.zig");
const ghostty = @import("../term/ghostty.zig");
const status = @import("../term/program_status.zig");

pub fn handles(channel: []const u8) bool {
    return std.mem.eql(u8, channel, "program_status_get") or
        std.mem.eql(u8, channel, "program_status_set") or
        std.mem.eql(u8, channel, "program_status_clear");
}

pub fn execute(app: *App, source_pane_id: usize, channel: []const u8, params: ?std.json.Value) !command.Response {
    const object = if (params) |value| switch (value) {
        .object => |obj| obj,
        else => return .fail("invalid_args", "params must be an object"),
    } else std.json.ObjectMap.empty;
    const pane_id = if (object.get("pane")) |value| switch (value) {
        .integer => |id| if (id > 0) std.math.cast(usize, id) orelse return .fail("invalid_args", "invalid pane id") else return .fail("invalid_args", "invalid pane id"),
        else => return .fail("invalid_args", "pane must be a positive integer"),
    } else if (source_pane_id != 0) source_pane_id else app.currentPaneIdValue();
    const pane = app.findPaneById(pane_id) orelse return .fail("invalid_args", "unknown pane id");
    pane.program_status.setFocused(app.activePane() == pane);
    const response = try apply(&pane.program_status, app.allocator, channel, object);
    if (response.success and pane.program_status.dirty) app.signalWake();
    return response;
}

fn string(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return "";
    return switch (value) {
        .string => |text| if (std.unicode.utf8ValidateSlice(text)) text else error.InvalidArgs,
        else => error.InvalidArgs,
    };
}

fn borrowed(text: []const u8) ghostty.String {
    return .{ .ptr = text.ptr, .len = text.len };
}

fn parseReport(channel: []const u8, object: std.json.ObjectMap) !ghostty.ProgramStatus {
    const id = try string(object, "id");
    if (id.len > 256) return error.InvalidArgs;
    for (id) |c| if (!(std.ascii.isAlphanumeric(c) or c == '/' or c == '_' or c == '-' or c == '.')) return error.InvalidArgs;
    const clearing = std.mem.eql(u8, channel, "program_status_clear");
    const state_text = try string(object, "state");
    const state: c_int = if (clearing) 5 else state: {
        for ([_][]const u8{ "idle", "working", "done", "blocked", "error" }, 0..) |name, index| {
            if (std.mem.eql(u8, name, state_text)) break :state @intCast(index);
        }
        return error.InvalidArgs;
    };
    const kind_text = try string(object, "kind");
    const kind: c_int = if (kind_text.len == 0) 0 else kind: {
        for ([_][]const u8{ "none", "permission", "question", "auth" }, 0..) |name, index| {
            if (std.mem.eql(u8, name, kind_text)) break :kind @intCast(index);
        }
        return error.InvalidArgs;
    };
    if (kind != 0 and state != 3) return error.InvalidArgs;
    const progress: i8 = if (object.get("progress")) |value| switch (value) {
        .integer => |number| if (number >= 0 and number <= 100 and (state == 1 or state == 3)) @intCast(number) else return error.InvalidArgs,
        else => return error.InvalidArgs,
    } else -1;
    const app = try string(object, "app");
    const title = try string(object, "title");
    const message = try string(object, "message");
    // Reject oversized IPC input before storing; State applies display sanitization.
    if (app.len > 256 or title.len > 512 or message.len > 2048) return error.InvalidArgs;
    return .{ .state = state, .kind = kind, .progress = progress, .id = borrowed(id), .app = borrowed(app), .title = borrowed(title), .message = borrowed(message) };
}

fn apply(records: *status.State, allocator: std.mem.Allocator, channel: []const u8, object: std.json.ObjectMap) !command.Response {
    if (std.mem.eql(u8, channel, "program_status_get")) return .ok(try snapshot(records, allocator));
    const report = parseReport(channel, object) catch return .fail("invalid_args", "invalid program status: check state, kind, progress, id and text limits");
    try records.apply(allocator, &report);
    return .ok(null);
}

fn snapshot(records: *const status.State, allocator: std.mem.Allocator) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer command.deinitJsonValue(allocator, .{ .array = array });
    for (records.records.items) |record| {
        // Serialize then parse to produce an independently owned JSON value.
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try std.json.Stringify.value(.{
            .id = record.id,
            .state = record.stateName(),
            .kind = @tagName(record.kind),
            .progress = if (record.progress >= 0) @as(?i8, record.progress) else null,
            .app = records.effectiveApp(record),
            .title = record.title,
            .message = record.message,
            .attention = record.attention,
        }, .{}, &out.writer);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.written(), .{});
        defer parsed.deinit();
        const value = try command.cloneJsonValue(allocator, parsed.value);
        array.append(value) catch |err| {
            command.deinitJsonValue(allocator, value);
            return err;
        };
    }
    return .{ .array = array };
}

test "program status commands replace, inspect inherited metadata, and clear subtrees" {
    const a = std.testing.allocator;
    var records: status.State = .{};
    defer records.deinit(a);
    const cases = [_]struct { channel: []const u8, json: []const u8 }{
        .{ .channel = "program_status_set", .json = "{\"state\":\"working\",\"app\":\"demo\",\"progress\":25}" },
        .{ .channel = "program_status_set", .json = "{\"state\":\"blocked\",\"kind\":\"permission\",\"id\":\"build/tests\"}" },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, a, case.json, .{});
        defer parsed.deinit();
        var response = try apply(&records, a, case.channel, parsed.value.object);
        defer response.deinit(a);
        try std.testing.expect(response.success);
    }
    var response = try apply(&records, a, "program_status_get", .empty);
    defer response.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), response.payload.?.array.items.len);
    try std.testing.expectEqualStrings("demo", response.payload.?.array.items[1].object.get("app").?.string);
    var clear = try std.json.parseFromSlice(std.json.Value, a, "{\"id\":\"build\"}", .{});
    defer clear.deinit();
    _ = try apply(&records, a, "program_status_clear", clear.value.object);
    try std.testing.expectEqual(@as(usize, 1), records.records.items.len);
    _ = try apply(&records, a, "program_status_clear", .empty);
    try std.testing.expectEqual(@as(usize, 0), records.records.items.len);
}

test "program status command validation is atomic" {
    const a = std.testing.allocator;
    var records: status.State = .{};
    defer records.deinit(a);
    for ([_][]const u8{
        "{}",                                            "{\"state\":\"bogus\"}",                  "{\"state\":\"working\",\"progress\":101}",
        "{\"state\":\"working\",\"progress\":2.5}",      "{\"state\":\"done\",\"kind\":\"auth\"}", "{\"state\":\"working\",\"message\":true}",
        "{\"state\":\"working\",\"id\":\"bad\\u001b\"}",
    }) |json| {
        var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
        defer parsed.deinit();
        var response = try apply(&records, a, "program_status_set", parsed.value.object);
        defer response.deinit(a);
        try std.testing.expect(!response.success);
        try std.testing.expectEqualStrings("invalid_args", response.status);
        try std.testing.expectEqual(@as(usize, 0), records.records.items.len);
    }
}

test "socket and OSC queries share state, pane targeting, and validation without Lua" {
    const a = std.testing.allocator;
    const mux = @import("../mux.zig");
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();
    app.mux = mux.Mux.init(a);
    defer {
        app.mux.?.workspaces.deinit(a);
        app.mux = null;
    }
    var workspace = mux.Workspace.init(a, 1);
    defer workspace.tabs.deinit(a);
    var tab = mux.Tab.init(a, 2);
    defer {
        if (tab.root_split) |root| {
            root.deinit(a);
            a.destroy(root);
        }
        tab.panes.deinit(a);
    }
    var pane = @import("../pane.zig").Pane.init(a);
    defer pane.program_status.deinit(a);
    try tab.appendPane(&pane);
    try workspace.appendTab(&tab);
    try app.mux.?.workspaces.append(a, &workspace);
    app.mux.?.active_workspace = &workspace;
    var params = try std.json.parseFromSlice(std.json.Value, a, "{\"state\":\"working\",\"progress\":40}", .{});
    defer params.deinit();
    var set = try @import("command_dispatcher.zig").executeCommand(app, .{
        .kind = .get_htp,
        .pane_id = @intFromPtr(&pane),
        .channel = "program_status_set",
        .params = params.value,
    });
    defer set.deinit(a);
    try std.testing.expect(set.success);
    var get = try @import("htp.zig").dispatchHtpQuerySync(app, @intFromPtr(&pane), "program_status_get", null);
    defer get.deinit(a);
    try std.testing.expect(get.success);
    try std.testing.expectEqual(@as(i64, 40), get.value.?.array.items[0].object.get("progress").?.integer);
    try std.testing.expect(!get.value.?.array.items[0].object.get("attention").?.bool);

    var background = mux.Workspace.init(a, 3);
    defer background.tabs.deinit(a);
    try app.mux.?.workspaces.append(a, &background);
    app.mux.?.active_workspace = &background;
    app.syncActivePaneChange(&pane, null);
    var blocked = try std.json.parseFromSlice(std.json.Value, a, "{\"state\":\"blocked\",\"kind\":\"permission\"}", .{});
    defer blocked.deinit();
    var report = try execute(app, @intFromPtr(&pane), "program_status_set", blocked.value);
    defer report.deinit(a);
    try std.testing.expect(report.success);
    try std.testing.expect(pane.program_status.needsAttention());
    var unread = try execute(app, @intFromPtr(&pane), "program_status_get", null);
    defer unread.deinit(a);
    try std.testing.expect(unread.payload.?.array.items[0].object.get("attention").?.bool);

    app.mux.?.active_workspace = &workspace;
    app.syncActivePaneChange(null, &pane);
    try std.testing.expect(!pane.program_status.needsAttention());
    var acknowledged = try execute(app, @intFromPtr(&pane), "program_status_get", null);
    defer acknowledged.deinit(a);
    try std.testing.expectEqualStrings("blocked", acknowledged.payload.?.array.items[0].object.get("state").?.string);
    try std.testing.expect(!acknowledged.payload.?.array.items[0].object.get("attention").?.bool);
    var active_report = try execute(app, @intFromPtr(&pane), "program_status_set", blocked.value);
    defer active_report.deinit(a);
    try std.testing.expect(!pane.program_status.needsAttention());
    app.mux.?.active_workspace = &background;
    app.syncActivePaneChange(&pane, null);
    try std.testing.expect(!pane.program_status.needsAttention());
    var repeated = try execute(app, @intFromPtr(&pane), "program_status_set", blocked.value);
    defer repeated.deinit(a);
    try std.testing.expect(pane.program_status.needsAttention());
    var unknown = try execute(app, 123, "program_status_get", null);
    defer unknown.deinit(a);
    try std.testing.expect(!unknown.success);
    const explicit_json = try std.fmt.allocPrint(a, "{{\"pane\":{d}}}", .{@intFromPtr(&pane)});
    defer a.free(explicit_json);
    var explicit = try std.json.parseFromSlice(std.json.Value, a, explicit_json, .{});
    defer explicit.deinit();
    var clear = try execute(app, 123, "program_status_clear", explicit.value);
    defer clear.deinit(a);
    try std.testing.expect(clear.success);
    try std.testing.expectEqual(@as(usize, 0), pane.program_status.records.items.len);
    try std.testing.expect(!pane.program_status.needsAttention());
}
