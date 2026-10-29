--- Dialog component.
---
--- Layout helper: title row, divider, body rows, footer row with buttons.
--- Raw footer specs are normalized into themed dialog buttons.
--- Supports selected/hovered styling on footer buttons.

local shared = require("hollow.ui.shared")
local ui = _G.hollow.ui
local button_component = require("hollow.ui.builder.components.button")
local click_registry = require("hollow.ui.builder.internal.click_registry")

local M = {}

local function title_style(theme)
  -- Dialog themes may be partial; absent optional paint retains native defaults.
  return { fg = theme.title, bold = true }
end

---@param items (HollowUiDialogButton|{ text: string, kind?: "default"|"primary"|"destructive", id?: string, on_click?: fun(e: { id: string }) })[]
---@return HollowUiDialogButton[]
local function normalize_footer_items(items)
  local result = {}
  for _, item in ipairs(items or {}) do
    if item._button then
      result[#result + 1] = item
    elseif type(item) == "table" and item.text then
      result[#result + 1] = button_component.button(item)
    else
      result[#result + 1] = item
    end
  end
  return result
end

local function contains_rows(item)
  if type(item) ~= "table" then
    return false
  end
  if item._type == "row" or item._type == "column" then
    return true
  end
  if item._type ~= nil or shared.is_text_shorthand(item) then
    return false
  end
  for i = 1, table.maxn(item) do
    if contains_rows(item[i]) then
      return true
    end
  end
  return false
end

--- Convert loose body items into rows or recursive row fragments.
local function body_item(item, theme)
  if item == nil or type(item) == "boolean" then
    return false
  end
  local default_style = theme and { fg = theme.fg } or nil

  if type(item) ~= "table" then
    return ui.row({ ui.text(tostring(item), default_style) })
  end

  if item._type == "row" or item._type == "column" then
    return item
  end

  if shared.is_span_node(item) or shared.is_text_shorthand(item) then
    local node = default_style and ui.group({ item }, default_style) or item
    return ui.row({ node })
  end

  if contains_rows(item) then
    local fragment = {}
    for i = 1, table.maxn(item) do
      fragment[i] = body_item(item[i], theme)
    end
    return fragment
  end

  local node = default_style and ui.group(item, default_style) or ui.group(item)
  return ui.row({ node })
end

---@param opts { title?: string, body?: table[], footer?: (HollowUiDialogButton|{ text: string, kind?: "default"|"primary"|"destructive", id?: string, on_click?: fun(e: { id: string }) })[], selected?: integer, hovered?: integer }
---@param theme table
---@return table
function M.dialog(opts, theme)
  local title = opts.title
  local body = opts.body or {}
  local footer = normalize_footer_items(opts.footer or {})
  local selected = opts.selected
  local hovered = opts.hovered

  local body_rows = {}
  for i = 1, table.maxn(body) do
    body_rows[i] = body_item(body[i], theme)
  end

  return ui.column({
    ui.when(title and title ~= "", function()
      return {
        ui.row({ ui.text(title, title_style(theme)) }),
        ui.divider(theme.divider),
      }
    end),
    body_rows,
    ui.when(#footer > 0, function()
      local buttons = ui.join(
        ui.each(footer, function(btn, i)
          local is_selected = selected and i == selected
          local is_hovered = hovered and i == hovered
          local style = button_component.button_style(theme, btn, is_selected, is_hovered)
          style.id = btn.id or ("dialog:btn:" .. i)
          style.on_click = btn.on_click

          click_registry.register(style.id, btn.on_click)
          return ui.text(" " .. btn.text .. " ", style)
        end),
        "  "
      )
      return { ui.row({ ui.text(" ") }), ui.row({ ui.spacer(), buttons }) }
    end),
  })
end

return M
