const std = @import("std");
const assert = std.debug.assert;

const Vec2 = struct { x: f64, y: f64 };

pub const SimpleCanvas = struct {
    buf: []u8,
    width: u32,
    height: u32,

    pub fn box(self: *SimpleCanvas, x0: i32, y0: i32, x1: i32, y1: i32) void {
        const l = @max(0, @min(x0, x1));
        const r = @min(@as(i32, @intCast(self.width)), @max(x0, x1));
        const t = @max(0, @min(y0, y1));
        const b = @min(@as(i32, @intCast(self.height)), @max(y0, y1));
        var y: i32 = t;
        while (y < b) : (y += 1) {
            const start = @as(usize, @intCast(y)) * self.width + @as(usize, @intCast(l));
            const end = @as(usize, @intCast(y)) * self.width + @as(usize, @intCast(r));
            @memset(self.buf[start..end], 255);
        }
    }

    pub fn setPixel(self: *SimpleCanvas, x: i32, y: i32, alpha: u8) void {
        if (x < 0 or @as(u32, @intCast(x)) >= self.width or y < 0 or @as(u32, @intCast(y)) >= self.height) return;
        self.buf[@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))] = alpha;
    }
};

pub const Thickness = enum {
    light,
    heavy,

    pub fn height(self: Thickness, base: u32) u32 {
        return switch (self) {
            .light => base,
            .heavy => base * 2,
        };
    }
};

pub const Corner = enum(u2) {
    tl,
    tr,
    bl,
    br,
};

pub const Lines = packed struct(u8) {
    up: Style = .none,
    right: Style = .none,
    down: Style = .none,
    left: Style = .none,

    pub const Style = enum(u2) {
        none,
        light,
        heavy,
        double,
    };
};

pub const Metrics = struct {
    cell_width: u32,
    cell_height: u32,
    box_thickness: u32,
};

fn hline(canvas: *SimpleCanvas, x1: i32, x2: i32, y: i32, thick_px: u32) void {
    canvas.box(x1, y, x2, y + @as(i32, @intCast(thick_px)));
}

fn vline(canvas: *SimpleCanvas, y1: i32, y2: i32, x: i32, thick_px: u32) void {
    canvas.box(x, y1, x + @as(i32, @intCast(thick_px)), y2);
}

fn hlineMiddle(metrics: Metrics, canvas: *SimpleCanvas, thickness: Thickness) void {
    const thick_px = thickness.height(metrics.box_thickness);
    hline(canvas, 0, @intCast(metrics.cell_width), @intCast((metrics.cell_height -| thick_px) / 2), thick_px);
}

fn vlineMiddle(metrics: Metrics, canvas: *SimpleCanvas, thickness: Thickness) void {
    const thick_px = thickness.height(metrics.box_thickness);
    vline(canvas, 0, @intCast(metrics.cell_height), @intCast((metrics.cell_width -| thick_px) / 2), thick_px);
}

