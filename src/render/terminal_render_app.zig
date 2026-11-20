const std = @import("std");
const c = @import("sokol_c");
const io = @import("../io.zig");
const ghostty = @import("../term/ghostty.zig");
const Config = @import("../config.zig").Config;
const App = @import("../app.zig").App;
const Pane = @import("../pane.zig").Pane;
const copy_mode = @import("../app/copy_mode.zig");
const quick_select = @import("../app/quick_select.zig");
const selection = @import("../selection.zig");
const color_math = @import("color_math.zig");
const terminal_render = @import("terminal_render.zig");
const FtRenderer = @import("ft_renderer.zig").FtRenderer;
const PaneCache = @import("pane_cache.zig").PaneCache;

const effectiveCursorColor = color_math.effectiveCursorColor;
const contrastTextColor = color_math.contrastTextColor;
const mixColor = color_math.mixColor;

const AppRenderPolicy = struct {
    app: *const App,
    pane: ?*const Pane,
    cursor_row: usize,
    cursor_col: usize,
    cursor_wide: bool,
};

fn effectiveCursorStyle(
    runtime: *ghostty.Runtime,
    render_state: ?*anyopaque,
    pane: ?*const Pane,
    app: *const App,
    is_focused: bool,
) ?ghostty.CursorVisualStyle {
    if (pane) |value| {
        if (copy_mode.copyModeActiveForPane(app, value)) return null;
    }
    if (runtime.cursorPos(render_state) == null) return null;
    if (runtime.cursorPasswordInput(render_state)) return .block;
    if (!runtime.cursorVisible(render_state)) return null;
    if (!is_focused) return app.config.cursor.unfocused;
    if (busyShellCursor(pane, &app.config.cursor)) |style| return style;
    return runtime.cursorVisualStyle(render_state);
}

pub fn busyShellCursor(pane: ?*const Pane, cursor: *const Config.Cursor) ?ghostty.CursorVisualStyle {
    const term = (pane orelse return null).asTerminalConst() orelse return null;
    if (!term.shell_command_running or !term.child_alive_cached or term.active_screen != @backingInt(ghostty.TerminalScreen.primary)) return null;
    return cursor.busy;
}

pub fn cursorBlinkVisible(runtime: *ghostty.Runtime, render_state: ?*anyopaque, pane: ?*const Pane, app: *const App, focused: bool, now_ns: i128) bool {
    const cursor = &app.config.cursor;
    return !runtime.cursorBlinking(render_state) or
        runtime.cursorPasswordInput(render_state) or
        (focused and busyShellCursor(pane, cursor) != null) or
        color_math.blinkVisibleWithTimeout(now_ns, app.cursor_blink_start_ns, cursor.blink_rate, cursor.blink_timeout, focused);
}

fn appSearchHighlight(context: ?*anyopaque, row: usize) ?terminal_render.SearchHighlight {
    const policy: *const AppRenderPolicy = @ptrCast(@alignCast(context.?));
    const pane = policy.pane orelse return null;
    const highlight = copy_mode.searchHighlightForRow(policy.app, pane, row) orelse return null;
    return .{
        .row = highlight.row,
        .start_col = highlight.start_col,
        .end_col = highlight.end_col,
        .active = highlight.active,
    };
}

fn appSearchCell(context: ?*anyopaque, row: usize, col: usize) ?bool {
    const policy: *const AppRenderPolicy = @ptrCast(@alignCast(context.?));
    const pane = policy.pane orelse return null;
    return @import("../app/terminal_find.zig").highlightForCell(policy.app, pane, row, col);
}

fn appCursorCol(context: ?*anyopaque, row: usize) ?usize {
    const policy: *const AppRenderPolicy = @ptrCast(@alignCast(context.?));
    const pane = policy.pane orelse return null;
    if (copy_mode.copyModeCursorColForRow(policy.app, pane, row)) |col| return col;
    if (copy_mode.copyModeActiveForPane(policy.app, pane)) return null;
    if (row == policy.cursor_row) return policy.cursor_col -| @intFromBool(policy.cursor_wide);
    return null;
}

