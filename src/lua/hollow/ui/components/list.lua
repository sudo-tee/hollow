-- One scroll viewport plus rendered item nodes; no extra list wrapper.
--
-- Renders a window of `window` items centred on the visible range, plus the
-- selected item. When item nodes exceed `budget`, the farthest rows outside
-- the visible range re-render with `view.plain`; visible and selected rows stay
-- rich, so the budget is soft when they alone exceed it.
local c = require("hollow.ui.components")
local props = require("hollow.ui.components.props")

local function count(value)
  if type(value) ~= "table" then
    return 0
  end
  local total = value.kind ~= nil and 1 or 0
  local children = value.kind ~= nil and value.children or value
  if children then
    for i = 1, table.maxn(children) do
      total = total + count(children[i])
    end
  end
  return total
end

return function(value)
  local options = props.split(value)
  assert(type(options.id) == "string" and options.id ~= "", "list requires an id")
  assert(type(options.render_item) == "function", "list requires render_item")
  local items, viewport = options.items or {}, options.viewport or {}
  local selected = math.max(1, math.min(#items, options.selected or 1))
  local visible_start = math.max(1, math.min(#items, viewport.start_idx or selected))
  local visible_end = math.max(visible_start, math.min(#items, viewport.end_idx or visible_start))
  local window = math.max(1, math.floor(options.window or 24))
  local budget = math.max(0, math.floor(options.budget or props.LIST_BUDGET))
  local start =
    math.max(1, visible_start - math.floor((window - (visible_end - visible_start + 1)) / 2))
  local finish = math.min(#items, math.max(visible_end, start + window - 1))
  start = math.max(1, math.min(start, finish - window + 1))
  local indices = {}
  for index = start, finish do
    indices[#indices + 1] = index
  end
  if #items > 0 and (selected < start or selected > finish) then
    indices[#indices + 1] = selected
    table.sort(indices)
  end
  local function render(index, plain)
    local row = options.render_item(items[index], index, { plain = plain })
    assert(type(row) == "table", "render_item must return a layout node or fragment")
    return row
  end
  local rows, costs, plain, total = {}, {}, {}, 0
  for offset, index in ipairs(indices) do
    rows[offset] = render(index, false)
    costs[offset] = count(rows[offset])
    total = total + costs[offset]
  end
  while total > budget do
    local farthest, distance
    for offset, index in ipairs(indices) do
      if
        not plain[offset]
        and index ~= selected
        and (index < visible_start or index > visible_end)
      then
        local d = math.abs(index - selected)
        if not distance or d > distance then
          farthest, distance = offset, d
        end
      end
    end
    if not farthest then
      break
    end
    local row = render(indices[farthest], true)
    local cost = count(row)
    total = total - costs[farthest] + cost
    rows[farthest], costs[farthest], plain[farthest] = row, cost, true
  end
  if #items == 0 and options.empty ~= nil then
    rows[1] = type(options.empty) == "string" and c.empty(options.empty) or options.empty
  end
  if options.reveal == nil then
    for offset, index in ipairs(indices) do
      if index == selected and rows[offset].kind ~= nil then
        options.reveal = rows[offset].id
        break
      end
    end
  end
  options.axis = options.axis or "both"
  if not options.scrollbar and viewport.show_scrollbar then
    options.scrollbar =
      { id = viewport.scrollbar_id, ratio = viewport.thumb_ratio, size = viewport.thumb_size }
  end
  options[1] = rows
  return c.scroll(options)
end
