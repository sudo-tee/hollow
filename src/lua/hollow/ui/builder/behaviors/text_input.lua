--- Text input behavior.
---
--- State + key handlers + render helper for a single-line text input.
--- Cursor is a 0-based byte offset.

local ui = _G.hollow.ui

local M = {}

local function backspace(value, cursor)
  if cursor <= 0 then
    return value, 0
  end
  return value:sub(1, cursor - 1) .. value:sub(cursor + 1), cursor - 1
end

local function insert_text(value, cursor, text)
  return value:sub(1, cursor) .. text .. value:sub(cursor + 1), cursor + #text
end

---@param opts { initial?: string, on_change?: function }
---@return table
function M.text_input(opts)
  opts = opts or {}

  local self = {
    value = opts.initial or "",
    cursor = #(opts.initial or ""),
    on_change = opts.on_change,
  }

  function self.set(value, cursor)
    self.value = value or ""
    self.cursor = cursor or #self.value
  end

  function self.render(theme)
    local before = self.value:sub(1, self.cursor)
    local after = self.value:sub(self.cursor + 1)
    local cursor_char = after:sub(1, 1)
    if cursor_char == "" then
      cursor_char = " "
    else
      after = after:sub(2)
    end

    return {
      ui.text(before, { fg = theme.input_fg, bg = theme.input_bg }),
      ui.text(cursor_char, { fg = theme.cursor_fg, bg = theme.cursor_bg, bold = true }),
      ui.text(after, { fg = theme.input_fg, bg = theme.input_bg }),
    }
  end

  self.handlers = {
    arrow_left = function()
      self.cursor = math.max(0, self.cursor - 1)
    end,
    arrow_right = function()
      self.cursor = math.min(#self.value, self.cursor + 1)
    end,
    backspace = function()
      self.value, self.cursor = backspace(self.value, self.cursor)
      if self.on_change then
        self.on_change(self.value)
      end
    end,
    _else = function(key, mods)
      local shared = require("hollow.ui.shared")
      local printable = shared.printable_char_for_key(key, mods)
      if printable then
        self.value, self.cursor = insert_text(self.value, self.cursor, printable)
        if self.on_change then
          self.on_change(self.value)
        end
        return true
      end
      return false
    end,
  }

  return self
end

return M
