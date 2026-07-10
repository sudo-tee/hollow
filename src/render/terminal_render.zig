/// Terminal rendering (terminal -> sokol_gl quads).
///
/// Extracted from ft_renderer.zig for code organisation.  Contains the
/// terminal-rendering pipeline (pass 1 background/rasterise, pass 2 glyph draw).

const std = @import("std");
const builtin = @import("builtin");
const c = @import("sokol_c");
const fastmem = @import("../fastmem.zig");
const ghostty = @import("../term/ghostty.zig");

const Config = @import("../config.zig").Config;
const App = @import("../app.zig").App;
const CopyModeSnapshotLine = @import("../app/copy_mode.zig").CopyModeSnapshotLine;
const SearchHighlight = @import("../app/copy_mode.zig").SearchHighlight;
const copy_mode = @import("../app/copy_mode.zig");
const Pane = @import("../pane.zig").Pane;
const selection = @import("../selection.zig");

const color_math = @import("color_math.zig");
const text_util = @import("text_util.zig");
const font_discovery = @import("font_discovery.zig");
const synth_glyphs = @import("synth_glyphs.zig");
const ft_types = @import("ft_types.zig");
const FtRenderer = @import("ft_renderer.zig").FtRenderer;

const mixColor = color_math.mixColor;
const rowSelectionBounds = color_math.rowSelectionBounds;
const effectiveCursorStyle = color_math.effectiveCursorStyle;
const effectiveCursorColor = color_math.effectiveCursorColor;
const contrastTextColor = color_math.contrastTextColor;
const colorsEqual = color_math.colorsEqual;
const RowSelectionBounds = color_math.RowSelectionBounds;

const encodeUtf8 = text_util.encodeUtf8;

const firstRenderableCodepoint = font_discovery.firstRenderableCodepoint;

const isSynthesizedTerminalCodepoint = synth_glyphs.isSynthesizedTerminalCodepoint;
const drawSynthesizedTerminalCodepoint = synth_glyphs.drawSynthesizedTerminalCodepoint;
const drawSynthesizedTerminalUtf8 = synth_glyphs.drawSynthesizedTerminalUtf8;

const CachedStyleInfo = ft_types.CachedStyleInfo;
const Glyph = ft_types.Glyph;
const RasterMode = ft_types.RasterMode;
const ShapeResult = ft_types.ShapeResult;
const PreparedRun = ft_types.PreparedRun;
const PreparedGlyph = ft_types.PreparedGlyph;

// ── Types (moved from inside FtRenderer) ──────────────────────────────────────

const HASH_SKIP_MAX_ROWS = 512;
const HASH_SKIP_WORDS = HASH_SKIP_MAX_ROWS / 64;
const HashSkipBits = [HASH_SKIP_WORDS]u64;

const QueueColors = struct {
    default_bg: ghostty.ColorRgb,
    default_fg: ghostty.ColorRgb,
    cursor_bg: ghostty.ColorRgb,
    cursor_fg: ghostty.ColorRgb,
    selection_bg: ghostty.ColorRgb,
    selection_fg: ghostty.ColorRgb,
    search_bg: ghostty.ColorRgb,
    search_active_bg: ghostty.ColorRgb,
    palette: *const [256]ghostty.ColorRgb,
};

const QueueContext = struct {
    cfg: *const Config,
    app: *const App,
    pane: ?*const Pane,
    render_state: ?*anyopaque,
    row_iterator: *?*anyopaque,
    row_cells: *?*anyopaque,
    row_count: usize,
    col_count: usize,
    force_full: bool,
    selection_range: ?selection.Range,
    hovered_hyperlink: ?App.HoveredHyperlink,
    prev_cursor_row: usize,
    cursor_row: usize,
    cursor_col: usize,
    cursor_style: ?ghostty.CursorVisualStyle,
    cursor_wide: bool,
    hovered_row: usize,
    row_map_keys: ?[]u64,
    row_map_vals: ?[]u64,
    row_map_skip: bool,
    colors: QueueColors,

    inline fn useRowMap(self: @This()) bool {
        return self.row_map_keys != null and self.row_map_vals != null;
    }

    inline fn helpersReady(self: @This()) bool {
        return self.render_state != null and self.row_iterator.* != null and self.row_cells.* != null;
    }
};

const RowRenderInfo = struct {
    row_y: usize,
    py: f32,
    selection: ?RowSelectionBounds,
    search_highlight: ?SearchHighlight,
    cursor_col: ?usize,
    cursor_wide: bool,
};

const CellTextStyle = struct {
    face_idx: u8,
    fg: ghostty.ColorRgb,
    needs_decorations: bool = false,
};

const GlyphRunMode = enum {
    raster,
    draw,
};

const GlyphRunState = struct {
    start_col: usize = 0,
    len: usize = 0,
    face_idx: u8 = 0,
    fg: ghostty.ColorRgb,
};

const Pass2Stats = struct {
    glyph_ns: i128 = 0,
    decoration_ns: i128 = 0,
};

// ── Entry points ──────────────────────────────────────────────────────────────

