/// Kitty graphics protocol support — image placement and texture management.
///
/// Contains:
///   - `expandKittyPixels`: converts Kitty image formats (RGBA/RGB/gray/PNG) to RGBA8.
///   - `getOrCreateKittyTexture`: GPU texture cache for Kitty images.
///   - `clipTexturedQuad`: clips a textured quad to pane bounds with UV adjustment.
///   - `queueKittyLayerInPane`: draws Kitty placement layers for a pane.

const std = @import("std");
const c = @import("sokol_c");
const ghostty = @import("../term/ghostty.zig");
const fastmem = @import("../fastmem.zig");

const ft_types = @import("ft_types.zig");
const FtRenderer = @import("ft_renderer.zig").FtRenderer;

const KittyTexture = ft_types.KittyTexture;
const KittyTextureKey = ft_types.KittyTextureKey;

extern fn hollow_decode_png_bytes(
    data: [*]const u8,
    data_len: usize,
    out_width: *u32,
    out_height: *u32,
    out_pixels: *?[*]u8,
    out_len: *usize,
) callconv(.c) bool;

extern fn hollow_decode_png_bytes_free(pixels: ?[*]u8) callconv(.c) void;

// ── Pixel format expansion ────────────────────────────────────────────────────

pub fn expandKittyPixels(allocator: std.mem.Allocator, format: ghostty.KittyImageFormat, pixels: []const u8, width: u32, height: u32) ?[]u8 {
    const pixel_count = @as(usize, width) * @as(usize, height);
    const out_len = pixel_count * 4;

    if (format == .png) {
        var decoded_width: u32 = 0;
        var decoded_height: u32 = 0;
        var decoded_ptr: ?[*]u8 = null;
        var decoded_len: usize = 0;
        if (!hollow_decode_png_bytes(pixels.ptr, pixels.len, &decoded_width, &decoded_height, &decoded_ptr, &decoded_len)) return null;
        defer hollow_decode_png_bytes_free(decoded_ptr);
        if (decoded_ptr == null or decoded_width != width or decoded_height != height or decoded_len != out_len) return null;
        return allocator.dupe(u8, decoded_ptr.?[0..decoded_len]) catch null;
    }

    var out = allocator.alloc(u8, out_len) catch return null;
    errdefer allocator.free(out);

    switch (format) {
        .rgba => {
            if (pixels.len != out_len) return null;
            fastmem.copy(u8, out, pixels);
        },
        .rgb => {
            if (pixels.len != pixel_count * 3) return null;
            var src_idx: usize = 0;
            var dst_idx: usize = 0;
            while (dst_idx < out_len) : (dst_idx += 4) {
                out[dst_idx + 0] = pixels[src_idx + 0];
                out[dst_idx + 1] = pixels[src_idx + 1];
                out[dst_idx + 2] = pixels[src_idx + 2];
                out[dst_idx + 3] = 255;
                src_idx += 3;
            }
        },
        .gray => {
            if (pixels.len != pixel_count) return null;
            for (pixels, 0..) |value, idx| {
                const dst_idx = idx * 4;
                out[dst_idx + 0] = value;
                out[dst_idx + 1] = value;
                out[dst_idx + 2] = value;
                out[dst_idx + 3] = 255;
            }
        },
        .gray_alpha => {
            if (pixels.len != pixel_count * 2) return null;
            var src_idx: usize = 0;
            var dst_idx: usize = 0;
            while (dst_idx < out_len) : (dst_idx += 4) {
                const value = pixels[src_idx + 0];
                out[dst_idx + 0] = value;
                out[dst_idx + 1] = value;
                out[dst_idx + 2] = value;
                out[dst_idx + 3] = pixels[src_idx + 1];
                src_idx += 2;
            }
        },
        .png => unreachable,
    }

    return out;
}

// ── Texture cache ─────────────────────────────────────────────────────────────

