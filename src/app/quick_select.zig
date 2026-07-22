const std = @import("std");
const c = @import("sokol_c");
const platform = @import("../platform.zig");
const text_helpers = @import("text_helpers.zig");
const hyperlinks = @import("hyperlinks.zig");
const lua_bridge = @import("../lua_bridge.zig");
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

pub const CandidateKind = enum {
    url,
    ip,
    quote,
    filename,
    custom,
};

pub const Candidate = struct {
    row: usize,
    start_col: usize,
    end_col: usize,
    text: []u8,
    open_target: ?[]u8 = null,
    default_action: Action,
    kind: CandidateKind,
    pattern_index: usize = 0,
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
    var action = selectedAction(self.quick_select_action, candidate.default_action);
    const text = candidate.text;
    const open_target = candidate.open_target orelse text;
    if (self.quick_select_action != .copy) {
        if (self.lua) |*lua| {
            var command: std.ArrayListUnmanaged([]u8) = .empty;
            defer {
                for (command.items) |arg| self.allocator.free(arg);
                command.deinit(self.allocator);
            }
            switch (lua.runQuickSelectAction(@tagName(candidate.kind), candidate.pattern_index, text, @tagName(candidate.default_action), &command)) {
                .open => action = .open,
                .copy => action = .copy,
                .handled => return finishAction(self, candidate, "callback"),
                .command => {
                    platform.runCommandAsync(command.items) catch |err| {
                        std.log.err("quick select command failed: {s}", .{@errorName(err)});
                        return;
                    };
                    return finishAction(self, candidate, "command");
                },
                .failed => return,
                .fallback => {},
            }
        }
    }
    switch (action) {
        .open => platform.openExternalWithOpenerAsync(open_target, self.config.hyperlinks.opener) catch |err| {
            std.log.err("quick select open failed: {s}", .{@errorName(err)});
            return;
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
    finishAction(self, candidate, @tagName(action));
}

fn finishAction(self: *App, candidate: Candidate, action: []const u8) void {
    const text = self.allocator.dupe(u8, candidate.text) catch {
        cancel(self);
        return;
    };
    defer self.allocator.free(text);
    const kind = @tagName(candidate.kind);
    const pattern_index: ?usize = if (candidate.kind == .custom) candidate.pattern_index else null;
    cancel(self);
    self.emitLuaBuiltInEvent("quick_select:action_executed", .{ .quick_select_action = .{
        .text = text,
        .kind = kind,
        .action = action,
        .pattern_index = pattern_index,
    } });
}

fn selectedAction(mode_action: Action, candidate_action: Action) Action {
    return if (mode_action == .copy) .copy else candidate_action;
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
    const cfg = self.config.hyperlinks;
    var active_uri: ?[]u8 = null;
    var active_start: usize = 0;
    defer if (active_uri) |uri| self.allocator.free(uri);

    if (cfg.enabled) {
        var col: usize = 0;
        while (col <= ascii_cols.len and self.quick_select_candidates.items.len < max_candidates) : (col += 1) {
            var uri_buf: [8192]u8 = undefined;
            const uri = if (col < ascii_cols.len) hyperlinks.hyperlinkUriAt(self, pane, .{ .row = row, .col = col }, &uri_buf) else null;
            const same = if (active_uri) |current| if (uri) |value| std.mem.eql(u8, current, value) else false else uri == null;
            if (same) continue;
            if (active_uri) |current| {
                markCovered(covered, active_start, col);
                active_uri = null;
                try appendOwnedCandidate(self, .{ .row = row, .start_col = active_start, .end_col = col, .text = current, .default_action = .open, .kind = .url });
            }
            if (uri) |value| {
                active_uri = try self.allocator.dupe(u8, value);
                active_start = col;
            }
        }
    }

    const delimiters = cfg.delimitersOrDefault();
    var token_scan_start: usize = 0;
    while (cfg.enabled and token_scan_start < ascii_cols.len and self.quick_select_candidates.items.len < max_candidates) {
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
                .default_action = .open,
                .kind = .url,
            });
            markCovered(covered, token_start, token_end);
        }
        token_scan_start = @max(end, token_scan_start + 1);
    }

    try captureConfiguredPatterns(self, row, ascii_cols, covered);

    var quote_start: usize = 0;
    while (quote_start < ascii_cols.len and self.quick_select_candidates.items.len < max_candidates) : (quote_start += 1) {
        const quote = ascii_cols[quote_start];
        if (quote != '\'' and quote != '"' and quote != '`') continue;
        const quote_end = findClosingQuote(ascii_cols, quote_start + 1, quote) orelse continue;
        const content_start = quote_start + 1;
        if (content_start < quote_end and std.mem.indexOfScalar(u8, ascii_cols[content_start..quote_end], 0) == null and !rangeCovered(covered, quote_start, quote_end + 1)) {
            const owned = try self.allocator.dupe(u8, ascii_cols[content_start..quote_end]);
            try appendOwnedCandidate(self, .{
                .row = row,
                .start_col = content_start,
                .end_col = quote_end,
                .text = owned,
                .default_action = .copy,
                .kind = .quote,
            });
            markCovered(covered, quote_start, quote_end + 1);
        }
        quote_start = quote_end;
    }

    var copy_scan_start: usize = 0;
    while (copy_scan_start < ascii_cols.len and self.quick_select_candidates.items.len < max_candidates) {
        while (copy_scan_start < ascii_cols.len and isCopyTokenDelimiter(ascii_cols[copy_scan_start])) copy_scan_start += 1;
        if (copy_scan_start >= ascii_cols.len) break;
        var copy_end = copy_scan_start;
        while (copy_end < ascii_cols.len and !isCopyTokenDelimiter(ascii_cols[copy_end])) copy_end += 1;
        const raw_copy_end = copy_end;
        var copy_start = copy_scan_start;
        while (copy_start < copy_end and isCopyTokenTrim(ascii_cols[copy_start])) copy_start += 1;
        while (copy_end > copy_start and isCopyTokenTrim(ascii_cols[copy_end - 1])) copy_end -= 1;
        var token = ascii_cols[copy_start..copy_end];
        if (std.mem.lastIndexOfScalar(u8, token, '=')) |equals| {
            const value = token[equals + 1 ..];
            if (isIpAddress(value) or isFilename(value)) {
                copy_start += equals + 1;
                token = value;
            }
        }
        const token_complete = raw_copy_end == ascii_cols.len or ascii_cols[raw_copy_end] != 0;
        const kind: ?CandidateKind = if (isIpAddress(token)) .ip else if (isFilename(token)) .filename else null;
        if (token_complete and token.len > 0 and !rangeCovered(covered, copy_start, copy_end) and kind != null) {
            const owned = try self.allocator.dupe(u8, token);
            try appendOwnedCandidate(self, .{
                .row = row,
                .start_col = copy_start,
                .end_col = copy_end,
                .text = owned,
                .default_action = .copy,
                .kind = kind.?,
            });
            markCovered(covered, copy_start, copy_end);
        }
        copy_scan_start = @max(raw_copy_end, copy_scan_start + 1);
    }
}

