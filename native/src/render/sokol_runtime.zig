const std = @import("std");
const builtin = @import("builtin");
const c = @import("sokol_c");
const App = @import("../app.zig").App;
const ghostty = @import("../term/ghostty.zig");
const bar = @import("../ui/bar.zig");
const LayoutLeaf = @import("../mux.zig").LayoutLeaf;
const MAX_LAYOUT_LEAVES = @import("../mux.zig").MAX_LAYOUT_LEAVES;
const FtRenderer = @import("ft_renderer.zig").FtRenderer;
const FtRendererConfig = @import("ft_renderer.zig").FtRendererConfig;

var g_app: ?*App = null;
var g_title_buf: [256]u8 = [_]u8{0} ** 256;
var g_renderer_ready = false;
var g_logged_first_frame = false;
var g_frame_index: usize = 0;
var g_logged_first_key = false;
var g_logged_first_char = false;
var g_logged_first_mouse = false;
var g_logged_first_scroll = false;
var g_ft_renderer: ?FtRenderer = null;

const CustomTabLayout = struct {
    x: f32,
    width: f32,
    title: []const u8,
};

fn utf8CodepointLen(first_byte: u8) usize {
    if (first_byte < 0x80) return 1;
    if (first_byte < 0xE0) return 2;
    if (first_byte < 0xF0) return 3;
    return 4;
}

fn takeCodepoints(text: []const u8, count: usize) []const u8 {
    var used_bytes: usize = 0;
    var used_codepoints: usize = 0;
    while (used_bytes < text.len and used_codepoints < count) {
        const cp_len = utf8CodepointLen(text[used_bytes]);
        if (used_bytes + cp_len > text.len) break;
        used_bytes += cp_len;
        used_codepoints += 1;
    }
    return text[0..used_bytes];
}

fn fitTabLabel(text: []const u8, max_chars: usize, out_buf: []u8) []const u8 {
    const ellipsis = "...";
    if (max_chars == 0) return "";

    const full = takeCodepoints(text, max_chars);
    if (full.len == text.len) return full;

    if (max_chars <= ellipsis.len) {
        const n = @min(max_chars, out_buf.len);
        @memcpy(out_buf[0..n], ellipsis[0..n]);
        return out_buf[0..n];
    }

    const prefix = takeCodepoints(text, max_chars - ellipsis.len);
    const total = prefix.len + ellipsis.len;
    if (total > out_buf.len) {
        return takeCodepoints(text, max_chars);
    }

    @memcpy(out_buf[0..prefix.len], prefix);
    @memcpy(out_buf[prefix.len..total], ellipsis);
    return out_buf[0..total];
}

fn computeCustomTabLayouts(app: *App, renderer: *FtRenderer, start_x: f32, max_right: f32, layouts: []CustomTabLayout, title_storage: []u8) []CustomTabLayout {
    const tab_count = @min(app.tabCount(), layouts.len);
    _ = renderer;
    if (tab_count == 0 or max_right <= start_x or title_storage.len == 0) return layouts[0..0];

    var temp_title_buf: [256]u8 = undefined;
    const available_width = max_right - start_x;
    if (available_width <= 0) return layouts[0..0];

    const tab_w = available_width / @as(f32, @floatFromInt(tab_count));
    var text_used: usize = 0;
    for (0..tab_count) |ti| {
        const x = start_x + @as(f32, @floatFromInt(ti)) * tab_w;
        const width = if (ti + 1 == tab_count) max_right - x else tab_w;
        if (width <= 0) break;
        const title = app.topBarTitle(ti, false, &temp_title_buf);
        const remaining_storage = title_storage.len - text_used;
        if (remaining_storage == 0) break;
        const copy_len = @min(title.len, remaining_storage);
        @memcpy(title_storage[text_used .. text_used + copy_len], title[0..copy_len]);
        const stored_title = title_storage[text_used .. text_used + copy_len];

        layouts[ti] = .{
            .x = x,
            .width = width,
            .title = stored_title,
        };
        text_used += copy_len;
    }

    return layouts[0..tab_count];
}

fn drawStatusSegments(renderer: *FtRenderer, x: f32, y: f32, bar_h: f32, segments: []const bar.Segment) f32 {
    var cursor_x = x;
    for (segments) |seg| {
        if (seg.text.len == 0) continue;
        const seg_w = @as(f32, @floatFromInt(seg.text.len)) * renderer.cell_w + renderer.cell_w;
        if (seg.bg) |bg| {
            drawBorderRect(cursor_x, 0.0, seg_w, bar_h, bg.r, bg.g, bg.b, 255);
        }
        const fg = seg.fg orelse ghostty.ColorRgb{ .r = 220, .g = 220, .b = 220 };
        renderer.drawLabelFace(cursor_x + renderer.cell_w * 0.5, y, seg.text, fg.r, fg.g, fg.b, if (seg.bold) 1 else 0);
        c.sgl_load_default_pipeline();
        cursor_x += seg_w;
    }
    return cursor_x;
}

