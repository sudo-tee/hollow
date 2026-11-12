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
    _ = open(app, null, inheritedDomain(app, domain_name), null, name, callback_ref, false, session_id) catch |err| {
        std.log.warn("persistent attachment admission failed: {s}", .{@errorName(err)});
        opens.reportAdmissionFailure(app, err, false);
        if (app.lua) |*lua| lua.invokeOperationCallback(callback_ref, false, .none);
        return;
    };
}

/// Explicit attach/list/kill target: the named domain, else the active pane's,
/// else the configured default. Borrowed from config or the pane.
pub fn inheritedDomain(app: *App, domain_name: ?[]const u8) ?[]const u8 {
    return domain_name orelse if (app.activePane()) |pane|
        (if (pane.domainName().len > 0) pane.domainName() else app.config.defaultDomainName())
    else
        app.config.defaultDomainName();
}

pub fn validSessionId(id: []const u8) bool {
    return id.len > 0 and id.len <= 128 and std.mem.indexOfScalar(u8, id, 0) == null;
}

pub const Resolved = struct {
    domain: []const u8,
    shell: []const u8,
    configured_shell: ?[]const u8,
    host: agent.Host,
    options: transport.Options,
};

/// Strict persistent host resolution. Everything is copied into `a`: host
/// resolution invokes Lua, which can synchronously update config, so no
/// domain/default-shell pointer is retained across that call.
pub fn resolve(app: *App, a: std.mem.Allocator, domain_name: ?[]const u8) !Resolved {
    const selected_domain = domain_name orelse app.config.defaultDomainName() orelse return error.UnknownDomain;
    if (!app.config.persistForDomain(selected_domain)) return error.PersistenceNotEnabled;
    const definition = app.config.domainByName(selected_domain) orelse return error.UnknownDomain;
    const domain = try a.dupe(u8, selected_domain);
    const configured_shell = if (definition.shell) |value| try a.dupe(u8, value) else null;
    const upgrade = definition.upgrade;
    const shell = configured_shell orelse try a.dupe(u8, app.config.shellOrDefault());
    const lua = if (app.lua) |*value| value else return error.LuaUnavailable;
    const host = try lua.sessionHost(a, domain, shell);
    if (host.error_message != null or host.fallback) return error.InvalidSessionHost;
    if (host.connector.argv.len == 0 and !nativeSupported()) return error.NativeSessionOwnerUnsupported;
    return .{
        .domain = domain,
        .shell = shell,
        .configured_shell = configured_shell,
        .host = host,
        .options = .{
            .connector = host.connector,
            .agent = host.agent,
            .ghostty_identity = @import("../term/ghostty.zig").buildIdentity(),
            .path_style = host.path_style,
            .wsl = host.wsl,
            .upgrade = if (upgrade == .handoff) null else @tagName(upgrade),
        },
    };
}

