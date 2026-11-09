const std = @import("std");
const Config = @import("config.zig").Config;
const ghostty = @import("term/ghostty.zig");
const GhosttyRuntime = ghostty.Runtime;
const TerminalPane = @import("term/terminal_pane.zig").TerminalPane;
const LuaSurface = @import("ui/lua_surface.zig").LuaSurface;
const policy = @import("term/pty_policy.zig");

pub const PTY_PARSE_CHUNK_BYTES = policy.parse_chunk_bytes;
pub const PTY_PRESSURE_PARSE_CHUNK_BYTES = policy.pressure_parse_chunk_bytes;
pub const PTY_HARD_BYTE_LIMIT = policy.hard_byte_limit;

/// Content-independent pane identity, layout and shared status. Content
/// specific state lives in `content`.
pub const Pane = struct {
    pub const HtpMessageHandler = TerminalPane.HtpMessageHandler;
    pub const Content = union(enum) {
        terminal: TerminalPane,
        /// Owned by the pane; released in `deinit`.
        lua: *LuaSurface,
    };

    content: Content = .{ .terminal = .{} },
    /// Zero denotes a pane not yet published by a mux.
    id: usize = 0,
    allocator: std.mem.Allocator,
    host_context: ?*anyopaque = null,
    foreground_process: ?[]u8 = null,
    title: []u8 = &.{},
    cwd: []u8 = &.{},
    program_status: @import("term/program_status.zig").State = .{},
    cols: u16 = 0,
    rows: u16 = 0,
    /// Retained texture damage, shared by terminal and Lua content.
    render_dirty: ghostty.RenderStateDirty = .false_value,
    title_dirty: bool = false,
    title_is_manual: bool = false,
    bell_dirty: bool = false,
    bell_active: bool = false,
    bell_started_at_ns: i128 = 0,
    bell_flash_color: ?ghostty.ColorRgb = null,
    has_bell_attention: bool = false,
    x_px: u32 = 0,
    y_px: u32 = 0,
    width_px: u32 = 0,
    height_px: u32 = 0,
    cwd_dirty: bool = false,
    is_floating: bool = false,
    /// Presentation only: hidden panes retain their PTY, mux identity, and split position.
    is_hidden: bool = false,
    /// Edge requested at creation. Only meaningful while the split tree still
    /// docks the pane there; see `Tab.paneEdge`.
    placed_edge: ?@import("mux/types.zig").PaneEdge = null,
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

    /// Pane with Lua content. Takes ownership of `surface`.
    pub fn initLua(allocator: std.mem.Allocator, surface: *LuaSurface) Pane {
        return .{ .allocator = allocator, .content = .{ .lua = surface } };
    }

    pub fn isTerminal(self: *const Pane) bool {
        return self.content == .terminal;
    }

    pub fn asLua(self: *const Pane) ?*LuaSurface {
        return switch (self.content) {
            .lua => |surface| surface,
            .terminal => null,
        };
    }

    /// Narrow content once at generic entry points. Terminal helpers receive
    /// this pointer rather than depending on the pane's storage layout.
    pub fn asTerminal(self: *Pane) ?*TerminalPane {
        return switch (self.content) {
            .terminal => |*term| term,
            .lua => null,
        };
    }

    pub fn asTerminalConst(self: *const Pane) ?*const TerminalPane {
        return switch (self.content) {
            .terminal => |*term| term,
            .lua => null,
        };
    }

    /// Domain of terminal content; empty for local terminals and other content.
    pub fn domainName(self: *const Pane) []const u8 {
        const term = self.asTerminalConst() orelse return "";
        return term.domain_name;
    }

    pub fn invalidate(self: *Pane) void {
        self.render_dirty = .full;
        if (self.asLua()) |surface| surface.dirty = true;
    }

    pub fn applyTerminalTheme(self: *Pane, runtime: *GhosttyRuntime, theme: *const Config.TerminalTheme) void {
        if (self.asTerminal()) |term| {
            runtime.setTerminalDefaultColors(term.terminal, theme.foreground, theme.background, theme.cursor, &theme.palette);
        }
        self.invalidate();
    }

    pub fn deinit(self: *Pane, runtime: *GhosttyRuntime) void {
        switch (self.content) {
            .terminal => |*term| term.deinit(runtime, self.allocator),
            .lua => |surface| {
                surface.deinit(self.allocator);
                self.allocator.destroy(surface);
            },
        }
        self.program_status.deinit(self.allocator);
        if (self.title.len > 0) self.allocator.free(self.title);
        if (self.cwd.len > 0) self.allocator.free(self.cwd);
        self.* = Pane.init(self.allocator);
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
            self.title_dirty = self.isTerminal();
            return;
        }
        self.title = self.allocator.dupe(u8, title) catch &.{};
        self.title_is_manual = self.title.len > 0;
        self.title_dirty = false;
    }

    pub fn refreshCwd(self: *Pane) bool {
        const term = self.asTerminal() orelse return false;
        return term.refreshCwd(self);
    }

    pub fn resize(self: *Pane, runtime: *GhosttyRuntime, cols: u16, rows: u16, cell_width_px: u32, cell_height_px: u32, skip_pty: bool) void {
        const term = self.asTerminal() orelse {
            self.cols = cols;
            self.rows = rows;
            self.invalidate();
            return;
        };
        term.resize(self, runtime, cols, rows, cell_width_px, cell_height_px, skip_pty);
    }

    pub fn refreshTitle(self: *Pane, runtime: *GhosttyRuntime, fallback_title: []const u8, shell_command: []const u8) void {
        if (self.asTerminal()) |term| term.refreshTitle(self, runtime, fallback_title, shell_command);
    }
};

test {
    _ = @import("term/pane_runtime.zig");
}
