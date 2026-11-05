//! Terminal-owned resources, extracted incrementally from the generic pane node.
//! During migration Pane embeds this value; it will become the terminal content
//! arm once all terminal consumers have moved behind the content boundary.
const ghostty = @import("ghostty.zig");
const Pty = @import("../pty/pty.zig").Pty;
const std = @import("std");
const osc99 = @import("osc99.zig");
const Pane = @import("../pane.zig").Pane;
const Config = @import("../config.zig").Config;
const LaunchCommand = @import("../pty/launch_command.zig").LaunchCommand;
const RuntimeContext = @import("pane_runtime.zig").RuntimeContext;

pub const read_buffer_size: usize = @import("pty_policy.zig").pressure_parse_chunk_bytes;
const pending_sequence_max: usize = 32;
const sanitize_buffer_size: usize = read_buffer_size + pending_sequence_max;

// PTYs are polled sequentially on the app thread. Keep transient storage shared,
// rather than allocating these large buffers for every terminal content value.
var shared_pty_read_buf: [read_buffer_size]u8 = undefined;
var shared_pty_sanitize_buf: [sanitize_buffer_size]u8 = undefined;

pub const TerminalPane = struct {
    pub const HtpMessageHandler = *const fn (pane: *Pane, payload: []const u8) void;

    host_wake: @import("../pty/wake.zig").Wake = .{},
    spawn_filter: @import("../pty/spawn_spec.zig").Filter = .{},
    pty_host: @import("../pty/spawn_spec.zig").HostResolver = .{},
    pty: ?Pty = null,
    session_callbacks: ?ghostty.TerminalCallbacks = null,
    /// Controller-owned borrowers (e.g. search handles) must be released here,
    /// while the old terminal is still alive. Must not reenter pane mutation.
    session_before_replace: ?*const fn (*Pane) void = null,
    session_view: ?struct {
        context: *anyopaque,
        id: usize,
        unbind: *const fn (*anyopaque, usize) void,
    } = null,
    session_snapshot: ?*@import("session_snapshot_job.zig").Job = null,
    session_snapshot_waiting: bool = false,
    session_scrollback: usize = 0,
    session_buffered_credit: usize = 0,
    terminal: ?*anyopaque = null,
    terminal_runtime: ?*ghostty.Runtime = null,
    render_state: ?*anyopaque = null,
    row_iterator: ?*anyopaque = null,
    row_cells: ?*anyopaque = null,
    /// The render helpers have received their first render-state update.
    render_state_ready: bool = false,
    /// Parser readiness survives releasing render helpers on hidden tabs.
    terminal_output_ready: bool = false,
    /// A PTY poll already refreshed this frame's render state.
    render_state_fresh: bool = false,
    key_encoder: ?*anyopaque = null,
    key_event: ?*anyopaque = null,
    mouse_encoder: ?*anyopaque = null,
    mouse_event: ?*anyopaque = null,
    /// Borrowed only during synchronous bracketed-paste encoding.
    paste_output: ?*ghostty.PasteOutput = null,
    clipboard_read: @import("clipboard_read.zig").State = .{},
    pending_cwd: ?[]u8 = null,
    read_buf: *[read_buffer_size]u8 = &shared_pty_read_buf,
    logged_first_pty_read: bool = false,
    pty_pending_seq: [pending_sequence_max]u8 = @splat(0),
    pty_pending_len: usize = 0,
    pty_sanitize_buf: *[sanitize_buffer_size]u8 = &shared_pty_sanitize_buf,
    osc99_active: bool = false,
    osc99_st_pending: bool = false,
    osc99_overflow: bool = false,
    osc99_buf: std.ArrayListUnmanaged(u8) = .empty,
    osc99_notifications: osc99.State = .{},
    osc_prefix_buf: [@import("../htp/codec.zig").osc_prefix.len]u8 = @splat(0),
    osc_prefix_len: usize = 0,
    osc1337_active: bool = false,
    osc1337_st_pending: bool = false,
    osc1337_overflow: bool = false,
    osc1337_buf: std.ArrayListUnmanaged(u8) = .empty,
    pending_terminal_inject: std.ArrayListUnmanaged(u8) = .empty,
    htp_osc_active: bool = false,
    htp_osc_st_pending: bool = false,
    htp_osc_overflow: bool = false,
    htp_osc_buf: []u8 = &.{},
    htp_osc_len: usize = 0,
    boot_output: std.ArrayListUnmanaged(u8) = .empty,
    pending_startup_input: []u8 = &.{},
    pending_startup_input_capacity: usize = 0,
    startup_input_quiet_ticks: u8 = 0,
    htp_message_handler: ?HtpMessageHandler = null,
    image_storage_generation: u64 = 0,
    image_animation_deadline_ns: i128 = 0,
    /// Scrolling invalidates row identity in the retained pane texture.
    viewport_scroll_pending: bool = false,
    /// Parser activity consumed by the app's render-state update.
    pty_received_data: bool = false,
    /// Parser activity consumed by the renderer, not the app tick.
    pty_wrote_this_frame: bool = false,
    synchronized_output_active: bool = false,
    synchronized_output_enabled: bool = true,
    synchronized_output_started_ns: i128 = 0,
    last_mouse_tracking: u32 = 0,
    mouse_tracking_logged_initial: bool = false,
    active_screen: u32 = 0,
    pending_alt_screen_nudge: bool = false,
    alt_screen_nudge_quiet_ticks: u8 = 0,
    alt_screen_nudge_not_before_ns: i128 = 0,
    last_has_pending_ns: i128 = 0,
    last_sanitize_ns: i128 = 0,
    last_child_alive_ns: i128 = 0,
    last_encoder_sync_ns: i128 = 0,
    last_terminal_write_bytes: usize = 0,
    last_terminal_write_chunks: usize = 0,
    last_pty_read_ns: i128 = 0,
    last_terminal_write_ns: i128 = 0,
    last_pty_output_ns: i128 = 0,
    /// Idle render polling preserves cursor blink without updating every frame.
    last_render_state_update_ns: i128 = 0,
    compression_activity: ?u64 = null,
    compression_deadline_ns: i128 = 0,
    child_alive_cached: bool = true,
    last_child_alive_check_ns: i128 = 0,
    exit_event_emitted: bool = false,
    automation_command_id: ?u64 = null,
    automation_token: ?[32]u8 = null,
    retain_on_exit: bool = false,
    job_output: @import("../job_output.zig").Capture = .{},
    scrollbar_total: u64 = 0,
    scrollbar_offset: u64 = 0,
    scrollbar_len: u64 = 0,
    domain_name: []u8 = &.{},
    is_remote: bool = false,

    fn runtimeContext(self: *TerminalPane, node: *Pane) RuntimeContext {
        return .{ .term = self, .node = node, .allocator = node.allocator };
    }

    pub fn bootstrap(self: *TerminalPane, node: *Pane, runtime: *ghostty.Runtime, callbacks: ghostty.TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32, inherited_cwd: ?[]const u8, domain_name: ?[]const u8, launch_command: ?LaunchCommand, workspace_id: ?[]const u8) !void {
        var context = self.runtimeContext(node);
        try context.bootstrap(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height, inherited_cwd, domain_name, launch_command, workspace_id);
    }

    /// Bind an already attached owner pane without spawning a local shell.
    /// SessionPty ownership transfers only on success; live panes cannot convert.
    pub fn bootstrapSession(self: *TerminalPane, node: *Pane, runtime: *ghostty.Runtime, callbacks: ghostty.TerminalCallbacks, cfg: Config, pty: @import("../pty/session.zig").SessionPty) !void {
        try @import("session_pane.zig").bootstrap(self, node, runtime, callbacks, cfg, pty);
    }

    pub fn beginSessionSnapshot(self: *TerminalPane, node: *Pane, format: @import("../agent/session_protocol.zig").SnapshotFormat) !void {
        try @import("session_pane.zig").beginSnapshot(self, node, format);
    }

    pub fn pollSessionSnapshot(self: *TerminalPane, node: *Pane, runtime: *ghostty.Runtime) !void {
        try @import("session_pane.zig").pollSnapshot(self, node, runtime);
    }

    pub fn pollPty(self: *TerminalPane, node: *Pane, runtime: *ghostty.Runtime, max_read_loops: usize, max_total_read: usize, budget_ns: i128, parse_chunk_bytes: usize, debug_overlay: bool) !usize {
        var context = self.runtimeContext(node);
        return context.pollPty(runtime, max_read_loops, max_total_read, budget_ns, parse_chunk_bytes, debug_overlay);
    }

    pub fn refreshCwd(self: *TerminalPane, node: *Pane) bool {
        var context = self.runtimeContext(node);
        return context.refreshCwd();
    }

    pub fn refreshTitle(self: *TerminalPane, node: *Pane, runtime: *ghostty.Runtime, fallback_title: []const u8, shell_command: []const u8) void {
        var context = self.runtimeContext(node);
        context.refreshTitle(runtime, fallback_title, shell_command);
    }

    pub fn resize(self: *TerminalPane, node: *Pane, runtime: *ghostty.Runtime, cols: u16, rows: u16, cell_width_px: u32, cell_height_px: u32, skip_pty: bool) void {
        var context = self.runtimeContext(node);
        context.resize(runtime, cols, rows, cell_width_px, cell_height_px, skip_pty);
    }

    pub fn nudgeTerminal(self: *TerminalPane, node: *Pane, runtime: *ghostty.Runtime, cell_width_px: u32, cell_height_px: u32) void {
        var context = self.runtimeContext(node);
        context.nudgeTerminal(runtime, cell_width_px, cell_height_px);
    }

    pub fn setMouseSize(self: *TerminalPane, runtime: *ghostty.Runtime, screen_width: u32, screen_height: u32, cell_width_px: u32, cell_height_px: u32, padding_top: u32, padding_bottom: u32, padding_left: u32, padding_right: u32) void {
        runtime.setMouseEncoderSize(self.mouse_encoder, .{
            .size = @sizeOf(ghostty.MouseEncoderSize),
            .screen_width = screen_width,
            .screen_height = screen_height,
            .cell_width = cell_width_px,
            .cell_height = cell_height_px,
            .padding_top = padding_top,
            .padding_bottom = padding_bottom,
            .padding_left = padding_left,
            .padding_right = padding_right,
        });
        runtime.setMouseEncoderTrackLastCell(self.mouse_encoder, true);
    }

    pub fn sendUserText(self: *TerminalPane, allocator: std.mem.Allocator, text: []const u8) void {
        if (self.pending_startup_input.len > 0) {
            self.queuePendingRawInput(allocator, text) catch |err| {
                std.log.err("pane: failed to queue input behind startup input: {s}", .{@errorName(err)});
            };
            return;
        }
        self.sendText(text);
    }

    pub fn initInput(runtime: *ghostty.Runtime, terminal: ?*anyopaque) !TerminalPane {
        const key_encoder = try runtime.createKeyEncoder();
        errdefer runtime.freeKeyEncoder(key_encoder);
        runtime.syncKeyEncoder(key_encoder, terminal);
        const key_event = try runtime.createKeyEvent();
        errdefer runtime.freeKeyEvent(key_event);
        const mouse_encoder = try runtime.createMouseEncoder();
        errdefer runtime.freeMouseEncoder(mouse_encoder);
        const mouse_event = try runtime.createMouseEvent();
        return .{
            .terminal_runtime = runtime,
            .key_encoder = key_encoder,
            .key_event = key_event,
            .mouse_encoder = mouse_encoder,
            .mouse_event = mouse_event,
        };
    }

    pub fn deinitInput(self: *TerminalPane, runtime: *ghostty.Runtime) void {
        runtime.freeMouseEvent(self.mouse_event);
        runtime.freeMouseEncoder(self.mouse_encoder);
        runtime.freeKeyEvent(self.key_event);
        runtime.freeKeyEncoder(self.key_encoder);
        self.mouse_event = null;
        self.mouse_encoder = null;
        self.key_event = null;
        self.key_encoder = null;
    }

    pub fn deinitPty(self: *TerminalPane) void {
        if (self.pty) |*pty| pty.deinit();
        self.pty = null;
    }

    pub fn deinit(self: *TerminalPane, runtime: *ghostty.Runtime, allocator: std.mem.Allocator) void {
        if (self.session_view) |view| view.unbind(view.context, view.id);
        self.session_view = null;
        // Decoder borrows this terminal after READY. Join and free it first.
        if (self.session_snapshot) |job| job.destroy();
        self.session_snapshot = null;
        self.deinitBuffers(allocator);
        self.deinitInput(runtime);
        self.freeRenderHandles(runtime);
        runtime.setTerminalUserdata(self.terminal, null);
        runtime.freeTerminal(self.terminal);
        self.deinitPty();
        self.* = .{};
    }

    pub fn deinitBuffers(self: *TerminalPane, allocator: std.mem.Allocator) void {
        self.clipboard_read.revoke(allocator);
        self.job_output.deinit(allocator);
        if (self.pending_cwd) |value| allocator.free(value);
        self.pending_cwd = null;
        self.boot_output.deinit(allocator);
        self.boot_output = .empty;
        self.osc1337_buf.deinit(allocator);
        self.osc1337_buf = .empty;
        self.osc99_buf.deinit(allocator);
        self.osc99_buf = .empty;
        self.osc99_notifications.deinit(allocator);
        self.osc99_notifications = .{};
        self.pending_terminal_inject.deinit(allocator);
        self.pending_terminal_inject = .empty;
        if (self.htp_osc_buf.len > 0) allocator.free(self.htp_osc_buf);
        self.htp_osc_buf = &.{};
        self.htp_osc_len = 0;
        if (self.pending_startup_input_capacity > 0) allocator.free(self.pending_startup_input.ptr[0..self.pending_startup_input_capacity]);
        self.pending_startup_input = &.{};
        self.pending_startup_input_capacity = 0;
        self.startup_input_quiet_ticks = 0;
        if (self.domain_name.len > 0) allocator.free(self.domain_name);
        self.domain_name = &.{};
    }

    pub fn sendText(self: *TerminalPane, text: []const u8) void {
        if (self.pty) |*pty| {
            if (!pty.isAlive()) return;
            pty.writeAll(text) catch |err| {
                std.log.err("pane: sendText failed: {s}", .{@errorName(err)});
            };
        }
    }

    pub fn writeEscapeSequence(self: *TerminalPane, sequence: []const u8) void {
        if (self.pty) |*pty| {
            pty.writeAll(sequence) catch |err| {
                std.log.warn("pane: writeEscapeSequence failed: {s}", .{@errorName(err)});
            };
        }
    }

    pub fn childPid(self: *const TerminalPane) usize {
        if (self.pty) |pty| return pty.childPid();
        return 0;
    }

    pub fn usesAgent(self: *const TerminalPane) bool {
        if (self.pty) |*pty| return @import("../pty/pty.zig").usesAgent(pty);
        return false;
    }

    pub fn pendingPtyOutputBytes(self: *TerminalPane) usize {
        if (self.pty) |*pty| return pty.pendingOutputBytes();
        return 0;
    }

    pub fn hasLiveChild(self: *TerminalPane) bool {
        self.refreshChildAliveCache(false);
        return self.child_alive_cached;
    }

    pub fn refreshChildAliveCache(self: *TerminalPane, force: bool) void {
        const pty = if (self.pty) |*value| value else {
            self.child_alive_cached = false;
            self.last_child_alive_check_ns = 0;
            return;
        };
        if (!self.child_alive_cached) return;
        const now_ns = @import("../io.zig").nanoTimestamp();
        if (!force and self.last_child_alive_check_ns != 0 and now_ns - self.last_child_alive_check_ns < 1_000_000_000 and !pty.hasPendingOutputOrExit()) return;
        self.last_child_alive_check_ns = now_ns;
        self.child_alive_cached = pty.isAlive();
    }

    pub fn refreshScrollbar(self: *TerminalPane, runtime: *ghostty.Runtime, rows: u16) ghostty.TerminalScrollbar {
        const value = runtime.terminalScrollbar(self.terminal) orelse ghostty.TerminalScrollbar{
            .total = @max(@as(u64, 1), rows),
            .offset = 0,
            .len = @max(@as(u64, 1), rows),
        };
        self.scrollbar_total = value.total;
        self.scrollbar_offset = value.offset;
        self.scrollbar_len = value.len;
        return value;
    }

    pub fn markViewportScrolled(self: *TerminalPane) void {
        self.viewport_scroll_pending = true;
        self.render_state_fresh = false;
        self.last_render_state_update_ns = 0;
        self.pty_received_data = true;
    }

    pub fn scrollbar(self: *const TerminalPane) ghostty.TerminalScrollbar {
        return .{ .total = self.scrollbar_total, .offset = self.scrollbar_offset, .len = self.scrollbar_len };
    }

    /// Returns whether the generic pane's retained texture needs invalidation.
    pub fn tickImageAnimation(self: *TerminalPane, runtime: *ghostty.Runtime, now_ns: i128) bool {
        if (self.synchronized_output_active) return false;
        const graphics = runtime.terminalKittyGraphics(self.terminal) orelse {
            self.image_animation_deadline_ns = 0;
            return false;
        };
        const before = runtime.kittyStorageGeneration(graphics);
        if (before == self.image_storage_generation and
            (self.image_animation_deadline_ns == 0 or now_ns < self.image_animation_deadline_ns)) return false;
        const next_ms = runtime.tickKittyAnimation(graphics, @intCast(@divFloor(now_ns, std.time.ns_per_ms)));
        self.image_animation_deadline_ns = if (next_ms) |ms| @max(now_ns + 8 * std.time.ns_per_ms, @as(i128, ms) * std.time.ns_per_ms) else 0;
        const after = runtime.kittyStorageGeneration(graphics);
        const changed = after != self.image_storage_generation;
        if (changed) self.render_state_fresh = false;
        self.image_storage_generation = after;
        return changed;
    }

    pub fn expireRenderHold(self: *TerminalPane, runtime: *ghostty.Runtime, now_ns: i128, timeout_ns: i128) bool {
        if (!self.synchronized_output_active or now_ns - self.synchronized_output_started_ns < timeout_ns) return false;
        // Setting a mode through the API intentionally does not call render_hold.
        _ = runtime.setTerminalMode(self.terminal, .synchronized_output, false);
        self.synchronized_output_active = false;
        self.synchronized_output_started_ns = 0;
        self.render_state_fresh = false;
        return true;
    }

    pub fn tickCompression(self: *TerminalPane, runtime: *ghostty.Runtime, now_ns: i128) void {
        const idle_delay_ns: i128 = 250 * std.time.ns_per_ms;
        const continuation_delay_ns: i128 = std.time.ns_per_ms;
        const activity = runtime.terminalCompressionActivity(self.terminal) catch |err| {
            std.log.err("pane compression activity failed: {s}", .{@errorName(err)});
            self.compression_deadline_ns = 0;
            return;
        };
        if (self.compression_activity == null or self.compression_activity.? != activity) {
            self.compression_activity = activity;
            self.compression_deadline_ns = now_ns + idle_delay_ns;
            return;
        }
        if (self.compression_deadline_ns == 0 or now_ns < self.compression_deadline_ns) return;
        self.compression_deadline_ns = switch (runtime.terminalCompress(self.terminal) catch |err| {
            std.log.err("pane compression failed: {s}", .{@errorName(err)});
            self.compression_deadline_ns = 0;
            return;
        }) {
            .pending => now_ns + continuation_delay_ns,
            .complete, .unsupported => 0,
        };
    }

    pub fn queueStartupInput(self: *TerminalPane, allocator: std.mem.Allocator, text: []const u8) !void {
        const suffix = if (!std.mem.endsWith(u8, text, "\r") and !std.mem.endsWith(u8, text, "\n")) "\r" else "";
        try self.queuePendingInput(allocator, text, suffix);
    }

    pub fn queuePendingRawInput(self: *TerminalPane, allocator: std.mem.Allocator, text: []const u8) !void {
        try self.queuePendingInput(allocator, text, "");
    }

    fn queuePendingInput(self: *TerminalPane, allocator: std.mem.Allocator, text: []const u8, suffix: []const u8) !void {
        const old = self.pending_startup_input;
        const queued = try allocator.alloc(u8, old.len + text.len + suffix.len);
        std.mem.copyForwards(u8, queued[0..old.len], old);
        std.mem.copyForwards(u8, queued[old.len..][0..text.len], text);
        std.mem.copyForwards(u8, queued[old.len + text.len ..], suffix);
        if (self.pending_startup_input_capacity > 0) allocator.free(old.ptr[0..self.pending_startup_input_capacity]);
        self.pending_startup_input = queued;
        self.pending_startup_input_capacity = queued.len;
        self.startup_input_quiet_ticks = 0;
    }

    fn freeRenderHandles(self: *TerminalPane, runtime: anytype) void {
        runtime.freeRowCells(self.row_cells);
        self.row_cells = null;
        runtime.freeRowIterator(self.row_iterator);
        self.row_iterator = null;
        runtime.freeRenderState(self.render_state);
        self.render_state = null;
    }

    pub fn hasRenderHelpers(self: *const TerminalPane) bool {
        return self.render_state != null and self.row_iterator != null and self.row_cells != null;
    }

    pub fn renderHelpersReady(self: *const TerminalPane) bool {
        return self.render_state_ready and self.hasRenderHelpers();
    }

    /// Borrow render helpers for a screen query, creating them temporarily for
    /// hidden terminals. Call `end` on every successful borrow.
    pub const Read = struct {
        runtime: *ghostty.Runtime,
        term: *TerminalPane,
        transient: bool,

        pub fn end(self: Read) void {
            if (self.transient) self.term.releaseRenderHelpers(self.runtime);
        }
    };

    pub fn beginRead(self: *TerminalPane, runtime: *ghostty.Runtime) ?Read {
        if (self.renderHelpersReady()) return .{ .runtime = runtime, .term = self, .transient = false };
        if (self.terminal == null) return null;
        var transient = false;
        if (!self.hasRenderHelpers()) {
            self.recreateRenderHelpers(runtime);
            if (!self.hasRenderHelpers()) return null;
            transient = true;
        }
        const read: Read = .{ .runtime = runtime, .term = self, .transient = transient };
        runtime.updateRenderState(self.render_state, self.terminal) catch {
            read.end();
            return null;
        };
        return read;
    }

    pub fn recreateRenderHelpers(self: *TerminalPane, runtime: *ghostty.Runtime) void {
        var failed: RenderResource = undefined;
        self.replaceRenderHelpers(runtime, &failed) catch |err| {
            std.log.err("pane: recreate {s} failed: {s}", .{ @tagName(failed), @errorName(err) });
        };
    }

    const RenderResource = enum { render_state, row_iterator, row_cells };

    /// Fallible ownership transaction, also exercised with an allocation-failing
    /// test runtime. No live handles or readiness flags change before success.
    fn replaceRenderHelpers(self: *TerminalPane, runtime: anytype, failed: *RenderResource) !void {
        failed.* = .render_state;
        const new_render_state = try runtime.createRenderState();
        errdefer runtime.freeRenderState(new_render_state);
        failed.* = .row_iterator;
        const new_row_iterator = try runtime.createRowIterator();
        errdefer runtime.freeRowIterator(new_row_iterator);
        failed.* = .row_cells;
        const new_row_cells = try runtime.createRowCells();
        // Publish all three only after every allocation succeeds. A failed
        // recreation leaves the previous helpers intact and releases its locals.
        self.freeRenderHandles(runtime);
        self.render_state = new_render_state;
        self.row_iterator = new_row_iterator;
        self.row_cells = new_row_cells;
        self.render_state_ready = false;
    }

    pub fn releaseRenderHelpers(self: *TerminalPane, runtime: *ghostty.Runtime) void {
        self.freeRenderHandles(runtime);
        self.render_state_ready = false;
        self.render_state_fresh = false;
    }

    pub fn syncInput(self: *TerminalPane, runtime: *ghostty.Runtime, terminal: ?*anyopaque) void {
        runtime.syncKeyEncoder(self.key_encoder, terminal);
        runtime.syncMouseEncoder(self.mouse_encoder, terminal);
    }

    pub fn encodeKey(self: *TerminalPane, runtime: *ghostty.Runtime, key: ghostty.Key, mods: u32, action: ghostty.KeyAction, consumed_mods: u32, unshifted_codepoint: u32, utf8: ?[]const u8, out: []u8) ?[]const u8 {
        return runtime.encodeKey(self.key_encoder, self.key_event, key, mods, action, consumed_mods, unshifted_codepoint, utf8, out);
    }

    pub fn encodeMouse(self: *TerminalPane, runtime: *ghostty.Runtime, action: ghostty.MouseAction, button: ?ghostty.MouseButton, mods: u32, position: ghostty.MousePosition, out: []u8) ?[]const u8 {
        runtime.setMouseEncoderAnyButtonPressed(self.mouse_encoder, action != .release and button != null);
        return runtime.encodeMouse(self.mouse_encoder, self.mouse_event, action, button, mods, position, out);
    }
};

