-- src/core/pane.lua
-- A single terminal pane: one GhosttyTerminal + one PTY child process.
--
-- Follows the ghostling reference implementation pattern:
--   https://github.com/ghostty-org/ghostling/blob/main/main.c
--
-- Object lifecycle:
--   1. Create terminal (ghostty_terminal_new with correct Zig ABI)
--   2. Spawn PTY
--   3. Register effect callbacks on terminal (write_pty, size, device_attrs...)
--   4. Create reusable render handles (render_state, row_iter, row_cells)
--   5. Create key/mouse encoders and reusable event handles
--   Per frame: read PTY → vt_write → render_state_update → draw

local ffi    = require("ffi")
local bit    = require("bit")
local gffi   = require("src.core.ghostty_ffi")
local Pty    = require("src.core.pty")
local Config = require("src.core.config")
local KeyMap = require("src.core.keymap")

local lib = gffi.lib

local Pane = {}
Pane.__index = Pane

local next_id = 1

-- LuaJIT null-pointer check: cdata NULL != Lua nil, must cast.
local function is_null(p)
    return p == nil or ffi.cast("void*", p) == nil
end

-- ── Effect callbacks (called by the terminal for VT queries / title changes) ─

-- We keep callback references alive in a module-level table so the GC
-- doesn't collect them while the terminal holds a function pointer.
local _callbacks = {}

