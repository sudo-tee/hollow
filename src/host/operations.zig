//! Typed RPC operations and owned response decoding for the host agent.
const std = @import("std");
const transport = @import("transport.zig");

pub const Operation = union(enum) {
    info: void,
    stat: []const u8,
    list: ListOptions,
    read: ReadOptions,
    exec: ExecOptions,
};
pub const Kind = std.meta.Tag(Operation);

pub const ListOptions = struct { path: []const u8, offset: u64 = 0, limit: u32 = 128 };
pub const ReadOptions = struct { path: []const u8, offset: u64 = 0, limit: u32 = 16384 };
pub const ExecOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: []const Env = &.{},
    timeout_ms: u64 = 30000,
    output_limit: usize = 1048576,
};
pub const Env = struct { key: []const u8, value: []const u8 };

pub const Failure = struct { code: []const u8, message: []const u8, truncated: bool = false };
pub const Info = struct {
    os: []const u8,
    arch: []const u8,
    cwd: []const u8,
    home: []const u8,
    protocol_major: u32,
    protocol_minor: u32,
    build: []const u8,
};
pub const Stat = struct { kind: []const u8, mode: u32, size: u64, mtime: i64 };
pub const Entry = struct { name: []const u8, kind: []const u8 };
pub const List = struct { entries: []const Entry, next_offset: ?u64, eof: bool };
pub const Read = struct { bytes: []const u8, eof: bool };
pub const Exec = struct { exit_code: i32, stdout: []const u8, stderr: []const u8 };
pub const Value = union(enum) { info: Info, stat: Stat, list: List, read: Read, exec: Exec, failure: Failure };

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    value: Value,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const max_payload = 1024 * 1024;

pub fn encode(allocator: std.mem.Allocator, operation: Operation, streams: ?transport.Streams) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    switch (operation) {
        .info => try w.writeAll("{\"op\":\"HOST_INFO\"}"),
        .stat => |path| {
            try validatePath(path);
            try w.writeAll("{\"op\":\"FS_STAT\",\"path_b64\":\"");
            try writeBase64(w, allocator, path);
            try w.writeAll("\"}");
        },
        .list => |opts| {
            try validatePath(opts.path);
            if (opts.offset > 1_000_000 or opts.limit > 256) return error.InvalidArgument;
            try w.print("{{\"op\":\"FS_LIST\",\"path_b64\":\"", .{});
            try writeBase64(w, allocator, opts.path);
            try w.print("\",\"offset\":{d},\"limit\":{d}}}", .{ opts.offset, opts.limit });
        },
        .read => |opts| {
            try validatePath(opts.path);
            if (opts.limit > 16384 or opts.offset > std.math.maxInt(i64)) return error.InvalidArgument;
            try w.writeAll("{\"op\":\"FS_READ\",\"path_b64\":\"");
            try writeBase64(w, allocator, opts.path);
            try w.print("\",\"offset\":{d},\"limit\":{d}}}", .{ opts.offset, opts.limit });
        },
        .exec => |opts| {
            const stream_ids = streams orelse return error.InvalidArgument;
            try validateExec(opts, stream_ids);
            try w.writeAll("{\"op\":\"EXEC\",\"argv_b64\":[");
            for (opts.argv, 0..) |arg, i| {
                if (i != 0) try w.writeByte(',');
                try w.writeByte('"');
                try writeBase64(w, allocator, arg);
                try w.writeByte('"');
            }
            try w.writeAll("],\"env_b64\":[");
            for (opts.env, 0..) |item, i| {
                if (i != 0) try w.writeByte(',');
                try w.writeAll("{\"key_b64\":\"");
                try writeBase64(w, allocator, item.key);
                try w.writeAll("\",\"value_b64\":\"");
                try writeBase64(w, allocator, item.value);
                try w.writeAll("\"}");
            }
            try w.writeAll("]");
            if (opts.cwd) |cwd| {
                try w.writeAll(",\"cwd_b64\":\"");
                try writeBase64(w, allocator, cwd);
                try w.writeByte('"');
            }
            try w.print(",\"timeout_ms\":{d},\"output_limit\":{d},\"stdout_stream_id\":{d},\"stderr_stream_id\":{d}}}", .{ opts.timeout_ms, opts.output_limit, stream_ids.stdout, stream_ids.stderr });
        },
    }
    if (out.written().len > max_payload) return error.InvalidArgument;
    return out.toOwnedSlice();
}

