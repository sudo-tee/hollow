//! Headless ghostty terminal for one session pane. The owner feeds every PTY
//! byte through it, answers terminal queries from it, and encodes attach
//! snapshots from it.
const std = @import("std");
const g = @import("ghostty_c");

pub const reply_limit = 4 * 1024 * 1024;
pub const snapshot_limit = 64 * 1024 * 1024;

pub const Vt = struct {
    allocator: std.mem.Allocator,
    terminal: g.GhosttyTerminal,
    /// Query responses (DA, DSR, ...) waiting to be written to the PTY.
    replies: std.ArrayList(u8) = .empty,
    reply_failed: bool = false,
    shell_command: @import("session_command.zig").Command = .{},

    /// Largest unfinished escape sequence a snapshot can carry.
    pub const continuation_max = 64 * 1024;

    /// The result has a stable address; the terminal's callbacks point at it.
    pub fn create(allocator: std.mem.Allocator, cols: u16, rows: u16, scrollback_bytes: usize) !*Vt {
        const self = try allocator.create(Vt);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .terminal = null };
        try check(g.ghostty_terminal_new(null, &self.terminal, cols, rows));
        errdefer g.ghostty_terminal_free(self.terminal);
        try self.setValue(g.GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, usize, continuation_max);
        try self.setValue(g.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, usize, scrollback_bytes);
        try check(g.ghostty_terminal_set(self.terminal, opt(g.GHOSTTY_TERMINAL_OPT_USERDATA), self));
        try check(g.ghostty_terminal_set(self.terminal, opt(g.GHOSTTY_TERMINAL_OPT_WRITE_PTY), @ptrCast(&writePty)));
        return self;
    }

    /// Rebuilds a pane terminal from an owner handoff: a binary snapshot
    /// from the same ghostty build, else a `formatVt` replay.
    pub fn adopt(allocator: std.mem.Allocator, bytes: []const u8, binary: bool, cols: u16, rows: u16, scrollback_bytes: usize) !*Vt {
        if (!binary) {
            const self = try create(allocator, cols, rows, scrollback_bytes);
            self.write(bytes);
            var replies = self.takeReplies();
            replies.deinit(allocator);
            return self;
        }
        const self = try allocator.create(Vt);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .terminal = try restore(bytes, scrollback_bytes) };
        errdefer g.ghostty_terminal_free(self.terminal);
        try self.setValue(g.GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, usize, continuation_max);
        try check(g.ghostty_terminal_set(self.terminal, opt(g.GHOSTTY_TERMINAL_OPT_USERDATA), self));
        try check(g.ghostty_terminal_set(self.terminal, opt(g.GHOSTTY_TERMINAL_OPT_WRITE_PTY), @ptrCast(&writePty)));
        return self;
    }

    pub fn destroy(self: *Vt) void {
        g.ghostty_terminal_free(self.terminal);
        self.replies.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn setValue(self: *Vt, option: c_int, comptime T: type, value: T) !void {
        const copy = value;
        try check(g.ghostty_terminal_set(self.terminal, opt(option), &copy));
    }

    fn writePty(_: g.GhosttyTerminal, userdata: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
        const self: *Vt = @ptrCast(@alignCast(userdata orelse return));
        if (self.replies.items.len > reply_limit or len > reply_limit - self.replies.items.len) {
            self.reply_failed = true;
            return;
        }
        self.replies.appendSlice(self.allocator, data[0..len]) catch {
            self.reply_failed = true;
        };
    }

    pub fn write(self: *Vt, bytes: []const u8) void {
        self.shell_command.feed(self.allocator, bytes);
        g.ghostty_terminal_vt_write(self.terminal, bytes.ptr, bytes.len);
    }

    pub fn resize(self: *Vt, cols: u16, rows: u16) !void {
        try check(g.ghostty_terminal_resize(self.terminal, cols, rows, 0, 0));
    }

    /// Takes the pending query responses; the caller writes them to the PTY.
    pub fn takeReplies(self: *Vt) std.ArrayList(u8) {
        const out = self.replies;
        self.replies = .empty;
        self.reply_failed = false;
        return out;
    }

    pub fn size(self: *Vt) !struct { cols: u16, rows: u16 } {
        var cols: u16 = 0;
        var rows: u16 = 0;
        try check(g.ghostty_terminal_get(self.terminal, dataKey(g.GHOSTTY_TERMINAL_DATA_COLS), &cols));
        try check(g.ghostty_terminal_get(self.terminal, dataKey(g.GHOSTTY_TERMINAL_DATA_ROWS), &rows));
        return .{ .cols = cols, .rows = rows };
    }

    /// Copies a string property (title, pwd) into `allocator` memory.
    fn string(self: *Vt, allocator: std.mem.Allocator, key: c_int) ![]u8 {
        var value: g.GhosttyString = .{ .ptr = null, .len = 0 };
        try check(g.ghostty_terminal_get(self.terminal, dataKey(key), &value));
        if (value.len == 0) return allocator.dupe(u8, "");
        return allocator.dupe(u8, value.ptr[0..value.len]);
    }

    pub fn title(self: *Vt, allocator: std.mem.Allocator) ![]u8 {
        return self.string(allocator, g.GHOSTTY_TERMINAL_DATA_TITLE);
    }

    pub fn pwd(self: *Vt, allocator: std.mem.Allocator) ![]u8 {
        return self.string(allocator, g.GHOSTTY_TERMINAL_DATA_PWD);
    }

    /// Binary snapshot appended to `out`. Callers must not feed the terminal
    /// concurrently.
    pub fn snapshot(self: *Vt, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        var sink: Sink = .{ .allocator = allocator, .out = out };
        const writer: g.GhosttyWriter = .{ .write = Sink.write, .userdata = &sink };
        check(g.ghostty_snapshot_encode(self.terminal, writer)) catch |err| {
            return sink.failure orelse err;
        };
    }

    /// VT formatter fallback for clients with a different ghostty build:
    /// active screen and scrollback with styles, modes, and cursor.
    pub fn formatVt(self: *Vt, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        var screen_extra = std.mem.zeroes(g.GhosttyFormatterScreenExtra);
        screen_extra.size = @sizeOf(g.GhosttyFormatterScreenExtra);
        screen_extra.cursor = true;
        screen_extra.style = true;
        screen_extra.hyperlink = true;
        screen_extra.protection = true;
        screen_extra.kitty_keyboard = true;
        screen_extra.charsets = true;
        var extra = std.mem.zeroes(g.GhosttyFormatterTerminalExtra);
        extra.size = @sizeOf(g.GhosttyFormatterTerminalExtra);
        extra.palette = true;
        extra.modes = true;
        extra.scrolling_region = true;
        extra.tabstops = true;
        extra.pwd = true;
        extra.keyboard = true;
        extra.screen = screen_extra;
        var options = std.mem.zeroes(g.GhosttyFormatterTerminalOptions);
        options.size = @sizeOf(g.GhosttyFormatterTerminalOptions);
        options.emit = @intCast(g.GHOSTTY_FORMATTER_FORMAT_VT);
        options.extra = extra;
        var formatter: g.GhosttyFormatter = null;
        try check(g.ghostty_formatter_terminal_new(null, &formatter, self.terminal, options));
        defer g.ghostty_formatter_free(formatter);
        var sink: Sink = .{ .allocator = allocator, .out = out };
        const writer: g.GhosttyWriter = .{ .write = Sink.write, .userdata = &sink };
        check(g.ghostty_formatter_format(formatter, writer)) catch |err| {
            return sink.failure orelse err;
        };
    }
};

