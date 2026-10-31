-- Bounded list composition. Clay owns pixel layout/scrolling; the select widget
-- keeps its existing filtering, navigation and action state.
local box = require("hollow.ui.style.box")
local list_row = require("hollow.ui.recipes.list_row")
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")
local styles = require("hollow.ui.recipes.select")
---@type HollowUiComponents
local c = require("hollow.ui.components")
local inline = require("hollow.ui.components.rich")
local input_field = require("hollow.ui.components.input")
local row_adapter = require("hollow.ui.components.row_adapter")

---@class HollowUiLayoutInlineOptions: HollowUiLayoutOptions
---@field prefix? string

---@class HollowUiLayoutSelectViewport
---@field start_idx integer
---@field end_idx integer
---@field show_scrollbar boolean
---@field scrollbar_id string
---@field thumb_ratio number
---@field thumb_size number

---@class HollowUiLayoutSelectOptions
---@field entries HollowUiSelectEntry[]
---@field viewport HollowUiLayoutSelectViewport
---@field selected integer
---@field query string
---@field filter HollowUiTextInput
---@field on_activate fun(index: integer, source_index: integer)
---@field id_prefix? string
---@field hovered_id? string
---@field prompt? string
---@field counter? string
---@field reveal_start? boolean
---@field styles? table<string, HollowUiNodeStyle>
---@field hints? HollowUiRowNode[]
---@field render_label? fun(item: any, ctx: HollowUiLayoutContext, view: { query: string, selected: boolean, hovered: boolean, theme: HollowUiTheme, id: string }): HollowUiLayoutNode|nil
---@field render_item? fun(entry: HollowUiSelectEntry, index: integer, id: string, plain: boolean): HollowUiLayoutNode
local M = { window_items = 24, row_budget = 410 }

---@param theme HollowUiTheme
---@param ctx HollowUiLayoutContext
---@return number
function M.line_height(theme, ctx)
  local padding = box.normalize(list_row(theme).indicator.padding)
  return (ctx.cell_h or 19) + padding.top + padding.bottom
end

---@param entry HollowUiSelectEntry
---@param index integer
---@param opts HollowUiLayoutSelectOptions
---@param theme HollowUiTheme
---@param ctx HollowUiLayoutContext
---@param plain boolean
---@return HollowUiLayoutNode
local function item(entry, index, opts, theme, ctx, plain)
  local id = (opts.id_prefix or "select") .. ":item:" .. entry.source_index
  local selected, hovered = index == opts.selected, opts.hovered_id == id
  local s = styles(theme, { selected = selected, hovered = hovered })
  local paint = list_row(theme, { selected = selected, hovered = hovered })
  local padding = box.normalize(paint.indicator.padding)
  local line_h = M.line_height(theme, ctx)
  local label_nodes = plain and { _G.hollow.ui.text(entry.label_text) }
    or shared.highlight_inline_nodes(entry.label_nodes, opts.query, s.match)
  local lines = {
    inline(label_nodes, s.label, {
      width = "grow",
      prefix = id .. ":label",
      height = line_h,
      padding = { top = padding.top, bottom = padding.bottom },
    }),
  }
  if opts.render_label and not plain then
    local custom = opts.render_label(
      entry.item,
      ctx,
      { query = opts.query, selected = selected, hovered = hovered, theme = theme, id = id }
    )
    if custom then
      lines[1] = c.column({ custom }, {
        width = "grow",
        height = line_h,
        padding = { top = padding.top, bottom = padding.bottom },
      })
    end
  end
  if entry.detail_text and entry.detail_text ~= "" then
    local detail = plain and { _G.hollow.ui.text(entry.detail_text) }
      or shared.highlight_inline_nodes(entry.detail_nodes, opts.query, s.match)
    lines[#lines + 1] = inline(detail, s.detail, {
      width = "grow",
      prefix = id .. ":detail",
      height = line_h,
      padding = { left = props.cell_w(ctx), top = padding.top, bottom = padding.bottom },
    })
  end
  return c.list_item({
    c.column(
      lines,
      { width = "grow", padding = { left = props.cell_w(ctx) * 2 + padding.left - 2 } }
    ),
    id = id,
    theme = theme,
    role = "listitem",
    label = entry.detail_text and (entry.label_text .. "\n" .. entry.detail_text)
      or entry.label_text,
    width = "grow",
    height = line_h * #lines,
    _accent = paint.paint.accent_bar or false,
    _style = {
      bg = paint.paint.fill_bg,
      radius = paint.paint.fill_radius,
      hover = { bg = list_row(theme, { selected = selected, hovered = true }).paint.fill_bg },
    },
    on_click = function()
      opts.on_activate(index, entry.source_index)
    end,
  })
