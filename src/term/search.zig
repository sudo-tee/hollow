const std = @import("std");
const c = @import("ghostty_c");
const ghostty = @import("ghostty.zig");

pub const Query = union(enum) {
    pattern: []const u8,
    literal: []const u8,

    /// Preserve copy mode's pattern syntax. Vim's very-nomagic prefix opts
    /// into native literal search without reinterpreting existing queries.
    pub fn parse(query: []const u8) Query {
        if (std.mem.startsWith(u8, query, "\\V")) return .{ .literal = query[2..] };
        return .{ .pattern = query };
    }
};

pub const Point = struct { row: usize, col: usize };
pub const Match = struct {
    start: Point,
    /// Exclusive column on the final row, including for wrapped matches.
    end: Point,
};

/// Reusable, UI-independent literal search. Call on the terminal owner thread,
/// serialized with PTY parsing, resize, and teardown. Only numeric coordinates
/// escape a step; Ghostty's borrowed grid refs never survive terminal mutation.
pub const Search = struct {
    handle: c.GhosttySearch = null,
    terminal: ?*anyopaque = null,
    matches: std.ArrayList(Match) = .empty,
    scratch: std.ArrayList(c.GhosttySelection) = .empty,
    complete: bool = true,
    revision: u64 = 0,

    pub fn deinit(self: *Search, allocator: std.mem.Allocator) void {
        c.ghostty_search_free(self.handle);
        self.matches.deinit(allocator);
        self.scratch.deinit(allocator);
        self.* = .{};
    }

    pub fn setNeedle(self: *Search, allocator: std.mem.Allocator, terminal: ?*anyopaque, needle: []const u8) !void {
        if (terminal == null) return error.SearchFailed;
        if (self.handle == null or self.terminal != terminal) {
            self.deinit(allocator);
            try check(c.ghostty_search_new(null, &self.handle, @ptrCast(terminal)));
            self.terminal = terminal;
        }
        const value = c.GhosttyString{ .ptr = needle.ptr, .len = needle.len };
        try check(c.ghostty_search_set(self.handle, c.GHOSTTY_SEARCH_OPT_NEEDLE, &value));
        self.matches.clearRetainingCapacity();
        self.complete = needle.len == 0;
        self.revision = 0;
    }

    /// One feed and one tick, never the blocking ghostty_search_run/select path.
    /// Feed again even after completion to pick up output, reflow and eviction.
    pub fn step(self: *Search, allocator: std.mem.Allocator) !void {
        if (self.handle == null) return;
        // On failure, don't expose coordinates from a previous terminal state.
        self.matches.clearRetainingCapacity();
        try check(c.ghostty_search_feed(self.handle));
        var status: c.GhosttySearchStatus = undefined;
        try check(c.ghostty_search_tick(self.handle, &status));
        self.complete = status == c.GHOSTTY_SEARCH_STATUS_COMPLETE;

        var buffer = c.GhosttySelectionBuffer{ .ptr = null, .cap = 0, .len = 0 };
        const result = c.ghostty_search_get(self.handle, c.GHOSTTY_SEARCH_DATA_MATCHES, &buffer);
        if (result != c.GHOSTTY_OUT_OF_SPACE) try check(result);
        try self.scratch.resize(allocator, buffer.len);
        buffer.ptr = self.scratch.items.ptr;
        buffer.cap = self.scratch.items.len;
        try check(c.ghostty_search_get(self.handle, c.GHOSTTY_SEARCH_DATA_MATCHES, &buffer));
        try self.matches.ensureTotalCapacity(allocator, buffer.len);
        // Native results are newest-first. Keep copy mode's oldest-first n/N
        // ordering, and make this ordering explicit for future search UIs.
        var index = buffer.len;
        while (index > 0) {
            index -= 1;
            const match = &self.scratch.items[index];
            var start: c.GhosttyPointCoordinate = undefined;
            var end: c.GhosttyPointCoordinate = undefined;
            if (c.ghostty_terminal_point_from_grid_ref(@ptrCast(self.terminal), &match.start, c.GHOSTTY_POINT_TAG_SCREEN, &start) != c.GHOSTTY_SUCCESS or
                c.ghostty_terminal_point_from_grid_ref(@ptrCast(self.terminal), &match.end, c.GHOSTTY_POINT_TAG_SCREEN, &end) != c.GHOSTTY_SUCCESS) continue;
            // Selection endpoints refer to the character's leading cell, not
            // necessarily its trailing spacer. Expand an ending wide glyph so
            // copy-mode highlighting and yanking cover the whole character.
            var cell: c.GhosttyCell = undefined;
            try check(c.ghostty_grid_ref_cell(&match.end, &cell));
            var wide: c.GhosttyCellWide = undefined;
            try check(c.ghostty_cell_get(cell, c.GHOSTTY_CELL_DATA_WIDE, &wide));
            const end_width: usize = if (wide == c.GHOSTTY_CELL_WIDE_WIDE) 2 else 1;
            self.matches.appendAssumeCapacity(.{
                .start = .{ .row = start.y, .col = start.x },
                .end = .{ .row = end.y, .col = @as(usize, end.x) + end_width },
            });
        }
        // References remain allocated as scratch, but are never read again.
        self.scratch.clearRetainingCapacity();
        var hash = std.hash.Wyhash.init(0);
        for (self.matches.items) |match| {
            const coordinates = [4]usize{ match.start.row, match.start.col, match.end.row, match.end.col };
            hash.update(std.mem.asBytes(&coordinates));
        }
        self.revision = hash.final();
    }
};