fn framebufferSize() struct { width: f32, height: f32 } {
    return .{
        .width = c.sapp_widthf(),
        .height = c.sapp_heightf(),
    };
}

fn windowSizeToPixels(width: f32, height: f32) struct { width: u32, height: u32 } {
    return .{
        .width = @max(1, @as(u32, @intFromFloat(width))),
        .height = @max(1, @as(u32, @intFromFloat(height))),
    };
}

pub fn run(app: *App) !void {
    g_app = app;
    g_renderer_ready = false;
    g_logged_first_frame = false;
    g_frame_index = 0;
    g_logged_first_key = false;
    g_logged_first_char = false;
    g_logged_first_mouse = false;
    g_logged_first_scroll = false;
    g_ft_renderer = null;

    var desc = std.mem.zeroes(c.sapp_desc);
    desc.user_data = app;
    desc.init_userdata_cb = initCb;
    desc.frame_userdata_cb = frameCb;
    desc.cleanup_userdata_cb = cleanupCb;
    desc.event_userdata_cb = eventCb;
    desc.width = @intCast(app.config.window_width);
    desc.height = @intCast(app.config.window_height);
    desc.high_dpi = true;
    desc.enable_clipboard = true;
    desc.window_title = titleCString(app.config.windowTitle());

    c.sapp_run(&desc);
}

fn initCb(user_data: ?*anyopaque) callconv(.c) void {
    const app = appFromUserData(user_data) orelse return;
    std.log.info("sokol init callback", .{});

    var sg_desc = std.mem.zeroes(c.sg_desc);
    sg_desc.environment = c.sglue_environment();
    c.sg_setup(&sg_desc);

    // sokol_gl is required by sokol_fontstash for glyph rendering.
    var sgl_desc = std.mem.zeroes(c.sgl_desc_t);
    sgl_desc.max_vertices = 1 << 20;
    sgl_desc.max_commands = 1 << 18;
    c.sgl_setup(&sgl_desc);

    // Query DPI scale after sg_setup so the GPU context is ready.
    // On a 2× HiDPI display this returns 2.0; on a 1× display it returns 1.0.
    const dpi_scale = c.sapp_dpi_scale();
    std.log.info("sokol dpi_scale={d:.2} font_size={d:.1}", .{ dpi_scale, app.config.font_size });

    g_ft_renderer = FtRenderer.init(std.heap.page_allocator, .{
        .font_size = app.config.font_size,
        .dpi_scale = dpi_scale,
        .padding_x = app.config.font_padding_x,
        .padding_y = app.config.font_padding_y,
        .coverage_boost = app.config.font_coverage_boost,
        .coverage_add = app.config.font_coverage_add,
        .lcd = app.config.font_lcd,
        .embolden = app.config.font_embolden,
    }) catch |err| blk: {
        std.log.err("ft_renderer init failed: {}", .{err});
        break :blk null;
    };

    // Feed measured cell dimensions back to the terminal so ghostty and the
    // mouse encoder use the correct physical pixel sizes.
    if (g_ft_renderer) |renderer| {
        const cw: u32 = @max(1, @as(u32, @intFromFloat(renderer.cell_w)));
        const ch: u32 = @max(1, @as(u32, @intFromFloat(renderer.cell_h)));
        app.setCellSize(cw, ch);
        const pixel_size = windowSizeToPixels(c.sapp_widthf(), c.sapp_heightf());
        app.requestResize(pixel_size.width, pixel_size.height);
    }

    g_renderer_ready = false;

    app.sendFocus(true) catch {};
}

