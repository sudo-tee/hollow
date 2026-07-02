const std = @import("std");
const FrameSnapshot = @import("../render/debug_backend.zig").FrameSnapshot;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const text_helpers = @import("text_helpers.zig");

pub fn captureSnapshot(self: *App) ?FrameSnapshot {
    if (self.renderer) |*renderer| {
        if (self.ghostty) |*runtime| {
            if (self.activePane()) |pane| {
                if (!App.paneRenderHelpersReady(pane)) return null;
                return renderer.fillSnapshot(runtime, pane.render_state, &pane.row_iterator, &pane.row_cells, self.config, pane.title);
            }
        }
    }
    return null;
}

pub fn dumpSnapshot(self: *App, frame_index: usize, render_mode: []const u8) void {
    const file = if (self.snapshot_dump_file) |*f| f else return;
    const snapshot = captureSnapshot(self) orelse return;
    const hash = text_helpers.snapshotHash(&snapshot, render_mode);
    if (self.snapshot_dump_has_last_hash and self.snapshot_dump_last_hash == hash) return;
    self.snapshot_dump_last_hash = hash;
    self.snapshot_dump_has_last_hash = true;

    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    writer.interface.print(
        "=== frame={d} mode={s} dirty={s} rows={d} cols={d} visible={d} title={s} hash={x} ===\n",
        .{ frame_index, render_mode, @tagName(snapshot.dirty), snapshot.rows, snapshot.cols, snapshot.visible_line_count, snapshot.title, hash },
    ) catch return;

    var line_idx: usize = 0;
    while (line_idx < snapshot.visible_line_count and line_idx < snapshot.lines.len) : (line_idx += 1) {
        const line = snapshot.lines[line_idx][0..snapshot.line_lens[line_idx]];
        writer.interface.print("{d:0>3}: {s}\n", .{ line_idx, line }) catch return;
    }
    writer.interface.writeAll("\n") catch return;
    writer.interface.flush() catch {};
}