pub fn queueInViewport(
    self: *FtRenderer,
    runtime: *ghostty.Runtime,
    cfg: *const Config,
    app: *const App,
    pane: ?*const Pane,
    terminal: ?*anyopaque,
    render_state: ?*anyopaque,
    row_iterator: *?*anyopaque,
    row_cells: *?*anyopaque,
    offset_x: f32,
    offset_y: f32,
    pane_w: f32,
    pane_h: f32,
    fb_w: f32,
    fb_h: f32,
    is_focused: bool,
    force_full: bool,
    row_map_keys: ?[]u64,
    row_map_vals: ?[]u64,
    row_map_skip: bool,
    selection_range: ?selection.Range,
    hovered_hyperlink: ?App.HoveredHyperlink,
    prev_cursor_row: usize,
) void {
    _ = fb_w;
    _ = fb_h;
    _ = terminal;
    const render_colors = if (cfg.terminal_theme.enabled) null else blk: {
        if (!runtime.renderStateColorsInto(render_state, &self.render_colors_scratch)) return;
        break :blk &self.render_colors_scratch;
    };
    const default_bg = if (cfg.terminal_theme.enabled) cfg.terminal_theme.background else render_colors.?.background;
    const default_fg = if (cfg.terminal_theme.enabled) cfg.terminal_theme.foreground else render_colors.?.foreground;
    const raw_cursor_color: ghostty.ColorRgb = if (cfg.terminal_theme.enabled)
        (cfg.terminal_theme.cursor orelse .{ .r = 220, .g = 220, .b = 220 })
    else if (render_colors.?.cursor_has_value)
        render_colors.?.cursor
    else
        .{ .r = 220, .g = 220, .b = 220 };
    const cursor_style = effectiveCursorStyle(runtime, render_state, pane, app, is_focused);
    const cursor_wide = runtime.cursorWideTail(render_state);
    const cursor_bg = effectiveCursorColor(raw_cursor_color, default_bg);
    const selection_bg = if (cfg.terminal_theme.enabled)
        (cfg.terminal_theme.selection_bg orelse mixColor(default_bg, default_fg, 0.35))
    else
        mixColor(default_bg, default_fg, 0.35);
    const search_bg = mixColor(default_bg, default_fg, 0.18);
    const search_active_bg = mixColor(default_bg, default_fg, 0.42);
    const queue = QueueContext{
        .cfg = cfg,
        .pane = pane,
        .render_state = render_state,
        .row_iterator = row_iterator,
        .row_cells = row_cells,
        .row_count = @intCast(runtime.renderStateRows(render_state) orelse 0),
        .col_count = @intCast(runtime.renderStateCols(render_state) orelse 0),
        .force_full = force_full,
        .app = app,
        .selection_range = selection_range,
        .hovered_hyperlink = hovered_hyperlink,
        .prev_cursor_row = prev_cursor_row,
        .cursor_row = if (runtime.cursorPos(render_state)) |cp| @intCast(cp.y) else std.math.maxInt(usize),
        .cursor_col = if (runtime.cursorPos(render_state)) |cp| @intCast(cp.x) else std.math.maxInt(usize),
        .cursor_style = cursor_style,
        .cursor_wide = cursor_wide,
        .hovered_row = if (hovered_hyperlink) |hovered| hovered.row else std.math.maxInt(usize),
        .row_map_keys = row_map_keys,
        .row_map_vals = row_map_vals,
        .row_map_skip = row_map_skip,
        .colors = .{
            .default_bg = default_bg,
            .default_fg = default_fg,
            .cursor_bg = cursor_bg,
            .cursor_fg = if (cfg.terminal_theme.enabled)
                (cfg.terminal_theme.cursor_fg orelse contrastTextColor(cursor_bg))
            else
                contrastTextColor(cursor_bg),
            .selection_bg = selection_bg,
            .selection_fg = if (cfg.terminal_theme.enabled)
                (cfg.terminal_theme.selection_fg orelse default_fg)
            else
                default_fg,
            .search_bg = search_bg,
            .search_active_bg = search_active_bg,
            .palette = if (cfg.terminal_theme.enabled) &cfg.terminal_theme.palette else &render_colors.?.palette,
        },
    };

    setupViewport(self, offset_x, offset_y, pane_w, pane_h);

    if (!self.logged_first_draw) {
        std.log.info("ft_renderer first draw: screen={d:.0}x{d:.0} cell={d:.1}x{d:.1}", .{
            pane_w, pane_h, self.cell_w, self.cell_h,
        });
    }

    if (!ensureRunBufferCapacity(self, queue.row_count, queue.col_count)) return;
    const run_buf = self.run_buf;
    resetQueueState(self);

    var hash_skip_bits: HashSkipBits = [_]u64{0} ** HASH_SKIP_WORDS;

    const t_pass1_start = if (cfg.debug_overlay) std.time.nanoTimestamp() else 0;
    queueBackgroundAndRasterPass(self, runtime, &queue, pane_w, pane_h, &hash_skip_bits, run_buf);

    if (self.atlas_dirty and !self.atlas_uploaded_this_frame) {
        self.flushAtlas();
        self.atlas_dirty = false;
        self.last_atlas_flushed = true;
    }
    const t_pass2_start = if (cfg.debug_overlay) std.time.nanoTimestamp() else 0;
    var pass2_glyph_ns: i128 = 0;
    var pass2_decoration_ns: i128 = 0;

    const pass2_stats = queueGlyphPass(self, runtime, &queue, &hash_skip_bits, run_buf);
    pass2_glyph_ns = pass2_stats.glyph_ns;
    pass2_decoration_ns = pass2_stats.decoration_ns;

    if (!self.logged_first_draw) self.logged_first_draw = true;
    if (self.frame_count <= 3) {
        std.log.info("ft_renderer queueInViewport done: frame={d} glyph_verts={d} rows_rendered={d} bg_rects={d}", .{
            self.frame_count, self.glyph_verts_count, self.last_rows_rendered, self.last_bg_rects,
        });
    }
    const t_pass2_end = if (cfg.debug_overlay) std.time.nanoTimestamp() else 0;

    if (cfg.debug_overlay) {
        self.last_pass1_ns = t_pass2_start - t_pass1_start;
        self.last_pass2_ns = t_pass2_end - t_pass2_start;
    }

    self.last_pass2_glyph_ns = pass2_glyph_ns;
    self.last_pass2_decoration_ns = pass2_decoration_ns;
}

pub fn queueCopyModeSnapshot(
    self: *FtRenderer,
    cfg: *const Config,
    app: *const App,
    pane: *const Pane,
    offset_x: f32,
    offset_y: f32,
    pane_w: f32,
    pane_h: f32,
) void {
    const default_bg = if (cfg.terminal_theme.enabled) cfg.terminal_theme.background else ghostty.ColorRgb{ .r = 0, .g = 0, .b = 0 };
    const default_fg = if (cfg.terminal_theme.enabled) cfg.terminal_theme.foreground else ghostty.ColorRgb{ .r = 220, .g = 220, .b = 220 };
    const selection_bg = if (cfg.terminal_theme.enabled)
        (cfg.terminal_theme.selection_bg orelse mixColor(default_bg, default_fg, 0.35))
    else
        mixColor(default_bg, default_fg, 0.35);
    const selection_fg = if (cfg.terminal_theme.enabled)
        (cfg.terminal_theme.selection_fg orelse default_fg)
    else
        default_fg;
    const search_bg = mixColor(default_bg, default_fg, 0.18);
    const search_active_bg = mixColor(default_bg, default_fg, 0.42);    const selection_range = copy_mode.copyModeSelectionRange(app, pane);

    setupViewport(self, offset_x, offset_y, pane_w, pane_h);
    resetQueueState(self);
    if (!ensureRunBufferCapacity(self, @max(@as(usize, 1), @as(usize, pane.rows)), @max(@as(usize, 1), @as(usize, pane.cols)))) return;
    const run_buf = self.run_buf;

    c.sgl_load_default_pipeline();
    c.sgl_begin_quads();
    emitRect(0.0, 0.0, pane_w, pane_h, default_bg.r, default_bg.g, default_bg.b, 255);

    const visible_rows = @max(@as(usize, 1), @as(usize, pane.rows));
    var row: usize = 0;
    while (row < visible_rows) : (row += 1) {
        const row_info = makeCopyModeSnapshotRowInfo(self, app, pane, selection_range, row, visible_rows);
        const line = copy_mode.copyModeSnapshotLineForRow(app,pane, row);
        queueCopyModeSnapshotRowBackground(self, line, row_info, default_bg, cfg, selection_bg, search_bg, search_active_bg, selection_fg);
    }
    c.sgl_end();

    row = 0;
    while (row < visible_rows) : (row += 1) {
        const line = copy_mode.copyModeSnapshotLineForRow(app,pane, row) orelse continue;
        const row_info = makeCopyModeSnapshotRowInfo(self, app, pane, selection_range, row, visible_rows);
        queueCopyModeSnapshotRowText(self, line, row_info, cfg, default_fg, selection_fg, run_buf, .raster);
    }

    if (self.atlas_dirty and !self.atlas_uploaded_this_frame) {
        self.flushAtlas();
        self.atlas_dirty = false;
        self.last_atlas_flushed = true;
    }

    row = 0;
    while (row < visible_rows) : (row += 1) {
        const line = copy_mode.copyModeSnapshotLineForRow(app,pane, row) orelse continue;
        const row_info = makeCopyModeSnapshotRowInfo(self, app, pane, selection_range, row, visible_rows);
        queueCopyModeSnapshotRowText(self, line, row_info, cfg, default_fg, selection_fg, run_buf, .draw);
    }
}

// ── Copy-mode helpers ─────────────────────────────────────────────────────────

pub fn makeCopyModeSnapshotRowInfo(
    self: *FtRenderer,
    app: *const App,
    pane: *const Pane,
    selection_range: ?selection.Range,
    row: usize,
    visible_rows: usize,
) RowRenderInfo {
    _ = visible_rows;
    const row_y_px = @as(f32, @floatFromInt(row)) * self.cell_h;
    return .{
        .row_y = row,
        .py = self.padding_y + row_y_px,
        .selection = if (selection_range) |range| rowSelectionBounds(range, row) else null,
        .search_highlight = copy_mode.searchHighlightForRow(app, pane, row),
        .cursor_col = copy_mode.copyModeCursorColForRow(app, pane, row),
    };
}

