const std = @import("std");
const build_options = @import("build_options");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

pub const Shell = enum { bash, zsh, fish };

pub const Bundle = struct {
    root: []const u8,
    shell: Shell,
};

pub fn detect(shell_path: []const u8) ?Shell {
    const shell_name = std.fs.path.basename(shell_path);
    if (std.mem.eql(u8, shell_name, "bash")) return .bash;
    if (std.mem.eql(u8, shell_name, "zsh")) return .zsh;
    if (std.mem.eql(u8, shell_name, "fish")) return .fish;
    return null;
}

/// Creates or reuses a private per-user bundle under /tmp. Bundle identity is
/// derived from contents, so new builds never reuse stale shell code.
pub fn install(allocator: std.mem.Allocator, shell_path: []const u8) !?Bundle {
    const shell = detect(shell_path) orelse return null;
    var bundle_hash = std.hash.Wyhash.hash(0, build_options.embedded_bash_integration);
    bundle_hash = std.hash.Wyhash.hash(bundle_hash, build_options.embedded_zsh_integration);
    bundle_hash = std.hash.Wyhash.hash(bundle_hash, build_options.embedded_fish_integration);
    bundle_hash = std.hash.Wyhash.hash(bundle_hash, build_options.embedded_hollow_cli);
    const root = try std.fmt.allocPrint(allocator, "/tmp/hollow-{d}/shell-{x}", .{ c.getuid(), bundle_hash });
    errdefer allocator.free(root);
    const root_z = try allocator.dupeZ(u8, root);
    defer allocator.free(root_z);

    const bin = try std.fs.path.join(allocator, &.{ root, "bin" });
    defer allocator.free(bin);
    const zsh_dir = try std.fs.path.join(allocator, &.{ root, "zsh" });
    defer allocator.free(zsh_dir);
    const fish_vendor = try std.fs.path.join(allocator, &.{ root, "fish", "vendor_conf.d" });
    defer allocator.free(fish_vendor);
    const marker = try std.fs.path.join(allocator, &.{ root, ".ready" });
    defer allocator.free(marker);
    if (std.fs.accessAbsolute(marker, .{})) |_| return .{ .root = root, .shell = shell } else |_| {}

    try std.fs.cwd().makePath(bin);
    try std.fs.cwd().makePath(zsh_dir);
    try std.fs.cwd().makePath(fish_vendor);
    if (c.chmod(root_z.ptr, 0o700) != 0) return error.SetBundlePermissionsFailed;

    try writeFile(allocator, root, "bash.sh", build_options.embedded_bash_integration, 0o600);
    try writeFile(allocator, root, "zsh.zsh", build_options.embedded_zsh_integration, 0o600);
    try writeFile(allocator, root, "fish.fish", build_options.embedded_fish_integration, 0o600);
    try writeFile(allocator, bin, "hollow-cli", build_options.embedded_hollow_cli, 0o700);
    try writeFile(allocator, root, "bashrc", bashRc, 0o600);
    try writeFile(allocator, zsh_dir, ".zshenv", zshEnv, 0o600);
    try writeFile(allocator, zsh_dir, ".zshrc", zshRc, 0o600);
    try writeFile(allocator, fish_vendor, "hollow.fish", fishRc, 0o600);
    try writeFile(allocator, root, ".ready", "", 0o600);

    return .{ .root = root, .shell = shell };
}

pub fn setupEnv(allocator: std.mem.Allocator, bundle: Bundle) !void {
    const bin = try std.fs.path.join(allocator, &.{ bundle.root, "bin" });
    defer allocator.free(bin);
    try setEnv(allocator, "HOLLOW_SHELL_INTEGRATION_DIR", bundle.root);
    try prependPath(allocator, "PATH", bin, ':');

    switch (bundle.shell) {
        .zsh => {
            const original = std.process.getEnvVarOwned(allocator, "ZDOTDIR") catch null;
            defer if (original) |value| allocator.free(value);
            try setEnv(allocator, "HOLLOW_ORIGINAL_ZDOTDIR", original orelse "");
            const zsh_dir = try std.fs.path.join(allocator, &.{ bundle.root, "zsh" });
            defer allocator.free(zsh_dir);
            try setEnv(allocator, "ZDOTDIR", zsh_dir);
        },
        .fish => {
            const fish_dir = try std.fs.path.join(allocator, &.{ bundle.root, "fish" });
            defer allocator.free(fish_dir);
            try prependPath(allocator, "XDG_DATA_DIRS", fish_dir, ':');
        },
        .bash => {},
    }
}

