const std = @import("std");
const Config = @import("config.zig").Config;
const GhosttyRuntime = @import("term/ghostty.zig").Runtime;
const ghostty = @import("term/ghostty.zig");
const Pty = @import("pty/pty.zig").Pty;
const platform = @import("platform.zig");

pub const Pane = struct {
    allocator: std.mem.Allocator,
    pty: ?Pty = null,
    terminal: ?*anyopaque = null,
    render_state: ?*anyopaque = null,
    row_iterator: ?*anyopaque = null,
    row_cells: ?*anyopaque = null,
    key_encoder: ?*anyopaque = null,
    key_event: ?*anyopaque = null,
    mouse_encoder: ?*anyopaque = null,
    mouse_event: ?*anyopaque = null,
    title: []u8 = &.{},
    /// Set to true after the first updateRenderState call so the renderer
    /// can skip rendering panes whose ghostty state is not yet initialized.
    render_state_ready: bool = false,
    read_buf: [65536]u8 = [_]u8{0} ** 65536,
    logged_first_pty_read: bool = false,
    pty_pending_seq: [8]u8 = [_]u8{0} ** 8,
    pty_pending_len: usize = 0,
    pty_sanitize_buf: [65544]u8 = [_]u8{0} ** 65544,

    pub fn init(allocator: std.mem.Allocator) Pane {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Pane, runtime: *GhosttyRuntime) void {
        runtime.freeMouseEvent(self.mouse_event);
        runtime.freeMouseEncoder(self.mouse_encoder);
        runtime.freeKeyEvent(self.key_event);
        runtime.freeKeyEncoder(self.key_encoder);
        runtime.freeRowCells(self.row_cells);
        runtime.freeRowIterator(self.row_iterator);
        runtime.freeRenderState(self.render_state);
        runtime.freeTerminal(self.terminal);
        if (self.pty) |*pty| pty.deinit();
        if (self.title.len > 0) self.allocator.free(self.title);
        self.* = Pane.init(self.allocator);
    }

    pub fn bootstrap(self: *Pane, runtime: *GhosttyRuntime, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32) !void {
        const terminal = try runtime.createTerminal(.{
            .cols = cfg.cols,
            .rows = cfg.rows,
            .max_scrollback = cfg.scrollback,
        });
        errdefer runtime.freeTerminal(terminal);

        const render_state = try runtime.createRenderState();
        errdefer runtime.freeRenderState(render_state);

        const row_iterator = try runtime.createRowIterator();
        errdefer runtime.freeRowIterator(row_iterator);

        const row_cells = try runtime.createRowCells();
        errdefer runtime.freeRowCells(row_cells);

        const key_encoder = try runtime.createKeyEncoder();
        errdefer runtime.freeKeyEncoder(key_encoder);

        const key_event = try runtime.createKeyEvent();
        errdefer runtime.freeKeyEvent(key_event);

        const mouse_encoder = try runtime.createMouseEncoder();
        errdefer runtime.freeMouseEncoder(mouse_encoder);

        const mouse_event = try runtime.createMouseEvent();
        errdefer runtime.freeMouseEvent(mouse_event);

        const shell = try self.allocator.dupeZ(u8, cfg.shellOrDefault());
        defer self.allocator.free(shell);
        var pty = try @import("pty/pty.zig").spawn(self.allocator, shell, cfg.cols, cfg.rows);
        errdefer pty.deinit();

        self.terminal = terminal;
        self.render_state = render_state;
        self.row_iterator = row_iterator;
        self.row_cells = row_cells;
        self.key_encoder = key_encoder;
        self.key_event = key_event;
        self.mouse_encoder = mouse_encoder;
        self.mouse_event = mouse_event;
        self.pty = pty;

        runtime.syncKeyEncoder(self.key_encoder, self.terminal);
        runtime.syncMouseEncoder(self.mouse_encoder, self.terminal);
        self.setMouseSize(runtime, window_width, window_height, cell_width_px, cell_height_px);
        self.resize(runtime, cfg.cols, cfg.rows, cell_width_px, cell_height_px);
        self.refreshTitle(runtime, cfg.windowTitle());
    }

    pub fn pollPty(self: *Pane, runtime: *GhosttyRuntime) !void {
        if (self.pty) |*pty| {
            var total_read: usize = 0;
            var read_loops: usize = 0;
            while ((pty.isAlive() or pty.hasPendingOutput()) and read_loops < 64 and total_read < (1024 * 1024)) {
                const count = try pty.read(&self.read_buf);
                if (count == 0) break;
                read_loops += 1;
                total_read += count;
                if (count > 0) {
                    if (!self.logged_first_pty_read) {
                        self.logged_first_pty_read = true;
                        std.log.info("first PTY bytes received count={d}", .{count});
                    }
                    const pty_bytes = self.sanitizePtyOutput(self.read_buf[0..count]);
                    if (pty_bytes.len > 0) runtime.terminalWrite(self.terminal, pty_bytes);
                }
            }
            runtime.syncKeyEncoder(self.key_encoder, self.terminal);
            runtime.syncMouseEncoder(self.mouse_encoder, self.terminal);
        }
    }

    pub fn sendText(self: *Pane, text: []const u8) !void {
        if (self.pty) |*pty| try pty.writeAll(text);
    }

    pub fn resize(self: *Pane, runtime: *GhosttyRuntime, cols: u16, rows: u16, cell_width_px: u32, cell_height_px: u32) void {
        runtime.resizeTerminal(self.terminal, cols, rows, cell_width_px, cell_height_px);
        if (self.pty) |*pty| pty.resize(cols, rows);
    }

    pub fn setMouseSize(self: *Pane, runtime: *GhosttyRuntime, screen_width: u32, screen_height: u32, cell_width_px: u32, cell_height_px: u32) void {
        runtime.setMouseEncoderSize(self.mouse_encoder, .{
            .size = @sizeOf(ghostty.MouseEncoderSize),
            .screen_width = screen_width,
            .screen_height = screen_height,
            .cell_width = cell_width_px,
            .cell_height = cell_height_px,
            .padding_top = 0,
            .padding_bottom = 0,
            .padding_left = 0,
            .padding_right = 0,
        });
    }

    pub fn recreateRenderHelpers(self: *Pane, runtime: *GhosttyRuntime) void {
        const new_render_state = runtime.createRenderState() catch |err| {
            std.log.err("pane: recreate render_state failed: {s}", .{@errorName(err)});
            return;
        };
        errdefer runtime.freeRenderState(new_render_state);

        const new_row_iterator = runtime.createRowIterator() catch |err| {
            std.log.err("pane: recreate row_iterator failed: {s}", .{@errorName(err)});
            return;
        };
        errdefer runtime.freeRowIterator(new_row_iterator);

        const new_row_cells = runtime.createRowCells() catch |err| {
            std.log.err("pane: recreate row_cells failed: {s}", .{@errorName(err)});
            return;
        };

        runtime.freeRowCells(self.row_cells);
        runtime.freeRowIterator(self.row_iterator);
        runtime.freeRenderState(self.render_state);
        self.render_state = new_render_state;
        self.row_iterator = new_row_iterator;
        self.row_cells = new_row_cells;
        // New render_state needs at least one updateRenderState before rendering.
        self.render_state_ready = false;
    }

    pub fn refreshTitle(self: *Pane, runtime: *GhosttyRuntime, fallback_title: []const u8) void {
        if (self.title.len > 0) {
            self.allocator.free(self.title);
            self.title = &.{};
        }
        const maybe_title = runtime.terminalTitle(self.allocator, self.terminal) catch null;
        if (maybe_title) |title| {
            self.title = title;
        } else {
            self.title = self.allocator.dupe(u8, fallback_title) catch &.{};
        }
    }

    pub fn hasLiveChild(self: *Pane) bool {
        if (self.pty) |*pty| return pty.isAlive();
        return false;
    }

    fn sanitizePtyOutput(self: *Pane, bytes: []u8) []const u8 {
        if (!platform.isWindows()) return bytes;

        const enable = "\x1b[?9001h";
        const disable = "\x1b[?9001l";
        var combined_len: usize = self.pty_pending_len;
        if (combined_len > 0) {
            @memcpy(self.pty_sanitize_buf[0..combined_len], self.pty_pending_seq[0..combined_len]);
        }
        @memcpy(self.pty_sanitize_buf[combined_len .. combined_len + bytes.len], bytes);
        combined_len += bytes.len;

        var read_idx: usize = 0;
        var write_idx: usize = 0;
        while (read_idx < combined_len) {
            const remaining = self.pty_sanitize_buf[read_idx..combined_len];
            if (std.mem.startsWith(u8, remaining, enable)) {
                read_idx += enable.len;
                continue;
            }
            if (std.mem.startsWith(u8, remaining, disable)) {
                read_idx += disable.len;
                continue;
            }
            self.pty_sanitize_buf[write_idx] = self.pty_sanitize_buf[read_idx];
            read_idx += 1;
            write_idx += 1;
        }

        const tail_len = trailingWin32ModePrefixLen(self.pty_sanitize_buf[0..write_idx]);
        self.pty_pending_len = tail_len;
        if (tail_len > 0) {
            @memcpy(self.pty_pending_seq[0..tail_len], self.pty_sanitize_buf[write_idx - tail_len .. write_idx]);
            write_idx -= tail_len;
        }

        return self.pty_sanitize_buf[0..write_idx];
    }
};

fn trailingWin32ModePrefixLen(bytes: []const u8) usize {
    const enable = "\x1b[?9001h";
    const disable = "\x1b[?9001l";
    const max_check = @min(bytes.len, enable.len - 1);
    var prefix_len = max_check;
    while (prefix_len > 0) : (prefix_len -= 1) {
        if (std.mem.eql(u8, bytes[bytes.len - prefix_len ..], enable[0..prefix_len])) return prefix_len;
        if (std.mem.eql(u8, bytes[bytes.len - prefix_len ..], disable[0..prefix_len])) return prefix_len;
    }
    return 0;
}
