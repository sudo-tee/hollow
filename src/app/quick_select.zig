const std = @import("std");
const c = @import("sokol_c");
const platform = @import("../platform.zig");
const text_helpers = @import("text_helpers.zig");
const hyperlinks = @import("hyperlinks.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Pane = @import("../pane.zig").Pane;

pub const label_alphabet = "asdfghjklqwertyuiopzxcvbnm";
pub const max_candidates = label_alphabet.len * label_alphabet.len;

pub const Action = enum {
    open,
    copy,
};

pub const Input = union(enum) {
    character: u8,
    backspace,
    cancel,
};

pub const Candidate = struct {
    row: usize,
    start_col: usize,
    end_col: usize,
    text: []u8,
    open_target: ?[]u8 = null,
    label: [2]u8 = undefined,
    label_len: u8 = 0,
};

pub fn inputActive(self: *const App) bool {
    return self.quick_select_input_active.load(.acquire);
}

pub fn armInput(self: *App) void {
    self.quick_select_input_active.store(true, .release);
}

pub fn disarmInput(self: *App) void {
    self.quick_select_input_active.store(false, .release);
}

pub fn start(self: *App, action: Action) void {
    resetState(self);
    if (!self.config.hyperlinks.enabled) {
        std.log.info("quick-select: disabled by hyperlinks.enabled=false", .{});
        return disarmInput(self);
    }
    const pane = self.activePane() orelse {
        std.log.info("quick-select: no active pane", .{});
        return disarmInput(self);
    };
    std.log.info("quick-select: start action={s} pane={x}", .{ @tagName(action), @intFromPtr(pane) });
    self.quick_select_pane = pane;
    self.quick_select_action = action;
    self.quick_select_layout_generation = self.currentLayoutGeneration();
    self.quick_select_pending_capture = true;
    self.quick_select_active = true;
    self.quick_select_input_active.store(true, .release);
    invalidatePane(self, pane);
    emitChanged(self);
    self.signalWake();
}

pub fn cancel(self: *App) void {
    const was_active = self.quick_select_active;
    const pane = self.quick_select_pane;
    resetState(self);
    disarmInput(self);
    if (pane) |value| if (self.hasPane(value)) invalidatePane(self, value);
    if (was_active) emitChanged(self);
    self.signalWake();
}

fn resetState(self: *App) void {
    clearCandidates(self);
    self.quick_select_pane = null;
    self.quick_select_prefix_len = 0;
    self.quick_select_pending_input_len = 0;
    self.quick_select_pending_capture = false;
    self.quick_select_active = false;
}

pub fn deinit(self: *App) void {
    resetState(self);
    disarmInput(self);
    self.quick_select_candidates.deinit(self.allocator);
}

pub fn pruneIfInvalid(self: *App) void {
    if (!self.quick_select_active) return;
    const pane = self.quick_select_pane orelse {
        cancel(self);
        return;
    };
    if (!self.hasPane(pane) or self.activePane() != pane) {
        cancel(self);
        return;
    }
    const generation = self.currentLayoutGeneration();
    if (generation != self.quick_select_layout_generation) {
        self.quick_select_layout_generation = generation;
        self.quick_select_prefix_len = 0;
        self.quick_select_pending_capture = true;
    }
}

pub fn refreshAfterPanes(self: *App) void {
    if (!self.quick_select_active) return;
    if (!inputActive(self)) return cancel(self);
    const pane = self.quick_select_pane orelse return cancel(self);
    if (!self.hasPane(pane)) return cancel(self);
    if (pane.pty_wrote_this_frame) {
        self.quick_select_prefix_len = 0;
        self.quick_select_pending_capture = true;
    }
    if (!self.quick_select_pending_capture) return;
    self.quick_select_pending_capture = false;
    capture(self, pane) catch |err| {
        std.log.err("quick select capture failed: {s}", .{@errorName(err)});
        cancel(self);
        return;
    };
    if (self.quick_select_candidates.items.len == 0) {
        std.log.info("quick-select: no matches", .{});
        self.emitLuaBuiltInEvent("quick_select:no_matches", .none);
        cancel(self);
        return;
    }
    assignLabels(self.quick_select_candidates.items);
    invalidatePane(self, pane);
    std.log.info("quick-select: captured {d} matches", .{self.quick_select_candidates.items.len});
    const pending_len = self.quick_select_pending_input_len;
    self.quick_select_pending_input_len = 0;
    for (self.quick_select_pending_inputs[0..pending_len]) |input| {
        if (!self.quick_select_active) break;
        handleInput(self, input);
    }
    self.signalWake();
}

fn emitChanged(self: *App) void {
    self.emitLuaBuiltInEvent("quick_select:changed", .{ .quick_select = .{
        .active = self.quick_select_active,
        .action = @tagName(self.quick_select_action),
    } });
}

pub fn handleInput(self: *App, input: Input) void {
    if (!self.quick_select_active) return;
    const pane = self.quick_select_pane orelse return cancel(self);
    if (!self.hasPane(pane)) return cancel(self);
    if (self.quick_select_pending_capture) {
        if (self.quick_select_pending_input_len < self.quick_select_pending_inputs.len) {
            self.quick_select_pending_inputs[self.quick_select_pending_input_len] = input;
            self.quick_select_pending_input_len += 1;
        }
        return;
    }
    switch (input) {
        .cancel => {
            cancel(self);
            return;
        },
        .backspace => {
            if (self.quick_select_prefix_len > 0) self.quick_select_prefix_len -= 1;
            invalidatePane(self, pane);
            self.signalWake();
            return;
        },
        .character => |ch| {
            if (std.mem.indexOfScalar(u8, label_alphabet, std.ascii.toLower(ch)) == null) return;
            if (self.quick_select_prefix_len >= self.quick_select_prefix.len) return;
            const normalized = std.ascii.toLower(ch);
            const prefix_len = self.quick_select_prefix_len + 1;
            self.quick_select_prefix[self.quick_select_prefix_len] = normalized;
            if (!hasPrefixMatch(self.quick_select_candidates.items, self.quick_select_prefix[0..prefix_len])) return;
            self.quick_select_prefix_len = prefix_len;
            invalidatePane(self, pane);
        },
    }

    const prefix = self.quick_select_prefix[0..self.quick_select_prefix_len];
    for (self.quick_select_candidates.items) |candidate| {
        if (candidate.label_len == prefix.len and std.mem.eql(u8, candidate.label[0..candidate.label_len], prefix)) {
            execute(self, candidate);
            return;
        }
    }
    self.signalWake();
}

pub fn candidateVisible(self: *const App, candidate: Candidate) bool {
    if (!self.quick_select_active or self.quick_select_pending_capture) return false;
    return std.mem.startsWith(u8, candidate.label[0..candidate.label_len], self.quick_select_prefix[0..self.quick_select_prefix_len]);
}

pub fn candidateLabelRemainder(self: *const App, candidate: *const Candidate) []const u8 {
    if (!candidateVisible(self, candidate.*)) return "";
    return candidate.label[self.quick_select_prefix_len..candidate.label_len];
}

fn execute(self: *App, candidate: Candidate) void {
    const action = self.quick_select_action;
    const text = candidate.text;
    const open_target = candidate.open_target orelse text;
    switch (action) {
        .open => platform.openExternalWithOpenerAsync(open_target, self.config.hyperlinks.opener) catch |err| {
            std.log.err("quick select open failed: {s}", .{@errorName(err)});
        },
        .copy => {
            const clipboard = self.allocator.alloc(u8, text.len + 1) catch {
                cancel(self);
                return;
            };
            defer self.allocator.free(clipboard);
            @memcpy(clipboard[0..text.len], text);
            clipboard[text.len] = 0;
            c.sapp_set_clipboard_string(@ptrCast(clipboard.ptr));
        },
    }
    cancel(self);
}

fn invalidatePane(self: *App, pane: *Pane) void {
    if (!self.hasPane(pane)) return;
    if (self.renderer) |*renderer| renderer.invalidatePaneCache(pane);
    pane.render_dirty = .full;
}

fn capture(self: *App, pane: *Pane) !void {
    clearCandidates(self);
    const runtime = if (self.ghostty) |*rt| rt else return;
    if (!App.paneRenderHelpersReady(pane)) return;
    if (!runtime.populateRowIterator(pane.render_state, &pane.row_iterator)) return;

    const col_capacity = @max(@as(usize, 1), @as(usize, pane.cols));
    const ascii_cols = try self.allocator.alloc(u8, col_capacity);
    defer self.allocator.free(ascii_cols);
    const covered = try self.allocator.alloc(bool, col_capacity);
    defer self.allocator.free(covered);

    var row: usize = 0;
    while (runtime.nextRow(pane.row_iterator) and self.quick_select_candidates.items.len < max_candidates) : (row += 1) {
        if (!runtime.populateRowCells(pane.row_iterator, &pane.row_cells)) continue;
        var col_count: usize = 0;
        while (runtime.nextCell(pane.row_cells) and col_count < ascii_cols.len) : (col_count += 1) {
            var cell_buf: [16]u8 = undefined;
            var cell_len: usize = 0;
            text_helpers.appendCellText(runtime, pane.row_cells, &cell_buf, &cell_len);
            ascii_cols[col_count] = if (cell_len == 1 and cell_buf[0] < 128) cell_buf[0] else 0;
        }
        try captureRow(self, pane, row, ascii_cols[0..col_count], covered[0..col_count]);
    }

    std.mem.sort(Candidate, self.quick_select_candidates.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            return a.row < b.row or (a.row == b.row and a.start_col < b.start_col);
        }
    }.lessThan);
}