fn check(result: c.GhosttyResult) !void {
    if (result == c.GHOSTTY_OUT_OF_MEMORY) return error.OutOfMemory;
    if (result != c.GHOSTTY_SUCCESS) return error.SearchFailed;
}

fn finish(search: *Search, allocator: std.mem.Allocator) !void {
    for (0..10000) |_| {
        try search.step(allocator);
        if (search.complete) return;
    }
    return error.SearchDidNotComplete;
}

test "terminal search query preserves patterns and explicitly enables literal mode" {
    try std.testing.expectEqualStrings("f.o", Query.parse("f.o").pattern);
    try std.testing.expectEqualStrings("f.o", Query.parse("\\Vf.o").literal);
    try std.testing.expectEqualStrings("", Query.parse("\\V").literal);
}

test "terminal search literal matches are case insensitive and span wrapped rows" {
    const allocator = std.testing.allocator;
    var runtime = try ghostty.Runtime.init(allocator, null);
    defer runtime.deinit();
    const terminal = try runtime.createTerminal(5, 3, 0);
    defer runtime.freeTerminal(terminal);
    runtime.terminalWrite(terminal, "abcDEFghi");
    var search: Search = .{};
    defer search.deinit(allocator);
    try search.setNeedle(allocator, terminal, "defg");
    try finish(&search, allocator);
    try std.testing.expectEqual(@as(usize, 1), search.matches.items.len);
    try std.testing.expectEqualDeep(Match{ .start = .{ .row = 0, .col = 3 }, .end = .{ .row = 1, .col = 2 } }, search.matches.items[0]);
    try search.setNeedle(allocator, terminal, "d.f");
    try finish(&search, allocator);
    try std.testing.expectEqual(@as(usize, 0), search.matches.items.len);
}