/// Cursor and theme colours exposed to custom shaders, in pane pixels.
pub const ShaderState = struct {
    /// Cursor geometry, top-left origin. Retained during the blink-off phase.
    cursor_rect: ?[4]f32,
    cursor_style: ?ghostty.CursorVisualStyle,
    cursor_visible: bool,
    cursor: ghostty.ColorRgb,
    cursor_text: ghostty.ColorRgb,
    background: ghostty.ColorRgb,
    foreground: ghostty.ColorRgb,
    selection_bg: ghostty.ColorRgb,
    selection_fg: ghostty.ColorRgb,
    palette: *const [256]ghostty.ColorRgb,
};

pub fn shaderState(renderer: *FtRenderer, runtime: *ghostty.Runtime, cfg: *const Config, app: *const App, pane: *const Pane, render_state: ?*anyopaque, padding_x: f32, padding_y: f32, now_ns: i128) ?ShaderState {
    const render_colors = if (cfg.terminal_theme.enabled) null else blk: {
        if (!runtime.renderStateColorsInto(render_state, &renderer.render_colors_scratch)) return null;
        break :blk &renderer.render_colors_scratch;
    };
    const theme = &cfg.terminal_theme;
    const default_bg = if (theme.enabled) theme.background else render_colors.?.background;
    const default_fg = if (theme.enabled) theme.foreground else render_colors.?.foreground;
    const raw_cursor_color: ghostty.ColorRgb = if (theme.enabled)
        (theme.cursor orelse .{ .r = 220, .g = 220, .b = 220 })
    else if (render_colors.?.cursor_has_value)
        render_colors.?.cursor
    else
        .{ .r = 220, .g = 220, .b = 220 };
    const cursor_bg = effectiveCursorColor(raw_cursor_color, default_bg);
    const style = effectiveCursorStyle(runtime, render_state, pane, app, true);

    var rect: ?[4]f32 = null;
    if (style) |s| if (runtime.cursorPos(render_state)) |pos| {
        const wide = runtime.cursorWideTail(render_state);
        const col = @as(usize, pos.x) -| @intFromBool(wide);
        const x = padding_x + @as(f32, @floatFromInt(col)) * renderer.cell_w;
        const y = padding_y + @as(f32, @floatFromInt(pos.y)) * renderer.cell_h;
        const w = if (wide and s != .bar) renderer.cell_w * 2.0 else renderer.cell_w;
        const underline = terminal_render.underlineThickness(renderer.cell_h, cfg.cursor.underline_thickness);
        rect = switch (s) {
            .block, .block_hollow => .{ x, y, w, renderer.cell_h },
            .bar => .{ x, y, terminal_render.barThickness(w, cfg.cursor.bar_thickness), renderer.cell_h },
            .underline => .{ x, y + renderer.cell_h - underline, w, underline },
        };
    };

    return .{
        .cursor_rect = rect,
        .cursor_style = style,
        .cursor_visible = style != null and cursorBlinkVisible(runtime, render_state, pane, app, true, now_ns),
        .cursor = cursor_bg,
        .cursor_text = if (theme.enabled) (theme.cursor_fg orelse contrastTextColor(cursor_bg)) else contrastTextColor(cursor_bg),
        .background = default_bg,
        .foreground = default_fg,
        .selection_bg = if (theme.enabled) (theme.selection_bg orelse mixColor(default_bg, default_fg, 0.35)) else mixColor(default_bg, default_fg, 0.35),
        .selection_fg = if (theme.enabled) (theme.selection_fg orelse default_fg) else default_fg,
        .palette = if (theme.enabled) &theme.palette else &render_colors.?.palette,
    };
}

