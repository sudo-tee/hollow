const std = @import("std");
const platform = @import("../platform.zig");

pub const success = 0;

pub const TerminalOptions = extern struct {
    cols: u16,
    rows: u16,
    max_scrollback: u32,
};

pub const ColorRgb = extern struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const StyleColorTag = enum(u32) {
    none = 0,
    palette = 1,
    rgb = 2,
};

pub const StyleColorValue = extern union {
    palette: u8,
    rgb: ColorRgb,
    _padding: u64,
};

pub const StyleColor = extern struct {
    tag: StyleColorTag,
    value: StyleColorValue,
};

pub const Style = extern struct {
    size: usize,
    fg_color: StyleColor,
    bg_color: StyleColor,
    underline_color: StyleColor,
    bold: bool,
    italic: bool,
    faint: bool,
    blink: bool,
    inverse: bool,
    invisible: bool,
    strikethrough: bool,
    overline: bool,
    underline: i32,
};

pub const RenderStateColors = extern struct {
    size: usize,
    background: ColorRgb,
    foreground: ColorRgb,
    cursor: ColorRgb,
    cursor_has_value: bool,
    palette: [256]ColorRgb,
};

pub const TerminalScrollbar = extern struct {
    total: u64,
    offset: u64,
    len: u64,
};

pub const SizeReportSize = extern struct {
    rows: u16,
    columns: u16,
    cell_width: u32,
    cell_height: u32,
};

pub const ColorScheme = enum(c_int) {
    light = 0,
    dark = 1,
};

pub const DeviceAttributesPrimary = extern struct {
    conformance_level: u16,
    features: [64]u16,
    num_features: usize,
};

pub const DeviceAttributesSecondary = extern struct {
    device_type: u16,
    firmware_version: u16,
    rom_cartridge: u16,
};

pub const DeviceAttributesTertiary = extern struct {
    unit_id: u32,
};

pub const DeviceAttributes = extern struct {
    primary: DeviceAttributesPrimary,
    secondary: DeviceAttributesSecondary,
    tertiary: DeviceAttributesTertiary,
};

pub const String = extern struct {
    ptr: ?[*]const u8,
    len: usize,
};

pub const ScrollViewport = extern struct {
    tag: u32,
    value: extern union {
        delta: isize,
    },
};

pub const MousePosition = extern struct {
    x: f32,
    y: f32,
};

pub const MouseEncoderSize = extern struct {
    size: usize,
    screen_width: u32,
    screen_height: u32,
    cell_width: u32,
    cell_height: u32,
    padding_top: u32,
    padding_bottom: u32,
    padding_left: u32,
    padding_right: u32,
};

pub const TerminalOpt = enum(u32) {
    userdata = 0,
    write_pty = 1,
    bell = 2,
    enquiry = 3,
    xtversion = 4,
    title_changed = 5,
    size = 6,
    color_scheme = 7,
    device_attributes = 8,
};

pub const TerminalData = enum(u32) {
    title = 12,
    scrollbar = 9,
    mouse_tracking = 11,
};

pub const Mode = enum(u32) {
    focus_event = 1004,
    bracketed_paste = 2004,
};

pub const RenderStateData = enum(u32) {
    invalid = 0,
    cols = 1,
    rows = 2,
    dirty = 3,
    row_iterator = 4,
    color_background = 5,
    color_foreground = 6,
    color_cursor = 7,
    color_cursor_has_value = 8,
    color_palette = 9,
    cursor_visual_style = 10,
    cursor_visible = 11,
    cursor_blinking = 12,
    cursor_password_input = 13,
    cursor_viewport_has_value = 14,
    cursor_viewport_x = 15,
    cursor_viewport_y = 16,
    cursor_viewport_wide_tail = 17,
};

pub const CursorVisualStyle = enum(u32) {
    bar = 0,
    block = 1,
    underline = 2,
    block_hollow = 3,
};

pub const RenderStateOpt = enum(u32) {
    dirty = 0,
};

pub const RenderStateDirty = enum(u32) {
    false_value = 0,
    true_value = 1,
    full = 2,
};

pub const RowData = enum(u32) {
    invalid = 0,
    dirty = 1,
    raw = 2,
    cells = 3,
};

pub const RowOpt = enum(u32) {
    dirty = 0,
};

pub const CellData = enum(u32) {
    invalid = 0,
    raw = 1,
    style = 2,
    graphemes_len = 3,
    graphemes_buf = 4,
    bg_color = 5,
    fg_color = 6,
};

/// Data kinds for the pure ghostty_cell_get() function (operates on a u64 cell value).
pub const CellDataV = enum(u32) {
    invalid = 0,
    codepoint = 1,
    content_tag = 2,
    wide = 3,
    has_text = 4,
    has_styling = 5,
    style_id = 6,
    has_hyperlink = 7,
    protected = 8,
    semantic_content = 9,
    color_palette = 10,
    color_rgb = 11,
};

/// Content tag values returned by CellDataV.content_tag
pub const CellContentTag = enum(u32) {
    codepoint = 0,
    codepoint_grapheme = 1,
    bg_color_palette = 2,
    bg_color_rgb = 3,
};

pub const MouseEncOpt = enum(u32) {
    size = 0,
    any_button_pressed = 1,
    track_last_cell = 2,
};

pub const MouseAction = enum(u32) {
    press = 0,
    release = 1,
    motion = 2,
};

