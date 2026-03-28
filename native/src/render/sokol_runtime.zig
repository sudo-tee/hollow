const std = @import("std");
const builtin = @import("builtin");
const c = @import("sokol_c");
const App = @import("../app.zig").App;
const ghostty = @import("../term/ghostty.zig");
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

    const fb = framebufferSize();
    const width = fb.width;
    const height = fb.height;

    // Resolve background color for the clear pass.
    var clear_r: f32 = 0.07;
    var clear_g: f32 = 0.08;
    var clear_b: f32 = 0.11;
    if (app.ghostty) |*runtime| {
        if (app.activePane()) |pane| {
            if (runtime.renderStateColors(pane.render_state)) |colors| {
                clear_r = @as(f32, @floatFromInt(colors.background.r)) / 255.0;
                clear_g = @as(f32, @floatFromInt(colors.background.g)) / 255.0;
                clear_b = @as(f32, @floatFromInt(colors.background.b)) / 255.0;
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
                );
            }
        }
    }

    // Queue split-border lines (only when >1 pane).
    if (leaves.len > 1) {
        // Reset to full-framebuffer viewport for border lines.
        c.sgl_defaults();
        c.sgl_viewport(0, 0, @as(c_int, @intFromFloat(width)), @as(c_int, @intFromFloat(height)), true);
        c.sgl_matrix_mode_projection();
        c.sgl_load_identity();
        c.sgl_ortho(0.0, width, height, 0.0, -1.0, 1.0);
        c.sgl_begin_lines();
        c.sgl_c4b(80, 80, 80, 255);
        for (leaves) |leaf| {
            const x0: f32 = @floatFromInt(leaf.bounds.x);
            const y0: f32 = @floatFromInt(leaf.bounds.y);
            const x1: f32 = x0 + @as(f32, @floatFromInt(leaf.bounds.width));
            const y1: f32 = y0 + @as(f32, @floatFromInt(leaf.bounds.height));
            // Right edge
            c.sgl_v2f(x1, y0);
            c.sgl_v2f(x1, y1);
            // Bottom edge
            c.sgl_v2f(x0, y1);
            c.sgl_v2f(x1, y1);
        }
        c.sgl_end();
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
        c.SAPP_EVENTTYPE_MOUSE_SCROLL => app.scroll(-@as(isize, @intFromFloat(event.scroll_y))),
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

    const button = switch (event.mouse_button) {
        c.SAPP_MOUSEBUTTON_LEFT => ghostty.MouseButton.left,
        c.SAPP_MOUSEBUTTON_RIGHT => ghostty.MouseButton.right,
        c.SAPP_MOUSEBUTTON_MIDDLE => ghostty.MouseButton.middle,
        else => return,
    };
    app.sendMouse(action, button, event.mouse_x, event.mouse_y, ghosttyMods(event.modifiers)) catch {};
}

fn handleMouseMove(app: *App, event: c.sapp_event) void {
    app.sendMouse(.motion, null, event.mouse_x, event.mouse_y, ghosttyMods(event.modifiers)) catch {};
}

fn handleScroll(app: *App, event: c.sapp_event) void {
    if (!g_logged_first_scroll and builtin.os.tag == .windows) {
        g_logged_first_scroll = true;
        std.log.info("first Windows scroll event delta={d:.2}", .{event.scroll_y});
    }
    app.scroll(-@as(isize, @intFromFloat(event.scroll_y)));
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
