//! Wire format for `hollow-agent session` v1 (see docs/persistent-sessions.md).
//! Reuses the dedicated PTY nine-byte envelope with session-specific kinds and
//! its own hello. Stream 0 carries JSON control; other streams are pane IDs
//! carrying binary data.
const std = @import("std");
pub const pty = @import("pty_protocol.zig");
pub const Header = pty.Header;
pub const Reader = pty.Reader;
pub const Spawn = pty.Spawn;
pub const header_len = pty.header_len;

pub const protocol = "hollow-session";
/// Protocol major version. Part of the endpoint name, so owners of different
/// majors coexist and old owners stay reachable.
pub const version = 1;
pub const socket_name = "session-v1.sock";
pub const lock_name = "session-v1.lock";

pub const max_data = 16 * 1024;
pub const control_limit = 512 * 1024;
/// Per-pane output credit, as in mux.
pub const window = 64 * 1024;
/// Unsent output per pane beyond which the owner drops the backlog and
/// resyncs the client with a fresh snapshot.
pub const resync_limit = 4 * 1024 * 1024;

pub const Kind = enum(u8) {
    // client -> owner
    hello = 1,
    request = 2,
    input = 3,
    resize = 4,
    credit = 5,
    // owner -> client
    welcome = 16,
    reply = 17,
    event = 18,
    output = 19,
    snapshot = 20,
    snapshot_end = 21,
    exit = 22,
};

pub const Direction = enum { to_owner, to_client };

pub fn header(kind: Kind, stream: u32, len: usize) Header {
    return .{ .kind = @fromBackingInt(@backingInt(kind)), .stream = stream, .len = @intCast(len) };
}

/// Validates kind, direction, stream, and size from the header alone, before
/// the payload is buffered.
pub fn validate(h: Header, direction: Direction) !Kind {
    const kind = std.enums.fromInt(Kind, @backingInt(h.kind)) orelse return error.InvalidKind;
    const to_owner = @backingInt(kind) < @backingInt(Kind.welcome);
    if (to_owner != (direction == .to_owner)) return error.InvalidKind;
    const control, const limit: u32 = switch (kind) {
        .hello, .request, .welcome, .reply, .event => .{ true, control_limit },
        .input, .output, .snapshot => .{ false, max_data },
        .resize, .credit, .exit => .{ false, 4 },
        .snapshot_end => .{ false, 0 },
    };
    if (h.len > limit) return error.PayloadTooLarge;
    if (control != (h.stream == 0)) return error.InvalidStream;
    return kind;
}

/// Client hello. `ghostty` is the client's ghostty build identity; the binary
/// snapshot format is only used when it matches the owner's exactly.
pub const Hello = struct {
    protocol: []const u8,
    version: u32,
    ghostty: []const u8,
    client: []const u8 = "",
    /// Client understands the pane-bound HTP foreground sync after snapshots.
    foreground_events: bool = false,
    /// Connector-only preflight, before any application request. New owners
    /// allow a normal GUI hello on this same connection after the probe.
    owner_probe: bool = false,
    owner_build: []const u8 = "",
    /// WSL lifetime holder requests an atomic empty-only guest drain.
    owner_drain: bool = false,
    /// Probe only: the connector's own executable, its handoff payload
    /// format, and its ghostty identity. A POSIX owner with live sessions
    /// may exec this build in place instead of waiting until it is empty.
    handoff_path: []const u8 = "",
    handoff_format: u32 = 0,
    handoff_ghostty: []const u8 = "",
};

pub const SnapshotFormat = enum { binary, vt };

pub const Welcome = struct {
    protocol: []const u8 = protocol,
    version: u32 = version,
    ghostty: []const u8,
    snapshot: SnapshotFormat,
    owner_pid: i64,
    /// Stable identity of this owner's state (user + machine), persisted in
    /// its state dir. Empty from owners that predate it.
    host: []const u8 = "",
    /// Optional ops this owner understands, e.g. "respawn". An owner closes
    /// the connection on an unknown op, so clients send these only when
    /// advertised.
    features: []const []const u8 = &.{},
    owner_build: []const u8 = "",
    retiring: bool = false,
    /// Sent for `handoff_notice_ms` after an in-place handoff, so the GUI that
    /// triggered it can tell the user. Absent from older owners.
    handoff: ?HandoffNotice = null,
};

/// `from` and `to` are owner builds; when `ok` is false, `from` kept serving.
pub const HandoffNotice = struct { from: []const u8, to: []const u8, ok: bool };
pub const handoff_notice_ms = 10_000;

