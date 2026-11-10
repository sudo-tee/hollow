const std = @import("std");

fn ghosttyOptimizeMode(optimize: std.builtin.OptimizeMode) std.builtin.OptimizeMode {
    return switch (optimize) {
        .Debug => .ReleaseFast,
        else => optimize,
    };
}

fn platformSystemLibraries(os_tag: std.Target.Os.Tag) []const []const u8 {
    return switch (os_tag) {
        .windows => &.{ "gdi32", "dxgi", "d3d11", "user32", "shell32", "winmm", "dwmapi", "dwrite", "ws2_32" },
        .linux => &.{ "X11", "Xi", "Xcursor", "GL", "asound" },
        else => &.{},
    };
}

fn addShellIntegrationOptions(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: *std.Build.Step.Options, root: *std.Build.Module) void {
    options.addOption([]const u8, "embedded_bash_integration", @embedFile("shell-integration/bash.sh"));
    options.addOption([]const u8, "embedded_zsh_integration", @embedFile("shell-integration/zsh.zsh"));
    options.addOption([]const u8, "embedded_fish_integration", @embedFile("shell-integration/fish.fish"));
    options.addOption([]const u8, "embedded_powershell_integration", @embedFile("shell-integration/powershell.ps1"));
    options.addOption([]const u8, "embedded_hollow_cli", @embedFile("scripts/hollow-cli"));
    if (target.result.os.tag == .linux) {
        options.addOption(bool, "native_cli_available", true);
        root.addImport("native_cli_blob", @import("src/cli_build_steps.zig").embeddedModule(b, target, optimize));
    }
}

// Native runtime C sources and libraries shared by the GUI executable and the
// unit tests that compile the same root module.
fn addNativeRuntime(b: *std.Build, module: *std.Build.Module, os_tag: std.Target.Os.Tag, fontdeps_dep: *std.Build.Dependency, zluajit_dep: *std.Build.Dependency) void {
    module.linkLibrary(fontdeps_dep.artifact("freetype"));
    module.linkLibrary(fontdeps_dep.artifact("harfbuzz"));
    module.linkLibrary(zluajit_dep.artifact("lua"));
    module.addCSourceFile(.{
        .file = b.path("src/render/sokol_app.c"),
        .flags = &.{
            "-Ithird_party/sokol",
            "-Ithird_party/sokol/util",
            "-Ithird_party/stb",
            "-Ithird_party/fontstash",
        },
    });
    module.addCSourceFile(.{
        .file = b.path("src/render/dwrite_resolver.c"),
        .flags = &.{},
    });
    module.addCSourceFile(.{
        .file = b.path("src/render/png_decode.c"),
        .flags = &.{
            "-Ithird_party/stb",
            "-DGHOSTTY_STATIC",
        },
    });
    for (platformSystemLibraries(os_tag)) |lib_name| {
        module.linkSystemLibrary(lib_name, .{});
    }
}

// Every Lua file under src/lua/hollow, as paths relative to src/. lua_bridge.zig
// embeds each one and derives its module name from the path.
fn luaModulePaths(b: *std.Build) []const []const u8 {
    const io = b.graph.io;
    var dir = b.root.openDir(io, "src/lua/hollow", .{ .iterate = true }) catch |err|
        std.debug.panic("cannot open src/lua/hollow: {s}", .{@errorName(err)});
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    // Configure results are cached; rerun it when a Lua file is added or removed.
    b.dependOnDirectoryContents(b.path("src/lua/hollow"));
    while (walker.next(io) catch |err| std.debug.panic("cannot walk src/lua/hollow: {s}", .{@errorName(err)})) |entry| {
        if (entry.kind == .directory) {
            b.dependOnDirectoryContents(b.path(b.fmt("src/lua/hollow/{s}", .{entry.path})));
            continue;
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".lua")) continue;
        const path = b.fmt("lua/hollow/{s}", .{entry.path});
        std.mem.replaceScalar(u8, path, '\\', '/');
        paths.append(b.allocator, path) catch @panic("OOM");
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, z: []const u8) bool {
            return std.mem.lessThan(u8, a, z);
        }
    }.lessThan);
    return paths.items;
}