const Sink = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    limit: usize = snapshot_limit,
    failure: ?anyerror = null,

    fn write(userdata: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) bool {
        const self: *Sink = @ptrCast(@alignCast(userdata.?));
        if (self.out.items.len > self.limit or len > self.limit - self.out.items.len) {
            self.failure = error.ResourceExhausted;
            return false;
        }
        self.out.appendSlice(self.allocator, data[0..len]) catch {
            self.failure = error.OutOfMemory;
            return false;
        };
        return true;
    }
};

test "query replies and encoded snapshot sink reject overflow before append" {
    const a = std.testing.allocator;
    const vt = try Vt.create(a, 40, 6, 4096);
    defer vt.destroy();
    try vt.replies.resize(a, reply_limit);
    Vt.writePty(vt.terminal, vt, "x", 1);
    try std.testing.expect(vt.reply_failed);
    try std.testing.expectEqual(reply_limit, vt.replies.items.len);
    var replies = vt.takeReplies();
    defer replies.deinit(a);
    try std.testing.expect(!vt.reply_failed);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    var sink: Sink = .{ .allocator = a, .out = &bytes, .limit = 3 };
    try std.testing.expect(Sink.write(&sink, "ab", 2));
    try std.testing.expect(!Sink.write(&sink, "cd", 2));
    try std.testing.expectEqual(error.ResourceExhausted, sink.failure.?);
    try std.testing.expectEqualStrings("ab", bytes.items);
}

/// The ghostty build identity sent in the session hello: the pinned package
/// hash from build.zig.zon. Binary snapshots are only exchanged between
/// identical identities.
pub fn buildIdentity() []const u8 {
    return @import("session_build").ghostty_identity;
}

fn opt(value: c_int) g.GhosttyTerminalOption {
    return @intCast(value);
}

fn dataKey(value: c_int) g.GhosttyTerminalData {
    return @intCast(value);
}

fn check(result: anytype) !void {
    if (result != g.GHOSTTY_SUCCESS) return error.GhosttyFailed;
}

pub fn freeTerminal(terminal: g.GhosttyTerminal) void {
    g.ghostty_terminal_free(terminal);
}