pub const owner_features = [_][]const u8{ "respawn", "create-id", "retire-empty", "drain-empty" };
pub const windows_owner_features = owner_features ++ [_][]const u8{"wsl-keepalive"};
pub const posix_owner_features = owner_features ++ [_][]const u8{"exec-handoff"};

test "WSL keepalive validates bounded identities and cannot redirect production state" {
    const valid: WslHold = .{ .distro = "Guest & Distro", .user = "alice", .agent = "/opt/agent" };
    try valid.validate(false);
    for ([_][]const u8{ "", "-guest", "guest\x00bad" }) |name| {
        var bad = valid;
        bad.distro = name;
        try std.testing.expectError(error.InvalidArgument, bad.validate(false));
    }
    var bad = valid;
    bad.launcher = "relative/wsl.exe";
    try std.testing.expectError(error.InvalidArgument, bad.validate(false));
    bad = valid;
    bad.session_dir = "/private/fixture";
    try std.testing.expectError(error.InvalidArgument, bad.validate(false));
    try bad.validate(true);
    try std.testing.expect(valid.matchesConnector(&.{ "wsl.exe", "--distribution", valid.distro, "--user", "alice", "--cd", "/", "--exec" }, false));
    try std.testing.expect(!valid.matchesConnector(&.{ "wsl.exe", "--distribution", "other", "--user", "alice", "--cd", "/", "--exec" }, false));
    try std.testing.expect(!valid.matchesConnector(&.{ "wsl.exe", "--distribution", valid.distro, "--user", "alice", "--cd", "/", "--exec" }, true));
}