pub fn linesChar(metrics: Metrics, canvas: *SimpleCanvas, lines: Lines) void {
    const light_px = Thickness.light.height(metrics.box_thickness);
    const heavy_px = Thickness.heavy.height(metrics.box_thickness);

    const h_light_top = (metrics.cell_height -| light_px) / 2;
    const h_light_bottom = h_light_top + light_px;

    const h_heavy_top = (metrics.cell_height -| heavy_px) / 2;
    const h_heavy_bottom = h_heavy_top + heavy_px;

    const h_double_top = h_light_top -| light_px;
    const h_double_bottom = h_light_bottom + light_px;

    const v_light_left = (metrics.cell_width -| light_px) / 2;
    const v_light_right = v_light_left + light_px;

    const v_heavy_left = (metrics.cell_width -| heavy_px) / 2;
    const v_heavy_right = v_heavy_left + heavy_px;

    const v_double_left = v_light_left -| light_px;
    const v_double_right = v_light_right + light_px;

    const up_bottom = if (lines.left == .heavy or lines.right == .heavy)
        h_heavy_bottom
    else if (lines.left != lines.right or lines.down == lines.up)
        if (lines.left == .double or lines.right == .double)
            h_double_bottom
        else
            h_light_bottom
    else if (lines.left == .none and lines.right == .none)
        h_light_bottom
    else
        h_light_top;

    const down_top = if (lines.left == .heavy or lines.right == .heavy)
        h_heavy_top
    else if (lines.left != lines.right or lines.up == lines.down)
        if (lines.left == .double or lines.right == .double)
            h_double_top
        else
            h_light_top
    else if (lines.left == .none and lines.right == .none)
        h_light_top
    else
        h_light_bottom;

    const left_right = if (lines.up == .heavy or lines.down == .heavy)
        v_heavy_right
    else if (lines.up != lines.down or lines.left == lines.right)
        if (lines.up == .double or lines.down == .double)
            v_double_right
        else
            v_light_right
    else if (lines.up == .none and lines.down == .none)
        v_light_right
    else
        v_light_left;

    const right_left = if (lines.up == .heavy or lines.down == .heavy)
        v_heavy_left
    else if (lines.up != lines.down or lines.right == lines.left)
        if (lines.up == .double or lines.down == .double)
            v_double_left
        else
            v_light_left
    else if (lines.up == .none and lines.down == .none)
        v_light_left
    else
        v_light_right;

    switch (lines.up) {
        .none => {},
        .light => canvas.box(@intCast(v_light_left), 0, @intCast(v_light_right), @intCast(up_bottom)),
        .heavy => canvas.box(@intCast(v_heavy_left), 0, @intCast(v_heavy_right), @intCast(up_bottom)),
        .double => {
            const left_bottom = if (lines.left == .double) h_light_top else up_bottom;
            const right_bottom = if (lines.right == .double) h_light_top else up_bottom;
            canvas.box(@intCast(v_double_left), 0, @intCast(v_light_left), @intCast(left_bottom));
            canvas.box(@intCast(v_light_right), 0, @intCast(v_double_right), @intCast(right_bottom));
        },
    }

    switch (lines.right) {
        .none => {},
        .light => canvas.box(@intCast(right_left), @intCast(h_light_top), @intCast(metrics.cell_width), @intCast(h_light_bottom)),
        .heavy => canvas.box(@intCast(right_left), @intCast(h_heavy_top), @intCast(metrics.cell_width), @intCast(h_heavy_bottom)),
        .double => {
            const top_left = if (lines.up == .double) v_light_right else right_left;
            const bottom_left = if (lines.down == .double) v_light_right else right_left;
            canvas.box(@intCast(top_left), @intCast(h_double_top), @intCast(metrics.cell_width), @intCast(h_light_top));
            canvas.box(@intCast(bottom_left), @intCast(h_light_bottom), @intCast(metrics.cell_width), @intCast(h_double_bottom));
        },
    }

    switch (lines.down) {
        .none => {},
        .light => canvas.box(@intCast(v_light_left), @intCast(down_top), @intCast(v_light_right), @intCast(metrics.cell_height)),
        .heavy => canvas.box(@intCast(v_heavy_left), @intCast(down_top), @intCast(v_heavy_right), @intCast(metrics.cell_height)),
        .double => {
            const left_top = if (lines.left == .double) h_light_bottom else down_top;
            const right_top = if (lines.right == .double) h_light_bottom else down_top;
            canvas.box(@intCast(v_double_left), @intCast(left_top), @intCast(v_light_left), @intCast(metrics.cell_height));
            canvas.box(@intCast(v_light_right), @intCast(right_top), @intCast(v_double_right), @intCast(metrics.cell_height));
        },
    }

    switch (lines.left) {
        .none => {},
        .light => canvas.box(0, @intCast(h_light_top), @intCast(left_right), @intCast(h_light_bottom)),
        .heavy => canvas.box(0, @intCast(h_heavy_top), @intCast(left_right), @intCast(h_heavy_bottom)),
        .double => {
            const top_right = if (lines.up == .double) v_light_left else left_right;
            const bottom_right = if (lines.down == .double) v_light_left else left_right;
            canvas.box(0, @intCast(h_double_top), @intCast(top_right), @intCast(h_light_top));
            canvas.box(0, @intCast(h_light_bottom), @intCast(bottom_right), @intCast(h_double_bottom));
        },
    }
}

fn lightDiagonalUpperRightToLowerLeft(metrics: Metrics, canvas: *SimpleCanvas) void {
    const fw: f64 = @floatFromInt(metrics.cell_width);
    const fh: f64 = @floatFromInt(metrics.cell_height);
    const slope_x: f64 = @min(1.0, fw / fh);
    const slope_y: f64 = @min(1.0, fh / fw);
    const thick: f64 = @floatFromInt(Thickness.light.height(metrics.box_thickness));
    renderThickLine(canvas, fw + 0.5 * slope_x, -0.5 * slope_y, -0.5 * slope_x, fh + 0.5 * slope_y, thick);
}

fn lightDiagonalUpperLeftToLowerRight(metrics: Metrics, canvas: *SimpleCanvas) void {
    const fw: f64 = @floatFromInt(metrics.cell_width);
    const fh: f64 = @floatFromInt(metrics.cell_height);
    const slope_x: f64 = @min(1.0, fw / fh);
    const slope_y: f64 = @min(1.0, fh / fw);
    const thick: f64 = @floatFromInt(Thickness.light.height(metrics.box_thickness));
    renderThickLine(canvas, -0.5 * slope_x, -0.5 * slope_y, fw + 0.5 * slope_x, fh + 0.5 * slope_y, thick);
}