fn open(app: *App, cwd: ?[]const u8, domain_name: ?[]const u8, command: ?[]const u8, name: ?[]const u8, callback_ref: c_int, startup: bool, session_id: ?[]const u8) !u64 {
    if (session_id) |id| if (!validSessionId(id)) return error.InvalidSessionId;
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Copy the caller's cwd before resolution can reload config under it.
    const selected_domain = domain_name orelse app.config.defaultDomainName() orelse return error.UnknownDomain;
    var launch_cwd: ?[]const u8 = if (cwd orelse app.config.defaultCwdForDomain(selected_domain)) |value| try a.dupe(u8, value) else null;
    const resolved = try resolve(app, a, selected_domain);
    const domain = resolved.domain;
    const host = resolved.host;
    const shell = resolved.shell;
    const configured_shell = resolved.configured_shell;
    const mux = if (app.mux) |*value| value else return error.MuxUnavailable;
    if (launch_cwd == null and host.connector.argv.len == 0 and builtin.os.tag == .linux) {
        launch_cwd = @import("../io.zig").getEnvVarOwned(a, "HOME") catch null;
    }
    const options = resolved.options;
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

fn nativeSupported() bool {
    return builtin.os.tag == .linux or (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64);
}

fn reservedEnv(key: []const u8) bool {
    return std.mem.eql(u8, key, "HOLLOW_PANE_ID") or
        std.mem.eql(u8, key, "HOLLOW_WORKSPACE_ID") or
        std.mem.eql(u8, key, "HOLLOW_COMMAND_ADDR");
}

fn sessionReservedEnv(key: []const u8, native_windows: bool) bool {
    return if (native_windows)
        std.ascii.eqlIgnoreCase(key, "HOLLOW_PANE_ID") or
            std.ascii.eqlIgnoreCase(key, "HOLLOW_WORKSPACE_ID") or
            std.ascii.eqlIgnoreCase(key, "HOLLOW_COMMAND_ADDR")
    else
        reservedEnv(key);
}

/// Arena-owned output. Never place GUI IDs or a client-local command endpoint
/// in a process that outlives/reconnects to different GUIs. OSC is pane-bound.
pub fn prepareSpawn(a: std.mem.Allocator, cfg: Config, host: agent.Host, shell: []const u8, cwd: ?[]const u8, domain: ?[]const u8, command: ?[]const u8, filter: spec.Filter) !wire.Spawn {
    if (host.error_message != null or host.fallback) return error.InvalidSessionHost;
    const local = host.connector.argv.len == 0;
    if (local and host.connector.remote_shell) return error.InvalidSessionHost;
    if (local and !nativeSupported()) return error.NativeSessionOwnerUnsupported;
    const native_windows = local and builtin.os.tag == .windows;
    if (native_windows and spec.isWsl(shell)) return error.InvalidSessionHost;
    if (shell.len > 64 * 1024 or (cwd != null and cwd.?.len > 32 * 1024) or (command != null and command.?.len > 64 * 1024)) return error.ResourceExhausted;
    if (std.mem.indexOfScalar(u8, shell, 0) != null) return error.InvalidSessionHost;
    var block: std.ArrayList(u8) = .empty;
    try block.appendSlice(a, "TERM=xterm-256color\x00COLORTERM=truecolor\x00TERM_PROGRAM=ghostty\x00");
    const env = cfg.envForDomain(domain);
    if (env.len > 256) return error.ResourceExhausted;
    for (env) |pair| {
        if (sessionReservedEnv(pair.key, native_windows)) return error.InvalidSessionEnvironment;
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
        if (sessionReservedEnv(pair.key, native_windows)) return error.InvalidSessionEnvironment;
        value.* = pair;
    }
    values[filtered.len] = .{ .key = "HOLLOW_TRANSPORT", .value = "osc" };
    const argv = if (!local and spec.isWsl(shell)) try agent.wslInnerArgv(a, shell) else try agent.tokenize(a, shell);
    if (argv.len > 256) return error.ResourceExhausted;
    if (spawn_spec.cwd) |value| {
        if (value.len > 32 * 1024) return error.ResourceExhausted;
        if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidSessionCwd;
    }
    if (command) |value| if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidSessionCommand;
    return .{ .cols = cfg.cols, .rows = cfg.rows, .cwd = spawn_spec.cwd, .argv = argv, .env = values, .path_style = host.path_style };
}

fn filterProbe(context: *anyopaque, _: std.mem.Allocator, value: *spec.SpawnSpec) !void {
    const count: *usize = @ptrCast(@alignCast(context));
    count.* += 1;
    value.cwd = "/filtered";
    value.shell = "ignored-filter-shell";
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
    var host_id: []const u8 = undefined;
    var split_ratio: f32 = undefined;
    {
        const app = try testApp(a, connector.items, path);
        defer a.destroy(app);
        defer app.deinit();
        @import("session_controller.zig").newWorkspace(app, null, "persistent-test", "MY_SESSION_VALUE=kept; printf 'persisted-marker'", "persistent-check", -1);
        try testWaitText(app, "persisted-marker");
        @import("session_controller.zig").newTab(app, null, null, "TAB_VALUE=second; printf 'tab-marker'", -1, false);
        try testWaitText(app, "tab-marker");
        @import("session_controller.zig").splitPane(app, .vertical, 0.4, null, null, "SPLIT_VALUE=third; printf 'split-marker'", .send, false, false, false, null, null, null, null, -1, null, null);
        try testWaitText(app, "split-marker");
        const workspace = app.activeWorkspace().?;
        try std.testing.expectEqual(@as(usize, 2), workspace.tabs.items.len);
        try std.testing.expectEqual(@as(usize, 2), workspace.tabs.items[1].panes.items.len);
        split_ratio = workspace.tabs.items[1].root_split.?.ratio;
        const saved_deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
        while (workspace.session_controller.?.layout_request != null or workspace.session_controller.?.layout_dirty or app.session_spawn_count != 0) {
            if (io.nanoTimestamp() >= saved_deadline) return error.Timeout;
            try testPump(app);
            try std.Io.sleep(io.get(), .fromMilliseconds(2), .awake);
        }
        session_id = try temp.dupe(u8, app.activeWorkspace().?.session_controller.?.session_id);
        host_id = try temp.dupe(u8, app.activeWorkspace().?.session_controller.?.host);
        try std.testing.expectEqual(@as(usize, 32), host_id.len);
        try std.testing.expect(app.activePane().?.content.terminal.pty.?.isAlive());
    }
    const app = try testApp(a, connector.items, path);
    defer a.destroy(app);
    defer app.deinit();
    attach(app, session_id, "persistent-test", null, -1);
    try testWaitText(app, "split-marker");
    const restored = app.activeWorkspace().?;
    // A new connector to the same owner reports the same persisted host.
    try std.testing.expectEqualStrings(host_id, restored.session_controller.?.host);
    try std.testing.expectEqual(@as(usize, 2), restored.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 2), restored.tabs.items[1].panes.items.len);
    try std.testing.expectEqual(split_ratio, restored.tabs.items[1].root_split.?.ratio);
    app.activePane().?.content.terminal.sendText("printf 'split-resumed:%s' \"$SPLIT_VALUE\"\r");
    try testWaitText(app, "split-resumed:third");
    app.mux.?.switchTab(0);
    try testWaitText(app, "persisted-marker");
    app.activePane().?.content.terminal.sendText("printf 'resumed:%s' \"$MY_SESSION_VALUE\"\r");
    try testWaitText(app, "resumed:kept");
    app.mux.?.switchTab(1);
    restored.tabs.items[1].active_pane = restored.tabs.items[1].panes.items[0];
    app.activePane().?.content.terminal.sendText("printf 'tab-resumed:%s' \"$TAB_VALUE\"\r");
    try testWaitText(app, "tab-resumed:second");
    const queries = @import("session_query.zig");
    const listed = try queries.begin(app, .list, null, null, -1);
    const missing = try queries.begin(app, .kill, "no-such-session", "persistent-test", -1);
    const query_deadline = io.nanoTimestamp() + 10 * std.time.ns_per_s;
    while (app.session_queries[0].?.state == .running or app.session_queries[1].?.state == .running) {
        if (io.nanoTimestamp() >= query_deadline) return error.Timeout;
        try testPump(app);
        queries.pump(app);
        try std.Io.sleep(io.get(), .fromMilliseconds(2), .awake);
    }
    var list_response = try queries.fetch(app, listed);
    defer list_response.deinit(a);
    const list_result = list_response.payload.?.object.get("result").?.object;
    try std.testing.expectEqualStrings("persistent-test", list_result.get("domain").?.string);
    try std.testing.expectEqualStrings(host_id, list_result.get("host").?.string);
    var found = false;
    for (list_result.get("sessions").?.array.items) |entry| {
        if (!std.mem.eql(u8, entry.object.get("id").?.string, session_id)) continue;
        found = true;
        try std.testing.expect(entry.object.get("open").?.bool);
        try std.testing.expect(entry.object.get("attached").?.bool);
        try std.testing.expectEqualStrings("persistent-check", entry.object.get("name").?.string);
        try std.testing.expectEqual(@as(usize, 3), entry.object.get("panes").?.array.items.len);
    }
    try std.testing.expect(found);
    var kill_response = try queries.fetch(app, missing);
    defer kill_response.deinit(a);
    try std.testing.expectEqualStrings("failed", kill_response.payload.?.object.get("state").?.string);
    try std.testing.expectEqualStrings("rejected", kill_response.payload.?.object.get("result").?.object.get("outcome").?.string);
    @import("session_controller.zig").closeWorkspace(app, null);
    const deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (app.mux.?.workspaces.items.len > 0) {
        if (io.nanoTimestamp() >= deadline) return error.Timeout;
        try testPump(app);
        try std.Io.sleep(io.get(), .fromMilliseconds(2), .awake);
    }
}

