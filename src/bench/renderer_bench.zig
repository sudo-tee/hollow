const std = @import("std");
const io = @import("../io.zig");
const c = @import("sokol_c");
const ghostty = @import("../term/ghostty.zig");
const FtRenderer = @import("../render/ft_renderer.zig").FtRenderer;
const terminal_render = @import("../render/terminal_render.zig");

const default_rows: usize = 40;
const default_cols: usize = 120;
const default_frames: usize = 1000;
const default_chunk_bytes: usize = 393216;
const default_warmup: usize = 3;
const default_iterations: usize = 10;

const Scenario = enum {
    repaint,
    scroll,
    styled,
    replay,
};

const Mode = enum {
    parse,
    render_state,
    render,
    pipeline,
};

const Options = struct {
    scenario: Scenario = .repaint,
    input_path: ?[]const u8 = null,
    frames: usize = default_frames,
    rows: usize = default_rows,
    cols: usize = default_cols,
    chunk_bytes: usize = default_chunk_bytes,
    warmup: usize = default_warmup,
    iterations: usize = default_iterations,
    mode: Mode = .pipeline,
    json: bool = false,
};

const CallbackState = struct {
    response_bytes: usize = 0,
    bells: usize = 0,
};

const Session = struct {
    runtime: *ghostty.Runtime,
    terminal: ?*anyopaque,
    render_state: ?*anyopaque,
    row_iterator: ?*anyopaque,
    row_cells: ?*anyopaque,
    callbacks: CallbackState = .{},

    fn init(runtime: *ghostty.Runtime, cols: usize, rows: usize) !Session {
        const terminal = try runtime.createTerminal(@intCast(cols), @intCast(rows), 64 * 1024 * 1024);
        errdefer runtime.freeTerminal(terminal);

        var session = Session{
            .runtime = runtime,
            .terminal = terminal,
            .render_state = null,
            .row_iterator = null,
            .row_cells = null,
        };
        session.render_state = try runtime.createRenderState();
        errdefer runtime.freeRenderState(session.render_state);
        session.row_iterator = try runtime.createRowIterator();
        errdefer runtime.freeRowIterator(session.row_iterator);
        session.row_cells = try runtime.createRowCells();
        return session;
    }

    fn activate(self: *Session) void {
        self.runtime.registerCallbacks(self.terminal, .{
            .write_pty = writePty,
            .bell = bell,
            .enquiry = enquiry,
            .xtversion = xtversion,
            .size = size,
            .color_scheme = colorScheme,
            .device_attributes = deviceAttributes,
            .title_changed = titleChanged,
        });
        self.runtime.setTerminalUserdata(self.terminal, @ptrCast(&self.callbacks));
    }

    fn deinit(self: *Session) void {
        self.runtime.freeRowCells(self.row_cells);
        self.runtime.freeRowIterator(self.row_iterator);
        self.runtime.freeRenderState(self.render_state);
        self.runtime.freeTerminal(self.terminal);
    }
};

const RenderTarget = struct {
    image: c.sg_image,
    view: c.sg_view,

    fn init(width: u32, height: u32) RenderTarget {
        var image_desc = std.mem.zeroes(c.sg_image_desc);
        image_desc.width = @intCast(width);
        image_desc.height = @intCast(height);
        image_desc.pixel_format = c.SG_PIXELFORMAT_RGBA8;
        image_desc.usage.color_attachment = true;
        image_desc.label = "renderer-bench-target";
        const image = c.sg_make_image(&image_desc);

        var view_desc = std.mem.zeroes(c.sg_view_desc);
        view_desc.color_attachment.image = image;
        const view = c.sg_make_view(&view_desc);
        return .{ .image = image, .view = view };
    }

    fn deinit(self: *RenderTarget) void {
        c.sg_destroy_view(self.view);
        c.sg_destroy_image(self.image);
    }
};

