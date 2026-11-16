//! In-place owner upgrade payload. The old owner writes it to a memfd and
//! execs the new build with `session serve --handoff <fd>`; PTY masters, the
//! listen socket, and the owner lock stay open across the exec.
//!
//! Layout (little endian): magic, u32 format, u32 fallback path length,
//! fallback path, u64 metadata length, JSON `State`, then one u64-length
//! terminal blob per pane in `State` order.
const std = @import("std");

pub const magic = "HHO1";
pub const format: u32 = 1;
pub const max_bytes = 512 * 1024 * 1024;
const max_path = 4096;

pub const VtKind = enum { binary, vt };

pub const PaneState = struct {
    id: u32,
    pid: i32,
    master: i32,
    cols: u16,
    rows: u16,
    spawn: []const u8,
    close_on_exit: bool = false,
    status: ?i32 = null,
    exit_deadline: i64 = 0,
    vt: VtKind,
    /// Shell-reported foreground command; the VT snapshot does not carry it.
    foreground: []const u8 = "",
};

pub const SessionState = struct {
    id: []const u8,
    creator: @import("session_trace.zig").Identity = .{},
    next_pane: u64,
    revision: u64,
    layout: []const u8,
    panes: []const PaneState,
};

pub const DoomedState = struct { pid: i32, deadline: i64, killed: bool };

pub const State = struct {
    listen_fd: i32,
    lock_fd: i32,
    /// Keeps the fallback image (`/proc/self/fd/<exe_fd>`) executable.
    exe_fd: i32,
    /// Build that wrote this payload; the successor never hands back to it.
    predecessor: []const u8,
    /// Build the payload was written for. A different reader is the fallback.
    target: []const u8,
    sessions: []const SessionState,
    doomed: []const DoomedState = &.{},
};

pub const View = struct {
    fallback: []const u8,
    json: []const u8,
    /// Concatenated length-prefixed blobs; read them with `Blobs`.
    blobs: []const u8,
};

pub fn encode(a: std.mem.Allocator, fallback: []const u8, json: []const u8, blobs: []const []const u8) ![]u8 {
    if (fallback.len > max_path) return error.NameTooLong;
    var total: usize = magic.len + 8 + fallback.len + 8 + json.len;
    for (blobs) |blob| {
        if (blob.len > max_bytes) return error.ResourceExhausted;
        total += 8 + blob.len;
    }
    if (total > max_bytes) return error.ResourceExhausted;
    const out = try a.alloc(u8, total);
    var w: std.Io.Writer = .fixed(out);
    w.writeAll(magic) catch unreachable;
    w.writeInt(u32, format, .little) catch unreachable;
    w.writeInt(u32, @intCast(fallback.len), .little) catch unreachable;
    w.writeAll(fallback) catch unreachable;
    w.writeInt(u64, json.len, .little) catch unreachable;
    w.writeAll(json) catch unreachable;
    for (blobs) |blob| {
        w.writeInt(u64, blob.len, .little) catch unreachable;
        w.writeAll(blob) catch unreachable;
    }
    return out;
}

