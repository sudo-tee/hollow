const std = @import("std");

pub fn executable(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const root = b.createModule(.{
        .root_source_file = b.path("src/cli_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (target.result.os.tag == .windows) root.linkSystemLibrary("ws2_32", .{});
    @import("c_build.zig").addPosix(b, root, target, optimize);
    return b.addExecutable(.{
        .name = "hollow-cli",
        .root_module = root,
        .linkage = if (target.result.abi == .musl) .static else null,
    });
}

pub fn embeddedModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const files = b.addWriteFiles();
    _ = files.addCopyFile(executable(b, target, optimize).getEmittedBin(), "hollow-cli");
    const source = files.add("cli_blob.zig", "pub const bytes = @embedFile(\"hollow-cli\");\n");
    return b.createModule(.{ .root_source_file = source });
}

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const install = b.addInstallArtifact(executable(b, target, optimize), .{});
    b.step("cli", "Build standalone hollow-cli for the selected target").dependOn(&install.step);
    b.getInstallStep().dependOn(&install.step);
    const all = b.step("cli-all", "Package x86_64 and aarch64 Linux musl CLIs");
    const manifest = b.addSystemCommand(&.{"python3"});
    manifest.addFileArg(b.path("scripts/agent_manifest.py"));
    manifest.addArgs(&.{ "--name", "hollow-cli" });
    const sums = manifest.addOutputFileArg("SHA256SUMS");
    inline for (.{ std.Target.Cpu.Arch.x86_64, std.Target.Cpu.Arch.aarch64 }) |arch| {
        const guest = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .linux, .abi = .musl });
        const exe = executable(b, guest, optimize);
        // Manifest inputs must not depend on installation order.
        manifest.addFileArg(exe.getEmittedBin());
        const packaged = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "cli/linux-" ++ @tagName(arch) } } });
        all.dependOn(&packaged.step);
    }
    all.dependOn(&b.addInstallFile(sums, "cli/SHA256SUMS").step);
    b.getInstallStep().dependOn(all);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/command_test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    }) });
    const test_step = b.step("test-cli", "Run GUI-independent shared CLI, transport, and contract tests");
    @import("c_build.zig").addPosix(b, tests.root_module, b.graph.host, .Debug);
    test_step.dependOn(&b.addRunArtifact(tests).step);
    if (b.graph.host.result.os.tag == .linux) {
        // Exercise the main build's binary module as well as the agent's
        // copied-file embedding path (test-cli-bundle).
        const options = b.addOptions();
        options.addOption(bool, "native_cli_available", true);
        options.addOption(bool, "native_cli_required", true);
        options.addOption([]const u8, "embedded_bash_integration", @embedFile("../shell-integration/bash.sh"));
        options.addOption([]const u8, "embedded_zsh_integration", @embedFile("../shell-integration/zsh.zsh"));
        options.addOption([]const u8, "embedded_fish_integration", @embedFile("../shell-integration/fish.fish"));
        const root = b.createModule(.{
            .root_source_file = b.path("src/shell_integration.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .link_libc = true,
        });
        root.addOptions("build_options", options);
        @import("c_build.zig").addPosix(b, root, b.graph.host, .Debug);
        root.addImport("native_cli_blob", embeddedModule(b, b.graph.host, optimize));
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = root })).step);
    }
    const smoke = b.addSystemCommand(&.{"python3"});
    smoke.addFileArg(b.path("scripts/test_zig_cli.py"));
    smoke.addArtifactArg(executable(b, b.graph.host, optimize));
    smoke.has_side_effects = true;
    test_step.dependOn(&smoke.step);
}