const NativeAppFixture = if (builtin.os.tag == .windows) struct {
    const Self = @This();
    const io = @import("../io.zig");
    const owner = @import("../agent/session_windows.zig");
    const pipe = @import("../agent/session_pipe_windows.zig");
    const p = transport.p;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn GetProcessId(std.os.windows.HANDLE) callconv(.winapi) u32;
    extern "kernel32" fn WaitForSingleObject(std.os.windows.HANDLE, u32) callconv(.winapi) u32;

    namespace: []const u8,
    exe: []const u8,
    child: std.process.Child,
    guard: owner.Connection,
    pid: i64,

    fn init(temp: std.mem.Allocator) !Self {
        const namespace = try std.fmt.allocPrint(temp, "native-app-{d}-{d}", .{ GetCurrentProcessId(), io.nanoTimestamp() });
        const path = @import("session_test_options").native_owner;
        const exe = if (std.mem.startsWith(u8, path, "/")) blk: {
            const distro = try io.getEnvVarOwned(temp, "WSL_DISTRO_NAME");
            const result = try std.fmt.allocPrint(temp, "\\\\wsl.localhost\\{s}{s}", .{ distro, path });
            std.mem.replaceScalar(u8, result, '/', '\\');
            break :blk result;
        } else if (std.fs.path.isAbsolute(path)) path else try std.Io.Dir.cwd().realPathFileAlloc(io.get(), path, temp);
        var child = try std.process.spawn(io.get(), .{
            .argv = &.{ exe, "session", "serve", "--namespace", namespace },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
            .create_no_window = true,
        });
        errdefer child.kill(io.get());
        var endpoint = try pipe.Endpoint.init(std.testing.allocator, namespace);
        defer endpoint.deinit(std.testing.allocator);
        const deadline = io.nanoTimestamp() + 10 * std.time.ns_per_s;
        while (io.nanoTimestamp() < deadline) {
            const handle = endpoint.connect() catch |err| switch (err) {
                error.PipeBusy => null,
                else => return err,
            };
            if (handle) |h| {
                var guard = try owner.Connection.init(std.testing.allocator, h);
                errdefer guard.deinit();
                try guard.sendJson(.hello, p.Hello{ .protocol = p.protocol, .version = p.version, .ghostty = @import("../term/ghostty.zig").buildIdentity(), .client = "native-app-guard" });
                const frame = try guard.next(5000);
                try std.testing.expectEqual(p.Kind.welcome, frame.kind);
                const welcome = try p.parse(p.Welcome, std.testing.allocator, frame.payload);
                defer welcome.deinit();
                try std.testing.expect(welcome.value.owner_pid > 0);
                try std.testing.expectEqual(@as(i64, GetProcessId(child.id.?)), welcome.value.owner_pid);
                try std.testing.expect(p.validHost(welcome.value.host));
                return .{ .namespace = namespace, .exe = exe, .child = child, .guard = guard, .pid = welcome.value.owner_pid };
            }
            try std.Io.sleep(io.get(), .fromMilliseconds(10), .awake);
        }
        return error.FixtureStartupTimeout;
    }

    fn deinit(self: *Self) void {
        // Only this test's private namespace and exact owner child are touched.
        self.guard.sendJson(.request, p.Request{ .id = 999, .op = .kill_server }) catch {};
        self.guard.deinit();
        _ = WaitForSingleObject(self.child.id.?, 10_000);
        self.child.kill(io.get());
    }

    fn detachedSession(self: *Self, id: []const u8) !void {
        try std.testing.expectEqual(@as(u32, 258), WaitForSingleObject(self.child.id.?, 0));
        try std.testing.expectEqual(self.pid, @as(i64, GetProcessId(self.child.id.?)));
        const deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
        var request_id: u64 = 1;
        while (io.nanoTimestamp() < deadline) : (request_id += 1) {
            try self.guard.sendJson(.request, p.Request{ .id = request_id, .op = .list });
            const frame = try self.guard.next(5000);
            try std.testing.expectEqual(p.Kind.reply, frame.kind);
            const reply = try p.parse(p.Reply, std.testing.allocator, frame.payload);
            defer reply.deinit();
            try std.testing.expect(reply.value.ok);
            const sessions = reply.value.sessions orelse return error.MissingSessions;
            try std.testing.expectEqual(@as(usize, 1), sessions.len);
            try std.testing.expectEqualStrings(id, sessions[0].id);
            try std.testing.expectEqual(@as(usize, 3), sessions[0].panes.len);
            for (sessions[0].panes) |pane| try std.testing.expect(pane.exit == null);
            if (!sessions[0].attached) return;
            try std.Io.sleep(io.get(), .fromMilliseconds(2), .awake);
        }
        return error.DetachTimeout;
    }
} else struct {};