end

-- Stacks sections one row apart; Clay paints a rule centred in each gap.
---@param children HollowUiLayoutNode[]
---@param theme HollowUiTheme
---@param cell_h number
---@return HollowUiLayoutNode
function M.sections(children, theme, cell_h)
  return c.stack({
    theme = theme,
    divided = true,
    width = "grow",
    height = "grow",
    gap = cell_h,
    children,
  })
end

---@param opts HollowUiLayoutSelectOptions
---@param theme HollowUiTheme
---@param ctx HollowUiLayoutContext
---@return HollowUiLayoutNode
function M.render(opts, theme, ctx)
  local cell_h = ctx.cell_h or 19
  local entries = opts.entries
  local viewport = opts.viewport
  -- Keep column-heavy windows conservative against Clay's fixed scroll pool.
  -- Native adapter also prunes retired IDs before updating scroll state.
  local window_items = opts.render_label and 23 or M.window_items
  local function make(entry, index, view)
    if opts.render_item then
      return opts.render_item(
        entry,
        index,
        (opts.id_prefix or "select") .. ":item:" .. entry.source_index,
        view.plain
      )
    end
    return item(entry, index, opts, theme, ctx, view.plain)
  end
  local s = opts.styles or styles(theme)
  local target = opts.reveal_start and viewport.start_idx or opts.selected
  local reveal = entries[target]
      and ((opts.id_prefix or "select") .. ":item:" .. entries[target].source_index)
    or nil
  local header = c.header({
    id = "select:header",
    width = "grow",
    height = cell_h,
    scroll_x = true,
    title = opts.prompt or "Select",
    prompt = true,
    meta = opts.counter
      or (#entries > 0 and string.format("   %d/%d", opts.selected, #entries) or ""),
    meta_align = "inline",
    title_style = s.title,
    meta_style = s.counter,
    _legacy_style = true,
  })
  local filter = c.row({
    c.text("Filter: ", s.title, { wrap = "none" }),
    input_field(opts.filter, theme, ctx, true),
  }, { width = "grow" })
  local list = {
    id = "select:viewport",
    theme = theme,
    ctx = ctx,
    _legacy_paint = true,
    _legacy_window = true,
    width = "grow",
    height = "grow",
    axis = "both",
    reveal = reveal,
    reveal_start = opts.reveal_start,
    measure = true,
    items = entries,
    selected = opts.selected,
    viewport = viewport,
    window = window_items,
    budget = M.row_budget,
    render_item = make,
    empty = c.empty({
      text = "No matches",
      style = s.empty,
      wrap = "words",
      _legacy_style = true,
    }),
  }
  local hint_node
  if opts.hints then
    if opts.hints._component then
      local hints = {}
      for key, value in pairs(opts.hints) do
        hints[key] = value
      end
      hints.id, hints.width, hints.height, hints.scroll_x = "select:hints", "grow", cell_h, true
      if #hints * 3 - 1 > 32 then
        local text = {}
        for _, hint in ipairs(hints) do
          text[#text + 1] = hint[1] .. " " .. hint[2]
        end
        hint_node = c.row({ c.text(table.concat(text, "  "), nil, { wrap = "none" }) }, hints)
      else
        hint_node = c.hints(hints)
      end
    else
      hint_node = inline(
        opts.hints[2].children,
        nil,
        { id = "select:hints", width = "grow", height = cell_h, scroll_x = true }
      )
    end
  end
  return c.picker({
    id = "select:picker",
    theme = theme,
    gap = cell_h,
    list = list,
    _legacy = true,
    _header = header,
    _filter = filter,
    _hints = hint_node,
  })
end

M.from_row = row_adapter.from_row
M.row_height = row_adapter.row_height
M.inline = inline

return M