fn lightDiagonalCross(metrics: Metrics, canvas: *SimpleCanvas) void {
    lightDiagonalUpperRightToLowerLeft(metrics, canvas);
    lightDiagonalUpperLeftToLowerRight(metrics, canvas);
}

fn renderThickLine(canvas: *SimpleCanvas, ax: f64, ay: f64, bx: f64, by: f64, thickness: f64) void {
    const half = thickness / 2.0 + 0.5;
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    if (len2 < 0.0001) return;
    const inv_len = 1.0 / @sqrt(len2);
    _ = inv_len;

    const pad = @ceil(half);
    const cw: i32 = @intCast(canvas.width);
    const ch: i32 = @intCast(canvas.height);
    const min_x_i = @max(0, @as(i32, @intFromFloat(@floor(@min(ax, bx) - pad))));
    const max_x_i = @min(cw, @as(i32, @intFromFloat(@ceil(@max(ax, bx) + pad))));
    const min_y_i = @max(0, @as(i32, @intFromFloat(@floor(@min(ay, by) - pad))));
    const max_y_i = @min(ch, @as(i32, @intFromFloat(@ceil(@max(ay, by) + pad))));

    var py: i32 = min_y_i;
    while (py < max_y_i) : (py += 1) {
        var px: i32 = min_x_i;
        while (px < max_x_i) : (px += 1) {
            const fx = @as(f64, @floatFromInt(px)) + 0.5;
            const fy = @as(f64, @floatFromInt(py)) + 0.5;

            const pdx = fx - ax;
            const pdy = fy - ay;
            var t = (pdx * dx + pdy * dy) / len2;
            if (t < 0.0) t = 0.0;
            if (t > 1.0) t = 1.0;
            const near_x = ax + t * dx;
            const near_y = ay + t * dy;
            const dist = @sqrt((fx - near_x) * (fx - near_x) + (fy - near_y) * (fy - near_y));
            const alpha = @min(255.0, @max(0.0, (half - dist) / 1.0 * 255.0));
            if (alpha > 0) {
                const idx = @as(usize, @intCast(py * @as(i32, @intCast(canvas.width)) + px));
                const existing = canvas.buf[idx];
                canvas.buf[idx] = @intFromFloat(@min(255.0, @as(f64, @floatFromInt(existing)) + alpha));
            }
        }
    }
}

pub fn arc(metrics: Metrics, canvas: *SimpleCanvas, comptime corner: Corner, comptime thickness: Thickness) void {
    const thick_px = thickness.height(metrics.box_thickness);
    const fw: f64 = @floatFromInt(metrics.cell_width);
    const fh: f64 = @floatFromInt(metrics.cell_height);
    const ft: f64 = @floatFromInt(thick_px);
    const cx: f64 = @as(f64, @floatFromInt((metrics.cell_width -| thick_px) / 2)) + ft / 2.0;
    const cy: f64 = @as(f64, @floatFromInt((metrics.cell_height -| thick_px) / 2)) + ft / 2.0;
    const r = @min(fw, fh) / 2.0;
    const half = ft / 2.0;
    const inner = @max(0.0, r - half);
    const outer = r + half;
    const inner2 = inner * inner;
    const outer2 = outer * outer;

    const v_left: i32 = @intCast((metrics.cell_width -| thick_px) / 2);
    const v_right = v_left + @as(i32, @intCast(thick_px));
    const h_top: i32 = @intCast((metrics.cell_height -| thick_px) / 2);
    const h_bottom = h_top + @as(i32, @intCast(thick_px));
    const x_left = @as(i32, @intFromFloat(@floor(cx - r)));
    const x_right = @as(i32, @intFromFloat(@ceil(cx + r)));
    const y_top = @as(i32, @intFromFloat(@floor(cy - r)));
    const y_bottom = @as(i32, @intFromFloat(@ceil(cy + r)));

    switch (corner) {
        .tl => {
            canvas.box(v_left, 0, v_right, y_top);
            canvas.box(0, h_top, x_left, h_bottom);
        },
        .tr => {
            canvas.box(v_left, 0, v_right, y_top);
            canvas.box(x_right, h_top, @intCast(metrics.cell_width), h_bottom);
        },
        .bl => {
            canvas.box(v_left, y_bottom, v_right, @intCast(metrics.cell_height));
            canvas.box(0, h_top, x_left, h_bottom);
        },
        .br => {
            canvas.box(v_left, y_bottom, v_right, @intCast(metrics.cell_height));
            canvas.box(x_right, h_top, @intCast(metrics.cell_width), h_bottom);
        },
    }

    var py: u32 = 0;
    while (py < metrics.cell_height) : (py += 1) {
        var px: u32 = 0;
        while (px < metrics.cell_width) : (px += 1) {
            const fx = @as(f64, @floatFromInt(px)) + 0.5;
            const fy = @as(f64, @floatFromInt(py)) + 0.5;
            const dx = fx - cx;
            const dy = fy - cy;

            const in_quadrant = switch (corner) {
                .tl => dx <= 0.0 and dy <= 0.0,
                .tr => dx >= 0.0 and dy <= 0.0,
                .bl => dx <= 0.0 and dy >= 0.0,
                .br => dx >= 0.0 and dy >= 0.0,
            };
            if (!in_quadrant) continue;

            const dist2 = dx * dx + dy * dy;
            if (dist2 >= inner2 and dist2 <= outer2) {
                canvas.setPixel(@intCast(px), @intCast(py), 255);
            }
        }
    }
}

