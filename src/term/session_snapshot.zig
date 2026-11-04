//! GUI-side binary snapshot decoder. READY transfers terminal ownership to
//! the caller; the decoder borrows it until FINISH or deinit. Calls are
//! synchronous: a transport reader must block off the GUI thread, never
//! return zero to signal temporary starvation.
//! Serialize decoder calls with rendering/live parsing of its terminal; READY
//! makes interleaving safe, not concurrent access from different threads.
const std = @import("std");
const g = @import("ghostty_c");
const ghostty = @import("ghostty.zig");

pub const Decoder = struct {
    handle: g.GhosttySnapshotDecoder = null,
    state: enum { prefix, history, finished, failed, closed } = .prefix,

    /// Buffer is borrowed and must stay immutable until FINISH or deinit.
    pub fn initBuffer(bytes: []const u8) !Decoder {
        var self: Decoder = .{};
        try check(g.ghostty_snapshot_decoder_new_buf(null, &self.handle, bytes.ptr, bytes.len));
        return self;
    }

    /// Reader context must outlive the decoder. Do not call from the UI thread
    /// when the callback can wait for network/connector data.
    pub fn initReader(reader: g.GhosttyReader) !Decoder {
        var self: Decoder = .{};
        try check(g.ghostty_snapshot_decoder_new(null, &self.handle, reader));
        return self;
    }

    pub fn deinit(self: *Decoder) void {
        g.ghostty_snapshot_decoder_free(self.handle);
        self.handle = null;
        self.state = .closed;
    }

    /// Returned terminal is renderable immediately. Caller must free it only
    /// after deinitializing this decoder. Snapshot does not carry local limits.
    pub fn ready(self: *Decoder, scrollback_bytes: usize) !*anyopaque {
        if (self.state != .prefix) return error.InvalidSnapshotState;
        errdefer self.state = .failed;
        var terminal: g.GhosttyTerminal = null;
        try check(g.ghostty_snapshot_decoder_ready(self.handle, &terminal));
        const result = terminal orelse return error.InvalidSnapshot;
        errdefer g.ghostty_terminal_free(result);
        try check(g.ghostty_terminal_set(result, @intCast(g.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES), &scrollback_bytes));
        // Install before any post-READY live bytes or resize. The owner, never
        // this mirror, owns query replies. After registering GUI callbacks,
        // live output must use Runtime.terminalWriteMirror for the same reason.
        try check(g.ghostty_terminal_set(result, @intCast(g.GHOSTTY_TERMINAL_OPT_WRITE_PTY), @ptrCast(&discardReply)));
        self.state = .history;
        return result;
    }

    /// Decode one history/image record. False means FINISH validated. The
    /// terminal may render, resize or consume live bytes between these calls.
    /// On failure, only deinit is allowed; terminal remains caller-owned.
    pub fn next(self: *Decoder) !bool {
        if (self.state == .finished) return false;
        if (self.state != .history) return error.InvalidSnapshotState;
        errdefer self.state = .failed;
        const result = g.ghostty_snapshot_decoder_next(self.handle);
        if (result == g.GHOSTTY_NO_VALUE) {
            self.state = .finished;
            return false;
        }
        try check(result);
        return true;
    }
};

fn discardReply(_: g.GhosttyTerminal, _: ?*anyopaque, _: [*c]const u8, _: usize) callconv(.c) void {}

fn check(result: anytype) !void {
    if (result != g.GHOSTTY_SUCCESS) return error.InvalidSnapshot;
}

fn encode(terminal: ?*anyopaque) ![]u8 {
    var ptr: [*c]u8 = null;
    var len: usize = 0;
    try check(g.ghostty_snapshot_encode_alloc(@ptrCast(terminal), null, &ptr, &len));
    defer g.ghostty_free(null, ptr, len);
    return std.testing.allocator.dupe(u8, if (len == 0) "" else ptr[0..len]);
}

