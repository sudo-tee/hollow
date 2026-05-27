local shared = require("hollow.ui.shared")
local theme_api = require("hollow.theme")
local util = require("hollow.util")

---@type Hollow
local hollow = _G.hollow
---@type HollowUi
local ui = hollow.ui

ui.input = ui.input or {}

---@param theme HollowUiTheme
---@param opts HollowUiInputOptions
---@return HollowUiTheme
local function resolve_input_theme(theme, opts)
  if type(opts.theme) == "table" then
    util.merge_tables(theme, util.clone_value(opts.theme))
  end
  return theme
end

---@param prompt string
---@param value string
---@param cursor integer
---@param theme HollowUiTheme
---@return HollowUiRows
local function render_input_rows(prompt, value, cursor, theme)
  ---@type HollowUiTags
  local tags = ui.tags
  local rows = {}

  if prompt ~= "" then
    rows = ui.rows(
      tags.overlay_row(nil, tags.text({ fg = theme.title, bold = true }, prompt)),
      tags.divider({ color = theme.divider })
    )
  end

  local before = value:sub(1, cursor)
  local after = value:sub(cursor + 1)
  local cursor_char = after:sub(1, 1)
  if cursor_char == "" then
    cursor_char = " "
  else
    after = after:sub(2)
  end

  local input_rows = ui.rows(
    tags.overlay_row(
      nil,
      tags.text({ fg = theme.input_fg, bg = theme.input_bg }, before),
      tags.text({ fg = theme.cursor_fg, bg = theme.cursor_bg, bold = true }, cursor_char),
      tags.text({ fg = theme.input_fg, bg = theme.input_bg }, after)
    )
  )

  for _, row in ipairs(input_rows) do
    rows[#rows + 1] = row
  end

  return rows
end

---@param value string
---@param cursor integer
---@return string
---@return integer
local function backspace(value, cursor)
  if cursor <= 0 then
    return value, 0
  end

  return value:sub(1, cursor - 1) .. value:sub(cursor + 1), cursor - 1
end

---@param value string
---@param cursor integer
---@param text string
---@return string
---@return integer
local function insert_text(value, cursor, text)
  return value:sub(1, cursor) .. text .. value:sub(cursor + 1), cursor + #text
end

---@param opts HollowUiInputOptions|nil
function ui.input.open(opts)
  opts = opts or {}

  local theme = resolve_input_theme(theme_api.resolve_widget("input"), opts)
  local backdrop = opts.backdrop ~= nil and opts.backdrop or theme.backdrop
  local local_state = {
    prompt = opts.prompt or "",
    value = opts.default or "",
    cursor = #(opts.default or ""),
  }

  local widget = ui.overlay.new({
    render = function()
      return render_input_rows(local_state.prompt, local_state.value, local_state.cursor, theme)
    end,
    width = opts.width,
    height = opts.height,
    chrome = opts.chrome or shared.theme_overlay_chrome(theme),
    align = opts.align or "center",
    backdrop = backdrop,
    on_key = function(key, mods)
      if key == "escape" then
        ui.overlay.pop()
        if type(opts.on_cancel) == "function" then
          opts.on_cancel()
        end
        return true
      end

      if key == "enter" then
        ui.overlay.pop()
        if type(opts.on_confirm) == "function" then
          opts.on_confirm(local_state.value)
        end
        return true
      end

      if key == "backspace" then
        local_state.value, local_state.cursor = backspace(local_state.value, local_state.cursor)
        return true
      end

      if key == "arrow_left" then
        local_state.cursor = math.max(0, local_state.cursor - 1)
        return true
      end

      if key == "arrow_right" then
        local_state.cursor = math.min(#local_state.value, local_state.cursor + 1)
        return true
      end

      local printable = shared.printable_char_for_key(key, mods)
      if printable ~= nil then
        local_state.value, local_state.cursor = insert_text(local_state.value, local_state.cursor, printable)
        return true
      end

      return false
    end,
  })

  ui.overlay.push(widget)
end

function ui.input.close()
  ui.overlay.pop()
end
