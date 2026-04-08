const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `zluajit` is declared in build.zig.zon.
    const zluajit = b.dependency("zluajit", .{
        .target = target,
        .optimize = optimize,
        .llvm = true, // Recommended.
    });

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Allow Zig source code to use `@import("zluajit")`.
    lib_mod.addImport("zluajit", zluajit.module("zluajit"));

    const lib = b.addLibrary(.{
        // Linkage must be dynamic to be loaded by LuaJIT at runtime.
        .linkage = .dynamic,
        .name = "module",
        .root_module = lib_mod,
        .use_llvm = true,
        .use_lld = true,
    });
    b.installArtifact(lib);
}