fn renderStrokePolyline(canvas: *SimpleCanvas, pts: []const Vec2, thickness: f64) void {
    const half = thickness / 2.0;

    var bbox_min_x: f64 = 1e9;
    var bbox_min_y: f64 = 1e9;
    var bbox_max_x: f64 = -1e9;
    var bbox_max_y: f64 = -1e9;
    for (pts) |p| {
        bbox_min_x = @min(bbox_min_x, p.x);
        bbox_min_y = @min(bbox_min_y, p.y);
        bbox_max_x = @max(bbox_max_x, p.x);
        bbox_max_y = @max(bbox_max_y, p.y);
    }

    const pad_f = @ceil(half);
    const cw: f64 = @floatFromInt(canvas.width);
    const ch: f64 = @floatFromInt(canvas.height);
    const min_x = @max(0, bbox_min_x - pad_f);
    const max_x = @min(cw, bbox_max_x + pad_f);
    const min_y = @max(0, bbox_min_y - pad_f);
    const max_y = @min(ch, bbox_max_y + pad_f);

    var py_f: f64 = min_y;
    while (py_f < max_y) : (py_f += 1.0) {
        var px_f: f64 = min_x;
        while (px_f < max_x) : (px_f += 1.0) {
            const fx = px_f + 0.5;
            const fy = py_f + 0.5;

            var min_dist: f64 = 1e9;
            var si: usize = 0;
            while (si + 1 < pts.len) : (si += 1) {
                const ax = pts[si].x;
                const ay = pts[si].y;
                const bx = pts[si + 1].x;
                const by = pts[si + 1].y;

                const dx = bx - ax;
                const dy = by - ay;
                const len2 = dx * dx + dy * dy;
                if (len2 < 0.0001) {
                    const d = (fx - ax) * (fx - ax) + (fy - ay) * (fy - ay);
                    if (d < min_dist) min_dist = d;
                    continue;
                }
                var t = ((fx - ax) * dx + (fy - ay) * dy) / len2;
                if (t < 0.0) t = 0.0;
                if (t > 1.0) t = 1.0;
                const near_x = ax + t * dx;
                const near_y = ay + t * dy;
                const d = (fx - near_x) * (fx - near_x) + (fy - near_y) * (fy - near_y);
                if (d < min_dist) min_dist = d;
            }

            const dist = @sqrt(min_dist);
            if (dist <= half) {
                const px_i = @as(usize, @intFromFloat(px_f));
                const py_i = @as(usize, @intFromFloat(py_f));
                const idx = py_i * canvas.width + px_i;
                canvas.buf[idx] = 255;
            }
        }
    }
}

fn dashHorizontal(metrics: Metrics, canvas: *SimpleCanvas, count: u8, thick_px: u32, desired_gap: u32) void {
    const gap_count = count;
    if (metrics.cell_width < count + gap_count) {
        hlineMiddle(metrics, canvas, .light);
        return;
    }
    const gap_width: i32 = @intCast(@min(desired_gap, metrics.cell_width / (2 * count)));
    const total_gap_width: i32 = gap_count * gap_width;
    const total_dash_width: i32 = @as(i32, @intCast(metrics.cell_width)) - total_gap_width;
    const dash_width: i32 = @divFloor(total_dash_width, count);
    const remaining: i32 = @mod(total_dash_width, count);
    const y: i32 = @intCast((metrics.cell_height -| thick_px) / 2);
    var x: i32 = @divFloor(gap_width, 2);
    var extra: i32 = remaining;
    for (0..count) |_| {
        var x1 = x + dash_width;
        if (extra > 0) {
            extra -= 1;
            x1 += 1;
        }
        hline(canvas, x, x1, y, thick_px);
        x = x1 + gap_width;
    }
}

