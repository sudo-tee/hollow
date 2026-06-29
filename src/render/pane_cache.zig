/// Per-pane offscreen render-target cache.
///
/// Each pane gets one `PaneCache` that holds:
///   - An offscreen RGBA8 render-target image (same pixel size as the pane).
///   - Two views: one color-attachment view (used as the pass attachment) and
///     one texture view (used to sample the result in the blit pass).
///   - A dedicated sgl_context so that pane draw commands are isolated from the
///     main context (tab bar, borders, etc.).
///   - A context-specific atlas pipeline that matches the offscreen color format.
///
/// Workflow per frame:
///   1. If dirty (or first frame / size changed): begin offscreen pass on this
///      pane's RT, set sgl context, call queueInViewport, sgl_context_draw,
///      end offscreen pass.
///   2. Regardless: in the main swapchain pass, blit the RT texture as a
///      textured quad at the pane's viewport position (one quad per pane).
///
/// This means clean frames (no terminal changes, no cursor movement) skip all
/// cell iteration entirely and just submit 2 triangles per pane.

const std = @import("std");
const c = @import("sokol_c");

pub const PaneCache = struct {
    rt_img: c.sg_image,
    rt_att_view: c.sg_view,
    rt_tex_view: c.sg_view,
    rt_smp: c.sg_sampler,
    sgl_ctx: c.sgl_context,
    atlas_pip: c.sgl_pipeline,
    blit_smp: c.sg_sampler,
    width: u32,
    height: u32,

    pub fn init(w: u32, h: u32) PaneCache {
        var img_desc = std.mem.zeroes(c.sg_image_desc);
        img_desc.width = @intCast(w);
        img_desc.height = @intCast(h);
        img_desc.pixel_format = c.SG_PIXELFORMAT_RGBA8;
        img_desc.usage.color_attachment = true;
        img_desc.label = "pane-rt";
        const rt_img = c.sg_make_image(&img_desc);

        var att_desc = std.mem.zeroes(c.sg_view_desc);
        att_desc.color_attachment.image = rt_img;
        const rt_att_view = c.sg_make_view(&att_desc);

        var tex_desc = std.mem.zeroes(c.sg_view_desc);
        tex_desc.texture.image = rt_img;
        const rt_tex_view = c.sg_make_view(&tex_desc);

        var smp_desc = std.mem.zeroes(c.sg_sampler_desc);
        smp_desc.min_filter = c.SG_FILTER_LINEAR;
        smp_desc.mag_filter = c.SG_FILTER_LINEAR;
        smp_desc.label = "pane-rt-smp";
        const rt_smp = c.sg_make_sampler(&smp_desc);

        var blit_smp_desc = std.mem.zeroes(c.sg_sampler_desc);
        blit_smp_desc.min_filter = c.SG_FILTER_NEAREST;
        blit_smp_desc.mag_filter = c.SG_FILTER_NEAREST;
        blit_smp_desc.label = "pane-blit-smp";
        const blit_smp = c.sg_make_sampler(&blit_smp_desc);

        var ctx_desc = std.mem.zeroes(c.sgl_context_desc_t);
        ctx_desc.max_vertices = 1 << 18;
        ctx_desc.max_commands = 1 << 16;
        ctx_desc.color_format = c.SG_PIXELFORMAT_RGBA8;
        ctx_desc.depth_format = c.SG_PIXELFORMAT_NONE;
        ctx_desc.sample_count = 1;
        const sgl_ctx = c.sgl_make_context(&ctx_desc);

        c.sgl_set_context(sgl_ctx);
        var pip_desc = std.mem.zeroes(c.sg_pipeline_desc);
        pip_desc.colors[0].blend.enabled = true;
        pip_desc.colors[0].blend.src_factor_rgb = c.SG_BLENDFACTOR_ONE;
        pip_desc.colors[0].blend.dst_factor_rgb = c.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        pip_desc.colors[0].blend.src_factor_alpha = c.SG_BLENDFACTOR_ONE;
        pip_desc.colors[0].blend.dst_factor_alpha = c.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        const atlas_pip = c.sgl_context_make_pipeline(sgl_ctx, &pip_desc);
        c.sgl_set_context(c.sgl_default_context());

        return .{
            .rt_img = rt_img,
            .rt_att_view = rt_att_view,
            .rt_tex_view = rt_tex_view,
            .rt_smp = rt_smp,
            .blit_smp = blit_smp,
            .sgl_ctx = sgl_ctx,
            .atlas_pip = atlas_pip,
            .width = w,
            .height = h,
        };
    }

    pub fn clear(self: *PaneCache) void {
        var pass = std.mem.zeroes(c.sg_pass);
        pass.attachments.colors[0] = self.rt_att_view;
        pass.action.colors[0].load_action = c.SG_LOADACTION_CLEAR;
        pass.action.colors[0].clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };
        c.sg_begin_pass(&pass);
        c.sg_end_pass();
    }

    pub fn deinit(self: *PaneCache) void {
        c.sgl_destroy_pipeline(self.atlas_pip);
        c.sgl_destroy_context(self.sgl_ctx);
        c.sg_destroy_sampler(self.blit_smp);
        c.sg_destroy_sampler(self.rt_smp);
        c.sg_destroy_view(self.rt_tex_view);
        c.sg_destroy_view(self.rt_att_view);
        c.sg_destroy_image(self.rt_img);
    }

    pub fn needsResize(self: *const PaneCache, w: u32, h: u32) bool {
        return self.width != w or self.height != h;
    }
};
