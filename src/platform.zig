const std = @import("std");
const builtin = @import("builtin");

/// Windows-specific Win32 API types and extern functions.
/// Only present when compiling for Windows targets.
const win32 = if (builtin.os.tag == .windows) struct {
    const cc: std.builtin.CallingConvention = if (builtin.cpu.arch == .x86) .stdcall else .c;

    const FILETIME = extern struct {
        dwLowDateTime: u32,
        dwHighDateTime: u32,
    };

    const SYSTEMTIME = extern struct {
        wYear: u16,
        wMonth: u16,
        wDayOfWeek: u16,
        wDay: u16,
        wHour: u16,
        wMinute: u16,
        wSecond: u16,
        wMilliseconds: u16,
    };

    const MEMORYSTATUSEX = extern struct {
        dwLength: u32,
        dwMemoryLoad: u32,
        ullTotalPhys: u64,
        ullAvailPhys: u64,
        ullTotalPageFile: u64,
        ullAvailPageFile: u64,
        ullTotalVirtual: u64,
        ullAvailVirtual: u64,
        ullAvailExtendedVirtual: u64,
    };

    pub extern "kernel32" fn GetSystemTimes(
        lpIdleTime: *FILETIME,
        lpKernelTime: *FILETIME,
        lpUserTime: *FILETIME,
    ) callconv(cc) i32;

    pub extern "kernel32" fn GlobalMemoryStatusEx(
        lpBuffer: *MEMORYSTATUSEX,
    ) callconv(cc) i32;

    pub extern "kernel32" fn GetLocalTime(
        lpSystemTime: *SYSTEMTIME,
    ) callconv(cc) void;

    pub extern "shell32" fn ShellExecuteW(
        hwnd: ?*anyopaque,
        lpOperation: ?[*:0]const u16,
        lpFile: ?[*:0]const u16,
        lpParameters: ?[*:0]const u16,
        lpDirectory: ?[*:0]const u16,
        nShowCmd: c_int,
    ) callconv(cc) isize;
} else struct {};

/// POSIX-specific C library types and extern functions.
/// Only present when compiling for non-Windows targets.
const posix = if (builtin.os.tag != .windows) struct {
    const time_t = c_long;

    // Must match the platform libc struct tm exactly.
    // glibc (Linux 64-bit): 9×int (36 B) + 4 B pad + long (8 B) + ptr (8 B) = 56 B.
    // macOS 64-bit: same layout (tm_gmtoff + tm_zone extensions).
    // musl / 32-bit: 9×int only (36 B); the extra fields are never written so
    //   the padding is harmless.
    const tm = extern struct {
        tm_sec: c_int,
        tm_min: c_int,
        tm_hour: c_int,
        tm_mday: c_int,
        tm_mon: c_int,
        tm_year: c_int,
        tm_wday: c_int,
        tm_yday: c_int,
        tm_isdst: c_int,
        // glibc/musl/macOS non-POSIX extensions; included so the struct is
        // large enough for localtime_r to write into without overflowing.
        tm_gmtoff: c_long,
        tm_zone: ?[*:0]const u8,
    };

    pub extern "c" fn localtime_r(timep: *const time_t, result: *tm) ?*tm;
} else struct {};

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

pub const SystemMetrics = struct {
    cpu_usage: f32,
    memory_used_mb: u32,
    memory_total_mb: u32,
    gpu_usage: f32,
    gpu_memory_used_mb: u32,
    gpu_memory_total_mb: u32,
};

pub const LocalTime = struct {
    hour: u8,
    minute: u8,
    second: u8,
    day: u8,
    month: u8, // 1-12
    year: u16,
};

pub fn getLocalTime() LocalTime {
    return switch (comptime current()) {
        .windows => getLocalTimeWindows(),
        else => getLocalTimePosix(),
    };
}

fn getLocalTimeWindows() LocalTime {
    var st: win32.SYSTEMTIME = std.mem.zeroes(win32.SYSTEMTIME);
    win32.GetLocalTime(&st);
    return LocalTime{
        .hour = if (st.wHour <= 255) @intCast(st.wHour) else 0,
        .minute = if (st.wMinute <= 255) @intCast(st.wMinute) else 0,
        .second = if (st.wSecond <= 255) @intCast(st.wSecond) else 0,
        .day = if (st.wDay <= 255) @intCast(st.wDay) else 1,
        .month = if (st.wMonth <= 255) @intCast(st.wMonth) else 1,
        .year = st.wYear,
    };
}

