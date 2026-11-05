//! Opt-in domain admission. All resolution is synchronous configuration work;
//! deployment, connection and owner creation stay in the asynchronous opener.
const std = @import("std");
const builtin = @import("builtin");
const App = @import("../app.zig").App;
const Config = @import("../config.zig").Config;
const agent = @import("../pty/agent.zig");
const spec = @import("../pty/spawn_spec.zig");
const wire = @import("../agent/pty_protocol.zig");
const transport = @import("../session/transport.zig");
const opens = @import("session_open.zig");
const max_env_bytes = 64 * 1024;

pub fn begin(app: *App, cwd: ?[]const u8, domain_name: ?[]const u8, command: ?[]const u8, name: ?[]const u8, callback_ref: c_int, startup: bool) !u64 {
    return open(app, cwd, domain_name, command, name, callback_ref, startup, null);
}

pub fn attach(app: *App, session_id: []const u8, domain_name: ?[]const u8, name: ?[]const u8, callback_ref: c_int) void {
    const inherited = domain_name orelse if (app.activePane()) |pane|
        (if (pane.domainName().len > 0) pane.domainName() else app.config.defaultDomainName())
    else
        app.config.defaultDomainName();
    _ = open(app, null, inherited, null, name, callback_ref, false, session_id) catch |err| {
        std.log.warn("persistent attachment admission failed: {s}", .{@errorName(err)});
        opens.reportAdmissionFailure(app, err, false);
        if (app.lua) |*lua| lua.invokeOperationCallback(callback_ref, false, .none);
        return;
    };
}

fn open(app: *App, cwd: ?[]const u8, domain_name: ?[]const u8, command: ?[]const u8, name: ?[]const u8, callback_ref: c_int, startup: bool, session_id: ?[]const u8) !u64 {
    if (session_id) |id| if (id.len == 0 or id.len > 128 or std.mem.indexOfScalar(u8, id, 0) != null) return error.InvalidSessionId;
    const selected_domain = domain_name orelse app.config.defaultDomainName() orelse return error.UnknownDomain;
    if (!app.config.persistForDomain(selected_domain)) return error.PersistenceNotEnabled;
    const definition = app.config.domainByName(selected_domain) orelse return error.UnknownDomain;
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Host resolution invokes Lua, which can synchronously update config.
    // Retain no domain/default-shell pointers across that call.
    const domain = try a.dupe(u8, selected_domain);
    const configured_shell = if (definition.shell) |value| try a.dupe(u8, value) else null;
    const shell = configured_shell orelse try a.dupe(u8, app.config.shellOrDefault());
    const configured_cwd = cwd orelse app.config.defaultCwdForDomain(domain);
    var launch_cwd: ?[]const u8 = if (configured_cwd) |value| try a.dupe(u8, value) else null;
    const lua = if (app.lua) |*value| value else return error.LuaUnavailable;
    const host = try lua.sessionHost(a, domain, shell);
    if (host.connector.argv.len == 0 and builtin.os.tag != .linux) return error.NativeSessionOwnerUnsupported;
    const mux = if (app.mux) |*value| value else return error.MuxUnavailable;
    if (launch_cwd == null and host.connector.argv.len == 0 and builtin.os.tag == .linux) {
        launch_cwd = @import("../io.zig").getEnvVarOwned(a, "HOME") catch null;
    }
    const options: transport.Options = .{
        .connector = host.connector,
        .agent = host.agent,
        .ghostty_identity = @import("../term/ghostty.zig").buildIdentity(),
    };
    const request: transport.p.Request = if (session_id) |id|
        .{ .id = 0, .op = .attach, .session = id }
    else
        .{ .id = 0, .op = .create, .spawn = try prepareSpawn(a, app.config, host, if (host.connector.argv.len == 0) shell else configured_shell orelse "", launch_cwd, domain, command, mux.spawn_filter) };
    // Both calls copy request/options before this arena or config can disappear.
    return if (startup)
        opens.beginStartup(app, options, request, domain, name)
    else
        opens.beginWithInput(app, options, request, domain, name, callback_ref, command);
}

fn reservedEnv(key: []const u8) bool {
    return std.mem.eql(u8, key, "HOLLOW_PANE_ID") or
        std.mem.eql(u8, key, "HOLLOW_WORKSPACE_ID") or
        std.mem.eql(u8, key, "HOLLOW_COMMAND_ADDR");
}

