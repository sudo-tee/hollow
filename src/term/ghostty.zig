const std = @import("std");

pub const success = 0;
pub const out_of_space = -3;
pub const no_value = -4;

pub const RowId = u128;
const NativeRowId = extern struct { bits: [2]u64 };
const CellsView = extern struct { ptr: ?[*]const u64, len: usize };
const SelectWordOptions = extern struct {
    size: usize = @sizeOf(SelectWordOptions),
    ref: GridRef,
    boundary_codepoints: ?[*]const u32 = null,
    boundary_codepoints_len: usize = 0,
};
const SelectLineOptions = extern struct {
    size: usize = @sizeOf(SelectLineOptions),
    ref: GridRef,
    whitespace: ?[*]const u32 = null,
    whitespace_len: usize = 0,
    semantic_prompt_boundary: bool = false,
};

const Writer = extern struct {
    write: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) bool,
    userdata: ?*anyopaque,
};
const MimeReader = extern struct {
    read: *const fn (?*anyopaque, String, Writer) callconv(.c) bool,
    userdata: ?*anyopaque,
};
const Paste = extern struct {
    size: usize = @sizeOf(Paste),
    location: c_int = 0,
    source: c_int = 0,
    mimes: [*]const String,
    mimes_len: usize = 1,
    reader: MimeReader,
    allow_unsafe: bool = false,
};

/// Stages the native paste's callback chunks for one atomic PTY queue admission.
pub const PasteOutput = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    failure: ?error{OutOfMemory} = null,

    pub fn append(self: *PasteOutput, bytes: []const u8) void {
        if (self.failure != null) return;
        self.bytes.appendSlice(self.allocator, bytes) catch {
            self.failure = error.OutOfMemory;
        };
    }
    pub fn deinit(self: *PasteOutput) void {
        self.bytes.deinit(self.allocator);
    }
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

pub const Selection = extern struct {
    size: usize,
    start: GridRef,
    end: GridRef,
    rectangle: bool,
};

pub const FormatterFormat = enum(u32) {
    plain = 0,
    vt = 1,
    html = 2,
};

pub const TerminalSelectionFormatOptions = extern struct {
    size: usize,
    emit: FormatterFormat,
    unwrap: bool,
    trim: bool,
    selection: ?*const Selection,
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

    pub fn slice(self: String) []const u8 {
        return if (self.ptr) |ptr| ptr[0..self.len] else "";
    }
};

pub const ProgramStatus = extern struct {
    size: usize = @sizeOf(ProgramStatus),
    state: c_int,
    kind: c_int,
    progress: i8,
    id: String,
    app: String,
    title: String,
    message: String,
};

pub const DesktopNotification = extern struct { size: usize, title: String, body: String };
pub const ProgressReport = extern struct { size: usize, state: c_int, progress: i8 };
pub const DesktopNotificationCallback = *const fn (?*anyopaque, ?*anyopaque, *const DesktopNotification) callconv(.c) void;
pub const ProgressReportCallback = *const fn (?*anyopaque, ?*anyopaque, *const ProgressReport) callconv(.c) void;

pub const SemanticPrompt = extern struct {
    size: usize,
    kind: c_int,
    prompt_kind: c_int,
    has_exit_code: bool,
    exit_code: i32,
    command: String,
    error_text: String,
};

pub const ClipboardContent = extern struct { mime: String, data: String };
pub const ClipboardWriteReply = extern struct {
    size: usize = @sizeOf(ClipboardWriteReply),
    result: c_int,
    remember: bool = false,
};
pub const ClipboardWrite = extern struct {
    size: usize,
    location: c_int,
    contents: ?[*]const ClipboardContent,
    contents_len: usize,
    name: String,
    granted: bool,
    can_remember: bool,
    ctx: ?*const anyopaque,
    reply: *const fn (*const ClipboardWrite, *const ClipboardWriteReply) callconv(.c) void,
};

pub const RenderHoldCallback = *const fn (?*anyopaque, ?*anyopaque, bool) callconv(.c) void;
pub const ProgramStatusCallback = *const fn (?*anyopaque, ?*anyopaque, *const ProgramStatus) callconv(.c) void;
pub const SemanticPromptCallback = *const fn (?*anyopaque, ?*anyopaque, *const SemanticPrompt) callconv(.c) void;
pub const ClipboardWriteCallback = *const fn (?*anyopaque, ?*anyopaque, *const ClipboardWrite) callconv(.c) void;

pub const Buffer = extern struct {
    ptr: ?[*]u8 = null,
    cap: usize = 0,
    len: usize = 0,
};

pub const TerminalModeConfig = extern struct {
    mode: u16,
    value: bool,
};

pub const PointCoordinate = extern struct {
    x: u16,
    y: u32,
};

pub const PointTag = enum(u32) {
    active = 0,
    viewport = 1,
    screen = 2,
    history = 3,
};

pub const PointValue = extern union {
    coordinate: PointCoordinate,
    _padding: [2]u64,
};

pub const Point = extern struct {
    tag: PointTag,
    value: PointValue,
};

pub const GridRef = extern struct {
    size: usize,
    node: ?*anyopaque,
    x: u16,
    y: u16,
};

pub const ScrollViewport = extern struct {
    tag: u32,
    value: extern union {
        delta: isize,
        row: usize,
        delta_prompt: isize,
        _padding: [2]u64,
    },
};

pub const TerminalCompressionMode = enum(c_int) {
    incremental = 0,
    full = 1,
};

pub const TerminalCompressionResult = enum(c_int) {
    unsupported = 0,
    pending = 1,
    complete = 2,
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
    padding_right: u32,
    padding_left: u32,
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
    title = 9,
    pwd = 10,
    color_foreground = 11,
    color_background = 12,
    color_cursor = 13,
    color_palette = 14,
    kitty_image_storage_limit = 15,
    kitty_image_medium_file = 16,
    kitty_image_medium_temp_file = 17,
    kitty_image_medium_shared_mem = 18,
    apc_max_bytes = 19,
    apc_max_bytes_kitty = 20,
    selection = 21,
    pwd_changed = 25,
    clipboard_write = 26,
    scrollback_max_bytes = 27,
    desktop_notification = 29,
    progress_report = 30,
    mode = 34,
    clipboard_write_max_bytes = 39,
    render_hold = 41,
    semantic_prompt = 42,
    reset = 43,
    program_status = 46,
};

pub const TerminalData = enum(u32) {
    invalid = 0,
    cols = 1,
    rows = 2,
    cursor_x = 3,
    cursor_y = 4,
    cursor_pending_wrap = 5,
    active_screen = 6,
    cursor_visible = 7,
    kitty_keyboard_flags = 8,
    scrollbar = 9,
    cursor_style = 10,
    mouse_tracking = 11,
    title = 12,
    pwd = 13,
    total_rows = 14,
    scrollback_rows = 15,
    width_px = 16,
    height_px = 17,
    color_foreground = 18,
    color_background = 19,
    color_cursor = 20,
    color_palette = 21,
    color_foreground_default = 22,
    color_background_default = 23,
    color_cursor_default = 24,
    color_palette_default = 25,
    kitty_image_storage_limit = 26,
    kitty_image_medium_file = 27,
    kitty_image_medium_temp_file = 28,
    kitty_image_medium_shared_mem = 29,
    kitty_graphics = 30,
    selection = 31,
    mode = 37,
};

pub const SysOpt = enum(u32) {
    userdata = 0,
    decode_png = 1,
    log = 2,
};

pub const KittyImageFormat = enum(u32) {
    rgb = 0,
    rgba = 1,
    png = 2,
    gray_alpha = 3,
    gray = 4,
};

pub const KittyImageData = enum(u32) {
    invalid = 0,
    id = 1,
    number = 2,
    width = 3,
    height = 4,
    format = 5,
    compression = 6,
    data_ptr = 7,
    data_len = 8,
    generation = 9,
};

pub const ImageLayer = enum(c_int) { below_bg, below_text, above_text };
pub const RenderImage = struct {
    protocol: c_int = 0,
    image_id: u32 = 0,
    generation: u64 = 0,
    layer: c_int = 0,
    z: i32 = 0,
    col: i32 = 0,
    row: i32 = 0,
    offset_x: u32 = 0,
    offset_y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    source_x: u32 = 0,
    source_y: u32 = 0,
    source_width: u32 = 0,
    source_height: u32 = 0,

    fn lessThan(_: void, a: RenderImage, b: RenderImage) bool {
        return if (a.layer != b.layer) a.layer < b.layer else a.z < b.z;
    }
};

/// Reusable, owned list of resolved fixed, relative and placeholder placements.
pub const RenderImages = struct {
    iterator: ?*anyopaque = null,
    items: std.ArrayList(RenderImage) = .empty,

    pub fn deinit(self: *RenderImages, allocator: std.mem.Allocator) void {
        ghostty_render_state_image_iterator_free(self.iterator);
        self.items.deinit(allocator);
        self.* = .{};
    }

    pub fn update(self: *RenderImages, allocator: std.mem.Allocator, state: ?*anyopaque) !void {
        self.items.clearRetainingCapacity();
        errdefer self.items.clearRetainingCapacity();
        if (state == null) return;
        if (self.iterator == null and ghostty_render_state_image_iterator_new(null, &self.iterator) != success) return error.OutOfMemory;
        var iterator = self.iterator;
        if (ghostty_render_state_get(state, 22, @ptrCast(&iterator)) != success) return error.ImageIteratorFailed;
        while (ghostty_render_state_image_iterator_next(self.iterator)) {
            var image: RenderImage = .{};
            const keys = [_]c_int{ 1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 13, 14, 15, 16, 17 };
            const values = [_]*anyopaque{ &image.protocol, &image.image_id, &image.generation, &image.layer, &image.z, &image.col, &image.row, &image.offset_x, &image.offset_y, &image.width, &image.height, &image.source_x, &image.source_y, &image.source_width, &image.source_height };
            if (ghostty_render_state_image_get_multi(self.iterator, keys.len, &keys, &values, null) != success or image.protocol != 0) continue;
            try self.items.append(allocator, image);
        }
        std.sort.insertion(RenderImage, self.items.items, {}, RenderImage.lessThan);
    }
};