test "terminal lifecycle queries and scroll state need no pane node" {
    var content: TerminalPane = .{
        .scrollbar_total = 100,
        .scrollbar_offset = 50,
        .scrollbar_len = 20,
        .last_child_alive_check_ns = 123,
    };
    try std.testing.expectEqualDeep(ghostty.TerminalScrollbar{ .total = 100, .offset = 50, .len = 20 }, content.scrollbar());
    try std.testing.expectEqual(@as(usize, 0), content.childPid());
    try std.testing.expectEqual(@as(usize, 0), content.pendingPtyOutputBytes());
    try std.testing.expect(!content.usesAgent());
    try std.testing.expect(!content.hasLiveChild());
    try std.testing.expect(!content.child_alive_cached);
    try std.testing.expectEqual(@as(i128, 0), content.last_child_alive_check_ns);
    content.refreshChildAliveCache(true);
    content.sendText("discarded without a PTY");
    content.writeEscapeSequence("\x1b[0m");
}

test "terminal scrollbar refresh and viewport damage need no pane node" {
    var runtime = try ghostty.Runtime.init(std.testing.allocator, null);
    defer runtime.deinit();
    var content: TerminalPane = .{};
    // Missing native terminal preserves the existing one-row-minimum fallback.
    try std.testing.expectEqualDeep(ghostty.TerminalScrollbar{ .total = 1, .offset = 0, .len = 1 }, content.refreshScrollbar(&runtime, 0));
    try std.testing.expectEqualDeep(ghostty.TerminalScrollbar{ .total = 24, .offset = 0, .len = 24 }, content.refreshScrollbar(&runtime, 24));
    content.terminal = try runtime.createTerminal(80, 12, 0);
    defer content.deinit(&runtime, std.testing.allocator);
    const native = runtime.terminalScrollbar(content.terminal).?;
    try std.testing.expectEqualDeep(native, content.refreshScrollbar(&runtime, 99));
    try std.testing.expectEqualDeep(native, content.scrollbar());
    content.render_state_fresh = true;
    content.last_render_state_update_ns = 123;
    content.markViewportScrolled();
    try std.testing.expect(content.viewport_scroll_pending);
    try std.testing.expect(!content.render_state_fresh);
    try std.testing.expectEqual(@as(i128, 0), content.last_render_state_update_ns);
    try std.testing.expect(content.pty_received_data);
}

