//! Incremental completed-job delivery for the explicitly gated scheduler experiment.
//! Captures stay owned by their existing bounded job until its terminal frame queues.
const std = @import("std");
const p = @import("protocol.zig");

pub const State = struct {
    ready: bool = false,
    stdout_offset: usize = 0,
    stderr_offset: usize = 0,
    worker_offset: usize = 0,
};

pub fn fitsBatch(queued: usize, size: usize, batch_limit: usize, hard_limit: usize) bool {
    if (size > hard_limit or queued > hard_limit - size) return false;
    // Metadata frames cannot be fragmented without changing the wire protocol.
    // Admit one oversized atomic frame only into an empty output buffer.
    return queued == 0 or (queued <= batch_limit and size <= batch_limit - queued);
}

pub const WorkerFrame = struct { bytes: []const u8, terminal: bool };

pub fn workerFrame(bytes: []const u8, offset: usize, id: u64, payload_limit: usize, data_limit: usize) !WorkerFrame {
    if (offset > bytes.len or bytes.len - offset < p.header_len) return error.InvalidWorkerResponse;
    const h = p.Header.decode(@ptrCast(bytes.ptr + offset)) catch return error.InvalidWorkerResponse;
    if (h.request_id != id or h.stream_id != 0 or h.payload_len > payload_limit or
        bytes.len - offset - p.header_len < h.payload_len) return error.InvalidWorkerResponse;
    const total = p.header_len + h.payload_len;
    const terminal = switch (h.kind) {
        .data => blk: {
            if (h.payload_len > data_limit) return error.InvalidWorkerResponse;
            break :blk false;
        },
        .response, .error_response => true,
        else => return error.InvalidWorkerResponse,
    };
    if (terminal != (offset + total == bytes.len)) return error.InvalidWorkerResponse;
    return .{ .bytes = bytes[offset..][0..total], .terminal = terminal };
}

test "bulk batches reserve atomic metadata exception only for an empty queue" {
    try std.testing.expect(fitsBatch(0, 100000, 65536, 4194304));
    try std.testing.expect(!fitsBatch(1, 100000, 65536, 4194304));
    try std.testing.expect(fitsBatch(32768, 32768, 65536, 4194304));
    try std.testing.expect(!fitsBatch(32768, 32769, 65536, 4194304));
    try std.testing.expect(!fitsBatch(0, 4194305, 65536, 4194304));
}

test "worker frames retain exact headers and require one final terminal frame" {
    const a = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    const data = try (p.Header{ .kind = .data, .request_id = 3, .payload_len = 2 }).encode();
    const end = try (p.Header{ .kind = .response, .request_id = 3, .payload_len = 2 }).encode();
    try bytes.appendSlice(a, &data);
    try bytes.appendSlice(a, "ab");
    try bytes.appendSlice(a, &end);
    try bytes.appendSlice(a, "{}");
    const first = try workerFrame(bytes.items, 0, 3, p.max_payload, p.max_data);
    try std.testing.expect(!first.terminal);
    try std.testing.expectEqualSlices(u8, bytes.items[0 .. p.header_len + 2], first.bytes);
    const last = try workerFrame(bytes.items, first.bytes.len, 3, p.max_payload, p.max_data);
    try std.testing.expect(last.terminal);
    try std.testing.expectError(error.InvalidWorkerResponse, workerFrame(bytes.items, 0, 4, p.max_payload, p.max_data));
    try std.testing.expectError(error.InvalidWorkerResponse, workerFrame(bytes.items[0 .. p.header_len + 2], 0, 3, p.max_payload, p.max_data));
    try std.testing.expectError(error.InvalidWorkerResponse, workerFrame(bytes.items, 0, 3, p.max_payload, 1));
    try std.testing.expectError(error.InvalidWorkerResponse, workerFrame(bytes.items[0..p.header_len], 0, 3, p.max_payload, p.max_data));
    try std.testing.expectError(error.InvalidWorkerResponse, workerFrame(bytes.items, bytes.items.len, 3, p.max_payload, p.max_data));
    try std.testing.expectError(error.InvalidWorkerResponse, workerFrame(bytes.items, first.bytes.len, 3, 1, p.max_data));
}
