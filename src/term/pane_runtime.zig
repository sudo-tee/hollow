const std = @import("std");
const io = @import("../io.zig");
const command_ipc = @import("../ipc.zig");
const Config = @import("../config.zig").Config;
const fastmem = @import("../fastmem.zig");
const GhosttyRuntime = @import("ghostty.zig").Runtime;
const ghostty = @import("ghostty.zig");
const osc99 = @import("osc99.zig");
const TerminalCallbacks = ghostty.TerminalCallbacks;
const TerminalPane = @import("terminal_pane.zig").TerminalPane;
const LaunchCommand = @import("../pty/launch_command.zig").LaunchCommand;
const platform = @import("../platform.zig");
const Pane = @import("../pane.zig").Pane;
const policy = @import("pty_policy.zig");

const PTY_PARSE_CHUNK_BYTES = policy.parse_chunk_bytes;
const PTY_PRESSURE_PARSE_CHUNK_BYTES = policy.pressure_parse_chunk_bytes;
const PTY_HARD_BYTE_LIMIT = policy.hard_byte_limit;
const PTY_DEFERRED_OUTPUT_LIMIT = policy.deferred_output_limit;
const PTY_READ_BUFFER_SIZE: usize = PTY_PRESSURE_PARSE_CHUNK_BYTES;

const is_windows = @import("builtin").os.tag == .windows;

const OSC99_PREFIX = "\x1b]99;";
const OSC1337_PREFIX = "\x1b]1337;";
const HTP_OSC_PREFIX = "\x1b]1337;Hollow;";
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
    osc1337,
    osc99,
    htp,
};

fn classifyOscPrefix(prefix: []const u8) OscPrefixMatch {
    if (std.mem.eql(u8, prefix, OSC99_PREFIX)) return .osc99;
    if (std.mem.eql(u8, prefix, HTP_OSC_PREFIX)) return .htp;
    if (prefix.len >= OSC1337_PREFIX.len and
        std.mem.eql(u8, prefix[0..OSC1337_PREFIX.len], OSC1337_PREFIX) and
        !std.mem.startsWith(u8, HTP_OSC_PREFIX, prefix))
    {
        return .osc1337;
    }
    if (std.mem.startsWith(u8, OSC99_PREFIX, prefix) or
        std.mem.startsWith(u8, OSC1337_PREFIX, prefix) or
        std.mem.startsWith(u8, HTP_OSC_PREFIX, prefix))
    {
        return .partial;
    }
    return .none;
}

