const std = @import("std");

pub const TransportKind = enum {
    ipc,
    osc,
};

pub const QueryRequest = struct {
    name: []const u8,
    params: []const u8,
    timeout_ms: u32,
};

pub const QueryResponse = struct {
    json: []u8,

    pub fn deinit(self: QueryResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.json);
    }
};

test "transport kinds remain stable" {
    try std.testing.expectEqualStrings("ipc", @tagName(TransportKind.ipc));
    try std.testing.expectEqualStrings("osc", @tagName(TransportKind.osc));
}

test "query request stores provided fields" {
    const request = QueryRequest{
        .name = "ping",
        .params = "{\"pane\":1}",
        .timeout_ms = 250,
    };

    try std.testing.expectEqualStrings("ping", request.name);
    try std.testing.expectEqualStrings("{\"pane\":1}", request.params);
    try std.testing.expectEqual(@as(u32, 250), request.timeout_ms);
}

test "query response deinit frees owned json buffer" {
    const json = try std.testing.allocator.dupe(u8, "{\"ok\":true}");
    const response = QueryResponse{ .json = json };

    response.deinit(std.testing.allocator);
}