fn captureRow(self: *App, pane: *Pane, row: usize, ascii_cols: []const u8, covered: []bool) !void {
    @memset(covered, false);
    var active_uri: ?[]u8 = null;
    var active_start: usize = 0;
    defer if (active_uri) |uri| self.allocator.free(uri);

    var col: usize = 0;
    while (col <= ascii_cols.len and self.quick_select_candidates.items.len < max_candidates) : (col += 1) {
        var uri_buf: [8192]u8 = undefined;
        const uri = if (col < ascii_cols.len) hyperlinks.hyperlinkUriAt(self, pane, .{ .row = row, .col = col }, &uri_buf) else null;
        const same = if (active_uri) |current| if (uri) |value| std.mem.eql(u8, current, value) else false else uri == null;
        if (same) continue;
        if (active_uri) |current| {
            for (covered[active_start..col]) |*value| value.* = true;
            active_uri = null;
            try appendOwnedCandidate(self, .{ .row = row, .start_col = active_start, .end_col = col, .text = current });
        }
        if (uri) |value| {
            active_uri = try self.allocator.dupe(u8, value);
            active_start = col;
        }
    }

    const cfg = self.config.hyperlinks;
    const delimiters = cfg.delimitersOrDefault();
    var token_scan_start: usize = 0;
    while (token_scan_start < ascii_cols.len and self.quick_select_candidates.items.len < max_candidates) {
        while (token_scan_start < ascii_cols.len and isDelimiter(delimiters, ascii_cols[token_scan_start])) token_scan_start += 1;
        if (token_scan_start >= ascii_cols.len) break;
        var end = token_scan_start;
        while (end < ascii_cols.len and !isDelimiter(delimiters, ascii_cols[end])) end += 1;
        var token_start = token_scan_start;
        var token_end = end;
        while (token_start < token_end and std.mem.indexOfScalar(u8, cfg.trimLeadingOrDefault(), ascii_cols[token_start]) != null) token_start += 1;
        while (token_end > token_start and std.mem.indexOfScalar(u8, cfg.trimTrailingOrDefault(), ascii_cols[token_end - 1]) != null) token_end -= 1;
        const token = ascii_cols[token_start..token_end];
        const token_complete = end == ascii_cols.len or ascii_cols[end] != 0;
        if (token_complete and token.len > 0 and !rangeCovered(covered, token_start, token_end) and isConfiguredLink(cfg.prefixesOrDefault(), cfg.match_www, token)) {
            const owned = try self.allocator.dupe(u8, token);
            var open_target: ?[]u8 = null;
            if (cfg.match_www and std.mem.startsWith(u8, token, "www.")) {
                open_target = std.mem.concat(self.allocator, u8, &.{ "https://", token }) catch |err| {
                    self.allocator.free(owned);
                    return err;
                };
            }
            try appendOwnedCandidate(self, .{
                .row = row,
                .start_col = token_start,
                .end_col = token_end,
                .text = owned,
                .open_target = open_target,
            });
        }
        token_scan_start = @max(end, token_scan_start + 1);
    }
}

