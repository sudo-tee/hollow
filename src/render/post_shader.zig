//! Ghostty-compatible shaders. The terminal scene renders into an offscreen
//! target and each post-process shader samples the previous pass through
//! `iChannel0`; the last pass writes the swapchain. An optional background
//! shader draws under the background image, directly or from a cached target.

const std = @import("std");
const c = @import("sokol_c");
const io = @import("../io.zig");
const shadertoy = @import("shaders/shadertoy.zig");
const Animation = @import("../config.zig").Config.CustomShader.Animation;
const Background = @import("../config.zig").Config.Background;

pub const Uniforms = shadertoy.Uniforms;
pub const CursorStyle = shadertoy.CursorStyle;
pub const max_passes = 8;
/// How long `Animation.cursor` keeps rendering after a cursor or focus change.
pub const cursor_animation_s: f32 = 1.0;

const target = shadertoy.native_target;
pub const y_is_down = shadertoy.yIsDown(target);
const Packed = if (target == .hlsl) shadertoy.Std140 else shadertoy.Native;
const background_cache_format = c.SG_PIXELFORMAT_RGBA16F;
const background_copy =
    \\void mainImage(out vec4 color, in vec2 pixel) {
    \\    color = texelFetch(iChannel0, ivec2(pixel), 0);
    \\}
;
const background_upscale =
    \\void mainImage(out vec4 color, in vec2 pixel) {
    \\    color = textureLod(iChannel0, pixel / iResolution.xy, 0.0);
    \\}
;

fn backgroundExtent(pixels: u32, scale: f32) u32 {
    return @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(pixels)) * scale)));
}

fn scaleBackgroundUniforms(uniforms: *Uniforms, size: [2]u32) void {
    const resolution: [2]f32 = .{ @floatFromInt(size[0]), @floatFromInt(size[1]) };
    for (resolution, uniforms.resolution, 0..) |new, old, axis| {
        const ratio = new / old;
        uniforms.current_cursor[axis] *= ratio;
        uniforms.current_cursor[axis + 2] *= ratio;
        uniforms.previous_cursor[axis] *= ratio;
        uniforms.previous_cursor[axis + 2] *= ratio;
    }
    uniforms.resolution = resolution;
}

/// Values baked into the cached background layer.
const BackgroundLayer = struct {
    opacity: f32,
    brightness: f32,
    window_alpha: f32,
};

const BackgroundRefresh = struct {
    last_ns: ?i128 = null,
    layer: ?BackgroundLayer = null,

    fn deadline(self: BackgroundRefresh, fps: u32) ?i128 {
        if (fps == 0) return null;
        return (self.last_ns orelse return null) + @divFloor(std.time.ns_per_s, @as(i128, fps));
    }

    fn due(self: BackgroundRefresh, now_ns: i128, fps: u32) bool {
        return now_ns >= (self.deadline(fps) orelse return true);
    }

    /// A static layer renders once per target and layer change.
    fn stale(self: BackgroundRefresh, bg: Background, layer: BackgroundLayer, now_ns: i128) bool {
        if (!std.meta.eql(self.layer, @as(?BackgroundLayer, layer))) return true;
        return bg.shader_animate and self.due(now_ns, bg.shader_max_fps);
    }
};