/// Short-lived adapter for terminal operations that also update shared pane
/// metadata. The terminal pointer is selected by the caller, never by this code.
/// Native callbacks always retain `node`, never the address of this adapter.
pub const RuntimeContext = struct {
    pub const HtpMessageHandler = TerminalPane.HtpMessageHandler;
    node: *Pane,
    term: *TerminalPane,
    allocator: std.mem.Allocator,

    pub fn bootstrap(self: *RuntimeContext, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32, inherited_cwd: ?[]const u8, domain_name: ?[]const u8, launch_command: ?LaunchCommand, workspace_id: ?[]const u8) !void {
        const start_ms = io.milliTimestamp();
        _ = cell_width_px;
        _ = cell_height_px;
        _ = window_width;
        _ = window_height;
        const terminal = try runtime.createTerminal(cfg.cols, cfg.rows, cfg.scrollback);
        errdefer runtime.freeTerminal(terminal);

        runtime.setTerminalDefaultColors(
            terminal,
            cfg.terminal_theme.foreground,
            cfg.terminal_theme.background,
            cfg.terminal_theme.cursor,
            &cfg.terminal_theme.palette,
        );

        runtime.setTerminalUserdata(terminal, self.node);
        self.term.terminal_runtime = runtime;
        self.term.synchronized_output_enabled = cfg.synchronized_output;

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

        var input_resources = try TerminalPane.initInput(runtime, terminal);
        errdefer input_resources.deinitInput(runtime);

        const shell = try self.allocator.dupeSentinel(u8, try cfg.shellForDomain(domain_name), 0);
        defer self.allocator.free(shell);

        // Build environment block for HTP
        // Format: "KEY1=value1\0KEY2=value2\0\0"
        var env_block: std.ArrayListUnmanaged(u8) = .empty;
        defer env_block.deinit(self.allocator);

        const pane_id = self.node.id;
        var pane_id_buf: [32]u8 = undefined;
        const pane_id_str = try std.fmt.bufPrint(&pane_id_buf, "{d}", .{pane_id});

        try env_block.appendSlice(self.allocator, "HOLLOW_PANE_ID=");
        try env_block.appendSlice(self.allocator, pane_id_str);
        try env_block.append(self.allocator, 0);

        try env_block.appendSlice(self.allocator, "HOLLOW_TRANSPORT=auto");
        try env_block.append(self.allocator, 0);

        if (io.getEnvVarOwned(self.allocator, command_ipc.EnvVar)) |command_addr| {
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

        var is_remote = false;
        if (domain_name) |name| {
            if (cfg.domainByName(name)) |domain| {
                if (domain.ssh != null) is_remote = true;
            }
        }
        self.term.is_remote = is_remote;

        const configured_cwd = cfg.defaultCwdForDomain(domain_name);
        const home_dir = if (inherited_cwd == null and configured_cwd == null and !is_remote)
            io.getEnvVarOwned(self.allocator, if (comptime is_windows) "USERPROFILE" else "HOME") catch null
        else
            null;
        defer if (home_dir) |h| self.allocator.free(h);

        // Lua decides whether this pane runs on an agent host. It sees the
        // unfiltered env: local spawn filters do not apply to remote hosts.
        var agent_pty: ?@import("../pty/pty.zig").Pty = try self.requestAgentPty(domain_name, shell, cfg.cols, cfg.rows, inherited_cwd orelse configured_cwd, inherited_cwd orelse configured_cwd orelse home_dir, env_block.items, launch_command);
        errdefer if (agent_pty) |*candidate| candidate.deinit();
        // Explicit hosts are not local PIDs/cwd authorities. Implicit WSL
        // panes keep local semantics, matching their native fallback.
        if (agent_pty) |*candidate| {
            if (!candidate.agent.fallbackAllowed()) {
                is_remote = true;
                self.term.is_remote = true;
            }
        }
        // SSH cwd belongs to remote shell, not local process launcher.
        var launch_cwd = if (is_remote) null else inherited_cwd orelse configured_cwd orelse home_dir;
        var spawn_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer spawn_arena.deinit();
        var spawn_spec: @import("../pty/spawn_spec.zig").SpawnSpec = .{
            .shell = shell,
            .domain = domain_name,
            .cwd = launch_cwd,
            .env_block = env_block.items,
        };
        // Remote cwd and guest environment require domain-aware plumbing.
        // This first producer only transforms native local launch contexts.
        if (agent_pty == null and !is_remote and !(is_windows and @import("../pty/spawn_spec.zig").isWsl(shell))) {
            self.term.spawn_filter.apply(spawn_arena.allocator(), &spawn_spec) catch |err| {
                std.log.warn("spawn filter failed: {s}", .{@errorName(err)});
            };
            launch_cwd = spawn_spec.cwd;
        }
        const pane_cwd = if (is_remote) inherited_cwd orelse configured_cwd else launch_cwd;

        var remote_launch_command_owned: ?[]u8 = null;
        defer if (remote_launch_command_owned) |command| self.allocator.free(command);
        const remote_cwd_via_launch = agent_pty == null and is_remote and pane_cwd != null;
        if (agent_pty == null and is_remote) {
            if (launch_command) |cmd| if (cmd.argv != null or cmd.one_shot) return error.BackgroundRequiresAgent;
        }
        const effective_launch_command: ?LaunchCommand = if (remote_cwd_via_launch) blk: {
            const cwd = pane_cwd.?;
            const quoted_cwd = try shellQuoteSingle(self.allocator, cwd);
            defer self.allocator.free(quoted_cwd);
            const command = if (launch_command) |value|
                try std.fmt.allocPrint(self.allocator, "cd -- {s} && {s}", .{ quoted_cwd, value.command })
            else
                try std.fmt.allocPrint(self.allocator, "cd -- {s} && exec \"$SHELL\" -il", .{quoted_cwd});
            remote_launch_command_owned = command;
            break :blk .{
                .command = command,
                .close_on_exit = if (launch_command) |value| value.close_on_exit else false,
            };
        } else launch_command;

        var pty = agent_pty orelse try @import("../pty/pty.zig").spawnNative(self.allocator, shell, cfg.cols, cfg.rows, launch_cwd, spawn_spec.env_block, effective_launch_command, self.term.host_wake);
        agent_pty = null;
        errdefer pty.deinit();

        // Transfer handles without overwriting terminal protocol buffers that
        // callbacks may already own. Locals retain rollback ownership until
        // the remaining fallible bootstrap steps have succeeded.
        self.term.key_encoder = input_resources.key_encoder;
        self.term.key_event = input_resources.key_event;
        self.term.mouse_encoder = input_resources.mouse_encoder;
        self.term.mouse_event = input_resources.mouse_event;
        self.term.terminal = terminal;
        self.term.render_state = render_state;
        self.term.row_iterator = row_iterator;
        self.term.row_cells = row_cells;
        self.term.pty = pty;

        // Bootstrap locals own these resources until every fallible step succeeds.
        errdefer {
            self.term.terminal = null;
            self.term.render_state = null;
            self.term.row_iterator = null;
            self.term.row_cells = null;
            self.term.key_encoder = null;
            self.term.key_event = null;
            self.term.mouse_encoder = null;
            self.term.mouse_event = null;
            self.term.pty = null;
        }

        // Defer terminal resize/render-state initialization until the first
        // layout pass on the frame thread. `newTab()` is triggered from the sokol
        // event callback, and calling ghostty resize/update APIs here has been a
        // recurring source of null-deref crashes during tab creation.
        self.node.title = &.{};
        if (domain_name) |name| self.term.domain_name = try self.allocator.dupe(u8, name);
        if (pane_cwd) |cwd| self.node.setCwd(cwd);
        std.log.info("pane.bootstrap total_ms={d} domain={s} remote={any}", .{ io.milliTimestamp() - start_ms, domain_name orelse "", self.term.is_remote });
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

    pub fn pollPty(self: *RuntimeContext, runtime: *GhosttyRuntime, max_read_loops: usize, max_total_read: usize, budget_ns: i128, parse_chunk_bytes: usize, debug_overlay: bool) !usize {
        var total_read: usize = 0;
        if (self.term.pty) |*pty| {
            const budget_start_ns = io.nanoTimestamp();
            const deadline_ns = budget_start_ns + @max(@as(i128, 0), budget_ns);
            self.term.last_pty_read_ns = 0;
            self.term.last_terminal_write_ns = 0;
            self.term.last_has_pending_ns = 0;
            self.term.last_sanitize_ns = 0;
            self.term.last_child_alive_ns = 0;
            self.term.last_encoder_sync_ns = 0;
            self.term.last_terminal_write_bytes = 0;
            self.term.last_terminal_write_chunks = 0;

            if (debug_overlay) {
                const pending_start_ns = io.nanoTimestamp();
                _ = pty.pendingOutputBytes();
                self.term.last_has_pending_ns = io.nanoTimestamp() - pending_start_ns;
            }

            var wrote_terminal = false;
            var can_read = true;
            if (self.term.terminal_output_ready) {
                can_read = self.writeBufferedTerminalOutput(runtime, &self.term.boot_output, deadline_ns, debug_overlay, &wrote_terminal);
                if (can_read) can_read = self.writeBufferedTerminalOutput(runtime, &self.term.pending_terminal_inject, deadline_ns, debug_overlay, &wrote_terminal);
            }

            const read_limit_total = @min(max_total_read, PTY_HARD_BYTE_LIMIT);
            const read_chunk_bytes = @min(parse_chunk_bytes, PTY_READ_BUFFER_SIZE);
            var read_loops: usize = 0;
            while (can_read and read_chunk_bytes > 0 and budget_ns > 0 and io.nanoTimestamp() < deadline_ns and read_loops < max_read_loops and total_read < read_limit_total and
                (self.term.terminal_output_ready or self.term.boot_output.items.len +| self.term.pending_terminal_inject.items.len < PTY_DEFERRED_OUTPUT_LIMIT - PTY_PRESSURE_PARSE_CHUNK_BYTES))
            {
                const read_limit = @min(read_chunk_bytes, read_limit_total - total_read);
                const read_start_ns = if (debug_overlay) io.nanoTimestamp() else 0;
                const count = pty.read(self.term.read_buf[0..read_limit]) catch |err| {
                    if (err == error.EndOfStream) break;
                    return err;
                };
                if (debug_overlay) self.term.last_pty_read_ns += io.nanoTimestamp() - read_start_ns;
                if (count == 0) break;
                if (self.term.automation_token != null) self.term.job_output.append(self.allocator, self.term.read_buf[0..count]);
                read_loops += 1;
                total_read += count;
                if (!self.term.logged_first_pty_read) {
                    self.term.logged_first_pty_read = true;
                    std.log.info("first PTY bytes received count={d}", .{count});
                }
                const sanitize_start_ns = if (debug_overlay) io.nanoTimestamp() else 0;
                const pty_bytes = self.sanitizePtyOutput(self.term.read_buf[0..count]);
                if (debug_overlay) self.term.last_sanitize_ns += io.nanoTimestamp() - sanitize_start_ns;
                if (pty_bytes.len > 0) {
                    if (self.term.terminal_output_ready) {
                        self.writeTerminalChunk(runtime, pty_bytes, debug_overlay);
                        wrote_terminal = true;
                    } else {
                        try self.term.boot_output.appendSlice(self.allocator, pty_bytes);
                    }
                }
                if (self.term.pending_terminal_inject.items.len > 0) {
                    if (self.term.terminal_output_ready) {
                        if (!self.writeBufferedTerminalOutput(runtime, &self.term.pending_terminal_inject, deadline_ns, debug_overlay, &wrote_terminal)) {
                            break;
                        }
                    } else {
                        self.term.boot_output.appendSlice(self.allocator, self.term.pending_terminal_inject.items) catch {};
                        self.term.pending_terminal_inject.clearRetainingCapacity();
                    }
                }
                if (io.nanoTimestamp() >= deadline_ns) break;
            }

            if (total_read > 0) self.term.last_pty_output_ns = io.nanoTimestamp();

            const child_alive_start_ns = if (debug_overlay) io.nanoTimestamp() else 0;
            self.term.refreshChildAliveCache(false);
            if (debug_overlay) self.term.last_child_alive_ns += io.nanoTimestamp() - child_alive_start_ns;
            if (self.term.pending_startup_input.len > 0 and self.term.logged_first_pty_read) {
                if (total_read == 0 and max_total_read > 0 and !pty.hasPendingOutput()) {
                    self.term.startup_input_quiet_ticks +|= 1;
                } else if (total_read > 0) {
                    self.term.startup_input_quiet_ticks = 0;
                }
                if (self.term.startup_input_quiet_ticks >= 1) {
                    if (io.nanoTimestamp() < deadline_ns) {
                        const write_len = @min(self.term.pending_startup_input.len, PTY_PARSE_CHUNK_BYTES);
                        const written = pty.writeAllUntil(self.term.pending_startup_input[0..write_len], deadline_ns) catch |err| blk: {
                            std.log.warn("pane: failed to send deferred startup input: {}", .{err});
                            break :blk 0;
                        };
                        if (written == 0) {
                            self.term.startup_input_quiet_ticks = 0;
                        } else if (written == self.term.pending_startup_input.len) {
                            self.allocator.free(self.term.pending_startup_input.ptr[0..self.term.pending_startup_input_capacity]);
                            self.term.pending_startup_input = &.{};
                            self.term.pending_startup_input_capacity = 0;
                            self.term.startup_input_quiet_ticks = 0;
                        } else {
                            fastmem.move(u8, self.term.pending_startup_input[0 .. self.term.pending_startup_input.len - written], self.term.pending_startup_input[written..]);
                            self.term.pending_startup_input = self.term.pending_startup_input[0 .. self.term.pending_startup_input.len - written];
                        }
                    }
                }
            }
            // Only sync encoders when PTY activity occurred. Doing this every
            // idle tick still crosses the Ghostty FFI boundary and adds up.
            // Fresh terminal mode changes arrive via PTY output, and resize/
            // focus paths already perform their own explicit syncs.
            if (self.term.terminal_output_ready and wrote_terminal) {
                const encoder_sync_start_ns = if (debug_overlay) io.nanoTimestamp() else 0;
                self.term.syncInput(runtime, self.term.terminal);
                // Log mouse tracking state changes for diagnostics.
                var mouse_tracking: u32 = 0;
                const mt_result = runtime.terminal_get(self.term.terminal, @backingInt(ghostty.TerminalData.mouse_tracking), &mouse_tracking);
                if (mouse_tracking != self.term.last_mouse_tracking) {
                    std.log.info("pane mouse_tracking changed {d} -> {d} (get_result={d})", .{ self.term.last_mouse_tracking, mouse_tracking, mt_result });
                    self.term.last_mouse_tracking = mouse_tracking;
                }
                if (!self.term.mouse_tracking_logged_initial) {
                    self.term.mouse_tracking_logged_initial = true;
                    std.log.info("pane initial mouse_tracking={d} (get_result={d})", .{ mouse_tracking, mt_result });
                }

                {
                    var active_screen: u32 = 0;
                    _ = runtime.terminal_get(self.term.terminal, @backingInt(ghostty.TerminalData.active_screen), &active_screen);
                    self.term.active_screen = active_screen;
                }

                if (debug_overlay) self.term.last_encoder_sync_ns += io.nanoTimestamp() - encoder_sync_start_ns;

                if (!self.term.render_state_ready or self.term.synchronized_output_active) return total_read;
                const now_ns = io.nanoTimestamp();
                runtime.clearRenderStateDirty(self.term.render_state);
                runtime.updateRenderState(self.term.render_state, self.term.terminal) catch |err| {
                    std.log.err("pane updateRenderState after PTY drain failed: {s}", .{@errorName(err)});
                    return total_read;
                };
                self.term.last_render_state_update_ns = now_ns;
                self.term.render_state_fresh = true;
            }
        }
        return total_read;
    }

    fn writeTerminalChunk(self: *RuntimeContext, runtime: *GhosttyRuntime, bytes: []const u8, debug_overlay: bool) void {
        const write_start_ns = if (debug_overlay) io.nanoTimestamp() else 0;
        runtime.terminalWrite(self.term.terminal, bytes);
        if (debug_overlay) self.term.last_terminal_write_ns += io.nanoTimestamp() - write_start_ns;
        self.term.last_terminal_write_bytes += bytes.len;
        self.term.last_terminal_write_chunks += 1;
        self.term.pty_received_data = true;
        self.term.pty_wrote_this_frame = true;
    }

    fn writeBufferedTerminalOutput(
        self: *RuntimeContext,
        runtime: *GhosttyRuntime,
        buffer: *std.ArrayListUnmanaged(u8),
        deadline_ns: i128,
        debug_overlay: bool,
        wrote_terminal: *bool,
    ) bool {
        while (buffer.items.len > 0) {
            if (io.nanoTimestamp() >= deadline_ns) break;
            const chunk_len = @min(PTY_PARSE_CHUNK_BYTES, buffer.items.len);
            self.writeTerminalChunk(runtime, buffer.items[0..chunk_len], debug_overlay);
            wrote_terminal.* = true;
            if (chunk_len == buffer.items.len) {
                buffer.clearRetainingCapacity();
            } else {
                fastmem.move(u8, buffer.items[0 .. buffer.items.len - chunk_len], buffer.items[chunk_len..]);
                buffer.items.len -= chunk_len;
            }
            if (io.nanoTimestamp() >= deadline_ns) break;
        }
        return buffer.items.len == 0;
    }

    pub fn refreshCwd(self: *RuntimeContext) bool {
        if (self.term.pending_cwd) |cwd| {
            self.term.pending_cwd = null;
            defer self.allocator.free(cwd);
            self.node.setCwd(cwd);
            self.node.cwd_dirty = false;
            // A shell report confirms the canonical cwd even when it matches
            // the launch path. WSL workspace bootstrap waits for this event.
            return true;
        }
        var changed = false;
        if (self.node.cwd_dirty) {
            changed = true;
            self.node.cwd_dirty = false;
        }

        if (self.term.is_remote) return changed;
        if (is_windows) return changed;

        const pid = self.term.childPid();
        if (pid == 0) return changed;

        var proc_path_buf: [64]u8 = undefined;
        const proc_path = std.fmt.bufPrint(&proc_path_buf, "/proc/{d}/cwd", .{pid}) catch return changed;
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = std.Io.Dir.readLinkAbsolute(io.get(), proc_path, &cwd_buf) catch return changed;
        const cwd = cwd_buf[0..cwd_len];
        if (!std.mem.eql(u8, self.node.cwd, cwd)) {
            self.node.setCwd(cwd);
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
    pub fn resize(self: *RuntimeContext, runtime: *GhosttyRuntime, cols: u16, rows: u16, cell_width_px: u32, cell_height_px: u32, skip_pty: bool) void {
        // A geometry change invalidates the previously presented surface, so
        // do not let synchronized output hold an obsolete frame across it.
        self.term.synchronized_output_active = false;
        self.term.synchronized_output_started_ns = 0;
        const prev_cols = self.node.cols;
        const prev_rows = self.node.rows;

        if (skip_pty) {
            // Drag-preview: just mark dirty so the renderer redraws in the new
            // pixel bounds. Keep rows/cols authoritative so mouse release still
            // performs the real terminal resize when the preview grid changed.
            self.node.render_dirty = .full;
            return;
        }

        self.node.cols = cols;
        self.node.rows = rows;

        const same_grid = cols == prev_cols and rows == prev_rows;

        if (same_grid) {
            // Same-grid layout changes should stay a pure geometry/cache refresh.
            // Resizing the terminal/PTY here can trigger shell reflow or prompt
            // redraw glitches even though the terminal cell grid did not change.
            self.node.render_dirty = .full;
            self.term.syncInput(runtime, self.term.terminal);
            return;
        }

        // Guard against null terminal — can happen if bootstrap partially failed
        // (e.g. PTY spawn error left self.term.terminal pointing at a freed handle).
        if (self.term.terminal) |terminal| {
            runtime.resizeTerminal(terminal, cols, rows, cell_width_px, cell_height_px);
        }
        runtime.updateRenderState(self.term.render_state, self.term.terminal) catch {};
        self.node.render_dirty = .full;
        self.term.syncInput(runtime, self.term.terminal);
        if (self.term.pty) |*pty| {
            if (pty.isAlive()) {
                pty.resize(cols, rows);
            }
        }
    }

    /// Force a repaint by briefly resizing both Ghostty and the PTY, matching
    /// the authoritative window-resize path instead of nudging only the PTY.
    pub fn nudgeTerminal(self: *RuntimeContext, runtime: *GhosttyRuntime, cell_width_px: u32, cell_height_px: u32) void {
        if (self.node.cols == 0 or self.node.rows == 0) return;
        const original_rows = self.node.rows;
        const bump_rows: u16 = original_rows +| 1;
        if (self.term.pty) |*pty| {
            if (pty.isAlive()) {
                std.log.info("pane.nudgeTerminal: cols={d} rows={d}->{}->{}", .{ self.node.cols, original_rows, bump_rows, original_rows });
                self.node.rows = bump_rows;
                runtime.resizeTerminal(self.term.terminal, self.node.cols, bump_rows, cell_width_px, cell_height_px);
                runtime.updateRenderState(self.term.render_state, self.term.terminal) catch {};
                pty.resize(self.node.cols, bump_rows);

                self.node.rows = original_rows;
                runtime.resizeTerminal(self.term.terminal, self.node.cols, original_rows, cell_width_px, cell_height_px);
                runtime.updateRenderState(self.term.render_state, self.term.terminal) catch {};
                pty.resize(self.node.cols, original_rows);
                self.term.synchronized_output_active = false;
                self.term.synchronized_output_started_ns = 0;
                self.node.render_dirty = .full;
            }
        }
    }

    pub fn refreshTitle(self: *RuntimeContext, runtime: *GhosttyRuntime, fallback_title: []const u8, shell_command: []const u8) void {
        if (self.node.title_is_manual) {
            if (runtime.terminalTitle(self.allocator, self.term.terminal) catch null) |title| {
                self.allocator.free(title);
            }
            self.node.title_dirty = false;
            return;
        }

        if (self.node.title.len > 0) {
            self.allocator.free(self.node.title);
            self.node.title = &.{};
        }
        const maybe_title = runtime.terminalTitle(self.allocator, self.term.terminal) catch null;
        if (maybe_title) |title| {
            if (is_windows and shouldIgnoreWindowsShellTitle(title, shell_command, self.term.usesAgent())) {
                self.allocator.free(title);
            } else {
                self.node.title = title;
            }
        } else if (!is_windows) {
            self.node.title = self.allocator.dupe(u8, fallback_title) catch &.{};
        }
        self.syncRemoteCwdFromTitle();
        self.node.title_dirty = false;
    }

    fn requestAgentPty(self: *RuntimeContext, domain_name: ?[]const u8, shell: [:0]const u8, cols: u16, rows: u16, cwd: ?[]const u8, native_cwd: ?[]const u8, env_block: []const u8, launch_command: ?LaunchCommand) !?@import("../pty/pty.zig").Pty {
        if (!self.term.pty_host.enabled()) return null;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const host = self.term.pty_host.resolve(arena.allocator(), domain_name, shell) orelse return null;
        var candidate = try @import("../pty/pty.zig").spawnAgent(self.allocator, .{
            .shell = shell,
            .cols = cols,
            .rows = rows,
            .cwd = cwd,
            .native_cwd = native_cwd,
            .env_block = env_block,
            .launch_command = launch_command,
            .host = host,
        }, self.term.host_wake);
        errdefer candidate.deinit();
        try candidate.agent.start();
        return candidate;
    }

    fn syncRemoteCwdFromTitle(self: *RuntimeContext) void {
        if (!self.term.is_remote or self.node.title.len == 0) return;

        const trimmed = std.mem.trim(u8, self.node.title, " \t\r\n");
        const derived = deriveRemotePathFromTitle(trimmed) orelse return;
        if (std.mem.eql(u8, self.node.cwd, derived)) return;

        self.node.setCwd(derived);
        self.node.cwd_dirty = true;
    }

    fn shouldIgnoreWindowsShellTitle(title: []const u8, shell_command: []const u8, agent_pty: bool) bool {
        const trimmed_title = std.mem.trim(u8, title, " \t\r\n");
        if (trimmed_title.len == 0) return false;

        if (agent_pty and isWslUncTitle(trimmed_title)) return true;

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

    fn sanitizePtyOutput(self: *RuntimeContext, bytes: []u8) []const u8 {
        return self.sanitizePtyOutputForPlatform(bytes, platform.isWindows());
    }

    fn containsWindowsFilteredSequence(bytes: []const u8) bool {
        const enable = "\x1b[?9001h";
        const disable = "\x1b[?9001l";
        var search_from: usize = 0;
        while (std.mem.indexOfScalarPos(u8, bytes, search_from, 0x1b)) |esc_idx| {
            if (std.mem.startsWith(u8, bytes[esc_idx..], enable) or std.mem.startsWith(u8, bytes[esc_idx..], disable)) return true;
            if (esc_idx + 1 < bytes.len and bytes[esc_idx + 1] == ']') return true;
            if (esc_idx + 1 < bytes.len and bytes[esc_idx + 1] == '[') {
                var i = esc_idx + 2;
                while (i < bytes.len and bytes[i] >= 0x30 and bytes[i] <= 0x3f) : (i += 1) {}
                if (i < bytes.len and bytes[i] == 't') return true;
            }
            search_from = esc_idx + 1;
        }
        return false;
    }

    fn sanitizePtyOutputForPlatform(self: *RuntimeContext, bytes: []u8, windows_mode: bool) []const u8 {
        const has_pending = windows_mode and self.term.pty_pending_len > 0;

        if (!has_pending) {
            return self.sanitizePtyOutputBytesForPlatform(bytes, windows_mode);
        }

        const pending = if (windows_mode) self.term.pty_pending_seq[0..self.term.pty_pending_len] else "";
        const input = CombinedInput{ .first = pending, .second = bytes };
        const enable = "\x1b[?9001h";
        const disable = "\x1b[?9001l";
        var read_idx: usize = 0;
        var write_idx: usize = 0;

        self.term.pty_pending_len = 0;

        while (read_idx < input.len()) {
            const byte = input.byteAt(read_idx);

            if (self.term.osc99_active) {
                if (self.term.osc99_st_pending) {
                    if (byte == '\\') {
                        self.finishNotificationOscSequence();
                    } else {
                        self.appendOsc99Byte(0x1b);
                        self.appendOsc99Byte(byte);
                    }
                    self.term.osc99_st_pending = false;
                    read_idx += 1;
                    continue;
                }

                if (byte == 0x07) {
                    self.finishNotificationOscSequence();
                    read_idx += 1;
                    continue;
                }
                if (byte == 0x1b) {
                    self.term.osc99_st_pending = true;
                    read_idx += 1;
                    continue;
                }

                self.appendOsc99Byte(byte);
                read_idx += 1;
                continue;
            }

            if (self.term.htp_osc_active) {
                if (self.term.htp_osc_st_pending) {
                    if (byte == '\\') {
                        self.finishHtpOscSequence();
                    } else {
                        self.appendHtpOscByte(0x1b);
                        self.appendHtpOscByte(byte);
                    }
                    self.term.htp_osc_st_pending = false;
                    read_idx += 1;
                    continue;
                }

                if (byte == 0x07) {
                    self.finishHtpOscSequence();
                    read_idx += 1;
                    continue;
                }
                if (byte == 0x1b) {
                    self.term.htp_osc_st_pending = true;
                    read_idx += 1;
                    continue;
                }

                self.appendHtpOscByte(byte);
                read_idx += 1;
                continue;
            }

            if (self.term.osc1337_active) {
                if (self.term.osc1337_st_pending) {
                    if (byte == '\\') {
                        self.finishOsc1337Sequence();
                    } else {
                        self.appendOsc1337Byte(0x1b);
                        self.appendOsc1337Byte(byte);
                    }
                    self.term.osc1337_st_pending = false;
                    read_idx += 1;
                    continue;
                }

                if (byte == 0x07) {
                    self.finishOsc1337Sequence();
                    read_idx += 1;
                    continue;
                }
                if (byte == 0x1b) {
                    self.term.osc1337_st_pending = true;
                    read_idx += 1;
                    continue;
                }

                self.appendOsc1337Byte(byte);
                read_idx += 1;
                continue;
            }

            if (self.term.osc_prefix_len > 0) {
                if (self.term.osc_prefix_len < self.term.osc_prefix_buf.len) {
                    self.term.osc_prefix_buf[self.term.osc_prefix_len] = byte;
                    self.term.osc_prefix_len += 1;
                    read_idx += 1;
                } else {
                    fastmem.copy(u8, self.term.pty_sanitize_buf[write_idx .. write_idx + self.term.osc_prefix_len], self.term.osc_prefix_buf[0..self.term.osc_prefix_len]);
                    write_idx += self.term.osc_prefix_len;
                    self.term.osc_prefix_len = 0;
                    continue;
                }

                const prefix = self.term.osc_prefix_buf[0..self.term.osc_prefix_len];
                switch (classifyOscPrefix(prefix)) {
                    .osc99 => {
                        self.beginNotificationOscSequence();
                        self.term.osc_prefix_len = 0;
                        continue;
                    },
                    .htp => {
                        self.term.htp_osc_active = true;
                        self.term.htp_osc_st_pending = false;
                        self.term.htp_osc_overflow = false;
                        self.term.htp_osc_len = 0;
                        self.term.osc_prefix_len = 0;
                        continue;
                    },
                    .osc1337 => {
                        self.term.osc1337_active = true;
                        self.term.osc1337_st_pending = false;
                        self.term.osc1337_overflow = false;
                        self.term.osc1337_buf.clearRetainingCapacity();
                        if (prefix.len > OSC1337_PREFIX.len) {
                            self.term.osc1337_buf.appendSlice(self.allocator, prefix[OSC1337_PREFIX.len..]) catch {
                                self.term.osc1337_overflow = true;
                            };
                        }
                        self.term.osc_prefix_len = 0;
                        continue;
                    },
                    .partial => continue,
                    .none => {
                        fastmem.copy(u8, self.term.pty_sanitize_buf[write_idx .. write_idx + prefix.len], prefix);
                        write_idx += prefix.len;
                        self.term.osc_prefix_len = 0;
                        continue;
                    },
                }
            }

            const esc_idx = input.indexOfScalarPos(read_idx, 0x1b) orelse {
                input.copyRange(read_idx, input.len(), self.term.pty_sanitize_buf[0..], &write_idx);
                break;
            };
            if (esc_idx > read_idx) {
                input.copyRange(read_idx, esc_idx, self.term.pty_sanitize_buf[0..], &write_idx);
                read_idx = esc_idx;
            }

            const next = input.byteAtOrNull(read_idx + 1);
            if (next == null or next.? == ']') {
                self.term.osc_prefix_buf[0] = 0x1b;
                self.term.osc_prefix_len = 1;
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

            self.term.pty_sanitize_buf[write_idx] = 0x1b;
            write_idx += 1;
            read_idx += 1;
        }

        if (windows_mode) {
            const tail_len = trailingAnsiPrefixLen(self.term.pty_sanitize_buf[0..write_idx]);
            self.term.pty_pending_len = tail_len;
            if (tail_len > 0) {
                fastmem.copy(u8, self.term.pty_pending_seq[0..tail_len], self.term.pty_sanitize_buf[write_idx - tail_len .. write_idx]);
                write_idx -= tail_len;
            }
        }

        return self.term.pty_sanitize_buf[0..write_idx];
    }

    fn sanitizePtyOutputBytesForPlatform(self: *RuntimeContext, bytes: []u8, windows_mode: bool) []const u8 {
        const enable = "\x1b[?9001h";
        const disable = "\x1b[?9001l";
        var read_idx: usize = 0;
        var write_idx: usize = 0;
        const has_active_filter = self.term.osc99_active or self.term.osc1337_active or self.term.htp_osc_active or self.term.osc_prefix_len > 0;

        self.term.pty_pending_len = 0;

        // Most Windows output only contains ordinary SGR/CSI sequences. Keep
        // it in place instead of copying every byte through the sanitizer.
        if (windows_mode and !has_active_filter and !containsWindowsFilteredSequence(bytes) and trailingAnsiPrefixLen(bytes) == 0) return bytes;

        if (!has_active_filter) {
            const first_esc = std.mem.indexOfScalar(u8, bytes, 0x1b) orelse return bytes;
            read_idx = first_esc;
            if (first_esc > 0) {
                const prefix = bytes[0..first_esc];
                fastmem.copy(u8, self.term.pty_sanitize_buf[0..prefix.len], prefix);
                write_idx = prefix.len;
            }
        }

        while (read_idx < bytes.len) {
            if (!self.term.osc99_active and !self.term.osc1337_active and !self.term.htp_osc_active and self.term.osc_prefix_len == 0) {
                const esc_idx = std.mem.indexOfScalarPos(u8, bytes, read_idx, 0x1b) orelse {
                    const span = bytes[read_idx..];
                    fastmem.copy(u8, self.term.pty_sanitize_buf[write_idx .. write_idx + span.len], span);
                    write_idx += span.len;
                    break;
                };
                if (esc_idx > read_idx) {
                    const span = bytes[read_idx..esc_idx];
                    fastmem.copy(u8, self.term.pty_sanitize_buf[write_idx .. write_idx + span.len], span);
                    write_idx += span.len;
                    read_idx = esc_idx;
                }
            }

            const byte = bytes[read_idx];

            if (self.term.osc99_active) {
                if (self.term.osc99_st_pending) {
                    if (byte == '\\') {
                        self.finishNotificationOscSequence();
                    } else {
                        self.appendOsc99Byte(0x1b);
                        self.appendOsc99Byte(byte);
                    }
                    self.term.osc99_st_pending = false;
                    read_idx += 1;
                    continue;
                }

                if (byte == 0x07) {
                    self.finishNotificationOscSequence();
                    read_idx += 1;
                    continue;
                }
                if (byte == 0x1b) {
                    self.term.osc99_st_pending = true;
                    read_idx += 1;
                    continue;
                }

                self.appendOsc99Byte(byte);
                read_idx += 1;
                continue;
            }

            if (self.term.htp_osc_active) {
                if (self.term.htp_osc_st_pending) {
                    if (byte == '\\') {
                        self.finishHtpOscSequence();
                    } else {
                        self.appendHtpOscByte(0x1b);
                        self.appendHtpOscByte(byte);
                    }
                    self.term.htp_osc_st_pending = false;
                    read_idx += 1;
                    continue;
                }

                if (byte == 0x07) {
                    self.finishHtpOscSequence();
                    read_idx += 1;
                    continue;
                }
                if (byte == 0x1b) {
                    self.term.htp_osc_st_pending = true;
                    read_idx += 1;
                    continue;
                }

                self.appendHtpOscByte(byte);
                read_idx += 1;
                continue;
            }

            if (self.term.osc1337_active) {
                if (self.term.osc1337_st_pending) {
                    if (byte == '\\') {
                        self.finishOsc1337Sequence();
                    } else {
                        self.appendOsc1337Byte(0x1b);
                        self.appendOsc1337Byte(byte);
                    }
                    self.term.osc1337_st_pending = false;
                    read_idx += 1;
                    continue;
                }

                if (byte == 0x07) {
                    self.finishOsc1337Sequence();
                    read_idx += 1;
                    continue;
                }
                if (byte == 0x1b) {
                    self.term.osc1337_st_pending = true;
                    read_idx += 1;
                    continue;
                }

                self.appendOsc1337Byte(byte);
                read_idx += 1;
                continue;
            }

            if (self.term.osc_prefix_len > 0) {
                if (self.term.osc_prefix_len < self.term.osc_prefix_buf.len) {
                    self.term.osc_prefix_buf[self.term.osc_prefix_len] = byte;
                    self.term.osc_prefix_len += 1;
                    read_idx += 1;
                } else {
                    fastmem.copy(u8, self.term.pty_sanitize_buf[write_idx .. write_idx + self.term.osc_prefix_len], self.term.osc_prefix_buf[0..self.term.osc_prefix_len]);
                    write_idx += self.term.osc_prefix_len;
                    self.term.osc_prefix_len = 0;
                    continue;
                }

                const prefix = self.term.osc_prefix_buf[0..self.term.osc_prefix_len];
                switch (classifyOscPrefix(prefix)) {
                    .osc99 => {
                        self.beginNotificationOscSequence();
                        self.term.osc_prefix_len = 0;
                        continue;
                    },
                    .htp => {
                        self.term.htp_osc_active = true;
                        self.term.htp_osc_st_pending = false;
                        self.term.htp_osc_overflow = false;
                        self.term.htp_osc_len = 0;
                        self.term.osc_prefix_len = 0;
                        continue;
                    },
                    .osc1337 => {
                        self.term.osc1337_active = true;
                        self.term.osc1337_st_pending = false;
                        self.term.osc1337_overflow = false;
                        self.term.osc1337_buf.clearRetainingCapacity();
                        if (prefix.len > OSC1337_PREFIX.len) {
                            self.term.osc1337_buf.appendSlice(self.allocator, prefix[OSC1337_PREFIX.len..]) catch {
                                self.term.osc1337_overflow = true;
                            };
                        }
                        self.term.osc_prefix_len = 0;
                        continue;
                    },
                    .partial => continue,
                    .none => {
                        fastmem.copy(u8, self.term.pty_sanitize_buf[write_idx .. write_idx + prefix.len], prefix);
                        write_idx += prefix.len;
                        self.term.osc_prefix_len = 0;
                        continue;
                    },
                }
            }

            if (byte == 0x1b) {
                const next = if (read_idx + 1 < bytes.len) bytes[read_idx + 1] else null;
                if (next == null or next.? == ']') {
                    self.term.osc_prefix_buf[0] = 0x1b;
                    self.term.osc_prefix_len = 1;
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

            self.term.pty_sanitize_buf[write_idx] = byte;
            write_idx += 1;
            read_idx += 1;
        }

        if (windows_mode) {
            const tail_len = trailingAnsiPrefixLen(self.term.pty_sanitize_buf[0..write_idx]);
            self.term.pty_pending_len = tail_len;
            if (tail_len > 0) {
                fastmem.copy(u8, self.term.pty_pending_seq[0..tail_len], self.term.pty_sanitize_buf[write_idx - tail_len .. write_idx]);
                write_idx -= tail_len;
            }
        }

        return self.term.pty_sanitize_buf[0..write_idx];
    }

    fn appendHtpOscByte(self: *RuntimeContext, byte: u8) void {
        if (self.term.htp_osc_buf.len == 0) {
            self.term.htp_osc_buf = self.allocator.alloc(u8, HTP_OSC_LOG_MAX) catch {
                self.term.htp_osc_overflow = true;
                return;
            };
        }
        if (self.term.htp_osc_len >= self.term.htp_osc_buf.len) {
            self.term.htp_osc_overflow = true;
            return;
        }
        self.term.htp_osc_buf[self.term.htp_osc_len] = byte;
        self.term.htp_osc_len += 1;
    }

    fn appendOsc1337Byte(self: *RuntimeContext, byte: u8) void {
        if (self.term.osc1337_buf.items.len >= OSC1337_SEQUENCE_MAX) {
            self.term.osc1337_overflow = true;
            return;
        }
        self.term.osc1337_buf.append(self.allocator, byte) catch {
            self.term.osc1337_overflow = true;
        };
    }

    fn beginNotificationOscSequence(self: *RuntimeContext) void {
        self.term.osc99_active = true;
        self.term.osc99_st_pending = false;
        self.term.osc99_overflow = false;
        self.term.osc99_buf.clearRetainingCapacity();
    }

    fn appendOsc99Byte(self: *RuntimeContext, byte: u8) void {
        if (self.term.osc99_buf.items.len >= osc99.max_sequence_bytes) {
            self.term.osc99_overflow = true;
            return;
        }
        self.term.osc99_buf.append(self.allocator, byte) catch {
            self.term.osc99_overflow = true;
        };
    }

    fn finishHtpOscSequence(self: *RuntimeContext) void {
        if (!self.term.htp_osc_overflow and self.term.htp_osc_len > 0) {
            const payload = self.term.htp_osc_buf[0..self.term.htp_osc_len];
            if (self.term.htp_message_handler) |handler| handler(self.node, payload);
        } else if (self.term.htp_osc_overflow) {
            std.log.warn("htp: dropped oversized osc pane={x} bytes={d}", .{ self.node.id, self.term.htp_osc_len });
        }
        self.term.htp_osc_active = false;
        self.term.htp_osc_st_pending = false;
        self.term.htp_osc_overflow = false;
        self.term.htp_osc_len = 0;
    }

    fn finishOsc1337Sequence(self: *RuntimeContext) void {
        if (!self.term.osc1337_overflow and self.term.osc1337_buf.items.len > 0) {
            self.applyOsc1337Sequence(self.term.osc1337_buf.items);
        }
        self.term.osc1337_active = false;
        self.term.osc1337_st_pending = false;
        self.term.osc1337_overflow = false;
        self.term.osc1337_buf.clearRetainingCapacity();
    }

    fn finishNotificationOscSequence(self: *RuntimeContext) void {
        if (!self.term.osc99_overflow and self.term.osc99_buf.items.len > 0) {
            self.term.osc99_notifications.feed(self.allocator, self.term.osc99_buf.items) catch |err| {
                std.log.warn("osc99: failed to queue notification pane={x} err={s}", .{ self.node.id, @errorName(err) });
            };
        }
        self.term.osc99_active = false;
        self.term.osc99_st_pending = false;
        self.term.osc99_overflow = false;
        self.term.osc99_buf.clearRetainingCapacity();
    }

    fn applyOsc1337Sequence(self: *RuntimeContext, payload: []const u8) void {
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

        self.term.pending_terminal_inject.clearRetainingCapacity();
        self.term.pending_terminal_inject.appendSlice(self.allocator, "\x1b_Ga=T,f=100,q=2") catch return;
        if (width_cells) |cols| {
            const value = std.fmt.allocPrint(self.allocator, ",c={d}", .{cols}) catch return;
            defer self.allocator.free(value);
            self.term.pending_terminal_inject.appendSlice(self.allocator, value) catch return;
        }
        if (height_cells) |rows| {
            const value = std.fmt.allocPrint(self.allocator, ",r={d}", .{rows}) catch return;
            defer self.allocator.free(value);
            self.term.pending_terminal_inject.appendSlice(self.allocator, value) catch return;
        }
        self.term.pending_terminal_inject.append(self.allocator, ';') catch return;
        self.term.pending_terminal_inject.appendSlice(self.allocator, data) catch return;
        self.term.pending_terminal_inject.appendSlice(self.allocator, "\x1b\\") catch return;
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

test "pane node separates shared metadata from terminal runtime storage" {
    inline for (.{
        "host_wake",                  "spawn_filter",          "pty_host",                "pty",                         "terminal",                 "render_state",
        "boot_output",                "pending_startup_input", "pending_cwd",             "htp_message_handler",         "pty_received_data",        "pty_wrote_this_frame",
        "synchronized_output_active", "active_screen",         "last_mouse_tracking",     "last_render_state_update_ns", "image_storage_generation", "image_animation_deadline_ns",
        "viewport_scroll_pending",    "compression_activity",  "compression_deadline_ns", "child_alive_cached",          "exit_event_emitted",       "automation_command_id",
        "automation_token",           "retain_on_exit",        "job_output",              "scrollbar_total",             "scrollbar_offset",         "scrollbar_len",
        "domain_name",                "is_remote",
    }) |field| {
        try std.testing.expect(!@hasField(Pane, field));
        try std.testing.expect(@hasField(TerminalPane, field));
    }
    inline for (.{ "id", "cols", "rows", "title", "cwd", "program_status", "foreground_process", "render_dirty", "x_px", "y_px", "width_px", "height_px", "is_floating" }) |field| {
        try std.testing.expect(@hasField(Pane, field));
        try std.testing.expect(!@hasField(TerminalPane, field));
    }
}

test "bootstrap callbacks retain pane node after runtime context returns" {
    if (is_windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var runtime = try GhosttyRuntime.init(a, null);
    defer runtime.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    cfg.shell = try a.dupe(u8, "/bin/sh");
    var pane = Pane.init(a);
    defer pane.deinit(&runtime);
    try pane.content.terminal.bootstrap(&pane, &runtime, @import("../app/terminal_callbacks.zig").terminalCallbacks(), cfg, 8, 16, 640, 384, null, null, .{
        .command = "read -r reply",
    }, null);

    // Bootstrap's stack-local RuntimeContext is gone. Real native callbacks
    // must still mutate the pane and its owned terminal storage.
    pane.cwd_dirty = false;
    runtime.terminalWrite(pane.content.terminal.terminal, "\x1b]7;file://localhost/bootstrap-callback-test\x07\x1b]2;callback title\x07\x07");
    try std.testing.expect(pane.cwd_dirty);
    try std.testing.expectEqualStrings("/bootstrap-callback-test", pane.content.terminal.pending_cwd.?);
    try std.testing.expect(pane.refreshCwd());
    try std.testing.expectEqualStrings("/bootstrap-callback-test", pane.cwd);
    try std.testing.expect(pane.title_dirty);
    try std.testing.expect(pane.bell_dirty);
    pane.refreshTitle(&runtime, "fallback", "/bin/sh");
    try std.testing.expectEqualStrings("callback title", pane.title);
}

test "background PTY parses blocked and error after rendering helpers are released" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var runtime = try GhosttyRuntime.init(a, null);
    defer runtime.deinit();
    var pane = Pane.init(a);
    pane.content.terminal.terminal_runtime = &runtime;
    pane.content.terminal.terminal = try runtime.createTerminal(80, 24, 0);
    defer pane.deinit(&runtime);
    runtime.setTerminalUserdata(pane.content.terminal.terminal, &pane);
    runtime.registerCallbacks(pane.content.terminal.terminal, @import("../app/terminal_callbacks.zig").terminalCallbacks());
    pane.content.terminal.pty = try @import("../pty/pty.zig").spawnNative(a, "/bin/sh", 80, 24, null, null, .{
        .command = "printf '\\033]7501;state=working\\007'; read -r reply; printf '\\033]7501;state=blocked:kind=permission\\007'; read -r reply; printf '\\033]133;A\\007'; read -r reply; printf '\\033]7501;state=error\\007\\033]133;A\\007\\033[?1049h'; read -r reply",
    }, .{});

    const Wait = struct {
        const Expected = union(enum) { startup, state: @import("program_status.zig").StateKind, cleared };

        fn poll(p: *Pane, rt: *GhosttyRuntime, expected: Expected) !void {
            const deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
            while (io.nanoTimestamp() < deadline) {
                _ = try p.content.terminal.pollPty(p, rt, 8, 64 * 1024, 10 * std.time.ns_per_ms, 4096, false);
                switch (expected) {
                    .state => |state| if (p.program_status.records.items.len == 1 and p.program_status.records.items[0].state == state) return,
                    .startup => if (p.content.terminal.boot_output.items.len > 0) return,
                    .cleared => if (p.program_status.records.items.len == 0) return,
                }
                try std.Io.sleep(io.get(), .fromMilliseconds(5), .awake);
            }
            return error.TestUnexpectedResult;
        }
    };
    // Preserve startup deferral until the initial layout completes.
    try Wait.poll(&pane, &runtime, .startup);
    try std.testing.expectEqual(@as(usize, 0), pane.program_status.records.items.len);
    pane.content.terminal.recreateRenderHelpers(&runtime);
    pane.content.terminal.render_state_ready = true;
    pane.content.terminal.terminal_output_ready = true;
    try Wait.poll(&pane, &runtime, .{ .state = .working });

    // This is the resource transition used when switching tabs/workspaces.
    pane.content.terminal.releaseRenderHelpers(&runtime);
    try std.testing.expect(!pane.content.terminal.render_state_ready);
    pane.content.terminal.sendText("\n");
    try Wait.poll(&pane, &runtime, .{ .state = .blocked });
    try std.testing.expectEqual(@import("program_status.zig").BlockKind.permission, pane.program_status.records.items[0].kind);
    // Prompt return clears transient blocked state. Observe that separately
    // rather than racing it against the blocked report in the same PTY chunk.
    pane.content.terminal.sendText("\n");
    try Wait.poll(&pane, &runtime, .cleared);
    pane.content.terminal.sendText("\n");
    try Wait.poll(&pane, &runtime, .{ .state = .failure });
    try std.testing.expectEqual(@backingInt(ghostty.TerminalScreen.alternate), pane.content.terminal.active_screen);
    try std.testing.expect(!pane.content.terminal.hasRenderHelpers());
    try std.testing.expectEqual(@as(usize, 0), pane.content.terminal.boot_output.items.len);
}

fn sanitizeForTest(node: *Pane, bytes: []u8, windows_mode: bool) []const u8 {
    var context: RuntimeContext = .{ .node = node, .term = &node.content.terminal, .allocator = node.allocator };
    return context.sanitizePtyOutputForPlatform(bytes, windows_mode);
}

test "sanitizePtyOutput windows strips split 9001 mode sequence" {
    var pane = Pane.init(std.testing.allocator);
    defer if (pane.cwd.len > 0) std.testing.allocator.free(pane.cwd);

    var part1 = [_]u8{ 0x1b, '[', '?', '9' };
    const out1 = sanitizeForTest(&pane, part1[0..], true);
    try std.testing.expectEqual(@as(usize, 0), out1.len);
    try std.testing.expectEqual(@as(usize, 4), pane.content.terminal.pty_pending_len);

    var part2 = [_]u8{ '0', '0', '1', 'h', 'A' };
    const out2 = sanitizeForTest(&pane, part2[0..], true);
    try std.testing.expectEqualStrings("A", out2);
    try std.testing.expectEqual(@as(usize, 0), pane.content.terminal.pty_pending_len);
}

test "sanitizePtyOutput windows strips split csi t sequence" {
    var pane = Pane.init(std.testing.allocator);
    defer if (pane.cwd.len > 0) std.testing.allocator.free(pane.cwd);

    var part1 = [_]u8{ 'x', 0x1b, '[', '8', ';' };
    const out1 = sanitizeForTest(&pane, part1[0..], true);
    try std.testing.expectEqualStrings("x", out1);
    try std.testing.expectEqual(@as(usize, 4), pane.content.terminal.pty_pending_len);

    var part2 = [_]u8{ '2', '4', 't', 'y' };
    const out2 = sanitizeForTest(&pane, part2[0..], true);
    try std.testing.expectEqualStrings("y", out2);
    try std.testing.expectEqual(@as(usize, 0), pane.content.terminal.pty_pending_len);
}

test "sanitizePtyOutput windows preserves ordinary CSI output in place" {
    var pane = Pane.init(std.testing.allocator);
    var input = "plain\x1b[38;5;42mcolored\x1b[0m".*;

    const output = sanitizeForTest(&pane, &input, true);

    try std.testing.expectEqualStrings(&input, output);
    try std.testing.expectEqual(@intFromPtr(&input), @intFromPtr(output.ptr));
}

test "sanitizePtyOutput forwards split OSC 7 to Ghostty" {
    var pane = Pane.init(std.testing.allocator);
    defer if (pane.cwd.len > 0) std.testing.allocator.free(pane.cwd);

    var part1 = [_]u8{ 0x1b, ']', '7', ';', 'f', 'i', 'l', 'e', ':', '/', '/' };
    const out1 = sanitizeForTest(&pane, part1[0..], false);
    try std.testing.expectEqualStrings(&part1, out1);

    var part2 = [_]u8{ '/', 't', 'm', 'p', 0x07, 'Z' };
    const out2 = sanitizeForTest(&pane, part2[0..], false);
    try std.testing.expectEqualStrings(&part2, out2);
    try std.testing.expect(!pane.cwd_dirty);
}

test "sanitizePtyOutput captures split OSC 99 notification packets" {
    var pane = Pane.init(std.testing.allocator);
    defer pane.content.terminal.osc99_buf.deinit(std.testing.allocator);
    defer pane.content.terminal.osc99_notifications.deinit(std.testing.allocator);

    var part1 = "\x1b]99;i=build:d=0:p=title;Build finished\x1b\\".*;
    const out1 = sanitizeForTest(&pane, &part1, false);
    try std.testing.expectEqual(@as(usize, 0), out1.len);
    try std.testing.expect(!pane.content.terminal.osc99_active);
    try std.testing.expectEqual(@as(usize, 1), pane.content.terminal.osc99_notifications.assemblies.items.len);
    try std.testing.expect(!pane.content.terminal.osc99_notifications.hasNotifications());

    var part2 = "\x1b]99;i=build:p=body:u=2:w=5000;All tests passed\x1b".*;
    const out2 = sanitizeForTest(&pane, &part2, false);
    try std.testing.expectEqual(@as(usize, 0), out2.len);
    try std.testing.expect(pane.content.terminal.osc99_active);
    try std.testing.expect(pane.content.terminal.osc99_st_pending);
    try std.testing.expectEqualStrings("i=build:p=body:u=2:w=5000;All tests passed", pane.content.terminal.osc99_buf.items);

    var part3 = "\\Z".*;
    const out3 = sanitizeForTest(&pane, &part3, false);
    try std.testing.expectEqualStrings("Z", out3);
    try std.testing.expect(!pane.content.terminal.osc99_active);
    try std.testing.expect(pane.content.terminal.osc99_notifications.hasNotifications());

    var result = pane.content.terminal.osc99_notifications.popNotification().?;
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("build", result.id.?);
    try std.testing.expectEqualStrings("Build finished", result.title);
    try std.testing.expectEqualStrings("All tests passed", result.message);
    try std.testing.expectEqual(@as(?u64, 5000), result.ttl_ms);
}

test "image animation invalidates fresh snapshots and schedules next frame" {
    var runtime = try GhosttyRuntime.init(std.testing.allocator, null);
    defer runtime.deinit();
    var pane = Pane.init(std.testing.allocator);
    pane.content.terminal.terminal = try runtime.createTerminal(20, 6, 0);
    defer pane.deinit(&runtime);
    runtime.terminalWrite(pane.content.terminal.terminal, "\x1b_Ga=T,f=32,i=2,s=1,v=1,q=2;/wAA/w==\x1b\\" ++
        "\x1b_Ga=f,f=32,i=2,s=1,v=1,z=40,q=2;AAD//w==\x1b\\" ++
        "\x1b_Ga=a,i=2,r=1,z=30,q=2\x1b\\\x1b_Ga=a,i=2,s=3,q=2\x1b\\");
    pane.content.terminal.render_state_fresh = true;
    try std.testing.expect(pane.content.terminal.tickImageAnimation(&runtime, 1000 * std.time.ns_per_ms));
    try std.testing.expect(!pane.content.terminal.render_state_fresh);
    try std.testing.expectEqual(@as(i128, 1030 * std.time.ns_per_ms), pane.content.terminal.image_animation_deadline_ns);
    pane.content.terminal.render_state_fresh = true;
    try std.testing.expect(!pane.content.terminal.tickImageAnimation(&runtime, 1010 * std.time.ns_per_ms));
    try std.testing.expect(pane.content.terminal.render_state_fresh);
    try std.testing.expect(pane.content.terminal.tickImageAnimation(&runtime, pane.content.terminal.image_animation_deadline_ns));
    try std.testing.expect(!pane.content.terminal.render_state_fresh);
}

test "sanitizePtyOutput forwards native OSC 9 and OSC 777 protocols" {
    var pane = Pane.init(std.testing.allocator);
    defer pane.content.terminal.osc99_buf.deinit(std.testing.allocator);
    defer pane.content.terminal.osc99_notifications.deinit(std.testing.allocator);

    var input = "\x1b]9;Build complete\x07 \x1b]777;notify;Build;Tests passed\x1b\\X".*;
    const output = sanitizeForTest(&pane, &input, false);
    try std.testing.expectEqualStrings("\x1b]9;Build complete\x07 \x1b]777;notify;Build;Tests passed\x1b\\X", output);
    try std.testing.expect(!pane.content.terminal.osc99_notifications.hasNotifications());
}

test "sanitizePtyOutput does not turn ConEmu OSC 9 commands into notifications" {
    var pane = Pane.init(std.testing.allocator);
    defer pane.content.terminal.osc99_buf.deinit(std.testing.allocator);
    defer pane.content.terminal.osc99_notifications.deinit(std.testing.allocator);

    var input = "\x1b]9;1;420\x07X".*;
    const output = sanitizeForTest(&pane, &input, false);
    try std.testing.expectEqualStrings("\x1b]9;1;420\x07X", output);
    try std.testing.expect(!pane.content.terminal.osc99_notifications.hasNotifications());
}

test "sendUserText queues raw input behind pending startup input" {
    var pane = Pane.init(std.testing.allocator);
    defer if (pane.content.terminal.pending_startup_input.len > 0) std.testing.allocator.free(pane.content.terminal.pending_startup_input);

    try pane.content.terminal.queueStartupInput(std.testing.allocator, "cd -- '/tmp'");
    pane.content.terminal.sendUserText(std.testing.allocator, "nvim\r");

    try std.testing.expectEqualStrings("cd -- '/tmp'\rnvim\r", pane.content.terminal.pending_startup_input);
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
    try std.testing.expect(RuntimeContext.shouldIgnoreWindowsShellTitle("\\\\wsl.localhost\\Ubuntu\\home\\francis", "zsh", true));
    try std.testing.expect(RuntimeContext.shouldIgnoreWindowsShellTitle("\\\\wsl$\\Ubuntu\\home\\francis", "zsh", true));
    try std.testing.expect(!RuntimeContext.shouldIgnoreWindowsShellTitle("\\\\wsl.localhost\\Ubuntu\\home\\francis", "zsh", false));
}
