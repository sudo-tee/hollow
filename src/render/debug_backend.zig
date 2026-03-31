const std = @import("std");
const Config = @import("../config.zig").Config;
const ghostty = @import("../term/ghostty.zig");

pub const MAX_ROWS = 64;
pub const MAX_COLS = 256;

pub const FrameSnapshot = struct {
    rows: u16,
    cols: u16,
    title: []const u8,
    shell: []const u8,
    dirty: ghostty.RenderStateDirty = .false_value,
    lines: [MAX_ROWS][MAX_COLS]u8 = [_][MAX_COLS]u8{[_]u8{0} ** MAX_COLS} ** MAX_ROWS,
    line_lens: [MAX_ROWS]usize = [_]usize{0} ** MAX_ROWS,
    visible_line_count: usize = 0,
};

pub const DebugBackend = struct {
    allocator: std.mem.Allocator,
    requested: []const u8,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) DebugBackend {
        return .{
            .allocator = allocator,
            .requested = cfg.backend.asString(),
        };
    }

    pub fn deinit(self: *DebugBackend) void {
        _ = self;
    }

    pub fn activeName(self: DebugBackend) []const u8 {
        _ = self;
        return "sokol-debug";
    }

    pub fn requestedName(self: DebugBackend) []const u8 {
        return self.requested;
    }

    pub fn fillSnapshot(self: *DebugBackend, runtime: *ghostty.Runtime, render_state: ?*anyopaque, row_iterator: *?*anyopaque, row_cells: *?*anyopaque, cfg: Config, title: []const u8) FrameSnapshot {
        _ = self;
        var snapshot = FrameSnapshot{
            .rows = cfg.rows,
            .cols = cfg.cols,
            .title = title,
            .shell = cfg.shellOrDefault(),
        };
        snapshot.dirty = runtime.getRenderStateDirty(render_state) orelse .false_value;

        if (!runtime.populateRowIterator(render_state, row_iterator)) return snapshot;

        var line_index: usize = 0;
        while (line_index < MAX_ROWS and runtime.nextRow(row_iterator.*)) : (line_index += 1) {
            if (!runtime.populateRowCells(row_iterator.*, row_cells)) break;

            var out_index: usize = 0;
            while (runtime.nextCell(row_cells.*) and out_index < MAX_COLS) {
                const grapheme_len = runtime.cellGraphemeLen(row_cells.*);
                if (grapheme_len == 0) {
                    snapshot.lines[line_index][out_index] = ' ';
                    out_index += 1;
                    continue;
                }

                var cps: [16]u32 = [_]u32{0} ** 16;
                runtime.cellGraphemes(row_cells.*, &cps);
                const cp = cps[0];
                snapshot.lines[line_index][out_index] = codepointToAscii(cp);
                out_index += 1;
            }

            snapshot.line_lens[line_index] = std.mem.trimRight(u8, snapshot.lines[line_index][0..out_index], " ").len;
            snapshot.visible_line_count = line_index + 1;
        }
        return snapshot;
    }
};

fn codepointToAscii(cp: u32) u8 {
    if (cp >= 32 and cp <= 126) return @intCast(cp);
    return '.';
}
