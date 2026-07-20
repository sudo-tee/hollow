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

const OpenExternalArgs = struct {
    target: []u8,
    opener: ?[]u8,
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

pub fn openExternalWithOpenerAsync(target: []const u8, opener: ?[]const u8) !void {
    const owned_target = try std.heap.page_allocator.dupe(u8, target);
    errdefer std.heap.page_allocator.free(owned_target);
    const owned_opener = if (opener) |value| try std.heap.page_allocator.dupe(u8, value) else null;
    errdefer if (owned_opener) |value| std.heap.page_allocator.free(value);

    const thread = try std.Thread.spawn(.{}, openExternalThread, .{OpenExternalArgs{ .target = owned_target, .opener = owned_opener }});
    thread.detach();
}

fn openExternalThread(args: OpenExternalArgs) void {
    defer std.heap.page_allocator.free(args.target);
    defer if (args.opener) |value| std.heap.page_allocator.free(value);

    if (args.opener) |opener| {
        openWithCommand(opener, args.target) catch |err| {
            std.log.err("open external failed: {s}", .{@errorName(err)});
        };
        return;
    }

    openExternal(args.target) catch |err| {
        std.log.err("open external failed: {s}", .{@errorName(err)});
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
    var child_args: std.ArrayList([]const u8) = .empty;
    defer child_args.deinit(std.heap.page_allocator);
    try child_args.appendSlice(std.heap.page_allocator, argv);
    try child_args.append(std.heap.page_allocator, target);

    var child = std.process.Child.init(child_args.items, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
}

fn openWithCommand(opener: []const u8, target: []const u8) !void {
    var child = std.process.Child.init(&.{ opener, target }, std.heap.page_allocator);
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
        .linux => if (comptime builtin.os.tag == .linux) std.posix.getenv("SHELL") orelse "/bin/sh" else "/bin/sh",
        .macos => "/bin/zsh",
    };
}

pub fn windowsShellCandidates() []const []const u8 {
    return &.{
        "pwsh.exe",
        "powershell.exe",
        "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
        "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
        "cmd.exe",
        "C:\\Windows\\System32\\cmd.exe",
        "wsl.exe",
        "C:\\Windows\\System32\\wsl.exe",
    };
}

fn envOwnedOrNull(allocator: std.mem.Allocator, key: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, key) catch null;
}

pub fn userDataDir(allocator: std.mem.Allocator) ![]u8 {
    if (isWindows()) {
        if (envOwnedOrNull(allocator, "APPDATA")) |appdata| {
            defer allocator.free(appdata);
            return std.fs.path.join(allocator, &.{ appdata, "hollow" });
        }

        if (envOwnedOrNull(allocator, "USERPROFILE")) |profile| {
            defer allocator.free(profile);
            return std.fs.path.join(allocator, &.{ profile, "AppData", "Roaming", "hollow" });
        }

        return allocator.dupe(u8, "C:\\Users\\Default\\AppData\\Roaming\\hollow");
    }

    if (envOwnedOrNull(allocator, "XDG_DATA_HOME")) |xdg| {
        defer allocator.free(xdg);
        return std.fs.path.join(allocator, &.{ xdg, "hollow" });
    }

    if (envOwnedOrNull(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".local", "share", "hollow" });
    }

    return allocator.dupe(u8, "/tmp/hollow");
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

/// Returns the Hollow runtime directory path (e.g., %LOCALAPPDATA%\hollow on Windows).
/// Creates the directory if it doesn't exist.
/// Caller must free the returned path.
pub fn ensureHollowRuntimeDir(allocator: std.mem.Allocator) ![]u8 {
    const base_dir = if (isWindows())
        std.process.getEnvVarOwned(allocator, "LOCALAPPDATA") catch |err| blk: {
            if (err == error.EnvironmentVariableNotFound) {
                std.log.warn("LOCALAPPDATA not set, using fallback", .{});
                break :blk try allocator.dupe(u8, "C:\\Users\\Default\\AppData\\Local");
            }
            return err;
        }
    else if (isMacos())
        std.process.getEnvVarOwned(allocator, "HOME") catch |err| blk: {
            if (err == error.EnvironmentVariableNotFound) {
                break :blk try allocator.dupe(u8, "/tmp");
            }
            return err;
        }
    else // Linux/Unix
        std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR") catch |err| blk: {
            if (err == error.EnvironmentVariableNotFound) {
                const home = std.process.getEnvVarOwned(allocator, "HOME") catch "/tmp";
                defer if (!std.mem.eql(u8, home, "/tmp")) allocator.free(home);
                break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share" });
            }
            return err;
        };
    defer allocator.free(base_dir);

    const hollow_dir = try std.fs.path.join(allocator, &.{ base_dir, "hollow" });
    errdefer allocator.free(hollow_dir);

    // Create the directory if it doesn't exist
    std.fs.makeDirAbsolute(hollow_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    return hollow_dir;
}

// ---------------------------------------------------------------------------
// WSL config path discovery (Windows only)
// ---------------------------------------------------------------------------

/// Run a command and return its stdout/stderr plus exit term.
/// Caller must free stdout/stderr. Returns null on spawn failure (e.g. wsl.exe not found).
fn runWslCommand(allocator: std.mem.Allocator, argv: []const []const u8) ?struct { stdout: []u8, stderr: []u8, term: std.process.Child.Term } {
    const timeout_ms = 3000;

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.create_no_window = true;

    child.spawn() catch return null;
    errdefer {
        _ = child.kill() catch {};
    }

    if (builtin.os.tag == .windows) {
        const wait_result = std.os.windows.kernel32.WaitForSingleObject(child.id, timeout_ms);
        if (wait_result != std.os.windows.WAIT_OBJECT_0) {
            std.log.warn("WSL command timed out after {d}ms", .{timeout_ms});
            _ = child.kill() catch {};
            return null;
        }
    }

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    child.collectOutput(allocator, &stdout, &stderr, 4096) catch return null;
    const term = child.wait() catch return null;

    return .{
        .stdout = stdout.toOwnedSlice(allocator) catch return null,
        .stderr = stderr.toOwnedSlice(allocator) catch return null,
        .term = term,
    };
}

/// Parse `wsl.exe -l -q` output (UTF-16LE) and return the first distro name.
/// Caller must free the returned slice.
fn wslDefaultDistro(allocator: std.mem.Allocator) ?[]u8 {
    const result = runWslCommand(allocator, &.{ "wsl.exe", "-l", "-q" }) orelse return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const success = switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!success or result.stdout.len == 0) return null;

    // wsl.exe -l -q outputs UTF-16LE. Detect by checking for frequent null bytes.
    var stdout_utf8 = result.stdout;
    var decoded: ?[]u8 = null;
    defer if (decoded) |d| allocator.free(d);

    if (result.stdout.len % 2 == 0) {
        var null_count: usize = 0;
        for (result.stdout) |b| {
            if (b == 0) null_count += 1;
        }
        if (null_count > result.stdout.len / 4) {
            const wide = allocator.alloc(u16, result.stdout.len / 2) catch return null;
            defer allocator.free(wide);
            for (wide, 0..) |*code_unit, index| {
                const lo = @as(u16, result.stdout[index * 2]);
                const hi = @as(u16, result.stdout[index * 2 + 1]) << 8;
                code_unit.* = lo | hi;
            }
            decoded = std.unicode.utf16LeToUtf8Alloc(allocator, wide) catch return null;
            stdout_utf8 = decoded.?;
        }
    }

    // First non-empty line is the default distro.
    var iter = std.mem.splitSequence(u8, stdout_utf8, "\n");
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len > 0) return allocator.dupe(u8, trimmed) catch null;
    }
    return null;
}