test "session borrowers native Windows full App detach and attach preserve three interactive panes" {
    if (comptime builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = @import("../io.zig");
    const controller = @import("session_controller.zig");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var fixture = try NativeAppFixture.init(temp);
    defer fixture.deinit();
    var session_id: []const u8 = undefined;
    var host_id: []const u8 = undefined;
    var split_ratio: f32 = undefined;
    {
        const app = try testApp(a, &.{}, fixture.exe);
        defer a.destroy(app);
        defer app.deinit();
        try app.config.setDomainShell("persistent-test", "powershell.exe -NoLogo -NoProfile");
        const resolved = try resolve(app, temp, "persistent-test");
        var options = resolved.options;
        // Private fixture routing is internal test input, never Lua/user config.
        options.namespace = fixture.namespace;
        const spawn = try prepareSpawn(temp, app.config, resolved.host, resolved.shell, null, resolved.domain, null, app.mux.?.spawn_filter);
        try std.testing.expect(spawn.command == null);
        _ = try opens.beginWithInput(app, options, .{ .id = 0, .op = .create, .spawn = spawn }, resolved.domain, "native-app-check", -1, "$global:MY_SESSION_VALUE='kept'; $global:MY_SESSION_PID=$PID; Write-Output ('native-'+'marker')");
        try testWaitText(app, "native-marker");
        controller.newTab(app, null, null, "$global:TAB_VALUE='second'; Write-Output ('tab-'+'marker')", -1, false);
        try testWaitText(app, "tab-marker");
        controller.splitPane(app, .vertical, 0.4, null, null, "$global:SPLIT_VALUE='third'; Write-Output ('split-'+'marker')", .send, false, false, false, null, null, null, null, -1, null, null);
        try testWaitText(app, "split-marker");
        const workspace = app.activeWorkspace().?;
        try std.testing.expectEqual(@as(usize, 2), workspace.tabs.items.len);
        try std.testing.expectEqual(@as(usize, 2), workspace.tabs.items[1].panes.items.len);
        split_ratio = workspace.tabs.items[1].root_split.?.ratio;
        const deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
        while (workspace.session_controller.?.layout_request != null or workspace.session_controller.?.layout_dirty or app.session_spawn_count != 0) {
            if (io.nanoTimestamp() >= deadline) return error.Timeout;
            try testPump(app);
            try std.Io.sleep(io.get(), .fromMilliseconds(2), .awake);
        }
        const session = workspace.session_controller.?;
        session_id = try temp.dupe(u8, session.session_id);
        host_id = try temp.dupe(u8, session.host);
        try std.testing.expectEqual(@as(usize, 32), host_id.len);
    }
    // The guard keeps this exact owner alive across destruction of every App.
    try fixture.detachedSession(session_id);
    const app = try testApp(a, &.{}, fixture.exe);
    defer a.destroy(app);
    defer app.deinit();
    try app.config.setDomainShell("persistent-test", "powershell.exe -NoLogo -NoProfile");
    const resolved = try resolve(app, temp, "persistent-test");
    var options = resolved.options;
    options.namespace = fixture.namespace;
    _ = try opens.beginWithInput(app, options, .{ .id = 0, .op = .attach, .session = session_id }, resolved.domain, null, -1, null);
    try testWaitText(app, "split-marker");
    const restored = app.activeWorkspace().?;
    try std.testing.expectEqualStrings(host_id, restored.session_controller.?.host);
    try std.testing.expectEqual(@as(usize, 2), restored.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 2), restored.tabs.items[1].panes.items.len);
    try std.testing.expectEqual(split_ratio, restored.tabs.items[1].root_split.?.ratio);
    app.activePane().?.content.terminal.sendText("Write-Output ('split-resumed:'+$global:SPLIT_VALUE)\r");
    try testWaitText(app, "split-resumed:third");
    app.mux.?.switchTab(0);
    try testWaitText(app, "native-marker");
    app.activePane().?.content.terminal.sendText("Write-Output ('resumed:'+$global:MY_SESSION_VALUE+':'+($global:MY_SESSION_PID -eq $PID))\r");
    try testWaitText(app, "resumed:kept:True");
    app.mux.?.switchTab(1);
    restored.tabs.items[1].active_pane = restored.tabs.items[1].panes.items[0];
    app.activePane().?.content.terminal.sendText("Write-Output ('tab-resumed:'+$global:TAB_VALUE)\r");
    try testWaitText(app, "tab-resumed:second");
    try std.testing.expectEqual(@as(u32, 258), NativeAppFixture.WaitForSingleObject(fixture.child.id.?, 0));
    try std.testing.expectEqual(fixture.pid, @as(i64, NativeAppFixture.GetProcessId(fixture.child.id.?)));
}