const Harness = struct {
    allocator: std.mem.Allocator,
    options: Options,
    runtime: ghostty.Runtime,
    renderer: FtRenderer,
    target: RenderTarget,
    palette: [256]ghostty.ColorRgb,
    viewport_width: f32,
    viewport_height: f32,
    final_cursor_row: usize = std.math.maxInt(usize),
    final_cursor_col: usize = std.math.maxInt(usize),
    render_state_rows: usize = 0,
    render_state_cols: usize = 0,
    dirty_level: ghostty.RenderStateDirty = .false_value,
    last_rows_rendered: usize = 0,
    last_rows_skipped: usize = 0,
    last_cells_visited: usize = 0,
    last_glyph_runs: usize = 0,
    last_bg_rects: usize = 0,
    last_atlas_flushed: bool = false,
    last_glyph_verts: usize = 0,

    fn init(allocator: std.mem.Allocator, options: Options) !Harness {
        setupSokol();
        errdefer shutdownSokol();

        var runtime = try ghostty.Runtime.init(allocator, null);
        errdefer runtime.deinit();

        var renderer = try FtRenderer.init(allocator, .{
            .font_size = 18.0,
            .dpi_scale = 1.0,
            .line_height = 1.0,
            .padding_x = 0.0,
            .padding_y = 0.0,
            .ligatures = true,
            .discover_system_emoji = false,
        }, c.SG_PIXELFORMAT_RGBA8);
        errdefer renderer.deinit();

        const width = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(options.cols)) * renderer.cell_w)));
        const height = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(options.rows)) * renderer.cell_h)));
        const target = RenderTarget.init(width, height);

        return .{
            .allocator = allocator,
            .options = options,
            .runtime = runtime,
            .renderer = renderer,
            .target = target,
            .palette = makePalette(),
            .viewport_width = @floatFromInt(width),
            .viewport_height = @floatFromInt(height),
        };
    }

    fn deinit(self: *Harness) void {
        self.renderer.deinit();
        self.target.deinit();
        self.runtime.deinit();
        shutdownSokol();
    }

    fn prepare(self: *Harness, session: *Session, corpus: []const u8) !void {
        feedChunks(&self.runtime, session.terminal, corpus, self.options.chunk_bytes);
        try self.runtime.updateRenderState(session.render_state, session.terminal);
        self.captureState(session);
    }

    fn captureState(self: *Harness, session: *Session) void {
        self.render_state_rows = @intCast(self.runtime.renderStateRows(session.render_state) orelse 0);
        self.render_state_cols = @intCast(self.runtime.renderStateCols(session.render_state) orelse 0);
        self.dirty_level = self.runtime.getRenderStateDirty(session.render_state) orelse .false_value;
        if (self.runtime.cursorPos(session.render_state)) |cursor| {
            self.final_cursor_row = @intCast(cursor.y);
            self.final_cursor_col = @intCast(cursor.x);
        }
    }

    fn clearDirtyRows(self: *Harness, session: *Session) void {
        if (!self.runtime.populateRowIterator(session.render_state, &session.row_iterator)) return;
        while (self.runtime.nextRow(session.row_iterator)) self.runtime.clearRowDirty(session.row_iterator);
    }

    fn queueOptions(self: *Harness, session: *Session, force_full: bool) terminal_render.QueueOptions {
        const cursor = self.runtime.cursorPos(session.render_state);
        const cursor_style = if (cursor != null and self.runtime.cursorVisible(session.render_state))
            self.runtime.cursorVisualStyle(session.render_state)
        else
            null;
        return .{
            .render_state = session.render_state,
            .row_iterator = &session.row_iterator,
            .row_cells = &session.row_cells,
            .row_count = self.options.rows,
            .col_count = self.options.cols,
            .viewport_width = self.viewport_width,
            .viewport_height = self.viewport_height,
            .force_full = force_full,
            .cursor_row = if (cursor) |value| @intCast(value.y) else std.math.maxInt(usize),
            .cursor_col = if (cursor) |value| @intCast(value.x) else std.math.maxInt(usize),
            .cursor_style = cursor_style,
            .cursor_wide = self.runtime.cursorWideTail(session.render_state),
            .cursor_block = cursor_style == .block,
            .selection_range = null,
            .redraw_range = null,
            .hovered_hyperlink = null,
            .prev_cursor_row = std.math.maxInt(usize),
            .colors = .{
                .default_bg = .{ .r = 18, .g = 20, .b = 28 },
                .default_fg = .{ .r = 220, .g = 220, .b = 220 },
                .cursor_bg = .{ .r = 220, .g = 220, .b = 220 },
                .cursor_fg = .{ .r = 0, .g = 0, .b = 0 },
                .selection_bg = .{ .r = 80, .g = 80, .b = 100 },
                .selection_fg = .{ .r = 255, .g = 255, .b = 255 },
                .search_bg = .{ .r = 55, .g = 55, .b = 70 },
                .search_active_bg = .{ .r = 100, .g = 90, .b = 50 },
                .palette = &self.palette,
            },
        };
    }

    fn queue(self: *Harness, session: *Session, force_full: bool) void {
        self.renderer.frame_count += 1;
        self.renderer.beginFrame();
        self.renderer.queueTerminal(&self.runtime, self.queueOptions(session, force_full));
        self.last_rows_rendered = self.renderer.last_rows_rendered;
        self.last_rows_skipped = self.renderer.last_rows_skipped;
        self.last_cells_visited = self.renderer.last_cells_visited;
        self.last_glyph_runs = self.renderer.last_glyph_runs;
        self.last_bg_rects = self.renderer.last_bg_rects;
        self.last_atlas_flushed = self.renderer.last_atlas_flushed;
        self.last_glyph_verts = self.renderer.glyph_verts_count;
    }

    fn submit(self: *Harness, force_full: bool) void {
        _ = self.renderer.uploadGlyphVerts();
        var pass = std.mem.zeroes(c.sg_pass);
        pass.attachments.colors[0] = self.target.view;
        pass.action.colors[0].load_action = if (force_full) c.SG_LOADACTION_CLEAR else c.SG_LOADACTION_LOAD;
        pass.action.colors[0].clear_value = .{ .r = 18.0 / 255.0, .g = 20.0 / 255.0, .b = 28.0 / 255.0, .a = 1.0 };
        c.sg_begin_pass(&pass);
        c.sgl_draw();
        self.renderer.drawGlyphQuads(self.viewport_width, self.viewport_height, true, .{ 0.006, 0.007, 0.009, 1.0 });
        c.sg_end_pass();
        c.sg_commit();
    }
};