fn captureConfiguredPatterns(self: *App, row: usize, ascii_cols: []const u8, covered: []bool) !void {
    const lua = if (self.lua) |*runtime| runtime else return;
    var matches: std.ArrayListUnmanaged(lua_bridge.QuickSelectMatch) = .empty;
    defer matches.deinit(self.allocator);
    lua.resolveQuickSelectMatches(ascii_cols, &matches);
    std.mem.sort(lua_bridge.QuickSelectMatch, matches.items, {}, struct {
        fn lessThan(_: void, a: lua_bridge.QuickSelectMatch, b: lua_bridge.QuickSelectMatch) bool {
            return a.pattern_index < b.pattern_index or (a.pattern_index == b.pattern_index and a.start_col < b.start_col);
        }
    }.lessThan);

    var match_index: usize = 0;
    errdefer for (matches.items[match_index + 1 ..]) |match| self.allocator.free(match.text);
    while (match_index < matches.items.len) : (match_index += 1) {
        const match = matches.items[match_index];
        if (match.end_col > ascii_cols.len or match.end_col <= match.start_col or std.mem.indexOfScalar(u8, match.text, 0) != null or rangeCovered(covered, match.start_col, match.end_col)) {
            self.allocator.free(match.text);
            continue;
        }
        try appendOwnedCandidate(self, .{
            .row = row,
            .start_col = match.start_col,
            .end_col = match.end_col,
            .text = match.text,
            .default_action = .copy,
            .kind = .custom,
            .pattern_index = match.pattern_index,
        });
        markCovered(covered, match.start_col, match.end_col);
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

fn markCovered(covered: []bool, range_start: usize, range_end: usize) void {
    for (covered[range_start..range_end]) |*value| value.* = true;
}

fn findClosingQuote(text: []const u8, search_start: usize, quote: u8) ?usize {
    var index = search_start;
    while (index < text.len) : (index += 1) {
        if (text[index] != quote) continue;
        var slash_count: usize = 0;
        var previous = index;
        while (previous > search_start and text[previous - 1] == '\\') : (previous -= 1) slash_count += 1;
        if (slash_count % 2 == 0) return index;
    }
    return null;
}

fn isCopyTokenDelimiter(ch: u8) bool {
    return ch == 0 or std.ascii.isWhitespace(ch) or std.mem.indexOfScalar(u8, "\"'`<>|", ch) != null;
}

fn isCopyTokenTrim(ch: u8) bool {
    return std.mem.indexOfScalar(u8, ",;!?()[]{}", ch) != null;
}

fn isIpAddress(token: []const u8) bool {
    var address = token;
    if (std.mem.lastIndexOfScalar(u8, token, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, token, ':') != colon) return false;
        const port = token[colon + 1 ..];
        if (port.len == 0 or port.len > 5) return false;
        const port_number = std.fmt.parseInt(u16, port, 10) catch return false;
        if (port_number == 0) return false;
        address = token[0..colon];
    }

    var octets = std.mem.splitScalar(u8, address, '.');
    var count: usize = 0;
    while (octets.next()) |octet| {
        if (octet.len == 0 or octet.len > 3) return false;
        _ = std.fmt.parseInt(u8, octet, 10) catch return false;
        count += 1;
    }
    return count == 4;
}

fn isFilename(token: []const u8) bool {
    if (token.len < 2) return false;
    if (std.mem.indexOf(u8, token, "://") != null) return false;
    var path = token;
    var location_parts: usize = 0;
    while (location_parts < 2) : (location_parts += 1) {
        const colon = std.mem.lastIndexOfScalar(u8, path, ':') orelse break;
        const suffix = path[colon + 1 ..];
        if (suffix.len == 0) break;
        var numeric = true;
        for (suffix) |ch| if (!std.ascii.isDigit(ch)) {
            numeric = false;
            break;
        };
        if (!numeric) break;
        path = path[0..colon];
    }
    if (path.len < 2) return false;
    if (std.mem.startsWith(u8, path, "/") or std.mem.startsWith(u8, path, "./") or std.mem.startsWith(u8, path, "../") or std.mem.startsWith(u8, path, "~/")) return path[path.len - 1] != '/' and containsAlphabetic(path);
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) return path[path.len - 1] != '\\' and path[path.len - 1] != '/';
    if (std.mem.indexOfAny(u8, path, "/\\") != null) return path[path.len - 1] != '\\' and path[path.len - 1] != '/' and containsAlphabetic(path);
    if (path[0] == '.') return path.len > 1 and path[1] != '.' and (std.ascii.isAlphabetic(path[1]) or path[1] == '_');
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    if (dot == 0 or dot + 1 >= path.len or path.len - dot - 1 > 16) return false;
    if (!std.ascii.isAlphabetic(path[dot + 1])) return false;
    for (path[dot + 1 ..]) |ch| if (!std.ascii.isAlphanumeric(ch)) return false;
    return true;
}

