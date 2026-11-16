//! Owner-side ConPTY + headless VT. Views/snapshots borrow this state; destroying
//! a view must never destroy the pane. All VT access stays on the owner thread.
const std = @import("std");
const WindowsPty = @import("../pty/pty_windows.zig").WindowsPty;
const LaunchCommand = @import("../pty/launch_command.zig").LaunchCommand;
const Wake = @import("../pty/wake.zig").Wake;
const terminal = @import("session_vt.zig");
const p = @import("session_protocol.zig");

pub const Options = struct {
    shell: [:0]const u8,
    cols: u16 = 80,
    rows: u16 = 24,
    cwd: ?[]const u8 = null,
    env_block: ?[]const u8 = null,
    launch_command: ?LaunchCommand = null,
    scrollback_bytes: usize = 10 * 1024 * 1024,
    wake: Wake = .{},
};

const Size = struct { cols: u16, rows: u16 };

pub const Pane = struct {
    a: std.mem.Allocator,
    pty: WindowsPty,
    vt: *terminal.Vt,
    wake: Wake,
    pending_replies: std.ArrayList(u8) = .empty,
    reply_offset: usize = 0,
    reply_failed: bool = false,
    pending_resize: ?Size = null,
    closed: bool = false,

    pub fn create(a: std.mem.Allocator, options: Options) !*Pane {
        try validate(options);
        const self = try a.create(Pane);
        errdefer a.destroy(self);
        const vt = try terminal.Vt.create(a, options.cols, options.rows, options.scrollback_bytes);
        errdefer vt.destroy();
        // All pane/VT allocation happens before execution. spawnSession assigns
        // the job, installs process-exit notification, and starts workers before
        // resuming the child. No fallible publication remains after it returns.
        const pty = try WindowsPty.spawnSession(a, options.shell, options.cols, options.rows, options.cwd, options.env_block, options.launch_command, options.wake);
        self.* = .{ .a = a, .pty = pty, .vt = vt, .wake = options.wake };
        return self;
    }

    pub fn destroy(self: *Pane) void {
        const a = self.a;
        self.close();
        a.destroy(self);
    }

    pub fn close(self: *Pane) void {
        if (self.closed) return;
        self.pty.close();
        self.vt.destroy();
        self.pending_replies.deinit(self.a);
        self.closed = true;
    }

    /// Accepted query-response prefixes are never submitted twice, even after
    /// a retry. Output draining must continue under input backpressure.
    pub fn flush(self: *Pane) !void {
        if (self.closed) return error.Closed;
        if (self.reply_failed) return error.ResourceExhausted;
        while (self.reply_offset < self.pending_replies.items.len) {
            const end = @min(self.reply_offset + p.max_data, self.pending_replies.items.len);
            try self.pty.writeAll(self.pending_replies.items[self.reply_offset..end]);
            self.reply_offset = end;
        }
        self.pending_replies.deinit(self.a);
        self.pending_replies = .empty;
        self.reply_offset = 0;
        if (self.pending_resize) |size| {
            try self.pty.resizeSession(size.cols, size.rows);
            self.pending_resize = null;
        }
    }

    /// Feeds owner VT with every consumed byte, independently of attached views.
    /// A returned chunk is safe to forward once; query replies remain owner-only.
    pub fn read(self: *Pane, buffer: []u8) !usize {
        self.flush() catch |err| switch (err) {
            error.ResourceExhausted => if (self.reply_failed) return err,
            else => return err,
        };
        const n = try self.pty.read(buffer);
        if (n > 0) {
            self.vt.write(buffer[0..n]);
            self.reply_failed = self.vt.reply_failed;
            var replies = self.vt.takeReplies();
            defer replies.deinit(self.a);
            // Compact only the unsubmitted suffix, never replay accepted bytes.
            const pending = self.pending_replies.items.len - self.reply_offset;
            std.mem.copyForwards(u8, self.pending_replies.items[0..pending], self.pending_replies.items[self.reply_offset..]);
            self.pending_replies.items.len = pending;
            self.reply_offset = 0;
            if (replies.items.len > terminal.reply_limit - pending) {
                self.reply_failed = true;
            } else self.pending_replies.appendSlice(self.a, replies.items) catch {
                self.reply_failed = true;
            };
            if (self.pending_replies.items.len > 0 or self.reply_failed) self.wake.signal();
        }
        _ = self.pty.pollExitStatus();
        return n;
    }

    pub fn writeAll(self: *Pane, bytes: []const u8) !void {
        try self.flush();
        try self.pty.writeAll(bytes);
    }

    /// Latest requested size is one bounded pending value. If PTY admission is
    /// full, flush retries that value without re-running an application command.
    pub fn resize(self: *Pane, cols: u16, rows: u16) !void {
        if (self.closed) return error.Closed;
        try validSize(cols, rows);
        try self.vt.resize(cols, rows);
        self.pending_resize = .{ .cols = cols, .rows = rows };
        self.wake.signal();
    }

    pub fn isAlive(self: *Pane) bool {
        return !self.closed and self.pty.pollExitStatus() == null;
    }

    /// Raw Windows status. Wire encoding is the session runtime's responsibility.
    pub fn exitStatus(self: *Pane) ?u32 {
        return self.pty.pollExitStatus();
    }

    pub fn outputEnded(self: *Pane) bool {
        return self.closed or self.pty.outputEnded();
    }

    pub fn snapshot(self: *Pane, a: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        if (self.closed) return error.Closed;
        try self.vt.snapshot(a, out);
    }

    pub fn formatVt(self: *Pane, a: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        if (self.closed) return error.Closed;
        try self.vt.formatVt(a, out);
    }
};

fn validSize(cols: u16, rows: u16) !void {
    if (cols == 0 or rows == 0 or cols > std.math.maxInt(i16) or rows > std.math.maxInt(i16)) return error.InvalidSize;
}

fn validate(options: Options) !void {
    try validSize(options.cols, options.rows);
    if (options.shell.len == 0 or std.mem.indexOfScalar(u8, options.shell, 0) != null) return error.InvalidArgv;
    if (options.shell.len > p.control_limit) return error.ResourceExhausted;
    if (options.cwd) |cwd| {
        if (std.mem.indexOfScalar(u8, cwd, 0) != null) return error.InvalidCwd;
        if (cwd.len > p.control_limit) return error.ResourceExhausted;
    }
    if (options.launch_command) |launch| {
        if (std.mem.indexOfScalar(u8, launch.command, 0) != null) return error.InvalidCommand;
        if (launch.command.len > p.control_limit) return error.ResourceExhausted;
        if (launch.argv) |argv| {
            if (argv.len == 0 or argv[0].len == 0) return error.InvalidArgv;
            var bytes: usize = 0;
            for (argv) |arg| {
                if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidArgv;
                if (bytes == p.control_limit or arg.len >= p.control_limit - bytes) return error.ResourceExhausted;
                bytes += arg.len + 1;
            }
        }
    }
    if (options.env_block) |block| {
        if (block.len > p.control_limit) return error.ResourceExhausted;
        var entries = std.mem.splitScalar(u8, block, 0);
        while (entries.next()) |entry| {
            if (entry.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return error.InvalidEnv;
            if (eq == 0) return error.InvalidEnv;
        }
    }
}