pub fn queueCopyModeSnapshotRowBackground(
    self: *FtRenderer,
    line: ?CopyModeSnapshotLine,
    row: RowRenderInfo,
    default_bg: ghostty.ColorRgb,
    cfg: *const Config,
    selection_bg: ghostty.ColorRgb,
    search_bg: ghostty.ColorRgb,
    search_active_bg: ghostty.ColorRgb,
    selection_fg: ghostty.ColorRgb,
) void {
    if (line) |snapshot| {
        for (snapshot.cells, 0..) |cell, col| {
            const bg = if (cell.bg_style.tag != .none)
                ghostty.resolveStyleColor(cell.bg_style, default_bg, &cfg.terminal_theme.palette)
            else
                cell.bg orelse continue;
            const x = self.padding_x + @as(f32, @floatFromInt(col)) * self.cell_w;
            emitRect(x, row.py, self.cell_w, self.cell_h, bg.r, bg.g, bg.b, 255);
        }
    }
    if (row.selection) |bounds| {
        const start_x = self.padding_x + @as(f32, @floatFromInt(bounds.start_col)) * self.cell_w;
        const end_x = self.padding_x + @as(f32, @floatFromInt(bounds.end_col + 1)) * self.cell_w;
        emitRect(start_x, row.py, @max(0.0, end_x - start_x), self.cell_h, selection_bg.r, selection_bg.g, selection_bg.b, 255);
    }
    if (row.search_highlight) |highlight| {
        const bg = if (highlight.active) search_active_bg else search_bg;
        const start_x = self.padding_x + @as(f32, @floatFromInt(highlight.start_col)) * self.cell_w;
        const end_x = self.padding_x + @as(f32, @floatFromInt(highlight.end_col)) * self.cell_w;
        emitRect(start_x, row.py, @max(0.0, end_x - start_x), self.cell_h, bg.r, bg.g, bg.b, 255);
    }
    if (row.cursor_col) |cursor_col| {
        const cursor_x = self.padding_x + @as(f32, @floatFromInt(cursor_col)) * self.cell_w;
        emitRect(cursor_x, row.py, self.cell_w, self.cell_h, selection_fg.r, selection_fg.g, selection_fg.b, 96);
    }
}

pub fn queueCopyModeSnapshotRowText(
    self: *FtRenderer,
    line: CopyModeSnapshotLine,
    row: RowRenderInfo,
    cfg: *const Config,
    default_fg: ghostty.ColorRgb,
    selection_fg: ghostty.ColorRgb,
    run_buf: []u8,
    mode: GlyphRunMode,
) void {
    var run = GlyphRunState{ .fg = default_fg };
    for (line.cells, 0..) |cell, col| {
        if (col >= line.cols) break;
        const resolved_fg = if (cell.fg_style.tag != .none)
            ghostty.resolveStyleColor(cell.fg_style, default_fg, &cfg.terminal_theme.palette)
        else
            default_fg;
        const fg = if (isSelectedCell(row.selection, col)) selection_fg else resolved_fg;
        if (cell.text.len == 0 or (cell.text.len == 1 and cell.text[0] == ' ')) {
            flushQueuedRun(self, mode, run_buf, &run, row.py);
            continue;
        }
        if (mode == .draw) {
            const px = columnPixelX(self, col, line.cols);
            if (self.drawSynthesizedBoxUtf8(px, row.py, cell.text, fg, row.py, row.py + self.cell_h) or
                drawSynthesizedTerminalUtf8(px, row.py, self.cell_w, self.cell_h, cell.text, fg))
            {
                flushQueuedRun(self, mode, run_buf, &run, row.py);
                continue;
            }
        }
        appendQueuedRun(self, mode, run_buf, cell.text, col, cell.face_idx, fg, &run, row.py);
    }
    flushQueuedRun(self, mode, run_buf, &run, row.py);
}

// ── Pass management ───────────────────────────────────────────────────────────

pub fn setupViewport(self: *FtRenderer, offset_x: f32, offset_y: f32, pane_w: f32, pane_h: f32) void {
    _ = self;
    c.sgl_defaults();
    c.sgl_viewport(
        @as(c_int, @intFromFloat(offset_x)),
        @as(c_int, @intFromFloat(offset_y)),
        @as(c_int, @intFromFloat(pane_w)),
        @as(c_int, @intFromFloat(pane_h)),
        true,
    );
    c.sgl_scissor_rect(
        @as(c_int, @intFromFloat(offset_x)),
        @as(c_int, @intFromFloat(offset_y)),
        @as(c_int, @intFromFloat(pane_w)),
        @as(c_int, @intFromFloat(pane_h)),
        true,
    );
    c.sgl_matrix_mode_projection();
    c.sgl_load_identity();
    c.sgl_ortho(0.0, pane_w, pane_h, 0.0, -1.0, 1.0);
}

pub fn ensureRunBufferCapacity(self: *FtRenderer, row_count: usize, col_count: usize) bool {
    if (row_count != self.run_buf_rows or col_count != self.run_buf_cols) {
        const run_buf_needed = @max(@as(usize, 1), row_count * col_count * 4);
        if (run_buf_needed > self.run_buf.len) {
            if (self.run_buf.len > 0) self.allocator.free(self.run_buf);
            self.run_buf = self.allocator.alloc(u8, run_buf_needed) catch return false;
        }
        self.run_buf_rows = row_count;
        self.run_buf_cols = col_count;
    }
    return true;
}

pub fn resetQueueState(self: *FtRenderer) void {
    self.prepared_glyphs.clearRetainingCapacity();
    self.shaped_runs.clearRetainingCapacity();
    self.shaped_run_read_idx = 0;
    self.styleCacheReset();
}

// ── Pass 1: Background & Raster ───────────────────────────────────────────────

pub fn queueBackgroundAndRasterPass(
    self: *FtRenderer,
    runtime: *ghostty.Runtime,
    queue: *const QueueContext,
    pane_w: f32,
    pane_h: f32,
    hash_skip_bits: *HashSkipBits,
    run_buf: []u8,
) void {
    if (!queue.helpersReady()) return;
    if (!runtime.populateRowIterator(queue.render_state, queue.row_iterator)) return;

    var row_y: usize = 0;
    var quads_open = false;
    if (queue.force_full) {
        c.sgl_begin_quads();
        quads_open = true;
        c.sgl_c4b(queue.colors.default_bg.r, queue.colors.default_bg.g, queue.colors.default_bg.b, 255);
        c.sgl_v2f(0.0, 0.0);
        c.sgl_v2f(pane_w, 0.0);
        c.sgl_v2f(pane_w, pane_h);
        c.sgl_v2f(0.0, pane_h);
    }
    while (runtime.nextRow(queue.row_iterator.*)) : (row_y += 1) {
        if (!queue.force_full and !runtime.rowDirty(queue.row_iterator.*) and row_y != queue.prev_cursor_row and row_y != queue.cursor_row) continue;
        if (shouldSkipRowByHash(self, runtime, queue, row_y, hash_skip_bits)) continue;

        const row = makeRowRenderInfo(self, queue, row_y);
        queueBackgroundAndRasterRow(self, runtime, queue, row, pane_w, &quads_open, run_buf);
    }
    if (quads_open) c.sgl_end();
}

