-- src/core/ghostty_ffi.lua
-- LuaJIT FFI bindings for ghostty-vt.dll
--
-- Derived from the official ghostling reference implementation:
--   https://github.com/ghostty-org/ghostling/blob/main/main.c
--   #include <ghostty/vt.h>
--
-- KEY FACTS about the ABI:
--   - All *_new() functions use the Zig allocator calling convention:
--       GhosttyResult fn(allocator*, handle**, config_value)
--     Pass NULL as allocator to use the default Zig page allocator.
--   - GhosttyResult is int32 (0 = GHOSTTY_SUCCESS).
--   - Opaque handles are void* in Lua (we never dereference them).
--   - ghostty_terminal_new takes opts BY VALUE (struct in register/stack),
--     NOT by pointer.  LuaJIT passes structs by value when the C signature
--     says so.  We define the struct and pass it directly.

local ffi      = require("ffi")
local Platform = require("src.core.platform")

-- ── Load the DLL ─────────────────────────────────────────────────────────────
local lib
for _, path in ipairs(Platform.lib_search_paths()) do
    local ok, result = pcall(ffi.load, path)
    if ok then
        lib = result
        print("[ghostty-ffi] Loaded:", path)
        break
    else
        print("[ghostty-ffi] Failed to load:", path, "-", result)
    end
end
if not lib then
    error("[ghostty-ffi] Could not load ghostty-vt.dll.\n" ..
          "Place ghostty-vt.dll next to love.exe or bundle it as lib/ghostty-vt.dll")
end

-- ── C declarations ────────────────────────────────────────────────────────────
-- All types taken directly from ghostling/main.c usage of <ghostty/vt.h>.
-- Opaque handles: the library owns the memory; we only hold pointers.

