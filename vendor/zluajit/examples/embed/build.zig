const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `zluajit` is declared in build.zig.zon.
    const zluajit = b.dependency("zluajit", .{
        .target = target,
        .optimize = optimize,
        .shared = false, // Build LuaJIT as a static library.
        .@"lua52-compat" = true, // Enable Lua 5.2 compatibility.
        .llvm = true, // Recommended.
    });

    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Allow Zig source code to use `@import("zluajit")`.
    exe_mod.addImport("zluajit", zluajit.module("zluajit"));

    const exe = b.addExecutable(.{
        .name = "embed",
        .root_module = exe_mod,
        .use_llvm = true,
        .use_lld = true,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
