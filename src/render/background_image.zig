//! Window background image drawn under the terminal panes.

const std = @import("std");
const c = @import("sokol_c");
const io = @import("../io.zig");
const Fit = @import("../config.zig").Config.Background.Fit;

extern fn hollow_decode_image_bytes(
    data: [*]const u8,
    data_len: usize,
    out_width: *u32,
    out_height: *u32,
    out_pixels: *?[*]u8,
    out_len: *usize,
) callconv(.c) bool;

extern fn hollow_decode_png_bytes_free(pixels: ?[*]u8) callconv(.c) void;

pub const max_file_bytes = 64 * 1024 * 1024;
pub const max_dimension = 8192;

pub const Quad = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    u0: f32 = 0,
    v0: f32 = 0,
    u1: f32 = 1,
    v1: f32 = 1,
};

/// Place an `img_w`×`img_h` image in a `fb_w`×`fb_h` framebuffer. Tile
/// covers the framebuffer and repeats through UVs above 1.
pub fn layout(fit: Fit, img_w: f32, img_h: f32, fb_w: f32, fb_h: f32) Quad {
    switch (fit) {
        .stretch => return .{ .x = 0, .y = 0, .w = fb_w, .h = fb_h },
        .tile => return .{ .x = 0, .y = 0, .w = fb_w, .h = fb_h, .u1 = fb_w / img_w, .v1 = fb_h / img_h },
        .cover, .contain, .center => {
            const scale: f32 = switch (fit) {
                .cover => @max(fb_w / img_w, fb_h / img_h),
                .contain => @min(fb_w / img_w, fb_h / img_h),
                else => 1.0,
            };
            const w = img_w * scale;
            const h = img_h * scale;
            return .{ .x = (fb_w - w) / 2, .y = (fb_h - h) / 2, .w = w, .h = h };
        },
    }
}

