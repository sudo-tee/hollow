//! Agent and CLI entry point: no GUI packages or submodules are required.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    @import("src/cli_build_steps.zig").add(b, target, optimize);
    @import("src/agent/build_steps.zig").add(b, target, optimize);
}