const TimingSamples = struct {
    values: std.ArrayListUnmanaged(i128) = .empty,

    fn deinit(self: *TimingSamples, allocator: std.mem.Allocator) void {
        self.values.deinit(allocator);
    }

    fn append(self: *TimingSamples, allocator: std.mem.Allocator, value: i128) !void {
        try self.values.append(allocator, value);
    }
};

const Results = struct {
    total: TimingSamples = .{},
    cold_render: TimingSamples = .{},
    cold_pipeline: TimingSamples = .{},
    parse: TimingSamples = .{},
    render_state: TimingSamples = .{},
    render: TimingSamples = .{},
    submit: TimingSamples = .{},

    fn deinit(self: *Results, allocator: std.mem.Allocator) void {
        self.total.deinit(allocator);
        self.cold_render.deinit(allocator);
        self.cold_pipeline.deinit(allocator);
        self.parse.deinit(allocator);
        self.render_state.deinit(allocator);
        self.render.deinit(allocator);
        self.submit.deinit(allocator);
    }
};

const TimingSummary = struct {
    minimum_ns: i128,
    median_ns: i128,
    mean_ns: f64,
    p95_ns: i128,
    maximum_ns: i128,
    stddev_ns: f64,
};

fn setupSokol() void {
    var sg_desc = std.mem.zeroes(c.sg_desc);
    sg_desc.buffer_pool_size = 512;
    sg_desc.image_pool_size = 256;
    sg_desc.sampler_pool_size = 64;
    sg_desc.shader_pool_size = 64;
    sg_desc.pipeline_pool_size = 256;
    sg_desc.view_pool_size = 512;
    c.sg_setup(&sg_desc);

    var sgl_desc = std.mem.zeroes(c.sgl_desc_t);
    sgl_desc.color_format = c.SG_PIXELFORMAT_RGBA8;
    sgl_desc.depth_format = c.SG_PIXELFORMAT_NONE;
    sgl_desc.sample_count = 1;
    sgl_desc.max_vertices = 1 << 20;
    sgl_desc.max_commands = 1 << 16;
    c.sgl_setup(&sgl_desc);
}

fn shutdownSokol() void {
    c.sgl_shutdown();
    c.sg_shutdown();
}

fn callbackState(userdata: ?*anyopaque) *CallbackState {
    return @ptrCast(@alignCast(userdata.?));
}

fn writePty(_: ?*anyopaque, userdata: ?*anyopaque, _: [*]const u8, len: usize) callconv(.c) void {
    callbackState(userdata).response_bytes += len;
}

fn bell(_: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
    callbackState(userdata).bells += 1;
}

fn enquiry(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) ghostty.String {
    return .{ .ptr = null, .len = 0 };
}

fn xtversion(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) ghostty.String {
    return .{ .ptr = null, .len = 0 };
}

fn size(_: ?*anyopaque, _: ?*anyopaque, _: *ghostty.SizeReportSize) callconv(.c) bool {
    return false;
}

fn colorScheme(_: ?*anyopaque, _: ?*anyopaque, _: *ghostty.ColorScheme) callconv(.c) bool {
    return false;
}

fn deviceAttributes(_: ?*anyopaque, _: ?*anyopaque, _: *ghostty.DeviceAttributes) callconv(.c) bool {
    return false;
}

fn titleChanged(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}

