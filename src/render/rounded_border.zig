const std = @import("std");

pub const Point = struct { x: f32, y: f32 };

// Shared unit-circle samples avoid per-frame trigonometry. Subdivide until the
// chord deviates by at most 0.15 pixels, with a fixed upper bound on mesh size.
const quarter = blk: {
    var points: [33]Point = undefined;
    for (&points, 0..) |*point, i| {
        const angle = @as(f32, @floatFromInt(i)) * (std.math.pi / 64.0);
        point.* = .{ .x = @cos(angle), .y = @sin(angle) };
    }
    break :blk points;
};

pub const Sample = struct {
    points: [4]Point,
    coverage: [4]f32,
};

/// Four contours form the outer fringe, opaque stroke, and inner fringe.
/// Adjacent strips share edges; no overlapping translucent edge rectangles.
pub const Border = struct {
    width: f32,
    height: f32,
    radius: f32,
    thickness: f32,
    segments: usize,

    pub fn init(width: f32, height: f32, radius: f32, thickness: f32) Border {
        const r = @min(@max(0, radius), @min(width, height) * 0.5);
        var segments: usize = 4;
        while (segments < 32 and (r + 0.5) * (1 - quarter[16 / segments].x) > 0.15)
            segments *= 2;
        return .{ .width = width, .height = height, .radius = r, .thickness = thickness, .segments = segments };
    }

    pub fn count(self: Border) usize {
        return 4 * (self.segments + 1);
    }

    pub fn sample(self: Border, index: usize) Sample {
        const corner = index / (self.segments + 1);
        const direction = quarter[(index % (self.segments + 1)) * (32 / self.segments)];
        const normal: Point = switch (corner) {
            0 => .{ .x = -direction.x, .y = -direction.y },
            1 => .{ .x = direction.y, .y = -direction.x },
            2 => .{ .x = direction.x, .y = direction.y },
            else => .{ .x = -direction.y, .y = direction.x },
        };
        // A subpixel stroke has a lower coverage plateau, not overlapping
        // fringes. Its integrated coverage still equals its thickness.
        const offsets = [4]f32{ -0.5, @min(0.5, self.thickness - 0.5), @max(0.5, self.thickness - 0.5), self.thickness + 0.5 };
        const peak = @min(1, self.thickness);
        var result: Sample = .{ .points = undefined, .coverage = .{ 0, peak, peak, 0 } };
        for (offsets, &result.points) |raw_offset, *point| {
            const offset = @min(raw_offset, @min(self.width, self.height) * 0.5);
            const radius = @max(0, self.radius - offset);
            const cx = if (corner == 0 or corner == 3) offset + radius else self.width - offset - radius;
            const cy = if (corner < 2) offset + radius else self.height - offset - radius;
            point.* = .{ .x = cx + normal.x * radius, .y = cy + normal.y * radius };
        }
        return result;
    }
};

test "rounded border has bounded curvature-dependent geometry" {
    const small = Border.init(100, 40, 6, 2);
    const tall = Border.init(100, 4000, 6, 2);
    try std.testing.expectEqual(small.count(), tall.count());
    try std.testing.expectEqual(@as(usize, 20), small.count());
    try std.testing.expect(Border.init(10000, 10000, 4000, 2).count() <= 132);
}

test "rounded border fringes straddle both stroke edges" {
    const border = Border.init(100, 40, 6, 2);
    const sample = border.sample(0);
    try std.testing.expectEqual(@as(f32, -0.5), sample.points[0].x);
    try std.testing.expectEqual(@as(f32, 0.5), sample.points[1].x);
    try std.testing.expectEqual(@as(f32, 1.5), sample.points[2].x);
    try std.testing.expectEqual(@as(f32, 2.5), sample.points[3].x);
    try std.testing.expectEqualSlices(f32, &.{ 0, 1, 1, 0 }, &sample.coverage);
    const opposite = border.sample(2 * (border.segments + 1));
    for (sample.points, opposite.points) |a, b| {
        try std.testing.expectApproxEqAbs(border.width, a.x + b.x, 0.0001);
        try std.testing.expectApproxEqAbs(border.height, a.y + b.y, 0.0001);
    }
}

test "thin strokes keep coverage and collapsed inner corners stay finite" {
    const thin = Border.init(100, 40, 6, 0.5).sample(0);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0.5, 0.5, 0 }, &thin.coverage);
    try std.testing.expectEqual(@as(f32, 0), thin.points[1].x);
    try std.testing.expectEqual(@as(f32, 0.5), thin.points[2].x);
    const thick = Border.init(100, 40, 3, 8);
    for (0..thick.count()) |index| {
        for (thick.sample(index).points) |point| {
            try std.testing.expect(std.math.isFinite(point.x));
            try std.testing.expect(std.math.isFinite(point.y));
        }
    }
}