pub fn queueBackgroundAndRasterRow(
    self: *FtRenderer,
    runtime: *ghostty.Runtime,
    queue: *const QueueContext,
    row: RowRenderInfo,
    pane_w: f32,
    quads_open: *bool,
    run_buf: []u8,
) void {
    if (!queue.helpersReady()) return;
    if (!runtime.populateRowCells(queue.row_iterator.*, queue.row_cells)) return;

    if (!queue.force_full) {
        if (!quads_open.*) {
            c.sgl_begin_quads();
            quads_open.* = true;
        }
        c.sgl_c4b(queue.colors.default_bg.r, queue.colors.default_bg.g, queue.colors.default_bg.b, 255);
        c.sgl_v2f(0.0, row.py);
        c.sgl_v2f(pane_w, row.py);
        c.sgl_v2f(pane_w, row.py + self.cell_h);
        c.sgl_v2f(0.0, row.py + self.cell_h);
    }

    var col_x: usize = 0;
    var col_px = self.padding_x;
    var run = GlyphRunState{ .fg = queue.colors.default_fg };
    const has_selection = row.selection != null;
    var last_style_id: u16 = 0;
    var last_style_selected = false;
    var last_style_valid = false;
    var last_style_info: CachedStyleInfo = undefined;
    while (runtime.nextCell(queue.row_cells.*)) : ({
        col_x += 1;
        col_px += self.cell_w;
    }) {
        self.last_cells_visited += 1;
        const raw_cell = runtime.cellRaw(queue.row_cells.*);
        const content_tag = runtime.cellContentTagRaw(raw_cell);
        const style_id = runtime.cellStyleIdRaw(raw_cell);
        const is_selected = has_selection and isSelectedCell(row.selection, col_x);
        const cached_style = if (style_id != 0) blk: {
            if (last_style_valid and last_style_id == style_id and last_style_selected == is_selected) {
                break :blk &last_style_info;
            }
            const info = self.resolveCachedStyle(runtime, queue.row_cells.*, style_id, is_selected, queue.colors.default_fg, queue.colors.default_bg, queue.colors.selection_fg, queue.colors.palette) orelse break :blk null;
            last_style_info = info.*;
            last_style_id = style_id;
            last_style_selected = is_selected;
            last_style_valid = true;
            break :blk &last_style_info;
        } else null;
        const has_search_highlight = if (row.search_highlight) |highlight|
            col_x >= highlight.start_col and col_x < highlight.end_col
        else
            false;
        const has_cursor = if (row.cursor_col) |cursor_col| col_x == cursor_col else false;
        const has_block_cursor = has_cursor and (queue.cursor_style == .block or (queue.cursor_style == null and queue.pane != null and copy_mode.copyModeActiveForPane(queue.app,queue.pane.?)));
        const style_needs_background = if (style_id != 0)
            if (cached_style) |style|
                style.has_non_default_bg or style.renders_background_without_text
            else
                true
        else
            false;
        const needs_background = if (is_selected or has_search_highlight or has_cursor)
            true
        else if (content_tag == .bg_color_palette or content_tag == .bg_color_rgb)
            true
        else if (style_needs_background)
            true
        else
            false;
        if (needs_background) {
            queueCellBackground(self, runtime, queue, row, content_tag, style_id, cached_style, is_selected, col_px, row.py, quads_open);
        }

        switch (content_tag) {
            .codepoint => {
                const cp = runtime.cellCodepointRaw(raw_cell);
                if (cp == 0) {
                    flushQueuedRun(self, .raster, run_buf, &run, row.py);
                    continue;
                }
                const cursor_fg = if (has_block_cursor and !(queue.cfg.terminal_theme.enabled and queue.cfg.terminal_theme.cursor_fg != null))
                    runtime.cellBackground(queue.row_cells.*) orelse queue.colors.cursor_fg
                else
                    queue.colors.cursor_fg;
                const text_style = if (style_id == 0)
                    CellTextStyle{
                        .face_idx = 0,
                        .fg = if (is_selected)
                            queue.colors.selection_fg
                        else if (has_block_cursor)
                            cursor_fg
                        else
                            queue.colors.default_fg,
                    }
                else if (cached_style) |info|
                    CellTextStyle{
                        .face_idx = info.face_idx,
                        .fg = if (has_block_cursor) cursor_fg else info.fg,
                        .needs_decorations = info.needs_decorations,
                    }
                else {
                    flushQueuedRun(self, .raster, run_buf, &run, row.py);
                    continue;
                };
                const glyph_utf8 = encodeCodepointUtf8(self, cp);
                if (glyph_utf8.len == 0) {
                    flushQueuedRun(self, .raster, run_buf, &run, row.py);
                    continue;
                }
                if (!self.ligatures or !isLigatureCodepoint(cp)) {
                    flushQueuedRun(self, .raster, run_buf, &run, row.py);
                    if (isSynthesizedTerminalCodepoint(cp)) {
                        continue;
                    }
                    if (self.directGlyph(cp, text_style.face_idx) == null) {
                        if (self.prepareGlyphs(glyph_utf8, text_style.face_idx, .terminal)) |prepared| {
                            self.recordShapedRun(glyph_utf8, text_style.face_idx, prepared.start, prepared.glyphs.len);
                        }
                    }
                    continue;
                }
                appendQueuedRun(self, .raster, run_buf, glyph_utf8, col_x, text_style.face_idx, text_style.fg, &run, row.py);
            },
            .codepoint_grapheme => {
                var cps: [16]u32 = [_]u32{0} ** 16;
                const grapheme_len = @min(runtime.cellGraphemeLen(queue.row_cells.*), cps.len);
                const glyph_utf8 = encodeCurrentCellGraphemeUtf8(self, runtime, queue.row_cells.*, &cps) orelse {
                    flushQueuedRun(self, .raster, run_buf, &run, row.py);
                    continue;
                };
                const cursor_fg = if (has_block_cursor and !(queue.cfg.terminal_theme.enabled and queue.cfg.terminal_theme.cursor_fg != null))
                    runtime.cellBackground(queue.row_cells.*) orelse queue.colors.cursor_fg
                else
                    queue.colors.cursor_fg;
                const text_style = if (style_id == 0)
                    CellTextStyle{
                        .face_idx = 0,
                        .fg = if (is_selected)
                            queue.colors.selection_fg
                        else if (has_block_cursor)
                            cursor_fg
                        else
                            queue.colors.default_fg,
                    }
                else if (cached_style) |info|
                    CellTextStyle{
                        .face_idx = info.face_idx,
                        .fg = if (has_block_cursor) cursor_fg else info.fg,
                        .needs_decorations = info.needs_decorations,
                    }
                else {
                    flushQueuedRun(self, .raster, run_buf, &run, row.py);
                    continue;
                };
                if (!self.ligatures or !isLigatureCandidate(cps[0..grapheme_len])) {
                    flushQueuedRun(self, .raster, run_buf, &run, row.py);
                    if (firstRenderableCodepoint(glyph_utf8)) |cp| {
                        if (isSynthesizedTerminalCodepoint(cp)) continue;
                    }
                    if (self.prepareGlyphs(glyph_utf8, text_style.face_idx, .terminal)) |prepared| {
                        self.recordShapedRun(glyph_utf8, text_style.face_idx, prepared.start, prepared.glyphs.len);
                    }
                    continue;
                }
                appendQueuedRun(self, .raster, run_buf, glyph_utf8, col_x, text_style.face_idx, text_style.fg, &run, row.py);
            },
            else => flushQueuedRun(self, .raster, run_buf, &run, row.py),
        }
    }
    flushQueuedRun(self, .raster, run_buf, &run, row.py);
}

// ── Pass 2: Glyph draw pass ───────────────────────────────────────────────────

