//! Opt-in, bounded frame samples. Output is written only at orderly shutdown.
const std = @import("std");
const builtin = @import("builtin");
const io = @import("../io.zig");

const FileTime = extern struct { low: u32, high: u32 };
extern "kernel32" fn GetCurrentThread() callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetThreadTimes(?*anyopaque, *FileTime, *FileTime, *FileTime, *FileTime) callconv(.winapi) i32;

fn ticks(t: FileTime) u64 {
    return (@as(u64, t.high) << 32) | t.low;
}

fn threadCpuNs() ?u64 {
    if (comptime builtin.os.tag != .windows) return null;
    var created: FileTime = undefined;
    var exited: FileTime = undefined;
    var kernel: FileTime = undefined;
    var user: FileTime = undefined;
    if (GetThreadTimes(GetCurrentThread(), &created, &exited, &kernel, &user) == 0) return null;
    return (ticks(kernel) + ticks(user)) * 100;
}

const Sample = struct { start: i128, elapsed: i128, cpu: ?u64, active_wall: ?i128, rendered: bool };
const max_samples = 200_000;
var samples: [max_samples]Sample = undefined;
var count: usize = 0;
var dropped: usize = 0;
var output_path: ?[]u8 = null;

pub fn init() void {
    output_path = io.getEnvVarOwned(std.heap.page_allocator, "HOLLOW_PROFILE_FRAMES") catch null;
}

pub const Start = struct { wall: i128, cpu: ?u64 };
pub fn start() ?Start {
    if (output_path == null) return null;
    return .{ .wall = io.nanoTimestamp(), .cpu = threadCpuNs() };
}

pub fn finish(begin: ?Start, rendered: bool, active_wall: ?i128) void {
    const b = begin orelse return;
    const end = io.nanoTimestamp();
    const cpu_end = threadCpuNs();
    if (count == samples.len) {
        dropped += 1;
        return;
    }
    samples[count] = .{ .start = b.wall, .elapsed = end - b.wall, .cpu = if (b.cpu != null and cpu_end != null and cpu_end.? >= b.cpu.?) cpu_end.? - b.cpu.? else null, .active_wall = active_wall, .rendered = rendered };
    count += 1;
}

pub fn deinit() void {
    const path = output_path orelse return;
    defer std.heap.page_allocator.free(path);
    output_path = null;
    const file = std.Io.Dir.createFileAbsolute(io.get(), path, .{}) catch return;
    defer file.close(io.get());
    var buffer: [8192]u8 = undefined;
    var writer = file.writer(io.get(), &buffer);
    writer.interface.print("# dropped={d}\nstart_ns,elapsed_ns,thread_cpu_ns,rendered,active_wall_ns\n", .{dropped}) catch return;
    for (samples[0..count]) |s| {
        if (s.cpu) |cpu| {
            writer.interface.print("{d},{d},{d},{d},", .{ s.start, s.elapsed, cpu, @intFromBool(s.rendered) }) catch return;
        } else {
            writer.interface.print("{d},{d},,{d},", .{ s.start, s.elapsed, @intFromBool(s.rendered) }) catch return;
        }
        if (s.active_wall) |active| writer.interface.print("{d}", .{active}) catch return;
        writer.interface.writeAll("\n") catch return;
    }
    writer.interface.flush() catch {};
}

test "FILETIME conversion" {
    try std.testing.expectEqual(@as(u64, 0x100000002), ticks(.{ .low = 2, .high = 1 }));
}
