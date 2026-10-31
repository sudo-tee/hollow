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

---@param node HollowUiLayoutNode
---@return integer
local function count(node)
  local n = 1
  for _, child in ipairs(node.children or {}) do
    n = n + count(child)
  end
  return n
end

---@param theme HollowUiTheme
---@param ctx HollowUiLayoutContext
---@return number
function M.line_height(theme, ctx)
  local padding = box.normalize(list_row(theme).indicator.padding)
  return (ctx.cell_h or 19) + padding.top + padding.bottom
end

---@param color HollowStyleColor|number|nil
---@param radius number|nil
---@return HollowUiLayoutNode
local function accent_gutter(color, radius)
  local inset = box.px(radius, 0)
  local children = {}
  if color and color ~= 0 then
    children[1] = c.column({}, {
      width = 2,
      height = "grow",
      style = { bg = color, radius = inset > 0 and 1 or 0 },
    })
  end
  return c.column(children, {
    width = 2,
    height = "grow",
    padding = { left = 0, right = 0, top = inset, bottom = inset },
  })
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
  return c.row({
    accent_gutter(paint.paint.accent_bar, paint.paint.fill_radius),
    c.column(
      lines,
      { width = "grow", padding = { left = props.cell_w(ctx) * 2 + padding.left - 2 } }
    ),
  }, {
    id = id,
    role = "listitem",
    label = entry.detail_text and (entry.label_text .. "\n" .. entry.detail_text)
      or entry.label_text,
    width = "grow",
    height = line_h * #lines,
    style = {
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
  local start = math.max(
    1,
    viewport.start_idx
      - math.floor((window_items - (viewport.end_idx - viewport.start_idx + 1)) / 2)
  )
  local finish = math.min(#entries, start + window_items - 1)
  start = math.max(1, finish - window_items + 1)
  local rows = {}
  local costs, plain_rows, total = {}, {}, 0
  local function make(index, plain)
    if opts.render_item then
      return opts.render_item(
        entries[index],
        index,
        (opts.id_prefix or "select") .. ":item:" .. entries[index].source_index,
        plain
      )
    end
    return item(entries[index], index, opts, theme, ctx, plain)
  end
  for index = start, finish do
    local row = make(index, false)
    rows[#rows + 1] = row
    costs[#rows] = count(row)
    total = total + costs[#rows]
  end
  -- Keep visible/selected rich content first. Simplify the farthest overscan
  -- rows only if the complete tree would exceed the bounded native arena.
  while total > M.row_budget do
    local farthest, distance
    for offset = 1, #rows do
      local d = math.abs(start + offset - 1 - opts.selected)
      if not plain_rows[offset] and (not distance or d > distance) then
        farthest, distance = offset, d
      end
    end
    if not farthest then
      break
    end
    local row = make(start + farthest - 1, true)
    total = total - costs[farthest] + count(row)
    costs[farthest], rows[farthest], plain_rows[farthest] = count(row), row, true
  end
  local s = opts.styles or styles(theme)
  if #entries == 0 then
    rows[1] =
      c.empty({ text = "No matches", style = s.empty, wrap = "words", _legacy_style = true })
  end
  local target = opts.reveal_start and viewport.start_idx or opts.selected
  local reveal = entries[target]
      and ((opts.id_prefix or "select") .. ":item:" .. entries[target].source_index)
    or nil
  local children = {
    c.header({
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
    }),
    c.row({
      c.text("Filter: ", s.title, { wrap = "none" }),
      input_field(opts.filter, theme, ctx, true),
    }, { width = "grow" }),
    c.scroll({
      id = "select:viewport",
      theme = theme,
      ctx = ctx,
      _legacy_paint = true,
      width = "grow",
      height = "grow",
      axis = "both",
      reveal = reveal,
      reveal_start = opts.reveal_start,
      measure = true,
      scrollbar = viewport.show_scrollbar and {
        id = viewport.scrollbar_id,
        ratio = viewport.thumb_ratio,
        size = viewport.thumb_size,
      } or nil,
      rows,
    }),
  }
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
        children[#children + 1] =
          c.row({ c.text(table.concat(text, "  "), nil, { wrap = "none" }) }, hints)
      else
        children[#children + 1] = c.hints(hints)
      end
    else
      children[#children + 1] = inline(
        opts.hints[2].children,
        nil,
        { id = "select:hints", width = "grow", height = cell_h, scroll_x = true }
      )
    end
  end
  return M.sections(children, theme, cell_h)
end

-- Adapter for existing row components. Layout is rebuilt as boxes/text;
-- Segment serialization and native row positioning are not involved.
---@param row HollowUiRowNode
---@param id string
---@param label string
---@param theme HollowUiTheme
---@param ctx HollowUiLayoutContext
---@param on_click fun(event: { id: string })|nil
---@param plain boolean|nil
---@return HollowUiLayoutNode
function M.from_row(row, id, label, theme, ctx, on_click, plain)
  local serialized = shared.serialize_row_paint(row, theme)
  local flat = shared.flatten_span_nodes(row.children)
  local top, bottom, center = 0, 0, false
  for _, span in ipairs(flat) do
    local padding = box.normalize(span.style and span.style.padding)
    top, bottom = math.max(top, padding.top), math.max(bottom, padding.bottom)
  end
  for _, span in ipairs(flat) do
    if
      not span.spacer
      and tostring(span.text or ""):match("%S")
      and box.normalize(span.style and span.style.padding).top < top
    then
      center = true
    end
  end
  local content
  if plain then
    content = c.row(
      { c.text(label, { fg = theme.fg }, { wrap = "none" }) },
      { width = "grow", padding = { top = top, bottom = bottom } }
    )
  else
    content = inline(row.children, nil, {
      width = "grow",
      prefix = id,
      height = (ctx.cell_h or 19) + top + bottom,
      align_y = center and "center" or "start",
    })
  end
  return c.row({
    accent_gutter(serialized.accent_bar, serialized.fill_radius),
    content,
  }, {
    id = id,
    role = "listitem",
    label = label,
    width = "grow",
    height = (ctx.cell_h or 19) + top + bottom,
    style = {
      bg = serialized.fill_bg,
      radius = serialized.fill_radius,
      hover = {
        bg = serialized.accent_bar and serialized.fill_bg
          or list_row(theme, { hovered = true }).paint.fill_bg,
      },
    },
    on_click = on_click,
  })
end

---@param row HollowUiRowNode
---@param ctx HollowUiLayoutContext
---@return number
function M.row_height(row, ctx)
  local top, bottom = 0, 0
  for _, span in ipairs(shared.flatten_span_nodes(row.children)) do
    local padding = box.normalize(span.style and span.style.padding)
    top, bottom = math.max(top, padding.top), math.max(bottom, padding.bottom)
  end
  return (ctx.cell_h or 19) + top + bottom
end

M.inline = inline

return M
