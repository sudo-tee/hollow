const std = @import("std");
const App = @import("app.zig").App;
const builtin = @import("builtin");
const sokol_runtime = @import("render/sokol_runtime.zig");
const ft_renderer = @import("render/ft_renderer.zig");

const win32 = if (builtin.os.tag == .windows) struct {
    const BOOL = i32;
    const DWORD = u32;
    const HANDLE = ?*anyopaque;
    const ATTACH_PARENT_PROCESS: DWORD = 0xFFFF_FFFF;
    const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
    const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));
    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

    pub extern "kernel32" fn AttachConsole(dwProcessId: DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) HANDLE;
} else struct {};

var g_log_file: ?std.fs.File = null;
var g_log_mutex: std.Thread.Mutex = .{};
threadlocal var g_log_recursion_depth: usize = 0;

pub const std_options: std.Options = .{
    .logFn = fileLogFn,
    .enable_segfault_handler = true,
};

fn writeLogLine(prefix: []const u8, text: []const u8) void {
    if (g_log_file) |f| {
        const needs_lock = g_log_recursion_depth == 0;
        if (needs_lock) {
            g_log_recursion_depth = 1;
            g_log_mutex.lock();
        } else {
            g_log_recursion_depth += 1;
        }
        defer {
            g_log_recursion_depth -= 1;
            if (needs_lock) g_log_mutex.unlock();
        }
        var buf: [1024]u8 = undefined;
        var w = f.writer(&buf);
        w.interface.print("[{s}] {s}\n", .{ prefix, text }) catch {};
        w.interface.flush() catch {};
        f.sync() catch {};
    }
}

fn writeCurrentStackToLog(start_addr: ?usize) void {
    if (g_log_file) |f| {
        const needs_lock = g_log_recursion_depth == 0;
        if (needs_lock) {
            g_log_recursion_depth = 1;
            g_log_mutex.lock();
        } else {
            g_log_recursion_depth += 1;
        }
        defer {
            g_log_recursion_depth -= 1;
            if (needs_lock) g_log_mutex.unlock();
        }
        var buf: [2048]u8 = undefined;
        var w = f.writer(&buf);

        const debug_info = std.debug.getSelfDebugInfo() catch |err| {
            w.interface.print("[panic] unable to load debug info: {s}\n", .{@errorName(err)}) catch {};
            w.interface.flush() catch {};
            f.sync() catch {};
            return;
        };

        w.interface.writeAll("[panic] stack trace:\n") catch {};
        std.debug.writeCurrentStackTrace(&w.interface, debug_info, .no_color, start_addr) catch |err| {
            w.interface.print("[panic] unable to write stack trace: {s}\n", .{@errorName(err)}) catch {};
        };
        w.interface.writeAll("\n") catch {};
        w.interface.flush() catch {};
        f.sync() catch {};
    }
}

fn fileLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    const prefix = comptime level.asText();
    if (g_log_file) |f| {
        const needs_lock = g_log_recursion_depth == 0;
        if (needs_lock) {
            g_log_recursion_depth = 1;
            g_log_mutex.lock();
        } else {
            g_log_recursion_depth += 1;
        }
        defer {
            g_log_recursion_depth -= 1;
            if (needs_lock) g_log_mutex.unlock();
        }
        var buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        fbs.writer().print("[{s}] " ++ format ++ "\n", .{prefix} ++ args) catch {};
        const written = fbs.getWritten();
        _ = f.writeAll(written) catch {};
    }
}

pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ra: ?usize) noreturn {
    std.log.err("PANIC: {s}", .{msg});
    writeLogLine("panic", msg);
    if (trace) |t| {
        if (g_log_file) |f| {
            const needs_lock = g_log_recursion_depth == 0;
            if (needs_lock) {
                g_log_recursion_depth = 1;
                g_log_mutex.lock();
            } else {
                g_log_recursion_depth += 1;
            }
            defer {
                g_log_recursion_depth -= 1;
                if (needs_lock) g_log_mutex.unlock();
            }
            var buf: [2048]u8 = undefined;
            var w = f.writer(&buf);

            const debug_info = std.debug.getSelfDebugInfo() catch |err| {
                w.interface.print("[panic] unable to load debug info: {s}\n", .{@errorName(err)}) catch {};
                w.interface.flush() catch {};
                f.sync() catch {};
                std.process.abort();
            };

            w.interface.writeAll("[panic] error return trace:\n") catch {};
            std.debug.writeStackTrace(t.*, &w.interface, debug_info, .no_color) catch |err| {
                w.interface.print("[panic] unable to write error return trace: {s}\n", .{@errorName(err)}) catch {};
            };
            w.interface.writeAll("\n") catch {};
            w.interface.flush() catch {};
            f.sync() catch {};
        }
    }
    writeCurrentStackToLog(ra orelse @returnAddress());
    std.process.abort();
}