pub const SysImage = extern struct {
    width: u32,
    height: u32,
    data: ?[*]u8,
    data_len: usize,
};

pub const AllocatorVtable = extern struct {
    alloc: *const fn (?*anyopaque, usize, u8, usize) callconv(.c) ?*anyopaque,
    resize: *const fn (?*anyopaque, ?*anyopaque, usize, u8, usize, usize) callconv(.c) bool,
    remap: *const fn (?*anyopaque, ?*anyopaque, usize, u8, usize, usize) callconv(.c) ?*anyopaque,
    free: *const fn (?*anyopaque, ?*anyopaque, usize, u8, usize) callconv(.c) void,
};

pub const Allocator = extern struct {
    ctx: ?*anyopaque,
    vtable: ?*const AllocatorVtable,
};

pub const DecodePngFn = *const fn (?*anyopaque, ?*const Allocator, [*]const u8, usize, *SysImage) callconv(.c) bool;

pub const TerminalScreen = enum(u32) {
    primary = 0,
    alternate = 1,
};

pub const Mode = enum(u16) {
    focus_event = 1004,
    bracketed_paste = 2004,
    synchronized_output = 2026,
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
    colors = 19,
    image_placements_generation = 23,
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
    cells_raw = 5,
    id = 7,
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
    selected = 7,
    graphemes_utf8 = 9,
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

/// Semantic content type of a cell, set by OSC 133 semantic prompt sequences.
pub const CellSemanticContent = enum(u32) {
    output = 0,
    input = 1,
    prompt = 2,
};

/// Row-level semantic prompt state from OSC 133 sequences.
pub const RowSemanticPrompt = enum(u32) {
    none = 0,
    prompt = 1,
    prompt_continuation = 2,
};

pub const MouseEncOpt = enum(u32) {
    event = 0,
    format = 1,
    size = 2,
    any_button_pressed = 3,
    track_last_cell = 4,
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
    pub const none: u16 = 0;
    pub const shift: u16 = 0x01;
    pub const ctrl: u16 = 0x02;
    pub const alt: u16 = 0x04;
    pub const super: u16 = 0x08;
};

pub const FocusEvent = enum(u32) {
    gained = 0,
    lost = 1,
};

pub const ScrollViewportTag = enum(u32) {
    top = 0,
    bottom = 1,
    delta = 2,
    row = 3,
    delta_prompt = 4,
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
    num_lock = 79,
    numpad_0 = 80,
    numpad_1 = 81,
    numpad_2 = 82,
    numpad_3 = 83,
    numpad_4 = 84,
    numpad_5 = 85,
    numpad_6 = 86,
    numpad_7 = 87,
    numpad_8 = 88,
    numpad_9 = 89,
    numpad_add = 90,
    numpad_backspace = 91,
    numpad_clear = 92,
    numpad_clear_entry = 93,
    numpad_comma = 94,
    numpad_decimal = 95,
    numpad_divide = 96,
    numpad_enter = 97,
    numpad_equal = 98,
    numpad_memory_add = 99,
    numpad_memory_clear = 100,
    numpad_memory_recall = 101,
    numpad_memory_store = 102,
    numpad_memory_subtract = 103,
    numpad_multiply = 104,
    numpad_paren_left = 105,
    numpad_paren_right = 106,
    numpad_subtract = 107,
    numpad_separator = 108,
    numpad_up = 109,
    numpad_down = 110,
    numpad_right = 111,
    numpad_left = 112,
    numpad_begin = 113,
    numpad_home = 114,
    numpad_end = 115,
    numpad_insert = 116,
    numpad_delete = 117,
    numpad_page_up = 118,
    numpad_page_down = 119,
    escape = 120,
    f1 = 121,
    f2 = 122,
    f3 = 123,
    f4 = 124,
    f5 = 125,
    f6 = 126,
    f7 = 127,
    f8 = 128,
    f9 = 129,
    f10 = 130,
    f11 = 131,
    f12 = 132,
};

const WritePtyCallback = *const fn (?*anyopaque, ?*anyopaque, [*]const u8, usize) callconv(.c) void;
const BellCallback = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;
const EnquiryCallback = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) String;
const XtversionCallback = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) String;
const SizeCallback = *const fn (?*anyopaque, ?*anyopaque, *SizeReportSize) callconv(.c) bool;
const ColorSchemeCallback = *const fn (?*anyopaque, ?*anyopaque, *ColorScheme) callconv(.c) bool;
const DeviceAttributesCallback = *const fn (?*anyopaque, ?*anyopaque, *DeviceAttributes) callconv(.c) bool;
const TitleChangedCallback = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;