pub const BackgroundImage = struct {
    /// Path of the last load attempt, so a failing file is not retried
    /// every frame.
    path: ?[]u8 = null,
    texture: ?Texture = null,

    const Texture = struct {
        image: c.sg_image,
        view: c.sg_view,
        clamp_smp: c.sg_sampler,
        repeat_smp: c.sg_sampler,
        width: u32,
        height: u32,

        fn deinit(self: Texture) void {
            c.sg_destroy_sampler(self.repeat_smp);
            c.sg_destroy_sampler(self.clamp_smp);
            c.sg_destroy_view(self.view);
            c.sg_destroy_image(self.image);
        }
    };

    pub fn deinit(self: *BackgroundImage, allocator: std.mem.Allocator) void {
        if (self.texture) |tex| tex.deinit();
        self.texture = null;
        if (self.path) |p| allocator.free(p);
        self.path = null;
    }

    /// Load `path` when it differs from the last attempt. Must run outside
    /// a render pass.
    pub fn sync(self: *BackgroundImage, allocator: std.mem.Allocator, path: ?[]const u8) void {
        const wanted = path orelse {
            self.deinit(allocator);
            return;
        };
        if (self.path) |current| if (std.mem.eql(u8, current, wanted)) return;
        self.deinit(allocator);
        self.path = allocator.dupe(u8, wanted) catch return;
        self.texture = load(allocator, wanted) catch |err| blk: {
            std.log.err("background image '{s}' failed: {s}", .{ wanted, @errorName(err) });
            break :blk null;
        };
    }

    fn load(allocator: std.mem.Allocator, path: []const u8) !Texture {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io.get(), path, allocator, .limited(max_file_bytes));
        defer allocator.free(bytes);

        var width: u32 = 0;
        var height: u32 = 0;
        var pixels_ptr: ?[*]u8 = null;
        var len: usize = 0;
        if (!hollow_decode_image_bytes(bytes.ptr, bytes.len, &width, &height, &pixels_ptr, &len)) return error.UnsupportedImage;
        defer hollow_decode_png_bytes_free(pixels_ptr);
        if (width > max_dimension or height > max_dimension) return error.ResourceExhausted;

        // The compositing pipeline expects premultiplied alpha.
        const pixels = pixels_ptr.?[0..len];
        var i: usize = 0;
        while (i < pixels.len) : (i += 4) {
            const a: u16 = pixels[i + 3];
            inline for (0..3) |k| pixels[i + k] = @intCast((@as(u16, pixels[i + k]) * a + 127) / 255);
        }

        var img_desc = std.mem.zeroes(c.sg_image_desc);
        img_desc.width = @intCast(width);
        img_desc.height = @intCast(height);
        img_desc.pixel_format = c.SG_PIXELFORMAT_RGBA8;
        img_desc.data.mip_levels[0].ptr = pixels.ptr;
        img_desc.data.mip_levels[0].size = pixels.len;
        img_desc.label = "background-image";
        const image = c.sg_make_image(&img_desc);

        var view_desc = std.mem.zeroes(c.sg_view_desc);
        view_desc.texture.image = image;
        const view = c.sg_make_view(&view_desc);

        var smp_desc = std.mem.zeroes(c.sg_sampler_desc);
        smp_desc.min_filter = c.SG_FILTER_LINEAR;
        smp_desc.mag_filter = c.SG_FILTER_LINEAR;
        smp_desc.wrap_u = c.SG_WRAP_CLAMP_TO_EDGE;
        smp_desc.wrap_v = c.SG_WRAP_CLAMP_TO_EDGE;
        smp_desc.label = "background-image-clamp";
        const clamp_smp = c.sg_make_sampler(&smp_desc);
        smp_desc.wrap_u = c.SG_WRAP_REPEAT;
        smp_desc.wrap_v = c.SG_WRAP_REPEAT;
        smp_desc.label = "background-image-repeat";
        const repeat_smp = c.sg_make_sampler(&smp_desc);

        return .{ .image = image, .view = view, .clamp_smp = clamp_smp, .repeat_smp = repeat_smp, .width = width, .height = height };
    }

    /// Draw into the current pass with a premultiplied-alpha pipeline.
    pub fn draw(self: *const BackgroundImage, pip: c.sgl_pipeline, fit: Fit, opacity: f32, fb_w: f32, fb_h: f32) void {
        const tex = self.texture orelse return;
        if (opacity <= 0) return;
        const q = layout(fit, @floatFromInt(tex.width), @floatFromInt(tex.height), fb_w, fb_h);
        c.sgl_defaults();
        c.sgl_viewport(0, 0, @intFromFloat(fb_w), @intFromFloat(fb_h), true);
        c.sgl_scissor_rect(0, 0, @intFromFloat(fb_w), @intFromFloat(fb_h), true);
        c.sgl_load_pipeline(pip);
        c.sgl_enable_texture();
        c.sgl_texture(tex.view, if (fit == .tile) tex.repeat_smp else tex.clamp_smp);
        c.sgl_matrix_mode_projection();
        c.sgl_load_identity();
        c.sgl_ortho(0.0, fb_w, fb_h, 0.0, -1.0, 1.0);
        c.sgl_begin_quads();
        c.sgl_c4f(opacity, opacity, opacity, opacity);
        c.sgl_v2f_t2f(q.x, q.y, q.u0, q.v0);
        c.sgl_v2f_t2f(q.x + q.w, q.y, q.u1, q.v0);
        c.sgl_v2f_t2f(q.x + q.w, q.y + q.h, q.u1, q.v1);
        c.sgl_v2f_t2f(q.x, q.y + q.h, q.u0, q.v1);
        c.sgl_end();
        c.sgl_disable_texture();
        c.sgl_load_default_pipeline();
    }
};

test "layout fits images to the framebuffer" {
    const cover = layout(.cover, 100, 50, 200, 200);
    try std.testing.expectEqual(@as(f32, 400), cover.w);
    try std.testing.expectEqual(@as(f32, 200), cover.h);
    try std.testing.expectEqual(@as(f32, -100), cover.x);

    const contain = layout(.contain, 100, 50, 200, 200);
    try std.testing.expectEqual(@as(f32, 200), contain.w);
    try std.testing.expectEqual(@as(f32, 100), contain.h);
    try std.testing.expectEqual(@as(f32, 50), contain.y);

    const center = layout(.center, 100, 50, 200, 200);
    try std.testing.expectEqual(@as(f32, 50), center.x);
    try std.testing.expectEqual(@as(f32, 75), center.y);

    const tile = layout(.tile, 100, 50, 200, 200);
    try std.testing.expectEqual(@as(f32, 2), tile.u1);
    try std.testing.expectEqual(@as(f32, 4), tile.v1);
}
