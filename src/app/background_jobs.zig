//! Automation-owned, retained panes. Handles cannot target ordinary user panes.
const std = @import("std");
const App = @import("../app.zig").App;
const Pane = @import("../pane.zig").Pane;
const command = @import("../command.zig");
const io = @import("../io.zig");
const lifecycle = @import("pane_lifecycle.zig");
pub const max_jobs = 64;

fn value(app: *App, result: anytype) !command.Response {
    const text = try std.json.Stringify.valueAlloc(app.allocator, result, .{});
    defer app.allocator.free(text);
    var parsed = try std.json.parseFromSlice(std.json.Value, app.allocator, text, .{});
    defer parsed.deinit();
    return .ok(try command.cloneJsonValue(app.allocator, parsed.value));
}

pub fn spawn(app: *App, args: command.JobSpawn) !command.Response {
    const mux = if (app.mux) |*m| m else return .fail("unavailable", "multiplexer unavailable");
    const runtime = if (app.ghostty) |*r| r else return .fail("unavailable", "terminal unavailable");
    const workspace = mux.activeWorkspace() orelse return .fail("unavailable", "no active workspace");
    var count: usize = 0;
    var panes = mux.paneIterator();
    while (panes.next()) |pane| if (pane.automation_token != null) {
        count += 1;
    };
    if (count >= max_jobs) return .fail("resource_exhausted", "clean up retained jobs before spawning more");
    const cursor = app.automation_events.subscribe();
    var random: [16]u8 = undefined;
    std.Io.random(io.get(), &random);
    const token = std.fmt.bytesToHex(random, .lower);
    // Allocate the response before launch: no post-launch OOM loses the handle.
    var response = try value(app, .{ .pane_id = @as(usize, 1), .tab_id = @as(usize, 1), .workspace_id = workspace.id, .token = &token, .cursor = cursor });
    errdefer response.deinit(app.allocator);
    const tab = mux.newTabWithFocus(runtime, @import("terminal_callbacks.zig").terminalCallbacks(), app.config, app.cell_width_px, app.cell_height_px, app.config.window_width, app.config.window_height, args.cwd, args.domain, .{ .command = args.cmd orelse "", .argv = args.argv, .one_shot = args.cmd != null or args.user_shell, .user_shell = args.user_shell }, true, false) catch |err| {
        response.deinit(app.allocator);
        return .fail("spawn_failed", @errorName(err));
    };
    const pane = tab.activePane().?;
    pane.automation_token = token;
    response.payload.?.object.getPtr("pane_id").?.* = .{ .integer = @intCast(@intFromPtr(pane)) };
    response.payload.?.object.getPtr("tab_id").?.* = .{ .integer = @intCast(tab.id) };
    @import("htp.zig").bindHtpHandlers(app);
    app.requestLayoutRefresh();
    app.markAutomationChanged();
    app.signalWake();
    return response;
}

fn ownedPane(app: anytype, args: command.JobHandle) ?*Pane {
    const pane = app.findPaneById(args.id) orelse return null;
    const token = pane.automation_token orelse return null;
    return if (std.mem.eql(u8, &token, args.token)) pane else null;
}

pub fn get(app: *App, args: command.JobHandle) !command.Response {
    const pane = ownedPane(app, args) orelse return .fail("job_not_found", "no matching automation-owned pane");
    const running = pane.hasLiveChild() or (if (pane.pty) |*pty| pty.jobOutputPending() else false);
    if (!running) lifecycle.exited(app, pane);
    return value(app, .{ .pane_id = args.id, .state = if (running) @as([]const u8, "running") else "exited", .status = if (pane.pty) |*pty| pty.exitStatus() else null, .cursor = app.automation_events.subscribe(), .output_bytes = pane.job_output.len, .output_truncated = pane.job_output.truncated, .output_incomplete = pane.job_output.incomplete });
}

pub fn output(app: *App, args: command.JobHandle) !command.Response {
    const pane = ownedPane(app, args) orelse return .fail("job_not_found", "no matching automation-owned pane");
    const bytes = try pane.job_output.snapshot(app.allocator);
    defer app.allocator.free(bytes);
    const encoded = try app.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    defer app.allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return value(app, .{ .encoding = "base64", .data = encoded, .truncated = pane.job_output.truncated, .incomplete = pane.job_output.incomplete, .capacity_bytes = @import("../job_output.zig").capacity });
}

pub fn cleanup(app: *App, args: command.JobHandle) command.Response {
    const pane = ownedPane(app, args) orelse return .fail("job_not_found", "no matching automation-owned pane");
    // Cleanup is not cancellation: never silently kill a running workload.
    if (pane.hasLiveChild() or (if (pane.pty) |*pty| pty.jobOutputPending() else false)) return .fail("job_running", "job still running or output is draining; cleanup refused");
    const mux = if (app.mux) |*m| m else return .fail("unavailable", "multiplexer unavailable");
    const runtime = if (app.ghostty) |*r| r else return .fail("unavailable", "terminal unavailable");
    // Closing the original pane only preserves any user-added panes in its tab.
    const active = mux.activePane();
    const previous = if (active == pane) null else active;
    if (mux.closePaneByIdWithFocus(runtime, args.id, false)) {
        @import("session_controller.zig").quitOnWorkspaceRemoved(app, mux, null);
    } else {
        @import("session_controller.zig").emitWorkspaceClosedIfRemoved(app, mux);
        app.syncActivePaneChange(previous, mux.activePane());
        app.refreshActivePaneBinding();
        app.requestLayoutResize(false);
        app.requestLayoutRefresh();
    }
    app.markAutomationChanged();
    return .ok(null);
}

test "background jobs: ownership rejects ordinary panes, mismatched tokens, and recycled pane addresses" {
    var pane = Pane.init(std.testing.allocator);
    const Fake = struct {
        pane: *Pane,
        fn findPaneById(self: *@This(), id: usize) ?*Pane {
            return if (id == @intFromPtr(self.pane)) self.pane else null;
        }
    };
    var app: Fake = .{ .pane = &pane };
    const handle: command.JobHandle = .{ .id = @intFromPtr(&pane), .token = "0123456789abcdef0123456789abcdef" };
    try std.testing.expect(ownedPane(&app, handle) == null);
    pane.automation_token = "0123456789abcdef0123456789abcdef".*;
    try std.testing.expect(ownedPane(&app, handle) == &pane);
    pane.automation_token = "fedcba9876543210fedcba9876543210".*;
    try std.testing.expect(ownedPane(&app, handle) == null);
}