test "shader cursor tracks movement during blink-off and busy shell uses a steady block" {
    const allocator = std.testing.allocator;
    const app = try allocator.create(App);
    defer allocator.destroy(app);
    app.* = App.init(allocator);
    defer app.config.deinit();
    app.config.terminal_theme.enabled = true;
    app.config.cursor.unfocused = .block_hollow;
    var runtime = try ghostty.Runtime.init(allocator, null);
    defer runtime.deinit();
    var pane = Pane.init(allocator);
    defer pane.deinit(&runtime);
    const term = pane.asTerminal().?;
    term.terminal = try runtime.createTerminal(80, 24, 0);
    term.render_state = try runtime.createRenderState();
    runtime.setTerminalDefaultCursor(term.terminal, .bar, true);
    var renderer: FtRenderer = undefined;
    renderer.cell_w = 8;
    renderer.cell_h = 16;
    const blink_off = @as(i128, app.config.cursor.blink_rate) * std.time.ns_per_ms;

    try runtime.updateRenderState(term.render_state, term.terminal);
    const initial = shaderState(&renderer, &runtime, &app.config, app, &pane, term.render_state, 0, 0, 0).?;
    try std.testing.expect(initial.cursor_visible);
    runtime.terminalWrite(term.terminal, "\x1b[3C");
    try runtime.updateRenderState(term.render_state, term.terminal);
    const moved = shaderState(&renderer, &runtime, &app.config, app, &pane, term.render_state, 0, 0, blink_off).?;
    try std.testing.expect(!moved.cursor_visible);
    try std.testing.expectEqual(initial.cursor_rect.?[0] + 24, moved.cursor_rect.?[0]);

    term.shell_command_running = true;
    const busy = shaderState(&renderer, &runtime, &app.config, app, &pane, term.render_state, 0, 0, blink_off).?;
    try std.testing.expect(busy.cursor_visible);
    try std.testing.expectEqual(ghostty.CursorVisualStyle.block, busy.cursor_style.?);
    try std.testing.expectEqual(ghostty.CursorVisualStyle.block_hollow, effectiveCursorStyle(&runtime, term.render_state, &pane, app, false).?);
    term.active_screen = @backingInt(ghostty.TerminalScreen.alternate);
    try std.testing.expectEqual(ghostty.CursorVisualStyle.bar, effectiveCursorStyle(&runtime, term.render_state, &pane, app, true).?);
    term.active_screen = @backingInt(ghostty.TerminalScreen.primary);
    app.config.cursor.busy = .underline;
    try std.testing.expectEqual(ghostty.CursorVisualStyle.underline, effectiveCursorStyle(&runtime, term.render_state, &pane, app, true).?);
    app.config.cursor.busy = null;
    const normal = shaderState(&renderer, &runtime, &app.config, app, &pane, term.render_state, 0, 0, blink_off).?;
    try std.testing.expect(!normal.cursor_visible);
    try std.testing.expectEqual(ghostty.CursorVisualStyle.bar, normal.cursor_style.?);
    app.config.cursor.bar_thickness = 5;
    const thick = shaderState(&renderer, &runtime, &app.config, app, &pane, term.render_state, 0, 0, blink_off).?;
    try std.testing.expectEqual(@as(f32, 5), thick.cursor_rect.?[2]);
}

