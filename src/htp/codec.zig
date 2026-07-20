const std = @import("std");

pub const osc_prefix = "\x1b]1337;Hollow;";
pub const string_terminator = "\x1b\\";
pub const max_chunk_payload = 3072;
pub const max_chunks = 256;
pub const max_assembly_bytes = max_chunks * max_chunk_payload;
pub const max_assemblies = 32;
pub const assembly_max_age_ns: i128 = 30 * std.time.ns_per_s;

pub const Envelope = struct {
    v: u8 = 1,
    id: u64,
    kind: []const u8,
    channel: ?[]const u8 = null,
    request_id: ?std.json.Value = null,
    status: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    payload: ?std.json.Value = null,
    params: ?std.json.Value = null,
};

pub const ChunkAssembly = struct {
    source_id: usize,
    request_id: []u8,
    total: usize,
    next_index: usize,
    created_at_ns: i128,
    buffer: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *ChunkAssembly, allocator: std.mem.Allocator) void {
        allocator.free(self.request_id);
        self.buffer.deinit(allocator);
    }
};

pub const Codec = struct {
    allocator: std.mem.Allocator,
    assemblies: std.ArrayListUnmanaged(ChunkAssembly) = .empty,
    next_message_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Codec {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Codec) void {
        for (self.assemblies.items) |*assembly| assembly.deinit(self.allocator);
        self.assemblies.deinit(self.allocator);
        self.* = init(self.allocator);
    }

    pub fn nextMessageId(self: *Codec) u64 {
        const value = self.next_message_id;
        self.next_message_id +%= 1;
        return value;
    }

    pub fn findOrCreateAssembly(self: *Codec, source_id: usize, request_id: []const u8, total: usize, now_ns: i128) !*ChunkAssembly {
        for (self.assemblies.items) |*assembly| {
            if (assembly.source_id == source_id and std.mem.eql(u8, assembly.request_id, request_id)) return assembly;
        }
        if (self.assemblies.items.len >= max_assemblies) return error.ResourceLimit;
        const owned_id = try self.allocator.dupe(u8, request_id);
        errdefer self.allocator.free(owned_id);
        try self.assemblies.append(self.allocator, .{
            .source_id = source_id,
            .request_id = owned_id,
            .total = total,
            .next_index = 1,
            .created_at_ns = now_ns,
        });
        return &self.assemblies.items[self.assemblies.items.len - 1];
    }

    pub fn removeAssembly(self: *Codec, source_id: usize, request_id: []const u8) void {
        var index: usize = 0;
        while (index < self.assemblies.items.len) : (index += 1) {
            const assembly = &self.assemblies.items[index];
            if (assembly.source_id != source_id or !std.mem.eql(u8, assembly.request_id, request_id)) continue;
            assembly.deinit(self.allocator);
            _ = self.assemblies.swapRemove(index);
            return;
        }
    }

    pub fn removeSource(self: *Codec, source_id: usize) void {
        var index: usize = 0;
        while (index < self.assemblies.items.len) {
            const assembly = &self.assemblies.items[index];
            if (assembly.source_id != source_id) {
                index += 1;
                continue;
            }
            assembly.deinit(self.allocator);
            _ = self.assemblies.swapRemove(index);
        }
    }

    pub fn prune(self: *Codec, now_ns: i128) void {
        var index: usize = 0;
        while (index < self.assemblies.items.len) {
            const assembly = &self.assemblies.items[index];
            if (now_ns >= assembly.created_at_ns and now_ns - assembly.created_at_ns >= assembly_max_age_ns) {
                assembly.deinit(self.allocator);
                _ = self.assemblies.swapRemove(index);
                continue;
            }
            index += 1;
        }
    }

    pub fn writeFramed(self: *Codec, json_text: []const u8, context: *anyopaque, sink: *const fn (*anyopaque, []const u8) void) !void {
        if (json_text.len <= max_chunk_payload) {
            var writer: std.Io.Writer.Allocating = .init(self.allocator);
            defer writer.deinit();
            try writer.writer.writeAll(osc_prefix);
            try writer.writer.writeAll(json_text);
            try writer.writer.writeAll(string_terminator);
            sink(context, writer.written());
            return;
        }

        const total = try std.math.divCeil(usize, json_text.len, max_chunk_payload);
        if (total > max_chunks) return error.ResourceLimit;
        var request_id_buf: [32]u8 = undefined;
        const request_id = try std.fmt.bufPrint(&request_id_buf, "{d}", .{self.nextMessageId()});
        var index: usize = 0;
        while (index < total) : (index += 1) {
            const start = index * max_chunk_payload;
            const end = @min(start + max_chunk_payload, json_text.len);
            const chunk = struct {
                v: u8 = 1,
                id: u64,
                kind: []const u8 = "chunk",
                request_id: []const u8,
                status: []const u8 = "partial",
                payload: struct {
                    index: usize,
                    total: usize,
                    data: []const u8,
                },
            }{
                .id = self.nextMessageId(),
                .request_id = request_id,
                .payload = .{
                    .index = index + 1,
                    .total = total,
                    .data = json_text[start..end],
                },
            };
            var writer: std.Io.Writer.Allocating = .init(self.allocator);
            defer writer.deinit();
            try writer.writer.writeAll(osc_prefix);
            try std.json.Stringify.value(chunk, .{}, &writer.writer);
            try writer.writer.writeAll(string_terminator);
            sink(context, writer.written());
        }
    }
};

test "codec assembly ownership is source scoped" {
    var codec = Codec.init(std.testing.allocator);
    defer codec.deinit();

    _ = try codec.findOrCreateAssembly(1, "request", 2, 0);
    _ = try codec.findOrCreateAssembly(2, "request", 2, 0);
    codec.removeSource(1);
    try std.testing.expectEqual(@as(usize, 1), codec.assemblies.items.len);
    try std.testing.expectEqual(@as(usize, 2), codec.assemblies.items[0].source_id);
}
