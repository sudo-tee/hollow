const std = @import("std");
const c = @import("sokol_c");
const command_ipc = @import("ipc.zig");
const Config = @import("config.zig").Config;
const fastmem = @import("fastmem.zig");
const GhosttyRuntime = @import("term/ghostty.zig").Runtime;
const ghostty = @import("term/ghostty.zig");
const TerminalCallbacks = ghostty.TerminalCallbacks;
const Pty = @import("pty/pty.zig").Pty;
const LaunchCommand = @import("pty/launch_command.zig").LaunchCommand;
const platform = @import("platform.zig");

const PTY_READ_BUFFER_SIZE: usize = 256 * 1024;
const PTY_PENDING_SEQUENCE_MAX: usize = 32;
const TERMINAL_WRITE_CHUNK_SIZE: usize = PTY_READ_BUFFER_SIZE;
const PTY_SANITIZE_BUFFER_SIZE: usize = PTY_READ_BUFFER_SIZE + PTY_PENDING_SEQUENCE_MAX;

const is_windows = @import("builtin").os.tag == .windows;

const OSC52_PREFIX = "\x1b]52;";
const OSC7_PREFIX = "\x1b]7;";
const OSC1337_PREFIX = "\x1b]1337;";
const HTP_OSC_PREFIX = "\x1b]1337;Hollow;";
const OSC52_SEQUENCE_MAX = 65536;
const OSC52_DECODED_MAX = OSC52_SEQUENCE_MAX / 4 * 3 + 4;
const OSC1337_SEQUENCE_MAX = 8 * 1024 * 1024;
const HTP_OSC_LOG_MAX = 8192;

const CombinedInput = struct {
    first: []const u8,
    second: []const u8,

    fn len(self: CombinedInput) usize {
        return self.first.len + self.second.len;
    }

    fn byteAt(self: CombinedInput, idx: usize) u8 {
        if (idx < self.first.len) return self.first[idx];
        return self.second[idx - self.first.len];
    }

    fn byteAtOrNull(self: CombinedInput, idx: usize) ?u8 {
        if (idx >= self.len()) return null;
        return self.byteAt(idx);
    }

    fn startsWith(self: CombinedInput, idx: usize, needle: []const u8) bool {
        if (idx + needle.len > self.len()) return false;
        for (needle, 0..) |byte, offset| {
            if (self.byteAt(idx + offset) != byte) return false;
        }
        return true;
    }

    fn indexOfScalarPos(self: CombinedInput, start: usize, value: u8) ?usize {
        if (start < self.first.len) {
            if (std.mem.indexOfScalarPos(u8, self.first, start, value)) |idx| return idx;
            if (std.mem.indexOfScalar(u8, self.second, value)) |idx| return self.first.len + idx;
            return null;
        }
        return if (std.mem.indexOfScalarPos(u8, self.second, start - self.first.len, value)) |idx|
            self.first.len + idx
        else
            null;
    }

    fn copyRange(self: CombinedInput, start: usize, end: usize, out: []u8, write_idx: *usize) void {
        if (end <= start) return;

        var remaining_start = start;
        const remaining_end = end;

        if (remaining_start < self.first.len) {
            const first_end = @min(remaining_end, self.first.len);
            const span = self.first[remaining_start..first_end];
            fastmem.copy(u8, out[write_idx.* .. write_idx.* + span.len], span);
            write_idx.* += span.len;
            remaining_start = first_end;
        }

        if (remaining_start < remaining_end) {
            const second_start = remaining_start - self.first.len;
            const second_end = remaining_end - self.first.len;
            const span = self.second[second_start..second_end];
            fastmem.copy(u8, out[write_idx.* .. write_idx.* + span.len], span);
            write_idx.* += span.len;
        }
    }
};

const OscPrefixMatch = enum {
    none,
    partial,
    osc52,
    osc7,
    osc1337,
    htp,
};

fn classifyOscPrefix(prefix: []const u8) OscPrefixMatch {
    if (std.mem.eql(u8, prefix, OSC52_PREFIX)) return .osc52;
    if (std.mem.eql(u8, prefix, OSC7_PREFIX)) return .osc7;
    if (std.mem.eql(u8, prefix, HTP_OSC_PREFIX)) return .htp;
    if (prefix.len >= OSC1337_PREFIX.len and
        std.mem.eql(u8, prefix[0..OSC1337_PREFIX.len], OSC1337_PREFIX) and
        !std.mem.startsWith(u8, HTP_OSC_PREFIX, prefix))
    {
        return .osc1337;
    }
    if (std.mem.startsWith(u8, OSC52_PREFIX, prefix) or
        std.mem.startsWith(u8, OSC7_PREFIX, prefix) or
        std.mem.startsWith(u8, OSC1337_PREFIX, prefix) or
        std.mem.startsWith(u8, HTP_OSC_PREFIX, prefix))
    {
        return .partial;
    }
    return .none;
}

