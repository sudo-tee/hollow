const std = @import("std");
const App = @import("app.zig").App;
const sokol_runtime = @import("render/sokol_runtime.zig");

var g_log_file: ?std.fs.File = null;
var g_log_mutex: std.Thread.Mutex = .{};

pub const std_options: std.Options = .{
    .logFn = fileLogFn,
    .enable_segfault_handler = true,
};

fn writeLogLine(prefix: []const u8, text: []const u8) void {
    if (g_log_file) |f| {
        g_log_mutex.lock();
        defer g_log_mutex.unlock();
        var buf: [1024]u8 = undefined;
        var w = f.writer(&buf);
        w.interface.print("[{s}] {s}\n", .{ prefix, text }) catch {};
        w.interface.flush() catch {};
        f.sync() catch {};
    }
}

fn writeCurrentStackToLog(start_addr: ?usize) void {
    if (g_log_file) |f| {
        g_log_mutex.lock();
        defer g_log_mutex.unlock();
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
        g_log_mutex.lock();
        defer g_log_mutex.unlock();
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
            g_log_mutex.lock();
            defer g_log_mutex.unlock();
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

    var app = App.init(allocator);
    defer app.deinit();

    app.bootstrap(cli.config_path) catch |err| {
        std.log.err("bootstrap failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    app.report();
    sokol_runtime.run(&app) catch |err| {
        std.log.err("sokol_runtime failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

const Cli = struct {
    config_path: ?[]u8 = null,
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

        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("usage: hollow-native [--config path]\n", .{});
            std.process.exit(0);
        }
    }

    return cli;
}

test {
    _ = @import("config.zig");
    _ = @import("platform.zig");
}
