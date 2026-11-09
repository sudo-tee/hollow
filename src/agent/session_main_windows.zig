//! Session-only Windows executable; Linux RPC/PTY/mux modes are not ported.
const std = @import("std");
const owner = @import("session_windows.zig");
const pipe = @import("session_pipe_windows.zig");
const p = @import("session_protocol.zig");

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        var buffer: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "hollow-agent session: {s}\n", .{@errorName(err)}) catch unreachable;
        std.Io.File.stderr().writeStreamingAll(init.io, text) catch {};
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    if (!std.mem.eql(u8, args.next() orelse return error.InvalidArgument, "session")) return error.Unsupported;
    const command = args.next() orelse return error.InvalidArgument;
    var namespace: ?[]const u8 = null;
    if (args.next()) |option| {
        if (!std.mem.eql(u8, option, "--namespace")) return error.InvalidArgument;
        namespace = args.next() orelse return error.InvalidArgument;
        if (args.next() != null) return error.InvalidArgument;
    }
    if (std.mem.eql(u8, command, "serve")) return owner.serve(init.gpa, init.io, namespace) catch |err| {
        // Detached production owners cannot depend on stderr. Fixture errors
        // and expected singleton losers must not replace real diagnostics.
        if (namespace == null and err != error.OwnerExists) logFailure(init, err);
        return err;
    };
    const operation: p.Op = if (std.mem.eql(u8, command, "list")) .list else if (std.mem.eql(u8, command, "kill-server")) .kill_server else return error.Unsupported;
    // Discovery and explicit cleanup never start an owner merely to query it.
    var endpoint = try pipe.Endpoint.init(init.gpa, namespace);
    defer endpoint.deinit(init.gpa);
    const handle = (try endpoint.connect()) orelse {
        try std.Io.File.stdout().writeStreamingAll(init.io, if (operation == .list) "{\"id\":1,\"ok\":true,\"sessions\":[]}\n" else "{\"id\":1,\"ok\":true}\n");
        return;
    };
    var connection = try owner.Connection.init(init.gpa, handle);
    defer connection.deinit();
    try connection.sendJson(.hello, p.Hello{ .protocol = p.protocol, .version = p.version, .ghostty = "bootstrap-cli", .client = "hollow-agent" });
    const welcome = try connection.next(5000);
    if (welcome.kind != .welcome) return error.ExpectedWelcome;
    const parsed = try p.parse(p.Welcome, init.gpa, welcome.payload);
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.protocol, p.protocol) or parsed.value.version != p.version) return error.ProtocolMismatch;
    try connection.sendJson(.request, p.Request{ .id = 1, .op = operation });
    const reply = try connection.next(5000);
    if (reply.kind != .reply) return error.InvalidReply;
    const result = try p.parse(p.Reply, init.gpa, reply.payload);
    defer result.deinit();
    if (result.value.id != 1) return error.InvalidReply;
    try std.Io.File.stdout().writeStreamingAll(init.io, reply.payload);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    if (!result.value.ok) return error.Rejected;
}

fn logFailure(init: std.process.Init, err: anyerror) void {
    const root = init.minimal.environ.getAlloc(init.gpa, "LOCALAPPDATA") catch return;
    defer init.gpa.free(root);
    const dir = std.fs.path.join(init.gpa, &.{ root, "hollow" }) catch return;
    defer init.gpa.free(dir);
    std.Io.Dir.cwd().createDirPath(init.io, dir) catch return;
    const path = std.fs.path.join(init.gpa, &.{ dir, "session-owner-error.log" }) catch return;
    defer init.gpa.free(path);
    // Bounded last-failure record; detached owners cannot depend on stderr.
    const file = std.Io.Dir.createFileAbsolute(init.io, path, .{}) catch return;
    defer file.close(init.io);
    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}: {s}\n", .{ owner.nowMs(), @errorName(err) }) catch return;
    file.writeStreamingAll(init.io, text) catch {};
}
