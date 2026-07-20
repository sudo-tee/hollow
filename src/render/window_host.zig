const std = @import("std");
const c = @import("sokol_c");

pub const Callbacks = struct {
    init: *const fn (?*anyopaque) callconv(.c) void,
    frame: *const fn (?*anyopaque) callconv(.c) void,
    cleanup: *const fn (?*anyopaque) callconv(.c) void,
    event: *const fn (?*const c.sapp_event, ?*anyopaque) callconv(.c) void,
};

pub const Options = struct {
    context: *anyopaque,
    callbacks: Callbacks,
    width: i32,
    height: i32,
    title: [*:0]const u8,
    vsync: bool,
};

pub const WindowHost = struct {
    desc: c.sapp_desc,

    pub fn init(options: Options) WindowHost {
        var desc = std.mem.zeroes(c.sapp_desc);
        desc.user_data = options.context;
        desc.init_userdata_cb = options.callbacks.init;
        desc.frame_userdata_cb = options.callbacks.frame;
        desc.cleanup_userdata_cb = options.callbacks.cleanup;
        desc.event_userdata_cb = options.callbacks.event;
        desc.width = options.width;
        desc.height = options.height;
        desc.high_dpi = true;
        desc.enable_clipboard = true;
        desc.clipboard_size = 1024 * 1024;
        desc.window_title = options.title;
        desc.no_vsync = !options.vsync;
        desc.logger.func = c.slog_func;
        return .{ .desc = desc };
    }

    pub fn run(self: *WindowHost) void {
        c.sapp_run(&self.desc);
    }
};
