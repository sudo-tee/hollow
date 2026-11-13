//! Runtime identity and deferred, empty-only owner retirement. Snapshot/VT
//! compatibility is independent of the executable that owns live sessions.
const std = @import("std");
const builtin = @import("builtin");
const p = @import("session_protocol.zig");

pub const Build = [64]u8;
pub const Probe = enum { legacy, current, retiring };
/// `session connect --upgrade`: how an outdated owner may be replaced.
/// `handoff` execs the new build in place (POSIX owners with live sessions),
/// `retire_empty` waits until the owner is empty, `never` leaves it alone.
pub const Mode = enum { handoff, retire_empty, never };

pub fn disposition(welcome: p.Welcome) !Probe {
    if (!std.mem.eql(u8, welcome.protocol, p.protocol) or welcome.version != p.version) return error.ProtocolMismatch;
    if (!p.hasFeature(welcome.features, "retire-empty")) return .legacy;
    return if (welcome.retiring) .retiring else .current;
}
// Debug agents include the terminal engine and can exceed 128 MiB. Hash in
// bounded chunks rather than allocating the image or depending on cache paths.
const max_executable = 256 * 1024 * 1024;

pub fn current(a: std.mem.Allocator, io: std.Io) !Build {
    if (builtin.os.tag == .linux) return fingerprint(io, "/proc/self/exe");
    const path = try std.process.executablePathAlloc(io, a);
    defer a.free(path);
    return fingerprint(io, path);
}

pub fn fingerprint(io: std.Io, path: []const u8) !Build {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size == 0 or stat.size > max_executable) return error.InvalidOwnerArtifact;
    // This is a compatibility fingerprint, not an authenticity check (managed
    // deployment already verifies SHA-256). Keep startup cheap for large Debug
    // images too; cryptographic hashing here can exceed handshake deadlines.
    var hashes = [_]std.hash.Wyhash{ .init(0), .init(1), .init(2), .init(3) };
    var reader = file.reader(io, &.{});
    var buf: [16 * 1024]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = reader.interface.readSliceShort(&buf) catch return reader.err orelse error.ReadFailed;
        if (n == 0) break;
        if (n > max_executable - total) return error.ResourceExhausted;
        total += n;
        for (&hashes) |*hash| hash.update(buf[0..n]);
    }
    if (total != stat.size) return error.InvalidOwnerArtifact;
    var digest: [32]u8 = undefined;
    for (&hashes, 0..) |*hash, i| std.mem.writeInt(u64, digest[i * 8 ..][0..8], hash.final(), .little);
    return std.fmt.bytesToHex(digest, .lower);
}

pub const Retirement = struct {
    build: ?Build = null,
    pending: bool = false,

    pub fn observe(self: *Retirement, wanted: []const u8) void {
        const build = self.build orelse return;
        if (wanted.len != build.len) return;
        for (wanted) |byte| if (!std.ascii.isHex(byte)) return;
        if (!std.mem.eql(u8, &build, wanted)) self.pending = true;
    }

    pub fn ready(self: *const Retirement, empty: bool) bool {
        return self.pending and empty;
    }

    pub fn identity(self: *const Retirement) []const u8 {
        return if (self.build) |*build| build else "";
    }
};

test "retirement waits for empty and never guesses an unknown runtime" {
    var retirement: Retirement = .{};
    retirement.observe(&(@as(Build, @splat('b'))));
    try std.testing.expect(!retirement.ready(true));
    retirement.build = @splat('a');
    retirement.observe("unknown");
    retirement.observe(&(@as(Build, @splat('z'))));
    retirement.observe(&(@as(Build, @splat('a'))));
    try std.testing.expect(!retirement.ready(true));
    retirement.observe(&(@as(Build, @splat('b'))));
    try std.testing.expect(!retirement.ready(false));
    try std.testing.expect(retirement.ready(true));
    retirement.observe(&(@as(Build, @splat('a'))));
    try std.testing.expect(retirement.ready(true));
}

test "runtime fingerprint tracks executable contents rather than path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const artifact = try std.fs.path.join(std.testing.allocator, &.{ path, "owner" });
    defer std.testing.allocator.free(artifact);
    try tmp.dir.writeFile(io, .{ .sub_path = "owner", .data = "first" });
    const first = try fingerprint(io, artifact);
    try tmp.dir.writeFile(io, .{ .sub_path = "owner", .data = "second" });
    const second = try fingerprint(io, artifact);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}

test "legacy welcomes never authorize retirement or a second hello on the same socket" {
    const old = try p.parse(p.Welcome, std.testing.allocator, "{\"ghostty\":\"old\",\"snapshot\":\"vt\",\"owner_pid\":1}");
    defer old.deinit();
    try std.testing.expectEqual(Probe.legacy, try disposition(old.value));
    var modern = old.value;
    modern.features = &p.owner_features;
    try std.testing.expectEqual(Probe.current, try disposition(modern));
    modern.retiring = true;
    try std.testing.expectEqual(Probe.retiring, try disposition(modern));
    modern.version += 1;
    try std.testing.expectError(error.ProtocolMismatch, disposition(modern));
}