pub fn buildQueueOptions(
    renderer: *FtRenderer,
    runtime: *ghostty.Runtime,
    cfg: *const Config,
    app: *const App,
    pane: ?*const Pane,
    render_state: ?*anyopaque,
    row_iterator: *?*anyopaque,
    row_cells: *?*anyopaque,
    offset_x: f32,
    offset_y: f32,
    pane_w: f32,
    pane_h: f32,
    is_focused: bool,
    force_full: bool,
    row_map_keys: ?[]ghostty.RowId,
    row_map_vals: ?[]u64,
    row_map_skip: bool,
    selection_range: ?selection.Range,
    redraw_range: ?selection.Range,
    hovered_hyperlink: ?App.HoveredHyperlink,
    prev_cursor_row: usize,
    policy: *AppRenderPolicy,
) terminal_render.QueueOptions {
    const render_colors = if (cfg.terminal_theme.enabled) null else blk: {
        if (!runtime.renderStateColorsInto(render_state, &renderer.render_colors_scratch)) return undefined;
        break :blk &renderer.render_colors_scratch;
    };
    const default_bg = if (cfg.terminal_theme.enabled) cfg.terminal_theme.background else render_colors.?.background;
    const default_fg = if (cfg.terminal_theme.enabled) cfg.terminal_theme.foreground else render_colors.?.foreground;
    const raw_cursor_color: ghostty.ColorRgb = if (cfg.terminal_theme.enabled)
        (cfg.terminal_theme.cursor orelse .{ .r = 220, .g = 220, .b = 220 })
    else if (render_colors.?.cursor_has_value)
        render_colors.?.cursor
    else
        .{ .r = 220, .g = 220, .b = 220 };
    const cursor_style = if (cursorBlinkVisible(runtime, render_state, pane, app, is_focused, io.nanoTimestamp()))
        effectiveCursorStyle(runtime, render_state, pane, app, is_focused)
    else
        null;
    const cursor_wide = runtime.cursorWideTail(render_state);
    const cursor_bg = effectiveCursorColor(raw_cursor_color, default_bg);
    const selection_bg = if (cfg.terminal_theme.enabled)
        (cfg.terminal_theme.selection_bg orelse mixColor(default_bg, default_fg, 0.35))
    else
        mixColor(default_bg, default_fg, 0.35);
    const cursor_pos = runtime.cursorPos(render_state);
    policy.* = .{
        .app = app,
        .pane = pane,
        .cursor_row = if (cursor_pos) |cp| @intCast(cp.y) else std.math.maxInt(usize),
        .cursor_col = if (cursor_pos) |cp| @intCast(cp.x) else std.math.maxInt(usize),
        .cursor_wide = cursor_wide,
    };
    const hovered = if (hovered_hyperlink) |value| terminal_render.HoveredRange{
        .row = value.row,
        .start_col = value.start_col,
        .end_col = value.end_col,
    } else null;
    const quick_select_visible = pane != null and app.quick_select_active and app.quick_select_pane == pane.? and !app.quick_select_pending_capture;
    const bg = paneBackground(cfg.background, pane);
    return .{
        .render_state = render_state,
        .row_iterator = row_iterator,
        .row_cells = row_cells,
        .row_count = @intCast(runtime.renderStateRows(render_state) orelse 0),
        .col_count = @intCast(runtime.renderStateCols(render_state) orelse 0),
        .offset_x = offset_x,
        .offset_y = offset_y,
        .viewport_width = pane_w,
        .viewport_height = pane_h,
        .force_full = force_full,
        .translucent_bg = bg.translucent,
        .cell_bg_alpha = bg.cell_alpha,
        .powerline = &cfg.background.powerline,
        .debug_timing = cfg.debug_overlay,
        .focused = is_focused,
        .cursor_row = if (cursor_pos) |cp| @intCast(cp.y) else std.math.maxInt(usize),
        .cursor_col = if (cursor_pos) |cp| @intCast(cp.x) else std.math.maxInt(usize),
        .cursor_style = cursor_style,
        .cursor_rounded = cfg.cursor.rounded,
        .cursor_bar_thickness = cfg.cursor.bar_thickness,
        .cursor_underline_thickness = cfg.cursor.underline_thickness,
        .cursor_hollow_thickness = cfg.cursor.hollow_thickness,
        .cursor_wide = cursor_wide,
        .cursor_block = cursor_style == .block or (cursor_style == null and pane != null and copy_mode.copyModeActiveForPane(app, pane.?)),
        .cursor_fg_explicit = cfg.terminal_theme.cursor_fg != null,
        .selection_range = selection_range,
        .redraw_range = redraw_range,
        .search_highlight_fn = if (pane != null) appSearchHighlight else null,
        .search_cell_fn = if (pane != null and app.find.pane_id == pane.?.id) appSearchCell else null,
        .search_highlight_context = if (pane != null) @ptrCast(policy) else null,
        .cursor_col_fn = if (pane != null) appCursorCol else null,
        .cursor_col_context = if (pane != null) @ptrCast(policy) else null,
        .overlay_fn = if (quick_select_visible) queueQuickSelectBackgrounds else null,
        .overlay_context = if (quick_select_visible) @ptrCast(policy) else null,
        .overlay_row_fn = if (quick_select_visible) quickSelectLabelRow else null,
        .overlay_label_fn = if (quick_select_visible) quickSelectLabelAt else null,
        .hovered_hyperlink = hovered,
        .prev_cursor_row = prev_cursor_row,
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
            .search_bg = mixColor(default_bg, default_fg, 0.18),
            .search_active_bg = mixColor(default_bg, default_fg, 0.42),
            .palette = if (cfg.terminal_theme.enabled) &cfg.terminal_theme.palette else &render_colors.?.palette,
        },
    };
}

