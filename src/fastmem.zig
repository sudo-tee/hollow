const builtin = @import("builtin");

pub inline fn copy(comptime T: type, dest: []T, source: []const T) void {
    if (builtin.link_libc) {
        _ = memcpy(dest.ptr, source.ptr, source.len * @sizeOf(T));
    } else {
        @memcpy(dest[0..source.len], source);
    }
}

pub inline fn move(comptime T: type, dest: []T, source: []const T) void {
    if (builtin.link_libc) {
        _ = memmove(dest.ptr, source.ptr, source.len * @sizeOf(T));
    } else {
        @memmove(dest, source);
    }
}

extern "c" fn memcpy(dest: *anyopaque, src: *const anyopaque, n: usize) *anyopaque;
extern "c" fn memmove(dest: *anyopaque, src: *const anyopaque, n: usize) *anyopaque;
