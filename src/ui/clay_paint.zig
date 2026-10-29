const c = @import("clay_c");

// Paint only; Clay geometry and the active scissor stack remain untouched.
pub fn rectangleBounds(bounds: c.Clay_BoundingBox, panel: c.Clay_BoundingBox, inset: f32, owner: usize, framed: bool, full_bleed_x: bool) c.Clay_BoundingBox {
    var result = bounds;
    if (owner > 0 and framed and full_bleed_x) {
        result.x = panel.x + inset;
        result.width = @max(0, panel.width - 2 * inset);
    }
    return result;
}