fn plain(terminal: ?*anyopaque) ![]u8 {
    var options = std.mem.zeroes(g.GhosttyFormatterTerminalOptions);
    options.size = @sizeOf(g.GhosttyFormatterTerminalOptions);
    options.emit = @intCast(g.GHOSTTY_FORMATTER_FORMAT_PLAIN);
    options.extra.size = @sizeOf(g.GhosttyFormatterTerminalExtra);
    options.extra.screen.size = @sizeOf(g.GhosttyFormatterScreenExtra);
    var formatter: g.GhosttyFormatter = null;
    try check(g.ghostty_formatter_terminal_new(null, &formatter, @ptrCast(terminal), options));
    defer g.ghostty_formatter_free(formatter);
    var ptr: [*c]u8 = null;
    var len: usize = 0;
    try check(g.ghostty_formatter_format_alloc(formatter, null, &ptr, &len));
    defer g.ghostty_free(null, ptr, len);
    return std.testing.allocator.dupe(u8, if (len == 0) "" else ptr[0..len]);
}

test "session snapshot READY supports rendering and live input before history finishes" {
    const a = std.testing.allocator;
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    const source = try runtime.createTerminal(40, 6, 1 << 20);
    defer runtime.freeTerminal(source);
    for (0..5000) |_| runtime.terminalWrite(source, "old history\r\n");
    runtime.terminalWrite(source, "\x1b]0;session-title\x07\x1b]7;file://host/home/user\x07main screen\x1b[?1049halt screen");
    const bytes = try encode(source);
    defer a.free(bytes);
    var decoder = try Decoder.initBuffer(bytes);
    const terminal = try decoder.ready(1 << 20);
    defer runtime.freeTerminal(terminal);
    defer decoder.deinit();
    const render_state = try runtime.createRenderState();
    defer runtime.freeRenderState(render_state);
    try runtime.updateRenderState(render_state, terminal);
    var title = g.GhosttyString{ .ptr = null, .len = 0 };
    try check(g.ghostty_terminal_get(@ptrCast(terminal), @intCast(g.GHOSTTY_TERMINAL_DATA_TITLE), &title));
    try std.testing.expectEqualStrings("session-title", title.ptr[0..title.len]);
    runtime.terminalWrite(terminal, " live");
    var pages: usize = 0;
    while (try decoder.next()) pages += 1;
    try std.testing.expect(pages > 0);
    try std.testing.expect(!try decoder.next());
    const alt = try plain(terminal);
    defer a.free(alt);
    try std.testing.expect(std.mem.indexOf(u8, alt, "alt screen live") != null);
    runtime.terminalWrite(terminal, "\x1b[?1049l");
    const main = try plain(terminal);
    defer a.free(main);
    try std.testing.expect(std.mem.indexOf(u8, main, "old history") != null);
    try std.testing.expect(std.mem.indexOf(u8, main, "main screen") != null);
}

test "session decoder rejects invalid lifecycle and truncated prefix" {
    var decoder = try Decoder.initBuffer("not a snapshot");
    defer decoder.deinit();
    try std.testing.expectError(error.InvalidSnapshotState, decoder.next());
    try std.testing.expectError(error.InvalidSnapshot, decoder.ready(4096));
    try std.testing.expectError(error.InvalidSnapshotState, decoder.ready(4096));
    try std.testing.expectError(error.InvalidSnapshotState, decoder.next());
}

test "session decoder owns no terminal after READY and can abandon history" {
    const a = std.testing.allocator;
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    const source = try runtime.createTerminal(40, 6, 1 << 20);
    defer runtime.freeTerminal(source);
    for (0..5000) |_| runtime.terminalWrite(source, "history\r\n");
    const bytes = try encode(source);
    defer a.free(bytes);
    var decoder = try Decoder.initBuffer(bytes);
    const terminal = try decoder.ready(4096);
    defer runtime.freeTerminal(terminal);
    try std.testing.expectError(error.InvalidSnapshotState, decoder.ready(4096));
    decoder.deinit();
    decoder.deinit(); // Cleanup is idempotent.
    runtime.terminalWrite(terminal, "still usable");
    const text = try plain(terminal);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "still usable") != null);
    var limit: usize = 0;
    try check(g.ghostty_terminal_get(@ptrCast(terminal), @intCast(g.GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_BYTES), &limit));
    try std.testing.expectEqual(@as(usize, 4096), limit);
}