fn appendOwnedCandidate(self: *App, candidate: Candidate) !void {
    if (self.quick_select_candidates.items.len >= max_candidates) {
        self.allocator.free(candidate.text);
        if (candidate.open_target) |value| self.allocator.free(value);
        return;
    }
    self.quick_select_candidates.append(self.allocator, candidate) catch |err| {
        self.allocator.free(candidate.text);
        if (candidate.open_target) |value| self.allocator.free(value);
        return err;
    };
}

fn clearCandidates(self: *App) void {
    for (self.quick_select_candidates.items) |candidate| {
        self.allocator.free(candidate.text);
        if (candidate.open_target) |value| self.allocator.free(value);
    }
    self.quick_select_candidates.clearRetainingCapacity();
}

fn isDelimiter(delimiters: []const u8, ch: u8) bool {
    return ch == 0 or std.mem.indexOfScalar(u8, delimiters, ch) != null;
}

fn rangeCovered(covered: []const bool, range_start: usize, range_end: usize) bool {
    for (covered[range_start..range_end]) |value| if (value) return true;
    return false;
}

fn isConfiguredLink(prefix_list: []const u8, match_www: bool, token: []const u8) bool {
    if (match_www and std.mem.startsWith(u8, token, "www.")) return true;
    var prefixes = std.mem.tokenizeScalar(u8, prefix_list, ' ');
    while (prefixes.next()) |prefix| {
        if (prefix.len > 0 and std.mem.startsWith(u8, token, prefix)) return true;
    }
    return false;
}