pub const Pane = struct {
    pub const HtpMessageHandler = *const fn (pane: *Pane, payload: []const u8) void;

    allocator: std.mem.Allocator,
    pty: ?Pty = null,
    terminal: ?*anyopaque = null,
    render_state: ?*anyopaque = null,
    row_iterator: ?*anyopaque = null,
    foreground_process: ?[]u8 = null,
    row_cells: ?*anyopaque = null,
    key_encoder: ?*anyopaque = null,
    key_event: ?*anyopaque = null,
    mouse_encoder: ?*anyopaque = null,
    mouse_event: ?*anyopaque = null,
    title: []u8 = &.{},
    cwd: []u8 = &.{},
    /// Actual terminal dimensions in characters (updated on every resize).
    cols: u16 = 0,
    rows: u16 = 0,
    /// Set to true after the first updateRenderState call so the renderer
    /// can skip rendering panes whose ghostty state is not yet initialized.
    render_state_ready: bool = false,
    /// Dirty level set by tickPanes after updateRenderState computes the latest
    /// render-state dirty result for the pane.
    ///   .false_value  → nothing changed, skip re-render entirely
    ///   .true_value   → partial update; use LOAD action and skip clean rows
    ///   .full         → full redraw needed (resize, scroll, color change);
    ///                   clear RT and re-render all rows
    /// Cleared (set back to .false_value) by the renderer after re-rendering.
    render_dirty: ghostty.RenderStateDirty = .false_value,
    read_buf: [PTY_READ_BUFFER_SIZE]u8 = [_]u8{0} ** PTY_READ_BUFFER_SIZE,
    logged_first_pty_read: bool = false,
    pty_pending_seq: [PTY_PENDING_SEQUENCE_MAX]u8 = [_]u8{0} ** PTY_PENDING_SEQUENCE_MAX,
    pty_pending_len: usize = 0,
    pty_sanitize_buf: [PTY_SANITIZE_BUFFER_SIZE]u8 = [_]u8{0} ** PTY_SANITIZE_BUFFER_SIZE,
    osc52_prefix_len: usize = 0,
    osc52_active: bool = false,
    osc52_st_pending: bool = false,
    osc52_overflow: bool = false,
    osc52_buf: [OSC52_SEQUENCE_MAX]u8 = [_]u8{0} ** OSC52_SEQUENCE_MAX,
    osc52_len: usize = 0,
    osc_prefix_buf: [HTP_OSC_PREFIX.len]u8 = [_]u8{0} ** HTP_OSC_PREFIX.len,
    osc_prefix_len: usize = 0,
    osc7_active: bool = false,
    osc7_st_pending: bool = false,
    osc7_buf: [1024]u8 = [_]u8{0} ** 1024,
    osc7_len: usize = 0,
    osc1337_active: bool = false,
    osc1337_st_pending: bool = false,
    osc1337_overflow: bool = false,
    osc1337_buf: std.ArrayListUnmanaged(u8) = .empty,
    pending_terminal_inject: std.ArrayListUnmanaged(u8) = .empty,
    htp_osc_active: bool = false,
    htp_osc_st_pending: bool = false,
    htp_osc_overflow: bool = false,
    htp_osc_buf: [HTP_OSC_LOG_MAX]u8 = [_]u8{0} ** HTP_OSC_LOG_MAX,
    htp_osc_len: usize = 0,
    htp_message_handler: ?HtpMessageHandler = null,
    boot_output: std.ArrayListUnmanaged(u8) = .empty,
    terminal_write_batch: std.ArrayListUnmanaged(u8) = .empty,
    pending_startup_input: []u8 = &.{},
    startup_input_quiet_ticks: u8 = 0,
    /// Set to true by pollPty when actual PTY bytes were written to the terminal
    /// this tick.  Cleared by tickPanes after updateRenderState is called.
    /// Used to avoid calling updateRenderState on idle panes — ghostty marks
    /// the render_state dirty on every updateRenderState call (cursor blink,
    /// etc.), so calling it unconditionally causes every pane to re-render
    /// every frame even when nothing changed.
    pty_received_data: bool = false,
    /// Set to true by pollPty when actual PTY bytes were written this tick.
    /// Unlike pty_received_data, this is cleared by the RENDERER (not by
    /// tickPanes) so that the render phase can see whether the shell was
    /// actively writing this frame.  Used to hold force-full CLEAR renders
    /// until the shell's post-resize redraw has fully settled.
    pty_wrote_this_frame: bool = false,
    /// Last known mouse tracking mode (from terminal_get).  Logged on change.
    last_mouse_tracking: u32 = 0,
    mouse_tracking_logged_initial: bool = false,
    /// Last known active screen (0=primary, 1=alternate).  Used for per-pane padding.
    active_screen: u32 = 0,
    /// Queue a one-shot PTY repaint nudge after alternate-screen entry settles.
    pending_alt_screen_nudge: bool = false,
    alt_screen_nudge_quiet_ticks: u8 = 0,
    last_has_pending_ns: i128 = 0,
    last_sanitize_ns: i128 = 0,
    last_child_alive_ns: i128 = 0,
    last_encoder_sync_ns: i128 = 0,
    last_terminal_write_bytes: usize = 0,
    last_terminal_write_chunks: usize = 0,
    last_pty_read_ns: i128 = 0,
    last_terminal_write_ns: i128 = 0,
    /// Monotonic nanosecond timestamp of the last updateRenderState call on this
    /// pane.  Used to throttle the cursor-blink / idle poll: even with no PTY
    /// data we call updateRenderState at most once per ~16 ms so that cursor
    /// blink (managed by ghostty's internal timer) still fires.
    last_render_state_update_ns: i128 = 0,
    /// Set when pollPty already refreshed render_state after draining PTY data.
    /// tickPanes consumes this to avoid doing the same update twice.
    render_state_fresh: bool = false,
    child_alive_cached: bool = true,
    last_child_alive_check_ns: i128 = 0,
    scrollbar_total: u64 = 0,
    scrollbar_offset: u64 = 0,
    scrollbar_len: u64 = 0,
    title_dirty: bool = false,
    title_is_manual: bool = false,
    bell_dirty: bool = false,
    bell_active: bool = false,
    bell_started_at_ns: i128 = 0,
    has_bell_attention: bool = false,
    x_px: u32 = 0,
    y_px: u32 = 0,
    width_px: u32 = 0,
    height_px: u32 = 0,
    domain_name: []u8 = &.{},
    is_remote: bool = false,
    cwd_dirty: bool = false,
    is_floating: bool = false,
    floating_x: f32 = 0.15,
    floating_y: f32 = 0.1,
    floating_width: f32 = 0.7,
    floating_height: f32 = 0.75,
    restore_anchor_id: usize = 0,
    restore_ratio: f32 = 0.5,
    restore_split_horizontal: bool = false,
    restore_place_first: bool = false,

    pub fn init(allocator: std.mem.Allocator) Pane {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Pane, runtime: *GhosttyRuntime) void {
        self.boot_output.deinit(self.allocator);
        self.terminal_write_batch.deinit(self.allocator);
        self.osc1337_buf.deinit(self.allocator);
        self.pending_terminal_inject.deinit(self.allocator);
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
        if (self.cwd.len > 0) self.allocator.free(self.cwd);
        if (self.pending_startup_input.len > 0) self.allocator.free(self.pending_startup_input);
        if (self.domain_name.len > 0) self.allocator.free(self.domain_name);
        self.* = Pane.init(self.allocator);
    }

    pub fn bootstrap(self: *Pane, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32, inherited_cwd: ?[]const u8, domain_name: ?[]const u8, launch_command: ?LaunchCommand, workspace_id: ?[]const u8) !void {
        const start_ms = std.time.milliTimestamp();
        _ = cell_width_px;
        _ = cell_height_px;
        _ = window_width;
        _ = window_height;
        const terminal = try runtime.createTerminal(.{
            .cols = cfg.cols,
            .rows = cfg.rows,
            .max_scrollback = cfg.scrollback,
        });
        errdefer runtime.freeTerminal(terminal);

        runtime.setKittyImageStorageLimit(terminal, 64 * 1024 * 1024);
        runtime.setKittyImageMediumFile(terminal, true);
        runtime.setKittyImageMediumTempFile(terminal, true);
        runtime.setKittyImageMediumSharedMem(terminal, true);
        runtime.setApcMaxBytes(terminal, 64 * 1024 * 1024);
        runtime.setApcMaxBytesKitty(terminal, 64 * 1024 * 1024);

        // Register callbacks immediately — before any ghostty call that might
        // invoke them (resizeTerminal, updateRenderState).  A freshly created
        // terminal has null slots for all callbacks; calling into ghostty before
        // these are set causes a null-function-pointer segfault.
        runtime.registerCallbacks(terminal, callbacks);
        // Enable Kitty keyboard protocol by simulating the activation sequence from the PTY
        runtime.terminalWrite(terminal, "\x1b[>12;1u");

        const render_state = try runtime.createRenderState();
        errdefer runtime.freeRenderState(render_state);

        const row_iterator = try runtime.createRowIterator();
        errdefer runtime.freeRowIterator(row_iterator);

        const row_cells = try runtime.createRowCells();
        errdefer runtime.freeRowCells(row_cells);

        const key_encoder = try runtime.createKeyEncoder();
        errdefer runtime.freeKeyEncoder(key_encoder);
        runtime.syncKeyEncoder(key_encoder, terminal);

        const key_event = try runtime.createKeyEvent();
        errdefer runtime.freeKeyEvent(key_event);

        const mouse_encoder = try runtime.createMouseEncoder();
        errdefer runtime.freeMouseEncoder(mouse_encoder);

        const mouse_event = try runtime.createMouseEvent();
        errdefer runtime.freeMouseEvent(mouse_event);

        const shell = try self.allocator.dupeZ(u8, try cfg.shellForDomain(domain_name));
        defer self.allocator.free(shell);

        // Build environment block for HTP
        // Format: "KEY1=value1\0KEY2=value2\0\0"
        var env_block: std.ArrayListUnmanaged(u8) = .empty;
        defer env_block.deinit(self.allocator);

        const pane_id = @intFromPtr(self);
        var pane_id_buf: [32]u8 = undefined;
        const pane_id_str = try std.fmt.bufPrint(&pane_id_buf, "{d}", .{pane_id});

        try env_block.appendSlice(self.allocator, "HOLLOW_PANE_ID=");
        try env_block.appendSlice(self.allocator, pane_id_str);
        try env_block.append(self.allocator, 0);

        try env_block.appendSlice(self.allocator, "HOLLOW_TRANSPORT=auto");
        try env_block.append(self.allocator, 0);

        if (std.process.getEnvVarOwned(self.allocator, command_ipc.EnvVar)) |command_addr| {
            defer self.allocator.free(command_addr);
            try env_block.appendSlice(self.allocator, command_ipc.EnvVar ++ "=");
            try env_block.appendSlice(self.allocator, command_addr);
            try env_block.append(self.allocator, 0);
        } else |_| {}

        if (cfg.command_timing) {
            try env_block.appendSlice(self.allocator, command_ipc.TimingEnvVar ++ "=");
            try env_block.appendSlice(self.allocator, "1");
            try env_block.append(self.allocator, 0);
        }

        if (workspace_id) |id| {
            try env_block.appendSlice(self.allocator, "HOLLOW_WORKSPACE_ID=");
            try env_block.appendSlice(self.allocator, id);
            try env_block.append(self.allocator, 0);
        }

        try env_block.appendSlice(self.allocator, "TERM=xterm-256color");
        try env_block.append(self.allocator, 0);

        try env_block.appendSlice(self.allocator, "COLORTERM=truecolor");
        try env_block.append(self.allocator, 0);

        try env_block.appendSlice(self.allocator, "TERM_PROGRAM=ghostty");
        try env_block.append(self.allocator, 0);

        // Domain-specific environment variables
        const domain_env = cfg.envForDomain(domain_name);
        for (domain_env) |pair| {
            try env_block.appendSlice(self.allocator, pair.key);
            try env_block.append(self.allocator, '=');
            try env_block.appendSlice(self.allocator, pair.value);
            try env_block.append(self.allocator, 0);
        }

        try env_block.append(self.allocator, 0); // double-null terminator

        const home_dir = if (inherited_cwd == null and cfg.defaultCwdForDomain(domain_name) == null)
            std.process.getEnvVarOwned(self.allocator, if (comptime is_windows) "USERPROFILE" else "HOME") catch null
        else
            null;
        defer if (home_dir) |h| self.allocator.free(h);
        const launch_cwd = inherited_cwd orelse cfg.defaultCwdForDomain(domain_name) orelse home_dir;

        var is_remote = false;
        if (domain_name) |name| {
            if (cfg.domainByName(name)) |domain| {
                if (domain.ssh != null) is_remote = true;
            }
        }
        self.is_remote = is_remote;

        var pty = try @import("pty/pty.zig").spawn(self.allocator, shell, cfg.cols, cfg.rows, launch_cwd, env_block.items, launch_command);
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

        // Bootstrap locals own these resources until every fallible step succeeds.
        errdefer {
            self.terminal = null;
            self.render_state = null;
            self.row_iterator = null;
            self.row_cells = null;
            self.key_encoder = null;
            self.key_event = null;
            self.mouse_encoder = null;
            self.mouse_event = null;
            self.pty = null;
        }

        if (self.is_remote and launch_command == null) {
            if (inherited_cwd) |cwd| {
                const quoted_cwd = try shellQuoteSingle(self.allocator, cwd);
                defer self.allocator.free(quoted_cwd);
                self.pending_startup_input = try std.fmt.allocPrint(self.allocator, "cd -- {s} && clear\r", .{quoted_cwd});
                self.startup_input_quiet_ticks = 0;
            }
        }

        // Defer terminal resize/render-state initialization until the first
        // layout pass on the frame thread. `newTab()` is triggered from the sokol
        // event callback, and calling ghostty resize/update APIs here has been a
        // recurring source of null-deref crashes during tab creation.
        self.title = &.{};
        if (domain_name) |name| self.domain_name = try self.allocator.dupe(u8, name);
        if (launch_cwd) |cwd| self.setCwd(cwd);
        std.log.info("pane.bootstrap total_ms={d} domain={s} remote={any}", .{ std.time.milliTimestamp() - start_ms, domain_name orelse "", self.is_remote });
    }

    fn shellQuoteSingle(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
        var quoted = std.ArrayList(u8).empty;
        errdefer quoted.deinit(allocator);

        try quoted.append(allocator, '\'');
        for (value) |ch| {
            if (ch == '\'') {
                try quoted.appendSlice(allocator, "'\\''");
            } else {
                try quoted.append(allocator, ch);
            }
        }
        try quoted.append(allocator, '\'');
        return quoted.toOwnedSlice(allocator);
    }

    pub fn pollPty(self: *Pane, runtime: *GhosttyRuntime, max_read_loops: usize, max_total_read: usize, debug_overlay: bool) !void {
        if (self.pty) |*pty| {
            self.last_pty_read_ns = 0;
            self.last_terminal_write_ns = 0;
            self.last_has_pending_ns = 0;
            self.last_sanitize_ns = 0;
            self.last_child_alive_ns = 0;
            self.last_encoder_sync_ns = 0;
            self.last_terminal_write_bytes = 0;
            self.last_terminal_write_chunks = 0;
            if (self.render_state_ready) {
                self.terminal_write_batch.clearRetainingCapacity();
            }
            var total_read: usize = 0;
            var read_loops: usize = 0;
            while (read_loops < max_read_loops and total_read < max_total_read) {
                const read_start_ns = if (debug_overlay) std.time.nanoTimestamp() else 0;
                const count = pty.read(&self.read_buf) catch |err| {
                    if (err == error.EndOfStream) break;
                    return err;
                };
                if (debug_overlay) self.last_pty_read_ns += std.time.nanoTimestamp() - read_start_ns;
                if (count == 0) break;
                read_loops += 1;
                total_read += count;
                if (count > 0) {
                    if (!self.logged_first_pty_read) {
                        self.logged_first_pty_read = true;
                        std.log.info("first PTY bytes received count={d}", .{count});
                    }
                    const sanitize_start_ns = if (debug_overlay) std.time.nanoTimestamp() else 0;
                    const pty_bytes = self.sanitizePtyOutput(self.read_buf[0..count]);
                    if (debug_overlay) self.last_sanitize_ns += std.time.nanoTimestamp() - sanitize_start_ns;
                    if (pty_bytes.len > 0) {
                        if (self.render_state_ready) {
                            const has_deferred_output = self.pending_terminal_inject.items.len > 0 or self.boot_output.items.len > 0;
                            const has_more_output = pty.hasPendingOutput();
                            if (self.terminal_write_batch.items.len == 0 and !has_deferred_output and !has_more_output) {
                                const write_start_ns = if (debug_overlay) std.time.nanoTimestamp() else 0;
                                runtime.terminalWrite(self.terminal, pty_bytes);
                                if (debug_overlay) self.last_terminal_write_ns += std.time.nanoTimestamp() - write_start_ns;
                                self.last_terminal_write_bytes += pty_bytes.len;
                                self.last_terminal_write_chunks += 1;
                            } else {
                                try self.terminal_write_batch.appendSlice(self.allocator, pty_bytes);
                            }
                            self.pty_received_data = true;
                            self.pty_wrote_this_frame = true;
                        } else {
                            try self.boot_output.appendSlice(self.allocator, pty_bytes);
                        }
                    }
                    if (self.pending_terminal_inject.items.len > 0) {
                        if (self.render_state_ready) {
                            try self.terminal_write_batch.appendSlice(self.allocator, self.pending_terminal_inject.items);
                            self.pty_received_data = true;
                            self.pty_wrote_this_frame = true;
                        } else {
                            self.boot_output.appendSlice(self.allocator, self.pending_terminal_inject.items) catch {};
                        }
                        self.pending_terminal_inject.clearRetainingCapacity();
                    }
                }
            }
            if (self.render_state_ready and self.boot_output.items.len > 0) {
                try self.terminal_write_batch.appendSlice(self.allocator, self.boot_output.items);
                self.boot_output.clearRetainingCapacity();
                self.pty_received_data = true;
                self.pty_wrote_this_frame = true;
            }
            if (self.render_state_ready and self.terminal_write_batch.items.len > 0) {
                const write_start_ns = if (debug_overlay) std.time.nanoTimestamp() else 0;
                runtime.terminalWrite(self.terminal, self.terminal_write_batch.items);
                if (debug_overlay) self.last_terminal_write_ns += std.time.nanoTimestamp() - write_start_ns;
                self.last_terminal_write_bytes += self.terminal_write_batch.items.len;
                self.last_terminal_write_chunks += 1;
            }
            const child_alive_start_ns = if (debug_overlay) std.time.nanoTimestamp() else 0;
            self.refreshChildAliveCache(false);
            if (debug_overlay) self.last_child_alive_ns += std.time.nanoTimestamp() - child_alive_start_ns;
            if (self.pending_startup_input.len > 0 and self.logged_first_pty_read) {
                if (total_read == 0) {
                    self.startup_input_quiet_ticks +|= 1;
                } else {
                    self.startup_input_quiet_ticks = 0;
                }
                if (self.startup_input_quiet_ticks >= 1) {
                    pty.writeAll(self.pending_startup_input) catch |err| {
                        std.log.warn("pane: failed to send deferred startup input: {}", .{err});
                    };
                    self.allocator.free(self.pending_startup_input);
                    self.pending_startup_input = &.{};
                    self.startup_input_quiet_ticks = 0;
                }
            }
            // Only sync encoders when PTY activity occurred. Doing this every
            // idle tick still crosses the Ghostty FFI boundary and adds up.
            // Fresh terminal mode changes arrive via PTY output, and resize/
            // focus paths already perform their own explicit syncs.
            if (self.render_state_ready and total_read > 0) {
                const encoder_sync_start_ns = if (debug_overlay) std.time.nanoTimestamp() else 0;
                runtime.syncKeyEncoder(self.key_encoder, self.terminal);
                runtime.syncMouseEncoder(self.mouse_encoder, self.terminal);
                // Log mouse tracking state changes for diagnostics.
                var mouse_tracking: u32 = 0;
                const mt_result = runtime.terminal_get(self.terminal, @intFromEnum(ghostty.TerminalData.mouse_tracking), &mouse_tracking);
                if (mouse_tracking != self.last_mouse_tracking) {
                    std.log.info("pane mouse_tracking changed {d} -> {d} (get_result={d})", .{ self.last_mouse_tracking, mouse_tracking, mt_result });
                    self.last_mouse_tracking = mouse_tracking;
                }
                if (!self.mouse_tracking_logged_initial) {
                    self.mouse_tracking_logged_initial = true;
                    std.log.info("pane initial mouse_tracking={d} (get_result={d})", .{ mouse_tracking, mt_result });
                }

                {
                    var active_screen: u32 = 0;
                    const as_result = runtime.terminal_get(self.terminal, @intFromEnum(ghostty.TerminalData.active_screen), &active_screen);
                    if (active_screen != self.active_screen) {
                        std.log.info("pane active_screen changed {d} -> {d} (get_result={d})", .{ self.active_screen, active_screen, as_result });
                    }
                    self.active_screen = active_screen;
                }

                if (debug_overlay) self.last_encoder_sync_ns += std.time.nanoTimestamp() - encoder_sync_start_ns;

                const now_ns = std.time.nanoTimestamp();
                runtime.clearRenderStateDirty(self.render_state);
                runtime.updateRenderState(self.render_state, self.terminal) catch |err| {
                    std.log.err("pane updateRenderState after PTY drain failed: {s}", .{@errorName(err)});
                    return;
                };
                self.last_render_state_update_ns = now_ns;
                self.render_state_fresh = true;
            }
        }
    }

    pub fn sendText(self: *Pane, text: []const u8) void {
        if (self.pty) |*pty| {
            if (!pty.isAlive()) return;
            pty.writeAll(text) catch |err| {
                std.log.err("pane: sendText failed: {s}", .{@errorName(err)});
            };
        }
    }

    pub fn setCwd(self: *Pane, cwd: []const u8) void {
        if (self.cwd.len > 0) self.allocator.free(self.cwd);
        self.cwd = if (cwd.len > 0) self.allocator.dupe(u8, cwd) catch &.{} else &.{};
    }

    pub fn setManualTitle(self: *Pane, title: []const u8) void {
        if (self.title.len > 0) self.allocator.free(self.title);
        self.title = &.{};
        self.title_is_manual = false;

        if (title.len == 0) {
            self.title_dirty = true;
            return;
        }

        self.title = self.allocator.dupe(u8, title) catch &.{};
        self.title_is_manual = self.title.len > 0;
        self.title_dirty = false;
    }

    pub fn childPid(self: *const Pane) usize {
        if (self.pty) |pty| return pty.childPid();
        return 0;
    }

    pub fn setHtpMessageHandler(self: *Pane, handler: ?HtpMessageHandler) void {
        self.htp_message_handler = handler;
    }

    pub fn refreshCwd(self: *Pane) bool {
        var changed = false;
        if (self.cwd_dirty) {
            changed = true;
            self.cwd_dirty = false;
        }

        if (self.is_remote) return changed;
        if (is_windows) return changed;

        const pid = self.childPid();
        if (pid == 0) return changed;

        var proc_path_buf: [64]u8 = undefined;
        const proc_path = std.fmt.bufPrint(&proc_path_buf, "/proc/{d}/cwd", .{pid}) catch return changed;
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.readlink(proc_path, &cwd_buf) catch return changed;
        if (!std.mem.eql(u8, self.cwd, cwd)) {
            self.setCwd(cwd);
            changed = true;
        }
        return changed;
    }

    /// Resize the pane.
    ///
    /// When `skip_pty` is true (drag-preview mode) only the pixel geometry and
    /// render-dirty flag are updated — ghostty's terminal buffer, the ConPTY,
    /// and this pane's committed rows/cols stay at their current size. This
    /// avoids the rapid SIGWINCH storm that causes PSReadLine to leave
    /// ghost/duplicate prompt rows in the buffer (see
    /// https://github.com/microsoft/terminal/issues/15976).
    /// Pass `skip_pty = false` for the single authoritative resize that fires on
    /// divider_commit (mouse release), which sends exactly one SIGWINCH.
    pub fn resize(self: *Pane, runtime: *GhosttyRuntime, cols: u16, rows: u16, cell_width_px: u32, cell_height_px: u32, skip_pty: bool) void {
        const prev_cols = self.cols;
        const prev_rows = self.rows;

        if (skip_pty) {
            // Drag-preview: just mark dirty so the renderer redraws in the new
            // pixel bounds. Keep rows/cols authoritative so mouse release still
            // performs the real terminal resize when the preview grid changed.
            self.render_dirty = .full;
            return;
        }

        self.cols = cols;
        self.rows = rows;

        const same_grid = cols == prev_cols and rows == prev_rows;

        if (same_grid) {
            // Same-grid layout changes should stay a pure geometry/cache refresh.
            // Resizing the terminal/PTY here can trigger shell reflow or prompt
            // redraw glitches even though the terminal cell grid did not change.
            self.render_dirty = .full;
            runtime.syncKeyEncoder(self.key_encoder, self.terminal);
            runtime.syncMouseEncoder(self.mouse_encoder, self.terminal);
            return;
        }

        // Guard against null terminal — can happen if bootstrap partially failed
        // (e.g. PTY spawn error left self.terminal pointing at a freed handle).
        if (self.terminal) |terminal| {
            runtime.resizeTerminal(terminal, cols, rows, cell_width_px, cell_height_px);
        }
        runtime.updateRenderState(self.render_state, self.terminal) catch {};
        self.render_dirty = .full;
        runtime.syncKeyEncoder(self.key_encoder, self.terminal);
        runtime.syncMouseEncoder(self.mouse_encoder, self.terminal);
        if (self.pty) |*pty| {
            if (pty.isAlive()) {
                pty.resize(cols, rows);
            }
        }
    }

    /// Force a repaint by briefly bumping the terminal and PTY row count and then
    /// restoring it. This mirrors a user resize more closely than a PTY-only nudge.
    pub fn nudgeResize(self: *Pane, runtime: *GhosttyRuntime, cell_width_px: u32, cell_height_px: u32) void {
        if (self.cols == 0 or self.rows == 0) return;
        const bump_rows: u16 = if (self.rows > 1) self.rows - 1 else self.rows + 1;
        std.log.info("pane.nudgeResize: row-bump cols={d} rows={d}->{}->{}", .{ self.cols, self.rows, bump_rows, self.rows });
        if (self.terminal) |terminal| {
            runtime.resizeTerminal(terminal, self.cols, bump_rows, cell_width_px, cell_height_px);
            runtime.resizeTerminal(terminal, self.cols, self.rows, cell_width_px, cell_height_px);
        }
        runtime.updateRenderState(self.render_state, self.terminal) catch {};
        self.render_dirty = .full;
        runtime.syncKeyEncoder(self.key_encoder, self.terminal);
        runtime.syncMouseEncoder(self.mouse_encoder, self.terminal);
        if (self.pty) |*pty| {
            if (pty.isAlive()) {
                pty.resize(self.cols, bump_rows);
                pty.resize(self.cols, self.rows);
            }
        }
    }

    pub fn setMouseSize(
        self: *Pane,
        runtime: *GhosttyRuntime,
        screen_width: u32,
        screen_height: u32,
        cell_width_px: u32,
        cell_height_px: u32,
        padding_top: u32,
        padding_bottom: u32,
        padding_left: u32,
        padding_right: u32,
    ) void {
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
        runtime.setMouseEncoderTrackLastCell(self.mouse_encoder, false);
    }

    pub fn writeEscapeSequence(self: *Pane, sequence: []const u8) void {
        // Write an escape sequence to the PTY
        if (self.pty) |*pty| {
            pty.writeAll(sequence) catch |err| {
                std.log.warn("pane: writeEscapeSequence failed: {s}", .{@errorName(err)});
            };
        }
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

        // Free OLD objects, then immediately null out fields before assigning new ones.
        // If anything goes wrong between free and assign, fields are null (safe for deinit).
        runtime.freeRowCells(self.row_cells);
        self.row_cells = null;
        runtime.freeRowIterator(self.row_iterator);
        self.row_iterator = null;
        runtime.freeRenderState(self.render_state);
        self.render_state = null;

        self.render_state = new_render_state;
        self.row_iterator = new_row_iterator;
        self.row_cells = new_row_cells;
        // New render_state needs at least one updateRenderState before rendering.
        self.render_state_ready = false;
    }

    pub fn refreshTitle(self: *Pane, runtime: *GhosttyRuntime, fallback_title: []const u8, shell_command: []const u8) void {
        if (self.title_is_manual) {
            if (runtime.terminalTitle(self.allocator, self.terminal) catch null) |title| {
                self.allocator.free(title);
            }
            self.title_dirty = false;
            return;
        }

        if (self.title.len > 0) {
            self.allocator.free(self.title);
            self.title = &.{};
        }
        const maybe_title = runtime.terminalTitle(self.allocator, self.terminal) catch null;
        if (maybe_title) |title| {
            if (is_windows and shouldIgnoreWindowsShellTitle(title, shell_command, self.usesWslBypass())) {
                self.allocator.free(title);
            } else {
                self.title = title;
            }
        } else if (!is_windows) {
            self.title = self.allocator.dupe(u8, fallback_title) catch &.{};
        }
        self.syncRemoteCwdFromTitle();
        self.title_dirty = false;
    }

    pub fn usesWslBypass(self: *const Pane) bool {
        if (self.pty) |*pty| return @import("pty/pty.zig").usesWslBypass(pty);
        return false;
    }

    fn syncRemoteCwdFromTitle(self: *Pane) void {
        if (!self.is_remote or self.title.len == 0) return;

        const trimmed = std.mem.trim(u8, self.title, " \t\r\n");
        const derived = deriveRemotePathFromTitle(trimmed) orelse return;
        if (std.mem.eql(u8, self.cwd, derived)) return;

        self.setCwd(derived);
        self.cwd_dirty = true;
    }

    fn shouldIgnoreWindowsShellTitle(title: []const u8, shell_command: []const u8, wsl_bypass: bool) bool {
        const trimmed_title = std.mem.trim(u8, title, " \t\r\n");
        if (trimmed_title.len == 0) return false;

        if (wsl_bypass and isWslUncTitle(trimmed_title)) return true;

        const shell_program = shellProgram(shell_command);
        const shell_name = pathBasenameAny(shell_program);
        const title_name = pathBasenameAny(trimmed_title);

        if (shell_name.len > 0 and std.ascii.eqlIgnoreCase(trimmed_title, shell_name)) return true;
        if (shell_name.len > 0 and std.ascii.eqlIgnoreCase(title_name, shell_name)) return true;
        return isWindowsLauncherTitle(trimmed_title) or isWindowsLauncherTitle(title_name);
    }

    fn shellProgram(shell_command: []const u8) []const u8 {
        const trimmed = std.mem.trim(u8, shell_command, " \t\r\n");
        if (trimmed.len == 0) return trimmed;
        if (trimmed[0] == '"') {
            const rest = trimmed[1..];
            const end_quote = std.mem.indexOfScalar(u8, rest, '"') orelse return rest;
            return rest[0..end_quote];
        }
        const end = std.mem.indexOfAny(u8, trimmed, " \t\r\n") orelse trimmed.len;
        return trimmed[0..end];
    }

    fn pathBasenameAny(path: []const u8) []const u8 {
        const idx = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
        return path[idx + 1 ..];
    }

    fn isWindowsLauncherTitle(title: []const u8) bool {
        return std.ascii.eqlIgnoreCase(title, "wsl") or
            std.ascii.eqlIgnoreCase(title, "wsl.exe") or
            std.ascii.eqlIgnoreCase(title, "pwsh") or
            std.ascii.eqlIgnoreCase(title, "pwsh.exe") or
            std.ascii.eqlIgnoreCase(title, "powershell") or
            std.ascii.eqlIgnoreCase(title, "powershell.exe") or
            std.ascii.eqlIgnoreCase(title, "cmd") or
            std.ascii.eqlIgnoreCase(title, "cmd.exe");
    }

    fn isWslUncTitle(title: []const u8) bool {
        return std.ascii.startsWithIgnoreCase(title, "\\\\wsl.localhost\\") or
            std.ascii.startsWithIgnoreCase(title, "\\\\wsl$\\");
    }

    fn looksLikeAbsolutePath(value: []const u8) bool {
        if (value.len == 0) return false;
        if (value[0] == '/') return true;
        if (value.len >= 3 and std.ascii.isAlphabetic(value[0]) and value[1] == ':' and (value[2] == '\\' or value[2] == '/')) return true;
        if (std.mem.startsWith(u8, value, "\\\\")) return true;
        return false;
    }

    fn deriveRemotePathFromTitle(title: []const u8) ?[]const u8 {
        if (looksLikeAbsolutePath(title)) return title;

        const colon_idx = std.mem.lastIndexOfScalar(u8, title, ':') orelse return null;
        const suffix = std.mem.trim(u8, title[colon_idx + 1 ..], " \t\r\n");
        if (!looksLikeAbsolutePath(suffix)) return null;

        // Only accept a host prefix when it looks like the common ssh title form
        // user@host:/path, so regular titles with colons are ignored.
        const prefix = std.mem.trim(u8, title[0..colon_idx], " \t\r\n");
        if (prefix.len == 0) return null;
        if (std.mem.indexOfScalar(u8, prefix, '@') == null) return null;
        return suffix;
    }

    pub fn hasLiveChild(self: *Pane) bool {
        self.refreshChildAliveCache(false);
        return self.child_alive_cached;
    }

    fn refreshChildAliveCache(self: *Pane, force: bool) void {
        const pty = if (self.pty) |*value| value else {
            self.child_alive_cached = false;
            self.last_child_alive_check_ns = 0;
            return;
        };
        if (!self.child_alive_cached) return;
        const now_ns = std.time.nanoTimestamp();
        if (!force and self.last_child_alive_check_ns != 0 and now_ns - self.last_child_alive_check_ns < 1_000_000_000 and !pty.hasPendingOutputOrExit()) return;
        self.last_child_alive_check_ns = now_ns;
        self.child_alive_cached = pty.isAlive();
    }

    pub fn scrollbar(self: *const Pane) ghostty.TerminalScrollbar {
        return .{
            .total = self.scrollbar_total,
            .offset = self.scrollbar_offset,
            .len = self.scrollbar_len,
        };
    }

    fn sanitizePtyOutput(self: *Pane, bytes: []u8) []const u8 {
        return self.sanitizePtyOutputForPlatform(bytes, platform.isWindows());
    }

    fn sanitizePtyOutputForPlatform(self: *Pane, bytes: []u8, windows_mode: bool) []const u8 {
        const has_pending = windows_mode and self.pty_pending_len > 0;

        if (!has_pending) {
            return self.sanitizePtyOutputBytesForPlatform(bytes, windows_mode);
        }

        const pending = if (windows_mode) self.pty_pending_seq[0..self.pty_pending_len] else "";
        const input = CombinedInput{ .first = pending, .second = bytes };
        const enable = "\x1b[?9001h";
        const disable = "\x1b[?9001l";
        var read_idx: usize = 0;
        var write_idx: usize = 0;

        self.pty_pending_len = 0;

        while (read_idx < input.len()) {
            const byte = input.byteAt(read_idx);

            if (self.osc52_active) {
                if (self.osc52_st_pending) {
                    if (byte == '\\') {
                        self.finishOsc52Sequence();
                    } else {
                        self.appendOsc52Byte(0x1b);
                        self.appendOsc52Byte(byte);
                    }
                    self.osc52_st_pending = false;
                    read_idx += 1;
                    continue;
                }

                if (byte == 0x07) {
                    self.finishOsc52Sequence();
                    read_idx += 1;
                    continue;
                }
                if (byte == 0x1b) {
                    self.osc52_st_pending = true;
                    read_idx += 1;
                    continue;
                }

                self.appendOsc52Byte(byte);
                read_idx += 1;
                continue;
            }

            if (self.osc7_active) {
                if (self.osc7_st_pending) {
                    if (byte == '\\') {
                        self.finishOsc7Sequence();
                    } else {
                        self.appendOsc7Byte(0x1b);
                        self.appendOsc7Byte(byte);
                    }
                    self.osc7_st_pending = false;
                    read_idx += 1;
                    continue;
                }

                if (byte == 0x07) {
                    self.finishOsc7Sequence();
                    read_idx += 1;
                    continue;
                }
                if (byte == 0x1b) {
                    self.osc7_st_pending = true;
                    read_idx += 1;
                    continue;
                }

                self.appendOsc7Byte(byte);
                read_idx += 1;
                continue;
            }

            if (self.htp_osc_active) {
                if (self.htp_osc_st_pending) {
                    if (byte == '\\') {
                        self.finishHtpOscSequence();
                    } else {
                        self.appendHtpOscByte(0x1b);
                        self.appendHtpOscByte(byte);
                    }
                    self.htp_osc_st_pending = false;
                    read_idx += 1;
                    continue;
                }

                if (byte == 0x07) {
                    self.finishHtpOscSequence();
                    read_idx += 1;
                    continue;
                }
                if (byte == 0x1b) {
                    self.htp_osc_st_pending = true;
                    read_idx += 1;
                    continue;
                }

                self.appendHtpOscByte(byte);
                read_idx += 1;
                continue;
            }

            if (self.osc1337_active) {
                if (self.osc1337_st_pending) {
                    if (byte == '\\') {
                        self.finishOsc1337Sequence();
                    } else {
                        self.appendOsc1337Byte(0x1b);
                        self.appendOsc1337Byte(byte);
                    }
                    self.osc1337_st_pending = false;
                    read_idx += 1;
                    continue;
                }

                if (byte == 0x07) {
                    self.finishOsc1337Sequence();
                    read_idx += 1;
                    continue;
                }
                if (byte == 0x1b) {
                    self.osc1337_st_pending = true;
                    read_idx += 1;
                    continue;
                }

                self.appendOsc1337Byte(byte);
                read_idx += 1;
                continue;
            }

            if (self.osc_prefix_len > 0) {
                if (self.osc_prefix_len < self.osc_prefix_buf.len) {
                    self.osc_prefix_buf[self.osc_prefix_len] = byte;
                    self.osc_prefix_len += 1;
                    read_idx += 1;
                } else {
                    fastmem.copy(u8, self.pty_sanitize_buf[write_idx .. write_idx + self.osc_prefix_len], self.osc_prefix_buf[0..self.osc_prefix_len]);
                    write_idx += self.osc_prefix_len;
                    self.osc_prefix_len = 0;
                    continue;
                }

                const prefix = self.osc_prefix_buf[0..self.osc_prefix_len];
                switch (classifyOscPrefix(prefix)) {
                    .osc52 => {
                        self.osc52_active = true;
                        self.osc52_st_pending = false;
                        self.osc52_overflow = false;
                        self.osc52_len = 0;
                        self.osc_prefix_len = 0;
                        continue;
                    },
                    .osc7 => {
                        self.osc7_active = true;
                        self.osc7_st_pending = false;
                        self.osc7_len = 0;
                        self.osc_prefix_len = 0;
                        continue;
                    },
                    .htp => {
                        self.htp_osc_active = true;
                        self.htp_osc_st_pending = false;
                        self.htp_osc_overflow = false;
                        self.htp_osc_len = 0;
                        self.osc_prefix_len = 0;
                        continue;
                    },
                    .osc1337 => {
                        self.osc1337_active = true;
                        self.osc1337_st_pending = false;
                        self.osc1337_overflow = false;
                        self.osc1337_buf.clearRetainingCapacity();
                        if (prefix.len > OSC1337_PREFIX.len) {
                            self.osc1337_buf.appendSlice(self.allocator, prefix[OSC1337_PREFIX.len..]) catch {
                                self.osc1337_overflow = true;
                            };
                        }
                        self.osc_prefix_len = 0;
                        continue;
                    },
                    .partial => continue,
                    .none => {
                        fastmem.copy(u8, self.pty_sanitize_buf[write_idx .. write_idx + prefix.len], prefix);
                        write_idx += prefix.len;
                        self.osc_prefix_len = 0;
                        continue;
                    },
                }
            }

            const esc_idx = input.indexOfScalarPos(read_idx, 0x1b) orelse {
                input.copyRange(read_idx, input.len(), self.pty_sanitize_buf[0..], &write_idx);
                break;
            };
            if (esc_idx > read_idx) {
                input.copyRange(read_idx, esc_idx, self.pty_sanitize_buf[0..], &write_idx);
                read_idx = esc_idx;
            }

            const next = input.byteAtOrNull(read_idx + 1);
            if (next == null or next.? == ']') {
                self.osc_prefix_buf[0] = 0x1b;
                self.osc_prefix_len = 1;
                read_idx += 1;
                continue;
            }

            if (windows_mode) {
                if (input.startsWith(read_idx, enable)) {
                    read_idx += enable.len;
                    continue;
                }
                if (input.startsWith(read_idx, disable)) {
                    read_idx += disable.len;
                    continue;
                }
                if (next.? == '[') {
                    var j = read_idx + 2;
                    var is_csi_t = false;
                    while (j < input.len()) : (j += 1) {
                        const b = input.byteAt(j);
                        if (b >= 0x30 and b <= 0x3f) {
                            // parameter byte, keep scanning
                        } else if (b == 't') {
                            is_csi_t = true;
                            j += 1;
                            break;
                        } else {
                            break;
                        }
                    }
                    if (is_csi_t) {
                        read_idx = j;
                        continue;
                    }
                }
            }

            self.pty_sanitize_buf[write_idx] = 0x1b;
            write_idx += 1;
            read_idx += 1;
        }

        if (windows_mode) {
            const tail_len = trailingAnsiPrefixLen(self.pty_sanitize_buf[0..write_idx]);
            self.pty_pending_len = tail_len;
            if (tail_len > 0) {
                fastmem.copy(u8, self.pty_pending_seq[0..tail_len], self.pty_sanitize_buf[write_idx - tail_len .. write_idx]);
                write_idx -= tail_len;
            }
        }

        return self.pty_sanitize_buf[0..write_idx];
    }

    fn sanitizePtyOutputBytesForPlatform(self: *Pane, bytes: []u8, windows_mode: bool) []const u8 {
        const enable = "\x1b[?9001h";
        const disable = "\x1b[?9001l";
        var read_idx: usize = 0;
        var write_idx: usize = 0;
        const has_active_filter = self.osc52_active or self.osc7_active or self.osc1337_active or self.htp_osc_active or self.osc_prefix_len > 0;

        self.pty_pending_len = 0;

        if (!has_active_filter) {
            const first_esc = std.mem.indexOfScalar(u8, bytes, 0x1b) orelse return bytes;
            read_idx = first_esc;
            if (first_esc > 0) {
                const prefix = bytes[0..first_esc];
                fastmem.copy(u8, self.pty_sanitize_buf[0..prefix.len], prefix);
                write_idx = prefix.len;
            }
        }

        while (read_idx < bytes.len) {
            if (!self.osc52_active and !self.osc7_active and !self.osc1337_active and !self.htp_osc_active and self.osc_prefix_len == 0) {
                const esc_idx = std.mem.indexOfScalarPos(u8, bytes, read_idx, 0x1b) orelse {
                    const span = bytes[read_idx..];
                    fastmem.copy(u8, self.pty_sanitize_buf[write_idx .. write_idx + span.len], span);
                    write_idx += span.len;
                    break;
                };
                if (esc_idx > read_idx) {
                    const span = bytes[read_idx..esc_idx];
                    fastmem.copy(u8, self.pty_sanitize_buf[write_idx .. write_idx + span.len], span);
                    write_idx += span.len;
                    read_idx = esc_idx;
                }
            }

            const byte = bytes[read_idx];

            if (self.osc52_active) {
                if (self.osc52_st_pending) {
                    if (byte == '\\') {
                        self.finishOsc52Sequence();
                    } else {
                        self.appendOsc52Byte(0x1b);
                        self.appendOsc52Byte(byte);
                    }
                    self.osc52_st_pending = false;
                    read_idx += 1;
                    continue;
                }

                if (byte == 0x07) {
                    self.finishOsc52Sequence();
                    read_idx += 1;
                    continue;
                }
                if (byte == 0x1b) {
                    self.osc52_st_pending = true;
                    read_idx += 1;
                    continue;
                }

                self.appendOsc52Byte(byte);
                read_idx += 1;
                continue;
            }

            if (self.osc7_active) {
                if (self.osc7_st_pending) {
                    if (byte == '\\') {
                        self.finishOsc7Sequence();
                    } else {
                        self.appendOsc7Byte(0x1b);
                        self.appendOsc7Byte(byte);
                    }
                    self.osc7_st_pending = false;
                    read_idx += 1;
                    continue;
                }

                if (byte == 0x07) {
                    self.finishOsc7Sequence();
                    read_idx += 1;
                    continue;
                }
                if (byte == 0x1b) {
                    self.osc7_st_pending = true;
                    read_idx += 1;
                    continue;
                }

                self.appendOsc7Byte(byte);
                read_idx += 1;
                continue;
            }

            if (self.htp_osc_active) {
                if (self.htp_osc_st_pending) {
                    if (byte == '\\') {
                        self.finishHtpOscSequence();
                    } else {
                        self.appendHtpOscByte(0x1b);
                        self.appendHtpOscByte(byte);
                    }
                    self.htp_osc_st_pending = false;
                    read_idx += 1;
                    continue;
                }

                if (byte == 0x07) {
                    self.finishHtpOscSequence();
                    read_idx += 1;
                    continue;
                }
                if (byte == 0x1b) {
                    self.htp_osc_st_pending = true;
                    read_idx += 1;
                    continue;
                }

                self.appendHtpOscByte(byte);
                read_idx += 1;
                continue;
            }

            if (self.osc1337_active) {
                if (self.osc1337_st_pending) {
                    if (byte == '\\') {
                        self.finishOsc1337Sequence();
                    } else {
                        self.appendOsc1337Byte(0x1b);
                        self.appendOsc1337Byte(byte);
                    }
                    self.osc1337_st_pending = false;
                    read_idx += 1;
                    continue;
                }

                if (byte == 0x07) {
                    self.finishOsc1337Sequence();
                    read_idx += 1;
                    continue;
                }
                if (byte == 0x1b) {
                    self.osc1337_st_pending = true;
                    read_idx += 1;
                    continue;
                }

                self.appendOsc1337Byte(byte);
                read_idx += 1;
                continue;
            }

            if (self.osc_prefix_len > 0) {
                if (self.osc_prefix_len < self.osc_prefix_buf.len) {
                    self.osc_prefix_buf[self.osc_prefix_len] = byte;
                    self.osc_prefix_len += 1;
                    read_idx += 1;
                } else {
                    fastmem.copy(u8, self.pty_sanitize_buf[write_idx .. write_idx + self.osc_prefix_len], self.osc_prefix_buf[0..self.osc_prefix_len]);
                    write_idx += self.osc_prefix_len;
                    self.osc_prefix_len = 0;
                    continue;
                }

                const prefix = self.osc_prefix_buf[0..self.osc_prefix_len];
                switch (classifyOscPrefix(prefix)) {
                    .osc52 => {
                        self.osc52_active = true;
                        self.osc52_st_pending = false;
                        self.osc52_overflow = false;
                        self.osc52_len = 0;
                        self.osc_prefix_len = 0;
                        continue;
                    },
                    .osc7 => {
                        self.osc7_active = true;
                        self.osc7_st_pending = false;
                        self.osc7_len = 0;
                        self.osc_prefix_len = 0;
                        continue;
                    },
                    .htp => {
                        self.htp_osc_active = true;
                        self.htp_osc_st_pending = false;
                        self.htp_osc_overflow = false;
                        self.htp_osc_len = 0;
                        self.osc_prefix_len = 0;
                        continue;
                    },
                    .osc1337 => {
                        self.osc1337_active = true;
                        self.osc1337_st_pending = false;
                        self.osc1337_overflow = false;
                        self.osc1337_buf.clearRetainingCapacity();
                        if (prefix.len > OSC1337_PREFIX.len) {
                            self.osc1337_buf.appendSlice(self.allocator, prefix[OSC1337_PREFIX.len..]) catch {
                                self.osc1337_overflow = true;
                            };
                        }
                        self.osc_prefix_len = 0;
                        continue;
                    },
                    .partial => continue,
                    .none => {
                        fastmem.copy(u8, self.pty_sanitize_buf[write_idx .. write_idx + prefix.len], prefix);
                        write_idx += prefix.len;
                        self.osc_prefix_len = 0;
                        continue;
                    },
                }
            }

            if (byte == 0x1b) {
                const next = if (read_idx + 1 < bytes.len) bytes[read_idx + 1] else null;
                if (next == null or next.? == ']') {
                    self.osc_prefix_buf[0] = 0x1b;
                    self.osc_prefix_len = 1;
                    read_idx += 1;
                    continue;
                }

                if (windows_mode) {
                    if (std.mem.startsWith(u8, bytes[read_idx..], enable)) {
                        read_idx += enable.len;
                        continue;
                    }
                    if (std.mem.startsWith(u8, bytes[read_idx..], disable)) {
                        read_idx += disable.len;
                        continue;
                    }
                    if (next.? == '[') {
                        var j = read_idx + 2;
                        var is_csi_t = false;
                        while (j < bytes.len) : (j += 1) {
                            const b = bytes[j];
                            if (b >= 0x30 and b <= 0x3f) {
                                // parameter byte, keep scanning
                            } else if (b == 't') {
                                is_csi_t = true;
                                j += 1;
                                break;
                            } else {
                                break;
                            }
                        }
                        if (is_csi_t) {
                            read_idx = j;
                            continue;
                        }
                    }
                }
            }

            self.pty_sanitize_buf[write_idx] = byte;
            write_idx += 1;
            read_idx += 1;
        }

        if (windows_mode) {
            const tail_len = trailingAnsiPrefixLen(self.pty_sanitize_buf[0..write_idx]);
            self.pty_pending_len = tail_len;
            if (tail_len > 0) {
                fastmem.copy(u8, self.pty_pending_seq[0..tail_len], self.pty_sanitize_buf[write_idx - tail_len .. write_idx]);
                write_idx -= tail_len;
            }
        }

        return self.pty_sanitize_buf[0..write_idx];
    }

    fn filterOsc52(self: *Pane, bytes: []const u8) usize {
        var read_idx: usize = 0;
        var write_idx: usize = 0;

        while (read_idx < bytes.len) {
        if (!self.osc52_active and !self.osc7_active and !self.osc1337_active and !self.htp_osc_active and self.osc_prefix_len == 0) {
                const esc_idx = std.mem.indexOfScalarPos(u8, bytes, read_idx, 0x1b) orelse {
                    const span = bytes[read_idx..];
                    fastmem.copy(u8, self.pty_sanitize_buf[write_idx .. write_idx + span.len], span);
                    write_idx += span.len;
                    break;
                };
                if (esc_idx > read_idx) {
                    const span = bytes[read_idx..esc_idx];
                    fastmem.copy(u8, self.pty_sanitize_buf[write_idx .. write_idx + span.len], span);
                    write_idx += span.len;
                    read_idx = esc_idx;
                }
            }

            const byte = bytes[read_idx];

            if (self.osc52_active) {
                if (self.osc52_st_pending) {
                    if (byte == '\\') {
                        self.finishOsc52Sequence();
                    } else {
                        self.appendOsc52Byte(0x1b);
                        self.appendOsc52Byte(byte);
                    }
                    self.osc52_st_pending = false;
                    read_idx += 1;
                    continue;
                }

                if (byte == 0x07) {
                    self.finishOsc52Sequence();
                    read_idx += 1;
                    continue;
                }
                if (byte == 0x1b) {
                    self.osc52_st_pending = true;
                    read_idx += 1;
                    continue;
                }

                self.appendOsc52Byte(byte);
                read_idx += 1;
                continue;
            }

            if (self.osc7_active) {
                if (self.osc7_st_pending) {
                    if (byte == '\\') {
                        self.finishOsc7Sequence();
                    } else {
                        self.appendOsc7Byte(0x1b);
                        self.appendOsc7Byte(byte);
                    }
                    self.osc7_st_pending = false;
                    read_idx += 1;
                    continue;
                }

                if (byte == 0x07) {
                    self.finishOsc7Sequence();
                    read_idx += 1;
                    continue;
                }
                if (byte == 0x1b) {
                    self.osc7_st_pending = true;
                    read_idx += 1;
                    continue;
                }

                self.appendOsc7Byte(byte);
                read_idx += 1;
                continue;
            }

            if (self.htp_osc_active) {
                if (self.htp_osc_st_pending) {
                    if (byte == '\\') {
                        self.finishHtpOscSequence();
                    } else {
                        self.appendHtpOscByte(0x1b);
                        self.appendHtpOscByte(byte);
                    }
                    self.htp_osc_st_pending = false;
                    read_idx += 1;
                    continue;
                }

                if (byte == 0x07) {
                    self.finishHtpOscSequence();
                    read_idx += 1;
                    continue;
                }
                if (byte == 0x1b) {
                    self.htp_osc_st_pending = true;
                    read_idx += 1;
                    continue;
                }

                self.appendHtpOscByte(byte);
                read_idx += 1;
                continue;
            }

            if (self.osc1337_active) {
                if (self.osc1337_st_pending) {
                    if (byte == '\\') {
                        self.finishOsc1337Sequence();
                    } else {
                        self.appendOsc1337Byte(0x1b);
                        self.appendOsc1337Byte(byte);
                    }
                    self.osc1337_st_pending = false;
                    read_idx += 1;
                    continue;
                }

                if (byte == 0x07) {
                    self.finishOsc1337Sequence();
                    read_idx += 1;
                    continue;
                }
                if (byte == 0x1b) {
                    self.osc1337_st_pending = true;
                    read_idx += 1;
                    continue;
                }

                self.appendOsc1337Byte(byte);
                read_idx += 1;
                continue;
            }

            if (self.osc_prefix_len > 0 or byte == 0x1b) {
                if (self.osc_prefix_len == 0 and byte == 0x1b) {
                    self.osc_prefix_buf[0] = byte;
                    self.osc_prefix_len = 1;
                    read_idx += 1;
                    continue;
                }

                if (self.osc_prefix_len < self.osc_prefix_buf.len) {
                    self.osc_prefix_buf[self.osc_prefix_len] = byte;
                    self.osc_prefix_len += 1;
                    read_idx += 1;
                } else {
                    fastmem.copy(u8, self.pty_sanitize_buf[write_idx .. write_idx + self.osc_prefix_len], self.osc_prefix_buf[0..self.osc_prefix_len]);
                    write_idx += self.osc_prefix_len;
                    self.osc_prefix_len = 0;
                    continue;
                }

                const prefix = self.osc_prefix_buf[0..self.osc_prefix_len];
                switch (classifyOscPrefix(prefix)) {
                    .osc52 => {
                        self.osc52_active = true;
                        self.osc52_st_pending = false;
                        self.osc52_overflow = false;
                        self.osc52_len = 0;
                        self.osc_prefix_len = 0;
                        continue;
                    },
                    .osc7 => {
                        self.osc7_active = true;
                        self.osc7_st_pending = false;
                        self.osc7_len = 0;
                        self.osc_prefix_len = 0;
                        continue;
                    },
                    .htp => {
                        self.htp_osc_active = true;
                        self.htp_osc_st_pending = false;
                        self.htp_osc_overflow = false;
                        self.htp_osc_len = 0;
                        self.osc_prefix_len = 0;
                        continue;
                    },
                    .osc1337 => {
                        self.osc1337_active = true;
                        self.osc1337_st_pending = false;
                        self.osc1337_overflow = false;
                        self.osc1337_buf.clearRetainingCapacity();
                        if (prefix.len > OSC1337_PREFIX.len) {
                            self.osc1337_buf.appendSlice(self.allocator, prefix[OSC1337_PREFIX.len..]) catch {
                                self.osc1337_overflow = true;
                            };
                        }
                        self.osc_prefix_len = 0;
                        continue;
                    },
                    .partial => continue,
                    .none => {
                        fastmem.copy(u8, self.pty_sanitize_buf[write_idx .. write_idx + prefix.len], prefix);
                        write_idx += prefix.len;
                        self.osc_prefix_len = 0;
                        continue;
                    },
                }
            }

            self.pty_sanitize_buf[write_idx] = byte;
            write_idx += 1;
            read_idx += 1;
        }

        return write_idx;
    }

    fn appendOsc52Byte(self: *Pane, byte: u8) void {
        if (self.osc52_len >= self.osc52_buf.len) {
            self.osc52_overflow = true;
            return;
        }
        self.osc52_buf[self.osc52_len] = byte;
        self.osc52_len += 1;
    }

    fn appendOsc7Byte(self: *Pane, byte: u8) void {
        if (self.osc7_len >= self.osc7_buf.len) {
            // Overflow: just stop collecting, sequence will be terminated by BEL/ST
            return;
        }
        self.osc7_buf[self.osc7_len] = byte;
        self.osc7_len += 1;
    }

    fn appendHtpOscByte(self: *Pane, byte: u8) void {
        if (self.htp_osc_len >= self.htp_osc_buf.len) {
            self.htp_osc_overflow = true;
            return;
        }
        self.htp_osc_buf[self.htp_osc_len] = byte;
        self.htp_osc_len += 1;
    }

    fn appendOsc1337Byte(self: *Pane, byte: u8) void {
        if (self.osc1337_buf.items.len >= OSC1337_SEQUENCE_MAX) {
            self.osc1337_overflow = true;
            return;
        }
        self.osc1337_buf.append(self.allocator, byte) catch {
            self.osc1337_overflow = true;
        };
    }

    fn finishOsc52Sequence(self: *Pane) void {
        if (!self.osc52_overflow and self.osc52_len > 0) {
            self.applyOsc52Clipboard(self.osc52_buf[0..self.osc52_len]);
        }
        self.osc52_active = false;
        self.osc52_st_pending = false;
        self.osc52_overflow = false;
        self.osc52_len = 0;
    }

    fn finishOsc7Sequence(self: *Pane) void {
        if (self.osc7_len > 0) {
            self.applyOsc7Cwd(self.osc7_buf[0..self.osc7_len]);
        }
        self.osc7_active = false;
        self.osc7_st_pending = false;
        self.osc7_len = 0;
    }

    fn finishHtpOscSequence(self: *Pane) void {
        if (!self.htp_osc_overflow and self.htp_osc_len > 0) {
            const payload = self.htp_osc_buf[0..self.htp_osc_len];
            std.log.info("htp: received osc pane={x} payload={s}", .{ @intFromPtr(self), payload });
            if (self.htp_message_handler) |handler| handler(self, payload);
        } else if (self.htp_osc_overflow) {
            std.log.warn("htp: dropped oversized osc pane={x} bytes={d}", .{ @intFromPtr(self), self.htp_osc_len });
        }
        self.htp_osc_active = false;
        self.htp_osc_st_pending = false;
        self.htp_osc_overflow = false;
        self.htp_osc_len = 0;
    }

    fn finishOsc1337Sequence(self: *Pane) void {
        if (!self.osc1337_overflow and self.osc1337_buf.items.len > 0) {
            self.applyOsc1337Sequence(self.osc1337_buf.items);
        }
        self.osc1337_active = false;
        self.osc1337_st_pending = false;
        self.osc1337_overflow = false;
        self.osc1337_buf.clearRetainingCapacity();
    }

    fn applyOsc52Clipboard(self: *Pane, payload: []const u8) void {
        _ = self;
        const sep = std.mem.indexOfScalar(u8, payload, ';') orelse return;
        const data = payload[sep + 1 ..];
        if (std.mem.eql(u8, data, "?")) return;

        var decoded_buf: [OSC52_DECODED_MAX + 1]u8 = undefined;
        const decoded = decodeOsc52Base64(data, decoded_buf[0..OSC52_DECODED_MAX]) catch return;

        const nul_pos = std.mem.indexOfScalar(u8, decoded, 0) orelse decoded.len;
        decoded_buf[nul_pos] = 0;
        c.sapp_set_clipboard_string(@ptrCast(decoded_buf[0..nul_pos :0].ptr));
    }

    fn applyOsc7Cwd(self: *Pane, payload: []const u8) void {
        var path = payload;
        if (std.mem.startsWith(u8, path, "cwd;")) {
            path = path[4..];
        }
        if (std.mem.startsWith(u8, path, "file://")) {
            path = path[7..];
            if (std.mem.indexOfScalar(u8, path, '/')) |idx| {
                path = path[idx..];
            }
        }
        std.log.info("pane: received OSC 7 cwd: {s}", .{path});
        self.setCwd(path);
        self.cwd_dirty = true;
    }

    fn applyOsc1337Sequence(self: *Pane, payload: []const u8) void {
        if (!std.mem.startsWith(u8, payload, "File=")) return;

        const colon_idx = std.mem.indexOfScalar(u8, payload, ':') orelse return;
        const meta = payload[0..colon_idx];
        const data = payload[colon_idx + 1 ..];
        if (data.len == 0) return;
        if (std.mem.indexOf(u8, meta, "inline=1") == null) return;

        var width_cells: ?u32 = null;
        var height_cells: ?u32 = null;
        var iter = std.mem.splitScalar(u8, meta, ';');
        while (iter.next()) |part| {
            if (std.mem.startsWith(u8, part, "width=")) {
                width_cells = parseOsc1337CellSize(part[6..]);
            } else if (std.mem.startsWith(u8, part, "height=")) {
                height_cells = parseOsc1337CellSize(part[7..]);
            }
        }

        self.pending_terminal_inject.clearRetainingCapacity();
        self.pending_terminal_inject.appendSlice(self.allocator, "\x1b_Ga=T,f=100,q=2") catch return;
        if (width_cells) |cols| {
            const value = std.fmt.allocPrint(self.allocator, ",c={d}", .{cols}) catch return;
            defer self.allocator.free(value);
            self.pending_terminal_inject.appendSlice(self.allocator, value) catch return;
        }
        if (height_cells) |rows| {
            const value = std.fmt.allocPrint(self.allocator, ",r={d}", .{rows}) catch return;
            defer self.allocator.free(value);
            self.pending_terminal_inject.appendSlice(self.allocator, value) catch return;
        }
        self.pending_terminal_inject.append(self.allocator, ';') catch return;
        self.pending_terminal_inject.appendSlice(self.allocator, data) catch return;
        self.pending_terminal_inject.appendSlice(self.allocator, "\x1b\\") catch return;
    }
};