fn frameCb(user_data: ?*anyopaque) callconv(.c) void {
    const app = appFromUserData(user_data) orelse return;
    g_frame_index += 1;
    if (!g_logged_first_frame) {
        g_logged_first_frame = true;
        std.log.info("sokol first frame (ft renderer)", .{});
    }
    app.tick() catch {};

    if (app.pending_quit) {
        c.sapp_request_quit();
        return;
    }

    const fb = framebufferSize();
    const width = fb.width;
    const height = fb.height;

    // Resolve background color for the clear pass.
    var clear_r: f32 = 0.07;
    var clear_g: f32 = 0.08;
    var clear_b: f32 = 0.11;
    if (app.ghostty) |*runtime| {
        if (app.activePane()) |pane| {
            if (pane.render_state_ready) {
                if (runtime.renderStateColors(pane.render_state)) |colors| {
                    clear_r = @as(f32, @floatFromInt(colors.background.r)) / 255.0;
                    clear_g = @as(f32, @floatFromInt(colors.background.g)) / 255.0;
                    clear_b = @as(f32, @floatFromInt(colors.background.b)) / 255.0;
                }
            }
        }
    }

    var pass = std.mem.zeroes(c.sg_pass);
    pass.swapchain = c.sglue_swapchain();
    pass.action.colors[0].load_action = c.SG_LOADACTION_CLEAR;
    pass.action.colors[0].clear_value = .{ .r = clear_r, .g = clear_g, .b = clear_b, .a = 1.0 };
    c.sg_begin_pass(&pass);

    // Compute layout once for the whole frame.
    var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
    const leaves = app.computeActiveLayout(&layout_buf);

    // Queue cell geometry for every pane (no sgl_draw yet).
    if (g_ft_renderer) |*renderer| {
        // Reset the per-frame atlas-upload guard so flushAtlas may upload once
        // this frame.  Pre-rasterize tab bar labels here so their glyphs are
        // included in the same atlas flush as the pane content.
        renderer.beginFrame();
        if (app.tabBarHeight() > 0 and app.shouldDrawTopBarTabs()) {
            const tc = app.tabCount();
            const close_sym = "\xc3\x97"; // U+00D7 ×
            for (0..tc) |ti| {
                var title_buf: [256]u8 = undefined;
                const title = app.topBarTitle(ti, false, &title_buf);
                std.log.info("rendering tab title={s} len={d}", .{ title, title.len });
                std.log.info("preRasterizeLabel", .{});
                renderer.preRasterizeLabel(title);
                renderer.preRasterizeLabel(close_sym);
            }
        }
        if (app.ghostty) |*runtime| {
            if (leaves.len > 0) {
                for (leaves) |leaf| {
                    // Skip panes whose render_state has not been initialized yet
                    // (avoids crashing ghostty on the first frame after a split).
                    if (!leaf.pane.render_state_ready) continue;
                    const ox: f32 = @floatFromInt(leaf.bounds.x);
                    const oy: f32 = @floatFromInt(leaf.bounds.y);
                    const pw: f32 = @floatFromInt(leaf.bounds.width);
                    const ph: f32 = @floatFromInt(leaf.bounds.height);
                    const is_focused = leaf.pane == app.activePane();
                    renderer.queueInViewport(
                        runtime,
                        leaf.pane.render_state,
                        &leaf.pane.row_iterator,
                        &leaf.pane.row_cells,
                        ox,
                        oy,
                        pw,
                        ph,
                        width,
                        height,
                        is_focused,
                    );
                }
            } else if (app.activePane()) |pane| {
                if (pane.render_state_ready) renderer.queueInViewport(
                    runtime,
                    pane.render_state,
                    &pane.row_iterator,
                    &pane.row_cells,
                    0,
                    0,
                    width,
                    height,
                    width,
                    height,
                    true,
                );
            }
        }
    }

    // Ensure atlas is uploaded before drawing tab bar labels.
    // queueInViewport already calls flushAtlas internally, but if no panes were
    // ready this frame (or the tab bar added new glyphs not seen in pane content),
    // we flush here.  The guard in flushAtlas prevents a double upload.
    if (g_ft_renderer) |*renderer| {
        renderer.flushAtlasIfDirty();
    }

    // Draw split borders as filled 2px quads (only when >1 pane).
    // We draw only seam edges (right/bottom of each pane that is not the
    // framebuffer edge) to avoid overdrawing the active pane outline on top
    // of terminal content from neighbouring panes.
    if (leaves.len > 1) {
        const fw: i32 = @intFromFloat(width);
        const fh: i32 = @intFromFloat(height);
        const border_px: f32 = 2.0;

        // Reset viewport + scissor to the full framebuffer so rects are not
        // clipped to the last pane's sub-rect (sgl_defaults() would leave the
        // viewport at whatever queueInViewport set last).
        c.sgl_defaults();
        c.sgl_viewport(0, 0, fw, fh, true);
        c.sgl_scissor_rect(0, 0, fw, fh, true);
        c.sgl_load_default_pipeline();
        c.sgl_matrix_mode_projection();
        c.sgl_load_identity();
        c.sgl_ortho(0.0, width, height, 0.0, -1.0, 1.0);

        const active = app.activePane();
        for (leaves) |leaf| {
            const is_active = leaf.pane == active;
            const x0: f32 = @floatFromInt(leaf.bounds.x);
            const y0: f32 = @floatFromInt(leaf.bounds.y);
            const lw: f32 = @floatFromInt(leaf.bounds.width);
            const lh: f32 = @floatFromInt(leaf.bounds.height);
            const x1 = x0 + lw;
            const y1 = y0 + lh;

            // Colour: active pane gets a light-blue accent; others get a
            // subtle grey.
            const br: u8 = if (is_active) 120 else 60;
            const bg: u8 = if (is_active) 150 else 65;
            const bb: u8 = if (is_active) 220 else 75;
            const ba: u8 = 255;

            // Right seam — only draw if the right edge does not touch the
            // framebuffer boundary (i.e. there is a neighbour to the right).
            if (@as(i32, @intFromFloat(x1)) < fw) {
                // rect drawn at x1 - border_px/2 so it straddles the seam
                drawBorderRect(x1 - border_px / 2.0, y0, border_px, lh, br, bg, bb, ba);
            }
            // Bottom seam — same logic vertically.
            if (@as(i32, @intFromFloat(y1)) < fh) {
                drawBorderRect(x0, y1 - border_px / 2.0, lw, border_px, br, bg, bb, ba);
            }
        }
    }

    // Draw tab bar when ≥2 tabs exist.
    const tbh_u = app.tabBarHeight();
    if (tbh_u > 0) {
        if (g_ft_renderer) |*renderer| {
            const tbh: f32 = @floatFromInt(tbh_u);
            const fw: i32 = @intFromFloat(width);
            const fh: i32 = @intFromFloat(height);

            // Full-framebuffer projection (Y-down, origin top-left).
            c.sgl_defaults();
            c.sgl_viewport(0, 0, fw, fh, true);
            c.sgl_scissor_rect(0, 0, fw, fh, true);
            c.sgl_load_default_pipeline();
            c.sgl_matrix_mode_projection();
            c.sgl_load_identity();
            c.sgl_ortho(0.0, width, height, 0.0, -1.0, 1.0);

            const bar_bg = app.config.top_bar_bg;
            drawBorderRect(0.0, 0.0, width, tbh, bar_bg.r, bar_bg.g, bar_bg.b, 255);

            const tab_count = app.tabCount();
            const active_idx = app.activeTabIndex();
            const tab_w: f32 = if (tab_count > 0) width / @as(f32, @floatFromInt(tab_count)) else width;
            const close_w: f32 = renderer.cell_w + 10.0;
            var title_buf: [256]u8 = undefined;
            var left_text_buf: [512]u8 = undefined;
            var right_text_buf: [512]u8 = undefined;
            var left_segments_buf: [16]bar.Segment = undefined;
            var right_segments_buf: [16]bar.Segment = undefined;
            var custom_tab_layouts: [32]CustomTabLayout = undefined;
            var custom_tab_title_storage: [1024]u8 = undefined;

            const status_y: f32 = @floor((tbh - renderer.cell_h) * 0.5);
            var left_end: f32 = 4.0;
            var right_width: f32 = 0.0;
            var right_start: f32 = width;
            if (app.shouldDrawTopBarStatus()) {
                const left_segments = app.topBarStatus(.left, &left_segments_buf, &left_text_buf);
                const right_segments = app.topBarStatus(.right, &right_segments_buf, &right_text_buf);
                left_end = drawStatusSegments(renderer, 0.0, status_y, tbh, left_segments);
                for (right_segments) |seg| {
                    right_width += (@as(f32, @floatFromInt(seg.text.len)) * renderer.cell_w) + renderer.cell_w;
                }
                right_start = @max(left_end, width - right_width);
                _ = drawStatusSegments(renderer, right_start, status_y, tbh, right_segments);
            }

            if (app.shouldDrawTopBarTabs()) {
                if (app.hasCustomTopBarTabs()) {
                    const tab_gap: f32 = if (right_width > 0) renderer.cell_w else 0.0;
                    const max_right = if (right_width > 0) right_start - tab_gap else width;
                    const layouts = computeCustomTabLayouts(app, renderer, left_end, max_right, &custom_tab_layouts, &custom_tab_title_storage);
                    for (layouts, 0..) |layout, ti| {
                        const is_active = ti == active_idx;
                        const hover_tab = app.hovered_tab_index != null and app.hovered_tab_index.? == ti;
                        const bg = if (is_active)
                            ghostty.ColorRgb{ .r = 64, .g = 68, .b = 86 }
                        else if (hover_tab)
                            ghostty.ColorRgb{ .r = 52, .g = 55, .b = 70 }
                        else
                            ghostty.ColorRgb{ .r = 43, .g = 45, .b = 55 };
                        drawBorderRect(layout.x, 0.0, layout.width, tbh, bg.r, bg.g, bg.b, 255);

                        const label_space = layout.width - renderer.cell_w;
                        const max_label_chars: usize = if (label_space > 0)
                            @max(1, @as(usize, @intFromFloat(label_space / renderer.cell_w)))
                        else
                            0;
                        var display_buf: [256]u8 = undefined;
                        const display_title = fitTabLabel(layout.title, max_label_chars, &display_buf);
                        if (display_title.len > 0) {
                            const fg_r: u8 = if (is_active) 255 else 190;
                            const fg_g: u8 = if (is_active) 255 else 190;
                            const fg_b: u8 = if (is_active) 255 else 190;
                            renderer.drawLabel(layout.x + renderer.cell_w * 0.5, status_y, display_title, fg_r, fg_g, fg_b);
                            c.sgl_load_default_pipeline();
                        }
                    }
                } else {
                    for (0..tab_count) |ti| {
                        const tx: f32 = @as(f32, @floatFromInt(ti)) * tab_w;

                        // Tab background.
                        const is_active = ti == active_idx;
                        const bg_r: u8 = if (is_active) 55 else 35;
                        const bg_g: u8 = if (is_active) 58 else 37;
                        const bg_b: u8 = if (is_active) 72 else 46;
                        drawBorderRect(tx + 1.0, 1.0, tab_w - 2.0, tbh - 1.0, bg_r, bg_g, bg_b, 255);

                        // Active tab: top accent line.
                        if (is_active) {
                            drawBorderRect(tx + 1.0, 0.0, tab_w - 2.0, 2.0, 120, 150, 220, 255);
                        }

                        // Tab title text — leave room for the close button on the right.
                        const hover_close = app.hovered_close_tab_index != null and app.hovered_close_tab_index.? == ti;
                        const title = app.topBarTitle(ti, hover_close, &title_buf);
                        std.log.info("rendering tab title={s} len={d}", .{ title, title.len });
                        const label_space = tab_w - close_w - renderer.cell_w;
                        const max_label_chars: usize = if (label_space > 0)
                            @max(1, @as(usize, @intFromFloat(label_space / renderer.cell_w)))
                        else
                            0;
                        const label_y: f32 = @floor((tbh - renderer.cell_h) * 0.5);
                        const label_x: f32 = @floor(tx + renderer.cell_w * 0.5);
                        var display_buf: [256]u8 = undefined;
                        const display_title = fitTabLabel(title, max_label_chars, &display_buf);
                        if (display_title.len > 0) {
                            const fg_r: u8 = if (is_active) 255 else 185;
                            const fg_g: u8 = if (is_active) 255 else 185;
                            const fg_b: u8 = if (is_active) 255 else 185;
                            std.log.info("drawLabel len={d}", .{display_title.len});
                            renderer.drawLabel(label_x, label_y, display_title, fg_r, fg_g, fg_b);
                            // After drawLabel the pipeline changed; restore defaults for rects.
                            c.sgl_load_default_pipeline();
                        }

                        // Close button "×".
                        const close_x: f32 = @floor(tx + tab_w - close_w + 2.0);
                        const close_y: f32 = @floor((tbh - renderer.cell_h) * 0.5);
                        if (hover_close) {
                            drawBorderRect(close_x - 4.0, 3.0, close_w - 2.0, tbh - 6.0, 92, 44, 44, 255);
                        }
                        renderer.drawLabelFace(close_x, close_y - 1.0, "\xc3\x97", if (hover_close) 255 else 215, if (hover_close) 220 else 140, if (hover_close) 220 else 140, 1); // U+00D7 ×
                        c.sgl_load_default_pipeline();

                        // Separator line between tabs.
                        if (ti + 1 < tab_count) {
                            drawBorderRect(tx + tab_w - 1.0, 1.0, 1.0, tbh - 2.0, 50, 52, 65, 255);
                        }
                    }
                }
            }
        }
    }

    // Flush all queued geometry — exactly once per frame.
    c.sgl_draw();

    c.sg_end_pass();
    c.sg_commit();

    g_renderer_ready = true;

    c.sapp_set_window_title(titleCString(app.activeTitle()));
}

