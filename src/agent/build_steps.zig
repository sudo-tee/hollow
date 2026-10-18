const std = @import("std");

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const profile = b.option(bool, "agent-profile", "Keep symbols and frame pointers in agent/PTY benchmark binaries") orelse false;
    const agent_step = b.step("agent", "Build the standalone Linux musl agent for the selected architecture");
    if (target.result.cpu.arch != .x86_64 and target.result.cpu.arch != .aarch64) {
        agent_step.dependOn(&b.addFail("hollow-agent supports only x86_64 and aarch64 Linux targets").step);
    }
    const all_step = b.step("agent-all", "Cross-build x86_64 and aarch64 Linux musl agents");
    const manifest = b.addSystemCommand(&.{ "python3", b.path("scripts/agent_manifest.py").getPath(b) });
    const manifest_file = manifest.addOutputFileArg("SHA256SUMS");
    inline for (.{ std.Target.Cpu.Arch.x86_64, std.Target.Cpu.Arch.aarch64 }) |arch| {
        const agent_target = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .linux, .abi = .musl });
        const module = b.createModule(.{
            .root_source_file = b.path("src/agent/main.zig"),
            .target = agent_target,
            .optimize = optimize,
            .link_libc = true,
            .strip = if (profile) false else null,
            .omit_frame_pointer = if (profile) false else null,
        });
        const exe = b.addExecutable(.{ .name = "hollow-agent", .root_module = module, .linkage = .static });
        manifest.addArtifactArg(exe);
        const packaged = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "agents/linux-" ++ @tagName(arch) } } });
        all_step.dependOn(&packaged.step);
        if (target.result.cpu.arch == arch) {
            const installed = b.addInstallArtifact(exe, .{});
            agent_step.dependOn(&installed.step);
        }
    }
    const install_manifest = b.addInstallFile(manifest_file, "agents/SHA256SUMS");
    all_step.dependOn(&install_manifest.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/agent/protocol.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }) });
    const run_tests = b.addRunArtifact(tests);
    b.step("test-agent", "Run GUI-independent agent protocol tests").dependOn(&run_tests.step);
    const loop_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/agent/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    }) });
    b.step("test-agent-loop", "Run agent scheduling regressions without real child processes").dependOn(&b.addRunArtifact(loop_tests).step);
    const fs_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/agent/fs.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    }) });
    const run_fs_tests = b.addRunArtifact(fs_tests);
    b.step("test-agent-fs", "Run GUI-independent agent filesystem tests").dependOn(&run_fs_tests.step);
    const host_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/host_transport.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    }) });
    const run_host_tests = b.addRunArtifact(host_tests);
    run_host_tests.has_side_effects = true;
    // Tests use the freshly built native agent, never a stale installed binary.
    const native_module = b.createModule(.{
        .root_source_file = b.path("src/agent/main.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = b.graph.host.result.cpu.arch, .os_tag = .linux, .abi = .musl }),
        .optimize = optimize,
        .link_libc = true,
    });
    const native_agent = b.addExecutable(.{ .name = "hollow-agent-test", .root_module = native_module, .linkage = .static });
    const install_test_agent = b.addInstallArtifact(native_agent, .{ .dest_dir = .{ .override = .{ .custom = "host-test" } } });
    run_host_tests.setEnvironmentVariable("HOLLOW_TEST_AGENT", b.getInstallPath(.prefix, "host-test/hollow-agent-test"));
    run_host_tests.step.dependOn(&install_test_agent.step);
    b.step("test-host-transport", "Run persistent transport integration tests against a native Linux agent").dependOn(&run_host_tests.step);
    const pty_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/agent_pty_test.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    }) });
    if (b.graph.host.result.os.tag == .linux) pty_tests.root_module.linkSystemLibrary("util", .{});
    pty_tests.root_module.addImport("build_options", b.createModule(.{ .root_source_file = b.path("src/agent_pty_build_options.zig") }));
    const run_pty_tests = b.addRunArtifact(pty_tests);
    run_pty_tests.has_side_effects = true;
    run_pty_tests.setEnvironmentVariable("HOLLOW_TEST_AGENT", b.getInstallPath(.prefix, "host-test/hollow-agent-test"));
    const pane_agent_config = std.json.Stringify.valueAlloc(b.allocator, .{
        .connector_argv = &[_][]const u8{ b.getInstallPath(.prefix, "host-test/hollow-agent-test"), "stdio" },
        .argv = &[_][]const u8{ "/bin/sh", "-c", "printf PANE_ENTRY; exit 4" },
    }, .{}) catch @panic("out of memory");
    run_pty_tests.setEnvironmentVariable("HOLLOW_EXPERIMENTAL_AGENT_PTY", pane_agent_config);
    run_pty_tests.step.dependOn(&install_test_agent.step);
    b.step("test-agent-pty", "Run experimental native streaming PTY and pane-adapter tests").dependOn(&run_pty_tests.step);
    const pty_bench_module = b.createModule(.{
        .root_source_file = b.path("src/agent_pty_bench.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
        .strip = if (profile) false else null,
        .omit_frame_pointer = if (profile) false else null,
    });
    pty_bench_module.addImport("build_options", b.createModule(.{ .root_source_file = b.path("src/agent_pty_build_options.zig") }));
    if (b.graph.host.result.os.tag == .linux) pty_bench_module.linkSystemLibrary("util", .{});
    const pty_bench = b.addExecutable(.{ .name = "hollow-agent-pty-bench", .root_module = pty_bench_module });
    const install_pty_bench = b.addInstallArtifact(pty_bench, .{});
    b.step("agent-pty-bench", "Build the headless native-versus-agent PTY benchmark").dependOn(&install_pty_bench.step);
    const operation_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/host_operations.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    }) });
    b.step("test-host-operations", "Run byte-safe typed host operation tests").dependOn(&b.addRunArtifact(operation_tests).step);
    const manager_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/host_manager_test.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    }) });
    const run_manager_tests = b.addRunArtifact(manager_tests);
    run_manager_tests.has_side_effects = true;
    run_manager_tests.setEnvironmentVariable("HOLLOW_TEST_AGENT", b.getInstallPath(.prefix, "host-test/hollow-agent-test"));
    run_manager_tests.step.dependOn(&install_test_agent.step);
    b.step("test-host-manager", "Run bounded HostManager lifecycle integration tests").dependOn(&run_manager_tests.step);
    const local_step = b.step("test-host-local", "Run native-local filesystem/process and dispatch tests");
    inline for (.{ "src/host_local_test.zig", "src/host_local_manager_test.zig" }) |root| {
        const local_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = b.graph.host,
            .optimize = optimize,
            .link_libc = true,
        }) });
        const run_local_tests = b.addRunArtifact(local_tests);
        run_local_tests.has_side_effects = true;
        local_step.dependOn(&run_local_tests.step);
    }

    // Optional headless test: requires Lua 5.1-compatible headers/library, not
    // GUI dependencies or submodules. CI supplies LuaJIT; plain Lua 5.1 works too.
    const lua_module = b.createModule(.{
        .root_source_file = b.path("src/host_lua_test.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    lua_module.addIncludePath(.{ .cwd_relative = b.option([]const u8, "host-lua-include", "Lua 5.1-compatible API include directory") orelse "/usr/include/luajit-2.1" });
    if (b.option([]const u8, "host-lua-object", "Explicit Lua 5.1-compatible library file")) |path| {
        lua_module.addObjectFile(.{ .cwd_relative = path });
    } else lua_module.linkSystemLibrary("luajit-5.1", .{});
    if (b.graph.host.result.os.tag == .linux) {
        lua_module.linkSystemLibrary("m", .{});
        lua_module.linkSystemLibrary("dl", .{});
    }
    const lua_tests = b.addTest(.{ .root_module = lua_module });
    // Execute the installed test runner, not its compiler-cache copy, to test
    // the real executable-relative prefix/bin + prefix/agents discovery layout.
    const install_lua_tests = b.addInstallArtifact(lua_tests, .{
        .dest_dir = .{ .override = .bin },
        .dest_sub_path = "host-lua-test",
    });
    const run_lua_tests = b.addSystemCommand(&.{b.getInstallPath(.bin, "host-lua-test")});
    run_lua_tests.has_side_effects = true;
    run_lua_tests.step.dependOn(&install_lua_tests.step);
    run_lua_tests.step.dependOn(all_step);
    run_lua_tests.setEnvironmentVariable("HOLLOW_TEST_AGENT", b.getInstallPath(.prefix, "host-test/hollow-agent-test"));
    run_lua_tests.step.dependOn(&install_test_agent.step);
    b.step("test-host-lua", "Run headless Lua promises through native HostManager and a real agent").dependOn(&run_lua_tests.step);

    const flat_runner = b.addInstallArtifact(lua_tests, .{
        .dest_dir = .{ .override = .{ .custom = "bundle-test" } },
        .dest_sub_path = "host-lua-test",
    });
    const flat_agents = b.addInstallDirectory(.{
        .source_dir = .{ .cwd_relative = b.getInstallPath(.prefix, "agents") },
        .install_dir = .prefix,
        .install_subdir = "bundle-test/agents",
    });
    flat_agents.step.dependOn(all_step);
    const run_flat = b.addSystemCommand(&.{b.getInstallPath(.prefix, "bundle-test/host-lua-test")});
    run_flat.has_side_effects = true;
    run_flat.setEnvironmentVariable("HOLLOW_TEST_AGENT", b.getInstallPath(.prefix, "host-test/hollow-agent-test"));
    run_flat.step.dependOn(&install_test_agent.step);
    run_flat.step.dependOn(&flat_runner.step);
    run_flat.step.dependOn(&flat_agents.step);
    b.step("test-host-lua-flat", "Run native Lua tests from a flat executable plus agents release layout").dependOn(&run_flat.step);
}