pub fn decode(allocator: std.mem.Allocator, kind: Kind, completion: transport.Completion) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    if (completion.failure) |failure| {
        if (failure == error.RemoteError) {
            if (completion.stdout.len != 0 or completion.stderr.len != 0) return error.ProtocolMismatch;
            const metadata = completion.metadata_json orelse return error.ProtocolMismatch;
            const parsed_error = std.json.parseFromSlice(std.json.Value, a, metadata, .{ .max_value_len = transport.max_metadata }) catch |err| return if (err == error.OutOfMemory) err else error.ProtocolMismatch;
            if (parsed_error.value != .object) return error.ProtocolMismatch;
            const code = try stringField(a, parsed_error.value, "code");
            const message = try stringField(a, parsed_error.value, "message");
            const truncated = if (parsed_error.value.object.get("truncated")) |v| blk: {
                if (v != .bool) return error.ProtocolMismatch;
                break :blk v.bool;
            } else false;
            return .{ .arena = arena, .value = .{ .failure = .{ .code = code, .message = message, .truncated = truncated } } };
        }
        const value: Value = .{ .failure = .{ .code = failureCode(failure), .message = failureMessage(failure) } };
        return .{ .arena = arena, .value = value };
    }
    if (completion.stdout.len + completion.stderr.len > max_payload) return error.ProtocolMismatch;
    const meta = completion.metadata_json orelse return error.ProtocolMismatch;
    const parsed = std.json.parseFromSlice(std.json.Value, a, meta, .{ .max_value_len = transport.max_metadata }) catch |err| return if (err == error.OutOfMemory) err else error.ProtocolMismatch;
    const obj = parsed.value;
    if (obj != .object) return error.ProtocolMismatch;
    if ((kind == .info or kind == .stat or kind == .list) and (completion.stdout.len != 0 or completion.stderr.len != 0)) return error.ProtocolMismatch;
    if (kind == .read and completion.stderr.len != 0) return error.ProtocolMismatch;
    const value: Value = if (kind == .info) .{ .info = try parseInfo(a, obj) } else if (kind == .stat) .{ .stat = try parseStat(a, obj) } else if (kind == .list) .{ .list = try parseList(a, obj) } else if (kind == .read) .{ .read = try parseRead(a, obj, completion.stdout) } else .{ .exec = try parseExec(a, obj, completion) };
    return .{ .arena = arena, .value = value };
}

fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path.len > 4096 or hasNul(path)) return error.InvalidArgument;
}
fn validateExec(opts: ExecOptions, streams: transport.Streams) !void {
    if (opts.argv.len == 0 or opts.argv.len > 4096 or opts.timeout_ms == 0 or opts.timeout_ms > 86400000 or opts.output_limit > max_payload) return error.InvalidArgument;
    if (opts.argv[0].len == 0) return error.InvalidArgument;
    if (streams.stdout == 0 or streams.stderr == 0 or streams.stdout % 2 != 0 or streams.stderr % 2 != 0 or streams.stdout == streams.stderr) return error.InvalidArgument;
    var total: usize = 0;
    for (opts.argv) |arg| {
        if (arg.len > 131072 or hasNul(arg)) return error.InvalidArgument;
        total = std.math.add(usize, total, arg.len) catch return error.InvalidArgument;
        if (total >= max_payload) return error.InvalidArgument;
    }
    if (opts.cwd) |cwd| try validatePath(cwd);
    if (opts.env.len > 4096) return error.InvalidArgument;
    for (opts.env) |item| {
        if (item.key.len == 0 or item.key.len > 131072 or item.value.len > 131072 or hasNul(item.key) or hasNul(item.value) or std.mem.indexOfScalar(u8, item.key, '=') != null) return error.InvalidArgument;
        total = std.math.add(usize, total, item.key.len + item.value.len) catch return error.InvalidArgument;
        if (total >= max_payload) return error.InvalidArgument;
    }
}
fn hasNul(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0) != null;
}
fn writeBase64(w: *std.Io.Writer, allocator: std.mem.Allocator, bytes: []const u8) !void {
    const encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(bytes.len));
    defer allocator.free(encoded);
    try w.writeAll(encoder.encode(encoded, bytes));
}
fn field(obj: std.json.Value, name: []const u8) !std.json.Value {
    if (obj != .object) return error.ProtocolMismatch;
    return obj.object.get(name) orelse error.ProtocolMismatch;
}
fn stringField(a: std.mem.Allocator, obj: std.json.Value, name: []const u8) ![]const u8 {
    const v = try field(obj, name);
    if (v != .string) return error.ProtocolMismatch;
    return a.dupe(u8, v.string) catch return error.OutOfMemory;
}
fn intField(comptime T: type, obj: std.json.Value, name: []const u8) !T {
    const v = try field(obj, name);
    if (v != .integer) return error.ProtocolMismatch;
    return std.math.cast(T, v.integer) orelse error.ProtocolMismatch;
}
fn boolField(obj: std.json.Value, name: []const u8) !bool {
    const v = try field(obj, name);
    if (v != .bool) return error.ProtocolMismatch;
    return v.bool;
}
fn parseInfo(a: std.mem.Allocator, obj: std.json.Value) !Info {
    return .{ .os = try stringField(a, obj, "os"), .arch = try stringField(a, obj, "arch"), .cwd = try decodeB64(a, try stringField(a, obj, "cwd_b64"), 4096), .home = try decodeB64(a, try stringField(a, obj, "home_b64"), 4096), .protocol_major = try intField(u32, obj, "protocol_major"), .protocol_minor = try intField(u32, obj, "protocol_minor"), .build = try stringField(a, obj, "build") };
}
fn parseStat(a: std.mem.Allocator, obj: std.json.Value) !Stat {
    const kind = try stringField(a, obj, "kind");
    if (!validFsKind(kind)) return error.ProtocolMismatch;
    const size_signed = try intField(i64, obj, "size");
    if (size_signed < 0) return error.ProtocolMismatch;
    return .{ .kind = kind, .mode = try intField(u32, obj, "mode"), .size = @intCast(size_signed), .mtime = try intField(i64, obj, "mtime") };
}
fn parseList(a: std.mem.Allocator, obj: std.json.Value) !List {
    const arr = try field(obj, "entries");
    if (arr != .array or arr.array.items.len > 256) return error.ProtocolMismatch;
    const entries = try a.alloc(Entry, arr.array.items.len);
    for (arr.array.items, 0..) |item, i| {
        const name = try decodeB64(a, try stringField(a, item, "name_b64"), 4096);
        if (name.len == 0 or hasNul(name) or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.ProtocolMismatch;
        const k = if (item == .object and item.object.get("kind") != null) try stringField(a, item, "kind") else "unknown";
        if (!validFsKind(k)) return error.ProtocolMismatch;
        entries[i] = .{ .name = name, .kind = try a.dupe(u8, k) };
    }
    const nextv = try field(obj, "next_offset");
    const next: ?u64 = if (nextv == .null) null else if (nextv == .integer and nextv.integer >= 0) @intCast(nextv.integer) else return error.ProtocolMismatch;
    return .{ .entries = entries, .next_offset = next, .eof = try boolField(obj, "done") };
}
fn parseRead(a: std.mem.Allocator, obj: std.json.Value, bytes: []const u8) !Read {
    if (bytes.len > 16384) return error.ProtocolMismatch;
    if (try intField(u64, obj, "bytes") != bytes.len) return error.ProtocolMismatch;
    return .{ .bytes = try a.dupe(u8, bytes), .eof = try boolField(obj, "eof") };
}
fn parseExec(a: std.mem.Allocator, obj: std.json.Value, c: transport.Completion) !Exec {
    if (try intField(u64, obj, "stdout_bytes") != c.stdout.len or try intField(u64, obj, "stderr_bytes") != c.stderr.len) return error.ProtocolMismatch;
    if (try boolField(obj, "truncated")) return error.ProtocolMismatch;
    return .{ .exit_code = try intField(i32, obj, "exit_code"), .stdout = try a.dupe(u8, c.stdout), .stderr = try a.dupe(u8, c.stderr) };
}
fn decodeB64(a: std.mem.Allocator, text: []const u8, max: usize) ![]const u8 {
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(text) catch return error.ProtocolMismatch;
    if (size > max) return error.ProtocolMismatch;
    const result = try a.alloc(u8, size);
    decoder.decode(result, text) catch return error.ProtocolMismatch;
    return result;
}
fn validFsKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "file") or std.mem.eql(u8, kind, "directory") or std.mem.eql(u8, kind, "symlink") or std.mem.eql(u8, kind, "other") or std.mem.eql(u8, kind, "unknown");
}
fn failureCode(err: anyerror) []const u8 {
    return switch (err) {
        error.Timeout => "timeout",
        error.Disconnected => "transport_disconnected",
        error.ProtocolMismatch => "protocol_mismatch",
        error.OutputLimit => "output_limit",
        else => "io_error",
    };
}
fn failureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.Timeout => "request timed out",
        error.Disconnected => "transport disconnected",
        error.ProtocolMismatch => "transport protocol mismatch",
        error.OutputLimit => "output limit exceeded",
        else => "transport I/O error",
    };
}
