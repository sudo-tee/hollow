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