fn makePalette() [256]ghostty.ColorRgb {
    var palette = [_]ghostty.ColorRgb{.{ .r = 0, .g = 0, .b = 0 }} ** 256;
    palette[0] = .{ .r = 0, .g = 0, .b = 0 };
    palette[1] = .{ .r = 205, .g = 49, .b = 49 };
    palette[2] = .{ .r = 13, .g = 188, .b = 121 };
    palette[3] = .{ .r = 229, .g = 229, .b = 16 };
    palette[4] = .{ .r = 36, .g = 114, .b = 200 };
    palette[5] = .{ .r = 188, .g = 63, .b = 188 };
    palette[6] = .{ .r = 17, .g = 168, .b = 205 };
    palette[7] = .{ .r = 229, .g = 229, .b = 229 };
    palette[8] = .{ .r = 102, .g = 102, .b = 102 };
    palette[9] = .{ .r = 241, .g = 76, .b = 76 };
    palette[10] = .{ .r = 35, .g = 209, .b = 139 };
    palette[11] = .{ .r = 245, .g = 245, .b = 67 };
    palette[12] = .{ .r = 59, .g = 142, .b = 234 };
    palette[13] = .{ .r = 214, .g = 112, .b = 214 };
    palette[14] = .{ .r = 41, .g = 184, .b = 219 };
    palette[15] = .{ .r = 229, .g = 229, .b = 229 };
    var i: usize = 16;
    while (i < 232) : (i += 1) {
        const value = i - 16;
        const r = value / 36;
        const g = (value / 6) % 6;
        const b = value % 6;
        palette[i] = .{
            .r = @intCast(if (r == 0) 0 else 55 + r * 40),
            .g = @intCast(if (g == 0) 0 else 55 + g * 40),
            .b = @intCast(if (b == 0) 0 else 55 + b * 40),
        };
    }
    while (i < 256) : (i += 1) {
        const value: u8 = @intCast(8 + (i - 232) * 10);
        palette[i] = .{ .r = value, .g = value, .b = value };
    }
    return palette;
}

fn appendFormat(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, format, args);
    try list.appendSlice(allocator, text);
}

fn appendRepeated(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try list.appendSlice(allocator, text);
}

fn appendPattern(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8, width: usize) !void {
    var written: usize = 0;
    while (written < width) {
        const count = @min(text.len, width - written);
        try list.appendSlice(allocator, text[0..count]);
        written += count;
    }
}

fn buildCorpus(allocator: std.mem.Allocator, options: Options) ![]u8 {
    if (options.scenario == .replay) {
        const path = options.input_path orelse return error.InputRequired;
        return std.Io.Dir.cwd().readFileAlloc(io.get(), path, allocator, .limited(512 * 1024 * 1024));
    }

    var corpus: std.ArrayListUnmanaged(u8) = .empty;
    errdefer corpus.deinit(allocator);
    switch (options.scenario) {
        .repaint => {
            try corpus.appendSlice(allocator, "\x1b[?1049h\x1b[2J\x1b[H");
            var frame: usize = 0;
            while (frame < options.frames) : (frame += 1) {
                try corpus.appendSlice(allocator, "\x1b[H");
                var row: usize = 0;
                while (row + 1 < options.rows) : (row += 1) {
                    const base = 16 + ((frame * 7 + row * 13) % 240);
                    try appendFormat(&corpus, allocator, "\x1b[38;5;{d}m", .{base});
                    var label_buffer: [128]u8 = undefined;
                    const label = try std.fmt.bufPrint(&label_buffer, " frame={d} row={d} ", .{ frame, row });
                    try corpus.appendSlice(allocator, label);
                    if (label.len < 22) try appendRepeated(&corpus, allocator, " ", 22 - label.len);
                    const fill = "<>[]{}()##==++--";
                    const width = if (options.cols > 22) options.cols - 22 else 0;
                    const split = width / 2;
                    try appendFormat(&corpus, allocator, "\x1b[38;5;{d}m", .{16 + ((base - 16 + 40) % 240)});
                    try appendPattern(&corpus, allocator, fill, split);
                    try appendFormat(&corpus, allocator, "\x1b[38;5;{d}m", .{base});
                    try appendPattern(&corpus, allocator, fill, width - split);
                    try corpus.appendSlice(allocator, "\x1b[0m\n");
                }
                try appendFormat(&corpus, allocator, "\x1b[0mrepaint benchmark frame={d} size={d}x{d}", .{ frame, options.cols, options.rows });
            }
        },
        .scroll => {
            const lines = try std.math.mul(usize, options.frames, options.rows);
            var line: usize = 0;
            while (line < lines) : (line += 1) {
                try appendFormat(&corpus, allocator, "\x1b[38;5;{d}m{d} ", .{ 16 + (line % 240), line });
                const body = " abcdefghijklmnopqrstuvwxyz0123456789";
                const width = if (options.cols > 10) options.cols - 10 else 0;
                try appendPattern(&corpus, allocator, body, width);
                try corpus.appendSlice(allocator, "\x1b[0m\n");
            }
        },
        .styled => {
            var frame: usize = 0;
            while (frame < options.frames) : (frame += 1) {
                var row: usize = 0;
                while (row < options.rows) : (row += 1) {
                    try corpus.appendSlice(allocator,
                        "\x1b[31m16 \x1b[38;5;196m256 \x1b[38;2;120;80;220mtruecolor\x1b[0m " ++
                            "\x1b[1mbold\x1b[22m \x1b[3mitalic\x1b[23m \x1b[4munderline\x1b[24m " ++
                            "\x1b[9mstrike\x1b[29m \x1b[7minverse\x1b[27m \u{250c}\u{2500}\u{2510} " ++
                            "cafe\u{301}\u{754c} ligature ffi\n");
                }
            }
        },
        .replay => unreachable,
    }
    return corpus.toOwnedSlice(allocator);
}

