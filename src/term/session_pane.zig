//! Session-specific terminal lifecycle. No workspace policy or network waits.
const std = @import("std");
const io = @import("../io.zig");
const ghostty = @import("ghostty.zig");
const TerminalPane = @import("terminal_pane.zig").TerminalPane;
const Pane = @import("../pane.zig").Pane;
const Config = @import("../config.zig").Config;
const SessionPty = @import("../pty/session.zig").SessionPty;
const Job = @import("session_snapshot_job.zig").Job;
const p = @import("../agent/session_protocol.zig");

pub fn bootstrap(term: *TerminalPane, node: *Pane, runtime: *ghostty.Runtime, callbacks: ghostty.TerminalCallbacks, cfg: Config, pty: SessionPty) !void {
    if (term.pty != null or term.terminal != null) return error.CannotConvertLivePane;
    const terminal = (try runtime.createTerminal(cfg.cols, cfg.rows, cfg.scrollback)).?;
    errdefer runtime.freeTerminal(terminal);
    runtime.setTerminalDefaultColors(terminal, cfg.terminal_theme.foreground, cfg.terminal_theme.background, cfg.terminal_theme.cursor, &cfg.terminal_theme.palette);
    try replaceTerminal(term, node, runtime, callbacks, terminal);
    term.pty = .{ .session = pty };
    term.session_callbacks = callbacks;
    term.session_scrollback = cfg.scrollback;
    term.synchronized_output_enabled = cfg.synchronized_output;
    term.retain_on_exit = true;
    term.is_remote = true;
    term.child_alive_cached = pty.status == null;
}

/// After an accepted respawn: the owner restarted the process under the same
/// screen, so only liveness and exit bookkeeping reset.
pub fn revive(term: *TerminalPane, node: *Pane) void {
    if (term.pty) |*pty| if (pty.* == .session) {
        pty.session.status = null;
    };
    term.child_alive_cached = true;
    term.last_child_alive_check_ns = 0;
    term.exit_event_emitted = false;
    node.invalidate();
}

pub fn beginSnapshot(term: *TerminalPane, node: *Pane, format: p.SnapshotFormat) !void {
    if (term.session_callbacks == null) return error.NotSessionPane;
    // Construct before abandoning the old job; failed admission preserves the
    // existing terminal and any pending history decode.
    const job = try Job.create(node.allocator, io.get(), format, node.cols, node.rows, term.session_scrollback, term.host_wake);
    if (term.session_snapshot) |old| old.destroy();
    term.session_snapshot = job;
    term.session_snapshot_waiting = true;
}

pub fn pollSnapshot(term: *TerminalPane, node: *Pane, runtime: *ghostty.Runtime) !void {
    const job = term.session_snapshot orelse return;
    errdefer if (term.session_snapshot == job) {
        job.destroy();
        term.session_snapshot = null;
    };
    if (job.takeReady()) |terminal| {
        replaceTerminal(term, node, runtime, term.session_callbacks.?, terminal) catch |err| {
            // Free the borrowing decoder before its not-yet-installed terminal.
            job.destroy();
            term.session_snapshot = null;
            runtime.freeTerminal(terminal);
            return err;
        };
        term.session_snapshot_waiting = false;
    }
    const progress = try job.nextHistory() orelse return;
    if (progress) {
        term.render_state_fresh = false;
        term.pty_received_data = true;
        term.viewport_scroll_pending = true;
        node.invalidate();
    } else {
        job.destroy();
        term.session_snapshot = null;
    }
}

/// Fallible transaction: allocate/render against the new terminal before
/// releasing any old terminal-bound helpers. Caller owns terminal on failure.
pub fn replaceTerminal(term: *TerminalPane, node: *Pane, runtime: *ghostty.Runtime, callbacks: ghostty.TerminalCallbacks, terminal: *anyopaque) !void {
    if (term.terminal == terminal) return error.AlreadyInstalled;
    if (term.pty) |pty| if (pty != .session) return error.CannotConvertLivePane;
    runtime.setTerminalUserdata(terminal, node);
    runtime.registerCallbacks(terminal, callbacks);
    if (node.cols > 0 and node.rows > 0) runtime.resizeTerminal(terminal, node.cols, node.rows, 0, 0);
    const render_state = try runtime.createRenderState();
    errdefer runtime.freeRenderState(render_state);
    const row_iterator = try runtime.createRowIterator();
    errdefer runtime.freeRowIterator(row_iterator);
    const row_cells = try runtime.createRowCells();
    errdefer runtime.freeRowCells(row_cells);
    var input = try TerminalPane.initInput(runtime, terminal);
    errdefer input.deinitInput(runtime);
    try runtime.updateRenderState(render_state, terminal);

    if (term.terminal != null) if (term.session_before_replace) |callback| callback(node);
    term.deinitInput(runtime);
    term.releaseRenderHelpers(runtime);
    runtime.setTerminalUserdata(term.terminal, null);
    runtime.freeTerminal(term.terminal);
    term.terminal_runtime = runtime;
    term.terminal = terminal;
    term.render_state = render_state;
    term.row_iterator = row_iterator;
    term.row_cells = row_cells;
    term.key_encoder = input.key_encoder;
    term.key_event = input.key_event;
    term.mouse_encoder = input.mouse_encoder;
    term.mouse_event = input.mouse_event;
    term.render_state_ready = true;
    term.terminal_output_ready = true;
    term.render_state_fresh = false;
    term.last_render_state_update_ns = 0;
    term.viewport_scroll_pending = true;
    term.pty_received_data = true;
    term.pty_wrote_this_frame = true;
    term.image_storage_generation = 0;
    term.image_animation_deadline_ns = 0;
    term.compression_activity = null;
    term.compression_deadline_ns = 0;
    term.pending_alt_screen_nudge = false;
    term.alt_screen_nudge_quiet_ticks = 0;
    term.alt_screen_nudge_not_before_ns = 0;
    term.clipboard_read.revoke(node.allocator);
    if (term.pending_cwd) |cwd| node.allocator.free(cwd);
    term.pending_cwd = null;
    term.boot_output.clearRetainingCapacity();
    term.pending_terminal_inject.clearRetainingCapacity();
    // Old client-side sanitizer state must not leak across resync. Ghostty's
    // unfinished VT parser state is already part of the restored terminal.
    term.pty_pending_len = 0;
    term.osc_prefix_len = 0;
    term.osc99_active = false;
    term.osc99_st_pending = false;
    term.osc99_overflow = false;
    term.osc99_buf.clearRetainingCapacity();
    term.osc1337_active = false;
    term.osc1337_st_pending = false;
    term.osc1337_overflow = false;
    term.osc1337_buf.clearRetainingCapacity();
    term.htp_osc_active = false;
    term.htp_osc_st_pending = false;
    term.htp_osc_overflow = false;
    term.htp_osc_len = 0;
    term.active_screen = @backingInt(runtime.terminalActiveScreen(terminal));
    term.synchronized_output_active = runtime.terminalMode(terminal, .synchronized_output);
    term.synchronized_output_started_ns = if (term.synchronized_output_active) io.nanoTimestamp() else 0;
    term.syncInput(runtime, terminal);
    _ = runtime.terminal_get(terminal, @backingInt(ghostty.TerminalData.cols), &node.cols);
    _ = runtime.terminal_get(terminal, @backingInt(ghostty.TerminalData.rows), &node.rows);
    node.title_dirty = !node.title_is_manual;
    callbacks.title_changed(terminal, node);
    if (callbacks.pwd_changed) |callback| callback(terminal, node);
    node.invalidate();
}