fn cleanupCb(user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    std.log.info("sokol cleanup callback frame_count={d}", .{g_frame_index});
    if (g_ft_renderer) |*renderer| {
        renderer.deinit();
        g_ft_renderer = null;
    }
    c.sgl_shutdown();
    c.sg_shutdown();
}

fn eventCb(ev: [*c]const c.sapp_event, user_data: ?*anyopaque) callconv(.c) void {
    const app = appFromUserData(user_data) orelse return;
    const event = ev.*;

    if (event.type == c.SAPP_EVENTTYPE_QUIT_REQUESTED) {
        std.log.info("sokol quit requested", .{});
    }

    if (builtin.os.tag == .windows) {
        switch (event.type) {
            c.SAPP_EVENTTYPE_KEY_DOWN => handleKeyDown(app, event),
            c.SAPP_EVENTTYPE_CHAR => handleChar(app, event),
            c.SAPP_EVENTTYPE_MOUSE_DOWN => handleMouseButton(app, event, .press),
            c.SAPP_EVENTTYPE_MOUSE_UP => handleMouseButton(app, event, .release),
            c.SAPP_EVENTTYPE_MOUSE_MOVE => handleMouseMove(app, event),
            c.SAPP_EVENTTYPE_MOUSE_SCROLL => handleScroll(app, event),
            c.SAPP_EVENTTYPE_RESIZED => handleResize(app, event),
            c.SAPP_EVENTTYPE_FOCUSED => app.sendFocus(true) catch {},
            c.SAPP_EVENTTYPE_UNFOCUSED => app.sendFocus(false) catch {},
            c.SAPP_EVENTTYPE_QUIT_REQUESTED => c.sapp_request_quit(),
            else => {},
        }
        return;
    }

    switch (event.type) {
        c.SAPP_EVENTTYPE_KEY_DOWN => handleKeyDown(app, event),
        c.SAPP_EVENTTYPE_CHAR => handleChar(app, event),
        c.SAPP_EVENTTYPE_MOUSE_DOWN => handleMouseButton(app, event, .press),
        c.SAPP_EVENTTYPE_MOUSE_UP => handleMouseButton(app, event, .release),
        c.SAPP_EVENTTYPE_MOUSE_MOVE => handleMouseMove(app, event),
        c.SAPP_EVENTTYPE_MOUSE_SCROLL => app.scroll(event.mouse_x, event.mouse_y, -@as(isize, @intFromFloat(event.scroll_y))),
        c.SAPP_EVENTTYPE_RESIZED => handleResize(app, event),
        c.SAPP_EVENTTYPE_FOCUSED => app.sendFocus(true) catch {},
        c.SAPP_EVENTTYPE_UNFOCUSED => app.sendFocus(false) catch {},
        c.SAPP_EVENTTYPE_QUIT_REQUESTED => c.sapp_request_quit(),
        else => {},
    }
}

