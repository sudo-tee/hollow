const std = @import("std");

fn ghosttyOptimizeMode(optimize: std.builtin.OptimizeMode) std.builtin.OptimizeMode {
    return switch (optimize) {
        .Debug => .ReleaseFast,
        else => optimize,
    };
}

fn platformSystemLibraries(os_tag: std.Target.Os.Tag) []const []const u8 {
    return switch (os_tag) {
        .windows => &.{ "gdi32", "dxgi", "d3d11", "user32", "shell32", "winmm", "dwmapi", "dwrite" },
        .linux => &.{ "X11", "Xi", "Xcursor", "GL", "asound" },
        else => &.{},
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ghostty_optimize = ghosttyOptimizeMode(optimize);
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
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "embedded_base_config", @embedFile("conf/init.lua"));
    root_module.addImport("fonts", fonts_module);
    root_module.addImport("icon_data", icon_module);
    root_module.addOptions("build_options", build_options);
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
    if (target.result.os.tag == .windows) {
        exe.subsystem = .Windows;
    }
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
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/render/dwrite_resolver.c"),
        .flags = &.{},
    });
    for (platformSystemLibraries(target.result.os.tag)) |lib_name| {
        exe.root_module.linkSystemLibrary(lib_name, .{});
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

test "ghostty optimize mode keeps release builds and upgrades debug" {
    try std.testing.expectEqual(std.builtin.OptimizeMode.ReleaseFast, ghosttyOptimizeMode(.Debug));
    try std.testing.expectEqual(std.builtin.OptimizeMode.ReleaseFast, ghosttyOptimizeMode(.ReleaseFast));
    try std.testing.expectEqual(std.builtin.OptimizeMode.ReleaseSafe, ghosttyOptimizeMode(.ReleaseSafe));
    try std.testing.expectEqual(std.builtin.OptimizeMode.ReleaseSmall, ghosttyOptimizeMode(.ReleaseSmall));
}

test "platform system libraries remain stable by target OS" {
    const windows_libs = [_][]const u8{ "gdi32", "dxgi", "d3d11", "user32", "shell32", "winmm", "dwmapi", "dwrite" };
    const linux_libs = [_][]const u8{ "X11", "Xi", "Xcursor", "GL", "asound" };

    try std.testing.expectEqualDeep(
        windows_libs[0..],
        platformSystemLibraries(.windows),
    );
    try std.testing.expectEqualDeep(
        linux_libs[0..],
        platformSystemLibraries(.linux),
    );
    try std.testing.expectEqual(@as(usize, 0), platformSystemLibraries(.macos).len);
}