fn feedChunks(runtime: *ghostty.Runtime, terminal: ?*anyopaque, corpus: []const u8, chunk_bytes: usize) void {
    var offset: usize = 0;
    while (offset < corpus.len) {
        const end = @min(offset + chunk_bytes, corpus.len);
        runtime.terminalWrite(terminal, corpus[offset..end]);
        offset = end;
    }
}

fn parseSample(harness: *Harness, corpus: []const u8) !i128 {
    var session = try Session.init(&harness.runtime, harness.options.cols, harness.options.rows);
    defer session.deinit();
    session.activate();
    const start = io.nanoTimestamp();
    feedChunks(&harness.runtime, session.terminal, corpus, harness.options.chunk_bytes);
    return io.nanoTimestamp() - start;
}

fn renderSample(harness: *Harness, session: *Session) i128 {
    const start = io.nanoTimestamp();
    harness.queue(session, true);
    harness.renderer.discardGlyphQuads();
    return io.nanoTimestamp() - start;
}

fn pipelineSample(harness: *Harness, corpus: []const u8) !struct { total: i128, parse: i128, render_state: i128, render: i128, submit: i128 } {
    var session = try Session.init(&harness.runtime, harness.options.cols, harness.options.rows);
    defer session.deinit();
    session.activate();

    var parse_ns: i128 = 0;
    var render_state_ns: i128 = 0;
    var render_ns: i128 = 0;
    var submit_ns: i128 = 0;
    const total_start = io.nanoTimestamp();
    var offset: usize = 0;
    while (offset < corpus.len) {
        const end = @min(offset + harness.options.chunk_bytes, corpus.len);
        var start = io.nanoTimestamp();
        harness.runtime.terminalWrite(session.terminal, corpus[offset..end]);
        parse_ns += io.nanoTimestamp() - start;

        start = io.nanoTimestamp();
        try harness.runtime.updateRenderState(session.render_state, session.terminal);
        render_state_ns += io.nanoTimestamp() - start;
        harness.captureState(&session);

        start = io.nanoTimestamp();
        const force_full = offset == 0;
        harness.queue(&session, force_full);
        if (force_full) harness.clearDirtyRows(&session);
        render_ns += io.nanoTimestamp() - start;

        start = io.nanoTimestamp();
        harness.submit(force_full);
        submit_ns += io.nanoTimestamp() - start;
        offset = end;
    }
    return .{
        .total = io.nanoTimestamp() - total_start,
        .parse = parse_ns,
        .render_state = render_state_ns,
        .render = render_ns,
        .submit = submit_ns,
    };
}

fn run(harness: *Harness, corpus: []const u8, results: *Results) !void {
    switch (harness.options.mode) {
        .parse => {
            var i: usize = 0;
            while (i < harness.options.warmup) : (i += 1) _ = try parseSample(harness, corpus);
            i = 0;
            while (i < harness.options.iterations) : (i += 1) try results.parse.append(harness.allocator, try parseSample(harness, corpus));
        },
        .render_state => {
            var session = try Session.init(&harness.runtime, harness.options.cols, harness.options.rows);
            defer session.deinit();
            session.activate();
            try harness.prepare(&session, corpus);
            var i: usize = 0;
            while (i < harness.options.warmup) : (i += 1) try harness.runtime.updateRenderState(session.render_state, session.terminal);
            i = 0;
            while (i < harness.options.iterations) : (i += 1) {
                const start = io.nanoTimestamp();
                try harness.runtime.updateRenderState(session.render_state, session.terminal);
                try results.render_state.append(harness.allocator, io.nanoTimestamp() - start);
            }
        },
        .render => {
            var session = try Session.init(&harness.runtime, harness.options.cols, harness.options.rows);
            defer session.deinit();
            session.activate();
            try harness.prepare(&session, corpus);
            try results.cold_render.append(harness.allocator, renderSample(harness, &session));
            var i: usize = 0;
            while (i < harness.options.warmup) : (i += 1) _ = renderSample(harness, &session);
            i = 0;
            while (i < harness.options.iterations) : (i += 1) try results.render.append(harness.allocator, renderSample(harness, &session));
        },
        .pipeline => {
            const cold = try pipelineSample(harness, corpus);
            try results.cold_pipeline.append(harness.allocator, cold.total);
            var i: usize = 0;
            while (i < harness.options.warmup) : (i += 1) _ = try pipelineSample(harness, corpus);
            i = 0;
            while (i < harness.options.iterations) : (i += 1) {
                const sample = try pipelineSample(harness, corpus);
                try results.total.append(harness.allocator, sample.total);
                try results.parse.append(harness.allocator, sample.parse);
                try results.render_state.append(harness.allocator, sample.render_state);
                try results.render.append(harness.allocator, sample.render);
                try results.submit.append(harness.allocator, sample.submit);
            }
        },
    }
}