const Target = struct {
    image: c.sg_image,
    depth: c.sg_image = .{ .id = 0 },
    attachment: c.sg_view,
    depth_attachment: c.sg_view = .{ .id = 0 },
    texture: c.sg_view,

    fn init(w: u32, h: u32, color_format: c.sg_pixel_format, depth_format: c.sg_pixel_format) Target {
        var result: Target = .{
            .image = .{ .id = 0 },
            .attachment = .{ .id = 0 },
            .texture = .{ .id = 0 },
        };
        const limit: u32 = @intCast(c.sg_query_limits().max_image_size_2d);
        if (w == 0 or h == 0 or w > limit or h > limit) return result;
        var img_desc = std.mem.zeroes(c.sg_image_desc);
        img_desc.width = @intCast(w);
        img_desc.height = @intCast(h);
        img_desc.pixel_format = color_format;
        img_desc.usage.color_attachment = true;
        img_desc.label = "post-shader-rt";
        result.image = c.sg_make_image(&img_desc);
        if (c.sg_query_image_state(result.image) != c.SG_RESOURCESTATE_VALID) return result;

        var att_desc = std.mem.zeroes(c.sg_view_desc);
        att_desc.color_attachment.image = result.image;
        var tex_desc = std.mem.zeroes(c.sg_view_desc);
        tex_desc.texture.image = result.image;
        result.attachment = c.sg_make_view(&att_desc);
        result.texture = c.sg_make_view(&tex_desc);

        if (depth_format != c.SG_PIXELFORMAT_NONE) {
            var depth_desc = std.mem.zeroes(c.sg_image_desc);
            depth_desc.width = @intCast(w);
            depth_desc.height = @intCast(h);
            depth_desc.pixel_format = depth_format;
            depth_desc.usage.depth_stencil_attachment = true;
            depth_desc.label = "post-shader-depth";
            result.depth = c.sg_make_image(&depth_desc);
            if (c.sg_query_image_state(result.depth) != c.SG_RESOURCESTATE_VALID) return result;
            var depth_view = std.mem.zeroes(c.sg_view_desc);
            depth_view.depth_stencil_attachment.image = result.depth;
            result.depth_attachment = c.sg_make_view(&depth_view);
        }
        return result;
    }

    fn valid(self: Target, depth_format: c.sg_pixel_format) bool {
        return c.sg_query_image_state(self.image) == c.SG_RESOURCESTATE_VALID and
            c.sg_query_view_state(self.attachment) == c.SG_RESOURCESTATE_VALID and
            c.sg_query_view_state(self.texture) == c.SG_RESOURCESTATE_VALID and
            (depth_format == c.SG_PIXELFORMAT_NONE or
                (c.sg_query_image_state(self.depth) == c.SG_RESOURCESTATE_VALID and
                    c.sg_query_view_state(self.depth_attachment) == c.SG_RESOURCESTATE_VALID));
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
        return .{ .image = image, .view = if (c.sg_query_image_state(image) == c.SG_RESOURCESTATE_VALID)
            c.sg_make_view(&view_desc)
        else
            .{ .id = 0 } };
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
    background_cache_pipeline: ?c.sg_pipeline = null,
    background_copy_pass: ?Pass = null,
    background_target: ?Target = null,
    background_size: [2]u32 = .{ 0, 0 },
    background_options: ?Background = null,
    background_refresh: BackgroundRefresh = .{},
    background_frame: u32 = 0,
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
        self.releasePost();
        self.releaseBackground();
        if (self.sampler.id != 0) c.sg_destroy_sampler(self.sampler);
        self.sampler = .{ .id = 0 };
    }

    fn releasePost(self: *Chain) void {
        for (self.passes[0..self.pass_count]) |pass| pass.deinit();
        self.pass_count = 0;
        self.releaseTargets();
    }

    fn releaseBackground(self: *Chain) void {
        self.releaseBackgroundTarget();
        if (self.background_cache_pipeline) |pip| c.sg_destroy_pipeline(pip);
        self.background_cache_pipeline = null;
        if (self.background_copy_pass) |pass| pass.deinit();
        self.background_copy_pass = null;
        if (self.background) |pass| pass.deinit();
        self.background = null;
        self.background_options = null;
        if (self.empty_texture) |t| t.deinit();
        self.empty_texture = null;
        self.background_frame = 0;
    }

    fn releaseBackgroundTarget(self: *Chain) void {
        if (self.background_target) |t| t.deinit();
        self.background_target = null;
        self.background_size = .{ 0, 0 };
        self.background_refresh = .{};
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
    pub fn sync(self: *Chain, alloc: std.mem.Allocator, paths: []const []const u8, bg: Background, generation: u32, notice: *shadertoy.Log) void {
        if (self.generation == generation) return;
        self.generation = generation;
        if (paths.len == 0 and bg.shader == null) {
            self.releaseGpu();
            self.start_ns = 0;
            return;
        }

        const swapchain = c.sglue_swapchain();
        if (swapchain.sample_count > 1) {
            self.releaseGpu();
            notice.set("Shaders are disabled with multisampling.");
            std.log.err("{s}", .{notice.slice()});
            return;
        }
        if (self.sampler.id == 0) {
            var smp_desc = std.mem.zeroes(c.sg_sampler_desc);
            smp_desc.min_filter = c.SG_FILTER_LINEAR;
            smp_desc.mag_filter = c.SG_FILTER_LINEAR;
            smp_desc.wrap_u = c.SG_WRAP_CLAMP_TO_EDGE;
            smp_desc.wrap_v = c.SG_WRAP_CLAMP_TO_EDGE;
            smp_desc.label = "post-shader-smp";
            const sampler = c.sg_make_sampler(&smp_desc);
            if (c.sg_query_sampler_state(sampler) != c.SG_RESOURCESTATE_VALID) {
                c.sg_destroy_sampler(sampler);
                notice.set("Could not allocate the shader sampler. See hollow.log.");
                std.log.err("{s}", .{notice.slice()});
                return;
            }
            self.sampler = sampler;
        }

        // Stage each replacement independently. In particular a bad pass must
        // not turn a multi-pass chain into a partially updated one.
        const post_changed = self.syncPost(alloc, paths, swapchain, notice);
        const background_changed = self.syncBackground(alloc, bg, swapchain, notice);
        if (!self.anyActive()) {
            self.releaseGpu();
            self.start_ns = 0;
            return;
        }
        // Don't reset the shared timeline if either side kept its old shader.
        if (!post_changed or !background_changed) {
            if (self.start_ns != 0) return;
        }
        self.start_ns = io.nanoTimestamp();
        self.last_frame_ns = self.start_ns;
        self.uniforms = .{};
        self.focus_known = false;
    }

    fn syncPost(self: *Chain, alloc: std.mem.Allocator, paths: []const []const u8, swapchain: c.sg_swapchain, notice: *shadertoy.Log) bool {
        var staged: [max_passes]Pass = undefined;
        var count: usize = 0;
        for (paths[0..@min(paths.len, max_passes)]) |path| {
            var log: shadertoy.Log = .{};
            staged[count] = buildPass(alloc, path, swapchain.color_format, swapchain.depth_format, false, &log) catch |err| {
                for (staged[0..count]) |pass| pass.deinit();
                reportFailure("Post-process shader", path, err, log, notice);
                return false;
            };
            count += 1;
        }
        self.releasePost();
        @memcpy(self.passes[0..count], staged[0..count]);
        self.pass_count = count;
        return true;
    }

    fn syncBackground(self: *Chain, alloc: std.mem.Allocator, bg: Background, swapchain: c.sg_swapchain, notice: *shadertoy.Log) bool {
        const path = bg.shader orelse {
            self.releaseBackground();
            return true;
        };
        var log: shadertoy.Log = .{};
        const pass = buildPass(alloc, path, swapchain.color_format, swapchain.depth_format, true, &log) catch |err| {
            reportFailure("Background shader", path, err, log, notice);
            return false;
        };
        const empty = EmptyTexture.init();
        if (c.sg_query_view_state(empty.view) != c.SG_RESOURCESTATE_VALID) {
            empty.deinit();
            pass.deinit();
            reportFailure("Background shader", path, error.GpuAllocationFailed, log, notice);
            return false;
        }

        self.releaseBackground();
        self.background = pass;
        self.empty_texture = empty;
        self.background_options = .{
            .shader_opacity = bg.shader_opacity,
            .shader_brightness = bg.shader_brightness,
            .shader_animate = bg.shader_animate,
            .shader_max_fps = bg.shader_max_fps,
            .shader_render_scale = bg.shader_render_scale,
        };
        if (!bg.shader_animate or bg.shader_max_fps > 0 or bg.shader_render_scale < 1) {
            self.initBackgroundCache(alloc, pass, swapchain, bg.shader_render_scale < 1);
        }
        return true;
    }

    fn initBackgroundCache(self: *Chain, alloc: std.mem.Allocator, pass: Pass, swapchain: c.sg_swapchain, upscale: bool) void {
        const fmt = c.sg_query_pixelformat(background_cache_format);
        if (!fmt.render or !fmt.sample or (upscale and !fmt.filter)) return;
        const pip = makePipeline(pass.shader, background_cache_format, c.SG_PIXELFORMAT_NONE, false) catch return;
        const source = if (upscale) background_upscale else background_copy;
        self.background_copy_pass = buildSourcePass(alloc, source, "background shader cache", swapchain.color_format, swapchain.depth_format, true) catch {
            c.sg_destroy_pipeline(pip);
            return;
        };
        self.background_cache_pipeline = pip;
    }

    /// Attachments for the scene pass, resized to the framebuffer. Must run
    /// outside a render pass.
    pub fn sceneAttachments(self: *Chain, w: u32, h: u32) ?c.sg_attachments {
        if (!self.active()) return null;
        if (self.target_size[0] != w or self.target_size[1] != h) {
            self.releaseTargets();
            const swapchain = c.sglue_swapchain();
            // A single pass reads the scene and writes the swapchain, so the
            // second target is only needed for chains.
            const count: usize = if (self.pass_count > 1) 2 else 1;
            for (self.targets[0..count]) |*slot| {
                const scene = Target.init(w, h, swapchain.color_format, swapchain.depth_format);
                slot.* = scene;
                if (!scene.valid(swapchain.depth_format)) {
                    self.releaseTargets();
                    // Don't retry on each frame. A new size or chain retries.
                    self.target_size = .{ w, h };
                    std.log.err("Post-process targets unavailable at {d}x{d}; rendering directly", .{ w, h });
                    return null;
                }
            }
            self.target_size = .{ w, h };
        }
        return if (self.targets[0]) |scene| scene.attachments() else null;
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
    pub fn backgroundDeadline(self: *const Chain, bg: Background) ?i128 {
        if (!bg.shader_animate or bg.shader_opacity <= 0 or self.background_copy_pass == null) return null;
        return self.background_refresh.deadline(bg.shader_max_fps);
    }

    pub fn wantsFrame(self: *const Chain, now_ns: i128, animation: Animation, bg: Background) bool {
        if (self.backgroundActive() and bg.shader_animate and bg.shader_opacity > 0) {
            if (now_ns >= (self.backgroundDeadline(bg) orelse return true)) return true;
        }
        if (!self.active()) return false;
        if (self.targets[0] == null and self.target_size[0] != 0) return false;
        return switch (animation) {
            .always => true,
            .off => false,
            .cursor => blk: {
                const last = @max(self.uniforms.time_cursor_change, self.uniforms.time_focus);
                const now = self.secondsSince(now_ns);
                break :blk now - last < cursor_animation_s or now - self.uniforms.time_cursor_change < self.uniforms.cursor_trail_decay;
            },
        };
    }

    /// Update only the background layer, without touching scene targets or
    /// terminal content. On cache allocation failure, keep the direct path.
    pub fn prepareBackground(self: *Chain, bg: Background, w: u32, h: u32, now_ns: i128, window_alpha: f32) void {
        const pip = self.background_cache_pipeline orelse return;
        if (bg.shader_opacity <= 0) return;
        const size = [2]u32{ backgroundExtent(w, bg.shader_render_scale), backgroundExtent(h, bg.shader_render_scale) };
        if (!std.meta.eql(size, self.background_size)) {
            self.releaseBackgroundTarget();
            const t = Target.init(size[0], size[1], background_cache_format, c.SG_PIXELFORMAT_NONE);
            if (!t.valid(c.SG_PIXELFORMAT_NONE)) {
                t.deinit();
                // Remember the size to avoid trying again on every frame.
                self.background_size = size;
                return;
            }
            self.background_target = t;
            self.background_size = size;
        }
        const cache = self.background_target orelse return;
        const layer: BackgroundLayer = .{ .opacity = bg.shader_opacity, .brightness = bg.shader_brightness, .window_alpha = window_alpha };
        if (!self.background_refresh.stale(bg, layer, now_ns)) return;

        var uniforms = self.uniforms;
        if (bg.shader_render_scale < 1) scaleBackgroundUniforms(&uniforms, size);
        uniforms.frame = self.background_frame;
        uniforms.time_delta = @floatCast(@as(f64, @floatFromInt(now_ns - (self.background_refresh.last_ns orelse self.start_ns))) / std.time.ns_per_s);
        uniforms.frame_rate = if (uniforms.time_delta > 0) 1.0 / uniforms.time_delta else 0;
        var packed_uniforms: Packed = undefined;
        if (target == .hlsl) uniforms.packStd140(&packed_uniforms) else uniforms.packNative(&packed_uniforms);
        setLayerUniforms(&packed_uniforms, bg.shader_opacity, bg.shader_brightness, window_alpha);
        var pass = std.mem.zeroes(c.sg_pass);
        pass.attachments = cache.attachments();
        // Keep pixels discarded by the shader transparent in the cached layer.
        pass.action.colors[0].load_action = c.SG_LOADACTION_CLEAR;
        pass.action.colors[0].clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        pass.label = "background-shader-cache";
        c.sg_begin_pass(&pass);
        self.drawFullscreen(pip, self.empty_texture.?.view, &packed_uniforms);
        c.sg_end_pass();
        self.background_refresh = .{ .last_ns = now_ns, .layer = layer };
        self.background_frame +%= 1;
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
    pub fn drawBackground(self: *const Chain, opacity: f32, brightness: f32, window_alpha: f32) void {
        const pass = self.background orelse return;
        if (opacity <= 0) return;
        var packed_uniforms = self.packed_uniforms;
        if (self.background_target) |cache| {
            // The copy shader must not apply the Shadertoy layer wrapper again.
            setLayerUniforms(&packed_uniforms, 0, 1, 1);
            self.drawFullscreen(self.background_copy_pass.?.pipeline, cache.texture, &packed_uniforms);
            return;
        }
        setLayerUniforms(&packed_uniforms, opacity, brightness, window_alpha);
        self.drawFullscreen(pass.pipeline, self.empty_texture.?.view, &packed_uniforms);
    }

    fn setLayerUniforms(packed_uniforms: *Packed, opacity: f32, brightness: f32, window_alpha: f32) void {
        packed_uniforms.globals[9][2] = opacity;
        packed_uniforms.globals[9][3] = window_alpha;
        packed_uniforms.globals[10][3] = brightness;
    }

    fn drawFullscreen(self: *const Chain, pip: c.sg_pipeline, texture: c.sg_view, packed_uniforms: *const Packed) void {
        c.sg_apply_pipeline(pip);
        var bindings = std.mem.zeroes(c.sg_bindings);
        bindings.views[0] = texture;
        bindings.samplers[0] = self.sampler;
        c.sg_apply_bindings(&bindings);
        c.sg_apply_uniforms(0, &.{ .ptr = packed_uniforms, .size = @sizeOf(Packed) });
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
fn reportFailure(kind: []const u8, path: []const u8, err: anyerror, log: shadertoy.Log, notice: *shadertoy.Log) void {
    std.log.err("{s} '{s}' failed: {s} {s}", .{ kind, path, @errorName(err), log.slice() });
    if (notice.slice().len != 0) return;
    const detail = if (log.slice().len != 0) log.slice() else @errorName(err);
    var buf: [2048]u8 = undefined;
    notice.set(std.fmt.bufPrint(&buf, "{s} failed: {s}\n{s}\nSee hollow.log for details.", .{
        kind, path[0..@min(path.len, 512)], detail[0..@min(detail.len, 1024)],
    }) catch unreachable);
}

fn buildPass(alloc: std.mem.Allocator, path: []const u8, color_format: c.sg_pixel_format, depth_format: c.sg_pixel_format, premultiplied_blend: bool, log: *shadertoy.Log) !Pass {
    const source = try std.Io.Dir.cwd().readFileAlloc(io.get(), path, alloc, .limited(shadertoy.max_source_bytes));
    defer alloc.free(source);
    return buildSourcePassLogged(alloc, source, color_format, depth_format, premultiplied_blend, log);
}

fn buildSourcePass(alloc: std.mem.Allocator, source: []const u8, label: []const u8, color_format: c.sg_pixel_format, depth_format: c.sg_pixel_format, premultiplied_blend: bool) !Pass {
    var log: shadertoy.Log = .{};
    return buildSourcePassLogged(alloc, source, color_format, depth_format, premultiplied_blend, &log) catch |err| {
        std.log.err("{s}: {s} {s}", .{ label, @errorName(err), log.slice() });
        return err;
    };
}

fn buildSourcePassLogged(alloc: std.mem.Allocator, source: []const u8, color_format: c.sg_pixel_format, depth_format: c.sg_pixel_format, premultiplied_blend: bool, log: *shadertoy.Log) !Pass {
    const fragment = try shadertoy.compileFragment(alloc, source, target, log);
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

    errdefer c.sg_destroy_shader(shader);
    return .{ .shader = shader, .pipeline = try makePipeline(shader, color_format, depth_format, premultiplied_blend) };
}

fn makePipeline(shader: c.sg_shader, color_format: c.sg_pixel_format, depth_format: c.sg_pixel_format, premultiplied_blend: bool) !c.sg_pipeline {
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
        return error.PipelineInvalid;
    }
    return pipeline;
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
    try std.testing.expect(chain.wantsFrame(2 * std.time.ns_per_s + std.time.ns_per_s / 2, .cursor, .{}));
    try std.testing.expect(!chain.wantsFrame(4 * std.time.ns_per_s, .cursor, .{}));
    try std.testing.expect(chain.wantsFrame(4 * std.time.ns_per_s, .always, .{}));

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
    try std.testing.expect(chain.wantsFrame(10 * std.time.ns_per_s, .off, .{}));
    try std.testing.expect(!chain.wantsFrame(10 * std.time.ns_per_s, .off, .{ .shader_animate = false }));
}

test "post-process target failure does not keep an idle window repainting" {
    var chain: Chain = .{ .pass_count = 2, .target_size = .{ 800, 600 } };
    try std.testing.expectEqual(@as(?c.sg_attachments, null), chain.sceneAttachments(800, 600));
    try std.testing.expect(!chain.wantsFrame(0, .always, .{}));
    chain.target_size = .{ 0, 0 };
    try std.testing.expect(chain.wantsFrame(0, .always, .{}));
}

test "live smoke shader fixtures compile except for the broken replacement" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "bands", "mark", "swap", "broken" }) |name| {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "scripts/shader-smoke/{s}.glsl", .{name});
        const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, alloc, .limited(shadertoy.max_source_bytes));
        defer alloc.free(source);
        for ([_]shadertoy.Target{ .glsl, .hlsl }) |backend| {
            var log: shadertoy.Log = .{};
            const compiled = shadertoy.compileFragment(alloc, source, backend, &log);
            if (std.mem.eql(u8, name, "broken")) {
                try std.testing.expectError(error.ShaderInvalid, compiled);
                try std.testing.expect(std.mem.indexOf(u8, log.slice(), "intentional_compile_error") != null);
            } else {
                alloc.free(try compiled);
            }
        }
    }
}

