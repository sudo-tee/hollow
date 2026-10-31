-- One scroll viewport plus rendered item nodes; no extra list wrapper.
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

local function legacy_count(node)
  local total = 1
  for _, child in ipairs(node.children or {}) do
    total = total + legacy_count(child)
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
  local visible_count = options._legacy_visible_count or (visible_end - visible_start + 1)
  local start = math.max(1, visible_start - math.floor((window - visible_count) / 2))
  local finish = math.min(
    #items,
    options._legacy_window and (start + window - 1) or math.max(visible_end, start + window - 1)
  )
  start = math.max(1, math.min(start, finish - window + 1))
  local indices = {}
  for index = start, finish do
    indices[#indices + 1] = index
  end
  if not options._legacy_window and #items > 0 and (selected < start or selected > finish) then
    indices[#indices + 1] = selected
    table.sort(indices)
  end
  local rows, costs, plain, total = {}, {}, {}, 0
  local node_count = options._legacy_window and legacy_count or count
  local function render(index, simplified)
    return options.render_item(items[index], index, { plain = simplified })
  end
  for offset, index in ipairs(indices) do
    local row = render(index, false)
    assert(type(row) == "table", "render_item must return a layout node or fragment")
    rows[offset], costs[offset] = row, node_count(row)
    total = total + costs[offset]
  end
  while total > budget do
    local farthest, distance
    for offset, index in ipairs(indices) do
      if
        not plain[offset]
        and (
          options._legacy_window
          or (index ~= selected and (index < visible_start or index > visible_end))
        )
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
    assert(type(row) == "table", "render_item must return a layout node or fragment")
    local cost = node_count(row)
    total = total - costs[farthest] + cost
    rows[farthest], costs[farthest], plain[farthest] = row, cost, true
  end
  if #items == 0 and options.empty ~= nil then
    rows[1] = type(options.empty) == "string" and c.empty(options.empty) or options.empty
  end
  local root = options
  if root.reveal == nil and not options._legacy_window then
    for offset, index in ipairs(indices) do
      if index == selected and rows[offset].kind ~= nil then
        root.reveal = rows[offset].id
        break
      end
    end
  end
  root.axis = options.axis or "both"
  if not root.scrollbar and viewport.show_scrollbar then
    root.scrollbar =
      { id = viewport.scrollbar_id, ratio = viewport.thumb_ratio, size = viewport.thumb_size }
  end
  root[1] = rows
  return c.scroll(root)
end
