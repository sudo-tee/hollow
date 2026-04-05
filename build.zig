const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    translate.addIncludePath(b.path("third_party/freetype-prebuilt/include"));
    translate.addIncludePath(b.path("third_party/harfbuzz-prebuilt/include/harfbuzz"));
    root_module.addImport("sokol_c", translate.createModule());

    // Separate translate-c for freetype + harfbuzz C headers → Zig bindings.
    const ft_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/render/ft_bindings.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ft_translate.addIncludePath(b.path("third_party/freetype-prebuilt/include"));
    ft_translate.addIncludePath(b.path("third_party/harfbuzz-prebuilt/include/harfbuzz"));
    root_module.addImport("ft_c", ft_translate.createModule());

    const exe = b.addExecutable(.{
        .name = "hollow-native",
        .root_module = root_module,
    });
    exe.linkLibC();
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
        // FreeType and HarfBuzz prebuilt Windows DLLs (mingw64).
        // Link directly against the GNU import libs (.dll.a).
        exe.addObjectFile(b.path("third_party/freetype-prebuilt/lib/libfreetype.dll.a"));
        exe.addObjectFile(b.path("third_party/harfbuzz-prebuilt/lib/libharfbuzz.dll.a"));
        const copy_ghostty = b.addInstallFile(b.path("ghostty-vt.dll"), "bin/ghostty-vt.dll");
        b.getInstallStep().dependOn(&copy_ghostty.step);
        // Copy FreeType/HarfBuzz DLLs and their runtime deps to bin/.
        for (&[_][]const u8{
            "libfreetype-6.dll",
            "libharfbuzz-0.dll",
            "libgcc_s_seh-1.dll",
            "libstdc++-6.dll",
            "libwinpthread-1.dll",
            "libglib-2.0-0.dll",
            "libbrotlidec.dll",
            "libbrotlicommon.dll",
            "libbz2-1.dll",
            "libpng16-16.dll",
            "zlib1.dll",
            "libpcre2-8-0.dll",
            "libiconv-2.dll",
            "libintl-8.dll",
        }) |dll| {
            const copy = b.addInstallFile(b.path(dll), b.fmt("bin/{s}", .{dll}));
            b.getInstallStep().dependOn(&copy.step);
        }
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