fn handleKeyDown(app: *App, event: c.sapp_event) void {
    if (event.key_code == c.SAPP_KEYCODE_ESCAPE) {
        c.sapp_request_quit();
        return;
    }

    if (!g_logged_first_key and builtin.os.tag == .windows) {
        g_logged_first_key = true;
        std.log.info("first Windows key event key_code={d}", .{event.key_code});
    }

    const mods = ghosttyMods(event.modifiers);
    const key = mapKey(event.key_code);

    // Give Lua a chance to consume this key before the terminal sees it.
    if (key != .unidentified) {
        const key_name = @tagName(key);
        if (app.fireOnKey(key_name, mods)) return;
    }

    if (key != .unidentified) _ = app.sendKey(key, mods, null) catch {};
}

fn handleChar(app: *App, event: c.sapp_event) void {
    if (!g_logged_first_char and builtin.os.tag == .windows) {
        g_logged_first_char = true;
        std.log.info("first Windows char event char_code={d}", .{event.char_code});
    }

    var utf8_buf: [5]u8 = [_]u8{0} ** 5;
    const utf8 = encodeCodepoint(event.char_code, &utf8_buf) orelse return;
    app.sendText(utf8) catch {};
}

fn handleMouseButton(app: *App, event: c.sapp_event, action: ghostty.MouseAction) void {
    if (!g_logged_first_mouse and builtin.os.tag == .windows) {
        g_logged_first_mouse = true;
        std.log.info("first Windows mouse event button={d} x={d:.2} y={d:.2}", .{ event.mouse_button, event.mouse_x, event.mouse_y });
    }

    // Intercept clicks in the tab bar (only on press; release falls through).
    if (action == .press) {
        const tbh: f32 = @floatFromInt(app.tabBarHeight());
        if (tbh > 0 and event.mouse_y < tbh) {
            if (event.mouse_button == c.SAPP_MOUSEBUTTON_LEFT) {
                const tab_count = app.tabCount();
                const win_w = c.sapp_widthf();
                if (tab_count > 0 and win_w > 0) {
                    if (app.hasCustomTopBarTabs()) {
                        if (app.hovered_tab_index) |ti| app.switchTab(ti);
                        return;
                    }
                    const tab_w: f32 = win_w / @as(f32, @floatFromInt(tab_count));
                    // Guard: tab_w must be positive and finite to avoid @intFromFloat panic.
                    const raw = event.mouse_x / tab_w;
                    const clamped = @min(@as(f32, @floatFromInt(tab_count - 1)), @max(0.0, raw));
                    const ti: usize = @intFromFloat(clamped);
                    // Determine if the close button was hit.
                    // close region: last cell_w + 4 px of the tab slot.
                    const close_w: f32 = if (g_ft_renderer) |r| r.cell_w + 10.0 else 26.0;
                    const tab_right: f32 = (@as(f32, @floatFromInt(ti)) + 1.0) * tab_w;
                    if (event.mouse_x >= tab_right - close_w) {
                        // Close button: switch to that tab first, then close.
                        app.switchTab(ti);
                        app.closeTab();
                    } else {
                        app.switchTab(ti);
                    }
                }
            }
            return; // do not forward to pane
        }
    }

    const button = switch (event.mouse_button) {
        c.SAPP_MOUSEBUTTON_LEFT => ghostty.MouseButton.left,
        c.SAPP_MOUSEBUTTON_RIGHT => ghostty.MouseButton.right,
        c.SAPP_MOUSEBUTTON_MIDDLE => ghostty.MouseButton.middle,
        else => return,
    };
    app.sendMouse(action, button, event.mouse_x, event.mouse_y, ghosttyMods(event.modifiers)) catch {};
}