extern fn ghostty_terminal_new(?*anyopaque, *?*anyopaque, u16, u16) callconv(.c) i32;
extern fn ghostty_terminal_free(?*anyopaque) callconv(.c) void;
extern fn ghostty_terminal_vt_write(?*anyopaque, [*]const u8, usize) callconv(.c) void;
extern fn ghostty_terminal_paste(?*anyopaque, *const Paste, ?*bool) callconv(.c) i32;
extern fn ghostty_terminal_resize(?*anyopaque, u16, u16, u32, u32) callconv(.c) void;
extern fn ghostty_terminal_get(?*anyopaque, u32, ?*anyopaque) callconv(.c) i32;
extern fn ghostty_terminal_set(?*anyopaque, u32, ?*const anyopaque) callconv(.c) i32;
extern fn ghostty_terminal_grid_ref(?*anyopaque, Point, *GridRef) callconv(.c) i32;
extern fn ghostty_terminal_point_from_grid_ref(?*anyopaque, *const GridRef, PointTag, *PointCoordinate) callconv(.c) i32;
extern fn ghostty_terminal_select_word(?*anyopaque, *const SelectWordOptions, *Selection) callconv(.c) i32;
extern fn ghostty_terminal_select_line(?*anyopaque, *const SelectLineOptions, *Selection) callconv(.c) i32;
extern fn ghostty_terminal_selection_format_buf(?*anyopaque, TerminalSelectionFormatOptions, ?[*]u8, usize, *usize) callconv(.c) i32;
extern fn ghostty_terminal_scroll_viewport(?*anyopaque, ScrollViewport) callconv(.c) void;
extern fn ghostty_terminal_compression_activity(?*anyopaque, *u64) callconv(.c) i32;
extern fn ghostty_terminal_compress(?*anyopaque, TerminalCompressionMode, *TerminalCompressionResult) callconv(.c) i32;
extern fn ghostty_sys_set(u32, ?*const anyopaque) callconv(.c) i32;
extern fn ghostty_alloc(?*const Allocator, usize) callconv(.c) ?[*]u8;
extern fn ghostty_kitty_graphics_get(?*anyopaque, u32, ?*anyopaque) callconv(.c) i32;
extern fn ghostty_kitty_graphics_image(?*anyopaque, u32) callconv(.c) ?*const anyopaque;
extern fn ghostty_kitty_graphics_image_get(?*const anyopaque, u32, ?*anyopaque) callconv(.c) i32;
extern fn ghostty_render_state_new(?*anyopaque, *?*anyopaque) callconv(.c) i32;
extern fn ghostty_render_state_free(?*anyopaque) callconv(.c) void;
extern fn ghostty_render_state_update(?*anyopaque, ?*anyopaque) callconv(.c) i32;
extern fn ghostty_render_state_get(?*anyopaque, u32, ?*anyopaque) callconv(.c) i32;
extern fn ghostty_render_state_image_iterator_new(?*const Allocator, *?*anyopaque) callconv(.c) i32;
extern fn ghostty_render_state_image_iterator_free(?*anyopaque) callconv(.c) void;
extern fn ghostty_render_state_image_iterator_next(?*anyopaque) callconv(.c) bool;
extern fn ghostty_render_state_image_get_multi(?*anyopaque, usize, [*]const c_int, [*]const *anyopaque, ?*usize) callconv(.c) i32;
extern fn ghostty_kitty_graphics_animation_tick(?*anyopaque, u64, *u64) callconv(.c) i32;
extern fn ghostty_render_state_set(?*anyopaque, u32, ?*const anyopaque) callconv(.c) i32;
extern fn ghostty_render_state_row_iterator_new(?*anyopaque, *?*anyopaque) callconv(.c) i32;
extern fn ghostty_render_state_row_iterator_free(?*anyopaque) callconv(.c) void;
extern fn ghostty_render_state_row_iterator_next(?*anyopaque) callconv(.c) bool;
extern fn ghostty_render_state_row_get(?*anyopaque, u32, ?*anyopaque) callconv(.c) i32;
extern fn ghostty_render_state_row_set(?*anyopaque, u32, ?*const anyopaque) callconv(.c) i32;
extern fn ghostty_render_state_row_cells_new(?*anyopaque, *?*anyopaque) callconv(.c) i32;
extern fn ghostty_render_state_row_cells_free(?*anyopaque) callconv(.c) void;
extern fn ghostty_render_state_row_cells_next(?*anyopaque) callconv(.c) bool;
extern fn ghostty_render_state_row_cells_get(?*anyopaque, u32, ?*anyopaque) callconv(.c) i32;
extern fn ghostty_cell_get(u64, u32, ?*anyopaque) callconv(.c) i32;
extern fn ghostty_grid_ref_cell(*const GridRef, ?*u64) callconv(.c) i32;
extern fn ghostty_grid_ref_row(*const GridRef, ?*u64) callconv(.c) i32;
extern fn ghostty_row_get(u64, u32, ?*anyopaque) callconv(.c) i32;
extern fn ghostty_grid_ref_graphemes(*const GridRef, ?[*]u32, usize, *usize) callconv(.c) i32;
extern fn ghostty_grid_ref_hyperlink_uri(*const GridRef, ?[*]u8, usize, *usize) callconv(.c) i32;
extern fn ghostty_grid_ref_style(*const GridRef, *Style) callconv(.c) i32;
extern fn ghostty_key_encoder_new(?*anyopaque, *?*anyopaque) callconv(.c) i32;
extern fn ghostty_key_encoder_free(?*anyopaque) callconv(.c) void;
extern fn ghostty_key_encoder_setopt_from_terminal(?*anyopaque, ?*anyopaque) callconv(.c) void;
extern fn ghostty_key_encoder_encode(?*anyopaque, ?*anyopaque, [*]u8, usize, *usize) callconv(.c) i32;
extern fn ghostty_key_event_new(?*anyopaque, *?*anyopaque) callconv(.c) i32;
extern fn ghostty_key_event_free(?*anyopaque) callconv(.c) void;
extern fn ghostty_key_event_set_key(?*anyopaque, u32) callconv(.c) void;
extern fn ghostty_key_event_set_action(?*anyopaque, u32) callconv(.c) void;
extern fn ghostty_key_event_set_mods(?*anyopaque, u32) callconv(.c) void;
extern fn ghostty_key_event_set_consumed_mods(?*anyopaque, u32) callconv(.c) void;
extern fn ghostty_key_event_set_unshifted_codepoint(?*anyopaque, u32) callconv(.c) void;
extern fn ghostty_key_event_set_utf8(?*anyopaque, ?[*]const u8, usize) callconv(.c) void;
extern fn ghostty_mouse_encoder_new(?*anyopaque, *?*anyopaque) callconv(.c) i32;
extern fn ghostty_mouse_encoder_free(?*anyopaque) callconv(.c) void;
extern fn ghostty_mouse_encoder_setopt_from_terminal(?*anyopaque, ?*anyopaque) callconv(.c) void;
extern fn ghostty_mouse_encoder_setopt(?*anyopaque, u32, ?*const anyopaque) callconv(.c) void;
extern fn ghostty_mouse_encoder_encode(?*anyopaque, ?*anyopaque, [*]u8, usize, *usize) callconv(.c) i32;
extern fn ghostty_mouse_event_new(?*anyopaque, *?*anyopaque) callconv(.c) i32;
extern fn ghostty_mouse_event_free(?*anyopaque) callconv(.c) void;
extern fn ghostty_mouse_event_set_action(?*anyopaque, u32) callconv(.c) void;
extern fn ghostty_mouse_event_set_button(?*anyopaque, u32) callconv(.c) void;
extern fn ghostty_mouse_event_clear_button(?*anyopaque) callconv(.c) void;
extern fn ghostty_mouse_event_set_mods(?*anyopaque, u32) callconv(.c) void;
extern fn ghostty_mouse_event_set_position(?*anyopaque, MousePosition) callconv(.c) void;
extern fn ghostty_focus_encode(u32, [*]u8, usize, *usize) callconv(.c) i32;

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
    pwd_changed: ?TitleChangedCallback = null,
    clipboard_write: ?ClipboardWriteCallback = null,
    render_hold: ?RenderHoldCallback = null,
    semantic_prompt: ?SemanticPromptCallback = null,
    reset: ?TitleChangedCallback = null,
    program_status: ?ProgramStatusCallback = null,
    desktop_notification: ?DesktopNotificationCallback = null,
    progress_report: ?ProgressReportCallback = null,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,

    terminal_new: *const fn (?*anyopaque, *?*anyopaque, u16, u16) callconv(.c) i32,
    terminal_free: *const fn (?*anyopaque) callconv(.c) void,
    terminal_vt_write: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,
    terminal_resize: *const fn (?*anyopaque, u16, u16, u32, u32) callconv(.c) void,
    terminal_get: *const fn (?*anyopaque, u32, ?*anyopaque) callconv(.c) i32,
    terminal_set: *const fn (?*anyopaque, u32, ?*const anyopaque) callconv(.c) i32,
    terminal_grid_ref: *const fn (?*anyopaque, Point, *GridRef) callconv(.c) i32,
    terminal_selection_format_buf: *const fn (?*anyopaque, TerminalSelectionFormatOptions, ?[*]u8, usize, *usize) callconv(.c) i32,
    terminal_scroll_viewport: *const fn (?*anyopaque, ScrollViewport) callconv(.c) void,
    terminal_compression_activity: *const fn (?*anyopaque, *u64) callconv(.c) i32,
    terminal_compress: *const fn (?*anyopaque, TerminalCompressionMode, *TerminalCompressionResult) callconv(.c) i32,
    sys_set: *const fn (u32, ?*const anyopaque) callconv(.c) i32,
    alloc: *const fn (?*const Allocator, usize) callconv(.c) ?[*]u8,
    kitty_graphics_get: *const fn (?*anyopaque, u32, ?*anyopaque) callconv(.c) i32,
    kitty_graphics_image: *const fn (?*anyopaque, u32) callconv(.c) ?*const anyopaque,
    kitty_graphics_image_get: *const fn (?*const anyopaque, u32, ?*anyopaque) callconv(.c) i32,

    render_state_new: *const fn (?*anyopaque, *?*anyopaque) callconv(.c) i32,
    render_state_free: *const fn (?*anyopaque) callconv(.c) void,
    render_state_update: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i32,
    render_state_get: *const fn (?*anyopaque, u32, ?*anyopaque) callconv(.c) i32,
    render_state_set: *const fn (?*anyopaque, u32, ?*const anyopaque) callconv(.c) i32,

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
    grid_ref_cell: *const fn (*const GridRef, ?*u64) callconv(.c) i32,
    /// Get a raw GhosttyRow value from a grid reference.
    grid_ref_row: *const fn (*const GridRef, ?*u64) callconv(.c) i32,
    /// Extract typed data from a raw GhosttyRow u64.
    grid_row_get: *const fn (u64, u32, ?*anyopaque) callconv(.c) i32,
    grid_ref_graphemes: *const fn (*const GridRef, ?[*]u32, usize, *usize) callconv(.c) i32,
    grid_ref_hyperlink_uri: *const fn (*const GridRef, ?[*]u8, usize, *usize) callconv(.c) i32,
    grid_ref_style: *const fn (*const GridRef, *Style) callconv(.c) i32,

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
    mouse_event_set_position: *const fn (?*anyopaque, MousePosition) callconv(.c) void,

    focus_encode: *const fn (u32, [*]u8, usize, *usize) callconv(.c) i32,

    pub fn init(allocator: std.mem.Allocator, preferred_path: ?[]const u8) !Runtime {
        _ = preferred_path;
        return .{
            .allocator = allocator,
            .terminal_new = ghostty_terminal_new,
            .terminal_free = ghostty_terminal_free,
            .terminal_vt_write = ghostty_terminal_vt_write,
            .terminal_resize = ghostty_terminal_resize,
            .terminal_get = ghostty_terminal_get,
            .terminal_set = ghostty_terminal_set,
            .terminal_grid_ref = ghostty_terminal_grid_ref,
            .terminal_selection_format_buf = ghostty_terminal_selection_format_buf,
            .terminal_scroll_viewport = ghostty_terminal_scroll_viewport,
            .terminal_compression_activity = ghostty_terminal_compression_activity,
            .terminal_compress = ghostty_terminal_compress,
            .sys_set = ghostty_sys_set,
            .alloc = ghostty_alloc,
            .kitty_graphics_get = ghostty_kitty_graphics_get,
            .kitty_graphics_image = ghostty_kitty_graphics_image,
            .kitty_graphics_image_get = ghostty_kitty_graphics_image_get,
            .render_state_new = ghostty_render_state_new,
            .render_state_free = ghostty_render_state_free,
            .render_state_update = ghostty_render_state_update,
            .render_state_get = ghostty_render_state_get,
            .render_state_set = ghostty_render_state_set,
            .row_iterator_new = ghostty_render_state_row_iterator_new,
            .row_iterator_free = ghostty_render_state_row_iterator_free,
            .row_iterator_next = ghostty_render_state_row_iterator_next,
            .row_get = ghostty_render_state_row_get,
            .row_set = ghostty_render_state_row_set,
            .row_cells_new = ghostty_render_state_row_cells_new,
            .row_cells_free = ghostty_render_state_row_cells_free,
            .row_cells_next = ghostty_render_state_row_cells_next,
            .row_cells_get = ghostty_render_state_row_cells_get,
            .cell_get = ghostty_cell_get,
            .grid_ref_cell = ghostty_grid_ref_cell,
            .grid_ref_row = ghostty_grid_ref_row,
            .grid_row_get = ghostty_row_get,
            .grid_ref_graphemes = ghostty_grid_ref_graphemes,
            .grid_ref_hyperlink_uri = ghostty_grid_ref_hyperlink_uri,
            .grid_ref_style = ghostty_grid_ref_style,
            .key_encoder_new = ghostty_key_encoder_new,
            .key_encoder_free = ghostty_key_encoder_free,
            .key_encoder_setopt_from_terminal = ghostty_key_encoder_setopt_from_terminal,
            .key_encoder_encode = ghostty_key_encoder_encode,
            .key_event_new = ghostty_key_event_new,
            .key_event_free = ghostty_key_event_free,
            .key_event_set_key = ghostty_key_event_set_key,
            .key_event_set_action = ghostty_key_event_set_action,
            .key_event_set_mods = ghostty_key_event_set_mods,
            .key_event_set_consumed_mods = ghostty_key_event_set_consumed_mods,
            .key_event_set_unshifted_codepoint = ghostty_key_event_set_unshifted_codepoint,
            .key_event_set_utf8 = ghostty_key_event_set_utf8,
            .mouse_encoder_new = ghostty_mouse_encoder_new,
            .mouse_encoder_free = ghostty_mouse_encoder_free,
            .mouse_encoder_setopt_from_terminal = ghostty_mouse_encoder_setopt_from_terminal,
            .mouse_encoder_setopt = ghostty_mouse_encoder_setopt,
            .mouse_encoder_encode = ghostty_mouse_encoder_encode,
            .mouse_event_new = ghostty_mouse_event_new,
            .mouse_event_free = ghostty_mouse_event_free,
            .mouse_event_set_action = ghostty_mouse_event_set_action,
            .mouse_event_set_button = ghostty_mouse_event_set_button,
            .mouse_event_clear_button = ghostty_mouse_event_clear_button,
            .mouse_event_set_mods = ghostty_mouse_event_set_mods,
            .mouse_event_set_position = ghostty_mouse_event_set_position,
            .focus_encode = ghostty_focus_encode,
        };
    }

    pub fn deinit(self: *Runtime) void {
        _ = self;
    }

    pub fn createTerminal(self: *Runtime, cols: u16, rows: u16, max_scrollback: usize) !?*anyopaque {
        var handle: ?*anyopaque = null;
        const result = self.terminal_new(null, &handle, cols, rows);
        if (result != success or handle == null) {
            return error.TerminalCreateFailed;
        }
        _ = self.terminal_set(handle, @backingInt(TerminalOpt.scrollback_max_bytes), &max_scrollback);
        return handle;
    }

    /// Set the embedder's terminal color defaults. Ghostty uses these values
    /// both for cells that use the default SGR colors and for OSC 10/11/12
    /// queries from programs running in the terminal.
    pub fn setTerminalDefaultColors(
        self: *Runtime,
        handle: ?*anyopaque,
        foreground: ColorRgb,
        background: ColorRgb,
        cursor: ?ColorRgb,
        palette: *const [256]ColorRgb,
    ) void {
        const terminal = handle orelse return;

        var foreground_value = foreground;
        _ = self.terminal_set(terminal, @backingInt(TerminalOpt.color_foreground), &foreground_value);

        var background_value = background;
        _ = self.terminal_set(terminal, @backingInt(TerminalOpt.color_background), &background_value);

        if (cursor) |cursor_value| {
            var cursor_color = cursor_value;
            _ = self.terminal_set(terminal, @backingInt(TerminalOpt.color_cursor), &cursor_color);
        } else {
            _ = self.terminal_set(terminal, @backingInt(TerminalOpt.color_cursor), null);
        }

        _ = self.terminal_set(terminal, @backingInt(TerminalOpt.color_palette), palette);
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
            var config = TerminalModeConfig{ .mode = @backingInt(mode), .value = false };
            return self.terminal_get(terminal, @backingInt(TerminalData.mode), &config) == success and config.value;
        }
        return false;
    }

    pub fn setTerminalMode(self: *Runtime, handle: ?*anyopaque, mode: Mode, value: bool) bool {
        if (handle) |terminal| {
            var config = TerminalModeConfig{ .mode = @backingInt(mode), .value = value };
            return self.terminal_set(terminal, @backingInt(TerminalOpt.mode), &config) == success;
        }
        return false;
    }

    pub fn terminalTitle(self: *Runtime, allocator: std.mem.Allocator, handle: ?*anyopaque) !?[]u8 {
        if (handle) |terminal| {
            var title = String{ .ptr = null, .len = 0 };
            if (self.terminal_get(terminal, @backingInt(TerminalData.title), &title) == success and title.ptr != null and title.len > 0) {
                return try allocator.dupe(u8, title.ptr.?[0..title.len]);
            }
        }
        return null;
    }

    pub fn terminalActiveScreen(self: *Runtime, handle: ?*anyopaque) TerminalScreen {
        if (handle) |terminal| {
            var screen: u32 = 0;
            if (self.terminal_get(terminal, @backingInt(TerminalData.active_screen), &screen) == success) {
                return @fromBackingInt(@intCast(screen));
            }
        }
        return .primary;
    }

    pub fn terminalScrollbar(self: *Runtime, handle: ?*anyopaque) ?TerminalScrollbar {
        if (handle) |terminal| {
            var scrollbar: TerminalScrollbar = undefined;
            if (self.terminal_get(terminal, @backingInt(TerminalData.scrollbar), &scrollbar) == success) {
                return scrollbar;
            }
        }
        return null;
    }

    pub fn terminalScroll(self: *Runtime, handle: ?*anyopaque, delta: isize) void {
        if (handle) |terminal| {
            const viewport = ScrollViewport{ .tag = @backingInt(ScrollViewportTag.delta), .value = .{ .delta = delta } };
            self.terminal_scroll_viewport(terminal, viewport);
        }
    }

    pub fn terminalScrollPrompt(self: *Runtime, handle: ?*anyopaque, delta: isize) void {
        if (handle) |terminal| self.terminal_scroll_viewport(terminal, .{
            .tag = @backingInt(ScrollViewportTag.delta_prompt),
            .value = .{ .delta_prompt = delta },
        });
    }

    pub fn terminalScrollTop(self: *Runtime, handle: ?*anyopaque) void {
        if (handle) |terminal| {
            const viewport = ScrollViewport{ .tag = @backingInt(ScrollViewportTag.top), .value = .{ ._padding = .{ 0, 0 } } };
            self.terminal_scroll_viewport(terminal, viewport);
        }
    }

    pub fn terminalScrollBottom(self: *Runtime, handle: ?*anyopaque) void {
        if (handle) |terminal| {
            const viewport = ScrollViewport{ .tag = @backingInt(ScrollViewportTag.bottom), .value = .{ ._padding = .{ 0, 0 } } };
            self.terminal_scroll_viewport(terminal, viewport);
        }
    }

    pub fn terminalScrollToRow(self: *Runtime, handle: ?*anyopaque, row: usize) void {
        if (handle) |terminal| {
            const viewport = ScrollViewport{ .tag = @backingInt(ScrollViewportTag.row), .value = .{ .row = row } };
            self.terminal_scroll_viewport(terminal, viewport);
        }
    }

    pub fn formatSelectionInto(self: *Runtime, handle: ?*anyopaque, selection: *const Selection, out: ?[]u8, written: *usize) i32 {
        const options = TerminalSelectionFormatOptions{
            .size = @sizeOf(TerminalSelectionFormatOptions),
            .emit = .plain,
            .unwrap = true,
            .trim = true,
            .selection = selection,
        };
        return self.terminal_selection_format_buf(
            handle,
            options,
            if (out) |buf| buf.ptr else null,
            if (out) |buf| buf.len else 0,
            written,
        );
    }

    pub fn terminalCompressionActivity(self: *Runtime, handle: ?*anyopaque) !u64 {
        var activity: u64 = 0;
        if (self.terminal_compression_activity(handle, &activity) != success) {
            return error.TerminalCompressionActivityFailed;
        }
        return activity;
    }

    pub fn terminalCompress(self: *Runtime, handle: ?*anyopaque) !TerminalCompressionResult {
        var result: TerminalCompressionResult = undefined;
        if (self.terminal_compress(handle, .incremental, &result) != success) {
            return error.TerminalCompressionFailed;
        }
        return result;
    }

    pub fn setWritePtyCallback(self: *Runtime, handle: ?*anyopaque, callback: WritePtyCallback) void {
        if (handle) |terminal| _ = self.terminal_set(terminal, @backingInt(TerminalOpt.write_pty), @ptrCast(callback));
    }

    pub fn setTerminalUserdata(self: *Runtime, handle: ?*anyopaque, userdata: ?*anyopaque) void {
        if (handle) |terminal| _ = self.terminal_set(terminal, @backingInt(TerminalOpt.userdata), userdata);
    }

    pub fn setBellCallback(self: *Runtime, handle: ?*anyopaque, callback: BellCallback) void {
        if (handle) |terminal| _ = self.terminal_set(terminal, @backingInt(TerminalOpt.bell), @ptrCast(callback));
    }

    pub fn setEnquiryCallback(self: *Runtime, handle: ?*anyopaque, callback: EnquiryCallback) void {
        if (handle) |terminal| _ = self.terminal_set(terminal, @backingInt(TerminalOpt.enquiry), @ptrCast(callback));
    }

    pub fn setXtversionCallback(self: *Runtime, handle: ?*anyopaque, callback: XtversionCallback) void {
        if (handle) |terminal| _ = self.terminal_set(terminal, @backingInt(TerminalOpt.xtversion), @ptrCast(callback));
    }

    pub fn setSizeCallback(self: *Runtime, handle: ?*anyopaque, callback: SizeCallback) void {
        if (handle) |terminal| _ = self.terminal_set(terminal, @backingInt(TerminalOpt.size), @ptrCast(callback));
    }

    pub fn setColorSchemeCallback(self: *Runtime, handle: ?*anyopaque, callback: ColorSchemeCallback) void {
        if (handle) |terminal| _ = self.terminal_set(terminal, @backingInt(TerminalOpt.color_scheme), @ptrCast(callback));
    }

    pub fn setDeviceAttributesCallback(self: *Runtime, handle: ?*anyopaque, callback: DeviceAttributesCallback) void {
        if (handle) |terminal| _ = self.terminal_set(terminal, @backingInt(TerminalOpt.device_attributes), @ptrCast(callback));
    }

    pub fn setTitleChangedCallback(self: *Runtime, handle: ?*anyopaque, callback: TitleChangedCallback) void {
        if (handle) |terminal| _ = self.terminal_set(terminal, @backingInt(TerminalOpt.title_changed), @ptrCast(callback));
    }

    pub fn setKittyImageStorageLimit(self: *Runtime, handle: ?*anyopaque, bytes: u64) void {
        if (handle) |terminal| {
            var copy = bytes;
            _ = self.terminal_set(terminal, @backingInt(TerminalOpt.kitty_image_storage_limit), &copy);
        }
    }

    pub fn setKittyImageMediumFile(self: *Runtime, handle: ?*anyopaque, enabled: bool) void {
        if (handle) |terminal| {
            var copy = enabled;
            _ = self.terminal_set(terminal, @backingInt(TerminalOpt.kitty_image_medium_file), &copy);
        }
    }

    pub fn setKittyImageMediumTempFile(self: *Runtime, handle: ?*anyopaque, enabled: bool) void {
        if (handle) |terminal| {
            var copy = enabled;
            _ = self.terminal_set(terminal, @backingInt(TerminalOpt.kitty_image_medium_temp_file), &copy);
        }
    }

    pub fn setKittyImageMediumSharedMem(self: *Runtime, handle: ?*anyopaque, enabled: bool) void {
        if (handle) |terminal| {
            var copy = enabled;
            _ = self.terminal_set(terminal, @backingInt(TerminalOpt.kitty_image_medium_shared_mem), &copy);
        }
    }

    pub fn setApcMaxBytes(self: *Runtime, handle: ?*anyopaque, bytes: usize) void {
        if (handle) |terminal| {
            var copy = bytes;
            _ = self.terminal_set(terminal, @backingInt(TerminalOpt.apc_max_bytes), &copy);
        }
    }

    pub fn setApcMaxBytesKitty(self: *Runtime, handle: ?*anyopaque, bytes: usize) void {
        if (handle) |terminal| {
            var copy = bytes;
            _ = self.terminal_set(terminal, @backingInt(TerminalOpt.apc_max_bytes_kitty), &copy);
        }
    }

    pub fn setSysDecodePng(self: *Runtime, callback: ?DecodePngFn) i32 {
        return self.sys_set(@backingInt(SysOpt.decode_png), if (callback) |cb| @ptrCast(cb) else null);
    }

    pub fn setSysUserdata(self: *Runtime, value: ?*anyopaque) i32 {
        return self.sys_set(@backingInt(SysOpt.userdata), value);
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
        inline for (.{ "pwd_changed", "clipboard_write", "render_hold", "semantic_prompt", "reset", "program_status", "desktop_notification", "progress_report" }) |name| {
            const cb = @field(cbs, name);
            _ = self.terminal_set(handle, @backingInt(@field(TerminalOpt, name)), if (cb) |value| @ptrCast(value) else null);
        }
        // Match Hollow's former bounded OSC 52 capture. Reads remain disabled.
        var max_bytes: usize = 48 * 1024;
        _ = self.terminal_set(handle, @backingInt(TerminalOpt.clipboard_write_max_bytes), &max_bytes);
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
            if (self.render_state_get(state, @backingInt(RenderStateData.dirty), &dirty) == success) return @fromBackingInt(@intCast(dirty));
        }
        return null;
    }

    pub fn clearRenderStateDirty(self: *Runtime, render_state: ?*anyopaque) void {
        if (render_state) |state| {
            var dirty: u32 = @backingInt(RenderStateDirty.false_value);
            _ = self.render_state_set(state, @backingInt(RenderStateOpt.dirty), &dirty);
        }
    }

    pub fn renderStateColorsInto(self: *Runtime, render_state: ?*anyopaque, out: *RenderStateColors) bool {
        if (render_state) |state| {
            out.size = @sizeOf(RenderStateColors);
            return self.render_state_get(state, @backingInt(RenderStateData.colors), out) == success;
        }
        return false;
    }

    pub fn renderStateColors(self: *Runtime, render_state: ?*anyopaque) ?RenderStateColors {
        var colors: RenderStateColors = undefined;
        if (self.renderStateColorsInto(render_state, &colors)) return colors;
        return null;
    }

    pub fn renderStateCols(self: *Runtime, render_state: ?*anyopaque) ?u16 {
        if (render_state) |state| {
            var cols: u16 = 0;
            if (self.render_state_get(state, @backingInt(RenderStateData.cols), &cols) == success) return cols;
        }
        return null;
    }

    pub fn renderStateRows(self: *Runtime, render_state: ?*anyopaque) ?u16 {
        if (render_state) |state| {
            var rows: u16 = 0;
            if (self.render_state_get(state, @backingInt(RenderStateData.rows), &rows) == success) return rows;
        }
        return null;
    }

    pub fn renderStateImagePlacementsGeneration(self: *Runtime, render_state: ?*anyopaque) ?u64 {
        if (render_state) |state| {
            var generation: u64 = 0;
            if (self.render_state_get(state, @backingInt(RenderStateData.image_placements_generation), &generation) == success) return generation;
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
            return self.render_state_get(state, @backingInt(RenderStateData.row_iterator), @ptrCast(row_iterator)) == success;
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
            return self.row_get(iterator, @backingInt(RowData.dirty), &dirty) == success and dirty;
        }
        return false;
    }

    pub fn clearRowDirty(self: *Runtime, row_iterator: ?*anyopaque) void {
        if (row_iterator) |iterator| {
            var dirty = false;
            _ = self.row_set(iterator, @backingInt(RowOpt.dirty), &dirty);
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
            return self.row_get(iterator, @backingInt(RowData.cells), @ptrCast(row_cells)) == success;
        }
        return false;
    }

    pub fn nextCell(self: *Runtime, row_cells: ?*anyopaque) bool {
        if (row_cells) |cells| return self.row_cells_next(cells);
        return false;
    }

    pub fn cellStyleInto(self: *Runtime, row_cells: ?*anyopaque, out: *Style) bool {
        if (row_cells) |cells| {
            out.* = undefined;
            out.size = @sizeOf(Style);
            return self.row_cells_get(cells, @backingInt(CellData.style), out) == success;
        }
        return false;
    }

    pub fn cellStyle(self: *Runtime, row_cells: ?*anyopaque) ?Style {
        var style: Style = undefined;
        if (self.cellStyleInto(row_cells, &style)) return style;
        return null;
    }

    pub fn cellGraphemeLen(self: *Runtime, row_cells: ?*anyopaque) u32 {
        if (row_cells) |cells| {
            var len: u32 = 0;
            _ = self.row_cells_get(cells, @backingInt(CellData.graphemes_len), &len);
            return len;
        }
        return 0;
    }

    pub fn cellGraphemes(self: *Runtime, row_cells: ?*anyopaque, out: *[16]u32) void {
        @memset(out, 0);
        var utf8: [256]u8 = undefined;
        const text = self.cellGraphemeUtf8Into(row_cells, &utf8) orelse return;
        var view = std.unicode.Utf8View.init(text) catch return;
        var iter = view.iterator();
        var i: usize = 0;
        while (i < out.len) : (i += 1) {
            out[i] = iter.nextCodepoint() orelse break;
        }
    }

    pub fn cellGraphemeUtf8Len(self: *Runtime, row_cells: ?*anyopaque) ?usize {
        const cells = row_cells orelse return null;
        var buffer = Buffer{};
        const result = self.row_cells_get(cells, @backingInt(CellData.graphemes_utf8), &buffer);
        if (result == success or result == out_of_space) return buffer.len;
        return null;
    }

    pub fn cellGraphemeUtf8Into(self: *Runtime, row_cells: ?*anyopaque, out: []u8) ?[]const u8 {
        const cells = row_cells orelse return null;
        var buffer = Buffer{
            .ptr = if (out.len > 0) out.ptr else null,
            .cap = out.len,
        };
        if (self.row_cells_get(cells, @backingInt(CellData.graphemes_utf8), &buffer) != success) return null;
        return out[0..buffer.len];
    }

    pub fn cellBackground(self: *Runtime, row_cells: ?*anyopaque) ?ColorRgb {
        if (row_cells) |cells| {
            var rgb: ColorRgb = undefined;
            if (self.row_cells_get(cells, @backingInt(CellData.bg_color), &rgb) == success) return rgb;
        }
        return null;
    }

    pub fn cellForeground(self: *Runtime, row_cells: ?*anyopaque) ?ColorRgb {
        if (row_cells) |cells| {
            var rgb: ColorRgb = undefined;
            if (self.row_cells_get(cells, @backingInt(CellData.fg_color), &rgb) == success) return rgb;
        }
        return null;
    }

    /// Pure function: extract the style_id from a raw cell u64.
    /// Cell packed struct(u64) layout:
    ///   bits  0- 1: content_tag (u2)
    ///   bits  2-22: content union (u21 codepoint / u8 palette / u24 rgb)
    ///   bits 23-38: style_id (u16)
    /// No C call — direct bit extraction.
    /// Returns 0 (default style) when the cell has no non-default styling.
    pub inline fn cellStyleIdRaw(_: *Runtime, cell: u64) u16 {
        return @truncate((cell >> 23) & 0xFFFF);
    }

    /// Pure function: extract the content_tag from a raw cell u64 (bits 0-1).
    /// No C call — direct bit extraction.
    pub inline fn cellContentTagRaw(_: *Runtime, cell: u64) CellContentTag {
        return @fromBackingInt(@intCast(cell & 0x3));
    }

    /// Pure function: extract the codepoint from a raw cell u64 (bits 2-22).
    /// Returns 0 for bg-color-only cells or empty cells.
    /// No C call — direct bit extraction.
    pub inline fn cellCodepointRaw(_: *Runtime, cell: u64) u32 {
        const tag = cell & 0x3;
        // Only codepoint (0) and codepoint_grapheme (1) tags have a codepoint.
        if (tag > 1) return 0;
        return @truncate((cell >> 2) & 0x1FFFFF);
    }

    /// Pure function: returns true if the cell has text to render.
    /// No C call — direct bit extraction.
    pub inline fn cellHasTextRaw(_: *Runtime, cell: u64) bool {
        const tag = cell & 0x3;
        if (tag > 1) return false; // bg_color_palette or bg_color_rgb: no text
        return ((cell >> 2) & 0x1FFFFF) != 0; // codepoint != 0
    }

    /// Fetch the raw GhosttyCell u64 value for the current cell position.
    /// Returns 0 on failure.
    pub fn cellRaw(self: *Runtime, row_cells: ?*anyopaque) u64 {
        if (row_cells) |cells| {
            var raw: u64 = 0;
            _ = self.row_cells_get(cells, @backingInt(CellData.raw), &raw);
            return raw;
        }
        return 0;
    }

    /// Pure function: returns true if the cell has text content (codepoint != 0).
    /// Cheap bit-test on the raw u64 — no iterator, no struct allocation.
    pub fn cellHasText(self: *Runtime, cell: u64) bool {
        var result: bool = false;
        _ = self.cell_get(cell, @backingInt(CellDataV.has_text), &result);
        return result;
    }

    /// Pure function: returns true if the cell has non-default styling
    /// (bold, italic, custom fg/bg color, etc.). Cheap bool query on the
    /// raw u64 — no iterator, no struct allocation.
    pub fn cellHasStyling(self: *Runtime, cell: u64) bool {
        var result: bool = false;
        _ = self.cell_get(cell, @backingInt(CellDataV.has_styling), &result);
        return result;
    }

    /// Pure function: get the content tag from a raw cell u64.
    pub fn cellContentTag(self: *Runtime, cell: u64) CellContentTag {
        var tag: u32 = 0;
        _ = self.cell_get(cell, @backingInt(CellDataV.content_tag), &tag);
        return @fromBackingInt(@intCast(tag));
    }

    /// Pure function: get the codepoint from a raw cell u64.
    /// Returns 0 for empty/bg-only cells.
    pub fn cellCodepoint(self: *Runtime, cell: u64) u32 {
        var cp: u32 = 0;
        _ = self.cell_get(cell, @backingInt(CellDataV.codepoint), &cp);
        return cp;
    }

    /// Pure function: get the semantic content type from a raw cell u64.
    /// Returns the OSC 133 semantic prompt state of the cell.
    pub fn cellSemanticContent(self: *Runtime, cell: u64) CellSemanticContent {
        var sc: u32 = 0;
        _ = self.cell_get(cell, @backingInt(CellDataV.semantic_content), &sc);
        return @fromBackingInt(@intCast(sc));
    }

    /// Get a GhosttyRow from a grid reference.
    /// Returns null if the ref's node is NULL.
    pub fn gridRefRow(self: *Runtime, ref: *const GridRef) ?u64 {
        var row: u64 = 0;
        if (self.grid_ref_row(ref, &row) == success) return row;
        return null;
    }

    pub fn gridRefCell(self: *Runtime, ref: *const GridRef) ?u64 {
        var cell: u64 = 0;
        if (self.grid_ref_cell(ref, &cell) == success) return cell;
        return null;
    }

    pub fn gridRefGraphemesInto(self: *Runtime, ref: *const GridRef, out: []u32) ?usize {
        var len: usize = 0;
        const buf = if (out.len > 0) out.ptr else null;
        const result = self.grid_ref_graphemes(ref, buf, out.len, &len);
        return if (result == success) len else null;
    }

    pub fn gridRefStyleInto(self: *Runtime, ref: *const GridRef, out: *Style) bool {
        out.* = undefined;
        out.size = @sizeOf(Style);
        return self.grid_ref_style(ref, out) == success;
    }

    /// Get the row-level semantic prompt state from a raw GhosttyRow u64.
    pub fn rowSemanticPrompt(self: *Runtime, row: u64) RowSemanticPrompt {
        var sp: u32 = 0;
        _ = self.grid_row_get(row, 6, &sp);
        return @fromBackingInt(@intCast(sp));
    }

    pub fn rowWrapped(self: *Runtime, row: u64) bool {
        var wrapped = false;
        _ = self.grid_row_get(row, 1, &wrapped);
        return wrapped;
    }

    pub fn rowWrapContinuation(self: *Runtime, row: u64) bool {
        var continuation = false;
        _ = self.grid_row_get(row, 2, &continuation);
        return continuation;
    }

    pub fn terminalKittyGraphics(self: *Runtime, handle: ?*anyopaque) ?*anyopaque {
        if (handle) |terminal| {
            var graphics: ?*anyopaque = null;
            const result = self.terminal_get(terminal, @backingInt(TerminalData.kitty_graphics), @ptrCast(&graphics));
            if (result == success and graphics != null) return graphics;
        }
        return null;
    }

    pub fn kittyStorageGeneration(self: *Runtime, graphics: ?*anyopaque) u64 {
        var generation: u64 = 0;
        _ = self.kitty_graphics_get(graphics, 2, &generation);
        return generation;
    }

    pub fn tickKittyAnimation(_: *Runtime, graphics: ?*anyopaque, now_ms: u64) ?u64 {
        var next_ms: u64 = 0;
        return if (ghostty_kitty_graphics_animation_tick(graphics, now_ms, &next_ms) == success) next_ms else null;
    }

    pub fn kittyGraphicsImage(self: *Runtime, graphics: ?*anyopaque, image_id: u32) ?*const anyopaque {
        if (graphics) |value| return self.kitty_graphics_image(value, image_id);
        return null;
    }

    pub fn kittyImageData(self: *Runtime, image: ?*const anyopaque, data: KittyImageData, out: ?*anyopaque) bool {
        if (image) |value| return self.kitty_graphics_image_get(value, @backingInt(data), out) == success;
        return false;
    }

    pub fn cursorPos(self: *Runtime, render_state: ?*anyopaque) ?struct { x: u16, y: u16 } {
        if (render_state) |state| {
            var has_value = false;
            _ = self.render_state_get(state, @backingInt(RenderStateData.cursor_viewport_has_value), &has_value);
            if (!has_value) return null;
            var x: u16 = 0;
            var y: u16 = 0;
            _ = self.render_state_get(state, @backingInt(RenderStateData.cursor_viewport_x), &x);
            _ = self.render_state_get(state, @backingInt(RenderStateData.cursor_viewport_y), &y);
            return .{ .x = x, .y = y };
        }
        return null;
    }

    pub fn cursorVisible(self: *Runtime, render_state: ?*anyopaque) bool {
        if (render_state) |state| {
            var visible = false;
            if (self.render_state_get(state, @backingInt(RenderStateData.cursor_visible), &visible) == success) return visible;
        }
        return false;
    }

    pub fn cursorVisualStyle(self: *Runtime, render_state: ?*anyopaque) CursorVisualStyle {
        if (render_state) |state| {
            var style: u32 = 0;
            _ = self.render_state_get(state, @backingInt(RenderStateData.cursor_visual_style), &style);
            return @fromBackingInt(@intCast(style));
        }
        return .block;
    }

    pub fn cursorBlinking(self: *Runtime, render_state: ?*anyopaque) bool {
        if (render_state) |state| {
            var blinking = false;
            if (self.render_state_get(state, @backingInt(RenderStateData.cursor_blinking), &blinking) == success) return blinking;
        }
        return false;
    }

    pub fn cursorPasswordInput(self: *Runtime, render_state: ?*anyopaque) bool {
        if (render_state) |state| {
            var password_input = false;
            if (self.render_state_get(state, @backingInt(RenderStateData.cursor_password_input), &password_input) == success) return password_input;
        }
        return false;
    }

    pub fn cursorWideTail(self: *Runtime, render_state: ?*anyopaque) bool {
        if (render_state) |state| {
            var wide_tail = false;
            if (self.render_state_get(state, @backingInt(RenderStateData.cursor_viewport_wide_tail), &wide_tail) == success) return wide_tail;
        }
        return false;
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

        self.key_event_set_key(event, @backingInt(key));
        self.key_event_set_action(event, @backingInt(action));
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
            self.mouse_encoder_setopt(mouse_encoder, @backingInt(MouseEncOpt.size), &copy);
        }
    }

    pub fn setMouseEncoderAnyButtonPressed(self: *Runtime, encoder: ?*anyopaque, pressed: bool) void {
        if (encoder) |mouse_encoder| {
            var copy = pressed;
            self.mouse_encoder_setopt(mouse_encoder, @backingInt(MouseEncOpt.any_button_pressed), &copy);
        }
    }

    pub fn setMouseEncoderTrackLastCell(self: *Runtime, encoder: ?*anyopaque, track: bool) void {
        if (encoder) |mouse_encoder| {
            var copy = track;
            self.mouse_encoder_setopt(mouse_encoder, @backingInt(MouseEncOpt.track_last_cell), &copy);
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
        self.mouse_event_set_action(event, @backingInt(action));
        if (button) |value| self.mouse_event_set_button(event, @backingInt(value)) else self.mouse_event_clear_button(event);
        self.mouse_event_set_mods(event, mods);
        self.mouse_event_set_position(event, position);
        var written: usize = 0;
        if (self.mouse_encoder_encode(encoder, event, out.ptr, out.len, &written) == success and written > 0) return out[0..written];
        return null;
    }

    pub fn encodeFocus(self: *Runtime, event: FocusEvent, out: []u8) ?[]const u8 {
        if (out.len == 0) return null;
        var written: usize = 0;
        if (self.focus_encode(@backingInt(event), out.ptr, out.len, &written) == success and written > 0) return out[0..written];
        return null;
    }

    /// Raw row for typed row queries only, never a cache identity.
    pub fn rowRaw(self: *Runtime, row_iterator: ?*anyopaque) u64 {
        if (row_iterator) |iterator| {
            var raw: u64 = 0;
            if (self.row_get(iterator, @backingInt(RowData.raw), &raw) != success) return 0;
            return raw;
        }
        return 0;
    }

    /// Opaque identity: retain both words, including across viewport scrolls.
    pub fn rowId(self: *Runtime, iterator: ?*anyopaque) RowId {
        var id: NativeRowId = .{ .bits = .{ 0, 0 } };
        if (self.row_get(iterator, @backingInt(RowData.id), &id) != success) return 0;
        return @bitCast(id.bits);
    }

    /// Bulk view avoids mutating the cell iterator and one FFI call per cell.
    pub fn rowHashCells(self: *Runtime, row_iterator: ?*anyopaque, row_cells: *?*anyopaque) ?u64 {
        _ = row_cells;
        var view: CellsView = undefined;
        if (self.row_get(row_iterator, @backingInt(RowData.cells_raw), &view) != success) return null;
        var h: u64 = 0x517CC1B727220A95; // FNV-like seed
        const cells = if (view.ptr) |ptr| ptr[0..view.len] else &.{};
        for (cells) |raw| {
            // Wyhash-inspired mixing: fast and avalanche well
            h ^= raw;
            h = h *% 0x9E3779B97F4A7C15;
            h ^= h >> 30;
        }
        return h;
    }

    /// Native mode-aware paste. Output goes through the terminal's write callback.
    pub fn pasteText(_: *Runtime, terminal: ?*anyopaque, text: []const u8) !void {
        const Source = struct {
            fn read(context: ?*anyopaque, _: String, writer: Writer) callconv(.c) bool {
                const bytes: *const []const u8 = @ptrCast(@alignCast(context.?));
                return bytes.len == 0 or writer.write(writer.userdata, bytes.ptr, bytes.len);
            }
        };
        var source = text;
        const mime: String = .{ .ptr = "text/plain", .len = "text/plain".len };
        const paste: Paste = .{ .mimes = @ptrCast(&mime), .reader = .{ .read = Source.read, .userdata = @ptrCast(&source) } };
        switch (ghostty_terminal_paste(terminal, &paste, null)) {
            success => {},
            -7 => return error.UnsafePaste,
            -1 => return error.OutOfMemory,
            else => return error.PasteFailed,
        }
    }

    pub fn selectAt(self: *Runtime, terminal: ?*anyopaque, point: Point, line: bool) ?Selection {
        var ref: GridRef = .{ .size = @sizeOf(GridRef), .node = null, .x = 0, .y = 0 };
        if (self.terminal_grid_ref(terminal, point, &ref) != success) return null;
        var selected: Selection = .{ .size = @sizeOf(Selection), .start = ref, .end = ref, .rectangle = false };
        const result = if (line)
            ghostty_terminal_select_line(terminal, &.{ .ref = ref }, &selected)
        else
            ghostty_terminal_select_word(terminal, &.{ .ref = ref }, &selected);
        return if (result == success) selected else null;
    }

    pub fn gridRefPoint(_: *Runtime, terminal: ?*anyopaque, ref: *const GridRef, tag: PointTag) ?PointCoordinate {
        var point: PointCoordinate = undefined;
        return if (ghostty_terminal_point_from_grid_ref(terminal, ref, tag, &point) == success) point else null;
    }
};