-- Helper: create a C callback and keep it alive.
local function make_cb(ct, fn)
    local cb = ffi.cast(ct, fn)
    _callbacks[#_callbacks + 1] = cb
    return cb
end

-- write_pty effect: terminal asks us to write bytes back to the pty.
-- Signature: void(GhosttyTerminal, void* userdata, const uint8_t* data, size_t len)
-- NOTE: We cannot easily use the userdata pointer back into Lua safely via FFI
-- callback. Instead we use a Lua closure over the pane table reference.
-- The terminal's userdata is set but the actual writing goes through the closure.
local WRITE_PTY_CB_TYPE =
    "void(*)(void*, void*, const uint8_t*, size_t)"

local SIZE_CB_TYPE =
    "bool(*)(void*, void*, void*)"   -- (terminal, userdata, GhosttySizeReportSize*)

local DA_CB_TYPE =
    "bool(*)(void*, void*, void*)"   -- (terminal, userdata, GhosttyDeviceAttributes*)

local XTVERSION_CB_TYPE =
    "void*(*)(void*, void*)"         -- returns GhosttyString by value... tricky

local TITLE_CB_TYPE =
    "void(*)(void*, void*)"          -- (terminal, userdata)

local COLOR_SCHEME_CB_TYPE =
    "bool(*)(void*, void*, void*)"   -- (terminal, userdata, GhosttyColorScheme*)

-- ── Pane constructor ──────────────────────────────────────────────────────────

function Pane.new(cols, rows, opts)
    opts = opts or {}
    local self = setmetatable({}, Pane)

    self.id      = next_id; next_id = next_id + 1
    self.cols    = math.max(cols, 2)
    self.rows    = math.max(rows, 2)
    self.focused = false
    self.title   = opts.title or "terminal"
    self.bell    = false
    self.px_rect = opts.px_rect or {x=0, y=0, w=cols*8, h=rows*16}
    self.cell_w  = opts.cell_w or 8
    self.cell_h  = opts.cell_h or 16
    self._child_exited = false

    -- ── 1. Create the ghostty terminal ────────────────────────────────────────
    self.term = gffi.new_terminal(self.cols, self.rows)

    -- ── 2. Spawn PTY ──────────────────────────────────────────────────────────
    local shell = opts.shell or Config.get("shell") or "/bin/sh"
    self.pty = Pty.spawn(shell, self.cols, self.rows, opts)

    -- ── 3. Register effect callbacks ──────────────────────────────────────────
    -- We use closures so each pane instance has its own callback state.

    -- write_pty: write VT response bytes back to the shell
    local pane_ref = self   -- capture for closures
    local write_pty_cb = make_cb(WRITE_PTY_CB_TYPE,
        function(terminal, userdata, data, len)
            if not pane_ref._child_exited and pane_ref.pty then
                local n = tonumber(len)
                if n > 0 then
                    pane_ref.pty:write_str(ffi.string(data, n))
                end
            end
        end)

    -- size: respond to XTWINOPS size queries
    local size_cb = make_cb(SIZE_CB_TYPE,
        function(terminal, userdata, out_size_ptr)
            -- GhosttySizeReportSize: rows(u16), cols(u16), cw(u32), ch(u32)
            local out = ffi.cast("uint16_t*", out_size_ptr)
            out[0] = pane_ref.rows
            out[1] = pane_ref.cols
            -- cell dimensions as uint32 at offset 4
            local out32 = ffi.cast("uint32_t*", ffi.cast("char*", out_size_ptr) + 4)
            out32[0] = pane_ref.cell_w or 8
            out32[1] = pane_ref.cell_h or 16
            return true
        end)

    -- device_attributes: respond to DA1/DA2/DA3 capability queries
    -- We emit a minimal VT220-like response.
    -- The callback populates a GhosttyDeviceAttributes struct.
    local da_cb = make_cb(DA_CB_TYPE,
        function(terminal, userdata, out_da_ptr)
            -- Primary: VT220 conformance (1), 3 features: 132col, sel-erase, ansi-color
            local b = ffi.cast("uint8_t*", out_da_ptr)
            b[0] = 1   -- conformance_level = VT220
            b[1] = 1   -- features[0] = COLUMNS_132
            b[2] = 2   -- features[1] = SELECTIVE_ERASE
            b[3] = 22  -- features[2] = ANSI_COLOR
            b[9] = 3   -- num_features
            -- Secondary: device_type=VT220(1), firmware=1, rom=0
            b[10] = 1  -- device_type
            -- firmware_version at offset 11 (uint32)
            local fw = ffi.cast("uint32_t*", ffi.cast("char*", out_da_ptr) + 11)
            fw[0] = 1
            return true
        end)

    -- title_changed: update our local title string
    local title_cb = make_cb(TITLE_CB_TYPE,
        function(terminal, userdata)
            local t = gffi.terminal_title(terminal)
            if t and t ~= "" then pane_ref.title = t end
        end)

    -- color_scheme: we can't query OS color scheme, return false
    local cs_cb = make_cb(COLOR_SCHEME_CB_TYPE,
        function(terminal, userdata, out_scheme_ptr)
            return false
        end)

    -- Register all callbacks on the terminal
    lib.ghostty_terminal_set(self.term, gffi.TERMINAL_OPT.WRITE_PTY,
        ffi.cast("void*", write_pty_cb))
    lib.ghostty_terminal_set(self.term, gffi.TERMINAL_OPT.SIZE,
        ffi.cast("void*", size_cb))
    lib.ghostty_terminal_set(self.term, gffi.TERMINAL_OPT.DEVICE_ATTRIBUTES,
        ffi.cast("void*", da_cb))
    lib.ghostty_terminal_set(self.term, gffi.TERMINAL_OPT.TITLE_CHANGED,
        ffi.cast("void*", title_cb))
    lib.ghostty_terminal_set(self.term, gffi.TERMINAL_OPT.COLOR_SCHEME,
        ffi.cast("void*", cs_cb))

    -- Keep references alive on the pane so GC doesn't collect them
    self._cbs = { write_pty_cb, size_cb, da_cb, title_cb, cs_cb }

    -- ── 4. Create reusable render handles ─────────────────────────────────────
    self.render_state  = gffi.new_render_state()
    -- row_iter and row_cells are stored as void*[1] boxes so we can pass
    -- their address (void**) to ghostty_render_state_get / row_get.
    self.row_iter_box  = ffi.new("void*[1]", { gffi.new_row_iterator() })
    self.row_cells_box = ffi.new("void*[1]", { gffi.new_row_cells() })

    -- ── 5. Create key/mouse encoders and reusable event handles ───────────────
    self.key_encoder   = gffi.new_key_encoder()
    self.key_event     = gffi.new_key_event()
    self.mouse_encoder = gffi.new_mouse_encoder()
    self.mouse_event   = gffi.new_mouse_event()

    -- Sync encoders to initial terminal mode state
    lib.ghostty_key_encoder_setopt_from_terminal(self.key_encoder, self.term)
    lib.ghostty_mouse_encoder_setopt_from_terminal(self.mouse_encoder, self.term)

    print(string.format("[pane %d] ready  shell=%s  cols=%d rows=%d",
        self.id, shell, self.cols, self.rows))
    return self
end

-- ── Per-frame update ──────────────────────────────────────────────────────────

-- Call every frame. Drains PTY output, feeds it into the VT parser,
-- then updates the render state snapshot.
function Pane:update()
    if self._child_exited then return end

    local data = self.pty:read()
    if data and #data > 0 then
        gffi.terminal_write(self.term, data)
        -- Re-sync encoder options in case modes changed
        lib.ghostty_key_encoder_setopt_from_terminal(self.key_encoder, self.term)
        lib.ghostty_mouse_encoder_setopt_from_terminal(self.mouse_encoder, self.term)
    end

    -- Snapshot terminal state into render state for this frame
    lib.ghostty_render_state_update(self.render_state, self.term)
end

-- ── Input ─────────────────────────────────────────────────────────────────────

-- Send a key event. love_key is a Love2D key name string.
-- mods: { ctrl, shift, alt, super } booleans. action: press/repeat/release.
function Pane:send_key(love_key, mods, action)
    if self._child_exited then return end

    local fallback = KeyMap.encode(love_key, mods or {})
    if fallback and (love_key == "escape" or (mods and mods.ctrl and love_key == "[")) then
        self.pty:write_str(fallback)
        return true
    end

    local gkey   = gffi.love_key_to_ghostty(love_key)
    if gkey == gffi.KEY.UNIDENTIFIED then return end

    local gmods = 0
    if mods then
        if mods.ctrl  then gmods = bit.bor(gmods, gffi.MODS.CTRL)  end
        if mods.shift then gmods = bit.bor(gmods, gffi.MODS.SHIFT) end
        if mods.alt   then gmods = bit.bor(gmods, gffi.MODS.ALT)   end
        if mods.super then gmods = bit.bor(gmods, gffi.MODS.SUPER) end
    end

    local gaction = action or gffi.KEY_ACTION.PRESS
    local ucp     = gffi.love_key_unshifted_cp(love_key)

    -- For printable single chars, pass as utf8 text so encoder can attach it
    local utf8_text = nil
    if #love_key == 1 and string.byte(love_key) >= 32 then
        utf8_text = love_key
    end

    -- Consumed mods: shift is consumed for printable keys
    local consumed = 0
    if ucp > 0 and bit.band(gmods, gffi.MODS.SHIFT) ~= 0 then
        consumed = gffi.MODS.SHIFT
    end
    lib.ghostty_key_event_set_consumed_mods(self.key_event, consumed)

    local encoded = gffi.encode_key(self.key_encoder, self.key_event,
                                     gkey, gmods, gaction, ucp, utf8_text)
    if encoded and #encoded > 0 then
        self.pty:write_str(encoded)
        return true   -- caller can suppress textinput double-send
    end
    return false
end

-- Send raw text from normal typing / IME composition.
function Pane:send_text(text)
    if self._child_exited then return end
    self.pty:write_str(text)
end

-- Send pasted text, using bracketed paste only when the app requested it.
function Pane:send_paste(text)
    if self._child_exited then return end
    if gffi.terminal_mode(self.term, gffi.MODE.BRACKETED_PASTE) then
        self.pty:write_str("\27[200~" .. text .. "\27[201~")
        return
    end
    self.pty:write_str(text)
end

-- ── Resize ────────────────────────────────────────────────────────────────────

function Pane:resize(cols, rows, cell_w, cell_h)
    cols   = math.max(cols, 2)
    rows   = math.max(rows, 2)
    cell_w = cell_w or self.cell_w or 8
    cell_h = cell_h or self.cell_h or 16
    self.cols   = cols
    self.rows   = rows
    self.cell_w = cell_w
    self.cell_h = cell_h
    lib.ghostty_terminal_resize(self.term, cols, rows, cell_w, cell_h)
    self.pty:resize(cols, rows)
end

-- ── Scroll ────────────────────────────────────────────────────────────────────

function Pane:scroll(delta)
    gffi.terminal_scroll(self.term, delta)
end

-- ── Mouse ─────────────────────────────────────────────────────────────────────

function Pane:send_mouse(px_x, px_y, button, action, mods)
    if self._child_exited then return end

    lib.ghostty_mouse_event_set_action(self.mouse_event, action or gffi.MOUSE_ACTION.PRESS)
    lib.ghostty_mouse_event_set_button(self.mouse_event, button or gffi.MOUSE_BUTTON.LEFT)
    local pos = ffi.new("GhosttyMousePosition", { x = px_x, y = px_y })
    lib.ghostty_mouse_event_set_position(self.mouse_event, pos)  -- pos passed as pointer

    local gmods = 0
    if mods then
        if mods.ctrl  then gmods = bit.bor(gmods, gffi.MODS.CTRL)  end
        if mods.shift then gmods = bit.bor(gmods, gffi.MODS.SHIFT) end
        if mods.alt   then gmods = bit.bor(gmods, gffi.MODS.ALT)   end
    end
    lib.ghostty_mouse_event_set_mods(self.mouse_event, gmods)

    local buf     = ffi.new("char[128]")
    local written = ffi.new("size_t[1]")
    local res = lib.ghostty_mouse_encoder_encode(
        self.mouse_encoder, self.mouse_event, buf, 128, written)
    if res == gffi.GHOSTTY_SUCCESS and written[0] > 0 then
        self.pty:write_str(ffi.string(buf, written[0]))
    end
end

-- ── Focus ─────────────────────────────────────────────────────────────────────

function Pane:send_focus(gained)
    if self._child_exited then return end
    -- Only send if the terminal has focus reporting enabled (DECSET 1004)
    if not gffi.terminal_mode(self.term, gffi.MODE.FOCUS_EVENT) then return end

    local ev = gained and gffi.FOCUS.GAINED or gffi.FOCUS.LOST
    local buf     = ffi.new("char[8]")
    local written = ffi.new("size_t[1]")
    local res = lib.ghostty_focus_encode(ev, buf, 8, written)
    if res == gffi.GHOSTTY_SUCCESS and written[0] > 0 then
        self.pty:write_str(ffi.string(buf, written[0]))
    end
end

-- ── Accessors ─────────────────────────────────────────────────────────────────

function Pane:get_title()      return self.title end
function Pane:is_alive()       return not self._child_exited end
function Pane:get_scrollbar()  return gffi.terminal_scrollbar(self.term) end

-- ── Destroy ───────────────────────────────────────────────────────────────────

function Pane:destroy()
    if self.pty then self.pty:close() end
    if self.mouse_event    then lib.ghostty_mouse_event_free(self.mouse_event) end
    if self.mouse_encoder  then lib.ghostty_mouse_encoder_free(self.mouse_encoder) end
    if self.key_event      then lib.ghostty_key_event_free(self.key_event) end
    if self.key_encoder    then lib.ghostty_key_encoder_free(self.key_encoder) end
    if self.row_cells_box then lib.ghostty_render_state_row_cells_free(self.row_cells_box[0]) end
    if self.row_iter_box  then lib.ghostty_render_state_row_iterator_free(self.row_iter_box[0]) end
    if self.render_state   then lib.ghostty_render_state_free(self.render_state) end
    if self.term           then lib.ghostty_terminal_free(self.term) end
    self.term          = nil
    self.render_state  = nil
    self.row_iter_box  = nil
    self.row_cells_box = nil
    -- Release callback references
    self._cbs = nil
end

return Pane
