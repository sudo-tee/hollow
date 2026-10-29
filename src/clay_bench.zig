//! Headless native Clay layout cost, not Lua parsing or rendering/frame time.
const std = @import("std");
const io = @import("io.zig");
const c = @import("clay_c");

fn node(kind: c_int, width: f32, height: f32, children: c_int) c.HollowClayNode {
    var result = std.mem.zeroes(c.HollowClayNode);
    result.kind = kind;
    result.width = width;
    result.height = height;
    result.children = children;
    return result;
}

const Fixture = struct {
    // A framed panel, header/footer, and 23 two-column clipped workspace rows.
    nodes: [5 + 23 * 7]c.HollowClayNode = undefined,
    ids: [23][32]u8 = undefined,
    names: [23][32]u8 = undefined,

    fn init(self: *Fixture) !void {
        self.nodes[0] = node(0, 0, 0, 1);
        self.nodes[0].padding = .{ .left = 12, .right = 12, .top = 19, .bottom = 9 };
        self.nodes[1] = node(0, -1, -1, 3);
        self.nodes[2] = node(2, 0, 0, 0);
        self.nodes[2].text = .{ .chars = "Workspaces", .length = 10, .isStaticallyAllocated = true };
        self.nodes[3] = node(0, -1, -1, 23);
        self.nodes[3].scroll = true;
        self.nodes[3].scroll_x = true;
        self.nodes[3].padding.right = 8;
        for (0..23) |row| {
            const base = 4 + row * 7;
            const id = try std.fmt.bufPrint(&self.ids[row], "workspace:{d}", .{row});
            const name = try std.fmt.bufPrint(&self.names[row], "Workspace {d}", .{row});
            self.nodes[base] = node(1, -1, 23, 4);
            self.nodes[base].id = .{ .chars = id.ptr, .length = @intCast(id.len), .isStaticallyAllocated = false };
            self.nodes[base].clickable = true;
            self.nodes[base + 1] = node(1, 192, 19, 1);
            self.nodes[base + 1].scroll_x = true;
            self.nodes[base + 2] = node(2, 0, 0, 0);
            self.nodes[base + 2].text = .{ .chars = name.ptr, .length = @intCast(name.len), .isStaticallyAllocated = false };
            self.nodes[base + 2].wrap = 2;
            self.nodes[base + 3] = node(0, 16, 19, 0);
            self.nodes[base + 4] = node(1, -1, 19, 1);
            self.nodes[base + 4].scroll_x = true;
            self.nodes[base + 5] = node(2, 0, 0, 0);
            const cwd = "/srv/projects/a-workspace-with-a-long-path";
            self.nodes[base + 5].text = .{ .chars = cwd, .length = cwd.len, .isStaticallyAllocated = true };
            self.nodes[base + 5].wrap = 2;
            // Fourth direct child is an unpainted status slot.
            self.nodes[base + 6] = node(0, 16, 19, 0);
        }
        self.nodes[self.nodes.len - 1] = node(2, 0, 0, 0);
        self.nodes[self.nodes.len - 1].text = .{ .chars = "Enter switch", .length = 12, .isStaticallyAllocated = true };
    }

    fn step(self: *Fixture, surface: *c.HollowClay, scenario: enum { idle, reveal, resize }, index: usize) !usize {
        const width: f32 = if (scenario == .resize and index % 2 == 0) 720 else 1200;
        self.nodes[3].reveal = if (scenario == .reveal) self.nodes[4 + (if (index % 2 == 0) @as(usize, 0) else 22) * 7].id else std.mem.zeroes(c.Clay_String);
        const commands = c.hollow_clay_layout(surface, &self.nodes, @intCast(self.nodes.len), width, 900, 8, 19, -1, -1, 0, 1.0 / 60.0);
        if (c.hollow_clay_failed(surface)) return error.LayoutFailed;
        return @intCast(commands.length);
    }
};

pub fn main(init: std.process.Init) !void {
    io.init(init.io, init.minimal.environ);
    var args = init.minimal.args.iterate();
    _ = args.next();
    const iterations = if (args.next()) |text| try std.fmt.parseInt(usize, text, 10) else 2000;
    if (iterations == 0) return error.InvalidIterations;
    inline for (.{ .idle, .reveal, .resize }) |scenario| {
        const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
        defer c.hollow_clay_destroy(surface);
        c.hollow_clay_frame(surface, .{ .enabled = true, .width = 768, .height = 485, .margin = .{ .left = 8, .right = 8, .top = 19, .bottom = 19 }, .align_x = 1, .align_y = 0 });
        var fixture: Fixture = .{};
        try fixture.init();
        for (0..200) |i| _ = try fixture.step(surface, scenario, i);
        var samples: [7]f64 = undefined;
        var command_count: usize = 0;
        for (&samples) |*sample| {
            const start = io.nanoTimestamp();
            for (0..iterations) |i| command_count = try fixture.step(surface, scenario, i);
            sample.* = @as(f64, @floatFromInt(io.nanoTimestamp() - start)) / @as(f64, @floatFromInt(iterations)) / 1000;
        }
        std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
        const json = try std.json.Stringify.valueAlloc(init.gpa, .{
            .scenario = @tagName(scenario),
            .iterations = iterations,
            .median_us_per_layout = samples[3],
            .nodes = fixture.nodes.len,
            .render_commands = command_count,
            .clay_min_arena_bytes = c.Clay_MinMemorySize(),
        }, .{});
        defer init.gpa.free(json);
        try std.Io.File.stdout().writeStreamingAll(init.io, json);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    }
}