pub const MouseButton = enum(u32) {
    unknown = 0,
    left = 1,
    right = 2,
    middle = 3,
    four = 4,
    five = 5,
    six = 6,
    seven = 7,
};

pub const KeyAction = enum(u32) {
    release = 0,
    press = 1,
    repeat = 2,
};

pub const Mods = struct {
    pub const none: u32 = 0;
    pub const shift: u32 = 0x01;
    pub const ctrl: u32 = 0x02;
    pub const alt: u32 = 0x04;
    pub const super: u32 = 0x08;
};

pub const FocusEvent = enum(u32) {
    gained = 0,
    lost = 1,
};

pub const ScrollViewportTag = enum(u32) {
    delta = 0,
};

pub const Key = enum(u32) {
    unidentified = 0,
    backquote = 1,
    backslash = 2,
    bracket_left = 3,
    bracket_right = 4,
    comma = 5,
    digit_0 = 6,
    digit_1 = 7,
    digit_2 = 8,
    digit_3 = 9,
    digit_4 = 10,
    digit_5 = 11,
    digit_6 = 12,
    digit_7 = 13,
    digit_8 = 14,
    digit_9 = 15,
    equal = 16,
    intl_backslash = 17,
    intl_ro = 18,
    intl_yen = 19,
    a = 20,
    b = 21,
    c = 22,
    d = 23,
    e = 24,
    f = 25,
    g = 26,
    h = 27,
    i = 28,
    j = 29,
    k = 30,
    l = 31,
    m = 32,
    n = 33,
    o = 34,
    p = 35,
    q = 36,
    r = 37,
    s = 38,
    t = 39,
    u = 40,
    v = 41,
    w = 42,
    x = 43,
    y = 44,
    z = 45,
    minus = 46,
    period = 47,
    quote = 48,
    semicolon = 49,
    slash = 50,
    alt_left = 51,
    alt_right = 52,
    backspace = 53,
    caps_lock = 54,
    context_menu = 55,
    control_left = 56,
    control_right = 57,
    enter = 58,
    meta_left = 59,
    meta_right = 60,
    shift_left = 61,
    shift_right = 62,
    space = 63,
    tab = 64,
    convert = 65,
    kana_mode = 66,
    non_convert = 67,
    delete = 68,
    end = 69,
    help = 70,
    home = 71,
    insert = 72,
    page_down = 73,
    page_up = 74,
    arrow_down = 75,
    arrow_left = 76,
    arrow_right = 77,
    arrow_up = 78,
    escape = 97,
    f1 = 98,
    f2 = 99,
    f3 = 100,
    f4 = 101,
    f5 = 102,
    f6 = 103,
    f7 = 104,
    f8 = 105,
    f9 = 106,
    f10 = 107,
    f11 = 108,
    f12 = 109,
};

const WritePtyCallback = *const fn (?*anyopaque, ?*anyopaque, [*]const u8, usize) callconv(.c) void;
const BellCallback = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;
const EnquiryCallback = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) String;
const XtversionCallback = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) String;
const SizeCallback = *const fn (?*anyopaque, ?*anyopaque, *SizeReportSize) callconv(.c) bool;
const ColorSchemeCallback = *const fn (?*anyopaque, ?*anyopaque, *ColorScheme) callconv(.c) bool;
const DeviceAttributesCallback = *const fn (?*anyopaque, ?*anyopaque, *DeviceAttributes) callconv(.c) bool;
const TitleChangedCallback = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;