ffi.cdef[[
    /* ── Result code ── */
    /* GHOSTTY_SUCCESS = 0 */
    typedef int32_t GhosttyResult;

    /* ── Opaque handle types (all void* from our perspective) ── */
    typedef void* GhosttyTerminal;
    typedef void* GhosttyRenderState;
    typedef void* GhosttyRenderStateRowIterator;
    typedef void* GhosttyRenderStateRowCells;
    typedef void* GhosttyKeyEncoder;
    typedef void* GhosttyKeyEvent;
    typedef void* GhosttyMouseEncoder;
    typedef void* GhosttyMouseEvent;

    /* ── GhosttyTerminalOptions (passed BY VALUE to ghostty_terminal_new) ── */
    typedef struct {
        uint16_t cols;
        uint16_t rows;
        uint32_t max_scrollback;
    } GhosttyTerminalOptions;

    /* ── GhosttyColorRgb ── */
    typedef struct { uint8_t r; uint8_t g; uint8_t b; } GhosttyColorRgb;

    /* ── GhosttyColorPaletteIndex ── */
    typedef uint8_t GhosttyColorPaletteIndex;

    /* ── GhosttyStyleColorTag ── */
    typedef uint32_t GhosttyStyleColorTag;  /* enum: 0=none 1=palette 2=rgb */

    /* ── GhosttyStyleColorValue (union, sized by largest member = uint64_t) ── */
    typedef union {
        GhosttyColorPaletteIndex palette;
        GhosttyColorRgb          rgb;
        uint64_t                 _padding;
    } GhosttyStyleColorValue;

    /* ── GhosttyStyleColor (tagged union) ── */
    /* tag(4) + padding(4) + value(8) = 16 bytes */
    typedef struct {
        GhosttyStyleColorTag  tag;
        GhosttyStyleColorValue value;
    } GhosttyStyleColor;

    /* ── GhosttyStyle (sized struct) ── */
    /* Layout from include/ghostty/vt/style.h:
         size_t size           (8 bytes)
         GhosttyStyleColor fg_color       (16 bytes, offset 8)
         GhosttyStyleColor bg_color       (16 bytes, offset 24)
         GhosttyStyleColor underline_color(16 bytes, offset 40)
         bool bold, italic, faint, blink, inverse, invisible, strikethrough, overline (8 bytes, offset 56)
         int underline        (4 bytes, offset 64)
    */
    typedef struct {
        size_t size;
        GhosttyStyleColor fg_color;
        GhosttyStyleColor bg_color;
        GhosttyStyleColor underline_color;
        bool bold;
        bool italic;
        bool faint;
        bool blink;
        bool inverse;
        bool invisible;
        bool strikethrough;
        bool overline;
        int32_t underline;
    } GhosttyStyle;

    /* GhosttyRenderStateColors (sized struct) */
    /* Layout from include/ghostty/vt/render.h GhosttyRenderStateColors:
         size_t size              (8 bytes)
         GhosttyColorRgb background   (3 bytes, offset 8)
         GhosttyColorRgb foreground   (3 bytes, offset 11)
         GhosttyColorRgb cursor       (3 bytes, offset 14)
         bool cursor_has_value        (1 byte,  offset 17)
         GhosttyColorRgb palette[256] (768 bytes, offset 18)
       Total: 786 bytes
    */
    typedef struct {
        size_t size;
        GhosttyColorRgb background;
        GhosttyColorRgb foreground;
        GhosttyColorRgb cursor;
        bool cursor_has_value;
        GhosttyColorRgb palette[256];
    } GhosttyRenderStateColors;

    /* ── GhosttyTerminalScrollbar ── */
    typedef struct {
        uint64_t total;
        uint64_t offset;
        uint64_t len;
    } GhosttyTerminalScrollbar;

    /* ── GhosttyMousePosition ── */
    typedef struct { float x; float y; } GhosttyMousePosition;

    /* ── GhosttyMouseEncoderSize (sized struct) ── */
    typedef struct {
        size_t size;
        uint32_t screen_width;
        uint32_t screen_height;
        uint32_t cell_width;
        uint32_t cell_height;
        uint32_t padding_top;
        uint32_t padding_bottom;
        uint32_t padding_left;
        uint32_t padding_right;
    } GhosttyMouseEncoderSize;

    /* ── SizeReportSize (for effect_size callback) ── */
    typedef struct {
        uint16_t rows;
        uint16_t columns;
        uint32_t cell_width;
        uint32_t cell_height;
    } GhosttySizeReportSize;

    /* ── DeviceAttributes (for effect_device_attributes callback) ── */
    typedef struct {
        uint8_t  conformance_level;
        uint8_t  features[8];
        uint8_t  num_features;
        /* secondary */
        uint8_t  device_type;
        uint32_t firmware_version;
        uint8_t  rom_cartridge;
        /* tertiary */
        uint64_t unit_id;
    } GhosttyDeviceAttributes;

    /* ── GhosttyString ── */
    typedef struct {
        const uint8_t* ptr;
        size_t len;
    } GhosttyString;

    /* ── GhosttyTerminalScrollViewport ── */
    /* tag 0 = delta */
    typedef struct {
        uint32_t tag;
        union { intptr_t delta; } value;
    } GhosttyTerminalScrollViewport;

    /* ── GhosttyFocusEvent ── */
    typedef uint32_t GhosttyFocusEvent;

    /* ════════════════════════════════════════════════════════════════════
       BUILD INFO
       ════════════════════════════════════════════════════════════════════ */

    /* ghostty_build_info(tag, out_ptr) */
    /* tag: 0=simd(bool*), 1=optimize(int32*) */
    GhosttyResult ghostty_build_info(uint32_t tag, void* out);

    /* ════════════════════════════════════════════════════════════════════
       TERMINAL
       ════════════════════════════════════════════════════════════════════ */

    /* ghostty_terminal_new(allocator*, &terminal, opts*) -- opts BY POINTER on Windows x64 */
    GhosttyResult ghostty_terminal_new(void* allocator,
                                       GhosttyTerminal* out,
                                       const GhosttyTerminalOptions* opts);
    void ghostty_terminal_free(GhosttyTerminal t);

    /* Feed raw VT bytes from the PTY into the parser */
    void ghostty_terminal_vt_write(GhosttyTerminal t,
                                   const uint8_t* data, size_t len);

    /* Resize the grid.  Also takes pixel cell dimensions for XTWINOPS. */
    void ghostty_terminal_resize(GhosttyTerminal t,
                                 uint16_t cols, uint16_t rows,
                                 uint32_t cell_width_px,
                                 uint32_t cell_height_px);

    /* Generic getter: ghostty_terminal_get(terminal, tag, out_ptr) */
    GhosttyResult ghostty_terminal_get(GhosttyTerminal t,
                                       uint32_t tag, void* out);

    /* Generic setter: ghostty_terminal_set(terminal, tag, val_ptr) */
    void ghostty_terminal_set(GhosttyTerminal t,
                              uint32_t tag, const void* val);

    /* Mode get/set */
    GhosttyResult ghostty_terminal_mode_get(GhosttyTerminal t,
                                             uint32_t mode, bool* out);

    /* Scroll viewport -- sv passed BY POINTER on Windows x64 */
    void ghostty_terminal_scroll_viewport(GhosttyTerminal t,
                                          const GhosttyTerminalScrollViewport* sv);

    /* ════════════════════════════════════════════════════════════════════
       RENDER STATE
       ════════════════════════════════════════════════════════════════════ */

    /* ghostty_render_state_new(allocator*, &render_state) */
    GhosttyResult ghostty_render_state_new(void* allocator,
                                            GhosttyRenderState* out);
    void ghostty_render_state_free(GhosttyRenderState rs);

    /* Snapshot terminal state into render state */
    GhosttyResult ghostty_render_state_update(GhosttyRenderState rs,
                                              GhosttyTerminal t);

    /* Read render state property */
    GhosttyResult ghostty_render_state_get(GhosttyRenderState rs,
                                            uint32_t tag, void* out);

    /* Write render state property */
    GhosttyResult ghostty_render_state_set(GhosttyRenderState rs,
                                            uint32_t tag, const void* val);

    /* Get color palette from render state */
    GhosttyResult ghostty_render_state_colors_get(GhosttyRenderState rs,
                                                   GhosttyRenderStateColors* out);

    /* ── Row Iterator ── */
    /* ghostty_render_state_row_iterator_new(allocator*, &row_iter) */
    GhosttyResult ghostty_render_state_row_iterator_new(
        void* allocator, GhosttyRenderStateRowIterator* out);
    void ghostty_render_state_row_iterator_free(GhosttyRenderStateRowIterator it);

    /* Advance; returns false when exhausted */
    bool ghostty_render_state_row_iterator_next(GhosttyRenderStateRowIterator it);

    /* Get a property of the current row */
    GhosttyResult ghostty_render_state_row_get(GhosttyRenderStateRowIterator it,
                                                uint32_t tag, void* out);

    /* Set a property of the current row (e.g. clear dirty flag) */
    GhosttyResult ghostty_render_state_row_set(GhosttyRenderStateRowIterator it,
                                                uint32_t tag, const void* val);

    /* ── Row Cells ── */
    /* ghostty_render_state_row_cells_new(allocator*, &cells) */
    GhosttyResult ghostty_render_state_row_cells_new(
        void* allocator, GhosttyRenderStateRowCells* out);
    void ghostty_render_state_row_cells_free(GhosttyRenderStateRowCells cells);

    /* Advance; returns false when exhausted */
    bool ghostty_render_state_row_cells_next(GhosttyRenderStateRowCells cells);

    /* Read a property of the current cell */
    GhosttyResult ghostty_render_state_row_cells_get(
        GhosttyRenderStateRowCells cells, uint32_t tag, void* out);

    /* ════════════════════════════════════════════════════════════════════
       KEY ENCODER + EVENT
       ════════════════════════════════════════════════════════════════════ */

    /* ghostty_key_encoder_new(allocator*, &encoder) */
    GhosttyResult ghostty_key_encoder_new(void* allocator,
                                           GhosttyKeyEncoder* out);
    void ghostty_key_encoder_free(GhosttyKeyEncoder e);

    /* Sync encoder options from terminal's current mode state */
    void ghostty_key_encoder_setopt_from_terminal(GhosttyKeyEncoder e,
                                                   GhosttyTerminal t);

    /* Encode a key event → VT bytes.
       Returns GHOSTTY_SUCCESS and sets *written to byte count. */
    GhosttyResult ghostty_key_encoder_encode(GhosttyKeyEncoder e,
                                              GhosttyKeyEvent ev,
                                              char* out_buf, size_t out_size,
                                              size_t* written);

    /* ghostty_key_event_new(allocator*, &event) */
    GhosttyResult ghostty_key_event_new(void* allocator,
                                         GhosttyKeyEvent* out);
    void ghostty_key_event_free(GhosttyKeyEvent ev);

    void ghostty_key_event_set_key(GhosttyKeyEvent ev, uint32_t key);
    void ghostty_key_event_set_action(GhosttyKeyEvent ev, uint32_t action);
    void ghostty_key_event_set_mods(GhosttyKeyEvent ev, uint32_t mods);
    void ghostty_key_event_set_consumed_mods(GhosttyKeyEvent ev, uint32_t mods);
    void ghostty_key_event_set_unshifted_codepoint(GhosttyKeyEvent ev, uint32_t cp);
    void ghostty_key_event_set_utf8(GhosttyKeyEvent ev,
                                    const char* text, size_t len);

    /* ════════════════════════════════════════════════════════════════════
       MOUSE ENCODER + EVENT
       ════════════════════════════════════════════════════════════════════ */

    /* ghostty_mouse_encoder_new(allocator*, &encoder) */
    GhosttyResult ghostty_mouse_encoder_new(void* allocator,
                                             GhosttyMouseEncoder* out);
    void ghostty_mouse_encoder_free(GhosttyMouseEncoder e);

    /* Sync encoder options from terminal's current mode state */
    void ghostty_mouse_encoder_setopt_from_terminal(GhosttyMouseEncoder e,
                                                     GhosttyTerminal t);

    /* Set a size/geometry option on the encoder */
    void ghostty_mouse_encoder_setopt(GhosttyMouseEncoder e,
                                      uint32_t tag, const void* val);

    /* Encode a mouse event → VT bytes.
       Returns GHOSTTY_SUCCESS and sets *written to byte count. */
    GhosttyResult ghostty_mouse_encoder_encode(GhosttyMouseEncoder e,
                                                GhosttyMouseEvent ev,
                                                char* out_buf, size_t out_size,
                                                size_t* written);

    /* ghostty_mouse_event_new(allocator*, &event) */
    GhosttyResult ghostty_mouse_event_new(void* allocator,
                                           GhosttyMouseEvent* out);
    void ghostty_mouse_event_free(GhosttyMouseEvent ev);

    void ghostty_mouse_event_set_action  (GhosttyMouseEvent ev, uint32_t action);
    void ghostty_mouse_event_set_button  (GhosttyMouseEvent ev, uint32_t button);
    void ghostty_mouse_event_clear_button(GhosttyMouseEvent ev);
    void ghostty_mouse_event_set_mods    (GhosttyMouseEvent ev, uint32_t mods);
    void ghostty_mouse_event_set_position(GhosttyMouseEvent ev,
                                          const GhosttyMousePosition* pos);

    /* ════════════════════════════════════════════════════════════════════
       FOCUS ENCODE
       ════════════════════════════════════════════════════════════════════ */

    /* Encode a focus event (FOCUS_GAINED=0, FOCUS_LOST=1).
       Returns GHOSTTY_SUCCESS and sets *written. */
    GhosttyResult ghostty_focus_encode(GhosttyFocusEvent ev,
                                        char* out_buf, size_t out_size,
                                        size_t* written);
]]