pub fn argv(allocator: std.mem.Allocator, bundle: Bundle, command: ?[]const u8, close_on_exit: bool) ![]const []const u8 {
    var result: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (result.items) |arg| allocator.free(arg);
        result.deinit(allocator);
    }
    switch (bundle.shell) {
        .bash => {
            const rcfile = try std.fs.path.join(allocator, &.{ bundle.root, "bashrc" });
            defer allocator.free(rcfile);
            try result.append(allocator, try allocator.dupe(u8, "--rcfile"));
            try result.append(allocator, try allocator.dupe(u8, rcfile));
        },
        .zsh, .fish => {},
    }
    if (command) |value| {
        const trimmed = std.mem.trimRight(u8, value, "\r\n");
        const wrapped = if (close_on_exit)
            try std.fmt.allocPrint(allocator, "{s}; exit", .{trimmed})
        else
            try allocator.dupe(u8, trimmed);
        try result.append(allocator, try allocator.dupe(u8, "-ic"));
        try result.append(allocator, wrapped);
    } else {
        try result.append(allocator, try allocator.dupe(u8, "-i"));
    }
    return result.toOwnedSlice(allocator);
}

fn writeFile(allocator: std.mem.Allocator, dir: []const u8, name: []const u8, contents: []const u8, mode: std.fs.File.Mode) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(path);
    const file = try std.fs.createFileAbsolute(path, .{ .mode = mode });
    defer file.close();
    try file.writeAll(contents);
}

fn setEnv(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    const key_z = try allocator.dupeZ(u8, key);
    defer allocator.free(key_z);
    const value_z = try allocator.dupeZ(u8, value);
    defer allocator.free(value_z);
    if (c.setenv(key_z.ptr, value_z.ptr, 1) != 0) return error.SetEnvFailed;
}

fn prependPath(allocator: std.mem.Allocator, key: []const u8, prefix: []const u8, separator: u8) !void {
    const current = std.process.getEnvVarOwned(allocator, key) catch null;
    defer if (current) |value| allocator.free(value);
    const value = if (current) |existing|
        try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ prefix, separator, existing })
    else
        try allocator.dupe(u8, prefix);
    defer allocator.free(value);
    try setEnv(allocator, key, value);
}

const bashRc =
    "[ -f /etc/bash.bashrc ] && source /etc/bash.bashrc\n" ++
    "[ -f \"$HOME/.bashrc\" ] && source \"$HOME/.bashrc\"\n" ++
    "source \"$HOLLOW_SHELL_INTEGRATION_DIR/bash.sh\"\n";
const zshEnv =
    "[ -n \"$HOLLOW_ORIGINAL_ZDOTDIR\" ] || HOLLOW_ORIGINAL_ZDOTDIR=\"$HOME\"\n" ++
    "export HOLLOW_ORIGINAL_ZDOTDIR\n" ++
    "[ -f \"$HOLLOW_ORIGINAL_ZDOTDIR/.zshenv\" ] && source \"$HOLLOW_ORIGINAL_ZDOTDIR/.zshenv\"\n";
const zshRc =
    "[ -f \"$HOLLOW_ORIGINAL_ZDOTDIR/.zshrc\" ] && source \"$HOLLOW_ORIGINAL_ZDOTDIR/.zshrc\"\n" ++
    "source \"$HOLLOW_SHELL_INTEGRATION_DIR/zsh.zsh\"\n";
const fishRc = "source \"$HOLLOW_SHELL_INTEGRATION_DIR/fish.fish\"\n";