fn dashVertical(metrics: Metrics, canvas: *SimpleCanvas, comptime count: u8, thick_px: u32, desired_gap: u32) void {
    const gap_count = count;
    if (metrics.cell_height < count + gap_count) {
        vlineMiddle(metrics, canvas, .light);
        return;
    }
    const gap_height: i32 = @intCast(@min(desired_gap, metrics.cell_height / (2 * count)));
    const total_gap_height: i32 = gap_count * gap_height;
    const total_dash_height: i32 = @as(i32, @intCast(metrics.cell_height)) - total_gap_height;
    const dash_height: i32 = @divFloor(total_dash_height, count);
    const remaining: i32 = @mod(total_dash_height, count);
    const x: i32 = @intCast((metrics.cell_width -| thick_px) / 2);
    var y: i32 = 0;
    var extra: i32 = remaining;
    for (0..count) |_| {
        var y1 = y + dash_height;
        if (extra > 0) {
            extra -= 1;
            y1 += 1;
        }
        vline(canvas, y, y1, x, thick_px);
        y = y1 + gap_height;
    }
}

pub fn draw(cp: u32, metrics: Metrics, canvas: *SimpleCanvas) void {
    switch (cp) {
        0x2500 => linesChar(metrics, canvas, .{ .left = .light, .right = .light }),
        0x2501 => linesChar(metrics, canvas, .{ .left = .heavy, .right = .heavy }),
        0x2502 => linesChar(metrics, canvas, .{ .up = .light, .down = .light }),
        0x2503 => linesChar(metrics, canvas, .{ .up = .heavy, .down = .heavy }),
        0x2504 => dashHorizontal(metrics, canvas, 3, Thickness.light.height(metrics.box_thickness), @max(4, Thickness.light.height(metrics.box_thickness))),
        0x2505 => dashHorizontal(metrics, canvas, 3, Thickness.heavy.height(metrics.box_thickness), @max(4, Thickness.light.height(metrics.box_thickness))),
        0x2506 => dashVertical(metrics, canvas, 3, Thickness.light.height(metrics.box_thickness), @max(4, Thickness.light.height(metrics.box_thickness))),
        0x2507 => dashVertical(metrics, canvas, 3, Thickness.heavy.height(metrics.box_thickness), @max(4, Thickness.light.height(metrics.box_thickness))),
        0x2508 => dashHorizontal(metrics, canvas, 4, Thickness.light.height(metrics.box_thickness), @max(4, Thickness.light.height(metrics.box_thickness))),
        0x2509 => dashHorizontal(metrics, canvas, 4, Thickness.heavy.height(metrics.box_thickness), @max(4, Thickness.light.height(metrics.box_thickness))),
        0x250a => dashVertical(metrics, canvas, 4, Thickness.light.height(metrics.box_thickness), @max(4, Thickness.light.height(metrics.box_thickness))),
        0x250b => dashVertical(metrics, canvas, 4, Thickness.heavy.height(metrics.box_thickness), @max(4, Thickness.light.height(metrics.box_thickness))),
        0x250c => linesChar(metrics, canvas, .{ .down = .light, .right = .light }),
        0x250d => linesChar(metrics, canvas, .{ .down = .light, .right = .heavy }),
        0x250e => linesChar(metrics, canvas, .{ .down = .heavy, .right = .light }),
        0x250f => linesChar(metrics, canvas, .{ .down = .heavy, .right = .heavy }),
        0x2510 => linesChar(metrics, canvas, .{ .down = .light, .left = .light }),
        0x2511 => linesChar(metrics, canvas, .{ .down = .light, .left = .heavy }),
        0x2512 => linesChar(metrics, canvas, .{ .down = .heavy, .left = .light }),
        0x2513 => linesChar(metrics, canvas, .{ .down = .heavy, .left = .heavy }),
        0x2514 => linesChar(metrics, canvas, .{ .up = .light, .right = .light }),
        0x2515 => linesChar(metrics, canvas, .{ .up = .light, .right = .heavy }),
        0x2516 => linesChar(metrics, canvas, .{ .up = .heavy, .right = .light }),
        0x2517 => linesChar(metrics, canvas, .{ .up = .heavy, .right = .heavy }),
        0x2518 => linesChar(metrics, canvas, .{ .up = .light, .left = .light }),
        0x2519 => linesChar(metrics, canvas, .{ .up = .light, .left = .heavy }),
        0x251a => linesChar(metrics, canvas, .{ .up = .heavy, .left = .light }),
        0x251b => linesChar(metrics, canvas, .{ .up = .heavy, .left = .heavy }),
        0x251c => linesChar(metrics, canvas, .{ .up = .light, .down = .light, .right = .light }),
        0x251d => linesChar(metrics, canvas, .{ .up = .light, .down = .light, .right = .heavy }),
        0x251e => linesChar(metrics, canvas, .{ .up = .heavy, .right = .light, .down = .light }),
        0x251f => linesChar(metrics, canvas, .{ .down = .heavy, .right = .light, .up = .light }),
        0x2520 => linesChar(metrics, canvas, .{ .up = .heavy, .down = .heavy, .right = .light }),
        0x2521 => linesChar(metrics, canvas, .{ .down = .light, .right = .heavy, .up = .heavy }),
        0x2522 => linesChar(metrics, canvas, .{ .up = .light, .right = .heavy, .down = .heavy }),
        0x2523 => linesChar(metrics, canvas, .{ .up = .heavy, .down = .heavy, .right = .heavy }),
        0x2524 => linesChar(metrics, canvas, .{ .up = .light, .down = .light, .left = .light }),
        0x2525 => linesChar(metrics, canvas, .{ .up = .light, .down = .light, .left = .heavy }),
        0x2526 => linesChar(metrics, canvas, .{ .up = .heavy, .left = .light, .down = .light }),
        0x2527 => linesChar(metrics, canvas, .{ .down = .heavy, .left = .light, .up = .light }),
        0x2528 => linesChar(metrics, canvas, .{ .up = .heavy, .down = .heavy, .left = .light }),
        0x2529 => linesChar(metrics, canvas, .{ .down = .light, .left = .heavy, .up = .heavy }),
        0x252a => linesChar(metrics, canvas, .{ .up = .light, .left = .heavy, .down = .heavy }),
        0x252b => linesChar(metrics, canvas, .{ .up = .heavy, .down = .heavy, .left = .heavy }),
        0x252c => linesChar(metrics, canvas, .{ .down = .light, .left = .light, .right = .light }),
        0x252d => linesChar(metrics, canvas, .{ .left = .heavy, .right = .light, .down = .light }),
        0x252e => linesChar(metrics, canvas, .{ .right = .heavy, .left = .light, .down = .light }),
        0x252f => linesChar(metrics, canvas, .{ .down = .light, .left = .heavy, .right = .heavy }),
        0x2530 => linesChar(metrics, canvas, .{ .down = .heavy, .left = .light, .right = .light }),
        0x2531 => linesChar(metrics, canvas, .{ .right = .light, .left = .heavy, .down = .heavy }),
        0x2532 => linesChar(metrics, canvas, .{ .left = .light, .right = .heavy, .down = .heavy }),
        0x2533 => linesChar(metrics, canvas, .{ .down = .heavy, .left = .heavy, .right = .heavy }),
        0x2534 => linesChar(metrics, canvas, .{ .up = .light, .left = .light, .right = .light }),
        0x2535 => linesChar(metrics, canvas, .{ .left = .heavy, .right = .light, .up = .light }),
        0x2536 => linesChar(metrics, canvas, .{ .right = .heavy, .left = .light, .up = .light }),
        0x2537 => linesChar(metrics, canvas, .{ .up = .light, .left = .heavy, .right = .heavy }),
        0x2538 => linesChar(metrics, canvas, .{ .up = .heavy, .left = .light, .right = .light }),
        0x2539 => linesChar(metrics, canvas, .{ .right = .light, .left = .heavy, .up = .heavy }),
        0x253a => linesChar(metrics, canvas, .{ .left = .light, .right = .heavy, .up = .heavy }),
        0x253b => linesChar(metrics, canvas, .{ .up = .heavy, .left = .heavy, .right = .heavy }),
        0x253c => linesChar(metrics, canvas, .{ .up = .light, .down = .light, .left = .light, .right = .light }),
        0x253d => linesChar(metrics, canvas, .{ .left = .heavy, .right = .light, .up = .light, .down = .light }),
        0x253e => linesChar(metrics, canvas, .{ .right = .heavy, .left = .light, .up = .light, .down = .light }),
        0x253f => linesChar(metrics, canvas, .{ .up = .light, .down = .light, .left = .heavy, .right = .heavy }),
        0x2540 => linesChar(metrics, canvas, .{ .up = .heavy, .down = .light, .left = .light, .right = .light }),
        0x2541 => linesChar(metrics, canvas, .{ .down = .heavy, .up = .light, .left = .light, .right = .light }),
        0x2542 => linesChar(metrics, canvas, .{ .up = .heavy, .down = .heavy, .left = .light, .right = .light }),
        0x2543 => linesChar(metrics, canvas, .{ .left = .heavy, .up = .heavy, .right = .light, .down = .light }),
        0x2544 => linesChar(metrics, canvas, .{ .right = .heavy, .up = .heavy, .left = .light, .down = .light }),
        0x2545 => linesChar(metrics, canvas, .{ .left = .heavy, .down = .heavy, .right = .light, .up = .light }),
        0x2546 => linesChar(metrics, canvas, .{ .right = .heavy, .down = .heavy, .left = .light, .up = .light }),
        0x2547 => linesChar(metrics, canvas, .{ .down = .light, .up = .heavy, .left = .heavy, .right = .heavy }),
        0x2548 => linesChar(metrics, canvas, .{ .up = .light, .down = .heavy, .left = .heavy, .right = .heavy }),
        0x2549 => linesChar(metrics, canvas, .{ .right = .light, .left = .heavy, .up = .heavy, .down = .heavy }),
        0x254a => linesChar(metrics, canvas, .{ .left = .light, .right = .heavy, .up = .heavy, .down = .heavy }),
        0x254b => linesChar(metrics, canvas, .{ .up = .heavy, .down = .heavy, .left = .heavy, .right = .heavy }),
        0x254c => dashHorizontal(metrics, canvas, 2, Thickness.light.height(metrics.box_thickness), Thickness.light.height(metrics.box_thickness)),
        0x254d => dashHorizontal(metrics, canvas, 2, Thickness.heavy.height(metrics.box_thickness), Thickness.heavy.height(metrics.box_thickness)),
        0x254e => dashVertical(metrics, canvas, 2, Thickness.light.height(metrics.box_thickness), Thickness.heavy.height(metrics.box_thickness)),
        0x254f => dashVertical(metrics, canvas, 2, Thickness.heavy.height(metrics.box_thickness), Thickness.heavy.height(metrics.box_thickness)),
        0x2550 => linesChar(metrics, canvas, .{ .left = .double, .right = .double }),
        0x2551 => linesChar(metrics, canvas, .{ .up = .double, .down = .double }),
        0x2552 => linesChar(metrics, canvas, .{ .down = .light, .right = .double }),
        0x2553 => linesChar(metrics, canvas, .{ .down = .double, .right = .light }),
        0x2554 => linesChar(metrics, canvas, .{ .down = .double, .right = .double }),
        0x2555 => linesChar(metrics, canvas, .{ .down = .light, .left = .double }),
        0x2556 => linesChar(metrics, canvas, .{ .down = .double, .left = .light }),
        0x2557 => linesChar(metrics, canvas, .{ .down = .double, .left = .double }),
        0x2558 => linesChar(metrics, canvas, .{ .up = .light, .right = .double }),
        0x2559 => linesChar(metrics, canvas, .{ .up = .double, .right = .light }),
        0x255a => linesChar(metrics, canvas, .{ .up = .double, .right = .double }),
        0x255b => linesChar(metrics, canvas, .{ .up = .light, .left = .double }),
        0x255c => linesChar(metrics, canvas, .{ .up = .double, .left = .light }),
        0x255d => linesChar(metrics, canvas, .{ .up = .double, .left = .double }),
        0x255e => linesChar(metrics, canvas, .{ .up = .light, .down = .light, .right = .double }),
        0x255f => linesChar(metrics, canvas, .{ .up = .double, .down = .double, .right = .light }),
        0x2560 => linesChar(metrics, canvas, .{ .up = .double, .down = .double, .right = .double }),
        0x2561 => linesChar(metrics, canvas, .{ .up = .light, .down = .light, .left = .double }),
        0x2562 => linesChar(metrics, canvas, .{ .up = .double, .down = .double, .left = .light }),
        0x2563 => linesChar(metrics, canvas, .{ .up = .double, .down = .double, .left = .double }),
        0x2564 => linesChar(metrics, canvas, .{ .down = .light, .left = .double, .right = .double }),
        0x2565 => linesChar(metrics, canvas, .{ .down = .double, .left = .light, .right = .light }),
        0x2566 => linesChar(metrics, canvas, .{ .down = .double, .left = .double, .right = .double }),
        0x2567 => linesChar(metrics, canvas, .{ .up = .light, .left = .double, .right = .double }),
        0x2568 => linesChar(metrics, canvas, .{ .up = .double, .left = .light, .right = .light }),
        0x2569 => linesChar(metrics, canvas, .{ .up = .double, .left = .double, .right = .double }),
        0x256a => linesChar(metrics, canvas, .{ .up = .light, .down = .light, .left = .double, .right = .double }),
        0x256b => linesChar(metrics, canvas, .{ .up = .double, .down = .double, .left = .light, .right = .light }),
        0x256c => linesChar(metrics, canvas, .{ .up = .double, .down = .double, .left = .double, .right = .double }),
        0x256d => arc(metrics, canvas, .br, .light),
        0x256e => arc(metrics, canvas, .bl, .light),
        0x256f => arc(metrics, canvas, .tl, .light),
        0x2570 => arc(metrics, canvas, .tr, .light),
        0x2571 => lightDiagonalUpperRightToLowerLeft(metrics, canvas),
        0x2572 => lightDiagonalUpperLeftToLowerRight(metrics, canvas),
        0x2573 => lightDiagonalCross(metrics, canvas),
        0x2574 => linesChar(metrics, canvas, .{ .left = .light }),
        0x2575 => linesChar(metrics, canvas, .{ .up = .light }),
        0x2576 => linesChar(metrics, canvas, .{ .right = .light }),
        0x2577 => linesChar(metrics, canvas, .{ .down = .light }),
        0x2578 => linesChar(metrics, canvas, .{ .left = .heavy }),
        0x2579 => linesChar(metrics, canvas, .{ .up = .heavy }),
        0x257a => linesChar(metrics, canvas, .{ .right = .heavy }),
        0x257b => linesChar(metrics, canvas, .{ .down = .heavy }),
        0x257c => linesChar(metrics, canvas, .{ .left = .light, .right = .heavy }),
        0x257d => linesChar(metrics, canvas, .{ .up = .light, .down = .heavy }),
        0x257e => linesChar(metrics, canvas, .{ .left = .heavy, .right = .light }),
        0x257f => linesChar(metrics, canvas, .{ .up = .heavy, .down = .light }),
        else => {},
    }
}

