const std = @import("std");

const luajit = @import("build/luajit.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const system = b.option(bool, "system", "Use system LuaJIT library ") orelse false;
    const shared = b.option(bool, "shared", "Build shared library instead of static") orelse false;
    const lua52_compat = b.option(bool, "lua52-compat", "Enable Lua 5.2 compatibility layer") orelse false;
    const llvm = b.option(bool, "llvm", "Use LLVM backend") orelse false;

    const luajit_lib = luajit.configure(
        b,
        target,
        optimize,
        b.dependency("luajit", .{}),
        shared,
        lua52_compat,
        llvm,
    );

    const module = b.addModule("zluajit", .{
        .root_source_file = b.path("src/zluajit.zig"),
        .target = target,
        .optimize = optimize,
        .unwind_tables = .sync,
    });

    const lib = b.addLibrary(.{
        .name = "zluajit",
        .root_module = module,
        .linkage = .static,
        .use_llvm = llvm,
        .use_lld = llvm,
    });
    if (system) {
        lib.linkSystemLibrary("luajit");
    } else {
        lib.linkLibrary(luajit_lib);
    }

    b.installArtifact(lib);
    b.installArtifact(luajit_lib);

    // Generate documentation.
    {
        const install_docs = b.addInstallDirectory(.{
            .source_dir = lib.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        });

        const docs_step = b.step("docs", "Install docs into zig-out/docs");
        docs_step.dependOn(&install_docs.step);
    }

    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .unwind_tables = .sync,
        }),
        .use_llvm = llvm,
        .use_lld = llvm,
    });
    lib_unit_tests.root_module.addImport("zluajit", module);
    const install_lib_unit_tests = b.addInstallArtifact(lib_unit_tests, .{});
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&install_lib_unit_tests.step);
}
