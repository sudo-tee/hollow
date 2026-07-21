/// Multi-atlas lifecycle — pages, packing, GPU upload, bounded growth.
///
/// Gray (RGBA8 coverage) pages for terminal glyphs, color (RGBA8) for emoji,
/// one UI (RGBA8) page for sgl labels. Full page → allocate another (up to cap).
/// Over cap → collapse that kind to one empty page and drop UV caches. Never
/// repacks live pages (old UVs stay valid until a kind-collapse).
const std = @import("std");
const c = @import("sokol_c");

const ft_types = @import("ft_types.zig");
const FtRenderer = @import("ft_renderer.zig").FtRenderer;

const AtlasKind = ft_types.AtlasKind;
const AtlasDirtyRect = ft_types.AtlasDirtyRect;
const Glyph = ft_types.Glyph;
const RecentPreparedEntry = ft_types.RecentPreparedEntry;
const RECENT_PREPARED_CACHE_LEN = ft_types.RECENT_PREPARED_CACHE_LEN;
const MAX_ATLAS_PAGES = ft_types.MAX_ATLAS_PAGES;
const MAX_GRAY_ATLASES = ft_types.MAX_GRAY_ATLASES;
const MAX_COLOR_ATLASES = ft_types.MAX_COLOR_ATLASES;
const MAX_UI_ATLASES = ft_types.MAX_UI_ATLASES;
const GRAY_ATLAS_W = ft_types.GRAY_ATLAS_W;
const GRAY_ATLAS_H = ft_types.GRAY_ATLAS_H;
const COLOR_ATLAS_W = ft_types.COLOR_ATLAS_W;
const COLOR_ATLAS_H = ft_types.COLOR_ATLAS_H;
const UI_ATLAS_W = ft_types.UI_ATLAS_W;
const UI_ATLAS_H = ft_types.UI_ATLAS_H;
const GRAY_BPP = ft_types.GRAY_BPP;
const COLOR_BPP = ft_types.COLOR_BPP;
const UI_BPP = ft_types.UI_BPP;

pub const AtlasPage = struct {
    kind: AtlasKind,
    img: c.sg_image,
    view: c.sg_view,
    data: []u8,
    w: u32,
    h: u32,
    bpp: u32,
    x: u32 = 1,
    y: u32 = 1,
    row_h: u32 = 0,
    dirty: bool = true,
    dirty_rect: AtlasDirtyRect = .{},
    uploaded_this_frame: bool = false,

    pub fn deinit(self: *AtlasPage, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        c.sg_destroy_view(self.view);
        c.sg_destroy_image(self.img);
        self.* = undefined;
    }

    pub fn rowPitch(self: *const AtlasPage) u32 {
        return self.w * self.bpp;
    }

    pub fn pixelFormat(self: *const AtlasPage) c.sg_pixel_format {
        _ = self;
        return c.SG_PIXELFORMAT_RGBA8;
    }
};

pub const AtlasSlot = struct {
    page_id: u8,
    x: u32,
    y: u32,
};

pub fn beginFrame(self: *FtRenderer) void {
    self.atlas_uploaded_this_frame = false;
    self.uploaded_glyph_verts = 0;
    self.atlas_reset_this_frame = false;
    self.glyph_atlas_run_count = 0;
    var i: u8 = 0;
    while (i < self.atlas_page_count) : (i += 1) {
        self.atlas_pages[i].uploaded_this_frame = false;
    }
}

pub fn flushAtlasIfDirty(self: *FtRenderer) void {
    if (self.atlas_dirty) self.flushAtlas();
}