test "terminal destruction owns domain and job capture and resets runtime state" {
    const allocator = std.testing.allocator;
    var runtime = try ghostty.Runtime.init(allocator, null);
    defer runtime.deinit();
    var content: TerminalPane = .{
        .exit_event_emitted = true,
        .automation_command_id = 42,
        .automation_token = "0123456789abcdef0123456789abcdef".*,
        .retain_on_exit = true,
        .synchronized_output_active = true,
        .synchronized_output_started_ns = 123,
        .image_animation_deadline_ns = 456,
        .compression_deadline_ns = 789,
        .pty_received_data = true,
        .pty_wrote_this_frame = true,
        .is_remote = true,
    };
    defer content.deinit(&runtime, allocator);
    content.domain_name = try allocator.dupe(u8, "remote");
    content.job_output.append(allocator, "raw job output\x1b[0m");
    const captured = try content.job_output.snapshot(allocator);
    defer allocator.free(captured);
    try std.testing.expectEqualStrings("raw job output\x1b[0m", captured);
    content.deinit(&runtime, allocator);
    try std.testing.expect(content.job_output.bytes == null);
    try std.testing.expectEqual(@as(usize, 0), content.domain_name.len);
    try std.testing.expect(!content.exit_event_emitted and !content.retain_on_exit);
    try std.testing.expect(content.automation_token == null and content.automation_command_id == null);
    try std.testing.expect(!content.synchronized_output_active and content.synchronized_output_enabled);
    try std.testing.expectEqual(@as(i128, 0), content.synchronized_output_started_ns);
    try std.testing.expectEqual(@as(i128, 0), content.image_animation_deadline_ns);
    try std.testing.expectEqual(@as(i128, 0), content.compression_deadline_ns);
    try std.testing.expect(!content.pty_received_data and !content.pty_wrote_this_frame);
    try std.testing.expect(!content.is_remote);
}

