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
    const wsl_bypass_target = b.resolveTargetQuery(.{
        .cpu_arch = target.result.cpu.arch,
        .os_tag = .linux,
    });
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

    const launcher_root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const launcher_build_options = b.addOptions();
    launcher_build_options.addOption([]const u8, "embedded_base_config", @embedFile("conf/init.lua"));
    launcher_build_options.addOption([]const u8, "embedded_types", @embedFile("types/hollow.lua"));
    launcher_build_options.addOption(bool, "launcher_mode", true);
    launcher_root_module.addImport("fonts", fonts_module);
    launcher_root_module.addImport("icon_data", icon_module);
    launcher_root_module.addOptions("build_options", launcher_build_options);
    launcher_root_module.addImport("zluajit", zluajit_dep.module("zluajit"));

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "embedded_base_config", @embedFile("conf/init.lua"));
    build_options.addOption([]const u8, "embedded_types", @embedFile("types/hollow.lua"));
    build_options.addOption(bool, "launcher_mode", false);
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

    var run_artifact: *std.Build.Step.Compile = undefined;
    if (target.result.os.tag == .windows) {
        const res_obj = b.addSystemCommand(&.{ "x86_64-w64-mingw32-windres", 
            b.path("assets/resources.rc").getPath(b), 
        });
        const res_file = res_obj.addOutputFileArg("resources.o");

        const gui_root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const gui_build_options = b.addOptions();
        gui_build_options.addOption([]const u8, "embedded_base_config", @embedFile("conf/init.lua"));
        gui_build_options.addOption([]const u8, "embedded_types", @embedFile("types/hollow.lua"));
        gui_build_options.addOption(bool, "launcher_mode", false);
        gui_root_module.addImport("fonts", fonts_module);
        gui_root_module.addImport("icon_data", icon_module);
        gui_root_module.addOptions("build_options", gui_build_options);
        gui_root_module.addImport("zluajit", zluajit_dep.module("zluajit"));
        gui_root_module.linkLibrary(ghostty_dep.artifact("ghostty-vt-static"));
        gui_root_module.addImport("sokol_c", translate.createModule());
        gui_root_module.addImport("ft_c", ft_translate.createModule());

        const gui_exe = b.addExecutable(.{
            .name = "hollow-native",
            .root_module = gui_root_module,
        });
        gui_exe.addObjectFile(res_file);
        gui_exe.subsystem = .Windows;
        gui_exe.linkLibC();
        gui_exe.root_module.linkLibrary(fontdeps_dep.artifact("freetype"));
        gui_exe.root_module.linkLibrary(fontdeps_dep.artifact("harfbuzz"));
        gui_exe.root_module.linkLibrary(zluajit_dep.artifact("lua"));
        gui_exe.root_module.addCSourceFile(.{
            .file = b.path("src/render/sokol_app.c"),
            .flags = &.{
                "-Ithird_party/sokol",
                "-Ithird_party/sokol/util",
                "-Ithird_party/stb",
                "-Ithird_party/fontstash",
            },
        });
        gui_exe.root_module.addCSourceFile(.{
            .file = b.path("src/render/dwrite_resolver.c"),
            .flags = &.{},
        });
        gui_exe.root_module.addCSourceFile(.{
            .file = b.path("src/render/png_decode.c"),
            .flags = &.{
                "-Ithird_party/stb",
                "-DGHOSTTY_STATIC",
            },
        });
        for (platformSystemLibraries(target.result.os.tag)) |lib_name| {
            gui_exe.root_module.linkSystemLibrary(lib_name, .{});
        }
        const install_gui_exe = b.addInstallArtifact(gui_exe, .{});
        b.getInstallStep().dependOn(&install_gui_exe.step);

        const launcher_exe = b.addExecutable(.{
            .name = "hollow",
            .root_module = launcher_root_module,
        });
        launcher_exe.addObjectFile(res_file);
        launcher_exe.linkLibC();
        launcher_exe.root_module.linkLibrary(zluajit_dep.artifact("lua"));
        launcher_exe.root_module.addCSourceFile(.{
            .file = b.path("src/render/dwrite_resolver.c"),
            .flags = &.{},
        });
        launcher_exe.root_module.linkSystemLibrary("kernel32", .{});
        launcher_exe.root_module.linkSystemLibrary("dwrite", .{});
        const install_launcher_exe = b.addInstallArtifact(launcher_exe, .{});
        b.getInstallStep().dependOn(&install_launcher_exe.step);

        const gui_launcher_exe = b.addExecutable(.{
            .name = "hollow-gui",
            .root_module = launcher_root_module,
        });
        gui_launcher_exe.addObjectFile(res_file);
        gui_launcher_exe.subsystem = .Windows;
        gui_launcher_exe.linkLibC();
        gui_launcher_exe.root_module.linkLibrary(zluajit_dep.artifact("lua"));
        gui_launcher_exe.root_module.addCSourceFile(.{
            .file = b.path("src/render/dwrite_resolver.c"),
            .flags = &.{},
        });
        gui_launcher_exe.root_module.linkSystemLibrary("kernel32", .{});
        gui_launcher_exe.root_module.linkSystemLibrary("dwrite", .{});
        const install_gui_launcher_exe = b.addInstallArtifact(gui_launcher_exe, .{});
        b.getInstallStep().dependOn(&install_gui_launcher_exe.step);

        run_artifact = gui_exe;
    } else {
        const exe = b.addExecutable(.{
            .name = "hollow",
            .root_module = if (target.result.os.tag == .windows) launcher_root_module else root_module,
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
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/render/dwrite_resolver.c"),
            .flags = &.{},
        });
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/render/png_decode.c"),
            .flags = &.{
                "-Ithird_party/stb",
                "-DGHOSTTY_STATIC",
            },
        });
        for (platformSystemLibraries(target.result.os.tag)) |lib_name| {
            exe.root_module.linkSystemLibrary(lib_name, .{});
        }
        const install_exe = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install_exe.step);
        run_artifact = exe;
    }

    const install_hollow_cli = b.addInstallFile(b.path("scripts/hollow-cli"), "bin/hollow-cli");
    b.getInstallStep().dependOn(&install_hollow_cli.step);

    const wsl_bypass_module = b.createModule(.{
        .root_source_file = b.path("src/wsl_bypass.zig"),
        .target = wsl_bypass_target,
        .optimize = optimize,
        .link_libc = true,
    });
    const wsl_bypass = b.addExecutable(.{
        .name = "hollow-wsl-bypass",
        .root_module = wsl_bypass_module,
    });
    const install_wsl_bypass = b.addInstallArtifact(wsl_bypass, .{});
    const wsl_bypass_step = b.step("wsl-bypass", "Build the WSL PTY bypass helper");
    wsl_bypass_step.dependOn(&install_wsl_bypass.step);

    const install_wsl_bypass_cmd = b.addSystemCommand(&.{"bash"});
    install_wsl_bypass_cmd.addFileArg(b.path("scripts/install-wsl-bypass.sh"));
    install_wsl_bypass_cmd.step.dependOn(&install_wsl_bypass.step);
    const install_wsl_bypass_step = b.step("install-wsl-bypass", "Install the WSL PTY bypass helper into /usr/local/bin");
    install_wsl_bypass_step.dependOn(&install_wsl_bypass_cmd.step);

    const run_cmd = b.addRunArtifact(run_artifact);
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