fn parseOsc1337CellSize(value: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    for (trimmed, 0..) |ch, idx| {
        if (ch < '0' or ch > '9') {
            if (idx == 0) return null;
            return std.fmt.parseInt(u32, trimmed[0..idx], 10) catch null;
        }
    }
    return std.fmt.parseInt(u32, trimmed, 10) catch null;
}

fn decodeOsc52Base64(data: []const u8, out: []u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, data, '=')) |_| {
        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(data);
        if (decoded_len > out.len) return error.NoSpaceLeft;
        try std.base64.standard.Decoder.decode(out[0..decoded_len], data);
        return out[0..decoded_len];
    }

    const decoded_len = try std.base64.standard_no_pad.Decoder.calcSizeForSlice(data);
    if (decoded_len > out.len) return error.NoSpaceLeft;
    try std.base64.standard_no_pad.Decoder.decode(out[0..decoded_len], data);
    return out[0..decoded_len];
}

fn trailingAnsiPrefixLen(bytes: []const u8) usize {
    const window = @min(bytes.len, 32);
    var start = bytes.len - window;
    while (start < bytes.len) : (start += 1) {
        if (bytes[start] != 0x1b) continue;
        const suffix = bytes[start..];
        if (suffix.len == 1) return 1;

        switch (suffix[1]) {
            '[' => {
                if (suffix.len == 2) return 2;
                var i: usize = 2;
                while (i < suffix.len) : (i += 1) {
                    const b = suffix[i];
                    if (b >= 0x40 and b <= 0x7e) break;
                    if (b < 0x20 or b > 0x3f) return 0;
                }
                if (i == suffix.len) return suffix.len;
            },
            ']' => {
                var i: usize = 2;
                while (i < suffix.len) : (i += 1) {
                    const b = suffix[i];
                    if (b == 0x07) return 0;
                    if (b == 0x1b and i + 1 < suffix.len and suffix[i + 1] == '\\') return 0;
                }
                return suffix.len;
            },
            else => return 0,
        }
    }
    return 0;
}