test "terminal protocol buffers clean up every partial allocation and shortened startup input" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var content: TerminalPane = .{};
            defer content.deinitBuffers(allocator);
            content.domain_name = try allocator.dupe(u8, "local");
            content.pending_cwd = try allocator.dupe(u8, "/reported");
            try content.boot_output.appendSlice(allocator, "deferred PTY output");
            try content.osc1337_buf.appendSlice(allocator, "image data");
            try content.osc99_buf.appendSlice(allocator, "notification packet");
            try content.pending_terminal_inject.appendSlice(allocator, "image escape sequence");
            content.htp_osc_buf = try allocator.alloc(u8, 8192);
            content.htp_osc_len = 5;
            try content.osc99_notifications.enqueueSimple(allocator, "Build", "Complete", .info);
            try content.queueStartupInput(allocator, "startup command");
            // PTY writes shrink the visible slice without shrinking its owned
            // allocation; destruction must free using the original capacity.
            content.pending_startup_input = content.pending_startup_input[0..3];
            content.deinitBuffers(allocator);
            content.deinitBuffers(allocator);
            try std.testing.expect(content.pending_cwd == null);
            try std.testing.expectEqual(@as(usize, 0), content.domain_name.len);
            try std.testing.expectEqual(@as(usize, 0), content.boot_output.capacity);
            try std.testing.expectEqual(@as(usize, 0), content.osc1337_buf.capacity);
            try std.testing.expectEqual(@as(usize, 0), content.osc99_buf.capacity);
            try std.testing.expectEqual(@as(usize, 0), content.pending_terminal_inject.capacity);
            try std.testing.expectEqual(@as(usize, 0), content.htp_osc_buf.len);
            try std.testing.expectEqual(@as(usize, 0), content.htp_osc_len);
            try std.testing.expectEqual(@as(usize, 0), content.pending_startup_input_capacity);
            try std.testing.expect(!content.osc99_notifications.hasNotifications());
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "terminal startup queue preserves old input on allocation failure and adds terminators only for commands" {
    const allocator = std.testing.allocator;
    var content: TerminalPane = .{};
    defer content.deinitBuffers(allocator);
    try content.queueStartupInput(allocator, "command");
    try std.testing.expectEqualStrings("command\r", content.pending_startup_input);
    content.startup_input_quiet_ticks = 7;
    const original = content.pending_startup_input;
    const capacity = content.pending_startup_input_capacity;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, content.queueStartupInput(failing.allocator(), "second"));
    try std.testing.expectEqual(original.ptr, content.pending_startup_input.ptr);
    try std.testing.expectEqualStrings("command\r", content.pending_startup_input);
    try std.testing.expectEqual(capacity, content.pending_startup_input_capacity);
    try std.testing.expectEqual(@as(u8, 7), content.startup_input_quiet_ticks);
    try content.queuePendingRawInput(allocator, "key");
    try content.queueStartupInput(allocator, "next\n");
    try std.testing.expectEqualStrings("command\rkeynext\n", content.pending_startup_input);
    try std.testing.expectEqual(@as(u8, 0), content.startup_input_quiet_ticks);
}

