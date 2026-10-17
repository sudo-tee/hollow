//! Dependency-free entry point: no GUI packages or submodules are required.
const std = @import("std");

pub fn build(b: *std.Build) void {
    @import("src/agent/build_steps.zig").add(b, b.standardTargetOptions(.{}), b.standardOptimizeOption(.{}));
}
