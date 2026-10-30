-- Bounded list composition. Clay owns pixel layout/scrolling; the select widget
-- keeps its existing filtering, navigation and action state.
local box = require("hollow.ui.style.box")
local list_row = require("hollow.ui.styles.list_row")
local shared = require("hollow.ui.shared")
local styles = require("hollow.ui.styles.select")
local util = require("hollow.util")
local layout = _G.hollow.ui.layout
local input_field = require("hollow.ui.builder.components.layout_input")
local M = { window_items = 24, row_budget = 410 }

local function count(node)
  local n = 1
  for _, child in ipairs(node.children or {}) do
    n = n + count(child)
  end
  return n
end

local function inline(children, style, opts)
  opts = opts or {}
  local flat = shared.flatten_span_nodes(children, style)
  if #flat > 32 then
    return layout.row(
      { layout.text(shared.nodes_plain_text(children), style, { wrap = "none" }) },
      opts
    )
  end
  local runs = {}
  local spacer
  for index, span in ipairs(flat) do
    if span.spacer then
      runs[#runs + 1] = layout.column({}, { width = "grow" })
      spacer = spacer or #runs
    else
      local text = layout.text(span.text, span.style, { wrap = "none" })
      local paint = span.style or {}
      if
        paint.bg
        or paint.border
        or paint.radius
        or type(paint.on_click) == "function"
        or not box.is_empty(box.normalize(paint.padding))
      then
        text = layout.column({ text }, {
          style = paint,
          id = type(paint.on_click) == "function"
              and ((opts.prefix or "select:inline") .. ":run:" .. index)
            or nil,
          label = span.text,
          on_click = type(paint.on_click) == "function" and function(event)
            local payload = util.clone_value(event)
            payload.id = paint.id
            paint.on_click(payload)
          end or nil,
        })
      end
      runs[#runs + 1] = text
    end
  end
  if spacer then
    local left, right = {}, {}
    for index, run in ipairs(runs) do
      if index < spacer then
        left[#left + 1] = run
      elseif index > spacer then
        right[#right + 1] = run
      end
    end
    return layout.row({
      layout.row(left, { width = "grow", scroll_x = true, align_y = opts.align_y }),
      layout.row(right, { align_y = opts.align_y }),
    }, opts)
  end
  return layout.row(runs, opts)
end

function M.line_height(theme, ctx)
  local padding = box.normalize(list_row(theme).indicator.padding)
  return (ctx.cell_h or 19) + padding.top + padding.bottom
end

local function accent_gutter(color, radius)
  local inset = box.px(radius, 0)
  local children = {}
  if color and color ~= 0 then
    children[1] = layout.column({}, {
      width = 2,
      height = "grow",
      style = { bg = color, radius = inset > 0 and 1 or 0 },
    })
  end
  return layout.column(children, {
    width = 2,
    height = "grow",
    padding = { left = 0, right = 0, top = inset, bottom = inset },
  })
end

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
      lines[1] = layout.column({ custom }, {
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
      padding = { left = ctx.cell_w or 8, top = padding.top, bottom = padding.bottom },
    })
  end
  return layout.row({
    accent_gutter(paint.paint.accent_bar, paint.paint.fill_radius),
    layout.column(
      lines,
      { width = "grow", padding = { left = (ctx.cell_w or 8) * 2 + padding.left - 2 } }
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

-- Clay borders cannot reach into the panel padding, so the rule stays a
-- full-bleed 1px node centred in one row.
function M.divider(theme, cell_h)
  return layout.column({
    layout.column(
      {},
      { width = "grow", height = 1, full_bleed_x = true, style = { bg = theme.divider } }
    ),
  }, { width = "grow", height = cell_h, padding = { top = math.floor(cell_h * 0.5) } })
end

function M.render(opts, theme, ctx)
  local cell_h = ctx.cell_h or 19
  local function divider()
    return M.divider(theme, cell_h)
  end
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
    rows[1] = layout.text("No matches", s.empty)
  end
  local target = opts.reveal_start and viewport.start_idx or opts.selected
  local reveal = entries[target]
      and ((opts.id_prefix or "select") .. ":item:" .. entries[target].source_index)
    or nil
  local scrollbar = viewport.show_scrollbar
      and shared.serialize_row_paint({ scrollbar_track = true }, theme)
    or {}
  local children = {
    layout.row({
      layout.text((opts.prompt or "Select") .. ":", s.title, { wrap = "none" }),
      layout.text(
        opts.counter or (#entries > 0 and string.format("   %d/%d", opts.selected, #entries) or ""),
        s.counter,
        { wrap = "none" }
      ),
    }, { id = "select:header", width = "grow", height = cell_h, scroll_x = true }),
    divider(),
    layout.row({
      layout.text("Filter: ", s.title, { wrap = "none" }),
      input_field(opts.filter, theme, ctx, true),
    }, { width = "grow" }),
    divider(),
    layout.column(rows, {
      id = "select:viewport",
      width = "grow",
      height = "grow",
      scroll = true,
      scroll_x = true,
      reveal = reveal,
      reveal_start = opts.reveal_start,
      measure = true,
      -- Box shorthand mirrors right onto left unless left is explicit.
      padding = { left = 0, right = viewport.show_scrollbar and math.max(8, ctx.cell_w or 8) or 0 },
      scrollbar_id = viewport.show_scrollbar and viewport.scrollbar_id or nil,
      scrollbar_thumb_ratio = viewport.thumb_ratio,
      scrollbar_thumb_size = viewport.thumb_size,
      scrollbar_track_color = scrollbar.scrollbar_track_color,
      scrollbar_thumb_color = scrollbar.scrollbar_thumb_color,
    }),
  }
  if opts.hints then
    children[#children + 1] = divider()
    children[#children + 1] = inline(
      opts.hints[2].children,
      nil,
      { id = "select:hints", width = "grow", height = cell_h, scroll_x = true }
    )
  end
  return layout.column(children, { width = "grow", height = "grow" })
end

-- Adapter for existing row components. Layout is rebuilt as boxes/text;
-- Segment serialization and native row positioning are not involved.
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
    content = layout.row(
      { layout.text(label, { fg = theme.fg }, { wrap = "none" }) },
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
  return layout.row({
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
