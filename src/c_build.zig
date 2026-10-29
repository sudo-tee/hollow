//! Explicit C translation replaces @cImport, removed in Zig 0.17.
const std = @import("std");

pub fn addClay(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/ui/clay_bridge.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("clay_c", translate.createModule());
    module.addCSourceFile(.{ .file = b.path("src/ui/clay_bridge.c"), .flags = &.{"-std=c99"} });
}

pub fn addPosix(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    if (target.result.os.tag == .windows) return;
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/posix_bindings.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("posix_c", translate.createModule());
}