pub fn getOrCreateKittyTexture(self: *FtRenderer, runtime: *ghostty.Runtime, image_id: u32, image: ?*const anyopaque) ?*KittyTexture {
    var width: u32 = 0;
    var height: u32 = 0;
    var format: ghostty.KittyImageFormat = .rgba;
    var data_ptr: ?[*]const u8 = null;
    var data_len: usize = 0;
    if (!runtime.kittyImageData(image, .width, &width) or width == 0) return null;
    if (!runtime.kittyImageData(image, .height, &height) or height == 0) return null;
    if (!runtime.kittyImageData(image, .format, &format)) return null;
    if (!runtime.kittyImageData(image, .data_ptr, @ptrCast(&data_ptr)) or data_ptr == null) return null;
    if (!runtime.kittyImageData(image, .data_len, &data_len) or data_len == 0) return null;

    const key = KittyTextureKey{
        .image_id = image_id,
        .width = width,
        .height = height,
        .format = format,
        .data_len = data_len,
        .data_ptr = @intFromPtr(data_ptr.?),
    };

    var free_slot: ?usize = null;
    for (&self.kitty_textures, 0..) |*slot, i| {
        if (slot.*) |*tex| {
            if (std.meta.eql(tex.key, key)) return tex;
        } else if (free_slot == null) {
            free_slot = i;
        }
    }

    const pixels = data_ptr.?[0..data_len];
    const rgba_pixels = expandKittyPixels(self.allocator, format, pixels, width, height) orelse return null;
    defer self.allocator.free(rgba_pixels);

    const slot_idx = free_slot orelse 0;
    if (self.kitty_textures[slot_idx]) |*old| old.deinit();

    var img_desc = std.mem.zeroes(c.sg_image_desc);
    img_desc.width = @intCast(width);
    img_desc.height = @intCast(height);
    img_desc.pixel_format = c.SG_PIXELFORMAT_RGBA8;
    img_desc.data.mip_levels[0].ptr = rgba_pixels.ptr;
    img_desc.data.mip_levels[0].size = rgba_pixels.len;
    img_desc.label = "kitty-image";
    const sg_img = c.sg_make_image(&img_desc);

    var view_desc = std.mem.zeroes(c.sg_view_desc);
    view_desc.texture.image = sg_img;
    const view = c.sg_make_view(&view_desc);

    self.kitty_textures[slot_idx] = KittyTexture{
        .key = key,
        .image = sg_img,
        .view = view,
    };
    return &self.kitty_textures[slot_idx].?;
}

// ── Quad clipping ─────────────────────────────────────────────────────────────

pub fn clipTexturedQuad(
    x: *f32,
    y: *f32,
    w: *f32,
    h: *f32,
    uv0_x: *f32,
    uv0_y: *f32,
    uv1_x: *f32,
    uv1_y: *f32,
    pane_w: f32,
    pane_h: f32,
) bool {
    if (w.* <= 0 or h.* <= 0) return false;
    const x_end = x.* + w.*;
    const y_end = y.* + h.*;
    if (x_end <= 0 or y_end <= 0 or x.* >= pane_w or y.* >= pane_h) return false;

    if (x.* < 0) {
        const t = (-x.*) / w.*;
        uv0_x.* = std.math.lerp(uv0_x.*, uv1_x.*, t);
        w.* += x.*;
        x.* = 0;
    }
    if (y.* < 0) {
        const t = (-y.*) / h.*;
        uv0_y.* = std.math.lerp(uv0_y.*, uv1_y.*, t);
        h.* += y.*;
        y.* = 0;
    }
    if (x.* + w.* > pane_w) {
        const t = (pane_w - x.*) / w.*;
        uv1_x.* = std.math.lerp(uv0_x.*, uv1_x.*, t);
        w.* = pane_w - x.*;
    }
    if (y.* + h.* > pane_h) {
        const t = (pane_h - y.*) / h.*;
        uv1_y.* = std.math.lerp(uv0_y.*, uv1_y.*, t);
        h.* = pane_h - y.*;
    }
    return w.* > 0 and h.* > 0;
}

// ── Kitty layer drawing ───────────────────────────────────────────────────────