test "session pane domain spawn rejects GUI bindings and supports native filters only" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    try cfg.setDomainEnv("guest", "HOLLOW_PANE_ID", "42");
    const remote: agent.Host = .{ .connector = .{ .argv = &.{"ssh"} } };
    try std.testing.expectError(error.InvalidSessionEnvironment, prepareSpawn(arena.allocator(), cfg, remote, "/bin/sh", null, "guest", null, .{}));
    var calls: usize = 0;
    if (nativeSupported()) {
        const spawn = try prepareSpawn(arena.allocator(), cfg, .{}, "/bin/sh", null, null, null, .{ .context = &calls, .callback = filterProbe });
        try std.testing.expectEqual(@as(usize, 1), calls);
        try std.testing.expectEqualStrings("/filtered", spawn.cwd.?);
        try std.testing.expectEqualStrings("/bin/sh", spawn.argv[0]);
    } else {
        try std.testing.expectError(error.NativeSessionOwnerUnsupported, prepareSpawn(arena.allocator(), cfg, .{}, "/bin/sh", null, null, null, .{}));
    }
}

test "session borrowers native Windows spawn preserves literal shell and rejects forged GUI environment" {
    if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    const shell = "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" -NoLogo -WorkingDirectory \"C:\\work space\"";
    var calls: usize = 0;
    const spawn = try prepareSpawn(arena.allocator(), cfg, .{}, shell, "C:\\work space", null, "Write-Output queued", .{ .context = &calls, .callback = filterProbe });
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqualStrings("/filtered", spawn.cwd.?);
    const expected = [_][]const u8{ "C:\\Program Files\\PowerShell\\7\\pwsh.exe", "-NoLogo", "-WorkingDirectory", "C:\\work space" };
    try std.testing.expectEqual(expected.len, spawn.argv.len);
    for (expected, spawn.argv) |want, actual| try std.testing.expectEqualStrings(want, actual);
    try std.testing.expect(spawn.command == null);
    try std.testing.expectEqualStrings("osc", spawn.env[spawn.env.len - 1].value);
    const default_cwd = try prepareSpawn(arena.allocator(), cfg, .{}, shell, null, null, null, .{});
    try std.testing.expect(default_cwd.cwd == null);
    for ([_][]const u8{ "wsl.exe", "\"C:\\Windows\\System32\\WSL.EXE\" -d Ubuntu", "pwsh.exe\x00bad" }) |invalid| {
        try std.testing.expectError(error.InvalidSessionHost, prepareSpawn(arena.allocator(), cfg, .{}, invalid, null, null, null, .{}));
    }
    for ([_][]const u8{ "Hollow_Pane_Id", "hollow_WORKSPACE_id", "hOlLoW_Command_ADDR" }) |key| {
        var bad = Config.init(a);
        defer bad.deinit();
        try bad.setDomainEnv("native", key, "forged");
        try std.testing.expectError(error.InvalidSessionEnvironment, prepareSpawn(arena.allocator(), bad, .{}, shell, null, "native", null, .{}));
        const remote: agent.Host = .{ .connector = .{ .argv = &.{"ssh"} } };
        _ = try prepareSpawn(arena.allocator(), bad, remote, "/bin/sh", null, "native", null, .{});
    }
    const ForgedFilter = struct {
        fn apply(_: *anyopaque, _: std.mem.Allocator, value: *spec.SpawnSpec) !void {
            value.env_block = "hollow_PANE_id=42\x00\x00";
        }
    };
    try std.testing.expectError(error.InvalidSessionEnvironment, prepareSpawn(arena.allocator(), cfg, .{}, shell, null, null, null, .{ .context = &calls, .callback = ForgedFilter.apply }));
    try std.testing.expectError(error.InvalidSessionHost, prepareSpawn(arena.allocator(), cfg, .{ .fallback = true }, shell, null, null, null, .{}));
    try std.testing.expectError(error.InvalidSessionHost, prepareSpawn(arena.allocator(), cfg, .{ .error_message = "unresolved" }, shell, null, null, null, .{}));
}

