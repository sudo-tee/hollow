const std = @import("std");
const selection = @import("../selection.zig");
const ghostty = @import("../term/ghostty.zig");
const text_helpers = @import("text_helpers.zig");
const selection_mod = @import("selection.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Pane = @import("../pane.zig").Pane;
const CellPoint = selection.CellPoint;

pub const HoveredHyperlink = struct {
    pane: *Pane,
    row: usize,
    start_col: usize,
    end_col: usize,
};

const HyperlinkToken = struct {
    text: []const u8,
    start_col: usize,
    end_col: usize,
    open_text: []const u8,
};

fn rowTextForHyperlinks(self: *App, pane: *Pane, row: usize, out: []u8) ?[]const u8 {
    const runtime = if (self.ghostty) |*rt| rt else return null;
    if (!App.paneRenderHelpersReady(pane)) return null;
    if (!runtime.populateRowIterator(pane.render_state, &pane.row_iterator)) return null;

    var row_index: usize = 0;
    while (runtime.nextRow(pane.row_iterator)) : (row_index += 1) {
        if (row_index != row) continue;
        if (!runtime.populateRowCells(pane.row_iterator, &pane.row_cells)) return null;

        var len: usize = 0;
        while (runtime.nextCell(pane.row_cells)) {
            text_helpers.appendCellText(runtime, pane.row_cells, out, &len);
        }
        return out[0..len];
    }

    return null;
}

fn hyperlinkUriAt(self: *App, pane: *Pane, point: CellPoint, out: []u8) ?[]const u8 {
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

fn hyperlinkTokenAt(self: *App, pane: *Pane, point: CellPoint, out: []u8) ?HyperlinkToken {
    const runtime = if (self.ghostty) |*rt| rt else return null;
    if (!App.paneRenderHelpersReady(pane)) return null;
    if (!runtime.populateRowIterator(pane.render_state, &pane.row_iterator)) return null;
    var row_index: usize = 0;
    while (runtime.nextRow(pane.row_iterator)) : (row_index += 1) {
        if (row_index != point.row) continue;
        if (!runtime.populateRowCells(pane.row_iterator, &pane.row_cells)) return null;

        // OSC 8 hyperlinks are tracked by URI in the terminal grid.
        if (hyperlinkUriAt(self, pane, point, out)) |url| {
            var compare_buf: [8192]u8 = undefined;
            var start_col = point.col;
            while (start_col > 0) {
                const prev_url = hyperlinkUriAt(self, pane, .{ .row = point.row, .col = start_col - 1 }, &compare_buf) orelse break;
                if (!std.mem.eql(u8, prev_url, url)) break;
                start_col -= 1;
            }

            var end_col = point.col + 1;
            const cols = @as(usize, pane.cols);
            while (end_col < cols) {
                const next_url = hyperlinkUriAt(self, pane, .{ .row = point.row, .col = end_col }, &compare_buf) orelse break;
                if (!std.mem.eql(u8, next_url, url)) break;
                end_col += 1;
            }

            return .{
                .text = "",
                .start_col = start_col,
                .end_col = end_col,
                .open_text = url,
            };
        }

        // Fallback: manual pattern matching
        if (!runtime.populateRowCells(pane.row_iterator, &pane.row_cells)) return null;
        var ascii_cols: [4096]u8 = [_]u8{0} ** 4096;
        var col_count: usize = 0;
        while (runtime.nextCell(pane.row_cells) and col_count < ascii_cols.len) : (col_count += 1) {
            var cell_buf: [16]u8 = [_]u8{0} ** 16;
            var cell_len: usize = 0;
            text_helpers.appendCellText(runtime, pane.row_cells, &cell_buf, &cell_len);
            ascii_cols[col_count] = if (cell_len == 1 and cell_buf[0] < 128) cell_buf[0] else 0;
        }

        if (point.col >= col_count) return null;
        const cfg = self.config.hyperlinks;
        const delimiters = cfg.delimitersOrDefault();
        const isDelimiter = struct {
            fn call(delims: []const u8, ch: u8) bool {
                return ch == 0 or std.mem.indexOfScalar(u8, delims, ch) != null;
            }
        }.call;

        if (isDelimiter(delimiters, ascii_cols[point.col])) return null;

        var start = point.col;
        while (start > 0 and !isDelimiter(delimiters, ascii_cols[start - 1])) : (start -= 1) {}

        var end = point.col;
        while (end < col_count and !isDelimiter(delimiters, ascii_cols[end])) : (end += 1) {}
        if (end <= start) return null;

        if (!runtime.populateRowCells(pane.row_iterator, &pane.row_cells)) return null;
        var len: usize = 0;
        var col: usize = 0;
        while (runtime.nextCell(pane.row_cells)) : (col += 1) {
            if (col < start) continue;
            if (col >= end) break;
            text_helpers.appendCellText(runtime, pane.row_cells, out, &len);
        }
        if (len == 0) return null;

        var token = out[0..len];
        var token_start = start;
        const trim_leading_chars = cfg.trimLeadingOrDefault();
        while (token.len > 0 and std.mem.indexOfScalar(u8, trim_leading_chars, token[0]) != null) {
            token = token[1..];
            token_start += 1;
        }
        var trimmed_end = end;
        const trim_chars = cfg.trimTrailingOrDefault();
        while (token.len > 0 and std.mem.indexOfScalar(u8, trim_chars, token[token.len - 1]) != null) {
            token = token[0 .. token.len - 1];
            trimmed_end -= 1;
        }
        if (token.len == 0 or trimmed_end <= token_start) return null;

        const open_text = if (cfg.match_www and std.mem.startsWith(u8, token, "www.")) blk: {
            if (out.len < token.len + "https://".len) return null;
            @memcpy(out[0..8], "https://");
            @memcpy(out[8 .. 8 + token.len], token);
            break :blk out[0 .. 8 + token.len];
        } else token;

        var prefixes = std.mem.tokenizeScalar(u8, cfg.prefixesOrDefault(), ' ');
        while (prefixes.next()) |prefix| {
            if (prefix.len == 0) continue;
            if (std.mem.startsWith(u8, token, prefix)) return .{
                .text = token,
                .start_col = token_start,
                .end_col = trimmed_end,
                .open_text = open_text,
            };
        }

        if (cfg.match_www and std.mem.startsWith(u8, token, "www.")) return .{
            .text = token,
            .start_col = token_start,
            .end_col = trimmed_end,
            .open_text = open_text,
        };

        return null;
    }

    return null;
}

pub fn openHyperlinkAt(self: *App, pane: *Pane, point: CellPoint) void {
    if (!self.config.hyperlinks.enabled) return;
    var row_buf: [8192]u8 = undefined;
    const token = hyperlinkTokenAt(self, pane, point, &row_buf) orelse return;
    platform.openExternalWithOpenerAsync(token.open_text, self.config.hyperlinks.opener) catch |err| {
        std.log.err("open hyperlink failed: {s}", .{@errorName(err)});
    };
}

pub fn hasHyperlinkAt(self: *App, pane: *Pane, point: CellPoint) bool {
    var row_buf: [8192]u8 = undefined;
    return hyperlinkTokenAt(self, pane, point, &row_buf) != null;
}

pub fn isHoveringHyperlink(self: *const App, pane: *const Pane, row: usize, col: usize) bool {
    const hovered = self.hovered_hyperlink orelse return false;
    return hovered.pane == pane and hovered.row == row and col >= hovered.start_col and col < hovered.end_col;
}

pub fn updateHoveredHyperlink(self: *App) void {
    if (!self.hover_probe_dirty) return;
    self.hover_probe_dirty = false;
    self.hovered_hyperlink = null;
    if (!self.config.hyperlinks.enabled) return;
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