/// Resolve a StyleColor tagged union to an RGB value, falling back to `default` when NONE.
/// When PALETTE, looks up the color in the provided 256-entry palette.
pub fn resolveStyleColor(sc: StyleColor, default: ColorRgb, palette: *const [256]ColorRgb) ColorRgb {
    return switch (sc.tag) {
        .none => default,
        .palette => palette[sc.value.palette],
        .rgb => sc.value.rgb,
    };
}

test "synchronized output mode round trips through Ghostty" {
    var runtime = try Runtime.init(std.testing.allocator, null);
    defer runtime.deinit();

    const terminal = try runtime.createTerminal(80, 24, 0);
    defer runtime.freeTerminal(terminal);

    try std.testing.expect(!runtime.terminalMode(terminal, .synchronized_output));
    runtime.terminalWrite(terminal, "\x1b[?2026h");
    try std.testing.expect(runtime.terminalMode(terminal, .synchronized_output));
    try std.testing.expect(runtime.setTerminalMode(terminal, .synchronized_output, false));
    try std.testing.expect(!runtime.terminalMode(terminal, .synchronized_output));
}

test "native prompt navigation moves relative to viewport top" {
    var runtime = try Runtime.init(std.testing.allocator, null);
    defer runtime.deinit();
    const terminal = try runtime.createTerminal(40, 3, 1000);
    defer runtime.freeTerminal(terminal);
    for (0..8) |_| runtime.terminalWrite(terminal, "\x1b]133;A\x07$ \x1b]133;B\x07command\x1b]133;C\x07\r\noutput\r\n\x1b]133;D;0\x07");
    runtime.terminalScrollTop(terminal);
    runtime.terminalScrollPrompt(terminal, 1);
    try std.testing.expectEqual(@as(u64, 2), runtime.terminalScrollbar(terminal).?.offset);
    runtime.terminalScrollPrompt(terminal, -1);
    try std.testing.expectEqual(@as(u64, 0), runtime.terminalScrollbar(terminal).?.offset);
}