/// Header and fallback path only, so a reader that cannot decode the rest
/// can still hand the payload back to the build that wrote it.
pub fn fallbackPath(bytes: []const u8) ![]const u8 {
    if (bytes.len < magic.len + 8 or !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidHandoff;
    const len = std.mem.readInt(u32, bytes[magic.len + 4 ..][0..4], .little);
    if (len == 0 or len > max_path or len > bytes.len - magic.len - 8) return error.InvalidHandoff;
    return bytes[magic.len + 8 ..][0..len];
}

pub fn parse(bytes: []const u8) !View {
    const fallback = try fallbackPath(bytes);
    if (std.mem.readInt(u32, bytes[magic.len..][0..4], .little) != format) return error.HandoffFormatMismatch;
    var rest = bytes[magic.len + 8 + fallback.len ..];
    const json = try take(&rest);
    return .{ .fallback = fallback, .json = json, .blobs = rest };
}

pub const Blobs = struct {
    rest: []const u8,

    pub fn next(self: *Blobs) ![]const u8 {
        return take(&self.rest);
    }

    pub fn finish(self: Blobs) !void {
        if (self.rest.len != 0) return error.InvalidHandoff;
    }
};

fn take(rest: *[]const u8) ![]const u8 {
    if (rest.len < 8) return error.InvalidHandoff;
    const len = std.mem.readInt(u64, rest.*[0..8], .little);
    if (len > rest.len - 8) return error.InvalidHandoff;
    const value = rest.*[8..][0..@intCast(len)];
    rest.* = rest.*[8 + @as(usize, @intCast(len)) ..];
    return value;
}

/// Reads a payload fd with positioned reads, so a failed reader can pass
/// the same fd to the fallback build.
pub fn readFd(a: std.mem.Allocator, fd: c_int) ![]u8 {
    const linux = std.os.linux;
    const size = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(size) != .SUCCESS) return error.InvalidHandoff;
    if (size > max_bytes) return error.ResourceExhausted;
    const out = try a.alloc(u8, @intCast(size));
    errdefer a.free(out);
    var off: usize = 0;
    while (off < out.len) {
        const n = linux.pread(fd, out[off..].ptr, out.len - off, @intCast(off));
        switch (linux.errno(n)) {
            .SUCCESS => if (n == 0) return error.InvalidHandoff else {
                off += n;
            },
            .INTR => {},
            else => return error.InvalidHandoff,
        }
    }
    return out;
}

/// A memfd holding `bytes`. Close-on-exec; the caller clears it.
pub fn writeFd(bytes: []const u8) !c_int {
    const linux = std.os.linux;
    const rc = linux.memfd_create("hollow-handoff", linux.MFD.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return error.HandoffFailed;
    const fd: c_int = @intCast(rc);
    errdefer _ = linux.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = linux.pwrite(fd, bytes[off..].ptr, bytes.len - off, @intCast(off));
        switch (linux.errno(n)) {
            .SUCCESS => off += n,
            .INTR => {},
            else => return error.HandoffFailed,
        }
    }
    return fd;
}

test "handoff payload round-trips header, metadata, and pane blobs" {
    const a = std.testing.allocator;
    const bytes = try encode(a, "/old/agent", "{\"x\":1}", &.{ "first", "", "third" });
    defer a.free(bytes);
    try std.testing.expectEqualStrings("/old/agent", try fallbackPath(bytes));
    const view = try parse(bytes);
    try std.testing.expectEqualStrings("{\"x\":1}", view.json);
    var blobs: Blobs = .{ .rest = view.blobs };
    try std.testing.expectEqualStrings("first", try blobs.next());
    try std.testing.expectEqualStrings("", try blobs.next());
    try std.testing.expectEqualStrings("third", try blobs.next());
    try blobs.finish();
    try std.testing.expectError(error.InvalidHandoff, blobs.next());

    const fd = try writeFd(bytes);
    defer _ = std.os.linux.close(fd);
    const read = try readFd(a, fd);
    defer a.free(read);
    try std.testing.expectEqualSlices(u8, bytes, read);
}

test "handoff payload rejects truncation, bad magic, and other formats" {
    const a = std.testing.allocator;
    const bytes = try encode(a, "/old/agent", "{}", &.{"blob"});
    defer a.free(bytes);
    for (0..bytes.len) |len| {
        if (parse(bytes[0..len])) |view| {
            var blobs: Blobs = .{ .rest = view.blobs };
            try std.testing.expectError(error.InvalidHandoff, blobs.next());
        } else |_| {}
    }
    var copy = try a.dupe(u8, bytes);
    defer a.free(copy);
    copy[magic.len] +%= 1;
    try std.testing.expectError(error.HandoffFormatMismatch, parse(copy));
    // The fallback path survives a format the reader does not understand.
    try std.testing.expectEqualStrings("/old/agent", try fallbackPath(copy));
    copy[0] = 'X';
    try std.testing.expectError(error.InvalidHandoff, fallbackPath(copy));
    try std.testing.expectError(error.NameTooLong, encode(a, &(@as([max_path + 1]u8, @splat('a'))), "{}", &.{}));
}
