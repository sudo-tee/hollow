const c = @import("clay_c");

/// Intersects a scissor command with the enclosing clip. Clay emits floating
/// roots clipped to their attached parent without axis flags, so a flagless
/// scissor clips both axes.
pub fn scissorBounds(previous: c.Clay_BoundingBox, bounds: c.Clay_BoundingBox, clip: c.Clay_ClipRenderData) c.Clay_BoundingBox {
    const both = !clip.horizontal and !clip.vertical;
    const horizontal = both or clip.horizontal;
    const vertical = both or clip.vertical;
    const x = if (horizontal) @max(previous.x, bounds.x) else previous.x;
    const y = if (vertical) @max(previous.y, bounds.y) else previous.y;
    const right = if (horizontal) @min(previous.x + previous.width, bounds.x + bounds.width) else previous.x + previous.width;
    const bottom = if (vertical) @min(previous.y + previous.height, bounds.y + bounds.height) else previous.y + previous.height;
    return .{ .x = x, .y = y, .width = @max(0, right - x), .height = @max(0, bottom - y) };
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
