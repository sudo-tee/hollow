const std = @import("std");
const io = @import("../io.zig");
const selection = @import("../selection.zig");
const ghostty = @import("../term/ghostty.zig");
const text_helpers = @import("text_helpers.zig");
const selection_mod = @import("selection.zig");
const platform = @import("../platform.zig");
const lua_bridge = @import("../lua_bridge.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Pane = @import("../pane.zig").Pane;
const Hyperlinks = @import("../config.zig").Config.Hyperlinks;
const CellPoint = selection.CellPoint;

pub const HoveredHyperlink = struct {
    pane: *Pane,
    row: usize,
    start_col: usize,
    end_col: usize,
};

const HyperlinkToken = struct {
    start_col: usize,
    end_col: usize,
    text: []const u8,
    open_text: []const u8,
};

const LinkRow = struct {
    text: []const u8,
    wrapped: bool,
    continuation: bool,
};

const LinkRows = struct {
    runtime: *ghostty.Runtime,
    pane: *Pane,
    ascii: [4096]u8 = undefined,

    fn get(self: *LinkRows, row: usize) ?LinkRow {
        if (!self.runtime.populateRowIterator(self.pane.render_state, &self.pane.row_iterator)) return null;
        var index: usize = 0;
        while (self.runtime.nextRow(self.pane.row_iterator)) : (index += 1) {
            if (index != row) continue;
            const raw = self.runtime.rowRaw(self.pane.row_iterator);
            if (!self.runtime.populateRowCells(self.pane.row_iterator, &self.pane.row_cells)) return null;
            var len: usize = 0;
            while (self.runtime.nextCell(self.pane.row_cells)) : (len += 1) {
                if (len == self.ascii.len) return null;
                var cell_buf: [16]u8 = undefined;
                var cell_len: usize = 0;
                text_helpers.appendCellText(self.runtime, self.pane.row_cells, &cell_buf, &cell_len);
                self.ascii[len] = if (cell_len == 1 and cell_buf[0] < 128) cell_buf[0] else 0;
            }
            return .{
                .text = self.ascii[0..len],
                .wrapped = self.runtime.rowWrapped(raw),
                .continuation = self.runtime.rowWrapContinuation(raw),
            };
        }
        return null;
    }
};

const www_scheme = "https://";

fn contains(set: []const u8, ch: u8) bool {
    return std.mem.indexOfScalar(u8, set, ch) != null;
}

fn isDelimiter(delimiters: []const u8, ch: u8) bool {
    return ch == 0 or contains(delimiters, ch);
}

fn hasLinkPrefix(cfg: Hyperlinks, token: []const u8) bool {
    var prefixes = std.mem.tokenizeScalar(u8, cfg.prefixesOrDefault(), ' ');
    while (prefixes.next()) |prefix| {
        if (std.mem.startsWith(u8, token, prefix)) return true;
    }
    return false;
}

// Finds the delimiter-free run under `point`, following soft wraps in both
// directions, then trims it and clips the result to the hovered row.
// Rows share the provider's storage, so each one is consumed before the next fetch.
fn wrappedTokenAt(rows: anytype, point: CellPoint, cfg: Hyperlinks, out: []u8) ?HyperlinkToken {
    const delimiters = cfg.delimitersOrDefault();
    var row_index = point.row;
    var row = rows.get(row_index) orelse return null;
    if (point.col >= row.text.len or isDelimiter(delimiters, row.text[point.col])) return null;

    // Walk back to the row where the run begins.
    var start = point.col;
    while (true) {
        while (start > 0 and !isDelimiter(delimiters, row.text[start - 1])) start -= 1;
        if (start > 0 or !row.continuation) break;
        // The run begins above the viewport and can't be reconstructed.
        if (row_index == 0) return null;
        row_index -= 1;
        row = rows.get(row_index) orelse return null;
        if (!row.wrapped) return null;
        start = row.text.len;
    }

    // Copy the run forward, leaving room in front to prepend the www scheme.
    const run = out[www_scheme.len..];
    var len: usize = 0;
    var cursor: usize = 0; // offset of `point` within the run
    var span_start: usize = 0; // columns the run covers on the hovered row
    var span_end: usize = 0;
    while (true) {
        var end = start;
        while (end < row.text.len and !isDelimiter(delimiters, row.text[end])) end += 1;
        if (row_index == point.row) {
            cursor = len + point.col - start;
            span_start = start;
            span_end = end;
        }
        const part = row.text[start..end];
        if (part.len > run.len - len) return null;
        @memcpy(run[len..][0..part.len], part);
        len += part.len;
        if (end < row.text.len or !row.wrapped) break;
        row_index += 1;
        row = rows.get(row_index) orelse return null;
        if (!row.continuation) return null;
        start = 0;
    }

    var lo: usize = 0;
    while (lo < len and contains(cfg.trimLeadingOrDefault(), run[lo])) lo += 1;
    var hi = len;
    while (hi > lo and contains(cfg.trimTrailingOrDefault(), run[hi - 1])) hi -= 1;
    if (cursor < lo or cursor >= hi) return null;

    const token = run[lo..hi];
    const www = cfg.match_www and std.mem.startsWith(u8, token, "www.");
    if (!www and !hasLinkPrefix(cfg, token)) return null;
    const open_text = if (www) blk: {
        // `token` starts at out[www_scheme.len + lo], so the scheme fits just before it.
        @memcpy(out[lo..][0..www_scheme.len], www_scheme);
        break :blk out[lo .. www_scheme.len + hi];
    } else token;

    return .{
        .start_col = @max(span_start, point.col -| (cursor - lo)),
        .end_col = @min(span_end, point.col + (hi - cursor)),
        .text = token,
        .open_text = open_text,
    };
}

pub fn hyperlinkUriAt(self: *App, pane: *Pane, point: CellPoint, out: []u8) ?[]const u8 {
    const rt = self.ghostty orelse return null;
    const terminal = pane.terminal orelse return null;

    var ref = ghostty.GridRef{
        .size = @sizeOf(ghostty.GridRef),
        .node = null,
        .x = 0,
        .y = 0,
    };
    const lookup_point = ghostty.Point{
        .tag = .viewport,
        .value = .{ .coordinate = .{
            .x = @intCast(point.col),
            .y = @intCast(point.row),
        } },
    };
    if (rt.terminal_grid_ref(terminal, lookup_point, &ref) != ghostty.success) return null;

    var uri_len: usize = 0;
    const probe_result = rt.grid_ref_hyperlink_uri(&ref, null, 0, &uri_len);
    if (probe_result == ghostty.success) return null;
    if (probe_result != ghostty.out_of_space or uri_len == 0 or uri_len > out.len) return null;
    if (rt.grid_ref_hyperlink_uri(&ref, out.ptr, out.len, &uri_len) != ghostty.success or uri_len == 0) return null;
    return out[0..uri_len];
}

// OSC 8 links carry their URI per cell; the token is the run of cells sharing it.
fn osc8TokenAt(self: *App, pane: *Pane, point: CellPoint, out: []u8) ?HyperlinkToken {
    const uri = hyperlinkUriAt(self, pane, point, out) orelse return null;
    var start_col = point.col;
    while (start_col > 0 and sameUriAt(self, pane, .{ .row = point.row, .col = start_col - 1 }, uri)) start_col -= 1;
    var end_col = point.col + 1;
    while (end_col < pane.cols and sameUriAt(self, pane, .{ .row = point.row, .col = end_col }, uri)) end_col += 1;
    return .{ .start_col = start_col, .end_col = end_col, .text = uri, .open_text = uri };
}

fn sameUriAt(self: *App, pane: *Pane, point: CellPoint, uri: []const u8) bool {
    var buf: [8192]u8 = undefined;
    const other = hyperlinkUriAt(self, pane, point, &buf) orelse return false;
    return std.mem.eql(u8, other, uri);
}

fn hyperlinkTokenAt(self: *App, pane: *Pane, point: CellPoint, out: []u8) ?HyperlinkToken {
    const runtime = if (self.ghostty) |*rt| rt else return null;
    if (!App.paneRenderHelpersReady(pane)) return null;
    if (osc8TokenAt(self, pane, point, out)) |token| return token;
    var rows = LinkRows{ .runtime = runtime, .pane = pane };
    return wrappedTokenAt(&rows, point, self.config.hyperlinks, out);
}

pub fn routeLink(self: *App, request: lua_bridge.LinkRouteRequest) lua_bridge.LinkRouteResult {
    if (self.lua) |*lua| return lua.runLinkRoute(request);
    return .fallback;
}

pub fn openHyperlinkAt(self: *App, pane: *Pane, point: CellPoint, mods: u32) void {
    if (!self.config.hyperlinks.enabled) return;
    var row_buf: [8192]u8 = undefined;
    const token = hyperlinkTokenAt(self, pane, point, &row_buf) orelse return;

    var route_url: ?[]u8 = null;
    switch (routeLink(self, .{
        .url = token.open_text,
        .text = token.text,
        .pane_id = @intFromPtr(pane),
        .mods = mods,
        .source = "click",
        .kind = "url",
    })) {
        .fallback => {},
        .handled => return,
        .rewrite => |url| route_url = url,
        .failed => return,
    }
    defer if (route_url) |url| self.allocator.free(url);

    platform.openExternalWithOpenerAsync(route_url orelse token.open_text, self.config.hyperlinks.opener) catch |err| {
        std.log.err("open hyperlink failed: {s}", .{@errorName(err)});
    };
}

pub fn updateHoveredHyperlink(self: *App) void {
    if (!self.hover_probe_dirty) return;
    if (!self.config.hyperlinks.enabled) {
        self.hover_probe_dirty = false;
        self.hover_probe_defer_until_ns = 0;
        self.hovered_hyperlink = null;
        return;
    }
    if (self.hitTestPane(self.pointer_x, self.pointer_y)) |hit| {
        if (hit.pane.pty_wrote_this_frame) {
            const now_ns = io.nanoTimestamp();
            if (self.hover_probe_defer_until_ns == 0) {
                self.hover_probe_defer_until_ns = now_ns + 50 * std.time.ns_per_ms;
            }
            if (now_ns < self.hover_probe_defer_until_ns) {
                self.hovered_hyperlink = null;
                return;
            }
        }
    }
    self.hover_probe_defer_until_ns = 0;
    self.hover_probe_dirty = false;
    self.hovered_hyperlink = null;
    if (self.hitTestPane(self.pointer_x, self.pointer_y)) |hit| {
        const point = selection_mod.cellPointFromPaneLocal(self, hit.pane, hit.x, hit.y);
        var row_buf: [8192]u8 = undefined;
        const token = hyperlinkTokenAt(self, hit.pane, point, &row_buf) orelse return;
        self.hovered_hyperlink = .{
            .pane = hit.pane,
            .row = point.row,
            .start_col = token.start_col,
            .end_col = token.end_col,
        };
    }
}

const TestLinkRows = struct {
    rows: []const LinkRow,

    fn get(self: *TestLinkRows, row: usize) ?LinkRow {
        return if (row < self.rows.len) self.rows[row] else null;
    }
};

test "hyperlinks reconstruct soft wraps from every segment" {
    var rows = TestLinkRows{ .rows = &.{
        .{ .text = "see https://exa", .wrapped = true, .continuation = false },
        .{ .text = "mple.com/a/long", .wrapped = true, .continuation = true },
        .{ .text = "/path. next", .wrapped = false, .continuation = true },
    } };
    const cfg = Hyperlinks{};
    var buf: [128]u8 = undefined;
    for ([_]CellPoint{ .{ .row = 0, .col = 8 }, .{ .row = 1, .col = 3 }, .{ .row = 2, .col = 2 } }) |point| {
        const token = wrappedTokenAt(&rows, point, cfg, &buf).?;
        try std.testing.expectEqualStrings("https://example.com/a/long/path", token.open_text);
    }
    const last = wrappedTokenAt(&rows, .{ .row = 2, .col = 2 }, cfg, &buf).?;
    try std.testing.expectEqual(@as(usize, 0), last.start_col);
    try std.testing.expectEqual(@as(usize, 5), last.end_col);
    try std.testing.expect(wrappedTokenAt(&rows, .{ .row = 2, .col = 5 }, cfg, &buf) == null);
}

test "hyperlinks do not join hard newlines or return truncated buffers" {
    var rows = TestLinkRows{ .rows = &.{
        .{ .text = "https://example.com", .wrapped = false, .continuation = false },
        .{ .text = "/not-a-continuation", .wrapped = false, .continuation = false },
    } };
    const cfg = Hyperlinks{};
    var buf: [128]u8 = undefined;
    const token = wrappedTokenAt(&rows, .{ .row = 0, .col = 2 }, cfg, &buf).?;
    try std.testing.expectEqualStrings("https://example.com", token.open_text);
    try std.testing.expect(wrappedTokenAt(&rows, .{ .row = 1, .col = 2 }, cfg, &buf) == null);
    try std.testing.expect(wrappedTokenAt(&rows, .{ .row = 0, .col = 2 }, cfg, buf[0..8]) == null);
}

test "wrapped www links expand safely and respect viewport boundaries" {
    var rows = TestLinkRows{ .rows = &.{
        .{ .text = "www.exam", .wrapped = true, .continuation = false },
        .{ .text = "ple.com!", .wrapped = false, .continuation = true },
    } };
    const cfg = Hyperlinks{};
    var buf: [128]u8 = undefined;
    const token = wrappedTokenAt(&rows, .{ .row = 1, .col = 2 }, cfg, &buf).?;
    try std.testing.expectEqualStrings("https://www.example.com", token.open_text);
    rows.rows = rows.rows[1..];
    try std.testing.expect(wrappedTokenAt(&rows, .{ .row = 0, .col = 2 }, cfg, &buf) == null);
    rows.rows = &.{.{ .text = "https://example", .wrapped = true, .continuation = false }};
    try std.testing.expect(wrappedTokenAt(&rows, .{ .row = 0, .col = 2 }, cfg, &buf) == null);
}

test "trimmed wrapped links clip hover columns to the trimmed token" {
    var rows = TestLinkRows{ .rows = &.{
        .{ .text = "x (www.ex", .wrapped = true, .continuation = false },
        .{ .text = "ample.com). y", .wrapped = false, .continuation = true },
    } };
    const cfg = Hyperlinks{};
    var buf: [128]u8 = undefined;
    try std.testing.expect(wrappedTokenAt(&rows, .{ .row = 0, .col = 2 }, cfg, &buf) == null);
    const head = wrappedTokenAt(&rows, .{ .row = 0, .col = 4 }, cfg, &buf).?;
    try std.testing.expectEqualStrings("https://www.example.com", head.open_text);
    try std.testing.expectEqual(@as(usize, 3), head.start_col);
    try std.testing.expectEqual(@as(usize, 9), head.end_col);
    const tail = wrappedTokenAt(&rows, .{ .row = 1, .col = 0 }, cfg, &buf).?;
    try std.testing.expectEqual(@as(usize, 0), tail.start_col);
    try std.testing.expectEqual(@as(usize, 9), tail.end_col);
    try std.testing.expect(wrappedTokenAt(&rows, .{ .row = 1, .col = 9 }, cfg, &buf) == null);
}