test "cached background wakes only at its own refresh deadline" {
    const stub: Pass = .{ .shader = .{ .id = 0 }, .pipeline = .{ .id = 0 } };
    var chain: Chain = .{ .background = stub, .background_copy_pass = stub };
    var bg: Background = .{ .shader_max_fps = 30 };
    try std.testing.expect(chain.wantsFrame(0, .off, bg));
    chain.background_refresh.last_ns = 0;
    const deadline = chain.backgroundDeadline(bg).?;
    try std.testing.expectEqual(@as(i128, 33_333_333), deadline);
    try std.testing.expect(!chain.wantsFrame(deadline - 1, .off, bg));
    chain.pass_count = 1;
    try std.testing.expect(chain.wantsFrame(deadline - 1, .always, bg));
    try std.testing.expect(!chain.background_refresh.due(deadline - 1, bg.shader_max_fps));
    try std.testing.expect(chain.wantsFrame(deadline, .off, bg));
    try std.testing.expect(chain.background_refresh.due(deadline, bg.shader_max_fps));
    bg.shader_animate = false;
    try std.testing.expectEqual(@as(?i128, null), chain.backgroundDeadline(bg));
    try std.testing.expect(!chain.wantsFrame(deadline, .off, bg));
}

test "static background cache renders once until its layer changes" {
    const bg: Background = .{ .shader_animate = false, .shader_opacity = 0.8, .shader_brightness = 0.6 };
    const layer: BackgroundLayer = .{ .opacity = 0.8, .brightness = 0.6, .window_alpha = 1 };
    var refresh: BackgroundRefresh = .{};
    try std.testing.expect(refresh.stale(bg, layer, 0));
    refresh = .{ .last_ns = 0, .layer = layer };
    try std.testing.expect(!refresh.stale(bg, layer, 10 * std.time.ns_per_s));
    try std.testing.expect(refresh.stale(bg, .{ .opacity = 0.8, .brightness = 0.6, .window_alpha = 0.9 }, 0));
    try std.testing.expect(refresh.stale(bg, .{ .opacity = 0.5, .brightness = 0.6, .window_alpha = 1 }, 0));
    try std.testing.expect(refresh.stale(bg, .{ .opacity = 0.8, .brightness = 1, .window_alpha = 1 }, 0));
    // Animated layers also refresh at their deadline.
    var animated = bg;
    animated.shader_animate = true;
    animated.shader_max_fps = 30;
    try std.testing.expect(!refresh.stale(animated, layer, 33_333_332));
    try std.testing.expect(refresh.stale(animated, layer, 33_333_333));
}