test "terminals share transient PTY buffers but keep parser progress independent" {
    var first: TerminalPane = .{};
    const second: TerminalPane = .{};
    try std.testing.expectEqual(first.read_buf, second.read_buf);
    try std.testing.expectEqual(first.pty_sanitize_buf, second.pty_sanitize_buf);
    try std.testing.expectEqual(read_buffer_size, first.read_buf.len);
    try std.testing.expectEqual(read_buffer_size + first.pty_pending_seq.len, first.pty_sanitize_buf.len);
    first.pty_pending_seq[0] = 'x';
    first.pty_pending_len = 1;
    first.osc_prefix_len = 1;
    try std.testing.expectEqual(@as(usize, 0), second.pty_pending_len);
    try std.testing.expectEqual(@as(u8, 0), second.pty_pending_seq[0]);
    try std.testing.expectEqual(@as(usize, 0), second.osc_prefix_len);
}

test "terminal input resources are owned and released independently of the pane node" {
    var runtime = try ghostty.Runtime.init(std.testing.allocator, null);
    defer runtime.deinit();
    const terminal = try runtime.createTerminal(80, 24, 0);
    defer runtime.freeTerminal(terminal);
    var content = try TerminalPane.initInput(&runtime, terminal);
    defer content.deinitInput(&runtime);
    try std.testing.expect(content.key_encoder != null and content.key_event != null);
    try std.testing.expect(content.mouse_encoder != null and content.mouse_event != null);
    content.syncInput(&runtime, terminal);
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("\r", content.encodeKey(&runtime, .enter, 0, .press, 0, 0, null, &out).?);
    content.deinitInput(&runtime);
    try std.testing.expect(content.key_encoder == null and content.key_event == null);
    try std.testing.expect(content.mouse_encoder == null and content.mouse_event == null);
}