fn summarize(samples: []i128) TimingSummary {
    std.mem.sort(i128, samples, {}, std.sort.asc(i128));
    var sum: f64 = 0;
    for (samples) |sample| sum += @floatFromInt(sample);
    const mean = sum / @as(f64, @floatFromInt(samples.len));
    var variance: f64 = 0;
    for (samples) |sample| {
        const delta = @as(f64, @floatFromInt(sample)) - mean;
        variance += delta * delta;
    }
    variance /= @as(f64, @floatFromInt(samples.len));
    const p95_index = @min(samples.len - 1, ((samples.len * 95 + 99) / 100) - 1);
    return .{
        .minimum_ns = samples[0],
        .median_ns = samples[samples.len / 2],
        .mean_ns = mean,
        .p95_ns = samples[p95_index],
        .maximum_ns = samples[samples.len - 1],
        .stddev_ns = std.math.sqrt(variance),
    };
}

fn printStats(writer: anytype, name: []const u8, samples: []i128, bytes: usize) !void {
    const stats = summarize(samples);
    const seconds = @as(f64, @floatFromInt(stats.median_ns)) / 1_000_000_000.0;
    const throughput = if (seconds > 0) @as(f64, @floatFromInt(bytes)) / seconds / (1024.0 * 1024.0) else 0;
    try writer.interface.print("\n{s}:\n  minimum_ms: {d:.3}\n  median_ms: {d:.3}\n  mean_ms: {d:.3}\n  p95_ms: {d:.3}\n  maximum_ms: {d:.3}\n  stddev_ms: {d:.3}\n", .{
        name,
        @as(f64, @floatFromInt(stats.minimum_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(stats.median_ns)) / 1_000_000.0,
        stats.mean_ns / 1_000_000.0,
        @as(f64, @floatFromInt(stats.p95_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(stats.maximum_ns)) / 1_000_000.0,
        stats.stddev_ns / 1_000_000.0,
    });
    if (bytes != 0) try writer.interface.print("  bytes_s: {d:.0}\n  throughput_mib_s: {d:.3}\n  ns_per_byte: {d:.3}\n", .{
        @as(f64, @floatFromInt(bytes)) / seconds,
        throughput,
        @as(f64, @floatFromInt(stats.median_ns)) / @as(f64, @floatFromInt(bytes)),
    });
}

fn printJsonStats(writer: anytype, name: []const u8, samples: []i128) !void {
    const stats = summarize(samples);
    try writer.interface.print("\"{s}\":{{\"minimum_ns\":{d},\"median_ns\":{d},\"mean_ns\":{d:.3},\"p95_ns\":{d},\"maximum_ns\":{d},\"stddev_ns\":{d:.3}}}", .{
        name, stats.minimum_ns, stats.median_ns, stats.mean_ns, stats.p95_ns, stats.maximum_ns, stats.stddev_ns,
    });
}

fn parseScenario(value: []const u8) !Scenario {
    if (std.mem.eql(u8, value, "repaint")) return .repaint;
    if (std.mem.eql(u8, value, "scroll")) return .scroll;
    if (std.mem.eql(u8, value, "styled")) return .styled;
    if (std.mem.eql(u8, value, "replay")) return .replay;
    return error.InvalidScenario;
}

fn parseMode(value: []const u8) !Mode {
    if (std.mem.eql(u8, value, "parse")) return .parse;
    if (std.mem.eql(u8, value, "render-state")) return .render_state;
    if (std.mem.eql(u8, value, "render")) return .render;
    if (std.mem.eql(u8, value, "pipeline")) return .pipeline;
    return error.InvalidMode;
}

fn parseUnsigned(value: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, value, 10);
}

fn parseOptions(allocator: std.mem.Allocator, args: [][]u8) !Options {
    var options = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingOptionValue;
        const value = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, arg, "--scenario")) options.scenario = try parseScenario(value)
        else if (std.mem.eql(u8, arg, "--input")) options.input_path = try allocator.dupe(u8, value)
        else if (std.mem.eql(u8, arg, "--frames")) options.frames = try parseUnsigned(value)
        else if (std.mem.eql(u8, arg, "--rows")) options.rows = try parseUnsigned(value)
        else if (std.mem.eql(u8, arg, "--cols")) options.cols = try parseUnsigned(value)
        else if (std.mem.eql(u8, arg, "--chunk-bytes")) options.chunk_bytes = try parseUnsigned(value)
        else if (std.mem.eql(u8, arg, "--warmup")) options.warmup = try parseUnsigned(value)
        else if (std.mem.eql(u8, arg, "--iterations")) options.iterations = try parseUnsigned(value)
        else if (std.mem.eql(u8, arg, "--mode")) options.mode = try parseMode(value)
        else return error.UnknownOption;
    }
    if (options.rows == 0 or options.cols == 0 or options.rows > std.math.maxInt(u16) or options.cols > std.math.maxInt(u16)) return error.InvalidGrid;
    if (options.chunk_bytes == 0 or options.iterations == 0) return error.InvalidCount;
    return options;
}

