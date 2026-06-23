--- Dialog component.
---
--- Layout helper: title row, divider, body rows, footer row with buttons.
--- Footer items are wrapped with w.button() if they are raw button specs.
--- Supports selected/hovered styling on footer buttons.

local shared = require("hollow.ui.shared")
local ui = _G.hollow.ui
local tags = ui.tags
local table_unpack = table.unpack or unpack
local button_component = require("hollow.ui.builder.components.button")
local click_registry = require("hollow.ui.builder.internal.click_registry")

local M = {}

---@param items (HollowUiBuilderButton|{ text: string, kind?: "default"|"primary"|"destructive", id?: string, on_click?: fun(e: { id: string }) })[]
---@return HollowUiBuilderButton[]
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
    rows[#rows + 1] = tags.overlay_row(nil, tags.text(default_style or {}, tostring(item)))
    return
  end

  if item._overlay_row then
    rows[#rows + 1] = item
    return
  end

  if shared.is_span_node(item) or shared.is_text_shorthand(item) then
    local node = default_style and ui.group(ui.row(item), default_style) or item
    rows[#rows + 1] = tags.overlay_row(nil, node)
    return
  end

  local children = {}
  for _, v in ipairs(item) do
    children[#children + 1] = v
  end
  if #children > 0 then
    local node = default_style and ui.group(ui.row(table_unpack(children)), default_style)
      or ui.row(table_unpack(children))
    rows[#rows + 1] = tags.overlay_row(nil, node)
  else
    rows[#rows + 1] = tags.overlay_row(nil, ui.group(item))
  end
end

---@param opts { title?: string, body?: table[], footer?: (HollowUiBuilderButton|{ text: string, kind?: "default"|"primary"|"destructive", id?: string, on_click?: fun(e: { id: string }) })[], selected?: integer, hovered?: integer }
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
    rows = ui.rows(
      tags.overlay_row(nil, tags.group(tags.text({ fg = theme.title, bold = true }, title))),
      tags.divider({ color = theme.divider })
    )
  end

  for _, item in ipairs(body) do
    append_body_item(rows, item, theme)
  end

  if #footer > 0 then
    rows[#rows + 1] = tags.overlay_row(nil, tags.text({}, " "))

    local button_nodes = {}
    button_nodes[#button_nodes + 1] = ui.spacer()

    for i, btn in ipairs(footer) do
      if #button_nodes > 1 then
        button_nodes[#button_nodes + 1] = tags.text({}, "  ")
      end
      local is_selected = selected and i == selected
      local is_hovered = hovered and i == hovered
      local style = button_component.button_style(theme, btn, is_selected, is_hovered)
      style.id = btn.id or ("dialog:btn:" .. i)
      style.on_click = btn.on_click

      click_registry.register(style.id, btn.on_click)

      button_nodes[#button_nodes + 1] = tags.text(style, " " .. btn.text .. " ")
    end

    rows[#rows + 1] = tags.overlay_row(nil, table_unpack(button_nodes))
  end

  return rows
end

return M