/// Arena-owned output. Never place GUI IDs or a client-local command endpoint
/// in a process that outlives/reconnects to different GUIs. OSC is pane-bound.
pub fn prepareSpawn(a: std.mem.Allocator, cfg: Config, host: agent.Host, shell: []const u8, cwd: ?[]const u8, domain: ?[]const u8, command: ?[]const u8, filter: spec.Filter) !wire.Spawn {
    if (host.error_message != null) return error.InvalidSessionHost;
    const local = host.connector.argv.len == 0;
    if (local and builtin.os.tag != .linux) return error.NativeSessionOwnerUnsupported;
    if (shell.len > 64 * 1024 or (cwd != null and cwd.?.len > 32 * 1024) or (command != null and command.?.len > 64 * 1024)) return error.ResourceExhausted;
    var block: std.ArrayList(u8) = .empty;
    try block.appendSlice(a, "TERM=xterm-256color\x00COLORTERM=truecolor\x00TERM_PROGRAM=ghostty\x00");
    const env = cfg.envForDomain(domain);
    if (env.len > 256) return error.ResourceExhausted;
    for (env) |pair| {
        if (reservedEnv(pair.key)) return error.InvalidSessionEnvironment;
        if (pair.key.len == 0 or std.mem.indexOfAny(u8, pair.key, "=\x00") != null or std.mem.indexOfScalar(u8, pair.value, 0) != null) return error.InvalidSessionEnvironment;
        if (pair.key.len + pair.value.len + 2 > max_env_bytes -| block.items.len) return error.ResourceExhausted;
        try block.appendSlice(a, pair.key);
        try block.append(a, '=');
        try block.appendSlice(a, pair.value);
        try block.append(a, 0);
    }
    if (cfg.command_timing) try block.appendSlice(a, "HOLLOW_COMMAND_TIMING=1\x00");
    try block.append(a, 0);
    var spawn_spec: spec.SpawnSpec = .{ .shell = shell, .domain = domain, .cwd = cwd, .env_block = block.items };
    if (local) filter.apply(a, &spawn_spec) catch |err| {
        std.log.warn("session local spawn filter failed: {s}", .{@errorName(err)});
    };
    if (spawn_spec.env_block.len > max_env_bytes) return error.ResourceExhausted;
    const filtered = try agent.parseEnvBlock(a, spawn_spec.env_block);
    if (filtered.len > 256) return error.ResourceExhausted;
    const values = try a.alloc(wire.EnvVar, filtered.len + 1);
    for (filtered, values[0..filtered.len]) |pair, *value| {
        if (reservedEnv(pair.key)) return error.InvalidSessionEnvironment;
        value.* = pair;
    }
    values[filtered.len] = .{ .key = "HOLLOW_TRANSPORT", .value = "osc" };
    const argv = if (!local and spec.isWsl(shell)) try agent.wslInnerArgv(a, shell) else try agent.tokenize(a, shell);
    if (argv.len > 256) return error.ResourceExhausted;
    if (spawn_spec.cwd) |value| if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidSessionCwd;
    if (command) |value| if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidSessionCommand;
    return .{ .cols = cfg.cols, .rows = cfg.rows, .cwd = spawn_spec.cwd, .argv = argv, .env = values, .path_style = host.path_style };
}

fn filterProbe(context: *anyopaque, _: std.mem.Allocator, value: *spec.SpawnSpec) !void {
    const count: *usize = @ptrCast(@alignCast(context));
    count.* += 1;
    value.cwd = "/filtered";
}

test "session pane domain spawn preserves guest argv env and skips local filters" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    try cfg.setDomainPersist("guest", true);
    try cfg.setDomainEnv("guest", "EXAMPLE", "x=y");
    try cfg.setDomainEnv("guest", "HOLLOW_TRANSPORT", "auto");
    var calls: usize = 0;
    const host: agent.Host = .{ .connector = .{ .argv = &.{ "wsl.exe", "--exec" } }, .path_style = .wsl };
    const spawn = try prepareSpawn(arena.allocator(), cfg, host, "wsl.exe -d Ubuntu --exec /bin/zsh -l", "C:\\work", "guest", "printf 'once'", .{ .context = &calls, .callback = filterProbe });
    try std.testing.expectEqual(@as(usize, 0), calls);
    try std.testing.expectEqualStrings("C:\\work", spawn.cwd.?);
    try std.testing.expectEqualStrings("/bin/zsh", spawn.argv[0]);
    try std.testing.expectEqualStrings("-l", spawn.argv[1]);
    try std.testing.expect(spawn.command == null); // Queued into interactive pane, never shell -c.
    try std.testing.expectEqual(wire.PathStyle.wsl, spawn.path_style);
    try std.testing.expectEqualStrings("HOLLOW_TRANSPORT", spawn.env[spawn.env.len - 1].key);
    try std.testing.expectEqualStrings("osc", spawn.env[spawn.env.len - 1].value);
    for (spawn.env) |pair| try std.testing.expect(!reservedEnv(pair.key));
    const guest_shell = try prepareSpawn(arena.allocator(), cfg, host, "/bin/zsh -l", null, "guest", null, .{});
    try std.testing.expectEqualStrings("/bin/zsh", guest_shell.argv[0]);
    try std.testing.expectEqualStrings("-l", guest_shell.argv[1]);
}