/// Windows-local mechanism, never forwarded to a Linux owner.
pub const WslHold = struct {
    distro: []const u8,
    user: ?[]const u8 = null,
    launcher: []const u8 = "wsl.exe",
    agent: []const u8,
    /// Private fixtures only; production admission rejects overrides.
    session_dir: ?[]const u8 = null,

    /// The caller supplies an arena; partial copies roll back with that arena.
    pub fn dupe(self: WslHold, a: std.mem.Allocator) !WslHold {
        return .{
            .distro = try a.dupe(u8, self.distro),
            .user = if (self.user) |value| try a.dupe(u8, value) else null,
            .launcher = try a.dupe(u8, self.launcher),
            .agent = try a.dupe(u8, self.agent),
            .session_dir = if (self.session_dir) |value| try a.dupe(u8, value) else null,
        };
    }

    pub fn matchesConnector(self: WslHold, argv: []const []const u8, remote_shell: bool) bool {
        if (remote_shell or argv.len != @as(usize, if (self.user != null) 8 else 6)) return false;
        if (!std.mem.eql(u8, argv[0], self.launcher) or !std.mem.eql(u8, argv[1], "--distribution") or !std.mem.eql(u8, argv[2], self.distro)) return false;
        const offset: usize = if (self.user) |user| blk: {
            if (!std.mem.eql(u8, argv[3], "--user") or !std.mem.eql(u8, argv[4], user)) return false;
            break :blk 5;
        } else 3;
        return std.mem.eql(u8, argv[offset], "--cd") and std.mem.eql(u8, argv[offset + 1], "/") and std.mem.eql(u8, argv[offset + 2], "--exec");
    }

    pub fn validate(self: WslHold, fixture: bool) !void {
        if (!name(self.distro)) return error.InvalidArgument;
        if (self.user) |user| if (!name(user)) return error.InvalidArgument;
        if (self.agent.len == 0 or self.agent.len > 4096 or self.agent[0] != '/' or std.mem.indexOfScalar(u8, self.agent, 0) != null) return error.InvalidArgument;
        if (self.session_dir) |dir| {
            if (!fixture or dir.len == 0 or dir.len > 4096 or dir[0] != '/' or std.mem.indexOfScalar(u8, dir, 0) != null) return error.InvalidArgument;
        }
        const path = self.launcher;
        const absolute = (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\')) or std.mem.startsWith(u8, path, "\\\\");
        if (path.len == 0 or path.len > 32 * 1024 or std.mem.indexOfScalar(u8, path, 0) != null or
            (!std.ascii.eqlIgnoreCase(path, "wsl.exe") and !absolute)) return error.InvalidArgument;
    }

    fn name(value: []const u8) bool {
        return value.len > 0 and value.len <= 256 and value[0] != '-' and std.mem.indexOfScalar(u8, value, 0) == null;
    }
};

pub fn validCreateId(id: []const u8) bool {
    if (id.len != 32) return false;
    for (id) |byte| if (!(byte >= '0' and byte <= '9') and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

test "reserved create IDs are fixed lowercase hexadecimal tokens" {
    try std.testing.expect(validCreateId("0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!validCreateId(""));
    try std.testing.expect(!validCreateId("0123456789ABCDEF0123456789ABCDEF"));
    try std.testing.expect(!validCreateId("/123456789abcdef0123456789abcdef"));
    try std.testing.expect(!validCreateId("0123456789abcdef0123456789abcdef0"));
}

pub fn hasFeature(features: []const []const u8, name: []const u8) bool {
    for (features) |feature| if (std.mem.eql(u8, feature, name)) return true;
    return false;
}

pub const max_host_len = 64;

/// Host IDs are opaque ASCII tokens, so they are safe to log and store.
pub fn validHost(host: []const u8) bool {
    if (host.len == 0 or host.len > max_host_len) return false;
    for (host) |byte| switch (byte) {
        '0'...'9', 'a'...'z', 'A'...'Z', '-', '_' => {},
        else => return false,
    };
    return true;
}

pub const Op = enum {
    /// List sessions.
    list,
    /// Create a session with one pane from `spawn`, then attach to it.
    create,
    /// Attach to `session` (take over from any attached client). `panes`
    /// carries the client's pane sizes.
    attach,
    detach,
    /// Kill `session` and all its panes.
    kill,
    /// Add a pane from `spawn` to the attached session.
    spawn,
    /// Kill `pane` in the attached session.
    close,
    /// Replace the attached session's layout blob if `revision` matches.
    layout,
    /// Kill every session and stop the owner.
    kill_server,
    /// Restart exited `pane` in the attached session from its original spawn,
    /// keeping its screen. Requires the "respawn" feature.
    respawn,
    /// Pin an explicitly resolved WSL host in the native Windows owner.
    /// Requires "wsl-keepalive". The pin lasts until this client disconnects.
    hold_wsl,
};

pub const PaneSize = struct { pane: u32, cols: u16, rows: u16 };

pub const Request = struct {
    id: u64,
    op: Op,
    session: ?[]const u8 = null,
    /// Optional client-reserved create identity. Requires "create-id".
    /// A collision rejects create; it never attaches or replays a spawn.
    create_id: ?[]const u8 = null,
    pane: ?u32 = null,
    spawn: ?Spawn = null,
    panes: []const PaneSize = &.{},
    revision: ?u64 = null,
    /// Opaque, GUI-defined layout blob.
    layout: ?[]const u8 = null,
    wsl: ?WslHold = null,
};

pub const PaneInfo = struct {
    id: u32,
    cols: u16,
    rows: u16,
    title: []const u8 = "",
    cwd: []const u8 = "",
    /// Shell-reported command at attachment time; absent on older owners.
    foreground_process: []const u8 = "",
    /// Encoded exit status (see `encodeExit`) once the process has exited.
    exit: ?i32 = null,
    /// Interactive shells close on exit; commands/apps normally retain output.
    /// Absent on older owners, which retain every exited pane.
    close_on_exit: bool = false,
};

pub const SessionInfo = struct {
    id: []const u8,
    attached: bool,
    revision: u64,
    layout: []const u8 = "",
    panes: []const PaneInfo = &.{},
};

/// Answer to a `Request` with the same `id`. Fields other than `id`, `ok`
/// and `error` are present only for the ops that return them.
pub const Reply = struct {
    id: u64,
    ok: bool = true,
    @"error": ?[]const u8 = null,
    session: ?SessionInfo = null,
    sessions: ?[]const SessionInfo = null,
    pane: ?u32 = null,
    revision: ?u64 = null,
};

pub fn stringify(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{ .emit_null_optional_fields = false });
}

pub const EventKind = enum {
    /// Another client attached; this client is detached.
    taken,
    /// The session ended (last pane closed or killed).
    session_end,
    /// The owner dropped this pane's backlog; a fresh snapshot follows.
    resync,
};

pub const Event = struct {
    event: EventKind,
    session: []const u8,
    pane: ?u32 = null,
};

/// Exit status as one i32: >= 0 is an exit code, < 0 is a negated signal.
pub fn encodeExit(status: i32) [4]u8 {
    var out: [4]u8 = undefined;
    std.mem.writeInt(i32, &out, status, .little);
    return out;
}

pub fn decodeExit(payload: []const u8) !i32 {
    if (payload.len != 4) return error.InvalidExit;
    return std.mem.readInt(i32, payload[0..4], .little);
}

pub fn decodeCredit(payload: []const u8) !u32 {
    if (payload.len != 4) return error.InvalidCredit;
    const value = std.mem.readInt(u32, payload[0..4], .little);
    if (value == 0 or value > window) return error.InvalidCredit;
    return value;
}

pub const encodeResize = pty.encodeResize;
pub const decodeResize = pty.decodeResize;

pub fn parse(comptime T: type, allocator: std.mem.Allocator, payload: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, payload, .{ .ignore_unknown_fields = true, .max_value_len = control_limit });
}

test "validate enforces direction, stream, and limits from the header" {
    try std.testing.expectEqual(Kind.hello, try validate(header(.hello, 0, 100), .to_owner));
    try std.testing.expectEqual(Kind.output, try validate(header(.output, 3, max_data), .to_client));
    try std.testing.expectError(error.InvalidKind, validate(header(.output, 3, 1), .to_owner));
    try std.testing.expectError(error.InvalidKind, validate(header(.request, 0, 1), .to_client));
    try std.testing.expectError(error.InvalidStream, validate(header(.request, 1, 1), .to_owner));
    try std.testing.expectError(error.InvalidStream, validate(header(.input, 0, 1), .to_owner));
    try std.testing.expectError(error.PayloadTooLarge, validate(header(.input, 1, max_data + 1), .to_owner));
    try std.testing.expectError(error.PayloadTooLarge, validate(header(.snapshot_end, 1, 1), .to_client));
    try std.testing.expectError(error.InvalidKind, validate(.{ .kind = @fromBackingInt(99), .len = 0 }, .to_owner));
}

test "session frames split through the shared reader" {
    const a = std.testing.allocator;
    var reader: Reader = .{};
    defer reader.deinit(a);
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(a);
    try wire.appendSlice(a, &header(.exit, 7, 4).encode());
    try wire.appendSlice(a, &encodeExit(-9));
    try wire.appendSlice(a, &header(.snapshot_end, 7, 0).encode());
    for (wire.items) |byte| try reader.push(a, &.{byte});
    const first = (try reader.next()).?;
    try std.testing.expectEqual(Kind.exit, try validate(first.header, .to_client));
    try std.testing.expectEqual(@as(u32, 7), first.header.stream);
    try std.testing.expectEqual(@as(i32, -9), try decodeExit(first.payload));
    const second = (try reader.next()).?;
    try std.testing.expectEqual(Kind.snapshot_end, try validate(second.header, .to_client));
    try std.testing.expect((try reader.next()) == null);
}

test "control JSON parses with defaults and ignores unknown fields" {
    const a = std.testing.allocator;
    const hello = try parse(Hello, a, "{\"protocol\":\"hollow-session\",\"version\":1,\"ghostty\":\"1.4.1\",\"future\":true}");
    defer hello.deinit();
    try std.testing.expectEqualStrings("1.4.1", hello.value.ghostty);
    const request = try parse(Request, a, "{\"id\":3,\"op\":\"attach\",\"session\":\"ab\",\"panes\":[{\"pane\":1,\"cols\":80,\"rows\":24}]}");
    defer request.deinit();
    try std.testing.expectEqual(Op.attach, request.value.op);
    try std.testing.expectEqual(@as(u16, 80), request.value.panes[0].cols);
    try std.testing.expect(request.value.spawn == null);
    const create = try parse(Request, a, "{\"id\":4,\"op\":\"create\",\"spawn\":{\"cols\":120}}");
    defer create.deinit();
    try std.testing.expectEqual(@as(u16, 120), create.value.spawn.?.cols);
    try std.testing.expectError(error.InvalidEnumTag, parse(Request, a, "{\"id\":5,\"op\":\"nope\"}"));
}

test "host ids are bounded opaque tokens and optional in welcome" {
    try std.testing.expect(validHost("0123abcdef-_Z"));
    try std.testing.expect(!validHost(""));
    try std.testing.expect(!validHost("a b"));
    try std.testing.expect(!validHost("a\x00"));
    try std.testing.expect(!validHost(&(@as([max_host_len + 1]u8, @splat('x')))));
    const old = try parse(Welcome, std.testing.allocator, "{\"ghostty\":\"g\",\"snapshot\":\"vt\",\"owner_pid\":1}");
    defer old.deinit();
    try std.testing.expectEqualStrings("", old.value.host);
}

test "credit rejects zero and oversized grants" {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, window, .little);
    try std.testing.expectEqual(@as(u32, window), try decodeCredit(&bytes));
    std.mem.writeInt(u32, &bytes, 0, .little);
    try std.testing.expectError(error.InvalidCredit, decodeCredit(&bytes));
    std.mem.writeInt(u32, &bytes, window + 1, .little);
    try std.testing.expectError(error.InvalidCredit, decodeCredit(&bytes));
}