pub fn flushAtlas(self: *FtRenderer) void {
    var any_upload = false;
    var i: u8 = 0;
    while (i < self.atlas_page_count) : (i += 1) {
        const page = &self.atlas_pages[i];
        if (!page.dirty or page.uploaded_this_frame) continue;
        const rect = page.dirty_rect;
        if (!rect.valid()) {
            page.dirty = false;
            continue;
        }
        const row_pitch = page.rowPitch();
        const offset = rect.min_y * row_pitch + rect.min_x * page.bpp;
        var region = std.mem.zeroes(c.sg_image_region);
        region.x = @intCast(rect.min_x);
        region.y = @intCast(rect.min_y);
        region.width = @intCast(rect.width());
        region.height = @intCast(rect.height());
        region.row_pitch = @intCast(row_pitch);
        region.data.ptr = page.data.ptr + offset;
        region.data.size = (rect.height() - 1) * row_pitch + rect.width() * page.bpp;
        c.sg_update_image_region(page.img, &region);
        page.dirty_rect.clear();
        page.dirty = false;
        page.uploaded_this_frame = true;
        any_upload = true;
    }
    if (any_upload) {
        self.atlas_uploaded_this_frame = true;
        self.atlas_append_epoch +%= 1;
    }
    self.atlas_dirty = anyPageDirty(self);
}

pub fn markPageDirty(self: *FtRenderer, page_id: u8, x: u32, y: u32, width: u32, height: u32) void {
    const page = &self.atlas_pages[page_id];
    page.dirty_rect.include(x, y, width, height);
    page.dirty = true;
    self.atlas_dirty = true;
}

fn anyPageDirty(self: *const FtRenderer) bool {
    var i: u8 = 0;
    while (i < self.atlas_page_count) : (i += 1) {
        if (self.atlas_pages[i].dirty) return true;
    }
    return false;
}

fn countKind(self: *const FtRenderer, kind: AtlasKind) u8 {
    var n: u8 = 0;
    var i: u8 = 0;
    while (i < self.atlas_page_count) : (i += 1) {
        if (self.atlas_pages[i].kind == kind) n += 1;
    }
    return n;
}

fn maxForKind(kind: AtlasKind) u8 {
    return switch (kind) {
        .gray => MAX_GRAY_ATLASES,
        .color => MAX_COLOR_ATLASES,
        .ui => MAX_UI_ATLASES,
    };
}

fn dimsForKind(kind: AtlasKind) struct { w: u32, h: u32, bpp: u32, fmt: c.sg_pixel_format, label: [:0]const u8 } {
    return switch (kind) {
        .gray => .{ .w = GRAY_ATLAS_W, .h = GRAY_ATLAS_H, .bpp = GRAY_BPP, .fmt = c.SG_PIXELFORMAT_RGBA8, .label = "ft-atlas-gray" },
        .color => .{ .w = COLOR_ATLAS_W, .h = COLOR_ATLAS_H, .bpp = COLOR_BPP, .fmt = c.SG_PIXELFORMAT_RGBA8, .label = "ft-atlas-color" },
        .ui => .{ .w = UI_ATLAS_W, .h = UI_ATLAS_H, .bpp = UI_BPP, .fmt = c.SG_PIXELFORMAT_RGBA8, .label = "ft-atlas-ui" },
    };
}

pub fn createPage(allocator: std.mem.Allocator, kind: AtlasKind) !AtlasPage {
    const d = dimsForKind(kind);
    const data = try allocator.alloc(u8, d.w * d.h * d.bpp);
    errdefer allocator.free(data);
    @memset(data, 0);

    var img_desc = std.mem.zeroes(c.sg_image_desc);
    img_desc.width = @intCast(d.w);
    img_desc.height = @intCast(d.h);
    img_desc.pixel_format = d.fmt;
    img_desc.usage.region_update = true;
    img_desc.label = d.label.ptr;
    const img = c.sg_make_image(&img_desc);

    var view_desc = std.mem.zeroes(c.sg_view_desc);
    view_desc.texture.image = img;
    const view = c.sg_make_view(&view_desc);

    var page = AtlasPage{
        .kind = kind,
        .img = img,
        .view = view,
        .data = data,
        .w = d.w,
        .h = d.h,
        .bpp = d.bpp,
        .dirty = true,
        .dirty_rect = .{},
    };
    page.dirty_rect.include(0, 0, d.w, d.h);
    return page;
}