const ChunkReader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn read(ctx: ?*anyopaque, buffer: [*c]u8, capacity: usize, out_read: [*c]usize) callconv(.c) bool {
        const self: *ChunkReader = @ptrCast(@alignCast(ctx.?));
        const n = @min(@min(capacity, 37), self.bytes.len - self.offset);
        @memcpy(buffer[0..n], self.bytes[self.offset..][0..n]);
        self.offset += n;
        out_read.* = n;
        return true;
    }
};

test "session snapshot chunk reader exposes READY before history and rejects missing FINISH" {
    const a = std.testing.allocator;
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    const source = try runtime.createTerminal(40, 6, 1 << 20);
    defer runtime.freeTerminal(source);
    for (0..5000) |_| runtime.terminalWrite(source, "history\r\n");
    const bytes = try encode(source);
    defer a.free(bytes);
    var reader: ChunkReader = .{ .bytes = bytes[0 .. bytes.len - 1] };
    var decoder = try Decoder.initReader(.{ .read = ChunkReader.read, .userdata = &reader });
    const terminal = try decoder.ready(1 << 20);
    defer runtime.freeTerminal(terminal);
    defer decoder.deinit();
    try std.testing.expect(reader.offset < bytes.len / 2);
    var failed = false;
    while (true) {
        const more = decoder.next() catch |err| {
            try std.testing.expectEqual(error.InvalidSnapshot, err);
            failed = true;
            break;
        };
        if (!more) break;
    }
    try std.testing.expect(failed);
    try std.testing.expectError(error.InvalidSnapshotState, decoder.next());
    // A late decoder error does not destroy or invalidate the caller's VT.
    runtime.terminalWrite(terminal, "recovered");
    const text = try plain(terminal);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "recovered") != null);
}

test "session snapshot carries unfinished parser continuation into live output" {
    const a = std.testing.allocator;
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    const source = try runtime.createTerminal(40, 6, 4096);
    defer runtime.freeTerminal(source);
    const continuation: usize = 64 * 1024;
    try check(g.ghostty_terminal_set(@ptrCast(source), @intCast(g.GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES), &continuation));
    runtime.terminalWrite(source, "before\x1b]0;unfinished");
    const bytes = try encode(source);
    defer a.free(bytes);
    var decoder = try Decoder.initBuffer(bytes);
    const terminal = try decoder.ready(4096);
    defer runtime.freeTerminal(terminal);
    defer decoder.deinit();
    while (try decoder.next()) {}
    runtime.terminalWrite(terminal, " title\x07after");
    var title = g.GhosttyString{ .ptr = null, .len = 0 };
    try check(g.ghostty_terminal_get(@ptrCast(terminal), @intCast(g.GHOSTTY_TERMINAL_DATA_TITLE), &title));
    try std.testing.expectEqualStrings("unfinished title", title.ptr[0..title.len]);
    const text = try plain(terminal);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "beforeafter") != null);
}

test "session mirror suppresses query replies without swallowing user paste" {
    const a = std.testing.allocator;
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    const terminal = try runtime.createTerminal(40, 6, 4096);
    defer runtime.freeTerminal(terminal);
    var output: ghostty.PasteOutput = .{ .allocator = a };
    defer output.deinit();
    const Sink = struct {
        fn write(_: ?*anyopaque, ctx: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void {
            const sink: *ghostty.PasteOutput = @ptrCast(@alignCast(ctx.?));
            sink.append(bytes[0..len]);
        }
    };
    runtime.setTerminalUserdata(terminal, &output);
    runtime.setWritePtyCallback(terminal, Sink.write);
    runtime.terminalWrite(terminal, "\x1b[5n");
    try std.testing.expectEqualStrings("\x1b[0n", output.bytes.items);
    output.bytes.clearRetainingCapacity();
    runtime.terminalWriteMirror(terminal, "\x1b[5n\x1b[6n\x1b[?2004h", Sink.write);
    try std.testing.expectEqual(@as(usize, 0), output.bytes.items.len);
    try runtime.pasteText(terminal, "user input");
    try std.testing.expectEqualStrings("\x1b[200~user input\x1b[201~", output.bytes.items);
}