test "sanitizePtyOutput windows strips split 9001 mode sequence" {
    var pane = Pane.init(std.testing.allocator);
    defer if (pane.cwd.len > 0) std.testing.allocator.free(pane.cwd);

    var part1 = [_]u8{ 0x1b, '[', '?', '9' };
    const out1 = pane.sanitizePtyOutputForPlatform(part1[0..], true);
    try std.testing.expectEqual(@as(usize, 0), out1.len);
    try std.testing.expectEqual(@as(usize, 4), pane.pty_pending_len);

    var part2 = [_]u8{ '0', '0', '1', 'h', 'A' };
    const out2 = pane.sanitizePtyOutputForPlatform(part2[0..], true);
    try std.testing.expectEqualStrings("A", out2);
    try std.testing.expectEqual(@as(usize, 0), pane.pty_pending_len);
}

test "sanitizePtyOutput windows strips split csi t sequence" {
    var pane = Pane.init(std.testing.allocator);
    defer if (pane.cwd.len > 0) std.testing.allocator.free(pane.cwd);

    var part1 = [_]u8{ 'x', 0x1b, '[', '8', ';' };
    const out1 = pane.sanitizePtyOutputForPlatform(part1[0..], true);
    try std.testing.expectEqualStrings("x", out1);
    try std.testing.expectEqual(@as(usize, 4), pane.pty_pending_len);

    var part2 = [_]u8{ '2', '4', 't', 'y' };
    const out2 = pane.sanitizePtyOutputForPlatform(part2[0..], true);
    try std.testing.expectEqualStrings("y", out2);
    try std.testing.expectEqual(@as(usize, 0), pane.pty_pending_len);
}

