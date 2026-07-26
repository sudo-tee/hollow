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

--- Append a body item (single node or array of nodes) to rows.
---@param rows table
---@param item any
---@param theme table
local function append_body_item(rows, item, theme)
  local default_style = theme and { fg = theme.fg } or nil

  if type(item) ~= "table" then
    rows[#rows + 1] = ui.row({ ui.text(tostring(item), default_style) })
    return
  end

  if item._type == "row" then
    rows[#rows + 1] = item
    return
  end

  if item._type == "column" then
    for _, row in ipairs(item.children) do
      rows[#rows + 1] = row
    end
    return
  end

  if shared.is_span_node(item) or shared.is_text_shorthand(item) then
    local node = default_style and ui.group({ item }, default_style) or item
    rows[#rows + 1] = ui.row({ node })
    return
  end

  local node = default_style and ui.group(item, default_style) or ui.group(item)
  rows[#rows + 1] = ui.row({ node })
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

  local rows = {}

  if title and title ~= "" then
    rows = {
      ui.row({ ui.text(title, { fg = theme.title, bold = true }) }),
      ui.divider(theme.divider),
    }
  end

  for _, item in ipairs(body) do
    append_body_item(rows, item, theme)
  end

  if #footer > 0 then
    rows[#rows + 1] = ui.row({ ui.text(" ") })

    local button_nodes = {}
    button_nodes[#button_nodes + 1] = ui.spacer()

    for i, btn in ipairs(footer) do
      if #button_nodes > 1 then
        button_nodes[#button_nodes + 1] = ui.text("  ")
      end
      local is_selected = selected and i == selected
      local is_hovered = hovered and i == hovered
      local style = button_component.button_style(theme, btn, is_selected, is_hovered)
      style.id = btn.id or ("dialog:btn:" .. i)
      style.on_click = btn.on_click

      click_registry.register(style.id, btn.on_click)

      button_nodes[#button_nodes + 1] = ui.text(" " .. btn.text .. " ", style)
    end

    rows[#rows + 1] = ui.row(button_nodes)
  end

  return ui.column(rows)
end

return M
