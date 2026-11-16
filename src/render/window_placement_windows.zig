const std = @import("std");
const placement = @import("../window_placement.zig");

const Point = extern struct { x: i32, y: i32 };
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const MonitorInfo = extern struct {
    size: u32 = @sizeOf(MonitorInfo),
    monitor: Rect = std.mem.zeroes(Rect),
    work: Rect = std.mem.zeroes(Rect),
    flags: u32 = 0,
};
const WindowPlacement = extern struct {
    length: u32 = @sizeOf(WindowPlacement),
    flags: u32 = 0,
    show_cmd: u32 = 1,
    min_position: Point = .{ .x = -1, .y = -1 },
    max_position: Point = .{ .x = -1, .y = -1 },
    normal_position: Rect = std.mem.zeroes(Rect),
};

extern "user32" fn GetWindowPlacement(hwnd: *anyopaque, state: *WindowPlacement) callconv(.winapi) i32;
extern "user32" fn SetWindowPlacement(hwnd: *anyopaque, state: *const WindowPlacement) callconv(.winapi) i32;
extern "user32" fn GetWindowRect(hwnd: *anyopaque, rect: *Rect) callconv(.winapi) i32;
extern "user32" fn MonitorFromWindow(hwnd: *anyopaque, flags: u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetMonitorInfoW(monitor: *anyopaque, info: *MonitorInfo) callconv(.winapi) i32;

pub fn restore(hwnd: *anyopaque) void {
    const state = placement.load() orelse return;
    const native: WindowPlacement = .{
        .show_cmd = if (state.maximized) 3 else 1, // SW_SHOWMAXIMIZED / SW_SHOWNORMAL
        .normal_position = .{
            .left = state.x,
            .top = state.y,
            .right = state.x + state.width,
            .bottom = state.y + state.height,
        },
    };
    // Windows relocates completely off-screen placements onto an available
    // monitor. Keep workspace coordinates paired with GetWindowPlacement;
    // mixing these with SetWindowPos causes drift around taskbars.
    if (SetWindowPlacement(hwnd, &native) == 0) {
        std.log.warn("could not restore window placement", .{});
    } else {
        std.log.info("restored window placement: {d},{d} {d}x{d} maximized={}", .{ state.x, state.y, state.width, state.height, state.maximized });
    }
}

fn captureState(native: WindowPlacement, visible: ?Rect, work_offset: Point) placement.State {
    var rect = native.normal_position;
    if (native.show_cmd == 1) {
        if (visible) |bounds| {
            // Snap keeps the old unsnapped rcNormalPosition. Remember the
            // actual visible bounds, converted from screen to workspace units.
            rect = .{
                .left = bounds.left - work_offset.x,
                .top = bounds.top - work_offset.y,
                .right = bounds.right - work_offset.x,
                .bottom = bounds.bottom - work_offset.y,
            };
        }
    }
    return .{
        .x = rect.left,
        .y = rect.top,
        .width = rect.right - rect.left,
        .height = rect.bottom - rect.top,
        // WPF_RESTORETOMAXIMIZED preserves maximization when closed minimized.
        .maximized = native.show_cmd == 3 or (native.show_cmd == 2 and (native.flags & 2) != 0),
    };
}

pub fn save(hwnd: *anyopaque) void {
    var native: WindowPlacement = .{};
    if (GetWindowPlacement(hwnd, &native) == 0) return;
    var bounds: Rect = undefined;
    var monitor: MonitorInfo = .{};
    var visible: ?Rect = null;
    var offset: Point = .{ .x = 0, .y = 0 };
    if (native.show_cmd == 1 and GetWindowRect(hwnd, &bounds) != 0) {
        if (MonitorFromWindow(hwnd, 2)) |handle| {
            if (GetMonitorInfoW(handle, &monitor) != 0) {
                visible = bounds;
                offset = .{
                    .x = monitor.work.left - monitor.monitor.left,
                    .y = monitor.work.top - monitor.monitor.top,
                };
            }
        }
    }
    const state = captureState(native, visible, offset);
    placement.save(state) catch |err| {
        std.log.warn("could not save window placement: {}", .{err});
        return;
    };
    std.log.info("saved window placement: {d},{d} {d}x{d} maximized={}", .{ state.x, state.y, state.width, state.height, state.maximized });
}

test "snapped placement saves visible bounds rather than old unsnapped bounds" {
    const native: WindowPlacement = .{
        .normal_position = .{ .left = 338, .top = 338, .right = 1794, .bottom = 1277 },
    };
    const state = captureState(native, .{ .left = 1720, .top = 0, .right = 3440, .bottom = 1392 }, .{ .x = 0, .y = 0 });
    try std.testing.expectEqualDeep(placement.State{
        .x = 1720,
        .y = 0,
        .width = 1720,
        .height = 1392,
        .maximized = false,
    }, state);
    const offset_state = captureState(native, .{ .left = -1920, .top = 30, .right = -640, .bottom = 830 }, .{ .x = 40, .y = 30 });
    try std.testing.expectEqual(@as(i32, -1960), offset_state.x);
    try std.testing.expectEqual(@as(i32, 0), offset_state.y);
    try std.testing.expectEqual(@as(i32, 1280), offset_state.width);
}

test "maximized and minimized placements retain normal restore bounds" {
    var native: WindowPlacement = .{
        .show_cmd = 3,
        .normal_position = .{ .left = 100, .top = 200, .right = 1380, .bottom = 1000 },
    };
    const expected: placement.State = .{ .x = 100, .y = 200, .width = 1280, .height = 800, .maximized = true };
    const visible: Rect = .{ .left = 0, .top = 0, .right = 3440, .bottom = 1392 };
    try std.testing.expectEqualDeep(expected, captureState(native, visible, .{ .x = 0, .y = 0 }));
    native.show_cmd = 2;
    native.flags = 2;
    try std.testing.expectEqualDeep(expected, captureState(native, visible, .{ .x = 0, .y = 0 }));
}