test "callback bindings match upstream C layouts" {
    const headers = @import("ghostty_c");
    try std.testing.expectEqual(@sizeOf(headers.GhosttyTerminalProgramStatus), @sizeOf(ProgramStatus));
    try std.testing.expectEqual(@offsetOf(headers.GhosttyTerminalProgramStatus, "message"), @offsetOf(ProgramStatus, "message"));
    try std.testing.expectEqual(@sizeOf(headers.GhosttyTerminalSemanticPrompt), @sizeOf(SemanticPrompt));
    try std.testing.expectEqual(@sizeOf(headers.GhosttyClipboardWrite), @sizeOf(ClipboardWrite));
    try std.testing.expectEqual(@offsetOf(headers.GhosttyClipboardWrite, "reply"), @offsetOf(ClipboardWrite, "reply"));
    try std.testing.expectEqual(@sizeOf(headers.GhosttyClipboardWriteReply), @sizeOf(ClipboardWriteReply));
    try std.testing.expectEqual(@sizeOf(headers.GhosttyPaste), @sizeOf(Paste));
    try std.testing.expectEqual(@offsetOf(headers.GhosttyPaste, "reader"), @offsetOf(Paste, "reader"));
    try std.testing.expectEqual(@sizeOf(headers.GhosttyRenderStateRowId), @sizeOf(NativeRowId));
    try std.testing.expectEqual(@sizeOf(headers.GhosttyCellsView), @sizeOf(CellsView));
    try std.testing.expectEqual(@sizeOf(headers.GhosttyTerminalSelectWordOptions), @sizeOf(SelectWordOptions));
    try std.testing.expectEqual(@sizeOf(headers.GhosttyTerminalSelectLineOptions), @sizeOf(SelectLineOptions));
    try std.testing.expectEqual(@sizeOf(headers.GhosttyTerminalDesktopNotification), @sizeOf(DesktopNotification));
    try std.testing.expectEqual(@sizeOf(headers.GhosttyTerminalProgressReport), @sizeOf(ProgressReport));
}

