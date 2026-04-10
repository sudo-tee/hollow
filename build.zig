const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ghostty_optimize: std.builtin.OptimizeMode = switch (optimize) {
        .Debug => .ReleaseFast,
        else => optimize,
    };
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = ghostty_optimize,
        .simd = true,
        .@"emit-lib-vt" = true,
    });
    const fontdeps_dep = b.dependency("fontdeps", .{
        .target = target,
        .optimize = optimize,
    });
    const zluajit_dep = b.dependency("zluajit", .{
        .target = target,
        .optimize = optimize,
        .system = false,
        .shared = false,
        .@"lua52-compat" = false,
        .llvm = true,
    });

    // Fonts module: root lives in third_party/fonts/ so @embedFile paths
    // stay inside that directory (avoids "outside package path" errors).
    const fonts_module = b.createModule(.{
        .root_source_file = b.path("third_party/fonts/fonts.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Icon data module: pre-resized RGBA pixel arrays for the app icon.
    const icon_module = b.createModule(.{
        .root_source_file = b.path("assets/icon_data.zig"),
        .target = target,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addImport("fonts", fonts_module);
    root_module.addImport("icon_data", icon_module);
    root_module.addImport("zluajit", zluajit_dep.module("zluajit"));
    root_module.linkLibrary(ghostty_dep.artifact("ghostty-vt-static"));

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/render/sokol_bindings.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate.addIncludePath(b.path("third_party/sokol"));
    translate.addIncludePath(b.path("third_party/sokol/util"));
    translate.addIncludePath(b.path("third_party/stb"));
    translate.addIncludePath(b.path("third_party/fontstash"));
    translate.addIncludePath(fontdeps_dep.artifact("freetype").getEmittedIncludeTree());
    translate.addIncludePath(fontdeps_dep.artifact("harfbuzz").getEmittedIncludeTree());
    root_module.addImport("sokol_c", translate.createModule());

    // Separate translate-c for freetype + harfbuzz C headers → Zig bindings.
    const ft_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/render/ft_bindings.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ft_translate.addIncludePath(fontdeps_dep.artifact("freetype").getEmittedIncludeTree());
    ft_translate.addIncludePath(fontdeps_dep.artifact("harfbuzz").getEmittedIncludeTree());
    root_module.addImport("ft_c", ft_translate.createModule());

    const exe = b.addExecutable(.{
        .name = "hollow-native",
        .root_module = root_module,
    });
    exe.linkLibC();
    exe.root_module.linkLibrary(fontdeps_dep.artifact("freetype"));
    exe.root_module.linkLibrary(fontdeps_dep.artifact("harfbuzz"));
    exe.root_module.linkLibrary(zluajit_dep.artifact("lua"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/render/sokol_app.c"),
        .flags = &.{
            "-Ithird_party/sokol",
            "-Ithird_party/sokol/util",
            "-Ithird_party/stb",
            "-Ithird_party/fontstash",
        },
    });
    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("gdi32", .{});
        exe.root_module.linkSystemLibrary("dxgi", .{});
        exe.root_module.linkSystemLibrary("d3d11", .{});
        exe.root_module.linkSystemLibrary("user32", .{});
        exe.root_module.linkSystemLibrary("shell32", .{});
        exe.root_module.linkSystemLibrary("winmm", .{});
        exe.root_module.linkSystemLibrary("dwmapi", .{});
    } else if (target.result.os.tag == .linux) {
        exe.root_module.linkSystemLibrary("X11", .{});
        exe.root_module.linkSystemLibrary("Xi", .{});
        exe.root_module.linkSystemLibrary("Xcursor", .{});
        exe.root_module.linkSystemLibrary("GL", .{});
        exe.root_module.linkSystemLibrary("asound", .{});
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the native hollow bootstrap");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = root_module });
    tests.linkLibC();
    const test_cmd = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run native rewrite unit tests");
    test_step.dependOn(&test_cmd.step);
}