test "session borrowers resolves explicit native Windows Lua domain without opening an owner" {
    if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();
    try app.config.setDomainPersist("native", true);
    try app.config.setDomainShell("native", "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" -NoLogo");
    app.lua = try @import("../lua_bridge.zig").Runtime.initForTests(a, &app.config);
    try app.lua.?.runString(
        \\hollow = {platform={is_windows=true}, config={get=function(key)
        \\  if key == 'domains' then return {native={host={type='local',agent_path='C:\\Hollow\\hollow-agent.exe'}}} end
        \\end}}
        \\require('hollow.host.pty').setup(hollow)
    );
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const resolved = try resolve(app, arena.allocator(), "native");
    try std.testing.expectEqual(@as(usize, 0), resolved.options.connector.argv.len);
    try std.testing.expect(!resolved.options.connector.remote_shell);
    try std.testing.expectEqualStrings("C:\\Hollow\\hollow-agent.exe", resolved.options.agent.path.?);
    try std.testing.expect(!resolved.host.fallback);
    try std.testing.expectEqual(@as(usize, 0), app.session_open_count);
    try app.config.setDomainShell("native", "pwsh.exe\x00bad");
    try std.testing.expectError(error.InvalidSessionHost, resolve(app, arena.allocator(), "native"));
    try app.config.setDomainShell("native", "pwsh.exe");
    try app.lua.?.runString(
        \\hollow.config.get = function(key)
        \\  if key == 'domains' then return {native={host={type='local',agent_path='C:\\bad\0agent.exe'}}} end
        \\end
    );
    try std.testing.expectError(error.InvalidSessionHost, resolve(app, arena.allocator(), "native"));
    try std.testing.expectEqual(@as(usize, 0), app.session_open_count);
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