test "terminal render helper lifetime preserves parser readiness across hidden tabs" {
    var runtime = try ghostty.Runtime.init(std.testing.allocator, null);
    defer runtime.deinit();
    var content: TerminalPane = .{
        .terminal_runtime = &runtime,
        .terminal = try runtime.createTerminal(80, 24, 0),
        .terminal_output_ready = true,
    };
    defer content.deinit(&runtime, std.testing.allocator);
    content.recreateRenderHelpers(&runtime);
    try std.testing.expect(content.hasRenderHelpers());
    try std.testing.expect(!content.renderHelpersReady());
    content.render_state_ready = true;
    content.render_state_fresh = true;
    try std.testing.expect(content.renderHelpersReady());
    const terminal = content.terminal;
    content.releaseRenderHelpers(&runtime);
    content.releaseRenderHelpers(&runtime);
    try std.testing.expect(!content.hasRenderHelpers());
    try std.testing.expect(!content.render_state_ready and !content.render_state_fresh);
    try std.testing.expect(content.terminal_output_ready);
    try std.testing.expectEqual(terminal, content.terminal);
    content.recreateRenderHelpers(&runtime);
    try std.testing.expect(content.hasRenderHelpers());
    try std.testing.expect(content.terminal_output_ready);
    content.deinit(&runtime, std.testing.allocator);
    try std.testing.expect(content.terminal == null and content.terminal_runtime == null);
    try std.testing.expect(!content.terminal_output_ready);
}