fn handleMouseMove(app: *App, event: c.sapp_event) void {
    const close_w: f32 = if (g_ft_renderer) |r| r.cell_w + 10.0 else 26.0;
    app.updateTopBarHover(event.mouse_x, event.mouse_y, c.sapp_widthf(), close_w);
    app.sendMouse(.motion, null, event.mouse_x, event.mouse_y, ghosttyMods(event.modifiers)) catch {};
}

fn handleScroll(app: *App, event: c.sapp_event) void {
    if (!g_logged_first_scroll and builtin.os.tag == .windows) {
        g_logged_first_scroll = true;
        std.log.info("first Windows scroll event delta={d:.2}", .{event.scroll_y});
    }
    app.scroll(event.mouse_x, event.mouse_y, -@as(isize, @intFromFloat(event.scroll_y)));
}

fn handleResize(app: *App, event: c.sapp_event) void {
    const pixel_size = windowSizeToPixels(@floatFromInt(event.framebuffer_width), @floatFromInt(event.framebuffer_height));
    app.requestResize(pixel_size.width, pixel_size.height);
}

fn mapKey(key_code: c.sapp_keycode) ghostty.Key {
    return switch (key_code) {
        c.SAPP_KEYCODE_A => .a,
        c.SAPP_KEYCODE_B => .b,
        c.SAPP_KEYCODE_C => .c,
        c.SAPP_KEYCODE_D => .d,
        c.SAPP_KEYCODE_E => .e,
        c.SAPP_KEYCODE_F => .f,
        c.SAPP_KEYCODE_G => .g,
        c.SAPP_KEYCODE_H => .h,
        c.SAPP_KEYCODE_I => .i,
        c.SAPP_KEYCODE_J => .j,
        c.SAPP_KEYCODE_K => .k,
        c.SAPP_KEYCODE_L => .l,
        c.SAPP_KEYCODE_M => .m,
        c.SAPP_KEYCODE_N => .n,
        c.SAPP_KEYCODE_O => .o,
        c.SAPP_KEYCODE_P => .p,
        c.SAPP_KEYCODE_Q => .q,
        c.SAPP_KEYCODE_R => .r,
        c.SAPP_KEYCODE_S => .s,
        c.SAPP_KEYCODE_T => .t,
        c.SAPP_KEYCODE_U => .u,
        c.SAPP_KEYCODE_V => .v,
        c.SAPP_KEYCODE_W => .w,
        c.SAPP_KEYCODE_X => .x,
        c.SAPP_KEYCODE_Y => .y,
        c.SAPP_KEYCODE_Z => .z,
        c.SAPP_KEYCODE_0 => .digit_0,
        c.SAPP_KEYCODE_1 => .digit_1,
        c.SAPP_KEYCODE_2 => .digit_2,
        c.SAPP_KEYCODE_3 => .digit_3,
        c.SAPP_KEYCODE_4 => .digit_4,
        c.SAPP_KEYCODE_5 => .digit_5,
        c.SAPP_KEYCODE_6 => .digit_6,
        c.SAPP_KEYCODE_7 => .digit_7,
        c.SAPP_KEYCODE_8 => .digit_8,
        c.SAPP_KEYCODE_9 => .digit_9,
        c.SAPP_KEYCODE_ENTER => .enter,
        c.SAPP_KEYCODE_TAB => .tab,
        c.SAPP_KEYCODE_BACKSPACE => .backspace,
        c.SAPP_KEYCODE_DELETE => .delete,
        c.SAPP_KEYCODE_INSERT => .insert,
        c.SAPP_KEYCODE_RIGHT => .arrow_right,
        c.SAPP_KEYCODE_LEFT => .arrow_left,
        c.SAPP_KEYCODE_DOWN => .arrow_down,
        c.SAPP_KEYCODE_UP => .arrow_up,
        c.SAPP_KEYCODE_PAGE_UP => .page_up,
        c.SAPP_KEYCODE_PAGE_DOWN => .page_down,
        c.SAPP_KEYCODE_HOME => .home,
        c.SAPP_KEYCODE_END => .end,
        c.SAPP_KEYCODE_SPACE => .space,
        c.SAPP_KEYCODE_MINUS => .minus,
        c.SAPP_KEYCODE_EQUAL => .equal,
        c.SAPP_KEYCODE_LEFT_BRACKET => .bracket_left,
        c.SAPP_KEYCODE_RIGHT_BRACKET => .bracket_right,
        c.SAPP_KEYCODE_BACKSLASH => .backslash,
        c.SAPP_KEYCODE_SEMICOLON => .semicolon,
        c.SAPP_KEYCODE_APOSTROPHE => .quote,
        c.SAPP_KEYCODE_GRAVE_ACCENT => .backquote,
        c.SAPP_KEYCODE_COMMA => .comma,
        c.SAPP_KEYCODE_PERIOD => .period,
        c.SAPP_KEYCODE_SLASH => .slash,
        c.SAPP_KEYCODE_ESCAPE => .escape,
        c.SAPP_KEYCODE_F1 => .f1,
        c.SAPP_KEYCODE_F2 => .f2,
        c.SAPP_KEYCODE_F3 => .f3,
        c.SAPP_KEYCODE_F4 => .f4,
        c.SAPP_KEYCODE_F5 => .f5,
        c.SAPP_KEYCODE_F6 => .f6,
        c.SAPP_KEYCODE_F7 => .f7,
        c.SAPP_KEYCODE_F8 => .f8,
        c.SAPP_KEYCODE_F9 => .f9,
        c.SAPP_KEYCODE_F10 => .f10,
        c.SAPP_KEYCODE_F11 => .f11,
        c.SAPP_KEYCODE_F12 => .f12,
        else => .unidentified,
    };
}

