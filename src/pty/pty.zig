const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform.zig");
pub const LaunchCommand = @import("launch_command.zig").LaunchCommand;
pub const Wake = @import("wake.zig").Wake;

const NativePty = switch (builtin.os.tag) {
    .windows => @import("pty_windows.zig").WindowsPty,
    else => @import("pty_posix.zig").PosixPty,
};
pub const agent = @import("agent.zig");
const AgentPty = agent.AgentPty;

pub const Pty = union(enum) {
    native: NativePty,
    agent: AgentPty,

    /// Swap an agent PTY whose implicit host proved unavailable for the
    /// native launch it replaced. Safe to call every tick.
    fn settle(self: *Pty) void {
        if (self.* != .agent) return;
        const remote = &self.agent;
        if (!remote.wantsFallback()) return;
        const spec = remote.fallback_spec;
        const size = remote.size();
        var native = spawn(remote.allocator, spec.shell, size.cols, size.rows, spec.cwd, spec.env_block, spec.launch_command, remote.wakeHandle()) catch |err| {
            std.log.warn("native fallback spawn failed: {s}", .{@errorName(err)});
            remote.abandonFallback();
            return;
        };
        const queued = remote.takeQueuedInput(remote.allocator) catch null;
        defer if (queued) |bytes| remote.allocator.free(bytes);
        if (queued) |bytes| if (bytes.len > 0) native.writeAll(bytes) catch {};
        remote.deinit();
        self.* = .{ .native = native };
    }

    pub fn deinit(self: *Pty) void {
        switch (self.*) {
            inline else => |*p| p.deinit(),
        }
    }
    pub fn close(self: *Pty) void {
        switch (self.*) {
            inline else => |*p| p.close(),
        }
    }
    pub fn isAlive(self: *Pty) bool {
        self.settle();
        return switch (self.*) {
            inline else => |*p| p.isAlive(),
        };
    }
    pub fn exitStatus(self: *const Pty) ?u32 {
        return switch (self.*) {
            inline else => |*p| p.exitStatus(),
        };
    }
    pub fn childPid(self: *const Pty) usize {
        return switch (self.*) {
            inline else => |*p| p.childPid(),
        };
    }

    pub fn setFocused(self: *Pty, focused: bool) void {
        if (self.* == .agent) self.agent.setFocused(focused);
    }
    pub fn read(self: *Pty, buffer: []u8) !usize {
        self.settle();
        return switch (self.*) {
            inline else => |*p| p.read(buffer),
        };
    }
    pub fn hasPendingOutput(self: *Pty) bool {
        return switch (self.*) {
            inline else => |*p| p.hasPendingOutput(),
        };
    }
    /// POSIX waitpid may win the race with the first reader chunk. Owned job
    /// completion waits for EOF as well, without changing legacy pane lifecycle.
    pub fn jobOutputPending(self: *Pty) bool {
        return switch (self.*) {
            .native => |*p| if (comptime builtin.os.tag == .windows) p.hasPendingOutput() else !p.outputDrained(),
            .agent => |*p| p.hasPendingOutput(),
        };
    }
    pub fn pendingOutputBytes(self: *Pty) usize {
        return switch (self.*) {
            inline else => |*p| p.pendingOutputBytes(),
        };
    }
    pub fn hasPendingOutputOrExit(self: *Pty) bool {
        self.settle();
        return switch (self.*) {
            inline else => |*p| p.hasPendingOutputOrExit(),
        };
    }
    pub fn writeAll(self: *Pty, bytes: []const u8) !void {
        switch (self.*) {
            inline else => |*p| try p.writeAll(bytes),
        }
    }
    pub fn writeAllUntil(self: *Pty, bytes: []const u8, deadline_ns: i128) !usize {
        return switch (self.*) {
            inline else => |*p| p.writeAllUntil(bytes, deadline_ns),
        };
    }
    pub fn resize(self: *Pty, cols: u16, rows: u16) void {
        switch (self.*) {
            inline else => |*p| p.resize(cols, rows),
        }
    }
};

pub fn usesAgent(pty: *const Pty) bool {
    return pty.* == .agent;
}

pub fn spawn(allocator: std.mem.Allocator, shell: [:0]const u8, cols: u16, rows: u16, cwd: ?[]const u8, env_block: ?[]const u8, launch_command: ?LaunchCommand, wake: Wake) !NativePty {
    return switch (builtin.os.tag) {
        .windows => try NativePty.spawnWithFallbacks(allocator, shell, cols, rows, cwd, env_block, launch_command, platform.windowsShellCandidates(), wake),
        else => try NativePty.spawn(allocator, shell, cols, rows, cwd, env_block, launch_command, wake),
    };
}

pub fn spawnNative(allocator: std.mem.Allocator, shell: [:0]const u8, cols: u16, rows: u16, cwd: ?[]const u8, env_block: ?[]const u8, launch_command: ?LaunchCommand, wake: Wake) !Pty {
    return .{ .native = try spawn(allocator, shell, cols, rows, cwd, env_block, launch_command, wake) };
}

/// Resolving agent PTY; hand `pty.agent.id()` to the Lua host resolver.
pub fn spawnAgent(allocator: std.mem.Allocator, request: agent.Request, wake: Wake) !Pty {
    return .{ .agent = try AgentPty.init(allocator, request, wake) };
}

test {
    _ = agent;
}
