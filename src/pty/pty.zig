const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform.zig");
pub const LaunchCommand = @import("launch_command.zig").LaunchCommand;
pub const Wake = @import("wake.zig").Wake;

const NativePty = switch (builtin.os.tag) {
    .windows => @import("pty_windows.zig").WindowsPty,
    else => @import("pty_posix.zig").PosixPty,
};
const AgentPty = @import("agent.zig").AgentPty;

pub const Pty = union(enum) {
    native: NativePty,
    agent: AgentPty,

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
    pub fn read(self: *Pty, buffer: []u8) !usize {
        return switch (self.*) {
            inline else => |*p| p.read(buffer),
        };
    }
    pub fn hasPendingOutput(self: *Pty) bool {
        return switch (self.*) {
            inline else => |*p| p.hasPendingOutput(),
        };
    }
    pub fn pendingOutputBytes(self: *Pty) usize {
        return switch (self.*) {
            inline else => |*p| p.pendingOutputBytes(),
        };
    }
    pub fn hasPendingOutputOrExit(self: *Pty) bool {
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

pub fn usesWslBypass(pty: *const Pty) bool {
    return switch (pty.*) {
        .native => |*p| if (builtin.os.tag == .windows) p.usesWslBypass() else false,
        .agent => false,
    };
}

pub fn usesAgent(pty: *const Pty) bool {
    return pty.* == .agent;
}

pub fn spawn(allocator: std.mem.Allocator, shell: [:0]const u8, cols: u16, rows: u16, cwd: ?[]const u8, env_block: ?[]const u8, launch_command: ?LaunchCommand, wake: Wake) !Pty {
    // Deliberately explicit development-only override; absent means identical
    // native/WSL bypass selection. No automatic deployment, shell inference or
    // translation of Windows cwd/environment into remote Linux paths.
    const config_json = @import("../io.zig").getEnvVarOwned(allocator, "HOLLOW_EXPERIMENTAL_AGENT_PTY") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
    defer if (config_json) |json| allocator.free(json);
    if (config_json) |json| {
        if (json.len > 1024 * 1024 or launch_command != null) return error.InvalidArgument;
        const parsed = try std.json.parseFromSlice(@import("agent.zig").Config, allocator, json, .{});
        defer parsed.deinit();
        return .{ .agent = try AgentPty.spawn(allocator, parsed.value, cols, rows, wake) };
    }
    return .{ .native = switch (builtin.os.tag) {
        .windows => try NativePty.spawnWithFallbacks(allocator, shell, cols, rows, cwd, env_block, launch_command, platform.windowsShellCandidates(), wake),
        else => try NativePty.spawn(allocator, shell, cols, rows, cwd, env_block, launch_command, wake),
    } };
}