fn appendPage(self: *FtRenderer, kind: AtlasKind) ?u8 {
    if (self.atlas_page_count >= MAX_ATLAS_PAGES) return null;
    if (countKind(self, kind) >= maxForKind(kind)) return null;
    const page = createPage(self.allocator, kind) catch return null;
    const id = self.atlas_page_count;
    self.atlas_pages[id] = page;
    self.atlas_page_count += 1;
    switch (kind) {
        .gray => self.atlas_current_gray = id,
        .color => self.atlas_current_color = id,
        .ui => self.atlas_current_ui = id,
    }
    self.atlas_dirty = true;
    std.log.info("ft_renderer: allocated {s} atlas page {d} ({d}x{d})", .{
        @tagName(kind), id, page.w, page.h,
    });
    return id;
}

/// Reserve bw×bh in a page of `kind`. Grows to a new page when full; collapses
/// that kind only when at cap (and only before any GPU upload this frame).
pub fn reserveAtlasSlot(self: *FtRenderer, kind: AtlasKind, bw: u32, bh: u32) ?AtlasSlot {
    if (tryReserveOnCurrent(self, kind, bw, bh)) |slot| return slot;

    // Grow: never repack existing pages.
    if (appendPage(self, kind)) |_| {
        if (tryReserveOnCurrent(self, kind, bw, bh)) |slot| return slot;
    }

    // At cap. Safe collapse only before upload (pass1); else drop glyph.
    if (self.atlas_uploaded_this_frame) {
        if (!self.atlas_full_logged) {
            std.log.warn("ft_renderer: {s} atlas full (at cap)!", .{@tagName(kind)});
            self.atlas_full_logged = true;
        }
        return null;
    }

    std.log.info("ft_renderer: {s} atlas at cap, collapsing (frame {d})", .{
        @tagName(kind), self.frame_count,
    });
    collapseKind(self, kind);
    return tryReserveOnCurrent(self, kind, bw, bh);
}

fn currentForKind(self: *const FtRenderer, kind: AtlasKind) u8 {
    return switch (kind) {
        .gray => self.atlas_current_gray,
        .color => self.atlas_current_color,
        .ui => self.atlas_current_ui,
    };
}

fn tryReserveOnCurrent(self: *FtRenderer, kind: AtlasKind, bw: u32, bh: u32) ?AtlasSlot {
    const id = currentForKind(self, kind);
    if (id >= self.atlas_page_count) return null;
    const page = &self.atlas_pages[id];
    if (page.kind != kind) return null;
    if (page.x + bw + 1 >= page.w) {
        page.x = 1;
        page.y += page.row_h + 1;
        page.row_h = 0;
    }
    if (page.y + bh >= page.h) return null;
    return .{ .page_id = id, .x = page.x, .y = page.y };
}

pub fn commitAtlasSlot(self: *FtRenderer, page_id: u8, bw: u32, bh: u32) void {
    const page = &self.atlas_pages[page_id];
    if (bh > page.row_h) page.row_h = bh;
    page.x += bw + 1;
}

