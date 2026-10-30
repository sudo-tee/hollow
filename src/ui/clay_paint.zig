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

/// Snaps edges to whole pixels so fractional Clay centering cannot leave
/// backgrounds, borders and rounded glyph origins half a pixel apart.
pub fn snap(bounds: c.Clay_BoundingBox) c.Clay_BoundingBox {
    const x = @round(bounds.x);
    const y = @round(bounds.y);
    return .{
        .x = x,
        .y = y,
        .width = @max(0, @round(bounds.x + bounds.width) - x),
        .height = @max(0, @round(bounds.y + bounds.height) - y),
    };
}