fn queueQuickSelectBackgrounds(context: ?*anyopaque, renderer: *FtRenderer, pane_w: f32, pane_h: f32) void {
    const policy: *const AppRenderPolicy = @ptrCast(@alignCast(context.?));
    const app = policy.app;
    const value = policy.pane orelse return;
    if (!app.quick_select_active or app.quick_select_pane != value or app.quick_select_pending_capture) return;
    c.sgl_begin_quads();
    c.sgl_c4b(67, 56, 120, 255);
    for (app.quick_select_candidates.items) |*candidate| {
        const label = quick_select.candidateLabelRemainder(app, candidate);
        if (label.len == 0) continue;
        const x = renderer.padding_x + @as(f32, @floatFromInt(candidate.start_col)) * renderer.cell_w;
        const y = renderer.padding_y + @as(f32, @floatFromInt(candidate.row)) * renderer.cell_h;
        const w = @as(f32, @floatFromInt(label.len)) * renderer.cell_w;
        if (x >= pane_w or y + renderer.cell_h > pane_h) continue;
        c.sgl_v2f(x, y);
        c.sgl_v2f(@min(x + w, pane_w), y);
        c.sgl_v2f(@min(x + w, pane_w), y + renderer.cell_h);
        c.sgl_v2f(x, y + renderer.cell_h);
    }
    c.sgl_end();
}

fn quickSelectLabelRow(context: ?*anyopaque, row: usize) bool {
    const policy: *const AppRenderPolicy = @ptrCast(@alignCast(context.?));
    const pane = policy.pane orelse return false;
    if (!policy.app.quick_select_active or policy.app.quick_select_pane != pane or policy.app.quick_select_pending_capture) return false;
    for (policy.app.quick_select_candidates.items) |*candidate| {
        if (candidate.row == row and quick_select.candidateVisible(policy.app, candidate.*)) return true;
    }
    return false;
}

fn quickSelectLabelAt(context: ?*anyopaque, row: usize, col: usize) ?u8 {
    const policy: *const AppRenderPolicy = @ptrCast(@alignCast(context.?));
    const pane = policy.pane orelse return null;
    if (!policy.app.quick_select_active or policy.app.quick_select_pane != pane or policy.app.quick_select_pending_capture) return null;
    for (policy.app.quick_select_candidates.items) |*candidate| {
        if (candidate.row != row or !quick_select.candidateVisible(policy.app, candidate.*)) continue;
        const label = quick_select.candidateLabelRemainder(policy.app, candidate);
        if (col >= candidate.start_col and col - candidate.start_col < label.len) return label[col - candidate.start_col];
    }
    return null;
}

pub fn paneBackground(background: Config.Background, pane: ?*const Pane) struct { translucent: bool, cell_alpha: u8 } {
    // A floating terminal is drawn over other terminal content, not just
    // window decoration. Neither default nor explicit cells should show it.
    if (pane) |p| if (p.is_floating) return .{ .translucent = false, .cell_alpha = 255 };
    return .{ .translucent = background.translucentCells(), .cell_alpha = background.cellAlpha() };
}