fn getLocalTimePosix() LocalTime {
    var ts: posix.time_t = @intCast(std.time.timestamp());
    var tm: posix.tm = std.mem.zeroes(posix.tm);
    _ = posix.localtime_r(&ts, &tm);
    return LocalTime{
        .hour = if (tm.tm_hour >= 0 and tm.tm_hour <= 255) @intCast(tm.tm_hour) else 0,
        .minute = if (tm.tm_min >= 0 and tm.tm_min <= 255) @intCast(tm.tm_min) else 0,
        .second = if (tm.tm_sec >= 0 and tm.tm_sec <= 255) @intCast(tm.tm_sec) else 0,
        .day = if (tm.tm_mday >= 1 and tm.tm_mday <= 255) @intCast(tm.tm_mday) else 1,
        .month = if (tm.tm_mon >= 0 and tm.tm_mon + 1 <= 12) @intCast(tm.tm_mon + 1) else 1,
        .year = if (tm.tm_year >= -1900 and tm.tm_year <= 15535) @intCast(1900 + tm.tm_year) else 1970,
    };
}

// CPU tracking globals for /proc/stat delta (Linux).
var last_cpu_time: u64 = 0;
var last_cpu_idle: u64 = 0;

// CPU tracking globals for GetSystemTimes delta (Windows).
var last_win_idle: u64 = 0;
var last_win_total: u64 = 0;

pub fn getSystemMetrics(allocator: std.mem.Allocator) !SystemMetrics {
    return switch (comptime current()) {
        .windows => getSystemMetricsWindows(allocator),
        .linux => getSystemMetricsLinux(),
        .macos => getSystemMetricsMacos(),
    };
}

pub fn openExternal(target: []const u8) !void {
    return switch (comptime current()) {
        .windows => openExternalWindows(target),
        .linux => openExternalPosix(target, &.{"xdg-open"}),
        .macos => openExternalPosix(target, &.{"open"}),
    };
}

fn openExternalWindows(target: []const u8) !void {
    const wide_target = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, target);
    defer std.heap.page_allocator.free(wide_target);
    const open_w = std.unicode.utf8ToUtf16LeStringLiteral("open");
    const result = win32.ShellExecuteW(null, open_w, wide_target.ptr, null, null, 1);
    if (@as(usize, @bitCast(result)) <= 32) return error.OpenExternalFailed;
}