test "background cache copy and upscale translate to both shader backends" {
    for ([_]shadertoy.Target{ .glsl, .hlsl }) |backend| {
        for ([_][]const u8{ background_copy, background_upscale }) |source| {
            var log: shadertoy.Log = .{};
            const fragment = try shadertoy.compileFragment(std.testing.allocator, source, backend, &log);
            std.testing.allocator.free(fragment);
        }
    }
}

test "scaled background uses actual target dimensions and scales cursor rectangles" {
    try std.testing.expectEqual(@as(u32, 1), backgroundExtent(1, 0.25));
    try std.testing.expectEqual(@as(u32, 450), backgroundExtent(901, 0.5));
    var uniforms: Uniforms = .{
        .resolution = .{ 9, 10 },
        .current_cursor = .{ 4.5, 4, 2.25, 2 },
        .previous_cursor = .{ 2.25, 8, 2.25, 2 },
    };
    scaleBackgroundUniforms(&uniforms, .{ 4, 5 });
    try std.testing.expectEqual([2]f32{ 4, 5 }, uniforms.resolution);
    try std.testing.expectEqual([4]f32{ 2, 2, 1, 1 }, uniforms.current_cursor);
    try std.testing.expectEqual([4]f32{ 1, 4, 1, 1 }, uniforms.previous_cursor);
}