test "native image iteration resolves placements and tracks replacement generations" {
    var runtime = try Runtime.init(std.testing.allocator, null);
    defer runtime.deinit();
    const terminal = try runtime.createTerminal(20, 6, 4096);
    defer runtime.freeTerminal(terminal);
    runtime.resizeTerminal(terminal, 20, 6, 8, 16);
    const state = try runtime.createRenderState();
    defer runtime.freeRenderState(state);
    var images: RenderImages = .{};
    defer images.deinit(std.testing.allocator);

    runtime.terminalWrite(terminal, "\x1b_Ga=T,f=32,i=1,s=1,v=1,c=2,r=1,z=-1,q=2;/wAA/w==\x1b\\");
    try runtime.updateRenderState(state, terminal);
    try images.update(std.testing.allocator, state);
    try std.testing.expectEqual(@as(usize, 1), images.items.items.len);
    const original = images.items.items[0];
    try std.testing.expectEqual(@as(u32, 1), original.image_id);
    try std.testing.expectEqual(@as(c_int, @backingInt(ImageLayer.below_text)), original.layer);
    try std.testing.expectEqual(@as(u32, 16), original.width);
    try std.testing.expectEqual(@as(u32, 16), original.height);
    try std.testing.expect(original.generation != 0);

    runtime.terminalWrite(terminal, "\x1b_Ga=T,f=32,i=1,s=1,v=1,c=2,r=1,q=2;AAD//w==\x1b\\");
    try runtime.updateRenderState(state, terminal);
    try images.update(std.testing.allocator, state);
    try std.testing.expect(images.items.items.len > 0);
    for (images.items.items) |image| try std.testing.expect(image.generation != original.generation);

    // Virtual placements are visible only through their Unicode placeholder cells.
    runtime.terminalWrite(terminal, "\x1b_Ga=T,U=1,f=32,i=3,s=1,v=1,c=2,r=1,q=2;AP8A/w==\x1b\\" ++
        "\r\n\x1b[38;5;3m\xf4\x8e\xbb\xae\xcc\x85\xcc\x85\xf4\x8e\xbb\xae\xcc\x85\xcc\x8d\x1b[39m");
    try runtime.updateRenderState(state, terminal);
    try images.update(std.testing.allocator, state);
    var placeholders: usize = 0;
    for (images.items.items) |image| {
        if (image.image_id == 3) {
            placeholders += 1;
            try std.testing.expectEqual(@as(i32, 1), image.row);
            try std.testing.expect(image.width > 0 and image.height > 0);
        }
    }
    try std.testing.expect(placeholders > 0);
    // Relative placements follow their parent, not the terminal cursor.
    runtime.terminalWrite(terminal, "\x1b_Ga=T,f=32,i=4,p=1,s=1,v=1,c=1,r=1,C=1,q=2;/wAA/w==\x1b\\" ++
        "\x1b_Ga=T,f=32,i=5,s=1,v=1,c=1,r=1,P=4,Q=1,H=2,V=1,q=2;AAD//w==\x1b\\");
    try runtime.updateRenderState(state, terminal);
    try images.update(std.testing.allocator, state);
    var parent: ?RenderImage = null;
    var child: ?RenderImage = null;
    for (images.items.items) |image| {
        if (image.image_id == 4) parent = image;
        if (image.image_id == 5) child = image;
    }
    try std.testing.expect(parent != null and child != null);
    try std.testing.expectEqual(parent.?.col + 2, child.?.col);
    try std.testing.expectEqual(parent.?.row + 1, child.?.row);
    try images.update(std.testing.allocator, null);
    try std.testing.expectEqual(@as(usize, 0), images.items.items.len);
}