/// Get the Windows USERNAME env var (used as a fast-path for Linux home).
fn windowsUsername(allocator: std.mem.Allocator) ?[]u8 {
    return envOwnedOrNull(allocator, "USERNAME");
}

/// Build a WSL UNC config path: `\\wsl.localhost\<distro>\home\<user>\.config\hollow\init.lua`.
fn buildWslConfigPath(allocator: std.mem.Allocator, distro: []const u8, linux_home: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\\\\wsl.localhost\\{s}{s}\\.config\\hollow\\init.lua", .{ distro, linux_home });
}

/// Build a WSL UNC home path: `\\wsl.localhost\<distro>\home\<user>`.
fn buildWslHomePath(allocator: std.mem.Allocator, distro: []const u8, linux_home: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\\\\wsl.localhost\\{s}{s}", .{ distro, linux_home });
}

/// Query the Linux HOME directory for a WSL distro by running `printenv HOME`.
/// Falls back to `/home/<windows_username>` if the query fails.
fn wslLinuxHome(allocator: std.mem.Allocator, distro: []const u8) ?[]u8 {
    // Try querying the actual Linux HOME (handles custom usernames).
    if (runWslCommand(allocator, &.{ "wsl.exe", "-d", distro, "--exec", "printenv", "HOME" })) |result| {
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const trimmed = std.mem.trim(u8, result.stdout, " \r\t\n");
        if (trimmed.len > 0 and trimmed[0] == '/') {
            return allocator.dupe(u8, trimmed) catch null;
        }
    }

    // Fall back to /home/<windows_username>.
    if (windowsUsername(allocator)) |username| {
        defer allocator.free(username);
        return std.fmt.allocPrint(allocator, "/home/{s}", .{username}) catch null;
    }

    return null;
}

/// Return the WSL Linux-side config path for the default distro, or null.
/// Checks `\\wsl.localhost\<distro>\home\<user>\.config\hollow\init.lua`.
/// Caller must free the returned path.
pub fn wslDefaultConfigPath(allocator: std.mem.Allocator) ?[]u8 {
    if (!isWindows()) return null;

    const distro = wslDefaultDistro(allocator) orelse return null;
    defer allocator.free(distro);

    const linux_home = wslLinuxHome(allocator, distro) orelse return null;
    defer allocator.free(linux_home);

    return buildWslConfigPath(allocator, distro, linux_home) catch null;
}

/// Return the WSL Linux-side home directory for the default distro, or null.
/// Caller must free the returned path.
pub fn wslHomeDir(allocator: std.mem.Allocator) ?[]u8 {
    if (!isWindows()) return null;

    const distro = wslDefaultDistro(allocator) orelse return null;
    defer allocator.free(distro);

    const linux_home = wslLinuxHome(allocator, distro) orelse return null;
    defer allocator.free(linux_home);

    return buildWslHomePath(allocator, distro, linux_home) catch null;
}

test "platform names are stable" {
    try std.testing.expect(name().len > 0);
    try std.testing.expect(defaultShell().len > 0);
}
