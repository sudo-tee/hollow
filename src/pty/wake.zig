pub const Wake = struct {
    context: ?*anyopaque = null,
    callback: ?*const fn (*anyopaque) void = null,

    pub fn signal(self: Wake) void {
        const callback = self.callback orelse return;
        callback(self.context orelse return);
    }
};
