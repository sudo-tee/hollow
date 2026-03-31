const std = @import("std");
const builtin = @import("builtin");

pub const Host = enum {
    windows,
    linux,
    macos,
};

pub fn current() Host {
    return switch (builtin.os.tag) {
        .windows => .windows,
        .macos => .macos,
        else => .linux,
    };
}

pub fn name() []const u8 {
    return switch (current()) {
        .windows => "windows",
        .linux => "linux",
        .macos => "macos",
    };
}

pub fn isWindows() bool {
    return current() == .windows;
}

pub fn isLinux() bool {
    return current() == .linux;
}

pub fn isMacos() bool {
    return current() == .macos;
}

pub fn defaultShell() []const u8 {
    return switch (current()) {
        .windows => "pwsh.exe",
        .linux => "/bin/sh",
        .macos => "/bin/zsh",
    };
}

pub fn windowsShellCandidates() []const []const u8 {
    return &.{
        "wsl.exe",
        "C:\\Windows\\System32\\wsl.exe",
        "pwsh.exe",
        "powershell.exe",
        "cmd.exe",
        "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
        "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
        "C:\\Windows\\System32\\cmd.exe",
    };
}

fn envOwnedOrNull(allocator: std.mem.Allocator, key: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, key) catch null;
}

pub fn defaultConfigPath(allocator: std.mem.Allocator) ![]u8 {
    if (isWindows()) {
        if (envOwnedOrNull(allocator, "APPDATA")) |appdata| {
            defer allocator.free(appdata);
            return std.fs.path.join(allocator, &.{ appdata, "hollow", "init.lua" });
        }

        if (envOwnedOrNull(allocator, "USERPROFILE")) |profile| {
            defer allocator.free(profile);
            return std.fs.path.join(allocator, &.{ profile, "AppData", "Roaming", "hollow", "init.lua" });
        }
    } else {
        if (envOwnedOrNull(allocator, "XDG_CONFIG_HOME")) |xdg| {
            defer allocator.free(xdg);
            return std.fs.path.join(allocator, &.{ xdg, "hollow", "init.lua" });
        }

        if (envOwnedOrNull(allocator, "HOME")) |home| {
            defer allocator.free(home);
            return std.fs.path.join(allocator, &.{ home, ".config", "hollow", "init.lua" });
        }
    }

    return allocator.dupe(u8, projectFallbackConfigPath());
}

pub fn projectFallbackConfigPath() []const u8 {
    return "conf/init.lua";
}

pub fn selfExeDir(allocator: std.mem.Allocator) ![]u8 {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    const dir = std.fs.path.dirname(exe_path) orelse return error.ExecutableDirectoryUnavailable;
    return allocator.dupe(u8, dir);
}

pub fn resolveRelativeToExe(allocator: std.mem.Allocator, candidate: []const u8) !?[]u8 {
    if (std.fs.path.isAbsolute(candidate)) return null;

    const exe_dir = selfExeDir(allocator) catch return null;
    defer allocator.free(exe_dir);

    const trimmed = std.mem.trimLeft(u8, candidate, "./\\");
    return try std.fs.path.join(allocator, &.{ exe_dir, trimmed });
}

pub fn ghosttyLibraryCandidates() []const []const u8 {
    return switch (current()) {
        .windows => &.{
            "ghostty-vt.dll",
            "libghostty-vt.dll",
            "libghostty.dll",
            "./ghostty-vt.dll",
            "./third_party/ghostty/zig-out/lib/ghostty-vt.dll",
            "./third_party/ghostty/zig-out/lib/libghostty-vt.dll",
            ".\\ghostty-vt.dll",
            ".\\third_party\\ghostty\\zig-out\\lib\\ghostty-vt.dll",
            ".\\third_party\\ghostty\\zig-out\\lib\\libghostty-vt.dll",
        },
        .linux => &.{
            "libghostty-vt.so.0",
            "libghostty-vt.so",
            "ghostty-vt.so",
            "./third_party/ghostty/zig-out/lib/libghostty-vt.so.0",
            "./third_party/ghostty/zig-out/lib/libghostty-vt.so",
            "./third_party/ghostty/zig-out/lib/ghostty-vt.so",
        },
        .macos => &.{
            "libghostty-vt.dylib",
            "ghostty-vt.dylib",
            "./third_party/ghostty/zig-out/lib/libghostty-vt.dylib",
            "./third_party/ghostty/zig-out/lib/ghostty-vt.dylib",
        },
    };
}

pub fn luajitLibraryCandidates() []const []const u8 {
    return switch (current()) {
        .windows => &.{
            "luajit-5.1.dll",
            "luajit.dll",
            "lua51.dll",
            "./luajit-5.1.dll",
            "./luajit.dll",
            "./lua51.dll",
            ".\\luajit-5.1.dll",
            ".\\luajit.dll",
            ".\\lua51.dll",
            "./zig-out/bin/luajit-5.1.dll",
            "./zig-out/bin/luajit.dll",
            "./zig-out/bin/lua51.dll",
            ".\\zig-out\\bin\\luajit-5.1.dll",
            ".\\zig-out\\bin\\luajit.dll",
            ".\\zig-out\\bin\\lua51.dll",
            "./third_party/luajit/luajit-5.1.dll",
            "./third_party/luajit/luajit.dll",
            ".\\third_party\\luajit\\luajit-5.1.dll",
            ".\\third_party\\luajit\\luajit.dll",
            "./third_party/luajit/bin/luajit-5.1.dll",
            "./third_party/luajit/bin/luajit.dll",
            ".\\third_party\\luajit\\bin\\luajit-5.1.dll",
            ".\\third_party\\luajit\\bin\\luajit.dll",
        },
        .linux => &.{
            "libluajit-5.1.so.2",
            "libluajit-5.1.so",
            "liblua5.1.so.0",
            "/home/linuxbrew/.linuxbrew/lib/libluajit-5.1.so.2",
            "/home/linuxbrew/.linuxbrew/lib/libluajit-5.1.so",
            "/home/linuxbrew/.linuxbrew/opt/luajit/lib/libluajit-5.1.so.2",
            "./third_party/luajit/lib/libluajit-5.1.so.2",
            "./third_party/luajit/lib/libluajit-5.1.so",
        },
        .macos => &.{
            "libluajit-5.1.dylib",
            "libluajit-5.1.2.dylib",
            "liblua.5.1.dylib",
            "/opt/homebrew/lib/libluajit-5.1.2.dylib",
            "/usr/local/lib/libluajit-5.1.2.dylib",
            "./third_party/luajit/lib/libluajit-5.1.dylib",
        },
    };
}

test "platform names are stable" {
    try std.testing.expect(name().len > 0);
    try std.testing.expect(defaultShell().len > 0);
}