test "floating terminal backgrounds are opaque without changing tiled opacity" {
    const background: Config.Background = .{ .opacity = 0.8, .cell_opacity = 0.25 };
    var pane = Pane.init(std.testing.allocator);
    for ([_]bool{ false, true, false }) |floating| {
        pane.is_floating = floating;
        const bg = paneBackground(background, &pane);
        try std.testing.expectEqual(!floating, bg.translucent);
        try std.testing.expectEqual(@as(u8, if (floating) 255 else 64), bg.cell_alpha);
    }
}

pub fn queueInViewport(
    renderer: *FtRenderer,
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
    row_map_keys: ?[]ghostty.RowId,
    row_map_vals: ?[]u64,
    row_map_skip: bool,
    selection_range: ?selection.Range,
    redraw_range: ?selection.Range,
    hovered_hyperlink: ?App.HoveredHyperlink,
    prev_cursor_row: usize,
) void {
    _ = terminal;
    _ = fb_w;
    _ = fb_h;
    var policy: AppRenderPolicy = undefined;
    renderer.queueTerminal(runtime, buildQueueOptions(renderer, runtime, cfg, app, pane, render_state, row_iterator, row_cells, offset_x, offset_y, pane_w, pane_h, is_focused, force_full, row_map_keys, row_map_vals, row_map_skip, selection_range, redraw_range, hovered_hyperlink, prev_cursor_row, &policy));
}

pub fn renderToCache(
    renderer: *FtRenderer,
    cache: *PaneCache,
    runtime: *ghostty.Runtime,
    cfg: *const Config,
    app: *const App,
    pane: *const Pane,
    terminal: ?*anyopaque,
    render_state: ?*anyopaque,
    row_iterator: *?*anyopaque,
    row_cells: *?*anyopaque,
    pane_w: f32,
    pane_h: f32,
    is_focused: bool,
    clear_r: f32,
    clear_g: f32,
    clear_b: f32,
    force_full: bool,
    row_map_keys: ?[]ghostty.RowId,
    row_map_vals: ?[]u64,
    row_map_skip: bool,
    selection_range: ?selection.Range,
    redraw_range: ?selection.Range,
    hovered_hyperlink: ?App.HoveredHyperlink,
    prev_cursor_row: usize,
) void {
    _ = terminal;
    var policy: AppRenderPolicy = undefined;
    const options = buildQueueOptions(renderer, runtime, cfg, app, pane, render_state, row_iterator, row_cells, 0, 0, pane_w, pane_h, is_focused, force_full, row_map_keys, row_map_vals, row_map_skip, selection_range, redraw_range, hovered_hyperlink, if (force_full) std.math.maxInt(usize) else prev_cursor_row, &policy);
    renderer.renderToCache(cache, runtime, options, clear_r, clear_g, clear_b);
}

pub fn drawDirect(
    renderer: *FtRenderer,
    runtime: *ghostty.Runtime,
    cfg: *const Config,
    app: *const App,
    pane: *const Pane,
    terminal: ?*anyopaque,
    render_state: ?*anyopaque,
    row_iterator: *?*anyopaque,
    row_cells: *?*anyopaque,
    offset_x: f32,
    offset_y: f32,
    screen_w: f32,
    screen_h: f32,
    fb_w: f32,
    fb_h: f32,
    is_focused: bool,
    force_full: bool,
    selection_range: ?selection.Range,
    redraw_range: ?selection.Range,
    hovered_hyperlink: ?App.HoveredHyperlink,
    prev_cursor_row: usize,
) void {
    _ = terminal;
    _ = fb_w;
    _ = fb_h;
    var policy: AppRenderPolicy = undefined;
    renderer.drawDirect(runtime, buildQueueOptions(renderer, runtime, cfg, app, pane, render_state, row_iterator, row_cells, offset_x, offset_y, screen_w, screen_h, is_focused, force_full, null, null, false, selection_range, redraw_range, hovered_hyperlink, prev_cursor_row, &policy));
}
