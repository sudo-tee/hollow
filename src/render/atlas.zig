/// Atlas lifecycle management — frame begin, GPU upload, and eviction.
///
/// These are free functions taking `*FtRenderer`; the struct wraps them as
/// one-line methods so existing call sites (`self.flushAtlas()`, etc.) work
/// unchanged.

const std = @import("std");
const c = @import("sokol_c");

const ft_types = @import("ft_types.zig");
const FtRenderer = @import("ft_renderer.zig").FtRenderer;

const ATLAS_W = ft_types.ATLAS_W;
const ATLAS_H = ft_types.ATLAS_H;
const ATLAS_BPP = ft_types.ATLAS_BPP;
const RECENT_PREPARED_CACHE_LEN = ft_types.RECENT_PREPARED_CACHE_LEN;
const Glyph = ft_types.Glyph;
const RecentPreparedEntry = ft_types.RecentPreparedEntry;

/// Call once at the start of each frame to allow atlas upload for that frame.
pub fn beginFrame(self: *FtRenderer) void {
    self.atlas_uploaded_this_frame = false;
    self.uploaded_glyph_verts = 0;
}

/// Upload atlas to GPU if it has been modified and not yet uploaded this frame.
/// Safe to call multiple times per frame — only the first call uploads.
pub fn flushAtlasIfDirty(self: *FtRenderer) void {
    if (self.atlas_dirty and !self.atlas_uploaded_this_frame) {
        self.flushAtlas();
        self.atlas_dirty = false;
    }
}

pub fn flushAtlas(self: *FtRenderer) void {
    if (self.atlas_uploaded_this_frame) return;
    var upd = std.mem.zeroes(c.sg_image_data);
    upd.mip_levels[0].ptr = self.atlas_data.ptr;
    upd.mip_levels[0].size = ATLAS_W * ATLAS_H * ATLAS_BPP;
    c.sg_update_image(self.atlas_img, &upd);
    self.atlas_uploaded_this_frame = true;
    self.atlas_epoch +%= 1;
}

/// Evict the glyph atlas and all caches when the atlas is >=90% full.
/// This prevents the "atlas full" hard stop and keeps memory bounded.
/// All glyphs will be re-rasterized on demand over the next few frames.
pub fn resetAtlasIfNeeded(self: *FtRenderer) void {
    if (self.atlas_y < (ATLAS_H * 9) / 10) return;
    std.log.info("ft_renderer: atlas >=90% full at row {d}/{d}, evicting (frame {d})", .{
        self.atlas_y, ATLAS_H, self.frame_count,
    });
    @memset(self.atlas_data, 0);
    self.atlas_x = 1;
    self.atlas_y = 1;
    self.atlas_row_h = 0;
    self.atlas_dirty = true;
    self.glyph_cache.clearRetainingCapacity();
    var shape_it = self.shape_cache.valueIterator();
    while (shape_it.next()) |val| {
        self.allocator.free(val.glyphs);
    }
    self.shape_cache.clearRetainingCapacity();
    var prepared_it = self.prepared_cache.valueIterator();
    while (prepared_it.next()) |val| {
        self.allocator.free(val.glyphs);
    }
    self.prepared_cache.clearRetainingCapacity();
    self.recent_prepared = [_]?RecentPreparedEntry{null} ** RECENT_PREPARED_CACHE_LEN;
    self.ascii_glyphs = [_][256]?Glyph{[_]?Glyph{null} ** 256} ** 4;
}