fn ghosttyMods(modifiers: u32) u32 {
    var mods: u32 = ghostty.Mods.none;
    if ((modifiers & c.SAPP_MODIFIER_SHIFT) != 0) mods |= ghostty.Mods.shift;
    if ((modifiers & c.SAPP_MODIFIER_CTRL) != 0) mods |= ghostty.Mods.ctrl;
    if ((modifiers & c.SAPP_MODIFIER_ALT) != 0) mods |= ghostty.Mods.alt;
    if ((modifiers & c.SAPP_MODIFIER_SUPER) != 0) mods |= ghostty.Mods.super;
    return mods;
}

fn titleCString(text: []const u8) [*:0]const u8 {
    const len = @min(text.len, g_title_buf.len - 1);
    @memset(g_title_buf[0..], 0);
    @memcpy(g_title_buf[0..len], text[0..len]);
    g_title_buf[len] = 0;
    return @ptrCast(&g_title_buf);
}

fn encodeCodepoint(codepoint: u32, buf: *[5]u8) ?[]const u8 {
    if (codepoint == 0) return null;
    if (codepoint < 0x80) {
        buf[0] = @intCast(codepoint);
        return buf[0..1];
    }
    if (codepoint < 0x800) {
        buf[0] = @intCast(0xC0 | (codepoint >> 6));
        buf[1] = @intCast(0x80 | (codepoint & 0x3F));
        return buf[0..2];
    }
    if (codepoint < 0x10000) {
        buf[0] = @intCast(0xE0 | (codepoint >> 12));
        buf[1] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (codepoint & 0x3F));
        return buf[0..3];
    }
    buf[0] = @intCast(0xF0 | (codepoint >> 18));
    buf[1] = @intCast(0x80 | ((codepoint >> 12) & 0x3F));
    buf[2] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
    buf[3] = @intCast(0x80 | (codepoint & 0x3F));
    return buf[0..4];
}

fn appFromUserData(user_data: ?*anyopaque) ?*App {
    const ptr = user_data orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// Draw a filled RGBA rectangle using the current sokol_gl projection.
/// Assumes the default pipeline (no texture) is active.
fn drawBorderRect(x: f32, y: f32, w: f32, h: f32, r: u8, g: u8, b: u8, a: u8) void {
    const rf = @as(f32, @floatFromInt(r)) / 255.0;
    const gf = @as(f32, @floatFromInt(g)) / 255.0;
    const bf = @as(f32, @floatFromInt(b)) / 255.0;
    const af = @as(f32, @floatFromInt(a)) / 255.0;
    c.sgl_begin_quads();
    c.sgl_c4f(rf, gf, bf, af);
    c.sgl_v2f(x, y);
    c.sgl_v2f(x + w, y);
    c.sgl_v2f(x + w, y + h);
    c.sgl_v2f(x, y + h);
    c.sgl_end();
}