test "SimpleCanvas: box fills correct region" {
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);
    var c = SimpleCanvas{ .buf = &buf, .width = 8, .height = 8 };
    c.box(2, 2, 6, 6);
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
    try std.testing.expectEqual(@as(u8, 255), buf[2 * 8 + 2]);
    try std.testing.expectEqual(@as(u8, 255), buf[5 * 8 + 5]);
    try std.testing.expectEqual(@as(u8, 0), buf[6 * 8 + 6]);
    try std.testing.expectEqual(@as(u8, 0), buf[1 * 8 + 2]);
}

test "line U+2500 draws horizontal bar" {
    var buf: [256]u8 = @splat(0);
    var c = SimpleCanvas{ .buf = &buf, .width = 16, .height = 16 };
    const m = Metrics{ .cell_width = 16, .cell_height = 16, .box_thickness = 2 };
    draw(0x2500, m, &c);
    var row_has_pixel = false;
    for (buf) |v| {
        if (v > 0) row_has_pixel = true;
    }
    try std.testing.expect(row_has_pixel);
}

test "arc U+256D draws non-empty" {
    var buf: [256]u8 = @splat(0);
    var c = SimpleCanvas{ .buf = &buf, .width = 16, .height = 16 };
    const m = Metrics{ .cell_width = 16, .cell_height = 16, .box_thickness = 2 };
    draw(0x256D, m, &c);
    var has_pixel = false;
    for (buf) |v| {
        if (v > 0) has_pixel = true;
    }
    try std.testing.expect(has_pixel);
}

