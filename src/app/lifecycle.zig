pub const Lifecycle = struct {
    state: State = .running,

    pub const State = enum {
        running,
        stopping,
        stopped,
        deinitialized,
    };

    pub fn beginRuntimeShutdown(self: *Lifecycle) bool {
        if (self.state != .running) return false;
        self.state = .stopping;
        return true;
    }

    pub fn finishRuntimeShutdown(self: *Lifecycle) void {
        if (self.state == .stopping) self.state = .stopped;
    }

    pub fn isDeinitialized(self: *const Lifecycle) bool {
        return self.state == .deinitialized;
    }

    pub fn finishDeinit(self: *Lifecycle) void {
        self.state = .deinitialized;
    }
};

test "runtime shutdown is idempotent" {
    var lifecycle = Lifecycle{};
    try @import("std").testing.expect(lifecycle.beginRuntimeShutdown());
    try @import("std").testing.expect(!lifecycle.beginRuntimeShutdown());
    lifecycle.finishRuntimeShutdown();
    try @import("std").testing.expectEqual(Lifecycle.State.stopped, lifecycle.state);
}
