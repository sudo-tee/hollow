//! Clay geometry for native surfaces. Painting, ellipsis and event semantics
//! stay with the renderer; no second layout algorithm or Lua snapshot required.
const std = @import("std");
const c = @import("clay_c");

pub const Box = c.Clay_BoundingBox;
pub const Axis = c.Clay_SizingAxis;

pub fn fixed(value: f32) Axis {
    return .{ .type = c.CLAY__SIZING_TYPE_FIXED, .size = .{ .minMax = .{ .min = @max(0, value), .max = @max(0, value) } } };
}

pub fn grow(max: f32) Axis {
    return .{ .type = c.CLAY__SIZING_TYPE_GROW, .size = .{ .minMax = .{ .min = 0, .max = max } } };
}

pub fn fit() Axis {
    return .{ .type = c.CLAY__SIZING_TYPE_FIT };
}

pub fn edge(value: f32) u16 {
    return @intFromFloat(std.math.clamp(@round(value), 0, std.math.maxInt(u16)));
}

pub const Surface = struct {
    memory: ?[]u8 = null,
    context: ?*c.Clay_Context = null,
    previous: ?*c.Clay_Context = null,
    failed: bool = false,

    pub fn deinit(self: *Surface) void {
        if (c.Clay_GetCurrentContext() == self.context) c.Clay_SetCurrentContext(null);
        if (self.memory) |memory| std.heap.page_allocator.free(memory);
        self.* = .{};
    }

    fn onError(data: c.Clay_ErrorData) callconv(.c) void {
        const self: *Surface = @ptrCast(@alignCast(data.userData orelse return));
        self.failed = true;
        std.log.err("native Clay layout: {s}", .{data.errorText.chars[0..@intCast(data.errorText.length)]});
    }

    pub fn begin(self: *Surface, width: f32, height: f32) bool {
        self.previous = c.Clay_GetCurrentContext();
        if (self.context == null) {
            // Never inherit the inspector's much larger element budget.
            c.Clay_SetCurrentContext(null);
            c.Clay_SetMaxElementCount(2048);
            c.Clay_SetMaxMeasureTextCacheWordCount(4096);
            const memory = std.heap.page_allocator.alloc(u8, c.Clay_MinMemorySize()) catch {
                c.Clay_SetCurrentContext(self.previous);
                return false;
            };
            self.memory = memory;
            self.context = c.Clay_Initialize(c.Clay_CreateArenaWithCapacityAndMemory(memory.len, memory.ptr), .{ .width = width, .height = height }, .{ .errorHandlerFunction = onError, .userData = self });
            if (self.context == null) {
                const previous = self.previous;
                self.deinit();
                c.Clay_SetCurrentContext(previous);
                return false;
            }
        }
        c.Clay_SetCurrentContext(self.context);
        self.failed = false;
        c.Clay_SetLayoutDimensions(.{ .width = @max(0, width), .height = @max(0, height) });
        c.Clay_SetPointerState(.{ .x = -1, .y = -1 }, false);
        c.Clay_BeginLayout();
        return true;
    }

    pub fn open(index: u32, layout: c.Clay_LayoutConfig) void {
        c.Clay__OpenElementWithId(id(index));
        c.Clay__ConfigureOpenElement(.{ .layout = layout });
    }

    pub fn close() void {
        c.Clay__CloseElement();
    }

    /// A shrinkable preferred width. The unpainted fixed child supplies Clay's
    /// intrinsic size; horizontal clipping lets its parent shrink below that
    /// size. The renderer fits text into the resulting parent bounds.
    pub fn preferred(index: u32, layout: c.Clay_LayoutConfig, width: f32) void {
        c.Clay__OpenElementWithId(id(index));
        c.Clay__ConfigureOpenElement(.{ .layout = layout, .clip = .{ .horizontal = true } });
        open(index + 10000, .{ .sizing = .{ .width = fixed(width), .height = fixed(0) } });
        close();
        close();
    }

    pub fn end(self: *Surface) bool {
        _ = c.Clay_EndLayout(0);
        c.Clay_SetCurrentContext(self.previous);
        return !self.failed;
    }

    fn id(index: u32) c.Clay_ElementId {
        return c.Clay_GetElementIdWithIndex(.{ .chars = "native", .length = 6, .isStaticallyAllocated = true }, index);
    }

    pub fn bounds(self: *Surface, index: u32) Box {
        const previous = c.Clay_GetCurrentContext();
        defer c.Clay_SetCurrentContext(previous);
        c.Clay_SetCurrentContext(self.context);
        const data = c.Clay_GetElementData(id(index));
        return if (data.found) data.boundingBox else std.mem.zeroes(Box);
    }
};

test "native Clay row distributes grow space and caps tabs" {
    var surface = Surface{};
    defer surface.deinit();
    try std.testing.expect(surface.begin(400, 30));
    Surface.open(0, .{ .sizing = .{ .width = fixed(400), .height = fixed(30) }, .layoutDirection = c.CLAY_LEFT_TO_RIGHT });
    Surface.open(1, .{ .sizing = .{ .width = grow(80), .height = fixed(30) } });
    Surface.close();
    Surface.open(2, .{ .sizing = .{ .width = grow(0), .height = fixed(30) } });
    Surface.close();
    Surface.open(3, .{ .sizing = .{ .width = fixed(40), .height = fixed(30) } });
    Surface.close();
    Surface.close();
    try std.testing.expect(surface.end());
    try std.testing.expectEqual(@as(f32, 80), surface.bounds(1).width);
    try std.testing.expectEqual(@as(f32, 360), surface.bounds(3).x);
}

test "native preferred widths shrink without moving fixed right items" {
    var surface = Surface{};
    defer surface.deinit();
    try std.testing.expect(surface.begin(100, 30));
    Surface.open(0, .{ .sizing = .{ .width = fixed(100), .height = fixed(30) }, .layoutDirection = c.CLAY_LEFT_TO_RIGHT });
    Surface.preferred(1, .{ .sizing = .{ .width = fit(), .height = fixed(20) } }, 200);
    Surface.open(2, .{ .sizing = .{ .width = grow(0), .height = fixed(0) } });
    Surface.close();
    Surface.open(3, .{ .sizing = .{ .width = fixed(40), .height = fixed(20) } });
    Surface.close();
    Surface.close();
    try std.testing.expect(surface.end());
    try std.testing.expectApproxEqAbs(@as(f32, 60), surface.bounds(1).width, 0.02);
    try std.testing.expectApproxEqAbs(@as(f32, 60), surface.bounds(3).x, 0.02);
}

test "native column uses fixed row heights and centered child alignment" {
    var surface = Surface{};
    defer surface.deinit();
    try std.testing.expect(surface.begin(100, 100));
    Surface.open(0, .{
        .sizing = .{ .width = fixed(100), .height = fixed(100) },
        .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
        .childAlignment = .{ .x = c.CLAY_ALIGN_X_CENTER },
        .padding = .{ .top = 10 },
    });
    for (1..4) |i| {
        Surface.open(@intCast(i), .{ .sizing = .{ .width = fixed(40), .height = fixed(20) } });
        Surface.close();
    }
    Surface.close();
    try std.testing.expect(surface.end());
    try std.testing.expectEqual(@as(f32, 30), surface.bounds(1).x);
    try std.testing.expectEqual(@as(f32, 50), surface.bounds(3).y);
}