-- ── Module table ──────────────────────────────────────────────────────────────
local M = {}
M.lib = lib

-- ── Known constants ────────────────────────────────────────────────────────────
-- All values are taken from ghostling/main.c and cross-checked with the
-- ghostty source (src/terminal/Terminal.zig, src/input/key.zig, etc.)

M.GHOSTTY_SUCCESS = 0

-- Terminal option tags (for ghostty_terminal_set)
M.TERMINAL_OPT = {
    USERDATA          = 0,
    WRITE_PTY         = 1,
    SIZE              = 2,
    DEVICE_ATTRIBUTES = 3,
    XTVERSION         = 4,
    TITLE_CHANGED     = 5,
    COLOR_SCHEME      = 6,
}

-- Terminal data tags (for ghostty_terminal_get)
M.TERMINAL_DATA = {
    TITLE           = 0,
    SCROLLBAR       = 1,
    MOUSE_TRACKING  = 2,
}

-- Mode constants (for ghostty_terminal_mode_get)
M.MODE = {
    FOCUS_EVENT  = 1004,
    BRACKETED_PASTE = 2004,
}

-- Render state data tags (for ghostty_render_state_get)
-- Values confirmed from include/ghostty/vt/render.h
M.RS_DATA = {
    INVALID                   = 0,
    COLS                      = 1,   -- uint16_t: viewport cols
    ROWS                      = 2,   -- uint16_t: viewport rows
    DIRTY                     = 3,   -- GhosttyRenderStateDirty
    ROW_ITERATOR              = 4,   -- confirmed by disassembly + header
    COLOR_BACKGROUND          = 5,   -- GhosttyColorRgb
    COLOR_FOREGROUND          = 6,   -- GhosttyColorRgb
    COLOR_CURSOR              = 7,   -- GhosttyColorRgb
    COLOR_CURSOR_HAS_VALUE    = 8,   -- bool
    -- 9 = COLOR_PALETTE (GhosttyColorRgb[256], 768 bytes — do not use naively)
    -- 10 = CURSOR_VISUAL_STYLE
    CURSOR_VISIBLE            = 11,  -- bool
    CURSOR_BLINKING           = 12,  -- bool
    CURSOR_PASSWORD_INPUT     = 13,  -- bool
    CURSOR_VIEWPORT_HAS_VALUE = 14,  -- bool: cursor within viewport
    CURSOR_VIEWPORT_X         = 15,  -- uint16_t (valid only when HAS_VALUE=true)
    CURSOR_VIEWPORT_Y         = 16,  -- uint16_t (valid only when HAS_VALUE=true)
    CURSOR_VIEWPORT_WIDE_TAIL = 17,  -- bool (valid only when HAS_VALUE=true)
}