pub fn main(init: std.process.Init) !void {
    io.init(init.io, init.minimal.environ);
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try io.argsAlloc(allocator, init.minimal.args);
    defer io.argsFree(allocator, args);
    const options = try parseOptions(allocator, args);
    defer if (options.input_path) |path| allocator.free(path);

    const corpus = try buildCorpus(allocator, options);
    defer allocator.free(corpus);
    var harness = try Harness.init(allocator, options);
    defer harness.deinit();
    var results = Results{};
    defer results.deinit(allocator);
    try run(&harness, corpus, &results);

    var output_buffer: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writer(io.get(), &output_buffer);
    const checksum = std.hash.Fnv1a_64.hash(corpus);
    if (options.json) {
        const chunks = (corpus.len + options.chunk_bytes - 1) / options.chunk_bytes;
        try output.interface.print("{{\"scenario\":\"{s}\",\"mode\":\"{s}\",\"rows\":{d},\"cols\":{d},\"frames\":{d},\"bytes\":{d},\"chunk_bytes\":{d},\"chunks\":{d},\"iterations\":{d},\"input_checksum\":\"{x}\",\"render_state_rows\":{d},\"render_state_cols\":{d},\"dirty_level\":\"{s}\",\"cursor_row\":{d},\"cursor_col\":{d},\"cells_visited\":{d},\"glyph_runs\":{d},\"bg_rects\":{d},\"atlas_flushed\":{},\"glyph_verts_count\":{d},\"stages\":{{", .{
            @tagName(options.scenario), @tagName(options.mode), options.rows, options.cols, options.frames, corpus.len, options.chunk_bytes, chunks, options.iterations, checksum,
            harness.render_state_rows, harness.render_state_cols, @tagName(harness.dirty_level), harness.final_cursor_row, harness.final_cursor_col,
            harness.last_cells_visited, harness.last_glyph_runs, harness.last_bg_rects, harness.last_atlas_flushed, harness.last_glyph_verts,
        });
        var first = true;
        if (results.parse.values.items.len > 0) {
            if (!first) try output.interface.writeAll(",");
            first = false;
            try printJsonStats(&output, "parse", results.parse.values.items);
        }
        if (results.render_state.values.items.len > 0) {
            if (!first) try output.interface.writeAll(",");
            first = false;
            try printJsonStats(&output, "render_state", results.render_state.values.items);
        }
        if (results.render.values.items.len > 0) {
            if (!first) try output.interface.writeAll(",");
            first = false;
            try printJsonStats(&output, "render_cpu", results.render.values.items);
        }
        if (results.submit.values.items.len > 0) {
            if (!first) try output.interface.writeAll(",");
            first = false;
            try printJsonStats(&output, "submit_cpu", results.submit.values.items);
        }
        if (results.total.values.items.len > 0) {
            if (!first) try output.interface.writeAll(",");
            try printJsonStats(&output, "pipeline", results.total.values.items);
        }
        if (results.cold_render.values.items.len > 0) {
            try output.interface.print(",\"cold_render_cpu_ns\":{d}", .{results.cold_render.values.items[0]});
        }
        if (results.cold_pipeline.values.items.len > 0) {
            try output.interface.print(",\"cold_pipeline_ns\":{d}", .{results.cold_pipeline.values.items[0]});
        }
        try output.interface.writeAll("}}\n");
    } else {
        const chunks = (corpus.len + options.chunk_bytes - 1) / options.chunk_bytes;
        try output.interface.print("scenario: {s}\nmode: {s}\ngrid: {d}x{d}\nframes: {d}\nbytes: {d}\nchunk_bytes: {d}\nchunks: {d}\niterations: {d}\ninput_checksum: {x}\nrender_state: {d}x{d}\ndirty_level: {s}\ncursor: {d},{d}\nrenderer_counters: rows_rendered={d} rows_skipped={d} cells_visited={d} glyph_runs={d} bg_rects={d} atlas_flushed={} glyph_verts_count={d}\n", .{
            @tagName(options.scenario), @tagName(options.mode), options.cols, options.rows, options.frames, corpus.len, options.chunk_bytes, chunks, options.iterations, checksum,
            harness.render_state_cols, harness.render_state_rows, @tagName(harness.dirty_level), harness.final_cursor_row, harness.final_cursor_col,
             harness.last_rows_rendered, harness.last_rows_skipped, harness.last_cells_visited, harness.last_glyph_runs,
             harness.last_bg_rects, harness.last_atlas_flushed, harness.last_glyph_verts,
         });
         if (results.cold_render.values.items.len > 0) try output.interface.print("cold_render_cpu_ms: {d:.3}\n", .{@as(f64, @floatFromInt(results.cold_render.values.items[0])) / 1_000_000.0});
         if (results.cold_pipeline.values.items.len > 0) try output.interface.print("cold_pipeline_ms: {d:.3}\n", .{@as(f64, @floatFromInt(results.cold_pipeline.values.items[0])) / 1_000_000.0});
        if (results.parse.values.items.len > 0) try printStats(&output, "parse", results.parse.values.items, corpus.len);
        if (results.render_state.values.items.len > 0) try printStats(&output, "render_state", results.render_state.values.items, 0);
        if (results.render.values.items.len > 0) try printStats(&output, "render_cpu", results.render.values.items, 0);
        if (results.submit.values.items.len > 0) try printStats(&output, "submit_cpu", results.submit.values.items, 0);
        if (results.total.values.items.len > 0) try printStats(&output, "pipeline", results.total.values.items, corpus.len);
    }
    try output.interface.flush();
}