fn testApp(a: std.mem.Allocator, connector: []const []const u8, agent_path: []const u8) !*App {
    const app = try a.create(App);
    app.* = App.init(a);
    errdefer {
        app.deinit();
        a.destroy(app);
    }
    app.ghostty = try @import("../term/ghostty.zig").Runtime.init(a, null);
    app.mux = @import("../mux.zig").Mux.init(a);
    app.mux.?.host_context = app;
    try app.config.setDomainPersist("persistent-test", true);
    try app.config.setDomainShell("persistent-test", "wsl.exe --exec /bin/sh");
    app.lua = try @import("../lua_bridge.zig").Runtime.initForTests(a, &app.config);
    const api = app.lua.?.context.api;
    const state = app.lua.?.state;
    api.create_table(state, @intCast(connector.len), 0);
    for (connector, 1..) |arg, i| {
        api.push_lstring(state, arg.ptr, arg.len);
        api.rawseti(state, -2, @intCast(i));
    }
    api.set_field(state, -10002, "__session_test_connector");
    api.push_lstring(state, agent_path.ptr, agent_path.len);
    api.set_field(state, -10002, "__session_test_agent");
    try app.lua.?.runString(
        \\hollow = { _session_host = function()
        \\ return {mode='explicit', path_style='posix',
        \\ connector={argv=__session_test_connector}, agent={path=__session_test_agent, timeout_ms=5000}}
        \\end }
    );
    return app;
}

fn testPump(app: *App) !void {
    opens.pump(app);
    @import("session_controller.zig").pumpSessionControllers(app, &app.ghostty.?);
    var panes = app.mux.?.paneIterator();
    while (panes.next()) |pane| {
        _ = try pane.content.terminal.pollPty(pane, &app.ghostty.?, 16, 64 * 1024, 10 * std.time.ns_per_ms, 16 * 1024, false);
    }
}

fn testWaitText(app: *App, needle: []const u8) !void {
    const io = @import("../io.zig");
    const deadline = io.nanoTimestamp() + 10 * std.time.ns_per_s;
    while (io.nanoTimestamp() < deadline) {
        try testPump(app);
        if (app.activePane()) |pane| {
            const text = try @import("../agent/session_vt.zig").plain(@ptrCast(pane.content.terminal.terminal), std.testing.allocator);
            defer std.testing.allocator.free(text);
            if (std.mem.indexOf(u8, text, needle) != null) return;
        }
        try std.Io.sleep(io.get(), .fromMilliseconds(2), .awake);
    }
    return error.Timeout;
}