pub fn queueGlyphPass(
    self: *FtRenderer,
    runtime: *ghostty.Runtime,
    queue: *const QueueContext,
    hash_skip_bits: *const HashSkipBits,
    run_buf: []u8,
) Pass2Stats {
    var stats = Pass2Stats{};
    if (!queue.helpersReady()) return stats;
    if (!runtime.populateRowIterator(queue.render_state, queue.row_iterator)) return stats;

    var row_y: usize = 0;
    while (runtime.nextRow(queue.row_iterator.*)) : (row_y += 1) {
        const row_is_dirty = queue.force_full or runtime.rowDirty(queue.row_iterator.*) or row_y == queue.prev_cursor_row or row_y == queue.cursor_row;
        if (!row_is_dirty) {
            self.last_rows_skipped += 1;
            continue;
        }
        if (skipSetGet(hash_skip_bits, row_y) and row_y != queue.prev_cursor_row and row_y != queue.cursor_row) {
            self.last_rows_skipped += 1;
            continue;
        }

        self.last_rows_rendered += 1;
        if (!runtime.populateRowCells(queue.row_iterator.*, queue.row_cells)) {
            if (!queue.force_full) runtime.clearRowDirty(queue.row_iterator.*);
            continue;
        }

        const row = makeRowRenderInfo(self, queue, row_y);
        queueGlyphRow(self, runtime, queue, row, run_buf, &stats);
        queueCursorShapeRow(self, queue, row, run_buf);
        if (!queue.force_full) runtime.clearRowDirty(queue.row_iterator.*);
    }

    return stats;
}

pub fn queueGlyphRow(
    self: *FtRenderer,
    runtime: *ghostty.Runtime,
    queue: *const QueueContext,
    row: RowRenderInfo,
    run_buf: []u8,
    stats: *Pass2Stats,
) void {
    const row_glyph_start_ns = if (queue.cfg.debug_overlay) std.time.nanoTimestamp() else 0;
    var row_needs_decorations = queue.hovered_row == row.row_y;
    var col_x: usize = 0;
    var col_px = self.padding_x;
    var run = GlyphRunState{ .fg = queue.colors.default_fg };
    const has_selection = row.selection != null;
    var last_style_id: u16 = 0;
    var last_style_selected = false;
    var last_style_valid = false;
    var last_style_info: CachedStyleInfo = undefined;
    while (runtime.nextCell(queue.row_cells.*)) : ({
        col_x += 1;
        col_px += self.cell_w;
    }) {
        const raw_cell = runtime.cellRaw(queue.row_cells.*);
        const content_tag = runtime.cellContentTagRaw(raw_cell);
        const style_id = runtime.cellStyleIdRaw(raw_cell);
        const is_selected = has_selection and isSelectedCell(row.selection, col_x);
        const cached_style = if (style_id != 0) blk: {
            if (last_style_valid and last_style_id == style_id and last_style_selected == is_selected) {
                break :blk &last_style_info;
            }
            const info = self.resolveCachedStyle(runtime, queue.row_cells.*, style_id, is_selected, queue.colors.default_fg, queue.colors.default_bg, queue.colors.selection_fg, queue.colors.palette) orelse break :blk null;
            last_style_info = info.*;
            last_style_id = style_id;
            last_style_selected = is_selected;
            last_style_valid = true;
            break :blk &last_style_info;
        } else null;
        const has_cursor = if (row.cursor_col) |cursor_col| col_x == cursor_col else false;
        const has_block_cursor = has_cursor and (queue.cursor_style == .block or (queue.cursor_style == null and queue.pane != null and copy_mode.copyModeActiveForPane(queue.app,queue.pane.?)));

        switch (content_tag) {
            .codepoint => {
                const cp = runtime.cellCodepointRaw(raw_cell);
                if (cp == 0) {
                    flushQueuedRun(self, .draw, run_buf, &run, row.py);
                    continue;
                }
                const cursor_fg = if (has_block_cursor and !(queue.cfg.terminal_theme.enabled and queue.cfg.terminal_theme.cursor_fg != null))
                    runtime.cellBackground(queue.row_cells.*) orelse queue.colors.cursor_fg
                else
                    queue.colors.cursor_fg;
                const text_style = if (style_id == 0)
                    CellTextStyle{
                        .face_idx = 0,
                        .fg = if (is_selected)
                            queue.colors.selection_fg
                        else if (has_block_cursor)
                            cursor_fg
                        else
                            queue.colors.default_fg,
                    }
                else if (cached_style) |info|
                    CellTextStyle{
                        .face_idx = info.face_idx,
                        .fg = if (has_block_cursor) cursor_fg else info.fg,
                        .needs_decorations = info.needs_decorations,
                    }
                else {
                    flushQueuedRun(self, .draw, run_buf, &run, row.py);
                    continue;
                };
                if (text_style.needs_decorations) row_needs_decorations = true;
                if (!self.ligatures or !isLigatureCodepoint(cp)) {
                    flushQueuedRun(self, .draw, run_buf, &run, row.py);
                    self.last_glyph_runs += 1;
                    if (self.drawSynthesizedBoxGlyph(col_px, row.py, cp, text_style.fg, row.py, row.py + self.cell_h)) {
                        continue;
                    }
                    if (drawSynthesizedTerminalCodepoint(col_px, row.py, self.cell_w, self.cell_h, cp, text_style.fg)) {
                        continue;
                    }
                    if (!self.drawDirectGlyph(col_px, row.py, cp, text_style.face_idx, text_style.fg, row.py, row.py + self.cell_h)) {
                        const glyph_utf8 = encodeCodepointUtf8(self, cp);
                        if (glyph_utf8.len == 0) continue;
                        if (self.consumeShapedRun(glyph_utf8, text_style.face_idx)) |prepared| {
                            self.batchPreparedGlyphs(col_px, row.py, prepared, text_style.fg, row.py, row.py + self.cell_h);
                        } else {
                            self.batchGlyphs(col_px, row.py, glyph_utf8, text_style.face_idx, text_style.fg, .terminal, row.py, row.py + self.cell_h);
                        }
                    }
                    continue;
                }
                appendQueuedRun(self, .draw, run_buf, encodeCodepointUtf8(self, cp), col_x, text_style.face_idx, text_style.fg, &run, row.py);
            },
            .codepoint_grapheme => {
                var cps: [16]u32 = [_]u32{0} ** 16;
                const grapheme_len = @min(runtime.cellGraphemeLen(queue.row_cells.*), cps.len);
                const glyph_utf8 = encodeCurrentCellGraphemeUtf8(self, runtime, queue.row_cells.*, &cps) orelse {
                    flushQueuedRun(self, .draw, run_buf, &run, row.py);
                    continue;
                };
                const cursor_fg = if (has_block_cursor and !(queue.cfg.terminal_theme.enabled and queue.cfg.terminal_theme.cursor_fg != null))
                    runtime.cellBackground(queue.row_cells.*) orelse queue.colors.cursor_fg
                else
                    queue.colors.cursor_fg;
                const text_style = if (style_id == 0)
                    CellTextStyle{
                        .face_idx = 0,
                        .fg = if (is_selected)
                            queue.colors.selection_fg
                        else if (has_block_cursor)
                            cursor_fg
                        else
                            queue.colors.default_fg,
                    }
                else if (cached_style) |info|
                    CellTextStyle{
                        .face_idx = info.face_idx,
                        .fg = if (has_block_cursor) cursor_fg else info.fg,
                        .needs_decorations = info.needs_decorations,
                    }
                else {
                    flushQueuedRun(self, .draw, run_buf, &run, row.py);
                    continue;
                };
                if (text_style.needs_decorations) row_needs_decorations = true;
                if (!self.ligatures or !isLigatureCandidate(cps[0..grapheme_len])) {
                    flushQueuedRun(self, .draw, run_buf, &run, row.py);
                    const px = columnPixelX(self, col_x, queue.col_count);
                    self.last_glyph_runs += 1;
                    if (self.drawSynthesizedBoxUtf8(px, row.py, glyph_utf8, text_style.fg, row.py, row.py + self.cell_h)) {
                        continue;
                    }
                    if (drawSynthesizedTerminalUtf8(px, row.py, self.cell_w, self.cell_h, glyph_utf8, text_style.fg)) {
                        continue;
                    }
                    if (self.consumeShapedRun(glyph_utf8, text_style.face_idx)) |prepared| {
                        self.batchPreparedGlyphs(px, row.py, prepared, text_style.fg, row.py, row.py + self.cell_h);
                    } else {
                        self.batchGlyphs(px, row.py, glyph_utf8, text_style.face_idx, text_style.fg, .terminal, row.py, row.py + self.cell_h);
                    }
                    continue;
                }
                appendQueuedRun(self, .draw, run_buf, glyph_utf8, col_x, text_style.face_idx, text_style.fg, &run, row.py);
            },
            else => flushQueuedRun(self, .draw, run_buf, &run, row.py),
        }
    }
    flushQueuedRun(self, .draw, run_buf, &run, row.py);
    if (queue.cfg.debug_overlay) stats.glyph_ns += std.time.nanoTimestamp() - row_glyph_start_ns;

    const row_decoration_start_ns = if (queue.cfg.debug_overlay) std.time.nanoTimestamp() else 0;
    if (row_needs_decorations) drawRowDecorations(self, runtime, queue, row);
    if (queue.cfg.debug_overlay) stats.decoration_ns += std.time.nanoTimestamp() - row_decoration_start_ns;
}