pub fn deterministicRepaintChecksum(allocator: std.mem.Allocator) !u64 {
    const corpus = try buildCorpus(allocator, .{ .scenario = .repaint, .frames = 10, .rows = 5, .cols = 20 });
    defer allocator.free(corpus);
    return std.hash.Fnv1a_64.hash(corpus);
}

pub fn runCorrectnessTest(allocator: std.mem.Allocator) !void {
    const options = Options{ .scenario = .repaint, .frames = 10, .rows = 5, .cols = 20, .warmup = 0, .iterations = 1 };
    const corpus = try buildCorpus(allocator, options);
    defer allocator.free(corpus);
    var harness = try Harness.init(allocator, options);
    defer harness.deinit();
    var session = try Session.init(&harness.runtime, options.cols, options.rows);
    defer session.deinit();
    session.activate();
    try harness.prepare(&session, corpus);
    if (harness.render_state_rows != options.rows or harness.render_state_cols != options.cols) return error.UnexpectedRenderStateDimensions;
    if (harness.final_cursor_row != 4 or harness.final_cursor_col != 3) return error.UnexpectedCursorPosition;
    harness.queue(&session, true);
    if (harness.last_cells_visited == 0 or harness.last_glyph_verts == 0) return error.EmptyRender;
    harness.submit(true);
}

pub fn runUnicodeGraphemeTest(allocator: std.mem.Allocator) !void {
    const options = Options{ .rows = 2, .cols = 80, .warmup = 0, .iterations = 1 };
    const corpus = "A\u{0300}\u{0301}\u{0302}\u{0303}\u{0304}\u{0305}\u{0306}\u{0307}\u{0308}\u{0309}\u{030A}\u{030B}\u{030C}\u{030D}\u{030E}\u{030F}\u{0310}\u{0311}\u{0312}\u{0313}\u{0314}\u{0315}\u{0316}\u{0317}\u{0318}\u{0319}\u{031A}\n";
    var harness = try Harness.init(allocator, options);
    defer harness.deinit();
    var session = try Session.init(&harness.runtime, options.cols, options.rows);
    defer session.deinit();
    session.activate();
    try harness.prepare(&session, corpus);
    harness.queue(&session, true);
    if (harness.last_cells_visited == 0 or harness.last_glyph_verts == 0) return error.EmptyUnicodeRender;
    harness.submit(true);
}

test "renderer benchmark checksum remains deterministic" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(u64, 0x652825d1a05e7565), try deterministicRepaintChecksum(allocator));
}