pub fn queueKittyLayerInPane(
    self: *FtRenderer,
    runtime: *ghostty.Runtime,
    terminal: ?*anyopaque,
    layer: ghostty.KittyPlacementLayer,
    ox: f32,
    oy: f32,
    pw: f32,
    ph: f32,
    fb_w: f32,
    fb_h: f32,
) void {
    const term = terminal orelse return;
    const graphics = runtime.terminalKittyGraphics(term) orelse return;
    const iterator = runtime.createKittyPlacementIterator() catch return;
    defer runtime.freeKittyPlacementIterator(iterator);
    if (!runtime.populateKittyPlacementIterator(graphics, iterator)) return;
    if (!runtime.setKittyPlacementLayer(iterator, layer)) return;

    c.sgl_defaults();
    c.sgl_viewport(0, 0, @intFromFloat(fb_w), @intFromFloat(fb_h), true);
    c.sgl_scissor_rect(@intFromFloat(ox), @intFromFloat(oy), @intFromFloat(pw), @intFromFloat(ph), true);
    c.sgl_matrix_mode_projection();
    c.sgl_load_identity();
    c.sgl_ortho(0.0, fb_w, fb_h, 0.0, -1.0, 1.0);

    while (runtime.nextKittyPlacement(iterator)) {
        var is_virtual = false;
        if (!runtime.kittyPlacementData(iterator, .is_virtual, &is_virtual) or is_virtual) continue;

        var image_id: u32 = 0;
        if (!runtime.kittyPlacementData(iterator, .image_id, &image_id)) continue;
        const image = runtime.kittyGraphicsImage(graphics, image_id) orelse continue;
        const render_info = runtime.kittyPlacementRenderInfo(iterator, image, term) orelse continue;
        if (!render_info.viewport_visible or render_info.pixel_width == 0 or render_info.pixel_height == 0) continue;

        const tex = getOrCreateKittyTexture(self, runtime, image_id, image) orelse continue;

        var x = self.padding_x + @as(f32, @floatFromInt(render_info.viewport_col)) * self.cell_w;
        var y = self.padding_y + @as(f32, @floatFromInt(render_info.viewport_row)) * self.cell_h;
        var w = @as(f32, @floatFromInt(render_info.pixel_width));
        var h = @as(f32, @floatFromInt(render_info.pixel_height));
        var uv0_x = @as(f32, @floatFromInt(render_info.source_x)) / @as(f32, @floatFromInt(tex.key.width));
        var uv0_y = @as(f32, @floatFromInt(render_info.source_y)) / @as(f32, @floatFromInt(tex.key.height));
        var uv1_x = @as(f32, @floatFromInt(render_info.source_x + render_info.source_width)) / @as(f32, @floatFromInt(tex.key.width));
        var uv1_y = @as(f32, @floatFromInt(render_info.source_y + render_info.source_height)) / @as(f32, @floatFromInt(tex.key.height));
        if (!clipTexturedQuad(&x, &y, &w, &h, &uv0_x, &uv0_y, &uv1_x, &uv1_y, pw, ph)) continue;

        x += ox;
        y += oy;

        c.sgl_load_default_pipeline();
        c.sgl_enable_texture();
        c.sgl_texture(tex.view, self.kitty_image_smp);
        c.sgl_begin_quads();
        c.sgl_c4b(255, 255, 255, 255);
        c.sgl_v2f_t2f(x, y, uv0_x, uv0_y);
        c.sgl_v2f_t2f(x + w, y, uv1_x, uv0_y);
        c.sgl_v2f_t2f(x + w, y + h, uv1_x, uv1_y);
        c.sgl_v2f_t2f(x, y + h, uv0_x, uv1_y);
        c.sgl_end();
        c.sgl_disable_texture();
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "clipTexturedQuad: fully visible quad passes through" {
    var x: f32 = 10;
    var y: f32 = 20;
    var w: f32 = 100;
    var h: f32 = 50;
    var uv0_x: f32 = 0;
    var uv0_y: f32 = 0;
    var uv1_x: f32 = 1;
    var uv1_y: f32 = 1;
    try std.testing.expect(clipTexturedQuad(&x, &y, &w, &h, &uv0_x, &uv0_y, &uv1_x, &uv1_y, 200, 200));
    try std.testing.expectEqual(@as(f32, 10), x);
    try std.testing.expectEqual(@as(f32, 20), y);
    try std.testing.expectEqual(@as(f32, 100), w);
    try std.testing.expectEqual(@as(f32, 50), h);
}

test "clipTexturedQuad: fully outside returns false" {
    var x: f32 = 300;
    var y: f32 = 300;
    var w: f32 = 50;
    var h: f32 = 50;
    var uv0_x: f32 = 0;
    var uv0_y: f32 = 0;
    var uv1_x: f32 = 1;
    var uv1_y: f32 = 1;
    try std.testing.expect(!clipTexturedQuad(&x, &y, &w, &h, &uv0_x, &uv0_y, &uv1_x, &uv1_y, 200, 200));
}

test "clipTexturedQuad: clips left edge" {
    var x: f32 = -20;
    var y: f32 = 0;
    var w: f32 = 100;
    var h: f32 = 50;
    var uv0_x: f32 = 0;
    var uv0_y: f32 = 0;
    var uv1_x: f32 = 1;
    var uv1_y: f32 = 1;
    try std.testing.expect(clipTexturedQuad(&x, &y, &w, &h, &uv0_x, &uv0_y, &uv1_x, &uv1_y, 200, 200));
    try std.testing.expectEqual(@as(f32, 0), x);
    try std.testing.expectEqual(@as(f32, 80), w); // 100 - 20
    // UV should have been adjusted
    try std.testing.expect(uv0_x > 0);
}

test "clipTexturedQuad: clips right edge" {
    var x: f32 = 150;
    var y: f32 = 0;
    var w: f32 = 100;
    var h: f32 = 50;
    var uv0_x: f32 = 0;
    var uv0_y: f32 = 0;
    var uv1_x: f32 = 1;
    var uv1_y: f32 = 1;
    try std.testing.expect(clipTexturedQuad(&x, &y, &w, &h, &uv0_x, &uv0_y, &uv1_x, &uv1_y, 200, 200));
    try std.testing.expectEqual(@as(f32, 50), w); // 200 - 150
    try std.testing.expect(uv1_x < 1);
}

test "clipTexturedQuad: zero-size returns false" {
    var x: f32 = 10;
    var y: f32 = 10;
    var w: f32 = 0;
    var h: f32 = 0;
    var uv0_x: f32 = 0;
    var uv0_y: f32 = 0;
    var uv1_x: f32 = 1;
    var uv1_y: f32 = 1;
    try std.testing.expect(!clipTexturedQuad(&x, &y, &w, &h, &uv0_x, &uv0_y, &uv1_x, &uv1_y, 200, 200));
}
