//! Ghostty-compatible shaders. The terminal scene renders into an offscreen
//! target and each post-process shader samples the previous pass through
//! `iChannel0`; the last pass writes the swapchain. An optional background
//! shader draws inside the scene pass, under the background image.

const std = @import("std");
const c = @import("sokol_c");
const io = @import("../io.zig");
const shadertoy = @import("shaders/shadertoy.zig");
const Animation = @import("../config.zig").Config.CustomShader.Animation;

pub const Uniforms = shadertoy.Uniforms;
pub const CursorStyle = shadertoy.CursorStyle;
pub const max_passes = 8;
/// How long `Animation.cursor` keeps rendering after a cursor or focus change.
pub const cursor_animation_s: f32 = 1.0;

const target = shadertoy.native_target;
pub const y_is_down = shadertoy.yIsDown(target);
const Packed = if (target == .hlsl) shadertoy.Std140 else shadertoy.Native;

const Target = struct {
    image: c.sg_image,
    depth: c.sg_image = .{ .id = 0 },
    attachment: c.sg_view,
    depth_attachment: c.sg_view = .{ .id = 0 },
    texture: c.sg_view,

    fn init(w: u32, h: u32, color_format: c.sg_pixel_format, depth_format: c.sg_pixel_format) Target {
        var img_desc = std.mem.zeroes(c.sg_image_desc);
        img_desc.width = @intCast(w);
        img_desc.height = @intCast(h);
        img_desc.pixel_format = color_format;
        img_desc.usage.color_attachment = true;
        img_desc.label = "post-shader-rt";
        const image = c.sg_make_image(&img_desc);

        var att_desc = std.mem.zeroes(c.sg_view_desc);
        att_desc.color_attachment.image = image;
        var tex_desc = std.mem.zeroes(c.sg_view_desc);
        tex_desc.texture.image = image;
        var result: Target = .{ .image = image, .attachment = c.sg_make_view(&att_desc), .texture = c.sg_make_view(&tex_desc) };

        if (depth_format != c.SG_PIXELFORMAT_NONE) {
            var depth_desc = std.mem.zeroes(c.sg_image_desc);
            depth_desc.width = @intCast(w);
            depth_desc.height = @intCast(h);
            depth_desc.pixel_format = depth_format;
            depth_desc.usage.depth_stencil_attachment = true;
            depth_desc.label = "post-shader-depth";
            result.depth = c.sg_make_image(&depth_desc);
            var depth_view = std.mem.zeroes(c.sg_view_desc);
            depth_view.depth_stencil_attachment.image = result.depth;
            result.depth_attachment = c.sg_make_view(&depth_view);
        }
        return result;
    }

    fn deinit(self: Target) void {
        if (self.depth.id != 0) {
            c.sg_destroy_view(self.depth_attachment);
            c.sg_destroy_image(self.depth);
        }
        c.sg_destroy_view(self.texture);
        c.sg_destroy_view(self.attachment);
        c.sg_destroy_image(self.image);
    }

    fn attachments(self: Target) c.sg_attachments {
        var result = std.mem.zeroes(c.sg_attachments);
        result.colors[0] = self.attachment;
        result.depth_stencil = self.depth_attachment;
        return result;
    }
};

const Pass = struct {
    shader: c.sg_shader,
    pipeline: c.sg_pipeline,

    fn deinit(self: Pass) void {
        c.sg_destroy_pipeline(self.pipeline);
        c.sg_destroy_shader(self.shader);
    }
};

/// 1×1 transparent texture bound as the background shader's `iChannel0`.
const EmptyTexture = struct {
    image: c.sg_image,
    view: c.sg_view,

    fn init() EmptyTexture {
        const pixel = [4]u8{ 0, 0, 0, 0 };
        var img_desc = std.mem.zeroes(c.sg_image_desc);
        img_desc.width = 1;
        img_desc.height = 1;
        img_desc.pixel_format = c.SG_PIXELFORMAT_RGBA8;
        img_desc.data.mip_levels[0].ptr = &pixel;
        img_desc.data.mip_levels[0].size = pixel.len;
        img_desc.label = "background-shader-empty";
        const image = c.sg_make_image(&img_desc);
        var view_desc = std.mem.zeroes(c.sg_view_desc);
        view_desc.texture.image = image;
        return .{ .image = image, .view = c.sg_make_view(&view_desc) };
    }

    fn deinit(self: EmptyTexture) void {
        c.sg_destroy_view(self.view);
        c.sg_destroy_image(self.image);
    }
};