test "terminal reads release only transient helpers and preserve parser readiness" {
    var runtime = try ghostty.Runtime.init(std.testing.allocator, null);
    defer runtime.deinit();
    var content: TerminalPane = .{};
    try std.testing.expect(content.beginRead(&runtime) == null);
    content.terminal = try runtime.createTerminal(80, 24, 0);
    content.terminal_output_ready = true;
    defer content.deinit(&runtime, std.testing.allocator);
    runtime.terminalWrite(content.terminal, "hidden text");
    const transient = content.beginRead(&runtime).?;
    try std.testing.expect(transient.transient);
    try std.testing.expect(content.hasRenderHelpers());
    try std.testing.expect(!content.render_state_ready);
    transient.end();
    try std.testing.expect(!content.hasRenderHelpers());
    try std.testing.expect(content.terminal_output_ready);

    content.recreateRenderHelpers(&runtime);
    const owned_state = content.render_state;
    const owned = content.beginRead(&runtime).?;
    try std.testing.expect(!owned.transient);
    owned.end();
    try std.testing.expectEqual(owned_state, content.render_state);
    try std.testing.expect(content.hasRenderHelpers());
    content.render_state_ready = true;
    content.render_state_fresh = true;
    const ready = content.beginRead(&runtime).?;
    try std.testing.expect(!ready.transient);
    ready.end();
    try std.testing.expect(content.render_state_ready and content.render_state_fresh);
    try std.testing.expectEqual(owned_state, content.render_state);
}

