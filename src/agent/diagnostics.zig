//! Process correlation and UTC log prefixes. Never writes to protocol stdout.
const std = @import("std");
const builtin = @import("builtin");
const io = struct {
    var runtime: std.Io = undefined;
    fn get() std.Io {
        return if (builtin.is_test) std.testing.io else runtime;
    }
};

pub fn init(runtime: std.Io) void {
    io.runtime = runtime;
}

var mutex: std.Io.Mutex = .init;
var instance: ?[32]u8 = null;
var instance_pid: u32 = 0;
var build: ?[64]u8 = null;
var build_checked = false;
var log_file: ?std.Io.File = null;
var log_mutex: std.Io.Mutex = .init;

/// Configure only before/after the owner loop, never while it is logging.
pub fn setLogFile(file: ?std.Io.File) void {
    log_file = file;
}

pub fn pid() u32 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

pub fn processId() [32]u8 {
    mutex.lockUncancelable(io.get());
    defer mutex.unlock(io.get());
    if (instance == null or instance_pid != pid()) {
        instance = randomId();
        instance_pid = pid();
    }
    return instance.?;
}

pub fn randomId() [32]u8 {
    var bytes: [16]u8 = undefined;
    std.Io.random(io.get(), &bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

/// Fingerprint once per process, never once per connection or log line.
pub fn buildId() [64]u8 {
    mutex.lockUncancelable(io.get());
    defer mutex.unlock(io.get());
    if (!build_checked) {
        build = @import("session_upgrade.zig").current(std.heap.page_allocator, io.get()) catch null;
        build_checked = true;
    }
    return build orelse @splat('0');
}

pub fn utcMillis() i64 {
    return @intCast(@divFloor(std.Io.Clock.real.now(io.get()).toNanoseconds(), std.time.ns_per_ms));
}

pub fn timestamp(w: *std.Io.Writer, millis: i64) !void {
    const positive: u64 = @intCast(@max(0, millis));
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = positive / 1000 };
    const day = seconds.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const time = seconds.getDaySeconds();
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        day.year,               @backingInt(month.month),  @as(u32, month.day_index) + 1,
        time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute(),
        positive % 1000,
    });
}

pub fn prefix(w: *std.Io.Writer, level: []const u8, scope: []const u8) !void {
    try timestamp(w, utcMillis());
    try w.print(" [{s}] pid={d} instance={s} scope={s} ", .{ level, pid(), &processId(), scope });
}

/// Owner stderr is redirected to owner.log by session startup.
pub fn stderrLog(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    prefix(&w, level.asText(), @tagName(scope)) catch return;
    w.print(format ++ "\n", args) catch return;
    if (log_file) |file| {
        log_mutex.lockUncancelable(io.get());
        defer log_mutex.unlock(io.get());
        var output = file.writer(io.get(), &.{});
        const stat = file.stat(io.get()) catch return;
        output.seekTo(stat.size) catch return;
        output.interface.writeAll(w.buffered()) catch {};
        return;
    }
    var output = std.Io.File.stderr().writer(io.get(), &.{});
    output.interface.writeAll(w.buffered()) catch {};
}

/// A gap is evidence of delayed execution, not proof of OS suspend.
pub const ExecutionGap = struct {
    previous_ms: ?i64 = null,

    pub fn observe(self: *ExecutionGap, now_ms: i64) ?i64 {
        const previous = self.previous_ms;
        self.previous_ms = now_ms;
        if (previous) |last| if (now_ms - last >= 30_000) return now_ms - last;
        return null;
    }
};

test "diagnostic UTC timestamp includes milliseconds" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try timestamp(&w, 0);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", w.buffered());
    w.end = 0;
    try timestamp(&w, 1_704_067_200_123);
    try std.testing.expectEqualStrings("2024-01-01T00:00:00.123Z", w.buffered());
}

test "diagnostic execution gaps do not label clock changes as suspend" {
    var gap: ExecutionGap = .{};
    try std.testing.expectEqual(null, gap.observe(100));
    try std.testing.expectEqual(null, gap.observe(110));
    try std.testing.expectEqual(@as(?i64, 30_000), gap.observe(30_110));
    try std.testing.expectEqual(null, gap.observe(0));
}