pub fn queueCursorShapeRow(self: *FtRenderer, queue: *const QueueContext, row: RowRenderInfo, run_buf: []u8) void {
    _ = run_buf;
    const cursor_style = queue.cursor_style orelse return;
    if (cursor_style == .block) return;
    const cursor_col = row.cursor_col orelse return;

    const cursor_width = if (row.cursor_wide and cursor_style != .bar) self.cell_w * 2.0 else self.cell_w;
    const px = columnPixelX(self, cursor_col, queue.col_count);
    c.sgl_load_default_pipeline();
    drawCursor(px, row.py, cursor_width, self.cell_h, queue.colors.cursor_bg, cursor_style);
}

// ── Decoration helpers ────────────────────────────────────────────────────────

pub fn drawRowDecorations(
    self: *FtRenderer,
    runtime: *ghostty.Runtime,
    queue: *const QueueContext,
    row: RowRenderInfo,
) void {
    if (!queue.helpersReady()) return;
    if (!runtime.populateRowCells(queue.row_iterator.*, queue.row_cells)) return;

    var dec_col_x: usize = 0;
    var dec_px = self.padding_x;
    var dec_quads_open = false;
    var last_style_id: u16 = 0;
    var last_style_selected = false;
    var last_style_valid = false;
    var last_style_info: CachedStyleInfo = undefined;
    while (runtime.nextCell(queue.row_cells.*)) : ({
        dec_col_x += 1;
        dec_px += self.cell_w;
    }) {
        const raw_cell = runtime.cellRaw(queue.row_cells.*);
        const hovered_link_visual = if (queue.hovered_hyperlink) |hovered|
            hovered.row == row.row_y and dec_col_x >= hovered.start_col and dec_col_x < hovered.end_col
        else
            false;
        const style_id = runtime.cellStyleIdRaw(raw_cell);
        if (style_id == 0 and !hovered_link_visual) continue;

        const is_selected = isSelectedCell(row.selection, dec_col_x);
        const cached_style = if (style_id != 0) blk: {
            if (last_style_valid and last_style_id == style_id and last_style_selected == is_selected) {
                break :blk &last_style_info;
            }
            const info = self.resolveCachedStyle(runtime, queue.row_cells.*, style_id, is_selected, queue.colors.default_fg, queue.colors.default_bg, queue.colors.selection_fg, queue.colors.palette) orelse break :blk null;
            last_style_info = info.*;
            last_style_id = style_id;
            last_style_selected = is_selected;
            last_style_valid = true;
            break :blk &last_style_info;
        } else null;
        if (style_id != 0 and cached_style == null) continue;

        const underline = if (cached_style) |info| info.underline else 0;
        const strikethrough = if (cached_style) |info| info.strikethrough else false;
        const overline = if (cached_style) |info| info.overline else false;
        if (underline == 0 and !strikethrough and !overline and !hovered_link_visual) continue;

        if (!dec_quads_open) {
            c.sgl_load_default_pipeline();
            c.sgl_begin_quads();
            dec_quads_open = true;
        }

        const dec_fg = if (cached_style) |info| info.fg else queue.colors.selection_fg;
        const dec_color = ghostty.resolveStyleColor(
            if (cached_style) |info| info.underline_color else .{ .tag = .none, .value = .{ ._padding = 0 } },
            dec_fg,
            queue.colors.palette,
        );
        const effective_underline: i32 = if (hovered_link_visual and underline == 0) 1 else underline;
        emitUnderlineDecoration(self, dec_px, row.py, effective_underline, dec_color.r, dec_color.g, dec_color.b);

        if (strikethrough) {
            const thickness: f32 = 1.0;
            const st_y = row.py + self.cell_h * 0.5 - 0.5;
            emitRect(dec_px, st_y, self.cell_w, thickness, dec_fg.r, dec_fg.g, dec_fg.b, 255);
        }

        if (overline) {
            emitRect(dec_px, row.py, self.cell_w, 1.0, dec_fg.r, dec_fg.g, dec_fg.b, 255);
        }
    }
    if (dec_quads_open) c.sgl_end();
}

pub fn emitUnderlineDecoration(self: *FtRenderer, x: f32, y: f32, underline: i32, r: u8, g: u8, b: u8) void {
    const thickness: f32 = 1.0;
    const ul_y = y + self.cell_h - thickness - 1.0;
    switch (underline) {
        0 => {},
        1 => emitRect(x, ul_y, self.cell_w, thickness, r, g, b, 255),
        2 => {
            emitRect(x, ul_y - 2.0, self.cell_w, thickness, r, g, b, 255);
            emitRect(x, ul_y, self.cell_w, thickness, r, g, b, 255);
        },
        3 => {
            const n_segs: usize = 8;
            const seg_w = self.cell_w / @as(f32, @floatFromInt(n_segs));
            const amp: f32 = 1.0;
            const base_y = ul_y + amp;
            var seg: usize = 0;
            while (seg < n_segs) : (seg += 1) {
                const t = @as(f32, @floatFromInt(seg)) / @as(f32, @floatFromInt(n_segs));
                const t1 = @as(f32, @floatFromInt(seg + 1)) / @as(f32, @floatFromInt(n_segs));
                const sx0 = x + t * self.cell_w;
                const sy0 = base_y - amp * @sin(t * std.math.tau);
                const sy1 = base_y - amp * @sin(t1 * std.math.tau);
                const seg_h = @abs(sy1 - sy0) + thickness;
                const seg_y = @min(sy0, sy1);
                emitRect(sx0, seg_y, seg_w, seg_h, r, g, b, 255);
            }
        },
        4 => {
            var dot_x = x;
            const dot_w: f32 = 1.0;
            const gap: f32 = 2.0;
            while (dot_x + dot_w <= x + self.cell_w) : (dot_x += dot_w + gap) {
                emitRect(dot_x, ul_y, dot_w, thickness, r, g, b, 255);
            }
        },
        5 => {
            var dash_x = x;
            const dash_w: f32 = 4.0;
            const dash_gap: f32 = 2.0;
            while (dash_x + dash_w <= x + self.cell_w) : (dash_x += dash_w + dash_gap) {
                emitRect(dash_x, ul_y, dash_w, thickness, r, g, b, 255);
            }
        },
        else => emitRect(x, ul_y, self.cell_w, thickness, r, g, b, 255),
    }
}

