const std = @import("std");

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
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
}