pub fn build(b: *std.Build) void {
    const lua_modules = luaModulePaths(b);
    const target = b.standardTargetOptions(.{});
    const requested_optimize = b.standardOptimizeOption(.{});
    // Fast edit loop: app code in Debug (about 3.5x faster to rebuild than
    // ReleaseFast), while cached C dependencies stay ReleaseFast at runtime.
    const dev = b.option(bool, "dev", "Build app code in Debug and C dependencies in ReleaseFast") orelse false;
    const optimize: std.builtin.OptimizeMode = if (dev) .Debug else requested_optimize;
    const dep_optimize: std.builtin.OptimizeMode = if (dev) .ReleaseFast else optimize;
    // The CLI and guest agents are installed and deployed, so dev mode keeps
    // them ReleaseFast with the other dependencies.
    @import("src/cli_build_steps.zig").add(b, target, dep_optimize);
    addAgentSteps(b, target, dep_optimize);
    // Skip GUI graph configuration. build-agent.zig also avoids resolving the
    // main package's GUI dependency manifest on a minimal checkout.
    if (b.option(bool, "agent-only", "Configure only the standalone Linux agent") orelse false) return;
    const emit_pdb = b.option(bool, "pdb", "Emit PDB debug symbols (enables profiling ReleaseFast builds)") orelse false;
    // ReleaseFast otherwise still generates CodeView/PDB information. Avoid
    // that LLVM work for normal builds without changing optimization settings.
    const strip: ?bool = if (emit_pdb) false else if (optimize == .fast) true else null;
    const ghostty_optimize = ghosttyOptimizeMode(optimize);
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = ghostty_optimize,
        .simd = true,
        .@"emit-lib-vt" = true,
    });
    const ghostty_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/term/ghostty_bindings.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ghostty_translate.addIncludePath(ghostty_dep.artifact("ghostty-vt-static").getEmittedIncludeTree());
    // Define this before optional GUI dependencies: snapshot tests need no
    // window, fonts, Lua or renderer, including on a cold dependency cache.
    const snapshot_module = b.createModule(.{
        .root_source_file = b.path("src/session_snapshot_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    snapshot_module.addImport("ghostty_c", ghostty_translate.createModule());
    snapshot_module.linkLibrary(ghostty_dep.artifact("ghostty-vt-static"));
    @import("src/c_build.zig").addSessionIdentity(b, snapshot_module, ghostty_dep.builder);
    const snapshot_tests = b.addTest(.{ .root_module = snapshot_module, .filters = &.{"session "} });
    const snapshot_run = b.addRunArtifact(snapshot_tests);
    b.step("test-session-snapshot", "Run GUI session mirror snapshot contracts").dependOn(&snapshot_run.step);
    const session_client_module = b.createModule(.{
        .root_source_file = b.path("src/session_transport_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    @import("src/c_build.zig").addPosix(b, session_client_module, target, optimize);
    const session_client_tests = b.addTest(.{ .root_module = session_client_module, .filters = &.{"session client"} });
    const session_client_run = b.addRunArtifact(session_client_tests);
    b.step("test-session-client", "Run portable session protocol client contracts").dependOn(&session_client_run.step);
    const connector_test_module = b.createModule(.{
        .root_source_file = b.path("src/session_connector_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    @import("src/c_build.zig").addPosix(b, connector_test_module, target, optimize);
    const connector_test_options = b.addOptions();
    connector_test_options.addOption(?[]const u8, "wsl", b.option([]const u8, "session-test-wsl", "WSL distro for opt-in session connector checks"));
    connector_test_options.addOption(?[]const u8, "agent", b.option([]const u8, "session-test-agent", "Preinstalled guest Linux agent for session connector checks"));
    if (target.result.os.tag == .windows and target.result.cpu.arch == .x86_64) {
        connector_test_options.addOptionPath("native_owner", b.named_lazy_paths.get("windows_session_owner").?);
    } else connector_test_options.addOption(?[]const u8, "native_owner", null);
    connector_test_module.addOptions("session_test_options", connector_test_options);
    const connector_tests = b.addTest(.{ .root_module = connector_test_module, .filters = &.{"session connector"} });
    const connector_run = b.addRunArtifact(connector_tests);
    connector_run.has_side_effects = true;
    b.step("test-session-connector", "Run opt-in WSL session connector lifecycle check").dependOn(&connector_run.step);
    const session_pane_module = b.createModule(.{
        .root_source_file = b.path("src/session_pane_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const session_pane_options = b.addOptions();
    session_pane_options.addOption(bool, "headless", true);
    addShellIntegrationOptions(b, target, optimize, session_pane_options, session_pane_module);
    session_pane_module.addOptions("build_options", session_pane_options);
    session_pane_module.addOptions("session_test_options", connector_test_options);
    session_pane_module.addImport("ghostty_c", ghostty_translate.createModule());
    session_pane_module.linkLibrary(ghostty_dep.artifact("ghostty-vt-static"));
    @import("src/c_build.zig").addSessionIdentity(b, session_pane_module, ghostty_dep.builder);
    @import("src/c_build.zig").addPosix(b, session_pane_module, target, optimize);
    const session_pane_tests = b.addTest(.{ .root_module = session_pane_module, .filters = &.{"session pane"} });
    const session_pane_run = b.addRunArtifact(session_pane_tests);
    session_pane_run.has_side_effects = true;
    b.step("test-session-pane", "Run headless session-backed terminal pane contracts").dependOn(&session_pane_run.step);
    // Temporary Phase 0 spike for persistent sessions (docs/persistent-sessions.md).
    {
        const spike_mod = b.createModule(.{ .target = target, .optimize = ghostty_optimize, .link_libc = true, .strip = true });
        spike_mod.addCSourceFiles(.{ .root = b.path("spikes/session-snapshot/src"), .files = &.{"main.c"} });
        spike_mod.addCMacro("GHOSTTY_STATIC", "");
        spike_mod.linkLibrary(ghostty_dep.artifact("ghostty-vt-static"));
        const spike_exe = b.addExecutable(.{
            .name = "session-snapshot-spike",
            .root_module = spike_mod,
            .linkage = if (target.result.abi == .musl) .static else null,
        });
        b.step("spike-session-snapshot", "Build the persistent-session snapshot spike")
            .dependOn(&b.addInstallArtifact(spike_exe, .{}).step);
    }
    // fontdeps is lazy because it bundles libpng_upstream (also lazy); on a
    // cold cache the first configure pass can't satisfy that chain, so the
    // vendored build silently returns without installing the freetype/
    // harfbuzz artifacts. Returning here lets the build runner fetch the
    // missing sub-deps and re-run configure with the full graph available.
    const fontdeps_dep = b.lazyDependency("fontdeps", .{
        .target = target,
        .optimize = dep_optimize,
    }) orelse return;
    const zluajit_dep = b.dependency("zluajit", .{
        .target = target,
        .optimize = dep_optimize,
        .system = false,
        .shared = false,
        .@"lua52-compat" = false,
        .llvm = true,
    });
    const nightwatch_dep = b.dependency("nightwatch", .{
        .target = target,
        .optimize = optimize,
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
        .strip = strip,
    });
    const launcher_build_options = b.addOptions();
    launcher_build_options.addOption([]const u8, "embedded_base_config", @embedFile("conf/init.lua"));
    launcher_build_options.addOption([]const u8, "embedded_types", @embedFile("types/hollow.lua"));
    launcher_build_options.addOption([]const []const u8, "lua_modules", lua_modules);
    addShellIntegrationOptions(b, target, optimize, launcher_build_options, launcher_root_module);
    launcher_build_options.addOption(bool, "launcher_mode", true);
    launcher_build_options.addOption(bool, "headless", false);
    launcher_root_module.addImport("fonts", fonts_module);
    launcher_root_module.addImport("icon_data", icon_module);
    launcher_root_module.addOptions("build_options", launcher_build_options);
    launcher_root_module.addImport("zluajit", zluajit_dep.module("zluajit"));
    launcher_root_module.addImport("nightwatch", nightwatch_dep.module("nightwatch"));
    @import("src/c_build.zig").addPosix(b, launcher_root_module, target, optimize);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "embedded_base_config", @embedFile("conf/init.lua"));
    build_options.addOption([]const u8, "embedded_types", @embedFile("types/hollow.lua"));
    build_options.addOption([]const []const u8, "lua_modules", lua_modules);
    addShellIntegrationOptions(b, target, optimize, build_options, root_module);
    build_options.addOption(bool, "launcher_mode", false);
    build_options.addOption(bool, "headless", false);
    root_module.addImport("fonts", fonts_module);
    root_module.addImport("icon_data", icon_module);
    root_module.addOptions("build_options", build_options);
    root_module.addImport("zluajit", zluajit_dep.module("zluajit"));
    root_module.addImport("nightwatch", nightwatch_dep.module("nightwatch"));
    @import("src/c_build.zig").addPosix(b, root_module, target, optimize);
    @import("src/c_build.zig").addClay(b, root_module, target, optimize, ghostty_dep.artifact("ghostty-vt-static"));
    root_module.addImport("ghostty_c", ghostty_translate.createModule());

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

    // Isolated renderer benchmark graph. The dummy Sokol backend exposes only
    // sokol_gfx and sokol_gl, so this target never pulls in a window backend.
    const headless_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/render/sokol_headless_bindings.h"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    headless_translate.addIncludePath(b.path("third_party/sokol"));
    headless_translate.addIncludePath(b.path("third_party/sokol/util"));

    // Generated by scripts/bench-rounded-borders.py from old/current runtime
    // functions, so the benchmark measures the real Sokol recording paths.
    if (b.option([]const u8, "border-bench-source", "Generated rounded border benchmark source")) |source| {
        const border_module = b.createModule(.{
            .root_source_file = .{ .cwd_relative = source },
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        });
        border_module.addImport("sokol_c", headless_translate.createModule());
        border_module.addImport("rounded_border", b.createModule(.{
            .root_source_file = b.path("src/render/rounded_border.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }));
        border_module.addCSourceFile(.{
            .file = b.path("src/render/sokol_headless.c"),
            .flags = &.{ "-Ithird_party/sokol", "-Ithird_party/sokol/util" },
        });
        const border_bench = b.addExecutable(.{ .name = "rounded-border-bench", .root_module = border_module });
        const run = b.addRunArtifact(border_bench);
        run.addPassthruArgs();
        b.step("bench-rounded-borders", "Run generated old/current rounded border CPU benchmark").dependOn(&run.step);
    }

    const bench_root_module = b.createModule(.{
        .root_source_file = b.path("src/renderer_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    bench_root_module.addImport("fonts", fonts_module);
    const bench_build_options = b.addOptions();
    bench_build_options.addOption(bool, "headless", true);
    bench_root_module.addOptions("build_options", bench_build_options);
    bench_root_module.addImport("sokol_c", headless_translate.createModule());
    bench_root_module.addImport("ft_c", ft_translate.createModule());
    @import("src/c_build.zig").addTextWidth(b, bench_root_module, ghostty_dep.artifact("ghostty-vt-static"));

    // App executables plus their native Windows session helper; skip standalone
    // CLI and Linux guest bundles that the install step also cross-builds.
    const gui_step = b.step("gui", "Build and install app executables and native session helper");
    if (target.result.os.tag == .windows and target.result.cpu.arch == .x86_64) {
        gui_step.dependOn(&b.top_level_steps.get("session-owner-windows").?.step);
    }
    var run_artifact: *std.Build.Step.Compile = undefined;
    if (target.result.os.tag == .windows) {
        const res_obj = b.addSystemCommand(&.{
            "x86_64-w64-mingw32-windres",
        });
        res_obj.addFileArg(b.path("assets/resources.rc"));
        const res_file = res_obj.addOutputFileArg("resources.o");

        const gui_root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip,
        });
        const gui_build_options = b.addOptions();
        gui_build_options.addOption([]const u8, "embedded_base_config", @embedFile("conf/init.lua"));
        gui_build_options.addOption([]const u8, "embedded_types", @embedFile("types/hollow.lua"));
        gui_build_options.addOption([]const []const u8, "lua_modules", lua_modules);
        addShellIntegrationOptions(b, target, optimize, gui_build_options, gui_root_module);
        gui_build_options.addOption(bool, "launcher_mode", false);
        gui_build_options.addOption(bool, "headless", false);
        gui_root_module.addImport("fonts", fonts_module);
        gui_root_module.addImport("icon_data", icon_module);
        gui_root_module.addOptions("build_options", gui_build_options);
        gui_root_module.addImport("zluajit", zluajit_dep.module("zluajit"));
        gui_root_module.addImport("nightwatch", nightwatch_dep.module("nightwatch"));
        gui_root_module.addImport("sokol_c", translate.createModule());
        gui_root_module.addImport("ft_c", ft_translate.createModule());
        gui_root_module.addImport("ghostty_c", ghostty_translate.createModule());
        @import("src/c_build.zig").addClay(b, gui_root_module, target, optimize, ghostty_dep.artifact("ghostty-vt-static"));

        const gui_exe = b.addExecutable(.{
            .name = "hollow-native",
            .root_module = gui_root_module,
        });

        gui_exe.root_module.addObjectFile(res_file);
        gui_exe.subsystem = .windows;
        addNativeRuntime(b, gui_root_module, target.result.os.tag, fontdeps_dep, zluajit_dep);
        // Tests compile root_module, which no Windows executable links.
        addNativeRuntime(b, root_module, target.result.os.tag, fontdeps_dep, zluajit_dep);
        const install_gui_exe = b.addInstallArtifact(gui_exe, .{});
        b.getInstallStep().dependOn(&install_gui_exe.step);
        gui_step.dependOn(&install_gui_exe.step);

        const launcher_exe = b.addExecutable(.{
            .name = "hollow",
            .root_module = launcher_root_module,
        });
        launcher_exe.root_module.addObjectFile(res_file);
        launcher_exe.root_module.linkLibrary(zluajit_dep.artifact("lua"));
        launcher_exe.root_module.addCSourceFile(.{
            .file = b.path("src/render/dwrite_resolver.c"),
            .flags = &.{},
        });
        launcher_exe.root_module.linkSystemLibrary("kernel32", .{});
        launcher_exe.root_module.linkSystemLibrary("dwrite", .{});
        launcher_exe.root_module.linkSystemLibrary("ws2_32", .{});
        const install_launcher_exe = b.addInstallArtifact(launcher_exe, .{});
        b.getInstallStep().dependOn(&install_launcher_exe.step);
        gui_step.dependOn(&install_launcher_exe.step);

        run_artifact = gui_exe;
    } else {
        const exe = b.addExecutable(.{
            .name = "hollow",
            .root_module = if (target.result.os.tag == .windows) launcher_root_module else root_module,
        });
        addNativeRuntime(b, exe.root_module, target.result.os.tag, fontdeps_dep, zluajit_dep);
        const install_exe = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install_exe.step);
        gui_step.dependOn(&install_exe.step);
        run_artifact = exe;
    }

    const install_hollow_cli = b.addInstallFile(b.path("scripts/hollow-cli"), "bin/hollow-cli.py");
    b.getInstallStep().dependOn(&install_hollow_cli.step);

    const renderer_bench = b.addExecutable(.{
        .name = "hollow-renderer-bench",
        .root_module = bench_root_module,
    });
    renderer_bench.root_module.linkLibrary(fontdeps_dep.artifact("freetype"));
    renderer_bench.root_module.linkLibrary(fontdeps_dep.artifact("harfbuzz"));
    renderer_bench.root_module.addCSourceFile(.{
        .file = b.path("src/render/sokol_headless.c"),
        .flags = &.{
            "-Ithird_party/sokol",
            "-Ithird_party/sokol/util",
        },
    });
    renderer_bench.root_module.addCSourceFile(.{
        .file = b.path("src/render/png_decode.c"),
        .flags = &.{
            "-Ithird_party/stb",
            "-DGHOSTTY_STATIC",
        },
    });
    const install_renderer_bench = b.addInstallArtifact(renderer_bench, .{});
    const renderer_bench_step = b.step("renderer-bench", "Build the headless renderer benchmark");
    renderer_bench_step.dependOn(&install_renderer_bench.step);

    const run_renderer_bench_cmd = b.addRunArtifact(renderer_bench);
    run_renderer_bench_cmd.addPassthruArgs();
    const run_renderer_bench_step = b.step("run-renderer-bench", "Run the headless renderer benchmark");
    run_renderer_bench_step.dependOn(&run_renderer_bench_cmd.step);

    const run_cmd = b.addRunArtifact(run_artifact);
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the native hollow bootstrap");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = root_module });
    const test_cmd = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run native rewrite unit tests");
    test_step.dependOn(&test_cmd.step);
    const borrower_tests = b.addTest(.{ .root_module = root_module, .filters = &.{"session borrowers"} });
    if (target.result.os.tag == .windows) root_module.linkSystemLibrary("advapi32", .{});
    root_module.addOptions("session_test_options", connector_test_options);
    b.step("test-session-borrowers", "Run app session terminal borrower invalidation tests").dependOn(&b.addRunArtifact(borrower_tests).step);
    const clay_test_module = b.createModule(.{
        .root_source_file = b.path("src/ui/clay_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    @import("src/c_build.zig").addClay(b, clay_test_module, target, optimize, ghostty_dep.artifact("ghostty-vt-static"));
    const clay_tests = b.addTest(.{ .root_module = clay_test_module });
    const clay_test_run = b.addRunArtifact(clay_tests);
    b.step("test-clay", "Run isolated Clay layout contracts").dependOn(&clay_test_run.step);
    test_step.dependOn(&clay_test_run.step);
    const width_test_module = b.createModule(.{
        .root_source_file = b.path("src/text_width_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    @import("src/c_build.zig").addClay(b, width_test_module, target, optimize, ghostty_dep.artifact("ghostty-vt-static"));
    const width_tests = b.addTest(.{ .root_module = width_test_module });
    const width_test_run = b.addRunArtifact(width_tests);
    b.step("test-text-width", "Run shared Ghostty grapheme width contracts").dependOn(&width_test_run.step);
    test_step.dependOn(&width_test_run.step);
    const clay_surface_test_module = b.createModule(.{
        .root_source_file = b.path("src/clay_surface_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    @import("src/c_build.zig").addClay(b, clay_surface_test_module, target, optimize, ghostty_dep.artifact("ghostty-vt-static"));
    clay_surface_test_module.linkLibrary(zluajit_dep.artifact("lua"));
    const clay_surface_tests = b.addTest(.{
        .root_module = clay_surface_test_module,
        .filters = &.{"Clay snapshot parser"},
    });
    const clay_surface_test_run = b.addRunArtifact(clay_surface_tests);
    b.step("test-clay-surface", "Run headless Clay snapshot parser contracts").dependOn(&clay_surface_test_run.step);
    test_step.dependOn(&clay_surface_test_run.step);
    const clay_bench_module = b.createModule(.{
        .root_source_file = b.path("src/clay_bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    @import("src/c_build.zig").addClay(b, clay_bench_module, target, optimize, ghostty_dep.artifact("ghostty-vt-static"));
    const clay_bench = b.addExecutable(.{ .name = "clay-bench", .root_module = clay_bench_module });
    const clay_bench_run = b.addRunArtifact(clay_bench);
    clay_bench_run.addPassthruArgs();
    b.step("bench-clay", "Run headless native Clay layout benchmark").dependOn(&clay_bench_run.step);
    const luajit_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/luajit_syntax_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    luajit_tests.root_module.linkLibrary(zluajit_dep.artifact("lua"));
    const luajit_test_run = b.addRunArtifact(luajit_tests);
    b.step("test-luajit", "Verify backported syntax in the bundled LuaJIT runtime").dependOn(&luajit_test_run.step);
    test_step.dependOn(&luajit_test_run.step);

    const background_module = b.createModule(.{
        .root_source_file = b.path("src/background_pane_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const background_options = b.addOptions();
    background_options.addOption(bool, "headless", true);
    background_module.addOptions("build_options", background_options);
    addShellIntegrationOptions(b, target, optimize, background_options, background_module);
    background_module.linkLibrary(ghostty_dep.artifact("ghostty-vt-static"));
    background_module.addImport("ghostty_c", ghostty_translate.createModule());
    const background_tests = b.addTest(.{ .root_module = background_module, .filters = &.{"background jobs:"} });
    @import("src/c_build.zig").addPosix(b, background_module, target, optimize);
    const background_run = b.addRunArtifact(background_tests);
    b.step("test-background", "Run headless background pane, mux, and native PTY tests").dependOn(&background_run.step);
    test_step.dependOn(&background_run.step);

    const mux_visibility_tests = b.addTest(.{
        .root_module = background_module,
        .filters = &.{
            "hidden split branches collapse for focus and resize",
            "pane IDs survive moves and floating restore and are never reused after close",
            "hidden panes retain session identity and restore tiled bounds",
            "edge split spans the whole layout on the requested side",
            "edge placement is dropped once the pane leaves the window edge",
        },
    });
    const mux_visibility_run = b.addRunArtifact(mux_visibility_tests);
    const mux_visibility_test_step = b.step("test-mux-visibility", "Run headless hidden-pane mux regressions");
    mux_visibility_test_step.dependOn(&mux_visibility_run.step);
    test_step.dependOn(&mux_visibility_run.step);
    test_step.dependOn(&snapshot_run.step);
    test_step.dependOn(&session_client_run.step);
    test_step.dependOn(&session_pane_run.step);

    const search_module = b.createModule(.{
        .root_source_file = b.path("src/terminal_search_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    search_module.addImport("ghostty_c", ghostty_translate.createModule());
    search_module.linkLibrary(ghostty_dep.artifact("ghostty-vt-static"));
    const search_tests = b.addTest(.{ .root_module = search_module, .filters = &.{"terminal search"} });
    const search_run = b.addRunArtifact(search_tests);
    b.step("test-search", "Run headless incremental terminal search tests").dependOn(&search_run.step);
    test_step.dependOn(&search_run.step);

    const command_test_module = b.createModule(.{
        .root_source_file = b.path("src/command_test.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    const command_tests = b.addTest(.{ .root_module = command_test_module });
    @import("src/c_build.zig").addPosix(b, command_test_module, target, optimize);
    const command_test_run = b.addRunArtifact(command_tests);
    const command_test_step = b.step("test-command", "Run headless command contracts, CLI, and socket tests");
    command_test_step.dependOn(&command_test_run.step);
    test_step.dependOn(&command_test_run.step);

    const lua_test_cmd = b.addSystemCommand(&.{"bash"});
    lua_test_cmd.addFileArg(b.path("scripts/test-lua.sh"));
    const lua_test_step = b.step("test-lua", "Run Lua tests with Busted");
    lua_test_step.dependOn(&lua_test_cmd.step);

    const bench_test_root_module = b.createModule(.{
        .root_source_file = b.path("src/renderer_bench_test.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    bench_test_root_module.addImport("fonts", fonts_module);
    const bench_test_build_options = b.addOptions();
    bench_test_build_options.addOption(bool, "headless", true);
    bench_test_root_module.addOptions("build_options", bench_test_build_options);
    bench_test_root_module.addImport("sokol_c", headless_translate.createModule());
    bench_test_root_module.addImport("ft_c", ft_translate.createModule());
    @import("src/c_build.zig").addTextWidth(b, bench_test_root_module, ghostty_dep.artifact("ghostty-vt-static"));
    const renderer_bench_tests = b.addTest(.{ .root_module = bench_test_root_module });
    bench_test_root_module.addImport("ghostty_c", ghostty_translate.createModule());
    renderer_bench_tests.root_module.linkLibrary(fontdeps_dep.artifact("freetype"));
    renderer_bench_tests.root_module.linkLibrary(fontdeps_dep.artifact("harfbuzz"));
    renderer_bench_tests.root_module.addCSourceFile(.{
        .file = b.path("src/render/sokol_headless.c"),
        .flags = &.{
            "-Ithird_party/sokol",
            "-Ithird_party/sokol/util",
        },
    });
    renderer_bench_tests.root_module.addCSourceFile(.{
        .file = b.path("src/render/png_decode.c"),
        .flags = &.{
            "-Ithird_party/stb",
            "-DGHOSTTY_STATIC",
        },
    });
    if (target.result.os.tag == .windows) {
        renderer_bench_tests.root_module.addCSourceFile(.{
            .file = b.path("src/render/dwrite_resolver.c"),
            .flags = &.{},
        });
        renderer_bench_tests.root_module.linkSystemLibrary("dwrite", .{});
    }
    const renderer_bench_test_cmd = b.addRunArtifact(renderer_bench_tests);
    test_step.dependOn(&renderer_bench_test_cmd.step);

    const all_test_step = b.step("test-all", "Run native and Lua tests");
    all_test_step.dependOn(test_step);
    all_test_step.dependOn(lua_test_step);
}

fn addAgentSteps(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    @import("src/agent/build_steps.zig").add(b, target, optimize);
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