pub const Chain = struct {
    /// Config generation of the last sync, so failing files are not retried
    /// every frame.
    generation: ?u32 = null,
    passes: [max_passes]Pass = undefined,
    pass_count: usize = 0,
    background: ?Pass = null,
    empty_texture: ?EmptyTexture = null,
    packed_uniforms: Packed = undefined,
    targets: [2]?Target = .{ null, null },
    target_size: [2]u32 = .{ 0, 0 },
    sampler: c.sg_sampler = .{ .id = 0 },
    uniforms: Uniforms = .{},
    start_ns: i128 = 0,
    last_frame_ns: i128 = 0,
    focus_known: bool = false,

    pub fn deinit(self: *Chain) void {
        self.releaseGpu();
    }

    fn releaseGpu(self: *Chain) void {
        for (self.passes[0..self.pass_count]) |pass| pass.deinit();
        self.pass_count = 0;
        if (self.background) |pass| pass.deinit();
        self.background = null;
        if (self.empty_texture) |t| t.deinit();
        self.empty_texture = null;
        self.releaseTargets();
        if (self.sampler.id != 0) c.sg_destroy_sampler(self.sampler);
        self.sampler = .{ .id = 0 };
    }

    fn releaseTargets(self: *Chain) void {
        for (&self.targets) |*slot| {
            if (slot.*) |t| t.deinit();
            slot.* = null;
        }
        self.target_size = .{ 0, 0 };
    }

    /// Whether post-process passes run, so the scene renders offscreen.
    pub fn active(self: *const Chain) bool {
        return self.pass_count > 0;
    }

    pub fn backgroundActive(self: *const Chain) bool {
        return self.background != null;
    }

    /// Whether any shader reads the uniforms.
    pub fn anyActive(self: *const Chain) bool {
        return self.active() or self.backgroundActive();
    }

    /// Rebuild the chain when the config generation changed. Must run
    /// outside a render pass.
    pub fn sync(self: *Chain, alloc: std.mem.Allocator, paths: []const []const u8, background_path: ?[]const u8, generation: u32) void {
        if (self.generation == generation) return;
        self.generation = generation;
        self.releaseGpu();
        if (paths.len == 0 and background_path == null) return;

        const swapchain = c.sglue_swapchain();
        if (swapchain.sample_count > 1) {
            std.log.err("custom_shader: disabled with MSAA swapchain (sample_count={d})", .{swapchain.sample_count});
            return;
        }
        for (paths[0..@min(paths.len, max_passes)]) |path| {
            const pass = buildPass(alloc, path, swapchain.color_format, swapchain.depth_format, false) catch |err| {
                std.log.err("custom_shader '{s}' failed: {s}", .{ path, @errorName(err) });
                continue;
            };
            self.passes[self.pass_count] = pass;
            self.pass_count += 1;
        }
        if (background_path) |path| {
            if (buildPass(alloc, path, swapchain.color_format, swapchain.depth_format, true)) |pass| {
                self.background = pass;
                self.empty_texture = EmptyTexture.init();
            } else |err| std.log.err("background shader '{s}' failed: {s}", .{ path, @errorName(err) });
        }
        if (!self.anyActive()) return;

        var smp_desc = std.mem.zeroes(c.sg_sampler_desc);
        smp_desc.min_filter = c.SG_FILTER_LINEAR;
        smp_desc.mag_filter = c.SG_FILTER_LINEAR;
        smp_desc.wrap_u = c.SG_WRAP_CLAMP_TO_EDGE;
        smp_desc.wrap_v = c.SG_WRAP_CLAMP_TO_EDGE;
        smp_desc.label = "post-shader-smp";
        self.sampler = c.sg_make_sampler(&smp_desc);
        self.start_ns = io.nanoTimestamp();
        self.last_frame_ns = self.start_ns;
        self.uniforms = .{};
        self.focus_known = false;
    }

    /// Attachments for the scene pass, resized to the framebuffer. Must run
    /// outside a render pass.
    pub fn sceneAttachments(self: *Chain, w: u32, h: u32) c.sg_attachments {
        if (self.target_size[0] != w or self.target_size[1] != h) {
            self.releaseTargets();
            const swapchain = c.sglue_swapchain();
            // A single pass reads the scene and writes the swapchain, so the
            // second target is only needed for chains.
            const count: usize = if (self.pass_count > 1) 2 else 1;
            for (self.targets[0..count]) |*slot| slot.* = Target.init(w, h, swapchain.color_format, swapchain.depth_format);
            self.target_size = .{ w, h };
        }
        return self.targets[0].?.attachments();
    }

    pub fn secondsSince(self: *const Chain, ns: i128) f32 {
        return @floatCast(@as(f64, @floatFromInt(ns - self.start_ns)) / std.time.ns_per_s);
    }

    /// Record the drawn cursor. `rect` is in shader pixel coordinates.
    pub fn noteCursor(self: *Chain, now_ns: i128, rect: [4]f32, color: [4]f32) void {
        const u = &self.uniforms;
        if (std.meta.eql(rect, u.current_cursor) and std.meta.eql(color, u.current_cursor_color)) return;
        u.previous_cursor = u.current_cursor;
        u.previous_cursor_color = u.current_cursor_color;
        u.current_cursor = rect;
        u.current_cursor_color = color;
        u.time_cursor_change = self.secondsSince(now_ns);
    }

    pub fn noteCursorStyle(self: *Chain, style: CursorStyle, visible: bool) void {
        const u = &self.uniforms;
        if (style != u.current_cursor_style) {
            u.previous_cursor_style = u.current_cursor_style;
            u.current_cursor_style = style;
        }
        u.cursor_visible = visible;
    }

    pub fn noteFocus(self: *Chain, now_ns: i128, focused: bool) void {
        const changed = !self.focus_known or self.uniforms.focus != focused;
        self.focus_known = true;
        self.uniforms.focus = focused;
        if (changed and focused) self.uniforms.time_focus = self.secondsSince(now_ns);
    }

    /// Whether the next frame must render even when nothing else changed.
    pub fn wantsFrame(self: *const Chain, now_ns: i128, animation: Animation, animate_background: bool) bool {
        if (self.backgroundActive() and animate_background) return true;
        if (!self.active()) return false;
        return switch (animation) {
            .always => true,
            .off => false,
            .cursor => blk: {
                const last = @max(self.uniforms.time_cursor_change, self.uniforms.time_focus);
                break :blk self.secondsSince(now_ns) - last < cursor_animation_s;
            },
        };
    }

    /// Update the per-frame uniforms. Call once per frame before
    /// `drawBackground` and `run`.
    pub fn beginFrame(self: *Chain, now_ns: i128, w: f32, h: f32) void {
        if (!self.anyActive()) return;
        const u = &self.uniforms;
        u.resolution = .{ w, h };
        u.time = self.secondsSince(now_ns);
        u.time_delta = @floatCast(@as(f64, @floatFromInt(now_ns - self.last_frame_ns)) / std.time.ns_per_s);
        u.frame_rate = if (u.time_delta > 0) 1.0 / u.time_delta else 0;
        u.date = date(now_ns);
        self.last_frame_ns = now_ns;
        if (target == .hlsl) u.packStd140(&self.packed_uniforms) else u.packNative(&self.packed_uniforms);
        u.frame +%= 1;
    }

    /// Draw the background shader inside the scene pass. It replaces
    /// `opacity` of the clear colour and keeps its alpha, `window_alpha`.
    pub fn drawBackground(self: *const Chain, opacity: f32, window_alpha: f32) void {
        const pass = self.background orelse return;
        if (opacity <= 0) return;
        var packed_uniforms = self.packed_uniforms;
        packed_uniforms.globals[9][2] = opacity;
        packed_uniforms.globals[9][3] = window_alpha;
        c.sg_apply_pipeline(pass.pipeline);
        var bindings = std.mem.zeroes(c.sg_bindings);
        bindings.views[0] = self.empty_texture.?.view;
        bindings.samplers[0] = self.sampler;
        c.sg_apply_bindings(&bindings);
        c.sg_apply_uniforms(0, &.{ .ptr = &packed_uniforms, .size = @sizeOf(Packed) });
        c.sg_draw(0, 3, 1);
    }

    /// Run every pass after the scene pass ended. The last pass writes the
    /// swapchain.
    pub fn run(self: *const Chain) void {
        if (!self.active() or self.targets[0] == null) return;
        for (self.passes[0..self.pass_count], 0..) |pass, i| {
            const src = self.targets[i % 2].?;
            const last = i + 1 == self.pass_count;
            var sg_pass = std.mem.zeroes(c.sg_pass);
            if (last) {
                sg_pass.swapchain = c.sglue_swapchain();
            } else {
                sg_pass.attachments = self.targets[(i + 1) % 2].?.attachments();
            }
            sg_pass.action.colors[0].load_action = c.SG_LOADACTION_DONTCARE;
            sg_pass.label = "post-shader-pass";
            c.sg_begin_pass(&sg_pass);
            c.sg_apply_pipeline(pass.pipeline);
            var bindings = std.mem.zeroes(c.sg_bindings);
            bindings.views[0] = src.texture;
            bindings.samplers[0] = self.sampler;
            c.sg_apply_bindings(&bindings);
            c.sg_apply_uniforms(0, &.{ .ptr = &self.packed_uniforms, .size = @sizeOf(Packed) });
            c.sg_draw(0, 3, 1);
            c.sg_end_pass();
        }
    }
};