fn assignLabels(candidates: []Candidate) void {
    const width: usize = if (candidates.len <= label_alphabet.len) 1 else 2;
    for (candidates, 0..) |*candidate, index| {
        if (width == 1) {
            candidate.label[0] = label_alphabet[index];
        } else {
            candidate.label[0] = label_alphabet[index / label_alphabet.len];
            candidate.label[1] = label_alphabet[index % label_alphabet.len];
        }
        candidate.label_len = @intCast(width);
    }
}

fn hasPrefixMatch(candidates: []const Candidate, prefix: []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.startsWith(u8, candidate.label[0..candidate.label_len], prefix)) return true;
    }
    return false;
}

test "quick select labels use shortest fixed width" {
    var short: [2]Candidate = undefined;
    assignLabels(&short);
    try std.testing.expectEqualStrings("a", short[0].label[0..short[0].label_len]);
    try std.testing.expectEqualStrings("s", short[1].label[0..short[1].label_len]);

    var long: [27]Candidate = undefined;
    assignLabels(&long);
    try std.testing.expectEqualStrings("aa", long[0].label[0..long[0].label_len]);
    try std.testing.expectEqualStrings("sa", long[26].label[0..long[26].label_len]);
}

test "quick select prefix matching" {
    var candidates: [27]Candidate = undefined;
    assignLabels(&candidates);
    try std.testing.expect(hasPrefixMatch(&candidates, "a"));
    try std.testing.expect(hasPrefixMatch(&candidates, "sa"));
    try std.testing.expect(!hasPrefixMatch(&candidates, "zz"));
}