test "failed render helper recreation unwinds allocations and preserves existing resources" {
    const Fake = struct {
        fail_at: usize,
        created: usize = 0,
        live: usize = 3,

        fn create(self: *@This()) !?*anyopaque {
            self.created += 1;
            if (self.created == self.fail_at) return error.OutOfMemory;
            self.live += 1;
            return @ptrFromInt(self.created * 16);
        }
        fn createRenderState(self: *@This()) !?*anyopaque {
            return self.create();
        }
        fn createRowIterator(self: *@This()) !?*anyopaque {
            return self.create();
        }
        fn createRowCells(self: *@This()) !?*anyopaque {
            return self.create();
        }
        fn freeRenderState(self: *@This(), handle: ?*anyopaque) void {
            if (handle != null) self.live -= 1;
        }
        fn freeRowIterator(self: *@This(), handle: ?*anyopaque) void {
            if (handle != null) self.live -= 1;
        }
        fn freeRowCells(self: *@This(), handle: ?*anyopaque) void {
            if (handle != null) self.live -= 1;
        }
    };
    for (1..4) |fail_at| {
        var runtime: Fake = .{ .fail_at = fail_at };
        var content: TerminalPane = .{
            .render_state = @ptrFromInt(1024),
            .row_iterator = @ptrFromInt(2048),
            .row_cells = @ptrFromInt(3072),
            .render_state_ready = true,
            .render_state_fresh = true,
            .terminal_output_ready = true,
        };
        const original = content;
        var failed: TerminalPane.RenderResource = undefined;
        try std.testing.expectError(error.OutOfMemory, content.replaceRenderHelpers(&runtime, &failed));
        try std.testing.expectEqual(std.enums.values(TerminalPane.RenderResource)[fail_at - 1], failed);
        try std.testing.expectEqual(original.render_state, content.render_state);
        try std.testing.expectEqual(original.row_iterator, content.row_iterator);
        try std.testing.expectEqual(original.row_cells, content.row_cells);
        try std.testing.expect(content.render_state_ready and content.render_state_fresh);
        try std.testing.expectEqual(@as(usize, 3), runtime.live);
        runtime.fail_at = 0;
        try content.replaceRenderHelpers(&runtime, &failed);
        try std.testing.expect(content.render_state != original.render_state);
        try std.testing.expect(!content.render_state_ready);
        try std.testing.expect(content.render_state_fresh and content.terminal_output_ready);
        try std.testing.expectEqual(@as(usize, 3), runtime.live);
        content.freeRenderHandles(&runtime);
        content.freeRenderHandles(&runtime);
        try std.testing.expectEqual(@as(usize, 0), runtime.live);
    }
}