test "terminal search follows output screen switches resize reset and clear" {
    const allocator = std.testing.allocator;
    var runtime = try ghostty.Runtime.init(allocator, null);
    defer runtime.deinit();
    const terminal = try runtime.createTerminal(20, 3, 0);
    defer runtime.freeTerminal(terminal);
    var search: Search = .{};
    defer search.deinit(allocator);
    runtime.terminalWrite(terminal, "needle");
    try search.setNeedle(allocator, terminal, "needle");
    try finish(&search, allocator);
    try std.testing.expectEqual(@as(usize, 1), search.matches.items.len);
    runtime.terminalWrite(terminal, "\r\nNEEDLE");
    try finish(&search, allocator);
    try std.testing.expectEqual(@as(usize, 2), search.matches.items.len);
    try std.testing.expect(search.matches.items[0].start.row < search.matches.items[1].start.row);
    runtime.terminalWrite(terminal, "\x1b[?1049halternate needle");
    try finish(&search, allocator);
    try std.testing.expectEqual(@as(usize, 1), search.matches.items.len);
    runtime.terminalWrite(terminal, "\x1b[?1049l");
    try finish(&search, allocator);
    try std.testing.expectEqual(@as(usize, 2), search.matches.items.len);
    runtime.terminal_resize(terminal, 10, 3, 0, 0);
    try finish(&search, allocator);
    try std.testing.expectEqual(@as(usize, 2), search.matches.items.len);
    runtime.terminalWrite(terminal, "\x1bc");
    try finish(&search, allocator);
    try std.testing.expectEqual(@as(usize, 0), search.matches.items.len);
    try search.setNeedle(allocator, terminal, "");
    try finish(&search, allocator);
    try std.testing.expect(search.complete);
    try std.testing.expectEqual(@as(usize, 0), search.matches.items.len);
}

test "terminal search may be freed after its terminal" {
    const allocator = std.testing.allocator;
    var runtime = try ghostty.Runtime.init(allocator, null);
    defer runtime.deinit();
    const terminal = try runtime.createTerminal(20, 3, 0);
    var search: Search = .{};
    defer search.deinit(allocator);
    try search.setNeedle(allocator, terminal, "needle");
    runtime.freeTerminal(terminal);
    try std.testing.expectError(error.SearchFailed, search.step(allocator));
    try std.testing.expectEqual(@as(usize, 0), search.matches.items.len);
}

test "terminal search maps wide Unicode matches to full cell ranges" {
    const allocator = std.testing.allocator;
    var runtime = try ghostty.Runtime.init(allocator, null);
    defer runtime.deinit();
    const terminal = try runtime.createTerminal(20, 3, 0);
    defer runtime.freeTerminal(terminal);
    runtime.terminalWrite(terminal, "a\u{754c}b");
    var search: Search = .{};
    defer search.deinit(allocator);
    try search.setNeedle(allocator, terminal, "\u{754c}");
    try finish(&search, allocator);
    try std.testing.expectEqual(@as(usize, 1), search.matches.items.len);
    try std.testing.expectEqualDeep(Match{ .start = .{ .row = 0, .col = 1 }, .end = .{ .row = 0, .col = 3 } }, search.matches.items[0]);
}

test "terminal search advances through scrollback and prunes evicted matches" {
    const allocator = std.testing.allocator;
    var runtime = try ghostty.Runtime.init(allocator, null);
    defer runtime.deinit();
    const terminal = try runtime.createTerminal(80, 3, 16 * 1024 * 1024);
    defer runtime.freeTerminal(terminal);
    for (0..2000) |_| runtime.terminalWrite(terminal, "needle\r\n");
    var search: Search = .{};
    defer search.deinit(allocator);
    try search.setNeedle(allocator, terminal, "needle");
    try search.step(allocator);
    try std.testing.expect(!search.complete);
    try finish(&search, allocator);
    try std.testing.expectEqual(@as(usize, 2000), search.matches.items.len);
    for (search.matches.items[1..], search.matches.items[0 .. search.matches.items.len - 1]) |current, previous| {
        try std.testing.expect(current.start.row > previous.start.row);
    }
    // ED3 drops history while retaining the active area.
    runtime.terminalWrite(terminal, "\x1b[3J");
    try finish(&search, allocator);
    try std.testing.expect(search.matches.items.len <= 3);
    try search.setNeedle(allocator, terminal, "absent");
    try finish(&search, allocator);
    try std.testing.expectEqual(@as(usize, 0), search.matches.items.len);
}