test "native animation deadlines change image generations and stop cleanly" {
    var runtime = try Runtime.init(std.testing.allocator, null);
    defer runtime.deinit();
    const terminal = try runtime.createTerminal(20, 6, 0);
    defer runtime.freeTerminal(terminal);
    runtime.terminalWrite(terminal, "\x1b_Ga=T,f=32,i=2,s=1,v=1,q=2;/wAA/w==\x1b\\" ++
        "\x1b_Ga=f,f=32,i=2,s=1,v=1,z=40,q=2;AAD//w==\x1b\\" ++
        "\x1b_Ga=a,i=2,r=1,z=30,q=2\x1b\\\x1b_Ga=a,i=2,s=3,q=2\x1b\\");
    const graphics = runtime.terminalKittyGraphics(terminal).?;
    const deadline = runtime.tickKittyAnimation(graphics, 1000).?;
    try std.testing.expectEqual(@as(u64, 1030), deadline);
    var generation: u64 = 0;
    try std.testing.expect(runtime.kittyImageData(runtime.kittyGraphicsImage(graphics, 2), .generation, &generation));
    const storage_generation = runtime.kittyStorageGeneration(graphics);
    try std.testing.expectEqual(@as(u64, 1070), runtime.tickKittyAnimation(graphics, deadline).?);
    var next_generation: u64 = 0;
    try std.testing.expect(runtime.kittyImageData(runtime.kittyGraphicsImage(graphics, 2), .generation, &next_generation));
    try std.testing.expect(next_generation != generation);
    try std.testing.expect(runtime.kittyStorageGeneration(graphics) != storage_generation);
    runtime.terminalWrite(terminal, "\x1b_Ga=a,i=2,s=1,q=2\x1b\\");
    try std.testing.expectEqual(@as(?u64, null), runtime.tickKittyAnimation(runtime.terminalKittyGraphics(terminal), 1070));
}