fn openExternalPosix(target: []const u8, argv: []const []const u8) !void {
    var child_args = std.ArrayList([]const u8).init(std.heap.page_allocator);
    defer child_args.deinit();
    try child_args.appendSlice(argv);
    try child_args.append(target);

    var child = std.process.Child.init(child_args.items, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
}

fn getSystemMetricsWindows(allocator: std.mem.Allocator) !SystemMetrics {
    _ = allocator;

    var idle_ft: win32.FILETIME = undefined;
    var kernel_ft: win32.FILETIME = undefined;
    var user_ft: win32.FILETIME = undefined;

    if (win32.GetSystemTimes(&idle_ft, &kernel_ft, &user_ft) == 0)
        return error.GetSystemTimesFailed;

    const idle_val = (@as(u64, idle_ft.dwHighDateTime) << 32) | idle_ft.dwLowDateTime;
    const kernel_val = (@as(u64, kernel_ft.dwHighDateTime) << 32) | kernel_ft.dwLowDateTime;
    const user_val = (@as(u64, user_ft.dwHighDateTime) << 32) | user_ft.dwLowDateTime;
    const total_val = kernel_val + user_val;

    var cpu_usage: f32 = 0.0;
    if (last_win_total > 0 and total_val >= last_win_total and idle_val >= last_win_idle) {
        const total_diff = total_val - last_win_total;
        const idle_diff = idle_val - last_win_idle;
        if (total_diff > 0 and idle_diff <= total_diff) {
            cpu_usage = 100.0 * @as(f32, @floatFromInt(total_diff - idle_diff)) / @as(f32, @floatFromInt(total_diff));
        }
    }
    last_win_total = total_val;
    last_win_idle = idle_val;

    var mem: win32.MEMORYSTATUSEX = std.mem.zeroes(win32.MEMORYSTATUSEX);
    mem.dwLength = @sizeOf(win32.MEMORYSTATUSEX);
    _ = win32.GlobalMemoryStatusEx(&mem);

    const mem_total_mb: u32 = @intCast(mem.ullTotalPhys / (1024 * 1024));
    const mem_avail_mb: u32 = @intCast(mem.ullAvailPhys / (1024 * 1024));
    const mem_used_mb = if (mem_total_mb > mem_avail_mb) mem_total_mb - mem_avail_mb else 0;

    return SystemMetrics{
        .cpu_usage = cpu_usage,
        .memory_used_mb = mem_used_mb,
        .memory_total_mb = mem_total_mb,
        .gpu_usage = 0.0,
        .gpu_memory_used_mb = 0,
        .gpu_memory_total_mb = 0,
    };
}

fn getSystemMetricsLinux() !SystemMetrics {
    var cpu_usage: f32 = 0.0;
    var mem_total: u32 = 0;
    var mem_available: u32 = 0;

    // Try to read CPU stats from /proc/stat
    if (std.fs.cwd().openFile("/proc/stat", .{})) |proc_stat| {
        defer proc_stat.close();
        var buf: [1024]u8 = undefined;
        const read_len = try proc_stat.readAll(&buf);
        const stat_contents = buf[0..read_len];

        if (std.mem.indexOf(u8, stat_contents, "cpu ")) |start| {
            var line_end = start;
            while (line_end < stat_contents.len and stat_contents[line_end] != '\n') line_end += 1;
            const cpu_line = stat_contents[start..line_end];

            var it = std.mem.tokenizeAny(u8, cpu_line, " \t");
            _ = it.next();

            var total: u64 = 0;
            var idle: u64 = 0;
            var i: usize = 0;
            while (it.next()) |token| : (i += 1) {
                const val = std.fmt.parseInt(u64, token, 10) catch 0;
                total += val;
                if (i == 3) idle = val;
            }

            if (last_cpu_time > 0) {
                const total_diff = total - last_cpu_time;
                const idle_diff = idle - last_cpu_idle;
                if (total_diff > 0) {
                    cpu_usage = 100.0 * (@as(f32, @floatFromInt(total_diff - idle_diff)) / @as(f32, @floatFromInt(total_diff)));
                }
            }

            last_cpu_time = total;
            last_cpu_idle = idle;
        }
    } else |_| {
        // /proc/stat not available
    }

    // Try to read memory info from /proc/meminfo
    if (std.fs.cwd().openFile("/proc/meminfo", .{})) |proc_meminfo| {
        defer proc_meminfo.close();
        var mem_buf: [1024]u8 = undefined;
        const mem_len = try proc_meminfo.readAll(&mem_buf);
        const mem_contents = mem_buf[0..mem_len];

        var lines = std.mem.splitAny(u8, mem_contents, "\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "MemTotal:")) {
                var parts = std.mem.tokenizeAny(u8, line, " \t");
                _ = parts.next();
                const val = parts.next() orelse "0";
                mem_total = std.fmt.parseInt(u32, val, 10) catch 0;
            } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
                var parts = std.mem.tokenizeAny(u8, line, " \t");
                _ = parts.next();
                const val = parts.next() orelse "0";
                mem_available = std.fmt.parseInt(u32, val, 10) catch 0;
            }
        }
    } else |_| {
        // /proc/meminfo not available
    }

    const mem_used = if (mem_total > mem_available) mem_total - mem_available else 0;

    return SystemMetrics{
        .cpu_usage = cpu_usage,
        .memory_used_mb = mem_used / 1024,
        .memory_total_mb = mem_total / 1024,
        .gpu_usage = 0.0,
        .gpu_memory_used_mb = 0,
        .gpu_memory_total_mb = 0,
    };
}

fn getSystemMetricsMacos() !SystemMetrics {
    // macOS sysctl APIs require conditional compilation
    // For now, return placeholder values

    return SystemMetrics{
        .cpu_usage = 0.0,
        .memory_used_mb = 0,
        .memory_total_mb = 0,
        .gpu_usage = 0.0,
        .gpu_memory_used_mb = 0,
        .gpu_memory_total_mb = 0,
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