test "sanitizePtyOutput preserves split OSC 7 state across chunks" {
    var pane = Pane.init(std.testing.allocator);
    defer if (pane.cwd.len > 0) std.testing.allocator.free(pane.cwd);

    var part1 = [_]u8{ 0x1b, ']', '7', ';', 'f', 'i', 'l', 'e', ':', '/', '/' };
    const out1 = pane.sanitizePtyOutputForPlatform(part1[0..], false);
    try std.testing.expectEqual(@as(usize, 0), out1.len);
    try std.testing.expect(pane.osc7_active);

    var part2 = [_]u8{ '/', 't', 'm', 'p', 0x07, 'Z' };
    const out2 = pane.sanitizePtyOutputForPlatform(part2[0..], false);
    try std.testing.expectEqualStrings("Z", out2);
    try std.testing.expectEqualStrings("/tmp", pane.cwd);
    try std.testing.expect(pane.cwd_dirty);
}

test "setManualTitle preserves override until cleared" {
    var pane = Pane.init(std.testing.allocator);
    defer if (pane.title.len > 0) std.testing.allocator.free(pane.title);

    pane.setManualTitle("editor");
    try std.testing.expect(pane.title_is_manual);
    try std.testing.expectEqualStrings("editor", pane.title);
    try std.testing.expect(!pane.title_dirty);

    pane.setManualTitle("");
    try std.testing.expect(!pane.title_is_manual);
    try std.testing.expectEqual(@as(usize, 0), pane.title.len);
    try std.testing.expect(pane.title_dirty);
}

test "shouldIgnoreWindowsShellTitle ignores stale wsl unc titles" {
    try std.testing.expect(Pane.shouldIgnoreWindowsShellTitle("\\\\wsl.localhost\\Ubuntu\\home\\francis", "zsh", true));
    try std.testing.expect(Pane.shouldIgnoreWindowsShellTitle("\\\\wsl$\\Ubuntu\\home\\francis", "zsh", true));
    try std.testing.expect(!Pane.shouldIgnoreWindowsShellTitle("\\\\wsl.localhost\\Ubuntu\\home\\francis", "zsh", false));
}