test "native paste sanitizes controls and refuses command injection without output" {
    var runtime = try Runtime.init(std.testing.allocator, null);
    defer runtime.deinit();
    const terminal = try runtime.createTerminal(80, 24, 0);
    defer runtime.freeTerminal(terminal);
    var output: PasteOutput = .{ .allocator = std.testing.allocator };
    defer output.deinit();
    const Sink = struct {
        fn write(_: ?*anyopaque, context: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void {
            const sink: *PasteOutput = @ptrCast(@alignCast(context.?));
            sink.append(bytes[0..len]);
        }
    };
    runtime.setTerminalUserdata(terminal, &output);
    runtime.setWritePtyCallback(terminal, Sink.write);
    try runtime.pasteText(terminal, "hello\x1bworld");
    try std.testing.expectEqualStrings("hello world", output.bytes.items);
    output.bytes.clearRetainingCapacity();
    try std.testing.expectError(error.UnsafePaste, runtime.pasteText(terminal, "echo safe\necho unsafe"));
    try std.testing.expectEqual(@as(usize, 0), output.bytes.items.len);
    runtime.terminalWrite(terminal, "\x1b[?2004h");
    try runtime.pasteText(terminal, "a\nb");
    try std.testing.expectEqualStrings("\x1b[200~a\nb\x1b[201~", output.bytes.items);
    output.bytes.clearRetainingCapacity();
    try std.testing.expectError(error.UnsafePaste, runtime.pasteText(terminal, "evil\x1b[201~command"));
    try std.testing.expectEqual(@as(usize, 0), output.bytes.items.len);
}

test "paste staging retains allocation failure and discards subsequent chunks" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    var output: PasteOutput = .{ .allocator = failing.allocator() };
    defer output.deinit();
    output.append("\x1b[200~");
    output.append("payload");
    output.append("\x1b[201~");
    try std.testing.expectEqual(error.OutOfMemory, output.failure.?);
    try std.testing.expectEqual(@as(usize, 0), output.bytes.items.len);
}

test "native word selection handles Unicode and soft wraps" {
    var runtime = try Runtime.init(std.testing.allocator, null);
    defer runtime.deinit();
    const terminal = try runtime.createTerminal(5, 4, 1000);
    defer runtime.freeTerminal(terminal);
    runtime.terminalWrite(terminal, "h\xc3\xa9lloworld next");
    const selected = runtime.selectAt(terminal, .{ .tag = .viewport, .value = .{ .coordinate = .{ .x = 1, .y = 1 } } }, false).?;
    var bytes: [64]u8 = undefined;
    var written: usize = 0;
    try std.testing.expectEqual(success, runtime.formatSelectionInto(terminal, &selected, &bytes, &written));
    try std.testing.expectEqualStrings("h\xc3\xa9lloworld", bytes[0..written]);
}

test "documented row identities survive scrolling and bulk hashes match cell iteration" {
    var runtime = try Runtime.init(std.testing.allocator, null);
    defer runtime.deinit();
    const terminal = try runtime.createTerminal(8, 3, 4096);
    defer runtime.freeTerminal(terminal);
    runtime.terminalWrite(terminal, "one\r\ntwo\r\nthree");
    const state = try runtime.createRenderState();
    defer runtime.freeRenderState(state);
    var rows = try runtime.createRowIterator();
    defer runtime.freeRowIterator(rows);
    var cells = try runtime.createRowCells();
    defer runtime.freeRowCells(cells);
    try runtime.updateRenderState(state, terminal);
    try std.testing.expect(runtime.populateRowIterator(state, &rows));
    try std.testing.expect(runtime.nextRow(rows));
    const id = runtime.rowId(rows);
    try std.testing.expect(id != 0);
    const bulk_hash = runtime.rowHashCells(rows, &cells).?;
    try std.testing.expect(runtime.populateRowCells(rows, &cells));
    var hash: u64 = 0x517CC1B727220A95;
    while (runtime.nextCell(cells)) {
        hash ^= runtime.cellRaw(cells);
        hash *%= 0x9E3779B97F4A7C15;
        hash ^= hash >> 30;
    }
    try std.testing.expectEqual(hash, bulk_hash);
    runtime.terminalWrite(terminal, "\r\nfour");
    runtime.terminalScrollTop(terminal);
    try runtime.updateRenderState(state, terminal);
    try std.testing.expect(runtime.populateRowIterator(state, &rows));
    try std.testing.expect(runtime.nextRow(rows));
    try std.testing.expectEqual(id, runtime.rowId(rows));
}

test "terminal default colors are exposed through render state" {
    var runtime = try Runtime.init(std.testing.allocator, null);
    defer runtime.deinit();

    const terminal = try runtime.createTerminal(80, 24, 0);
    defer runtime.freeTerminal(terminal);

    var palette = @as([256]ColorRgb, @splat(.{ .r = 0, .g = 0, .b = 0 }));
    palette[0] = .{ .r = 1, .g = 2, .b = 3 };
    const foreground = ColorRgb{ .r = 220, .g = 221, .b = 222 };
    const background = ColorRgb{ .r = 25, .g = 26, .b = 28 };
    runtime.setTerminalDefaultColors(terminal, foreground, background, null, &palette);

    const render_state = try runtime.createRenderState();
    defer runtime.freeRenderState(render_state);
    try runtime.updateRenderState(render_state, terminal);

    const colors = runtime.renderStateColors(render_state).?;
    try std.testing.expectEqual(foreground, colors.foreground);
    try std.testing.expectEqual(background, colors.background);
    try std.testing.expectEqual(palette[0], colors.palette[0]);
}

test "row wrap flags distinguish soft wraps from newlines" {
    var runtime = try Runtime.init(std.testing.allocator, null);
    defer runtime.deinit();
    const terminal = try runtime.createTerminal(8, 4, 0);
    defer runtime.freeTerminal(terminal);
    runtime.terminalWrite(terminal, "https://example\r\nnext");
    const render_state = try runtime.createRenderState();
    defer runtime.freeRenderState(render_state);
    try runtime.updateRenderState(render_state, terminal);
    var iterator = try runtime.createRowIterator();
    defer runtime.freeRowIterator(iterator);
    try std.testing.expect(runtime.populateRowIterator(render_state, &iterator));
    try std.testing.expect(runtime.nextRow(iterator));
    var row = runtime.rowRaw(iterator);
    try std.testing.expect(runtime.rowWrapped(row));
    try std.testing.expect(!runtime.rowWrapContinuation(row));
    try std.testing.expect(runtime.nextRow(iterator));
    row = runtime.rowRaw(iterator);
    try std.testing.expect(!runtime.rowWrapped(row));
    try std.testing.expect(runtime.rowWrapContinuation(row));
    try std.testing.expect(runtime.nextRow(iterator));
    row = runtime.rowRaw(iterator);
    try std.testing.expect(!runtime.rowWrapped(row));
    try std.testing.expect(!runtime.rowWrapContinuation(row));
}
