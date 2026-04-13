local shared = require("hollow.ui.shared")
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
---@param theme HollowUiTheme
---@return HollowUiRows
local function render_input_rows(prompt, value, theme)
  ---@type HollowUiTags
  local tags = ui.tags
  local rows = {}

  if prompt ~= "" then
    rows = ui.rows(
      tags.overlay_row(nil, tags.text({ fg = theme.title, bold = true }, prompt)),
      tags.divider({ color = theme.divider })
    )
  end

  local input_rows = ui.rows(
    tags.overlay_row(nil,
      tags.text({ fg = theme.input_fg, bg = theme.input_bg }, value),
      tags.text({ fg = theme.cursor_fg, bg = theme.cursor_bg, bold = true }, " ")
    )
  )

  for _, row in ipairs(input_rows) do
    rows[#rows + 1] = row
  end

  return rows
end

---@param value string
---@return string
local function backspace(value)
  return value:sub(1, math.max(0, #value - 1))
end

---@param opts HollowUiInputOptions|nil
function ui.input.open(opts)
  opts = opts or {}

  local theme = resolve_input_theme(shared.resolve_widget_theme("input"), opts)
  local backdrop = opts.backdrop ~= nil and opts.backdrop or theme.backdrop
  local local_state = {
    prompt = opts.prompt or "",
    value = opts.default or "",
  }

  local widget = ui.overlay.new({
    render = function()
      return render_input_rows(local_state.prompt, local_state.value, theme)
    end,
    width = opts.width,
    height = opts.height,
    chrome = opts.chrome or { bg = theme.panel_bg, border = theme.panel_border },
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
        local_state.value = backspace(local_state.value)
        return true
      end

      local printable = shared.printable_char_for_key(key, mods)
      if printable ~= nil then
        local_state.value = local_state.value .. printable
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