// ── Row hashing / skip ────────────────────────────────────────────────────────

pub fn shouldSkipRowByHash(
    self: *FtRenderer,
    runtime: *ghostty.Runtime,
    queue: *const QueueContext,
    row_y: usize,
    hash_skip_bits: *HashSkipBits,
) bool {
    _ = self;
    if (!queue.useRowMap() or row_y == queue.cursor_row or row_y == queue.prev_cursor_row) return false;

    const row_raw = runtime.rowRaw(queue.row_iterator.*);
    if (row_raw == 0) return false;

    const keys = queue.row_map_keys.?;
    const vals = queue.row_map_vals.?;
    const slot = rowMapProbe(keys, row_raw);
    if (runtime.rowHashCells(queue.row_iterator.*, queue.row_cells)) |new_hash| {
        if (queue.row_map_skip and new_hash != 0 and keys[slot] == row_raw and vals[slot] == new_hash) {
            skipSetSet(hash_skip_bits, row_y);
            return true;
        }
        keys[slot] = row_raw;
        vals[slot] = new_hash;
    }
    return false;
}

// ── Cell-level helpers ────────────────────────────────────────────────────────

pub fn queueCellBackground(
    self: *FtRenderer,
    runtime: *ghostty.Runtime,
    queue: *const QueueContext,
    row: RowRenderInfo,
    content_tag: ghostty.CellContentTag,
    style_id: u16,
    cached_style: ?*const CachedStyleInfo,
    is_selected: bool,
    col_px: f32,
    py: f32,
    quads_open: *bool,
) void {
    const is_bg_tag = content_tag == .bg_color_palette or content_tag == .bg_color_rgb;
    if (is_selected) {
        self.last_bg_rects += 1;
        openQuadBatch(self, quads_open);
        c.sgl_c4b(queue.colors.selection_bg.r, queue.colors.selection_bg.g, queue.colors.selection_bg.b, 255);
        c.sgl_v2f(col_px, py);
        c.sgl_v2f(col_px + self.cell_w, py);
        c.sgl_v2f(col_px + self.cell_w, py + self.cell_h);
        c.sgl_v2f(col_px, py + self.cell_h);
        return;
    }

    if (row.search_highlight) |highlight| {
        if (highlight.start_col <= highlight.end_col and col_px >= self.padding_x + @as(f32, @floatFromInt(highlight.start_col)) * self.cell_w and col_px < self.padding_x + @as(f32, @floatFromInt(highlight.end_col)) * self.cell_w) {
            const bg = if (highlight.active) queue.colors.search_active_bg else queue.colors.search_bg;
            self.last_bg_rects += 1;
            openQuadBatch(self, quads_open);
            c.sgl_c4b(bg.r, bg.g, bg.b, 255);
            c.sgl_v2f(col_px, py);
            c.sgl_v2f(col_px + self.cell_w, py);
            c.sgl_v2f(col_px + self.cell_w, py + self.cell_h);
            c.sgl_v2f(col_px, py + self.cell_h);
            return;
        }
    }

    if (queue.cursor_style == .block or (queue.cursor_style == null and queue.pane != null and copy_mode.copyModeActiveForPane(queue.app,queue.pane.?))) {
        if (row.cursor_col) |cursor_col| {
            const cursor_end = cursor_col + (if (row.cursor_wide) @as(usize, 2) else 1);
            if (col_px >= self.padding_x + @as(f32, @floatFromInt(cursor_col)) * self.cell_w and col_px < self.padding_x + @as(f32, @floatFromInt(cursor_end)) * self.cell_w) {
                const cursor_bg = if (queue.cfg.terminal_theme.enabled and queue.cfg.terminal_theme.cursor != null)
                    queue.colors.cursor_bg
                else
                    runtime.cellForeground(queue.row_cells.*) orelse queue.colors.cursor_bg;
                self.last_bg_rects += 1;
                openQuadBatch(self, quads_open);
                c.sgl_c4b(cursor_bg.r, cursor_bg.g, cursor_bg.b, 255);
                c.sgl_v2f(col_px, py);
                c.sgl_v2f(col_px + self.cell_w, py);
                c.sgl_v2f(col_px + self.cell_w, py + self.cell_h);
                c.sgl_v2f(col_px, py + self.cell_h);
                return;
            }
        }
    }

    if (!is_bg_tag and style_id == 0) return;
    const bg: ghostty.ColorRgb = if (!is_bg_tag and style_id != 0)
        if (cached_style) |style|
            style.bg
        else if (self.resolveCachedStyle(runtime, queue.row_cells.*, style_id, is_selected, queue.colors.default_fg, queue.colors.default_bg, queue.colors.selection_fg, queue.colors.palette)) |style|
            style.bg
        else
            runtime.cellBackground(queue.row_cells.*) orelse queue.colors.default_bg
    else
        runtime.cellBackground(queue.row_cells.*) orelse queue.colors.default_bg;
    if (colorsEqual(bg, queue.colors.default_bg)) return;

    self.last_bg_rects += 1;
    openQuadBatch(self, quads_open);
    c.sgl_c4b(bg.r, bg.g, bg.b, 255);
    c.sgl_v2f(col_px, py);
    c.sgl_v2f(col_px + self.cell_w, py);
    c.sgl_v2f(col_px + self.cell_w, py + self.cell_h);
    c.sgl_v2f(col_px, py + self.cell_h);
}

pub inline fn resolveCellTextStyle(
    self: *FtRenderer,
    runtime: *ghostty.Runtime,
    queue: *const QueueContext,
    style_id: u16,
    is_selected: bool,
) ?CellTextStyle {
    if (style_id == 0) {
        return .{
            .face_idx = 0,
            .fg = if (is_selected) queue.colors.selection_fg else queue.colors.default_fg,
        };
    }

    var resolved = CellTextStyle{ .face_idx = 0, .fg = queue.colors.default_fg };
    {
        const info = self.resolveCachedStyle(runtime, queue.row_cells.*, style_id, is_selected, queue.colors.default_fg, queue.colors.default_bg, queue.colors.selection_fg, queue.colors.palette) orelse return null;
        resolved.face_idx = info.face_idx;
        resolved.fg = info.fg;
        resolved.needs_decorations = info.needs_decorations;
    }
    return resolved;
}

pub fn makeRowRenderInfo(self: *FtRenderer, queue: *const QueueContext, row_y: usize) RowRenderInfo {
    const row_y_px = @as(f32, @floatFromInt(row_y)) * self.cell_h;
    return .{
        .row_y = row_y,
        .py = self.padding_y + row_y_px,
        .selection = if (queue.selection_range) |range| rowSelectionBounds(range, row_y) else null,
        .search_highlight = if (queue.pane) |pane| copy_mode.searchHighlightForRow(queue.app,pane, row_y) else null,
        .cursor_col = if (queue.pane) |pane|
            copy_mode.copyModeCursorColForRow(queue.app,pane, row_y) orelse
                if (!copy_mode.copyModeActiveForPane(queue.app, pane) and row_y == queue.cursor_row)
                    queue.cursor_col -| @intFromBool(queue.cursor_wide)
                else
                    null
        else if (row_y == queue.cursor_row)
            queue.cursor_col -| @intFromBool(queue.cursor_wide)
        else
            null,
        .cursor_wide = row_y == queue.cursor_row and queue.cursor_wide,
    };
}