-- Render state option tags (for ghostty_render_state_set)
M.RS_OPT = {
    DIRTY = 0,
}

-- Render state dirty values
M.RS_DIRTY = {
    FALSE = 0,
    TRUE  = 1,
}

-- Row data tags (for ghostty_render_state_row_get)
-- Values from include/ghostty/vt/render.h GhosttyRenderStateRowData
M.ROW_DATA = {
    INVALID = 0,
    DIRTY   = 1,
    RAW     = 2,
    CELLS   = 3,   -- GhosttyRenderStateRowCells*
}

-- Row option tags (for ghostty_render_state_row_set)
M.ROW_OPT = {
    DIRTY = 0,
}

-- Cell data tags (for ghostty_render_state_row_cells_get)
-- Values from include/ghostty/vt/render.h GhosttyRenderStateRowCellsData
M.CELL_DATA = {
    INVALID       = 0,
    RAW           = 1,
    STYLE         = 2,   -- GhosttyStyle
    GRAPHEMES_LEN = 3,   -- uint32_t: total codepoint count (0 = empty cell)
    GRAPHEMES_BUF = 4,   -- uint32_t[]: codepoints (base first, then extras)
    BG_COLOR      = 5,   -- GhosttyColorRgb (INVALID_VALUE if no bg)
    FG_COLOR      = 6,   -- GhosttyColorRgb (INVALID_VALUE if default fg)
}

