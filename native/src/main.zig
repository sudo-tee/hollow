const std = @import("std");
const App = @import("app.zig").App;
const sokol_runtime = @import("render/sokol_runtime.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cli = try parseArgs(allocator);
    defer if (cli.config_path) |path| allocator.free(path);

    var app = App.init(allocator);
    defer app.deinit();

    try app.bootstrap(cli.config_path);
    app.report();
    try sokol_runtime.run(&app);
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