pub fn encodeCodepointUtf8(self: *FtRenderer, cp: u32) []const u8 {
    const glyph_len: usize = encodeUtf8(cp, &self.glyph_buf) catch 0;
    return self.glyph_buf[0..glyph_len];
}

pub fn encodeCurrentCellGraphemeUtf8(self: *FtRenderer, runtime: *ghostty.Runtime, row_cells: ?*anyopaque, cps: *[16]u32) ?[]const u8 {
    const grapheme_len = @min(runtime.cellGraphemeLen(row_cells), cps.len);
    if (grapheme_len == 0) return null;

    cps.* = [_]u32{0} ** 16;
    runtime.cellGraphemes(row_cells, cps);
    var glyph_len: usize = 0;
    for (cps[0..grapheme_len]) |cp| {
        if (cp == 0) break;
        glyph_len += encodeUtf8(cp, self.glyph_buf[glyph_len..]) catch break;
    }
    if (glyph_len == 0) return null;
    return self.glyph_buf[0..glyph_len];
}

// ── Run batching (ligature grouping) ──────────────────────────────────────────

pub inline fn appendQueuedRun(
    self: *FtRenderer,
    mode: GlyphRunMode,
    run_buf: []u8,
    utf8: []const u8,
    col_x: usize,
    face_idx: u8,
    fg: ghostty.ColorRgb,
    run: *GlyphRunState,
    py: f32,
) void {
    if (utf8.len == 0) {
        flushQueuedRun(self, mode, run_buf, run, py);
        return;
    }

    const next_len = run.len + utf8.len;
    const same_style = run.face_idx == face_idx and colorsEqual(run.fg, fg);
    if (run.len != 0 and same_style and next_len <= run_buf.len) {
        copyUtf8Inline(run_buf[run.len..next_len], utf8);
        run.len = next_len;
        return;
    }

    if (next_len > run_buf.len) flushQueuedRun(self, mode, run_buf, run, py);
    if (run.len > 0 and !same_style) {
        flushQueuedRun(self, mode, run_buf, run, py);
    }
    if (run.len == 0) {
        run.start_col = col_x;
        run.face_idx = face_idx;
        run.fg = fg;
    }
    copyUtf8Inline(run_buf[run.len .. run.len + utf8.len], utf8);
    run.len += utf8.len;
}

pub inline fn copyUtf8Inline(dst: []u8, src: []const u8) void {
    switch (src.len) {
        0 => {},
        1 => dst[0] = src[0],
        2 => {
            dst[0] = src[0];
            dst[1] = src[1];
        },
        3 => {
            dst[0] = src[0];
            dst[1] = src[1];
            dst[2] = src[2];
        },
        4 => {
            dst[0] = src[0];
            dst[1] = src[1];
            dst[2] = src[2];
            dst[3] = src[3];
        },
        else => fastmem.copy(u8, dst, src),
    }
}

pub inline fn flushQueuedRun(self: *FtRenderer, mode: GlyphRunMode, run_buf: []u8, run: *GlyphRunState, py: f32) void {
    switch (mode) {
        .raster => self.flushRasterRun(run_buf, &run.start_col, &run.len, run.face_idx, run.fg, py),
        .draw => self.flushDrawRun(run_buf, &run.start_col, &run.len, run.face_idx, run.fg, py),
    }
}

// ── Geometry helpers ──────────────────────────────────────────────────────────

pub fn columnPixelX(self: *FtRenderer, col_x: usize, col_count: usize) f32 {
    const col_x_px = if (builtin.os.tag == .linux and col_count > 0)
        @as(f32, @floatFromInt((col_count - 1) - col_x)) * self.cell_w
    else
        @as(f32, @floatFromInt(col_x)) * self.cell_w;
    return self.padding_x + col_x_px;
}

pub inline fn openQuadBatch(self: *FtRenderer, quads_open: *bool) void {
    _ = self;
    if (quads_open.*) return;
    c.sgl_begin_quads();
    quads_open.* = true;
}

pub inline fn isSelectedCell(row_selection: ?RowSelectionBounds, col_x: usize) bool {
    return if (row_selection) |selection_bounds|
        col_x >= selection_bounds.start_col and col_x <= selection_bounds.end_col
    else
        false;
}

pub inline fn skipSetSet(bits: *HashSkipBits, row: usize) void {
    if (row >= HASH_SKIP_MAX_ROWS) return;
    bits[row / 64] |= @as(u64, 1) << @intCast(row % 64);
}

pub inline fn skipSetGet(bits: *const HashSkipBits, row: usize) bool {
    if (row >= HASH_SKIP_MAX_ROWS) return false;
    return (bits[row / 64] >> @intCast(row % 64)) & 1 != 0;
}

pub fn rowMapProbe(keys: []u64, key: u64) usize {
    const cap = keys.len;
    const mask = cap - 1;
    var idx = @as(usize, @truncate(key)) & mask;
    var i: usize = 0;
    while (i < cap) : (i += 1) {
        const existing = keys[idx];
        if (existing == 0 or existing == key) return idx;
        idx = (idx + 1) & mask;
    }
    return 0;
}

// ── Standalone helpers ────────────────────────────────────────────────────────

/// Emit a single filled rectangle quad into an already-open sgl_begin_quads batch.
/// Caller must have called sgl_begin_quads() before and sgl_end() after.
pub inline fn emitRect(x: f32, y: f32, w: f32, h: f32, r: u8, g: u8, b: u8, a: u8) void {
    const rf = @as(f32, @floatFromInt(r)) / 255.0;
    const gf = @as(f32, @floatFromInt(g)) / 255.0;
    const bf = @as(f32, @floatFromInt(b)) / 255.0;
    const af = @as(f32, @floatFromInt(a)) / 255.0;
    c.sgl_c4f(rf, gf, bf, af);
    c.sgl_v2f(x, y);
    c.sgl_v2f(x + w, y);
    c.sgl_v2f(x + w, y + h);
    c.sgl_v2f(x, y + h);
}

/// Draw the cursor shape using a single sgl_begin_quads/sgl_end batch.
fn drawCursor(x: f32, y: f32, w: f32, h: f32, color: ghostty.ColorRgb, style: ghostty.CursorVisualStyle) void {
    c.sgl_begin_quads();
    switch (style) {
        .block => emitRect(x, y, w, h, color.r, color.g, color.b, 255),
        .block_hollow => {
            const t: f32 = 2.0;
            emitRect(x, y, w, t, color.r, color.g, color.b, 255);
            emitRect(x, y + h - t, w, t, color.r, color.g, color.b, 255);
            emitRect(x, y, t, h, color.r, color.g, color.b, 255);
            emitRect(x + w - t, y, t, h, color.r, color.g, color.b, 255);
        },
        .bar => {
            const bar_w = @min(@as(f32, 3.0), @max(@as(f32, 2.0), @floor(w * 0.16)));
            emitRect(x, y, bar_w, h, color.r, color.g, color.b, 255);
        },
        .underline => emitRect(x, y + h - 4.0, w, 4.0, color.r, color.g, color.b, 255),
    }
    c.sgl_end();
}

inline fn isLigatureCodepoint(cp: u32) bool {
    return switch (cp) {
        '!', '#', '$', '%', '&', '*', '+', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '\\', '^', '|', '~' => true,
        else => false,
    };
}

inline fn isLigatureCandidate(cps: []const u32) bool {
    if (cps.len == 0) return false;
    for (cps) |cp| {
        if (cp == 0) break;
        if (!isLigatureCodepoint(cp)) return false;
    }
    return true;
}
