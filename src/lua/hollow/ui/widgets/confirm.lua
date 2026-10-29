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
local shared = require("hollow.ui.shared")
local util = require("hollow.util")
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

  local base_theme = shared.widget_theme("confirm", opts.theme)

  local raw_buttons = type(opts.buttons) == "table" and #opts.buttons > 0 and opts.buttons
    or default_buttons()

  local m

  local function confirm_and_close(btn)
    ui.fire(opts.on_confirm, btn.value)
    ui.fire(btn.on_confirm, btn.value)
    m.close()
  end

  local footer_buttons = {}
  for index, btn in ipairs(raw_buttons) do
    footer_buttons[index] = {
      id = btn.id or ("confirm:button:" .. index),
      text = btn.text,
      kind = btn.kind or btn.style,
      on_click = function()
        confirm_and_close(btn)
      end,
    }
  end

  local nav = ui.list_nav(#footer_buttons)

  local backdrop = opts.backdrop
  if backdrop == nil then
    backdrop = true
  end

  m = ui.modal({
    title = opts.title,
    theme = base_theme,
    layout_render = opts.layout == "clay" and function(theme, state, ctx)
      return require("hollow.ui.builder.components.layout_dialog")({
        title = opts.title,
        prompt = opts.prompt,
        footer = footer_buttons,
        selected = nav.index,
        hovered = state and find_hovered_index(state.hovered_id, footer_buttons),
      }, theme, ctx)
    end or nil,
    render = function(theme, state)
      local hovered = state and find_hovered_index(state.hovered_id, footer_buttons)
      return ui.dialog({
        title = opts.title,
        body = { ui.text(opts.prompt) },
        footer = footer_buttons,
        selected = nav.index,
        hovered = hovered,
      }, theme)
    end,
    width = opts.width or 50,
    height = opts.height,
    chrome = opts.chrome,
    align = opts.align or "center",
    backdrop = backdrop,
    keys = ui.keys(nav, {
      enter = function()
        local btn = raw_buttons[nav.index]
        confirm_and_close(btn)
      end,
      escape = function()
        m.close()
        ui.fire(opts.on_cancel)
      end,
    }),
  })
end

--- Dismiss the current confirm dialog (pops the overlay).
function ui.confirm.close()
  ui.overlay.pop()
end
