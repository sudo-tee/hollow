const std = @import("std");

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, ghostty: *std.Build.Dependency) void {
    const module = b.createModule(.{
        .root_source_file = b.path("src/agent_pane_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("build_options", b.createModule(.{ .root_source_file = b.path("src/agent_pty_build_options.zig") }));
    module.linkLibrary(ghostty.artifact("ghostty-vt-static"));
    if (target.result.os.tag == .linux) module.linkSystemLibrary("util", .{});
    const tests = b.addTest(.{ .root_module = module, .filters = &.{"agent pane"} });
    const run = b.addRunArtifact(tests);
    run.has_side_effects = true;
    const connector_json = b.graph.environ_map.get("HOLLOW_TEST_CONNECTOR_ARGV");
    const connector = if (connector_json) |json|
        (std.json.parseFromSlice([]const []const u8, b.allocator, json, .{}) catch @panic("invalid test connector JSON")).value
    else
        &[_][]const u8{ b.getInstallPath(.bin, "hollow-agent"), "stdio" };
    const config = std.json.Stringify.valueAlloc(b.allocator, .{
        .connector_argv = connector,
        .argv = &[_][]const u8{
            "/bin/sh", "-c",
            "stty raw -echo; printf 'READY'; head -c 131072 | sha256sum; " ++
                "dd bs=1 count=1 >/dev/null 2>&1; " ++ // queueStartupInput appends CR.
                "printf '\\033[5n'; reply=$(dd bs=1 count=4 2>/dev/null); " ++
                "[ \"$reply\" = \"$(printf '\\033[0n')\" ] || exit 99; " ++
                "printf 'RESPONSE_OK\\033[?1049hALT_SCREEN'; read v; " ++
                "printf '\\033[?1049lFINAL'; exit 7",
        },
    }, .{}) catch @panic("out of memory");
    run.setEnvironmentVariable("HOLLOW_EXPERIMENTAL_AGENT_PTY", config);
    run.step.dependOn(&b.top_level_steps.get("agent").?.step);
    b.step("test-agent-pane", "Run real pane/terminal lifecycle over experimental agent PTYs").dependOn(&run.step);
}