pub fn main() !void {
    // Open log file next to the exe (works even without a console).
    g_log_file = std.fs.cwd().createFile("hollow.log", .{ .truncate = true }) catch null;
    defer if (g_log_file) |f| f.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cli = parseArgs(allocator) catch |err| {
        std.log.err("parseArgs failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer if (cli.config_path) |path| allocator.free(path);
    defer if (cli.startup_command) |cmd| allocator.free(cmd);
    defer if (cli.snapshot_dump_path) |path| allocator.free(path);
    defer if (cli.match_font) |query| allocator.free(query);

    if (cli.list_fonts or cli.match_font != null) {
        try printAvailableFonts(allocator, cli.match_font, cli.list_fonts_json);
        return;
    }

    var app = App.init(allocator);
    defer app.deinit();
    try app.configureAutomation(cli.startup_command, cli.startup_command_delay_frames, cli.snapshot_dump_path);

    app.bootstrap(cli.config_path) catch |err| {
        std.log.err("bootstrap failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    if (cli.renderer_safe_mode) {
        app.config.renderer_safe_mode = true;
        app.config.renderer_disable_swapchain_glyphs = true;
    }
    if (cli.renderer_disable_swapchain_glyphs) app.config.renderer_disable_swapchain_glyphs = true;
    if (cli.renderer_disable_multi_pane_cache) app.config.renderer_disable_multi_pane_cache = true;
    app.report();
    sokol_runtime.run(&app) catch |err| {
        std.log.err("sokol_runtime failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

const Cli = struct {
    config_path: ?[]u8 = null,
    renderer_safe_mode: bool = false,
    renderer_disable_swapchain_glyphs: bool = false,
    renderer_disable_multi_pane_cache: bool = false,
    startup_command: ?[]u8 = null,
    startup_command_delay_frames: usize = 20,
    snapshot_dump_path: ?[]u8 = null,
    list_fonts: bool = false,
    list_fonts_json: bool = false,
    match_font: ?[]u8 = null,
};

fn parseArgs(allocator: std.mem.Allocator) !Cli {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var cli = Cli{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return error.MissingConfigPath;
            cli.config_path = try allocator.dupe(u8, args[i]);
            continue;
        }

        if (std.mem.eql(u8, arg, "--renderer-safe-mode")) {
            cli.renderer_safe_mode = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--renderer-disable-swapchain-glyphs")) {
            cli.renderer_disable_swapchain_glyphs = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--renderer-disable-multi-pane-cache")) {
            cli.renderer_disable_multi_pane_cache = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--startup-command")) {
            i += 1;
            if (i >= args.len) return error.MissingStartupCommand;
            cli.startup_command = try allocator.dupe(u8, args[i]);
            continue;
        }

        if (std.mem.eql(u8, arg, "--startup-command-delay-frames")) {
            i += 1;
            if (i >= args.len) return error.MissingStartupCommandDelay;
            cli.startup_command_delay_frames = try std.fmt.parseInt(usize, args[i], 10);
            continue;
        }

        if (std.mem.eql(u8, arg, "--snapshot-dump")) {
            i += 1;
            if (i >= args.len) return error.MissingSnapshotDumpPath;
            cli.snapshot_dump_path = try allocator.dupe(u8, args[i]);
            continue;
        }

        if (std.mem.eql(u8, arg, "--list-fonts")) {
            cli.list_fonts = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--json")) {
            cli.list_fonts_json = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--match-font")) {
            i += 1;
            if (i >= args.len) return error.MissingMatchFontQuery;
            cli.match_font = try allocator.dupe(u8, args[i]);
            continue;
        }

        if (std.mem.eql(u8, arg, "--help")) {
            try writeConsoleText("usage: hollow-native [--config path] [--renderer-safe-mode] [--renderer-disable-swapchain-glyphs] [--renderer-disable-multi-pane-cache] [--startup-command text] [--startup-command-delay-frames n] [--snapshot-dump path] [--list-fonts] [--match-font query] [--json]\n");
            std.process.exit(0);
        }
    }

    return cli;
}

fn printAvailableFonts(allocator: std.mem.Allocator, query: ?[]const u8, as_json: bool) !void {
    const families = try ft_renderer.listAvailableFontsDetailed(allocator);
    defer {
        for (families) |*family| family.deinit(allocator);
        allocator.free(families);
    }

    if (as_json) {
        try printAvailableFontsJson(allocator, families, query);
        return;
    }

    for (families) |family| {
        if (!fontFamilyMatchesQuery(family, query)) continue;
        try writeConsoleText(family.family);
        if (family.styles.len > 0) {
            try writeConsoleText(": ");
            for (family.styles, 0..) |style, i| {
                if (i > 0) try writeConsoleText(", ");
                try writeConsoleText(style.style);
            }
        }
        try writeConsoleText("\n");
    }
}

fn printAvailableFontsJson(allocator: std.mem.Allocator, families: []const ft_renderer.FontFamilyInfo, query: ?[]const u8) !void {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "[\n");
    var first_family = true;
    for (families) |family| {
        if (!fontFamilyMatchesQuery(family, query)) continue;
        if (!first_family) try list.appendSlice(allocator, ",\n");
        first_family = false;

        try list.appendSlice(allocator, "  {\"family\":");
        try appendJsonString(allocator, &list, family.family);
        try list.appendSlice(allocator, ",\"styles\":[");
        for (family.styles, 0..) |style, i| {
            if (i > 0) try list.appendSlice(allocator, ",");
            try appendJsonString(allocator, &list, style.style);
        }
        try list.appendSlice(allocator, "]}");
    }
    try list.appendSlice(allocator, "\n]\n");
    try writeConsoleText(list.items);
}

fn appendJsonString(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    try list.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '"' => try list.appendSlice(allocator, "\\\""),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            0...8, 11, 12, 14...31 => {
                var buf: [6]u8 = undefined;
                _ = try std.fmt.bufPrint(&buf, "\\u{X:0>4}", .{ch});
                try list.appendSlice(allocator, &buf);
            },
            else => try list.append(allocator, ch),
        }
    }
    try list.append(allocator, '"');
}

fn fontFamilyMatchesQuery(family: ft_renderer.FontFamilyInfo, query: ?[]const u8) bool {
    const q = query orelse return true;
    var query_buf: [256]u8 = undefined;
    const normalized_query = normalizeCliQuery(&query_buf, q);
    if (normalized_query.len == 0) return true;

    var family_buf: [256]u8 = undefined;
    const normalized_family = normalizeCliQuery(&family_buf, family.family);
    if (std.mem.indexOf(u8, normalized_family, normalized_query) != null) return true;

    for (family.styles) |style| {
        var style_buf: [256]u8 = undefined;
        const normalized_style = normalizeCliQuery(&style_buf, style.style);
        if (std.mem.indexOf(u8, normalized_style, normalized_query) != null) return true;
    }
    return false;
}

fn normalizeCliQuery(buf: []u8, input: []const u8) []const u8 {
    var len: usize = 0;
    for (input) |ch| {
        if (!std.ascii.isAlphanumeric(ch)) continue;
        if (len == buf.len) break;
        buf[len] = std.ascii.toLower(ch);
        len += 1;
    }
    return buf[0..len];
}

fn writeConsoleText(text: []const u8) !void {
    const stdout = ensureConsoleStdOut() orelse return;
    try stdout.writeAll(text);
}

fn ensureConsoleStdOut() ?std.fs.File {
    if (builtin.os.tag != .windows) return std.fs.File.stdout();

    _ = win32.AttachConsole(win32.ATTACH_PARENT_PROCESS);
    const handle = win32.GetStdHandle(win32.STD_OUTPUT_HANDLE) orelse return null;
    if (handle == win32.INVALID_HANDLE_VALUE) return null;
    return std.fs.File{ .handle = handle };
}

test {
    _ = @import("config.zig");
    _ = @import("platform.zig");
    _ = @import("lua_bridge.zig");
}
