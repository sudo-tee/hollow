//! Native-local session-only owner lookup. Never run Linux deployment probes or
//! fall back to an ordinary PTY when the Windows owner bundle is unavailable.
const std = @import("std");
const deploy = @import("../host/deploy.zig");

pub fn resolve(io: std.Io, a: std.mem.Allocator, agent: deploy.Agent, failure: *deploy.Failure) ![]const u8 {
    if (agent.path) |path| {
        try validatePath(path);
        if (!try available(io, path)) return failure.set("native Windows session owner unavailable at {s}", .{path});
        return absolute(io, a, path);
    }
    for (std.enums.values(deploy.Arch)) |arch| if (agent.artifacts.get(arch) != null)
        return failure.set("Linux agent artifacts cannot provide the native Windows session owner; configure agent_path or agent_dir", .{});
    if (agent.dir) |directory| {
        try validatePath(directory);
        const path = try bundled(a, directory);
        if (!try available(io, path)) return failure.set("native Windows session owner unavailable at {s}", .{path});
        return absolute(io, a, path);
    }
    const directory = std.process.executableDirPathAlloc(io, a) catch
        return failure.set("cannot locate the native Windows session owner bundle; configure agent_path or agent_dir", .{});
    const first = try bundled(a, try std.fs.path.join(a, &.{ directory, "agents" }));
    if (try available(io, first)) return absolute(io, a, first);
    if (std.ascii.eqlIgnoreCase(std.fs.path.basenameWindows(directory), "bin")) {
        const second = try bundled(a, try std.fs.path.join(a, &.{ directory, "..", "agents" }));
        if (try available(io, second)) return absolute(io, a, second);
    }
    return failure.set("native Windows session owner missing from the bundle; reinstall Hollow or configure agent_path", .{});
}

fn bundled(a: std.mem.Allocator, directory: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ directory, "windows-x86_64", "hollow-agent.exe" });
}

fn absolute(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    // Resolve relative bundle roots before caching/spawning; never let Windows
    // executable search order select a different image than the one inspected.
    const resolved = try std.Io.Dir.cwd().realPathFileAlloc(io, path, a);
    defer a.free(resolved);
    return a.dupe(u8, resolved);
}

fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path.len > 32 * 1024 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidArgument;
}

fn available(io: std.Io, path: []const u8) !bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    return stat.kind == .file and stat.size > 0;
}

pub fn validateNamespace(namespace: ?[]const u8) !void {
    if (namespace) |value| {
        if (value.len == 0 or value.len > 64) return error.InvalidArgument;
        for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidArgument;
    }
}

pub fn command(a: std.mem.Allocator, path: []const u8, namespace: ?[]const u8) ![]const []const u8 {
    try validatePath(path);
    try validateNamespace(namespace);
    return if (namespace) |name| a.dupe([]const u8, &.{ path, "session", "connect", "--namespace", name }) else a.dupe([]const u8, &.{ path, "session", "connect" });
}

test "native owner command is literal and fixture namespace cannot escape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try command(arena.allocator(), "C:\\Hollow Folder\\hollow-agent.exe", "private-fixture");
    try std.testing.expectEqualStrings("C:\\Hollow Folder\\hollow-agent.exe", argv[0]);
    try std.testing.expectEqualStrings("connect", argv[2]);
    try std.testing.expectEqualStrings("private-fixture", argv[4]);
    try std.testing.expectError(error.InvalidArgument, command(arena.allocator(), "owner.exe", "../production"));
}

test "native owner explicit missing path fails closed without Linux deployment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failure: deploy.Failure = .{};
    try std.testing.expectError(error.DeployFailed, resolve(std.testing.io, arena.allocator(), .{ .path = "Z:\\hollow-native-owner-nonexistent\\missing.exe" }, &failure));
    try std.testing.expect(std.mem.indexOf(u8, failure.text(), "native Windows session owner") != null);
}

test "native owner relative bundle root resolves to an absolute inspected file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "windows-x86_64");
    try tmp.dir.writeFile(io, .{ .sub_path = "windows-x86_64/hollow-agent.exe", .data = "fixture-only-not-executed" });
    const directory = try tmp.dir.realPathFileAlloc(io, ".", temp);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", temp);
    const relative = try std.fs.path.relativeAlloc(temp, cwd, null, cwd, directory);
    var failure: deploy.Failure = .{};
    const path = try resolve(io, temp, .{ .dir = relative }, &failure);
    try std.testing.expect(std.fs.path.isAbsolute(path));
    try std.testing.expect(std.mem.endsWith(u8, path, "hollow-agent.exe"));
}
