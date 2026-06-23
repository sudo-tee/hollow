--- Modal confirmation dialog built on the builder API.
---
--- Usage:
--- ```lua
--- hollow.ui.confirm.open({
---   prompt = "Are you sure?",
---   title = "Delete file",
---   on_confirm = function(value)
---     if value == true then delete_file() end
---   end,
---   on_cancel = function() end,
--- })
--- ```
local theme_api = require("hollow.theme")
local util = require("hollow.util")
local w = require("hollow.ui.builder")

local ui = _G.hollow.ui

ui.confirm = ui.confirm or {}

---@return { text: string, style?: string, value: any, on_confirm?: function }[]
local function default_buttons()
  return {
    { text = "Yes", style = "primary", value = true },
    { text = "No", value = false },
  }
end

local function find_hovered_index(hovered_id, buttons)
  if not hovered_id then
    return nil
  end
  for i, btn in ipairs(buttons) do
    if btn.id == hovered_id then
      return i
    end
  end
  return nil
end

--- Open a modal confirm dialog.
---@param opts HollowUiConfirmOptions
function ui.confirm.open(opts)
  opts = opts or {}

  if opts.prompt == nil or opts.prompt == "" then
    error("hollow.ui.confirm.open() requires a 'prompt' string")
  end

  local base_theme = theme_api.resolve_widget("confirm")
  if type(opts.theme) == "table" then
    util.merge_tables(base_theme, util.clone_value(opts.theme))
  end

  local raw_buttons = type(opts.buttons) == "table" and #opts.buttons > 0 and opts.buttons
    or default_buttons()

  local m

  local function confirm_and_close(btn)
    w.fire(opts.on_confirm, btn.value)
    w.fire(btn.on_confirm, btn.value)
    m.close()
  end

  local footer_buttons = w.buttons(raw_buttons, function(btn)
    return { on_click = function() confirm_and_close(btn) end }
  end)

  local nav = w.list_nav(#footer_buttons)

  m = w.modal({
    theme = base_theme,
    render = function(theme, state)
      local hovered = state and find_hovered_index(state.hovered_id, footer_buttons)
      return w.dialog({
        title = opts.title,
        body = { w.text(opts.prompt) },
        footer = footer_buttons,
        selected = nav.index,
        hovered = hovered,
      }, theme)
    end,
    width = opts.width or 50,
    height = opts.height,
    chrome = opts.chrome,
    align = opts.align or "center",
    backdrop = opts.backdrop ~= nil and opts.backdrop or true,
    keys = w.keys(nav, {
      enter = function()
        local btn = raw_buttons[nav.index]
        confirm_and_close(btn)
      end,
      escape = function()
        m.close()
        w.fire(opts.on_cancel)
      end,
    }),
  })
end

--- Dismiss the current confirm dialog (pops the overlay).
function ui.confirm.close()
  ui.overlay.pop()
end
