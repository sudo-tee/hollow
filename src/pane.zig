const std = @import("std");
const c = @import("sokol_c");
const Config = @import("config.zig").Config;
const GhosttyRuntime = @import("term/ghostty.zig").Runtime;
const ghostty = @import("term/ghostty.zig");
const TerminalCallbacks = ghostty.TerminalCallbacks;
const Pty = @import("pty/pty.zig").Pty;
const LaunchCommand = @import("pty/launch_command.zig").LaunchCommand;
const platform = @import("platform.zig");

const is_windows = @import("builtin").os.tag == .windows;

const OSC52_PREFIX = "\x1b]52;";
const OSC7_PREFIX = "\x1b]7;";
const OSC52_SEQUENCE_MAX = 65536;
const OSC52_DECODED_MAX = OSC52_SEQUENCE_MAX / 4 * 3 + 4;

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
    read_buf: [65536]u8 = [_]u8{0} ** 65536,
    logged_first_pty_read: bool = false,
    pty_pending_seq: [8]u8 = [_]u8{0} ** 8,
    pty_pending_len: usize = 0,
    pty_sanitize_buf: [65544]u8 = [_]u8{0} ** 65544,
    osc52_prefix_len: usize = 0,
    osc52_active: bool = false,
    osc52_st_pending: bool = false,
    osc52_overflow: bool = false,
    osc52_buf: [OSC52_SEQUENCE_MAX]u8 = [_]u8{0} ** OSC52_SEQUENCE_MAX,
    osc52_len: usize = 0,
    osc_prefix_len: usize = 0,
    osc7_active: bool = false,
    osc7_st_pending: bool = false,
    osc7_buf: [1024]u8 = [_]u8{0} ** 1024,
    osc7_len: usize = 0,
    boot_output: std.ArrayListUnmanaged(u8) = .empty,
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
    /// Monotonic nanosecond timestamp of the last updateRenderState call on this
    /// pane.  Used to throttle the cursor-blink / idle poll: even with no PTY
    /// data we call updateRenderState at most once per ~16 ms so that cursor
    /// blink (managed by ghostty's internal timer) still fires.
    last_render_state_update_ns: i128 = 0,
    scrollbar_total: u64 = 0,
    scrollbar_offset: u64 = 0,
    scrollbar_len: u64 = 0,
    title_dirty: bool = false,
    x_px: u32 = 0,
    y_px: u32 = 0,
    width_px: u32 = 0,
    height_px: u32 = 0,
    domain_name: []u8 = &.{},
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
        if (self.domain_name.len > 0) self.allocator.free(self.domain_name);
        self.* = Pane.init(self.allocator);
    }

    pub fn bootstrap(self: *Pane, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32, inherited_cwd: ?[]const u8, domain_name: ?[]const u8, launch_command: ?LaunchCommand) !void {
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

        // Register callbacks immediately — before any ghostty call that might
        // invoke them (resizeTerminal, updateRenderState).  A freshly created
        // terminal has null slots for all callbacks; calling into ghostty before
        // these are set causes a null-function-pointer segfault.
        runtime.registerCallbacks(terminal, callbacks);

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

        const base_dir = platform.ensureHollowRuntimeDir(self.allocator) catch null;
        if (base_dir) |dir| {
            defer self.allocator.free(dir);
            const htp_dir = std.fs.path.join(self.allocator, &.{ dir, "htp-requests" }) catch null;
            if (htp_dir) |hdir| {
                defer self.allocator.free(hdir);
                // Ensure the htp-requests directory exists
                std.fs.makeDirAbsolute(hdir) catch |err| {
                    if (err != error.PathAlreadyExists) std.log.warn("failed to create htp-requests dir: {}", .{err});
                };
                // On Windows, pass the raw Windows path (e.g. C:\...\htp-requests).
                // WSLENV with /p flag will translate it to /mnt/c/... for WSL automatically.
                // Do NOT pre-convert the path — that would double-convert it.
                try env_block.appendSlice(self.allocator, "HOLLOW_REQUEST_DIR=");
                try env_block.appendSlice(self.allocator, hdir);
                try env_block.append(self.allocator, 0);
            }
        }

        try env_block.append(self.allocator, 0); // double-null terminator

        var pty = try @import("pty/pty.zig").spawn(self.allocator, shell, cfg.cols, cfg.rows, inherited_cwd, env_block.items, launch_command);
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

        // If anything below fails, null out fields so deinit() doesn't double-free.
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

        // Defer terminal resize/render-state initialization until the first
        // layout pass on the frame thread. `newTab()` is triggered from the sokol
        // event callback, and calling ghostty resize/update APIs here has been a
        // recurring source of null-deref crashes during tab creation.
        self.title = &.{};
        if (domain_name) |name| self.domain_name = try self.allocator.dupe(u8, name);
        if (inherited_cwd) |cwd| self.setCwd(cwd);
    }

    pub fn pollPty(self: *Pane, runtime: *GhosttyRuntime) !void {
        if (self.pty) |*pty| {
            if (self.render_state_ready and self.boot_output.items.len > 0) {
                std.log.info("pollPty: flushing boot_output len={d}", .{self.boot_output.items.len});
                runtime.terminalWrite(self.terminal, self.boot_output.items);
                self.boot_output.clearRetainingCapacity();
            }
            var total_read: usize = 0;
            var read_loops: usize = 0;
            while ((pty.isAlive() or pty.hasPendingOutput()) and read_loops < 64 and total_read < (1024 * 1024)) {
                const count = pty.read(&self.read_buf) catch |err| {
                    if (err == error.EndOfStream) break;
                    return err;
                };
                if (count == 0) break;
                read_loops += 1;
                total_read += count;
                if (count > 0) {
                    if (!self.logged_first_pty_read) {
                        self.logged_first_pty_read = true;
                        std.log.info("first PTY bytes received count={d}", .{count});
                    }
                    const pty_bytes = self.sanitizePtyOutput(self.read_buf[0..count]);
                    if (!self.render_state_ready) {
                        if (pty_bytes.len > 0) try self.boot_output.appendSlice(self.allocator, pty_bytes);
                        continue;
                    }
                    if (pty_bytes.len > 0) {
                        std.log.info("pollPty: received bytes len={d} first_byte={x}", .{ pty_bytes.len, pty_bytes[0] });
                        std.log.info("pollPty: terminalWrite len={d}", .{pty_bytes.len});
                        runtime.terminalWrite(self.terminal, pty_bytes);
                        std.log.info("pollPty: terminalWrite done", .{});
                        self.pty_received_data = true;
                        self.pty_wrote_this_frame = true;
                    }
                }
            }
            // Only sync encoders once the pane is fully initialised — these
            // read mode flags from the terminal object and can crash on a
            // terminal that has never been through updateRenderState.
            if (self.render_state_ready) {
                std.log.info("pollPty: syncKeyEncoder", .{});
                runtime.syncKeyEncoder(self.key_encoder, self.terminal);
                std.log.info("pollPty: syncMouseEncoder", .{});
                runtime.syncMouseEncoder(self.mouse_encoder, self.terminal);
                std.log.info("pollPty: sync done", .{});
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

    pub fn childPid(self: *const Pane) usize {
        if (self.pty) |pty| return pty.childPid();
        return 0;
    }

    pub fn refreshCwd(self: *Pane) bool {
        if (is_windows) return false;
        const pid = self.childPid();
        if (pid == 0) return false;

        var proc_path_buf: [64]u8 = undefined;
        const proc_path = std.fmt.bufPrint(&proc_path_buf, "/proc/{d}/cwd", .{pid}) catch return false;
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.readlink(proc_path, &cwd_buf) catch return false;
        const changed = !std.mem.eql(u8, self.cwd, cwd);
        self.setCwd(cwd);
        return changed;
    }

    /// Resize the pane.
    ///
    /// When `skip_pty` is true (drag-preview mode) only the pixel geometry and
    /// render-dirty flag are updated — ghostty's terminal buffer and the ConPTY
    /// are left at their current size.  This avoids the rapid SIGWINCH storm
    /// that causes PSReadLine to leave ghost/duplicate prompt rows in the buffer
    /// (see https://github.com/microsoft/terminal/issues/15976).
    /// Pass `skip_pty = false` for the single authoritative resize that fires on
    /// divider_commit (mouse release), which sends exactly one SIGWINCH.
    pub fn resize(self: *Pane, runtime: *GhosttyRuntime, cols: u16, rows: u16, cell_width_px: u32, cell_height_px: u32, skip_pty: bool) void {
        const prev_cols = self.cols;
        const prev_rows = self.rows;
        self.cols = cols;
        self.rows = rows;

        if (skip_pty) {
            // Drag-preview: just mark dirty so the renderer redraws in the new
            // pixel bounds.  No ghostty reflow, no SIGWINCH.
            self.render_dirty = .full;
            std.log.info("pane.resize (drag-preview): pane={x} cols={d} rows={d} — PTY/ghostty frozen", .{ @intFromPtr(self), cols, rows });
            return;
        }

        // Guard against null terminal — can happen if bootstrap partially failed
        // (e.g. PTY spawn error left self.terminal pointing at a freed handle).
        if (self.terminal) |terminal| {
            std.log.info("pane.resize: resizeTerminal pane={x} cols={d} rows={d}", .{ @intFromPtr(self), cols, rows });
            // If the dimensions haven't changed from ghostty's perspective
            // (e.g. divider_commit after a drag that ended on the same grid
            // boundary as the last drag-frame resize), ghostty treats
            // terminal_resize as a no-op and does NOT reflow.  This leaves
            // its terminal state corrupted from the rapid resize churn during
            // the drag.  Force a real reflow by briefly resizing to a
            // neighbouring size first.
            if (cols == prev_cols and rows == prev_rows and (cols > 1 or rows > 1)) {
                const bump_cols: u16 = if (cols > 1) cols - 1 else cols + 1;
                std.log.info("pane.resize: forcing reflow via bump resize pane={x} bump_cols={d}", .{ @intFromPtr(self), bump_cols });
                runtime.resizeTerminal(terminal, bump_cols, rows, cell_width_px, cell_height_px);
            }
            runtime.resizeTerminal(terminal, cols, rows, cell_width_px, cell_height_px);
            std.log.info("pane.resize: resizeTerminal done", .{});
        }
        std.log.info("pane.resize: updateRenderState pane={x}", .{@intFromPtr(self)});
        runtime.updateRenderState(self.render_state, self.terminal) catch {};
        std.log.info("pane.resize: updateRenderState done", .{});
        // A resize always requires a full redraw (all rows change).
        self.render_dirty = .full;
        std.log.info("pane.resize: syncKeyEncoder pane={x}", .{@intFromPtr(self)});
        runtime.syncKeyEncoder(self.key_encoder, self.terminal);
        std.log.info("pane.resize: syncMouseEncoder pane={x}", .{@intFromPtr(self)});
        runtime.syncMouseEncoder(self.mouse_encoder, self.terminal);
        std.log.info("pane.resize: done pane={x}", .{@intFromPtr(self)});
        if (self.pty) |*pty| {
            if (pty.isAlive()) {
                pty.resize(cols, rows);
            }
        }
    }

    /// Force a full ConPTY screen repaint by briefly sending a row-bump SIGWINCH.
    /// Called after a post-settle VT clear so the shell repaints into the blank buffer.
    /// We only resize the PTY (not ghostty's terminal buffer) because the VT sequences
    /// the shell emits are absolute and render correctly inside ghostty's rows×cols grid.
    pub fn nudgePty(self: *Pane) void {
        if (self.pty) |*pty| {
            if (pty.isAlive()) {
                const bump_rows: u16 = if (self.rows > 1) self.rows - 1 else self.rows + 1;
                std.log.info("pane.nudgePty: row-bump cols={d} rows={d}→{d}→{d}", .{ self.cols, self.rows, bump_rows, self.rows });
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
        std.log.info("pane.setMouseSize: pane={x} screen={d}x{d} cell={d}x{d}", .{ @intFromPtr(self), screen_width, screen_height, cell_width_px, cell_height_px });
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
        std.log.info("pane.setMouseSize: setMouseEncoderSize done", .{});
        runtime.setMouseEncoderTrackLastCell(self.mouse_encoder, false);
        std.log.info("pane.setMouseSize: done", .{});
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
        std.log.info("refreshTitle start title.len={d}", .{self.title.len});
        if (self.title.len > 0) {
            self.allocator.free(self.title);
            self.title = &.{};
        }
        const maybe_title = runtime.terminalTitle(self.allocator, self.terminal) catch null;
        if (maybe_title) |title| {
            if (is_windows and shouldIgnoreWindowsShellTitle(title, shell_command)) {
                self.allocator.free(title);
            } else {
                self.title = title;
            }
        } else if (!is_windows) {
            self.title = self.allocator.dupe(u8, fallback_title) catch &.{};
        }
        self.title_dirty = false;
    }

    fn shouldIgnoreWindowsShellTitle(title: []const u8, shell_command: []const u8) bool {
        const trimmed_title = std.mem.trim(u8, title, " \t\r\n");
        if (trimmed_title.len == 0) return false;

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

    pub fn hasLiveChild(self: *Pane) bool {
        if (self.pty) |*pty| return pty.isAlive();
        return false;
    }

    pub fn scrollbar(self: *const Pane) ghostty.TerminalScrollbar {
        return .{
            .total = self.scrollbar_total,
            .offset = self.scrollbar_offset,
            .len = self.scrollbar_len,
        };
    }

    fn sanitizePtyOutput(self: *Pane, bytes: []u8) []const u8 {
        const filtered_len = self.filterOsc52(bytes);
        if (!platform.isWindows()) return self.pty_sanitize_buf[0..filtered_len];

        const enable = "\x1b[?9001h";
        const disable = "\x1b[?9001l";
        var combined_len: usize = self.pty_pending_len;
        if (combined_len > 0) {
            @memcpy(self.pty_sanitize_buf[0..combined_len], self.pty_pending_seq[0..combined_len]);
        }
        @memmove(self.pty_sanitize_buf[combined_len .. combined_len + filtered_len], self.pty_sanitize_buf[0..filtered_len]);
        combined_len += filtered_len;

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

        // Second pass: strip XTWINOPS CSI t sequences (e.g. ESC [ 8 ; rows ; cols t).
        // Ghostty does not implement these and crashes (null fn-ptr call) when it receives them.
        // They are sent by the shell in response to ConPTY SIGWINCH after a pane resize.
        const first_pass_len = write_idx;
        write_idx = 0;
        var scan_idx: usize = 0;
        while (scan_idx < first_pass_len) {
            if (scan_idx + 1 < first_pass_len and
                self.pty_sanitize_buf[scan_idx] == 0x1b and
                self.pty_sanitize_buf[scan_idx + 1] == '[')
            {
                var j: usize = scan_idx + 2;
                var is_csi_t = false;
                while (j < first_pass_len) : (j += 1) {
                    const b = self.pty_sanitize_buf[j];
                    if (b >= 0x30 and b <= 0x3f) {
                        // parameter byte, keep scanning
                    } else if (b == 't') {
                        is_csi_t = true;
                        j += 1; // advance past 't'
                        break;
                    } else {
                        break; // different final byte — not a CSI t, keep the sequence
                    }
                }
                if (is_csi_t) {
                    scan_idx = j;
                    continue;
                }
            }
            self.pty_sanitize_buf[write_idx] = self.pty_sanitize_buf[scan_idx];
            write_idx += 1;
            scan_idx += 1;
        }

        return self.pty_sanitize_buf[0..write_idx];
    }

    fn filterOsc52(self: *Pane, bytes: []const u8) usize {
        var read_idx: usize = 0;
        var write_idx: usize = 0;

        while (read_idx < bytes.len) {
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

            if (self.osc_prefix_len > 0 or byte == 0x1b) {
                if (self.osc_prefix_len == 0 and byte == 0x1b) {
                    std.log.info("pane: detected ESC (0x1b)", .{});
                    self.osc_prefix_len = 1;
                    read_idx += 1;
                    continue;
                }
                if (self.osc_prefix_len == 1 and byte == ']') {
                    self.osc_prefix_len = 2;
                    read_idx += 1;
                    continue;
                }
                if (self.osc_prefix_len == 2) {
                    if (byte == '5') {
                        self.osc_prefix_len = 3;
                        read_idx += 1;
                        continue;
                    }
                    if (byte == '7') {
                        self.osc_prefix_len = 5; // Jump to "saw \x1b]7"
                        read_idx += 1;
                        continue;
                    }
                }
                if (self.osc_prefix_len == 3 and byte == '2') {
                    self.osc_prefix_len = 4; // Saw \x1b]52
                    read_idx += 1;
                    continue;
                }
                if (self.osc_prefix_len == 4 and byte == ';') {
                    self.osc52_active = true;
                    self.osc52_st_pending = false;
                    self.osc52_overflow = false;
                    self.osc52_len = 0;
                    self.osc_prefix_len = 0;
                    read_idx += 1;
                    continue;
                }
                if (self.osc_prefix_len == 5 and byte == ';') {
                    self.osc7_active = true;
                    self.osc7_st_pending = false;
                    self.osc7_len = 0;
                    self.osc_prefix_len = 0;
                    read_idx += 1;
                    continue;
                }

                // Match failed: write back the prefix we've collected so far
                const prefix = if (self.osc_prefix_len == 1) "\x1b" else if (self.osc_prefix_len == 2) "\x1b]" else if (self.osc_prefix_len == 3) "\x1b]5" else if (self.osc_prefix_len == 4) "\x1b]52" else if (self.osc_prefix_len == 5) "\x1b]7" else "";
                @memcpy(self.pty_sanitize_buf[write_idx .. write_idx + prefix.len], prefix);
                write_idx += prefix.len;
                self.osc_prefix_len = 0;
                // Do NOT increment read_idx here, so we can process the current byte again
                continue;
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
    }
};

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