/// Bundle of callbacks that must be registered on every new terminal before any
/// ghostty API that might invoke them (resize, updateRenderState, vt_write).
pub const TerminalCallbacks = struct {
    write_pty: WritePtyCallback,
    bell: BellCallback,
    enquiry: EnquiryCallback,
    xtversion: XtversionCallback,
    size: SizeCallback,
    color_scheme: ColorSchemeCallback,
    device_attributes: DeviceAttributesCallback,
    title_changed: TitleChangedCallback,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    lib: std.DynLib,
    loaded_path: []u8,

    terminal_new: *const fn (?*anyopaque, *?*anyopaque, *const TerminalOptions) callconv(.c) i32,
    terminal_free: *const fn (?*anyopaque) callconv(.c) void,
    terminal_vt_write: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,
    terminal_resize: *const fn (?*anyopaque, u16, u16, u32, u32) callconv(.c) void,
    terminal_get: *const fn (?*anyopaque, u32, ?*anyopaque) callconv(.c) i32,
    terminal_set: *const fn (?*anyopaque, u32, ?*const anyopaque) callconv(.c) void,
    terminal_mode_get: *const fn (?*anyopaque, u32, *bool) callconv(.c) i32,
    terminal_scroll_viewport: *const fn (?*anyopaque, *const ScrollViewport) callconv(.c) void,

    render_state_new: *const fn (?*anyopaque, *?*anyopaque) callconv(.c) i32,
    render_state_free: *const fn (?*anyopaque) callconv(.c) void,
    render_state_update: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i32,
    render_state_get: *const fn (?*anyopaque, u32, ?*anyopaque) callconv(.c) i32,
    render_state_set: *const fn (?*anyopaque, u32, ?*const anyopaque) callconv(.c) i32,
    render_state_colors_get: *const fn (?*anyopaque, *RenderStateColors) callconv(.c) i32,

    row_iterator_new: *const fn (?*anyopaque, *?*anyopaque) callconv(.c) i32,
    row_iterator_free: *const fn (?*anyopaque) callconv(.c) void,
    row_iterator_next: *const fn (?*anyopaque) callconv(.c) bool,
    row_get: *const fn (?*anyopaque, u32, ?*anyopaque) callconv(.c) i32,
    row_set: *const fn (?*anyopaque, u32, ?*const anyopaque) callconv(.c) i32,

    row_cells_new: *const fn (?*anyopaque, *?*anyopaque) callconv(.c) i32,
    row_cells_free: *const fn (?*anyopaque) callconv(.c) void,
    row_cells_next: *const fn (?*anyopaque) callconv(.c) bool,
    row_cells_get: *const fn (?*anyopaque, u32, ?*anyopaque) callconv(.c) i32,

    /// Pure value function: extracts typed data from a raw GhosttyCell u64.
    /// Does not go through the iterator — safe to call with just the cell value.
    cell_get: *const fn (u64, u32, ?*anyopaque) callconv(.c) i32,

    key_encoder_new: *const fn (?*anyopaque, *?*anyopaque) callconv(.c) i32,
    key_encoder_free: *const fn (?*anyopaque) callconv(.c) void,
    key_encoder_setopt_from_terminal: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
    key_encoder_encode: *const fn (?*anyopaque, ?*anyopaque, [*]u8, usize, *usize) callconv(.c) i32,

    key_event_new: *const fn (?*anyopaque, *?*anyopaque) callconv(.c) i32,
    key_event_free: *const fn (?*anyopaque) callconv(.c) void,
    key_event_set_key: *const fn (?*anyopaque, u32) callconv(.c) void,
    key_event_set_action: *const fn (?*anyopaque, u32) callconv(.c) void,
    key_event_set_mods: *const fn (?*anyopaque, u32) callconv(.c) void,
    key_event_set_consumed_mods: *const fn (?*anyopaque, u32) callconv(.c) void,
    key_event_set_unshifted_codepoint: *const fn (?*anyopaque, u32) callconv(.c) void,
    key_event_set_utf8: *const fn (?*anyopaque, ?[*]const u8, usize) callconv(.c) void,

    mouse_encoder_new: *const fn (?*anyopaque, *?*anyopaque) callconv(.c) i32,
    mouse_encoder_free: *const fn (?*anyopaque) callconv(.c) void,
    mouse_encoder_setopt_from_terminal: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
    mouse_encoder_setopt: *const fn (?*anyopaque, u32, ?*const anyopaque) callconv(.c) void,
    mouse_encoder_encode: *const fn (?*anyopaque, ?*anyopaque, [*]u8, usize, *usize) callconv(.c) i32,

    mouse_event_new: *const fn (?*anyopaque, *?*anyopaque) callconv(.c) i32,
    mouse_event_free: *const fn (?*anyopaque) callconv(.c) void,
    mouse_event_set_action: *const fn (?*anyopaque, u32) callconv(.c) void,
    mouse_event_set_button: *const fn (?*anyopaque, u32) callconv(.c) void,
    mouse_event_clear_button: *const fn (?*anyopaque) callconv(.c) void,
    mouse_event_set_mods: *const fn (?*anyopaque, u32) callconv(.c) void,
    mouse_event_set_position: *const fn (?*anyopaque, *const MousePosition) callconv(.c) void,

    focus_encode: *const fn (u32, [*]u8, usize, *usize) callconv(.c) i32,

    pub fn init(allocator: std.mem.Allocator, preferred_path: ?[]const u8) !Runtime {
        if (preferred_path) |path| {
            if (loadFromCandidate(allocator, path)) |runtime| {
                return runtime;
            } else |err| switch (err) {
                error.LibraryOpenFailed => {},
                else => return err,
            }
        }

        for (platform.ghosttyLibraryCandidates()) |candidate| {
            if (loadFromCandidate(allocator, candidate)) |runtime| {
                return runtime;
            } else |err| switch (err) {
                error.LibraryOpenFailed => continue,
                else => return err,
            }
        }

        return error.LibraryOpenFailed;
    }

    fn loadFromCandidate(allocator: std.mem.Allocator, candidate: []const u8) !Runtime {
        if (loadFromPath(allocator, candidate)) |runtime| {
            return runtime;
        } else |err| switch (err) {
            error.LibraryOpenFailed => {},
            else => return err,
        }

        if (platform.resolveRelativeToExe(allocator, candidate)) |maybe_resolved| {
            if (maybe_resolved) |resolved| {
                defer allocator.free(resolved);
                return loadFromPath(allocator, resolved);
            }
        } else |_| {}

        return error.LibraryOpenFailed;
    }

    fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Runtime {
        var lib = std.DynLib.open(path) catch return error.LibraryOpenFailed;
        errdefer lib.close();

        return .{
            .allocator = allocator,
            .lib = lib,
            .loaded_path = try allocator.dupe(u8, path),
            .terminal_new = lookup(&lib, *const fn (?*anyopaque, *?*anyopaque, *const TerminalOptions) callconv(.c) i32, "ghostty_terminal_new"),
            .terminal_free = lookup(&lib, *const fn (?*anyopaque) callconv(.c) void, "ghostty_terminal_free"),
            .terminal_vt_write = lookup(&lib, *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void, "ghostty_terminal_vt_write"),
            .terminal_resize = lookup(&lib, *const fn (?*anyopaque, u16, u16, u32, u32) callconv(.c) void, "ghostty_terminal_resize"),
            .terminal_get = lookup(&lib, *const fn (?*anyopaque, u32, ?*anyopaque) callconv(.c) i32, "ghostty_terminal_get"),
            .terminal_set = lookup(&lib, *const fn (?*anyopaque, u32, ?*const anyopaque) callconv(.c) void, "ghostty_terminal_set"),
            .terminal_mode_get = lookup(&lib, *const fn (?*anyopaque, u32, *bool) callconv(.c) i32, "ghostty_terminal_mode_get"),
            .terminal_scroll_viewport = lookup(&lib, *const fn (?*anyopaque, *const ScrollViewport) callconv(.c) void, "ghostty_terminal_scroll_viewport"),
            .render_state_new = lookup(&lib, *const fn (?*anyopaque, *?*anyopaque) callconv(.c) i32, "ghostty_render_state_new"),
            .render_state_free = lookup(&lib, *const fn (?*anyopaque) callconv(.c) void, "ghostty_render_state_free"),
            .render_state_update = lookup(&lib, *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i32, "ghostty_render_state_update"),
            .render_state_get = lookup(&lib, *const fn (?*anyopaque, u32, ?*anyopaque) callconv(.c) i32, "ghostty_render_state_get"),
            .render_state_set = lookup(&lib, *const fn (?*anyopaque, u32, ?*const anyopaque) callconv(.c) i32, "ghostty_render_state_set"),
            .render_state_colors_get = lookup(&lib, *const fn (?*anyopaque, *RenderStateColors) callconv(.c) i32, "ghostty_render_state_colors_get"),
            .row_iterator_new = lookup(&lib, *const fn (?*anyopaque, *?*anyopaque) callconv(.c) i32, "ghostty_render_state_row_iterator_new"),
            .row_iterator_free = lookup(&lib, *const fn (?*anyopaque) callconv(.c) void, "ghostty_render_state_row_iterator_free"),
            .row_iterator_next = lookup(&lib, *const fn (?*anyopaque) callconv(.c) bool, "ghostty_render_state_row_iterator_next"),
            .row_get = lookup(&lib, *const fn (?*anyopaque, u32, ?*anyopaque) callconv(.c) i32, "ghostty_render_state_row_get"),
            .row_set = lookup(&lib, *const fn (?*anyopaque, u32, ?*const anyopaque) callconv(.c) i32, "ghostty_render_state_row_set"),
            .row_cells_new = lookup(&lib, *const fn (?*anyopaque, *?*anyopaque) callconv(.c) i32, "ghostty_render_state_row_cells_new"),
            .row_cells_free = lookup(&lib, *const fn (?*anyopaque) callconv(.c) void, "ghostty_render_state_row_cells_free"),
            .row_cells_next = lookup(&lib, *const fn (?*anyopaque) callconv(.c) bool, "ghostty_render_state_row_cells_next"),
            .row_cells_get = lookup(&lib, *const fn (?*anyopaque, u32, ?*anyopaque) callconv(.c) i32, "ghostty_render_state_row_cells_get"),
            .cell_get = lookup(&lib, *const fn (u64, u32, ?*anyopaque) callconv(.c) i32, "ghostty_cell_get"),
            .key_encoder_new = lookup(&lib, *const fn (?*anyopaque, *?*anyopaque) callconv(.c) i32, "ghostty_key_encoder_new"),
            .key_encoder_free = lookup(&lib, *const fn (?*anyopaque) callconv(.c) void, "ghostty_key_encoder_free"),
            .key_encoder_setopt_from_terminal = lookup(&lib, *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void, "ghostty_key_encoder_setopt_from_terminal"),
            .key_encoder_encode = lookup(&lib, *const fn (?*anyopaque, ?*anyopaque, [*]u8, usize, *usize) callconv(.c) i32, "ghostty_key_encoder_encode"),
            .key_event_new = lookup(&lib, *const fn (?*anyopaque, *?*anyopaque) callconv(.c) i32, "ghostty_key_event_new"),
            .key_event_free = lookup(&lib, *const fn (?*anyopaque) callconv(.c) void, "ghostty_key_event_free"),
            .key_event_set_key = lookup(&lib, *const fn (?*anyopaque, u32) callconv(.c) void, "ghostty_key_event_set_key"),
            .key_event_set_action = lookup(&lib, *const fn (?*anyopaque, u32) callconv(.c) void, "ghostty_key_event_set_action"),
            .key_event_set_mods = lookup(&lib, *const fn (?*anyopaque, u32) callconv(.c) void, "ghostty_key_event_set_mods"),
            .key_event_set_consumed_mods = lookup(&lib, *const fn (?*anyopaque, u32) callconv(.c) void, "ghostty_key_event_set_consumed_mods"),
            .key_event_set_unshifted_codepoint = lookup(&lib, *const fn (?*anyopaque, u32) callconv(.c) void, "ghostty_key_event_set_unshifted_codepoint"),
            .key_event_set_utf8 = lookup(&lib, *const fn (?*anyopaque, ?[*]const u8, usize) callconv(.c) void, "ghostty_key_event_set_utf8"),
            .mouse_encoder_new = lookup(&lib, *const fn (?*anyopaque, *?*anyopaque) callconv(.c) i32, "ghostty_mouse_encoder_new"),
            .mouse_encoder_free = lookup(&lib, *const fn (?*anyopaque) callconv(.c) void, "ghostty_mouse_encoder_free"),
            .mouse_encoder_setopt_from_terminal = lookup(&lib, *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void, "ghostty_mouse_encoder_setopt_from_terminal"),
            .mouse_encoder_setopt = lookup(&lib, *const fn (?*anyopaque, u32, ?*const anyopaque) callconv(.c) void, "ghostty_mouse_encoder_setopt"),
            .mouse_encoder_encode = lookup(&lib, *const fn (?*anyopaque, ?*anyopaque, [*]u8, usize, *usize) callconv(.c) i32, "ghostty_mouse_encoder_encode"),
            .mouse_event_new = lookup(&lib, *const fn (?*anyopaque, *?*anyopaque) callconv(.c) i32, "ghostty_mouse_event_new"),
            .mouse_event_free = lookup(&lib, *const fn (?*anyopaque) callconv(.c) void, "ghostty_mouse_event_free"),
            .mouse_event_set_action = lookup(&lib, *const fn (?*anyopaque, u32) callconv(.c) void, "ghostty_mouse_event_set_action"),
            .mouse_event_set_button = lookup(&lib, *const fn (?*anyopaque, u32) callconv(.c) void, "ghostty_mouse_event_set_button"),
            .mouse_event_clear_button = lookup(&lib, *const fn (?*anyopaque) callconv(.c) void, "ghostty_mouse_event_clear_button"),
            .mouse_event_set_mods = lookup(&lib, *const fn (?*anyopaque, u32) callconv(.c) void, "ghostty_mouse_event_set_mods"),
            .mouse_event_set_position = lookup(&lib, *const fn (?*anyopaque, *const MousePosition) callconv(.c) void, "ghostty_mouse_event_set_position"),
            .focus_encode = lookup(&lib, *const fn (u32, [*]u8, usize, *usize) callconv(.c) i32, "ghostty_focus_encode"),
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.lib.close();
        self.allocator.free(self.loaded_path);
    }

    pub fn createTerminal(self: *Runtime, options: TerminalOptions) !?*anyopaque {
        var handle: ?*anyopaque = null;
        const result = self.terminal_new(null, &handle, &options);
        if (result != success or handle == null) {
            return error.TerminalCreateFailed;
        }
        return handle;
    }

    pub fn freeTerminal(self: *Runtime, handle: ?*anyopaque) void {
        if (handle) |terminal| self.terminal_free(terminal);
    }

    pub fn terminalWrite(self: *Runtime, handle: ?*anyopaque, bytes: []const u8) void {
        if (handle) |terminal| {
            if (bytes.len > 0) self.terminal_vt_write(terminal, bytes.ptr, bytes.len);
        }
    }

    pub fn resizeTerminal(self: *Runtime, handle: ?*anyopaque, cols: u16, rows: u16, cell_width: u32, cell_height: u32) void {
        if (handle) |terminal| self.terminal_resize(terminal, cols, rows, cell_width, cell_height);
    }

    pub fn terminalMode(self: *Runtime, handle: ?*anyopaque, mode: Mode) bool {
        if (handle) |terminal| {
            var value = false;
            return self.terminal_mode_get(terminal, @intFromEnum(mode), &value) == success and value;
        }
        return false;
    }

    pub fn terminalTitle(self: *Runtime, allocator: std.mem.Allocator, handle: ?*anyopaque) !?[]u8 {
        if (handle) |terminal| {
            var title = String{ .ptr = null, .len = 0 };
            if (self.terminal_get(terminal, @intFromEnum(TerminalData.title), &title) == success and title.ptr != null and title.len > 0) {
                return try allocator.dupe(u8, title.ptr.?[0..title.len]);
            }
        }
        return null;
    }

    pub fn terminalScrollbar(self: *Runtime, handle: ?*anyopaque) ?TerminalScrollbar {
        if (handle) |terminal| {
            var scrollbar: TerminalScrollbar = undefined;
            if (self.terminal_get(terminal, @intFromEnum(TerminalData.scrollbar), &scrollbar) == success) return scrollbar;
        }
        return null;
    }

    pub fn terminalScroll(self: *Runtime, handle: ?*anyopaque, delta: isize) void {
        if (handle) |terminal| {
            var viewport = ScrollViewport{ .tag = @intFromEnum(ScrollViewportTag.delta), .value = .{ .delta = delta } };
            self.terminal_scroll_viewport(terminal, &viewport);
        }
    }

    pub fn setWritePtyCallback(self: *Runtime, handle: ?*anyopaque, callback: WritePtyCallback) void {
        if (handle) |terminal| self.terminal_set(terminal, @intFromEnum(TerminalOpt.write_pty), @ptrCast(callback));
    }

    pub fn setBellCallback(self: *Runtime, handle: ?*anyopaque, callback: BellCallback) void {
        if (handle) |terminal| self.terminal_set(terminal, @intFromEnum(TerminalOpt.bell), @ptrCast(callback));
    }

    pub fn setEnquiryCallback(self: *Runtime, handle: ?*anyopaque, callback: EnquiryCallback) void {
        if (handle) |terminal| self.terminal_set(terminal, @intFromEnum(TerminalOpt.enquiry), @ptrCast(callback));
    }

    pub fn setXtversionCallback(self: *Runtime, handle: ?*anyopaque, callback: XtversionCallback) void {
        if (handle) |terminal| self.terminal_set(terminal, @intFromEnum(TerminalOpt.xtversion), @ptrCast(callback));
    }

    pub fn setSizeCallback(self: *Runtime, handle: ?*anyopaque, callback: SizeCallback) void {
        if (handle) |terminal| self.terminal_set(terminal, @intFromEnum(TerminalOpt.size), @ptrCast(callback));
    }

    pub fn setColorSchemeCallback(self: *Runtime, handle: ?*anyopaque, callback: ColorSchemeCallback) void {
        if (handle) |terminal| self.terminal_set(terminal, @intFromEnum(TerminalOpt.color_scheme), @ptrCast(callback));
    }

    pub fn setDeviceAttributesCallback(self: *Runtime, handle: ?*anyopaque, callback: DeviceAttributesCallback) void {
        if (handle) |terminal| self.terminal_set(terminal, @intFromEnum(TerminalOpt.device_attributes), @ptrCast(callback));
    }

    pub fn setTitleChangedCallback(self: *Runtime, handle: ?*anyopaque, callback: TitleChangedCallback) void {
        if (handle) |terminal| self.terminal_set(terminal, @intFromEnum(TerminalOpt.title_changed), @ptrCast(callback));
    }

    /// Register all terminal callbacks on `handle` in one call. Must be called
    /// before any ghostty API that might invoke them (resize, updateRenderState).
    pub fn registerCallbacks(self: *Runtime, handle: ?*anyopaque, cbs: TerminalCallbacks) void {
        self.setWritePtyCallback(handle, cbs.write_pty);
        self.setBellCallback(handle, cbs.bell);
        self.setEnquiryCallback(handle, cbs.enquiry);
        self.setXtversionCallback(handle, cbs.xtversion);
        self.setSizeCallback(handle, cbs.size);
        self.setColorSchemeCallback(handle, cbs.color_scheme);
        self.setDeviceAttributesCallback(handle, cbs.device_attributes);
        self.setTitleChangedCallback(handle, cbs.title_changed);
    }

    pub fn createRenderState(self: *Runtime) !?*anyopaque {
        var handle: ?*anyopaque = null;
        const result = self.render_state_new(null, &handle);
        if (result != success or handle == null) return error.RenderStateCreateFailed;
        return handle;
    }

    pub fn freeRenderState(self: *Runtime, handle: ?*anyopaque) void {
        if (handle) |render_state| self.render_state_free(render_state);
    }

    pub fn updateRenderState(self: *Runtime, render_state: ?*anyopaque, terminal: ?*anyopaque) !void {
        if (render_state == null or terminal == null) return;
        if (self.render_state_update(render_state, terminal) != success) return error.RenderStateUpdateFailed;
    }

    pub fn getRenderStateDirty(self: *Runtime, render_state: ?*anyopaque) ?RenderStateDirty {
        if (render_state) |state| {
            var dirty: u32 = 0;
            if (self.render_state_get(state, @intFromEnum(RenderStateData.dirty), &dirty) == success) return @enumFromInt(dirty);
        }
        return null;
    }

    pub fn clearRenderStateDirty(self: *Runtime, render_state: ?*anyopaque) void {
        if (render_state) |state| {
            var dirty: u32 = @intFromEnum(RenderStateDirty.false_value);
            _ = self.render_state_set(state, @intFromEnum(RenderStateOpt.dirty), &dirty);
        }
    }

    pub fn renderStateColors(self: *Runtime, render_state: ?*anyopaque) ?RenderStateColors {
        if (render_state) |state| {
            var colors = std.mem.zeroes(RenderStateColors);
            colors.size = @sizeOf(RenderStateColors);
            if (self.render_state_colors_get(state, &colors) == success) return colors;
        }
        return null;
    }

    pub fn renderStateCols(self: *Runtime, render_state: ?*anyopaque) ?u16 {
        if (render_state) |state| {
            var cols: u16 = 0;
            if (self.render_state_get(state, @intFromEnum(RenderStateData.cols), &cols) == success) return cols;
        }
        return null;
    }

    pub fn renderStateRows(self: *Runtime, render_state: ?*anyopaque) ?u16 {
        if (render_state) |state| {
            var rows: u16 = 0;
            if (self.render_state_get(state, @intFromEnum(RenderStateData.rows), &rows) == success) return rows;
        }
        return null;
    }

    pub fn createRowIterator(self: *Runtime) !?*anyopaque {
        var handle: ?*anyopaque = null;
        if (self.row_iterator_new(null, &handle) != success or handle == null) return error.RowIteratorCreateFailed;
        return handle;
    }

    pub fn freeRowIterator(self: *Runtime, handle: ?*anyopaque) void {
        if (handle) |iterator| self.row_iterator_free(iterator);
    }

    pub fn populateRowIterator(self: *Runtime, render_state: ?*anyopaque, row_iterator: *?*anyopaque) bool {
        if (render_state) |state| {
            return self.render_state_get(state, @intFromEnum(RenderStateData.row_iterator), @ptrCast(row_iterator)) == success;
        }
        return false;
    }

    pub fn nextRow(self: *Runtime, row_iterator: ?*anyopaque) bool {
        if (row_iterator) |iterator| return self.row_iterator_next(iterator);
        return false;
    }

    pub fn rowDirty(self: *Runtime, row_iterator: ?*anyopaque) bool {
        if (row_iterator) |iterator| {
            var dirty = false;
            return self.row_get(iterator, @intFromEnum(RowData.dirty), &dirty) == success and dirty;
        }
        return false;
    }

    pub fn clearRowDirty(self: *Runtime, row_iterator: ?*anyopaque) void {
        if (row_iterator) |iterator| {
            var dirty = false;
            _ = self.row_set(iterator, @intFromEnum(RowOpt.dirty), &dirty);
        }
    }

    pub fn createRowCells(self: *Runtime) !?*anyopaque {
        var handle: ?*anyopaque = null;
        if (self.row_cells_new(null, &handle) != success or handle == null) return error.RowCellsCreateFailed;
        return handle;
    }

    pub fn freeRowCells(self: *Runtime, handle: ?*anyopaque) void {
        if (handle) |cells| self.row_cells_free(cells);
    }

    pub fn populateRowCells(self: *Runtime, row_iterator: ?*anyopaque, row_cells: *?*anyopaque) bool {
        if (row_iterator) |iterator| {
            return self.row_get(iterator, @intFromEnum(RowData.cells), @ptrCast(row_cells)) == success;
        }
        return false;
    }

    pub fn nextCell(self: *Runtime, row_cells: ?*anyopaque) bool {
        if (row_cells) |cells| return self.row_cells_next(cells);
        return false;
    }

    pub fn cellStyle(self: *Runtime, row_cells: ?*anyopaque) ?Style {
        if (row_cells) |cells| {
            var style = std.mem.zeroes(Style);
            style.size = @sizeOf(Style);
            if (self.row_cells_get(cells, @intFromEnum(CellData.style), &style) == success) return style;
        }
        return null;
    }

    pub fn cellGraphemeLen(self: *Runtime, row_cells: ?*anyopaque) u32 {
        if (row_cells) |cells| {
            var len: u32 = 0;
            _ = self.row_cells_get(cells, @intFromEnum(CellData.graphemes_len), &len);
            return len;
        }
        return 0;
    }

    pub fn cellGraphemes(self: *Runtime, row_cells: ?*anyopaque, out: *[16]u32) void {
        if (row_cells) |cells| _ = self.row_cells_get(cells, @intFromEnum(CellData.graphemes_buf), out);
    }

    pub fn cellBackground(self: *Runtime, row_cells: ?*anyopaque) ?ColorRgb {
        if (row_cells) |cells| {
            var rgb: ColorRgb = undefined;
            if (self.row_cells_get(cells, @intFromEnum(CellData.bg_color), &rgb) == success) return rgb;
        }
        return null;
    }

    pub fn cellForeground(self: *Runtime, row_cells: ?*anyopaque) ?ColorRgb {
        if (row_cells) |cells| {
            var rgb: ColorRgb = undefined;
            if (self.row_cells_get(cells, @intFromEnum(CellData.fg_color), &rgb) == success) return rgb;
        }
        return null;
    }

    /// Fetch the raw GhosttyCell u64 value for the current cell position.
    /// Returns 0 on failure.
    pub fn cellRaw(self: *Runtime, row_cells: ?*anyopaque) u64 {
        if (row_cells) |cells| {
            var raw: u64 = 0;
            _ = self.row_cells_get(cells, @intFromEnum(CellData.raw), &raw);
            return raw;
        }
        return 0;
    }

    /// Pure function: get the content tag from a raw cell u64.
    pub fn cellContentTag(self: *Runtime, cell: u64) CellContentTag {
        var tag: u32 = 0;
        _ = self.cell_get(cell, @intFromEnum(CellDataV.content_tag), &tag);
        return @enumFromInt(tag);
    }

    /// Pure function: get the codepoint from a raw cell u64.
    /// Returns 0 for empty/bg-only cells.
    pub fn cellCodepoint(self: *Runtime, cell: u64) u32 {
        var cp: u32 = 0;
        _ = self.cell_get(cell, @intFromEnum(CellDataV.codepoint), &cp);
        return cp;
    }

    pub fn cursorPos(self: *Runtime, render_state: ?*anyopaque) ?struct { x: u16, y: u16 } {
        if (render_state) |state| {
            var has_value = false;
            _ = self.render_state_get(state, @intFromEnum(RenderStateData.cursor_viewport_has_value), &has_value);
            if (!has_value) return null;
            var x: u16 = 0;
            var y: u16 = 0;
            _ = self.render_state_get(state, @intFromEnum(RenderStateData.cursor_viewport_x), &x);
            _ = self.render_state_get(state, @intFromEnum(RenderStateData.cursor_viewport_y), &y);
            return .{ .x = x, .y = y };
        }
        return null;
    }

    pub fn cursorVisible(self: *Runtime, render_state: ?*anyopaque) bool {
        if (render_state) |state| {
            var visible = false;
            if (self.render_state_get(state, @intFromEnum(RenderStateData.cursor_visible), &visible) == success) return visible;
        }
        return false;
    }

    pub fn cursorVisualStyle(self: *Runtime, render_state: ?*anyopaque) CursorVisualStyle {
        if (render_state) |state| {
            var style: u32 = 0;
            _ = self.render_state_get(state, @intFromEnum(RenderStateData.cursor_visual_style), &style);
            return @enumFromInt(style);
        }
        return .block;
    }

    pub fn syncKeyEncoder(self: *Runtime, encoder: ?*anyopaque, terminal: ?*anyopaque) void {
        if (encoder != null and terminal != null) self.key_encoder_setopt_from_terminal(encoder, terminal);
    }

    pub fn createKeyEncoder(self: *Runtime) !?*anyopaque {
        var handle: ?*anyopaque = null;
        if (self.key_encoder_new(null, &handle) != success or handle == null) return error.KeyEncoderCreateFailed;
        return handle;
    }

    pub fn freeKeyEncoder(self: *Runtime, handle: ?*anyopaque) void {
        if (handle) |encoder| self.key_encoder_free(encoder);
    }

    pub fn createKeyEvent(self: *Runtime) !?*anyopaque {
        var handle: ?*anyopaque = null;
        if (self.key_event_new(null, &handle) != success or handle == null) return error.KeyEventCreateFailed;
        return handle;
    }

    pub fn freeKeyEvent(self: *Runtime, handle: ?*anyopaque) void {
        if (handle) |event| self.key_event_free(event);
    }

    pub fn encodeKey(self: *Runtime, encoder: ?*anyopaque, event: ?*anyopaque, key: Key, mods: u32, action: KeyAction, consumed_mods: u32, unshifted_codepoint: u32, utf8: ?[]const u8, out: []u8) ?[]const u8 {
        if (encoder == null or event == null or out.len == 0) return null;

        self.key_event_set_key(event, @intFromEnum(key));
        self.key_event_set_action(event, @intFromEnum(action));
        self.key_event_set_mods(event, mods);
        self.key_event_set_consumed_mods(event, consumed_mods);
        self.key_event_set_unshifted_codepoint(event, unshifted_codepoint);
        if (utf8) |text| {
            if (text.len > 0) self.key_event_set_utf8(event, text.ptr, text.len) else self.key_event_set_utf8(event, null, 0);
        } else {
            self.key_event_set_utf8(event, null, 0);
        }

        var written: usize = 0;
        if (self.key_encoder_encode(encoder, event, out.ptr, out.len, &written) == success and written > 0) return out[0..written];
        return null;
    }

    pub fn syncMouseEncoder(self: *Runtime, encoder: ?*anyopaque, terminal: ?*anyopaque) void {
        if (encoder != null and terminal != null) self.mouse_encoder_setopt_from_terminal(encoder, terminal);
    }

    pub fn setMouseEncoderSize(self: *Runtime, encoder: ?*anyopaque, size: MouseEncoderSize) void {
        if (encoder) |mouse_encoder| {
            var copy = size;
            self.mouse_encoder_setopt(mouse_encoder, @intFromEnum(MouseEncOpt.size), &copy);
        }
    }

    pub fn createMouseEncoder(self: *Runtime) !?*anyopaque {
        var handle: ?*anyopaque = null;
        if (self.mouse_encoder_new(null, &handle) != success or handle == null) return error.MouseEncoderCreateFailed;
        return handle;
    }

    pub fn freeMouseEncoder(self: *Runtime, handle: ?*anyopaque) void {
        if (handle) |encoder| self.mouse_encoder_free(encoder);
    }

    pub fn createMouseEvent(self: *Runtime) !?*anyopaque {
        var handle: ?*anyopaque = null;
        if (self.mouse_event_new(null, &handle) != success or handle == null) return error.MouseEventCreateFailed;
        return handle;
    }

    pub fn freeMouseEvent(self: *Runtime, handle: ?*anyopaque) void {
        if (handle) |event| self.mouse_event_free(event);
    }

    pub fn encodeMouse(self: *Runtime, encoder: ?*anyopaque, event: ?*anyopaque, action: MouseAction, button: ?MouseButton, mods: u32, position: MousePosition, out: []u8) ?[]const u8 {
        if (encoder == null or event == null or out.len == 0) return null;
        self.mouse_event_set_action(event, @intFromEnum(action));
        if (button) |value| self.mouse_event_set_button(event, @intFromEnum(value)) else self.mouse_event_clear_button(event);
        self.mouse_event_set_mods(event, mods);
        var pos = position;
        self.mouse_event_set_position(event, &pos);
        var written: usize = 0;
        if (self.mouse_encoder_encode(encoder, event, out.ptr, out.len, &written) == success and written > 0) return out[0..written];
        return null;
    }

    pub fn encodeFocus(self: *Runtime, event: FocusEvent, out: []u8) ?[]const u8 {
        if (out.len == 0) return null;
        var written: usize = 0;
        if (self.focus_encode(@intFromEnum(event), out.ptr, out.len, &written) == success and written > 0) return out[0..written];
        return null;
    }
};

fn lookup(lib: *std.DynLib, comptime T: type, symbol: [:0]const u8) T {
    return lib.lookup(T, symbol) orelse @panic("missing required ghostty symbol");
}

/// Resolve a StyleColor tagged union to an RGB value, falling back to `default` when NONE.
/// When PALETTE, looks up the color in the provided 256-entry palette.
pub fn resolveStyleColor(sc: StyleColor, default: ColorRgb, palette: *const [256]ColorRgb) ColorRgb {
    return switch (sc.tag) {
        .none => default,
        .palette => palette[sc.value.palette],
        .rgb => sc.value.rgb,
    };
}