/// Shadertoy `iDate`: year, month (0-based), day (1-based), seconds of day, UTC.
fn date(now_ns: i128) [4]f32 {
    const secs: u64 = @intCast(@max(0, @divFloor(now_ns, std.time.ns_per_s)));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds().secs;
    const frac: f32 = @floatCast(@as(f64, @floatFromInt(@mod(now_ns, std.time.ns_per_s))) / std.time.ns_per_s);
    return .{
        @floatFromInt(year_day.year),
        @floatFromInt(month_day.month.numeric() - 1),
        @floatFromInt(month_day.day_index + 1),
        @as(f32, @floatFromInt(day_secs)) + frac,
    };
}

/// `premultiplied_blend` mixes the output into the target for the
/// background layer: colour `src + dst * (1 - a)`, alpha
/// `dst * a + dst * (1 - a)`, so the window alpha is unchanged.
fn buildPass(alloc: std.mem.Allocator, path: []const u8, color_format: c.sg_pixel_format, depth_format: c.sg_pixel_format, premultiplied_blend: bool) !Pass {
    const source = try std.Io.Dir.cwd().readFileAlloc(io.get(), path, alloc, .limited(shadertoy.max_source_bytes));
    defer alloc.free(source);
    var log: shadertoy.Log = .{};
    const fragment = shadertoy.compileFragment(alloc, source, target, &log) catch |err| {
        std.log.err("custom_shader '{s}': {s}", .{ path, log.slice() });
        return err;
    };
    defer alloc.free(fragment);

    var desc = std.mem.zeroes(c.sg_shader_desc);
    desc.vertex_func.source = switch (target) {
        .hlsl => shadertoy.vertex_source.hlsl.ptr,
        .glsl => shadertoy.vertex_source.glsl.ptr,
    };
    desc.fragment_func.source = fragment.ptr;
    if (target == .hlsl) {
        desc.vertex_func.d3d11_target = "vs_5_0";
        desc.fragment_func.d3d11_target = "ps_5_0";
    }

    const ub = &desc.uniform_blocks[0];
    ub.stage = c.SG_SHADERSTAGE_FRAGMENT;
    ub.size = @sizeOf(Packed);
    ub.hlsl_register_b_n = 0;
    ub.layout = if (target == .hlsl) c.SG_UNIFORMLAYOUT_STD140 else c.SG_UNIFORMLAYOUT_NATIVE;
    const members = [_]struct { name: [*:0]const u8, ty: c.sg_uniform_type, count: u16 }{
        .{ .name = "hollow_globals", .ty = c.SG_UNIFORMTYPE_FLOAT4, .count = shadertoy.slot_count },
        .{ .name = "iChannelTime", .ty = c.SG_UNIFORMTYPE_FLOAT, .count = 4 },
        .{ .name = "iChannelResolution", .ty = c.SG_UNIFORMTYPE_FLOAT3, .count = 4 },
        .{ .name = "iPalette", .ty = c.SG_UNIFORMTYPE_FLOAT3, .count = 256 },
    };
    if (target == .glsl) for (members, 0..) |m, i| {
        ub.glsl_uniforms[i].type = m.ty;
        ub.glsl_uniforms[i].array_count = m.count;
        ub.glsl_uniforms[i].glsl_name = m.name;
    };

    desc.views[0].texture.stage = c.SG_SHADERSTAGE_FRAGMENT;
    desc.views[0].texture.image_type = c.SG_IMAGETYPE_2D;
    desc.views[0].texture.sample_type = c.SG_IMAGESAMPLETYPE_FLOAT;
    desc.views[0].texture.hlsl_register_t_n = 0;
    desc.samplers[0].stage = c.SG_SHADERSTAGE_FRAGMENT;
    desc.samplers[0].sampler_type = c.SG_SAMPLERTYPE_FILTERING;
    desc.samplers[0].hlsl_register_s_n = 0;
    desc.texture_sampler_pairs[0].stage = c.SG_SHADERSTAGE_FRAGMENT;
    desc.texture_sampler_pairs[0].view_slot = 0;
    desc.texture_sampler_pairs[0].sampler_slot = 0;
    desc.texture_sampler_pairs[0].glsl_name = "iChannel0";
    desc.label = "post-shader";

    const shader = c.sg_make_shader(&desc);
    if (c.sg_query_shader_state(shader) != c.SG_RESOURCESTATE_VALID) {
        c.sg_destroy_shader(shader);
        return error.ShaderInvalid;
    }

    var pip_desc = std.mem.zeroes(c.sg_pipeline_desc);
    pip_desc.shader = shader;
    pip_desc.colors[0].pixel_format = color_format;
    if (premultiplied_blend) {
        const blend = &pip_desc.colors[0].blend;
        blend.enabled = true;
        blend.src_factor_rgb = c.SG_BLENDFACTOR_ONE;
        blend.dst_factor_rgb = c.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        blend.src_factor_alpha = c.SG_BLENDFACTOR_DST_ALPHA;
        blend.dst_factor_alpha = c.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
    }
    pip_desc.depth.pixel_format = depth_format;
    pip_desc.label = "post-shader-pipeline";
    const pipeline = c.sg_make_pipeline(&pip_desc);
    if (c.sg_query_pipeline_state(pipeline) != c.SG_RESOURCESTATE_VALID) {
        c.sg_destroy_pipeline(pipeline);
        c.sg_destroy_shader(shader);
        return error.PipelineInvalid;
    }
    return .{ .shader = shader, .pipeline = pipeline };
}