/// Drop every page of `kind` except one empty survivor; clear UV caches.
pub fn collapseKind(self: *FtRenderer, kind: AtlasKind) void {
    var keep: ?u8 = null;
    var i: u8 = 0;
    while (i < self.atlas_page_count) : (i += 1) {
        if (self.atlas_pages[i].kind == kind) {
            keep = i;
            break;
        }
    }
    if (keep == null) {
        _ = appendPage(self, kind);
        keep = currentForKind(self, kind);
    }

    // Free other pages of this kind (swap-remove from end).
    var idx: u8 = 0;
    while (idx < self.atlas_page_count) {
        if (idx != keep.? and self.atlas_pages[idx].kind == kind) {
            self.atlas_pages[idx].deinit(self.allocator);
            const last = self.atlas_page_count - 1;
            if (idx != last) {
                self.atlas_pages[idx] = self.atlas_pages[last];
                // Fix current_* if they pointed at last.
                remapPageId(self, last, idx);
                if (keep.? == last) keep = idx;
            }
            self.atlas_page_count -= 1;
            continue;
        }
        idx += 1;
    }

    const kid = keep.?;
    const page = &self.atlas_pages[kid];
    @memset(page.data, 0);
    page.x = 1;
    page.y = 1;
    page.row_h = 0;
    page.dirty_rect = .{};
    page.dirty_rect.include(0, 0, page.w, page.h);
    page.dirty = true;
    page.uploaded_this_frame = false;
    switch (kind) {
        .gray => self.atlas_current_gray = kid,
        .color => self.atlas_current_color = kid,
        .ui => self.atlas_current_ui = kid,
    }

    clearUvCaches(self);
    self.atlas_reset_this_frame = true;
    self.atlas_full_logged = false;
    self.atlas_reset_epoch +%= 1;
    self.atlas_dirty = true;
}

fn remapPageId(self: *FtRenderer, from: u8, to: u8) void {
    if (self.atlas_current_gray == from) self.atlas_current_gray = to;
    if (self.atlas_current_color == from) self.atlas_current_color = to;
    if (self.atlas_current_ui == from) self.atlas_current_ui = to;
}

fn clearUvCaches(self: *FtRenderer) void {
    self.glyph_cache.clearRetainingCapacity();
    var prepared_it = self.prepared_cache.valueIterator();
    while (prepared_it.next()) |val| {
        self.allocator.free(val.glyphs);
    }
    self.prepared_cache.clearRetainingCapacity();
    self.recent_prepared = [_]?RecentPreparedEntry{null} ** RECENT_PREPARED_CACHE_LEN;
    self.ascii_glyphs = [_][256]?Glyph{[_]?Glyph{null} ** 256} ** 4;
    self.prepared_glyphs.clearRetainingCapacity();
    self.shaped_runs.clearRetainingCapacity();
    self.shaped_run_read_idx = 0;
}

/// Init: one gray + one color + one ui page.
pub fn initPages(self: *FtRenderer) !void {
    self.atlas_page_count = 0;
    errdefer deinitPages(self);

    const g = try createPage(self.allocator, .gray);
    self.atlas_pages[0] = g;
    self.atlas_page_count = 1;
    self.atlas_current_gray = 0;

    const col = try createPage(self.allocator, .color);
    self.atlas_pages[1] = col;
    self.atlas_page_count = 2;
    self.atlas_current_color = 1;

    const ui = try createPage(self.allocator, .ui);
    self.atlas_pages[2] = ui;
    self.atlas_page_count = 3;
    self.atlas_current_ui = 2;

    self.atlas_dirty = true;
}

pub fn deinitPages(self: *FtRenderer) void {
    var i: u8 = 0;
    while (i < self.atlas_page_count) : (i += 1) {
        self.atlas_pages[i].deinit(self.allocator);
    }
    self.atlas_page_count = 0;
}

pub fn pageView(self: *const FtRenderer, page_id: u8) c.sg_view {
    return self.atlas_pages[page_id].view;
}

pub fn uiAtlasView(self: *const FtRenderer) c.sg_view {
    return self.atlas_pages[self.atlas_current_ui].view;
}

/// Legacy no-ops / compatibility shims.
pub fn resetAtlasIfNeeded(_: *FtRenderer) void {
    // Growth handles capacity; collapse only on reserve failure at cap.
}

pub fn resetAtlas(self: *FtRenderer) void {
    collapseKind(self, .gray);
    collapseKind(self, .color);
    collapseKind(self, .ui);
}