-- Mouse encoder option tags
M.MOUSE_ENC_OPT = {
    SIZE                 = 0,
    ANY_BUTTON_PRESSED   = 1,
    TRACK_LAST_CELL      = 2,
}

-- Mouse actions
M.MOUSE_ACTION = {
    PRESS   = 0,
    RELEASE = 1,
    MOTION  = 2,
}

-- Mouse buttons
M.MOUSE_BUTTON = {
    UNKNOWN = 0,
    LEFT    = 1,
    RIGHT   = 2,
    MIDDLE  = 3,
    FOUR    = 4,
    FIVE    = 5,
    SIX     = 6,
    SEVEN   = 7,
}

-- Key action values
M.KEY_ACTION = {
    PRESS   = 1,
    RELEASE = 0,
    REPEAT  = 2,
}

-- Modifier bitmask (matches GHOSTTY_MODS_*)
M.MODS = {
    NONE  = 0,
    SHIFT = 0x01,
    CTRL  = 0x02,
    ALT   = 0x04,
    SUPER = 0x08,
}

-- Focus events
M.FOCUS = {
    GAINED = 0,
    LOST   = 1,
}

-- Scroll viewport tag
M.SCROLL_VIEWPORT = {
    DELTA = 0,
}

-- Key codes (from ghostty's key.zig W3C UIEvents code mapping)
-- Taken from ghostling's raylib_key_to_ghostty() mapping.
M.KEY = {
    UNIDENTIFIED = 0,
    -- Writing system keys
    BACKQUOTE     = 1,
    BACKSLASH     = 2,
    BRACKET_LEFT  = 3,
    BRACKET_RIGHT = 4,
    COMMA         = 5,
    DIGIT_0 = 6, DIGIT_1 = 7, DIGIT_2 = 8, DIGIT_3 = 9,
    DIGIT_4 = 10, DIGIT_5 = 11, DIGIT_6 = 12, DIGIT_7 = 13,
    DIGIT_8 = 14, DIGIT_9 = 15,
    EQUAL         = 16,
    INTL_BACKSLASH = 17,
    INTL_RO        = 18,
    INTL_YEN       = 19,
    A=20, B=21, C=22, D=23, E=24, F=25, G=26, H=27, I=28, J=29,
    K=30, L=31, M=32, N=33, O=34, P=35, Q=36, R=37, S=38, T=39,
    U=40, V=41, W=42, X=43, Y=44, Z=45,
    MINUS   = 46,
    PERIOD  = 47,
    QUOTE   = 48,
    SEMICOLON = 49,
    SLASH   = 50,
    -- Functional keys
    ALT_LEFT    = 51,
    ALT_RIGHT   = 52,
    BACKSPACE   = 53,
    CAPS_LOCK   = 54,
    CONTEXT_MENU = 55,
    CONTROL_LEFT  = 56,
    CONTROL_RIGHT = 57,
    ENTER       = 58,
    META_LEFT   = 59,
    META_RIGHT  = 60,
    SHIFT_LEFT  = 61,
    SHIFT_RIGHT = 62,
    SPACE       = 63,
    TAB         = 64,
    CONVERT     = 65,
    KANA_MODE   = 66,
    NON_CONVERT = 67,
    -- Control pad
    DELETE    = 68,
    END       = 69,
    HELP      = 70,
    HOME      = 71,
    INSERT    = 72,
    PAGE_DOWN = 73,
    PAGE_UP   = 74,
    -- Arrow pad
    ARROW_DOWN  = 75,
    ARROW_LEFT  = 76,
    ARROW_RIGHT = 77,
    ARROW_UP    = 78,
    -- Function keys
    ESCAPE = 97,  -- after numpad section
    F1=98, F2=99, F3=100, F4=101, F5=102, F6=103,
    F7=104, F8=105, F9=106, F10=107, F11=108, F12=109,
}

-- ── Convenience wrappers ──────────────────────────────────────────────────────

-- Helper: allocate a handle out-pointer, call fn, return handle.
-- fn(allocator, &handle, ...) pattern.
local function alloc_handle(fn, ...)
    local out = ffi.new("void*[1]")
    local res = fn(nil, out, ...)
    if res ~= M.GHOSTTY_SUCCESS then
        return nil, res
    end
    return out[0], nil
end

-- Create a terminal. Returns handle or errors.
function M.new_terminal(cols, rows, max_scrollback)
    local opts = ffi.new("GhosttyTerminalOptions",
        { cols = cols, rows = rows,
          max_scrollback = max_scrollback or 1000 })
    local out = ffi.new("GhosttyTerminal[1]")
    local res = lib.ghostty_terminal_new(nil, out, opts)  -- opts passed as pointer (Windows x64 ABI)
    assert(res == M.GHOSTTY_SUCCESS,
        string.format("[ghostty-ffi] ghostty_terminal_new failed: %d", res))
    assert(ffi.cast("void*", out[0]) ~= nil,
        "[ghostty-ffi] ghostty_terminal_new returned NULL handle")
    return out[0]
end

-- Create a render state. Returns handle or errors.
function M.new_render_state()
    local out = ffi.new("GhosttyRenderState[1]")
    local res = lib.ghostty_render_state_new(nil, out)
    assert(res == M.GHOSTTY_SUCCESS,
        string.format("[ghostty-ffi] ghostty_render_state_new failed: %d", res))
    return out[0]
end

-- Create a row iterator. Returns handle or errors.
function M.new_row_iterator()
    local out = ffi.new("GhosttyRenderStateRowIterator[1]")
    local res = lib.ghostty_render_state_row_iterator_new(nil, out)
    assert(res == M.GHOSTTY_SUCCESS,
        string.format("[ghostty-ffi] ghostty_render_state_row_iterator_new failed: %d", res))
    return out[0]
end

-- Create row cells handle. Returns handle or errors.
function M.new_row_cells()
    local out = ffi.new("GhosttyRenderStateRowCells[1]")
    local res = lib.ghostty_render_state_row_cells_new(nil, out)
    assert(res == M.GHOSTTY_SUCCESS,
        string.format("[ghostty-ffi] ghostty_render_state_row_cells_new failed: %d", res))
    return out[0]
end

-- Create a key encoder. Returns handle or errors.
function M.new_key_encoder()
    local out = ffi.new("GhosttyKeyEncoder[1]")
    local res = lib.ghostty_key_encoder_new(nil, out)
    assert(res == M.GHOSTTY_SUCCESS,
        string.format("[ghostty-ffi] ghostty_key_encoder_new failed: %d", res))
    return out[0]
end

-- Create a key event. Returns handle or errors.
function M.new_key_event()
    local out = ffi.new("GhosttyKeyEvent[1]")
    local res = lib.ghostty_key_event_new(nil, out)
    assert(res == M.GHOSTTY_SUCCESS,
        string.format("[ghostty-ffi] ghostty_key_event_new failed: %d", res))
    return out[0]
end

-- Create a mouse encoder. Returns handle or errors.
function M.new_mouse_encoder()
    local out = ffi.new("GhosttyMouseEncoder[1]")
    local res = lib.ghostty_mouse_encoder_new(nil, out)
    assert(res == M.GHOSTTY_SUCCESS,
        string.format("[ghostty-ffi] ghostty_mouse_encoder_new failed: %d", res))
    return out[0]
end

-- Create a mouse event. Returns handle or errors.
function M.new_mouse_event()
    local out = ffi.new("GhosttyMouseEvent[1]")
    local res = lib.ghostty_mouse_event_new(nil, out)
    assert(res == M.GHOSTTY_SUCCESS,
        string.format("[ghostty-ffi] ghostty_mouse_event_new failed: %d", res))
    return out[0]
end

-- Feed bytes into the VT parser.
function M.terminal_write(term, str)
    if not str or #str == 0 then return end
    local bytes = ffi.cast("const uint8_t*", str)
    lib.ghostty_terminal_vt_write(term, bytes, #str)
end

-- Scroll viewport by delta rows (negative = up into history).
function M.terminal_scroll(term, delta)
    local sv = ffi.new("GhosttyTerminalScrollViewport")
    sv.tag = M.SCROLL_VIEWPORT.DELTA
    sv.value.delta = delta
    lib.ghostty_terminal_scroll_viewport(term, sv)  -- sv passed as pointer
end

-- Get terminal title. Returns string or nil.
function M.terminal_title(term)
    -- TERMINAL_DATA_TITLE returns a GhosttyString
    local gs = ffi.new("GhosttyString[1]")
    local res = lib.ghostty_terminal_get(term, M.TERMINAL_DATA.TITLE, gs)
    if res == M.GHOSTTY_SUCCESS and gs[0].ptr ~= nil and gs[0].len > 0 then
        return ffi.string(gs[0].ptr, gs[0].len)
    end
    return nil
end

-- Check if mouse tracking is active.
function M.terminal_mouse_tracking(term)
    local v = ffi.new("bool[1]")
    local res = lib.ghostty_terminal_get(term, M.TERMINAL_DATA.MOUSE_TRACKING, v)
    return res == M.GHOSTTY_SUCCESS and v[0]
end

-- Get scrollbar info. Returns {total, offset, len} or nil.
function M.terminal_scrollbar(term)
    local sb = ffi.new("GhosttyTerminalScrollbar[1]")
    local res = lib.ghostty_terminal_get(term, M.TERMINAL_DATA.SCROLLBAR, sb)
    if res == M.GHOSTTY_SUCCESS then
        return { total  = tonumber(sb[0].total),
                 offset = tonumber(sb[0].offset),
                 len    = tonumber(sb[0].len) }
    end
    return nil
end

-- Check if a terminal mode is enabled.
function M.terminal_mode(term, mode)
    local v = ffi.new("bool[1]")
    local res = lib.ghostty_terminal_mode_get(term, mode, v)
    return res == M.GHOSTTY_SUCCESS and v[0]
end

-- Get render state colors. Returns GhosttyRenderStateColors or nil.
function M.rs_colors(rs)
    local colors = ffi.new("GhosttyRenderStateColors")
    colors.size = ffi.sizeof("GhosttyRenderStateColors")
    local res = lib.ghostty_render_state_colors_get(rs, colors)
    if res == M.GHOSTTY_SUCCESS then return colors end
    return nil
end

-- Populate a row iterator from render state (must already be created).
-- In C: ghostty_render_state_get(rs, ROW_ITERATOR, &row_iter)
-- The row_iter is a void* handle; we need to pass &row_iter (a void**).
-- We store the handle in a single-element array so we can take its address.
function M.rs_get_row_iterator(rs, row_iter_box)
    -- row_iter_box must be a void*[1] array (so we can pass it as void**)
    return lib.ghostty_render_state_get(rs, M.RS_DATA.ROW_ITERATOR, row_iter_box)
        == M.GHOSTTY_SUCCESS
end

-- Get cells for current row from row iterator.
-- In C: ghostty_render_state_row_get(row_iter, CELLS, &cells)
function M.row_get_cells(row_iter, cells_box)
    -- cells_box must be a void*[1] array
    return lib.ghostty_render_state_row_get(row_iter, M.ROW_DATA.CELLS, cells_box)
        == M.GHOSTTY_SUCCESS
end

-- Get grapheme length for current cell (0 = empty cell).
function M.cell_grapheme_len(cells)
    local v = ffi.new("uint32_t[1]")
    lib.ghostty_render_state_row_cells_get(cells, M.CELL_DATA.GRAPHEMES_LEN, v)
    return tonumber(v[0])
end

-- Get grapheme codepoints for current cell.
-- Returns up to 16 codepoints as a table.
function M.cell_grapheme_buf(cells, len)
    len = math.min(len or 16, 16)
    local buf = ffi.new("uint32_t[16]")
    lib.ghostty_render_state_row_cells_get(cells, M.CELL_DATA.GRAPHEMES_BUF, buf)
    local t = {}
    for i = 0, len-1 do t[i+1] = tonumber(buf[i]) end
    return t
end

-- Get cell style. Returns GhosttyStyle or nil.
function M.cell_style(cells)
    local s = ffi.new("GhosttyStyle")
    s.size = ffi.sizeof("GhosttyStyle")
    lib.ghostty_render_state_row_cells_get(cells, M.CELL_DATA.STYLE, s)
    return s
end

-- Get cell foreground color. Returns r,g,b (0-255) or nil if default.
function M.cell_fg_color(cells, default_rgb)
    local rgb = ffi.new("GhosttyColorRgb")
    if default_rgb then
        rgb.r = default_rgb.r; rgb.g = default_rgb.g; rgb.b = default_rgb.b
    end
    local res = lib.ghostty_render_state_row_cells_get(cells, M.CELL_DATA.FG_COLOR, rgb)
    return rgb, (res == M.GHOSTTY_SUCCESS)
end

-- Get cell background color. Returns GhosttyColorRgb, has_value.
function M.cell_bg_color(cells)
    local rgb = ffi.new("GhosttyColorRgb")
    local res = lib.ghostty_render_state_row_cells_get(cells, M.CELL_DATA.BG_COLOR, rgb)
    return rgb, (res == M.GHOSTTY_SUCCESS)
end

-- Encode a key and return the VT byte string, or nil.
-- key_encoder, key_event: pre-created handles (reused each frame).
function M.encode_key(key_encoder, key_event, gkey, gmods, gaction,
                       unshifted_cp, utf8_text)
    lib.ghostty_key_event_set_key(key_event, gkey)
    lib.ghostty_key_event_set_action(key_event, gaction or M.KEY_ACTION.PRESS)
    lib.ghostty_key_event_set_mods(key_event, gmods or 0)
    lib.ghostty_key_event_set_unshifted_codepoint(key_event, unshifted_cp or 0)
    if utf8_text and #utf8_text > 0 then
        lib.ghostty_key_event_set_utf8(key_event, utf8_text, #utf8_text)
    else
        lib.ghostty_key_event_set_utf8(key_event, nil, 0)
    end

    local buf     = ffi.new("char[128]")
    local written = ffi.new("size_t[1]")
    local res = lib.ghostty_key_encoder_encode(key_encoder, key_event,
                                               buf, 128, written)
    if res == M.GHOSTTY_SUCCESS and written[0] > 0 then
        return ffi.string(buf, written[0])
    end
    return nil
end

-- Map Love2D key names to ghostty key codes (W3C UIEvents code order).
-- This matches ghostling's raylib_key_to_ghostty() logic.
function M.love_key_to_ghostty(k)
    -- Letters
    if #k == 1 then
        local b = string.byte(k)
        if b >= 97 and b <= 122 then   -- a-z
            return M.KEY.A + (b - 97)
        end
        if b >= 65 and b <= 90 then    -- A-Z (shifted)
            return M.KEY.A + (b - 65)
        end
        -- Digits
        if b == 48 then return M.KEY.DIGIT_0 end
        if b >= 49 and b <= 57 then return M.KEY.DIGIT_1 + (b - 49) end
        -- Punctuation
        local punct = {
            ["`"]  = M.KEY.BACKQUOTE,
            ["\\"] = M.KEY.BACKSLASH,
            ["["]  = M.KEY.BRACKET_LEFT,
            ["]"]  = M.KEY.BRACKET_RIGHT,
            [","]  = M.KEY.COMMA,
            ["="]  = M.KEY.EQUAL,
            ["-"]  = M.KEY.MINUS,
            ["."]  = M.KEY.PERIOD,
            ["'"]  = M.KEY.QUOTE,
            [";"]  = M.KEY.SEMICOLON,
            ["/"]  = M.KEY.SLASH,
            [" "]  = M.KEY.SPACE,
        }
        if punct[k] then return punct[k] end
    end
    -- Named keys
    local named = {
        ["return"]    = M.KEY.ENTER,
        ["backspace"] = M.KEY.BACKSPACE,
        ["tab"]       = M.KEY.TAB,
        ["escape"]    = M.KEY.ESCAPE,
        ["space"]     = M.KEY.SPACE,
        ["delete"]    = M.KEY.DELETE,
        ["insert"]    = M.KEY.INSERT,
        ["home"]      = M.KEY.HOME,
        ["end"]       = M.KEY.END,
        ["pageup"]    = M.KEY.PAGE_UP,
        ["pagedown"]  = M.KEY.PAGE_DOWN,
        ["up"]        = M.KEY.ARROW_UP,
        ["down"]      = M.KEY.ARROW_DOWN,
        ["left"]      = M.KEY.ARROW_LEFT,
        ["right"]     = M.KEY.ARROW_RIGHT,
        ["f1"]  = M.KEY.F1,  ["f2"]  = M.KEY.F2,  ["f3"]  = M.KEY.F3,
        ["f4"]  = M.KEY.F4,  ["f5"]  = M.KEY.F5,  ["f6"]  = M.KEY.F6,
        ["f7"]  = M.KEY.F7,  ["f8"]  = M.KEY.F8,  ["f9"]  = M.KEY.F9,
        ["f10"] = M.KEY.F10, ["f11"] = M.KEY.F11, ["f12"] = M.KEY.F12,
    }
    return named[k] or M.KEY.UNIDENTIFIED
end

-- Return the unshifted codepoint for a Love2D key (for Kitty protocol).
function M.love_key_unshifted_cp(k)
    if #k == 1 then
        local b = string.byte(k)
        if b >= 65 and b <= 90 then return b + 32 end  -- A-Z → a-z
        return b
    end
    local named = {
        ["space"] = 32, ["return"] = 13, ["tab"] = 9,
        ["backspace"] = 8, ["escape"] = 27, ["delete"] = 127,
    }
    return named[k] or 0
end

return M