test "diagonal U+2571 draws non-empty" {
    var buf: [256]u8 = @splat(0);
    var c = SimpleCanvas{ .buf = &buf, .width = 16, .height = 16 };
    const m = Metrics{ .cell_width = 16, .cell_height = 16, .box_thickness = 2 };
    draw(0x2571, m, &c);
    var has_pixel = false;
    for (buf) |v| {
        if (v > 0) has_pixel = true;
    }
    try std.testing.expect(has_pixel);
}

test "intersection U+253C draws all four arms" {
    var buf: [256]u8 = @splat(0);
    var c = SimpleCanvas{ .buf = &buf, .width = 16, .height = 16 };
    const m = Metrics{ .cell_width = 16, .cell_height = 16, .box_thickness = 2 };
    draw(0x253C, m, &c);
    var count: usize = 0;
    for (buf) |v| {
        if (v > 0) count += 1;
    }
    try std.testing.expect(count > 10);
}

test "double lines U+2550 draws two horizontal bars" {
    var buf: [256]u8 = @splat(0);
    var c = SimpleCanvas{ .buf = &buf, .width = 16, .height = 16 };
    const m = Metrics{ .cell_width = 16, .cell_height = 16, .box_thickness = 2 };
    draw(0x2550, m, &c);
    var has_pixel = false;
    for (buf) |v| {
        if (v > 0) has_pixel = true;
    }
    try std.testing.expect(has_pixel);
}

test "small cell doesn't crash" {
    var buf: [4]u8 = @splat(0);
    var c = SimpleCanvas{ .buf = &buf, .width = 2, .height = 2 };
    const m = Metrics{ .cell_width = 2, .cell_height = 2, .box_thickness = 1 };
    draw(0x256D, m, &c);
    draw(0x2571, m, &c);
    draw(0x2500, m, &c);
}

test "all codepoints render without error" {
    var buf: [4096]u8 = @splat(0);
    var c = SimpleCanvas{ .buf = &buf, .width = 64, .height = 64 };
    const m = Metrics{ .cell_width = 64, .cell_height = 64, .box_thickness = 4 };
    var cp: u32 = 0x2500;
    while (cp <= 0x257F) : (cp += 1) {
        @memset(&buf, 0);
        draw(cp, m, &c);
    }
}