test "session borrowers domain create and explicit attach preserve interactive shell state" {
    const a = std.testing.allocator;
    const io = @import("../io.zig");
    const settings = @import("session_test_options");
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const temp = arena_state.allocator();
    const path = settings.agent orelse if (builtin.os.tag == .linux)
        (std.testing.environ.getAlloc(temp, "HOLLOW_TEST_AGENT") catch return error.SkipZigTest)
    else
        return error.SkipZigTest;
    if (builtin.os.tag == .windows and settings.wsl == null) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = if (settings.wsl != null)
        try std.fmt.allocPrint(temp, "/tmp/opencode/hollow-domain-check-{d}", .{io.nanoTimestamp()})
    else
        try std.fmt.allocPrint(temp, "{s}/session", .{try tmp.dir.realPathFileAlloc(io.get(), ".", temp)});
    var connector: std.ArrayList([]const u8) = .empty;
    if (settings.wsl) |distro| try connector.appendSlice(temp, &.{ "wsl.exe", "-d", distro, "--" });
    try connector.appendSlice(temp, &.{ "/usr/bin/env", try std.fmt.allocPrint(temp, "HOLLOW_SESSION_DIR={s}", .{dir}), try std.fmt.allocPrint(temp, "XDG_STATE_HOME={s}", .{dir}) });
    const options: transport.Options = .{ .connector = .{ .argv = connector.items }, .agent = .{ .path = path }, .ghostty_identity = @import("../term/ghostty.zig").buildIdentity() };
    defer {
        if (transport.Connection.create(a, io.get(), options)) |connection| {
            defer connection.destroy();
            _ = connection.request(.{ .id = 0, .op = .kill_server }) catch 0;
            if (@import("../session_transport_test.zig").waitMessage(connection, .reply)) |message| message.deinit() else |_| {}
            @import("../session_transport_test.zig").waitEnded(connection) catch {};
        } else |_| {}
        if (settings.wsl != null) {
            const argv = options.connector.command(temp, &.{ "/bin/sh", "-c", "rm -f -- \"$1/owner.log\" \"$1/session-v1.lock\"; rmdir -- \"$1/hollow/sessions\" \"$1/hollow\" \"$1\"", "cleanup", dir }) catch null;
            if (argv) |args| {
                if (std.process.spawn(io.get(), .{ .argv = args, .stdout = .ignore, .stderr = .ignore, .create_no_window = true })) |value| {
                    var child = value;
                    _ = child.wait(io.get()) catch {};
                } else |_| {}
            }
        }
    }
    var session_id: []const u8 = undefined;
    {
        const app = try testApp(a, connector.items, path);
        defer a.destroy(app);
        defer app.deinit();
        @import("session_controller.zig").newWorkspace(app, null, "persistent-test", "MY_SESSION_VALUE=kept; printf 'persisted-marker'", "persistent-check", -1);
        try testWaitText(app, "persisted-marker");
        session_id = try temp.dupe(u8, app.activeWorkspace().?.session_controller.?.session_id);
        try std.testing.expect(app.activePane().?.content.terminal.pty.?.isAlive());
    }
    const app = try testApp(a, connector.items, path);
    defer a.destroy(app);
    defer app.deinit();
    attach(app, session_id, "persistent-test", null, -1);
    try testWaitText(app, "persisted-marker");
    app.activePane().?.content.terminal.sendText("printf 'resumed:%s' \"$MY_SESSION_VALUE\"\r");
    try testWaitText(app, "resumed:kept");
    @import("session_controller.zig").closePaneById(app, app.activePane().?.id);
    const deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (app.mux.?.workspaces.items.len > 0) {
        if (io.nanoTimestamp() >= deadline) return error.Timeout;
        try testPump(app);
        try std.Io.sleep(io.get(), .fromMilliseconds(2), .awake);
    }
}

test "session pane domain spawn rejects GUI bindings and supports native Linux filters only" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    try cfg.setDomainEnv("guest", "HOLLOW_PANE_ID", "42");
    const remote: agent.Host = .{ .connector = .{ .argv = &.{"ssh"} } };
    try std.testing.expectError(error.InvalidSessionEnvironment, prepareSpawn(arena.allocator(), cfg, remote, "/bin/sh", null, "guest", null, .{}));
    var calls: usize = 0;
    if (builtin.os.tag == .linux) {
        const spawn = try prepareSpawn(arena.allocator(), cfg, .{}, "/bin/sh", null, null, null, .{ .context = &calls, .callback = filterProbe });
        try std.testing.expectEqual(@as(usize, 1), calls);
        try std.testing.expectEqualStrings("/filtered", spawn.cwd.?);
        try std.testing.expectEqualStrings("/bin/sh", spawn.argv[0]);
    } else {
        try std.testing.expectError(error.NativeSessionOwnerUnsupported, prepareSpawn(arena.allocator(), cfg, .{}, "/bin/sh", null, null, null, .{}));
    }
}

test "session borrowers persistent workspace admission never falls back without Lua" {
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();
    app.ghostty = try @import("../term/ghostty.zig").Runtime.init(a, null);
    app.mux = @import("../mux.zig").Mux.init(a);
    try app.config.setDomainPersist("persistent", true);
    try app.config.setDefaultDomain("persistent");
    @import("session_controller.zig").newWorkspace(app, null, null, null, null, -1);
    try std.testing.expectEqual(@as(usize, 0), app.mux.?.workspaces.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.session_open_count);
    try std.testing.expect(app.session_notices.current().?.state == .failed);
    try std.testing.expectEqual(@as(?anyerror, error.LuaUnavailable), app.session_notices.current().?.reason);
    try std.testing.expectError(error.PersistentDomainRequiresWorkspace, app.mux.?.createPane(&app.ghostty.?, @import("terminal_callbacks.zig").terminalCallbacks(), app.config, 8, 16, 640, 480, null, "persistent", null, null));
}

test "session borrowers stale queued session admission cannot reroute after config reload" {
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();
    try std.testing.expect(app.enqueueMouse(.{ .attach_session = .{ .session_id = try a.dupe(u8, "old-session"), .domain_name = try a.dupe(u8, "old-host"), .name = null, .callback_ref = -1, .lua_generation = 10 } }));
    @import("input.zig").processInputQueue(app);
    try std.testing.expectEqual(@as(usize, 0), app.session_open_count);
    try std.testing.expectEqual(@as(?anyerror, error.SessionConfigurationChanged), app.session_notices.current().?.reason);
}