test "date splits a timestamp into shadertoy fields" {
    // 2024-03-01T12:00:30.5Z
    const ns: i128 = (1709294430 * std.time.ns_per_s) + std.time.ns_per_s / 2;
    const d = date(ns);
    try std.testing.expectEqual(@as(f32, 2024), d[0]);
    try std.testing.expectEqual(@as(f32, 2), d[1]);
    try std.testing.expectEqual(@as(f32, 1), d[2]);
    try std.testing.expectEqual(@as(f32, 43230.5), d[3]);
}

test "cursor animation runs for a second after a cursor change" {
    var chain: Chain = .{ .pass_count = 1 };
    chain.noteCursor(2 * std.time.ns_per_s, .{ 10, 20, 8, 16 }, .{ 1, 1, 1, 1 });
    try std.testing.expectEqual(@as(f32, 2), chain.uniforms.time_cursor_change);
    try std.testing.expect(chain.wantsFrame(2 * std.time.ns_per_s + std.time.ns_per_s / 2, .cursor, true));
    try std.testing.expect(!chain.wantsFrame(4 * std.time.ns_per_s, .cursor, true));
    try std.testing.expect(chain.wantsFrame(4 * std.time.ns_per_s, .always, true));

    // An unchanged cursor keeps the previous change time.
    chain.noteCursor(3 * std.time.ns_per_s, .{ 10, 20, 8, 16 }, .{ 1, 1, 1, 1 });
    try std.testing.expectEqual(@as(f32, 2), chain.uniforms.time_cursor_change);
    chain.noteCursor(3 * std.time.ns_per_s, .{ 18, 20, 8, 16 }, .{ 1, 1, 1, 1 });
    try std.testing.expectEqual([4]f32{ 10, 20, 8, 16 }, chain.uniforms.previous_cursor);
}

test "an animated background shader renders every frame" {
    const stub: Pass = .{ .shader = .{ .id = 0 }, .pipeline = .{ .id = 0 } };
    var chain: Chain = .{ .background = stub };
    try std.testing.expect(!chain.active());
    try std.testing.expect(chain.wantsFrame(10 * std.time.ns_per_s, .off, true));
    try std.testing.expect(!chain.wantsFrame(10 * std.time.ns_per_s, .off, false));
}
