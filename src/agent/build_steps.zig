const std = @import("std");

// Resolve environment paths at make time, including custom --prefix values.
// These integration tests run on Linux, where env can wrap the test command.
fn setPathEnvironmentVariable(run: *std.Build.Step.Run, name: []const u8, path: std.Build.LazyPath) void {
    const b = run.step.owner;
    const count = run.argv.items.len;
    run.addArg("env");
    run.addFileArg2(path, .{ .prefix = b.fmt("{s}=", .{name}), .make_absolute = true });
    std.mem.rotate(std.Build.Step.Run.Arg, run.argv.items, count);
}

/// Embeds shell integration without build.zig's options step, so the
/// standalone agent build stays independent of the GUI build graph.
fn shellIntegration(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const files = b.addWriteFiles();
    _ = files.addCopyFile(b.path("shell-integration/bash.sh"), "bash.sh");
    _ = files.addCopyFile(b.path("shell-integration/zsh.zsh"), "zsh.zsh");
    _ = files.addCopyFile(b.path("shell-integration/fish.fish"), "fish.fish");
    const cli = @import("../cli_build_steps.zig").executable(b, target, optimize);
    _ = files.addCopyFile(cli.getEmittedBin(), "hollow-cli");
    _ = files.addCopyFile(b.path("scripts/hollow-cli"), "hollow-cli.py");
    const options = files.add("build_options.zig",
        \\pub const embedded_bash_integration = @embedFile("bash.sh");
        \\pub const embedded_zsh_integration = @embedFile("zsh.zsh");
        \\pub const embedded_fish_integration = @embedFile("fish.fish");
        \\pub const embedded_hollow_cli = @embedFile("hollow-cli");
        \\pub const embedded_hollow_cli_python = @embedFile("hollow-cli.py");
        \\pub const native_cli_required = true;
        \\
    );
    const module = b.createModule(.{
        .root_source_file = b.path("src/shell_integration.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("build_options", b.createModule(.{ .root_source_file = options }));
    @import("../c_build.zig").addPosix(b, module, target, optimize);
    return module;
}

fn agentModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/agent/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const shell = shellIntegration(b, target, optimize);
    module.addImport("shell_integration", shell);
    module.addImport("posix_c", shell.import_table.get("posix_c").?);
    // glibc keeps forkpty in libutil; musl has it in libc.
    if (target.result.abi != .musl) module.linkSystemLibrary("util", .{});
    return module;
}

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const agent_step = b.step("agent", "Build the standalone Linux musl agent for the selected architecture");
    if (target.result.cpu.arch != .x86_64 and target.result.cpu.arch != .aarch64) {
        agent_step.dependOn(&b.addFail("hollow-agent supports only x86_64 and aarch64 Linux targets").step);
    }
    const all_step = b.step("agent-all", "Cross-build x86_64 and aarch64 Linux musl agents");
    const manifest = b.addSystemCommand(&.{"python3"});
    manifest.addFileArg(b.path("scripts/agent_manifest.py"));
    const manifest_file = manifest.addOutputFileArg("SHA256SUMS");
    inline for (.{ std.Target.Cpu.Arch.x86_64, std.Target.Cpu.Arch.aarch64 }) |arch| {
        const agent_target = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .linux, .abi = .musl });
        const exe = b.addExecutable(.{ .name = "hollow-agent", .root_module = agentModule(b, agent_target, optimize), .linkage = .static });
        // Hash immutable compiler output, not an installed path selected by
        // addArtifactArg while parallel install steps are still running.
        manifest.addFileArg(exe.getEmittedBin());
        const packaged = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "agents/linux-" ++ @tagName(arch) } } });
        all_step.dependOn(&packaged.step);
        if (target.result.cpu.arch == arch) {
            const installed = b.addInstallArtifact(exe, .{});
            agent_step.dependOn(&installed.step);
        }
    }
    const install_manifest = b.addInstallFile(manifest_file, "agents/SHA256SUMS");
    all_step.dependOn(&install_manifest.step);
    // Guest management is a default capability, not a separately prepared add-on.
    b.getInstallStep().dependOn(all_step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/agent/protocol.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }) });
    const run_tests = b.addRunArtifact(tests);
    const protocol_step = b.step("test-agent", "Run GUI-independent agent protocol tests");
    protocol_step.dependOn(&run_tests.step);
    const cli_bundle_tests = b.addTest(.{ .root_module = shellIntegration(b, b.graph.host, optimize) });
    b.step("test-cli-bundle", "Verify architecture-matched native CLI embedding in agent shell bundles").dependOn(&b.addRunArtifact(cli_bundle_tests).step);
    const pty_protocol_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/agent/pty_protocol.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }) });
    protocol_step.dependOn(&b.addRunArtifact(pty_protocol_tests).step);
    const loop_tests = b.addTest(.{ .root_module = agentModule(b, b.graph.host, optimize) });
    b.step("test-agent-loop", "Run agent RPC loop and PTY helper unit tests").dependOn(&b.addRunArtifact(loop_tests).step);
    const fs_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/agent/fs.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    }) });
    const run_fs_tests = b.addRunArtifact(fs_tests);
    @import("../c_build.zig").addPosix(b, fs_tests.root_module, b.graph.host, optimize);
    b.step("test-agent-fs", "Run GUI-independent agent filesystem tests").dependOn(&run_fs_tests.step);
    const host_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/host_transport.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    }) });
    const run_host_tests = b.addRunArtifact(host_tests);
    @import("../c_build.zig").addPosix(b, host_tests.root_module, b.graph.host, optimize);
    run_host_tests.has_side_effects = true;
    // Tests use the freshly built native agent, never a stale installed binary.
    const native_target = b.resolveTargetQuery(.{ .cpu_arch = b.graph.host.result.cpu.arch, .os_tag = .linux, .abi = .musl });
    const native_agent = b.addExecutable(.{ .name = "hollow-agent-test", .root_module = agentModule(b, native_target, optimize), .linkage = .static });
    const install_test_agent = b.addInstallArtifact(native_agent, .{ .dest_dir = .{ .override = .{ .custom = "host-test" } } });
    setPathEnvironmentVariable(run_host_tests, "HOLLOW_TEST_AGENT", b.graph.path(.install_prefix, "host-test/hollow-agent-test"));
    run_host_tests.step.dependOn(&install_test_agent.step);
    b.step("test-host-transport", "Run persistent transport integration tests against a native Linux agent").dependOn(&run_host_tests.step);
    const pty_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/agent_pty_test.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    }) });
    const run_pty_tests = b.addRunArtifact(pty_tests);
    @import("../c_build.zig").addPosix(b, pty_tests.root_module, b.graph.host, optimize);
    run_pty_tests.has_side_effects = true;
    setPathEnvironmentVariable(run_pty_tests, "HOLLOW_TEST_AGENT", b.graph.path(.install_prefix, "host-test/hollow-agent-test"));
    run_pty_tests.step.dependOn(&install_test_agent.step);
    b.step("test-agent-pty", "Run agent PTY client tests against a native Linux agent").dependOn(&run_pty_tests.step);
    const pane_bench = b.addExecutable(.{ .name = "hollow-agent-pane-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("src/agent_pane_bench.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    }) });
    b.step("agent-pane-bench", "Build native pane-adapter startup, frame-drain, and backlog diagnostics").dependOn(&b.addInstallArtifact(pane_bench, .{}).step);
    const pane_bench_tests = b.addSystemCommand(&.{"python3"});
    pane_bench_tests.addFileArg(b.path("scripts/test_agent_pane_bench.py"));
    setPathEnvironmentVariable(pane_bench_tests, "HOLLOW_TEST_AGENT", b.graph.path(.install_prefix, "host-test/hollow-agent-test"));
    setPathEnvironmentVariable(pane_bench_tests, "HOLLOW_TEST_PANE_BENCH", b.graph.path(.install_bin, "hollow-agent-pane-bench"));
    pane_bench_tests.step.dependOn(&install_test_agent.step);
    pane_bench_tests.step.dependOn(&b.addInstallArtifact(pane_bench, .{}).step);
    pane_bench_tests.has_side_effects = true;
    b.step("test-agent-pane-bench", "Smoke native pane-adapter startup and frame-drain diagnostics").dependOn(&pane_bench_tests.step);
    const mux_test_step = b.step("test-agent-mux", "Run headless mux tests with inline, 2/4 readers, and single/paired jobs");
    inline for (.{ .{ "0", "1" }, .{ "2", "1" }, .{ "4", "1" }, .{ "2", "2" }, .{ "4", "2" } }) |config| {
        const mux_tests = b.addSystemCommand(&.{"python3"});
        mux_tests.addFileArg(b.path("scripts/test_agent_mux.py"));
        mux_tests.has_side_effects = true;
        setPathEnvironmentVariable(mux_tests, "HOLLOW_TEST_AGENT", b.graph.path(.install_prefix, "host-test/hollow-agent-test"));
        mux_tests.setEnvironmentVariable("HOLLOW_MUX_READ_WORKERS", config[0]);
        mux_tests.setEnvironmentVariable("HOLLOW_MUX_READ_BATCH_JOBS", config[1]);
        mux_tests.step.dependOn(&install_test_agent.step);
        mux_test_step.dependOn(&mux_tests.step);
    }
    const operation_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/host_operations.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    }) });
    b.step("test-host-operations", "Run byte-safe typed host operation tests").dependOn(&b.addRunArtifact(operation_tests).step);
    @import("../c_build.zig").addPosix(b, operation_tests.root_module, b.graph.host, optimize);
    const manager_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/host_manager_test.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    }) });
    const run_manager_tests = b.addRunArtifact(manager_tests);
    @import("../c_build.zig").addPosix(b, manager_tests.root_module, b.graph.host, optimize);
    run_manager_tests.has_side_effects = true;
    setPathEnvironmentVariable(run_manager_tests, "HOLLOW_TEST_AGENT", b.graph.path(.install_prefix, "host-test/hollow-agent-test"));
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
        @import("../c_build.zig").addPosix(b, local_tests.root_module, b.graph.host, optimize);
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
    const lua_include = b.graph.cwdRelativePath(b.option([]const u8, "host-lua-include", "Lua 5.1-compatible API include directory") orelse "/usr/include/luajit-2.1");
    const lua_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/lua_bindings.h"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    lua_translate.addIncludePath(lua_include);
    lua_module.addImport("lua_c", lua_translate.createModule());
    @import("../c_build.zig").addPosix(b, lua_module, b.graph.host, optimize);
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
    const run_lua_tests = b.addRunFile(b.graph.path(.install_bin, "host-lua-test"));
    run_lua_tests.has_side_effects = true;
    run_lua_tests.step.dependOn(&install_lua_tests.step);
    run_lua_tests.step.dependOn(all_step);
    setPathEnvironmentVariable(run_lua_tests, "HOLLOW_TEST_AGENT", b.graph.path(.install_prefix, "host-test/hollow-agent-test"));
    run_lua_tests.step.dependOn(&install_test_agent.step);
    b.step("test-host-lua", "Run headless Lua promises through native HostManager and a real agent").dependOn(&run_lua_tests.step);

    const flat_runner = b.addInstallArtifact(lua_tests, .{
        .dest_dir = .{ .override = .{ .custom = "bundle-test" } },
        .dest_sub_path = "host-lua-test",
    });
    const flat_agents = b.addInstallDirectory(.{
        .source_dir = b.graph.path(.install_prefix, "agents"),
        .install_dir = .prefix,
        .install_subdir = "bundle-test/agents",
    });
    flat_agents.step.dependOn(all_step);
    const run_flat = b.addRunFile(b.graph.path(.install_prefix, "bundle-test/host-lua-test"));
    run_flat.has_side_effects = true;
    setPathEnvironmentVariable(run_flat, "HOLLOW_TEST_AGENT", b.graph.path(.install_prefix, "host-test/hollow-agent-test"));
    run_flat.step.dependOn(&install_test_agent.step);
    run_flat.step.dependOn(&flat_runner.step);
    run_flat.step.dependOn(&flat_agents.step);
    b.step("test-host-lua-flat", "Run native Lua tests from a flat executable plus agents release layout").dependOn(&run_flat.step);
}