/// Restores a binary snapshot into a fresh terminal (client side and tests).
pub fn restore(bytes: []const u8, scrollback_bytes: usize) !g.GhosttyTerminal {
    var decoder: g.GhosttySnapshotDecoder = null;
    try check(g.ghostty_snapshot_decoder_new_buf(null, &decoder, bytes.ptr, bytes.len));
    defer g.ghostty_snapshot_decoder_free(decoder);
    var terminal: g.GhosttyTerminal = null;
    try check(g.ghostty_snapshot_decoder_ready(decoder, &terminal));
    errdefer g.ghostty_terminal_free(terminal);
    // Scrollback limits are not part of the snapshot.
    const limit = scrollback_bytes;
    try check(g.ghostty_terminal_set(terminal, opt(g.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES), &limit));
    while (true) {
        const result = g.ghostty_snapshot_decoder_next(decoder);
        if (result == g.GHOSTTY_NO_VALUE) break;
        try check(result);
    }
    return terminal;
}

/// Plain text of the active screen and scrollback (tests and debugging).
pub fn plain(terminal: g.GhosttyTerminal, allocator: std.mem.Allocator) ![]u8 {
    var options = std.mem.zeroes(g.GhosttyFormatterTerminalOptions);
    options.size = @sizeOf(g.GhosttyFormatterTerminalOptions);
    options.emit = @intCast(g.GHOSTTY_FORMATTER_FORMAT_PLAIN);
    options.extra.size = @sizeOf(g.GhosttyFormatterTerminalExtra);
    options.extra.screen.size = @sizeOf(g.GhosttyFormatterScreenExtra);
    var formatter: g.GhosttyFormatter = null;
    try check(g.ghostty_formatter_terminal_new(null, &formatter, terminal, options));
    defer g.ghostty_formatter_free(formatter);
    var ptr: [*c]u8 = null;
    var len: usize = 0;
    try check(g.ghostty_formatter_format_alloc(formatter, null, &ptr, &len));
    defer g.ghostty_free(null, ptr, len);
    return allocator.dupe(u8, if (len == 0) "" else ptr[0..len]);
}

test "plain formatter accepts an empty terminal" {
    const vt = try Vt.create(std.testing.allocator, 40, 6, 4096);
    defer vt.destroy();
    const text = try plain(vt.terminal, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("", text);
}

test "device attribute and status queries are answered by the owner VT" {
    const vt = try Vt.create(std.testing.allocator, 80, 24, 1 << 20);
    defer vt.destroy();
    vt.write("\x1b[5n\x1b[3;7H\x1b[6n");
    var replies = vt.takeReplies();
    defer replies.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("\x1b[0n\x1b[3;7R", replies.items);
}

test "snapshot restores title, screen text, and alt screen over main" {
    const a = std.testing.allocator;
    const vt = try Vt.create(a, 40, 6, 1 << 20);
    defer vt.destroy();
    vt.write("\x1b]0;hello\x07main one\r\nmain two\r\n\x1b[?1049halt screen");
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try vt.snapshot(a, &bytes);
    const restored = try restore(bytes.items, 1 << 20);
    defer g.ghostty_terminal_free(restored);
    var value: g.GhosttyString = .{ .ptr = null, .len = 0 };
    try check(g.ghostty_terminal_get(restored, dataKey(g.GHOSTTY_TERMINAL_DATA_TITLE), &value));
    try std.testing.expectEqualStrings("hello", value.ptr[0..value.len]);
    const alt = try plain(restored, a);
    defer a.free(alt);
    try std.testing.expect(std.mem.indexOf(u8, alt, "alt screen") != null);
    const leave = "\x1b[?1049l";
    g.ghostty_terminal_vt_write(restored, leave, leave.len);
    const main = try plain(restored, a);
    defer a.free(main);
    try std.testing.expect(std.mem.indexOf(u8, main, "main two") != null);
}

test "handoff adoption keeps screen text and answers queries in both formats" {
    const a = std.testing.allocator;
    const vt = try Vt.create(a, 40, 6, 1 << 20);
    defer vt.destroy();
    vt.write("\x1b]0;kept\x07line one\r\nline two");
    for ([_]bool{ true, false }) |binary| {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(a);
        try if (binary) vt.snapshot(a, &bytes) else vt.formatVt(a, &bytes);
        const copy = try Vt.adopt(a, bytes.items, binary, 40, 6, 1 << 20);
        defer copy.destroy();
        const text = try plain(copy.terminal, a);
        defer a.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "line two") != null);
        try std.testing.expectEqual(@as(usize, 0), copy.replies.items.len);
        copy.write("\x1b[5n");
        var replies = copy.takeReplies();
        defer replies.deinit(a);
        try std.testing.expectEqualStrings("\x1b[0n", replies.items);
    }
}

test "formatter fallback replays screen text and cursor" {
    const a = std.testing.allocator;
    const vt = try Vt.create(a, 40, 6, 1 << 20);
    defer vt.destroy();
    vt.write("\x1b[1mbold\x1b[0m plain\r\nnext");
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try vt.formatVt(a, &bytes);
    const copy = try Vt.create(a, 40, 6, 1 << 20);
    defer copy.destroy();
    copy.write(bytes.items);
    const want = try plain(vt.terminal, a);
    defer a.free(want);
    const got = try plain(copy.terminal, a);
    defer a.free(got);
    try std.testing.expectEqualStrings(want, got);
    try std.testing.expect(buildIdentity().len > 0);
}