fn containsAlphabetic(text: []const u8) bool {
    for (text) |ch| if (std.ascii.isAlphabetic(ch)) return true;
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

test "quick select pattern actions" {
    try std.testing.expectEqual(Action.open, selectedAction(.open, .open));
    try std.testing.expectEqual(Action.copy, selectedAction(.open, .copy));
    try std.testing.expectEqual(Action.copy, selectedAction(.copy, .open));
}

test "quick select recognizes IPv4 addresses" {
    try std.testing.expect(isIpAddress("127.0.0.1"));
    try std.testing.expect(isIpAddress("192.168.1.20:8080"));
    try std.testing.expect(!isIpAddress("256.1.1.1"));
    try std.testing.expect(!isIpAddress("1.2.3"));
    try std.testing.expect(!isIpAddress("1.2.3.4:0"));
}

test "quick select recognizes filenames and paths" {
    try std.testing.expect(isFilename("src/main.zig"));
    try std.testing.expect(isFilename("./build.sh"));
    try std.testing.expect(isFilename("C:\\Users\\me\\notes.txt"));
    try std.testing.expect(isFilename("config.lua:42:7"));
    try std.testing.expect(isFilename("README.md"));
    try std.testing.expect(isFilename(".gitignore"));
    try std.testing.expect(!isFilename("README"));
    try std.testing.expect(!isFilename("directory/"));
    try std.testing.expect(!isFilename("3/4"));
    try std.testing.expect(!isFilename(".5"));
    try std.testing.expect(!isFilename("v1.2"));
    try std.testing.expect(!isFilename("https://example.com"));
}

test "quick select finds closing quotes" {
    try std.testing.expectEqual(@as(?usize, 6), findClosingQuote("'hello'", 1, '\''));
    try std.testing.expectEqual(@as(?usize, 9), findClosingQuote("\"say \\\"hi\"", 1, '"'));
    try std.testing.expectEqual(@as(?usize, 7), findClosingQuote("\"path\\\\\"", 1, '"'));
    try std.testing.expectEqual(@as(?usize, null), findClosingQuote("`open", 1, '`'));
}
