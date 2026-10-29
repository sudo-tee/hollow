-- Tree validation and native-boundary serialization. No mounting or global callbacks.
local box = require("hollow.ui.style.box")
local shared = require("hollow.ui.shared")
local wraps = { words = 0, newlines = 1, none = 2 }
local alignments = { start = 0, center = 1, ["end"] = 2 }

local function size(value)
  if value == "grow" then
    return -1
  end
  if value == nil or value == "fit" then
    return 0
  end
  assert(type(value) == "number" and value >= 0 and value < 65536, "invalid layout size")
  return value
end

return function(root, palette, namespace)
  local nodes, callbacks, ids, local_ids, subtree_ends = {}, {}, {}, {}, {}
  local default_scrollbar_colors = {}
  local default_scrollbar_resolved = {}
  local function scrollbar_color(key, value, fallback)
    if value then
      return shared.resolve_tokens({ [key] = value }, palette)[key]
    end
    if not default_scrollbar_resolved[key] then
      default_scrollbar_colors[key] = shared.resolve_tokens({ [key] = fallback }, palette)[key]
      default_scrollbar_resolved[key] = true
    end
    return default_scrollbar_colors[key]
  end
  local visit
  local function children(list, fragment_depth, serialized, depth)
    assert(
      type(list) == "table" and fragment_depth <= 32,
      "invalid or excessively nested layout children"
    )
    for i = 1, table.maxn(list) do
      local child = list[i]
      if child ~= nil and type(child) ~= "boolean" then
        if type(child) == "table" and child.kind == nil then
          children(child, fragment_depth + 1, serialized, depth)
        else
          serialized.children = serialized.children + 1
          visit(child, depth + 1)
        end
      end
    end
  end
  visit = function(node, depth)
    assert(type(node) == "table" and node.kind ~= nil, "expected layout node")
    assert(depth <= 32 and #nodes < 512, "layout tree exceeds prototype limits")
    assert(
      type(node.kind) == "number" and node.kind % 1 == 0 and node.kind >= 0 and node.kind <= 3,
      "unknown layout node"
    )
    local local_id = node.id or ("auto:" .. (#nodes + 1))
    assert(type(local_id) == "string" and #local_id > 0, "invalid layout id")
    local id = namespace .. local_id
    assert(type(id) == "string" and #id > 0 and #id <= 128, "invalid layout id")
    assert(not ids[id], "duplicate layout id: " .. id)
    ids[id] = #nodes + 1
    local style = shared.resolve_tokens(node.style or {}, palette)
    local paint = shared.normalize_surface_style(style) or {}
    local padding_value = node.padding
    if padding_value == nil then
      padding_value = style.padding
    end
    local padding = box.normalize(padding_value, true)
    assert(node.align_y == nil or alignments[node.align_y] ~= nil, "invalid vertical alignment")
    assert(
      node.role == nil or node.role == "button" or node.role == "listitem",
      "invalid layout role"
    )
    assert(node.wrap == nil or wraps[node.wrap] ~= nil, "invalid text wrap mode")
    assert(node.full_bleed_x == nil or type(node.full_bleed_x) == "boolean", "invalid full_bleed_x")
    assert(
      node.scrollbar_id == nil
        or (
          type(node.scrollbar_id) == "string"
          and #node.scrollbar_id > 0
          and #namespace + #node.scrollbar_id <= 128
        ),
      "invalid scrollbar id"
    )
    local track_color = scrollbar_color(
      "scrollbar_track_color",
      node.scrollbar_track_color,
      "parts.scrollbar.track|scrollbar_track|#5a6375"
    )
    local thumb_color = scrollbar_color(
      "scrollbar_thumb_color",
      node.scrollbar_thumb_color,
      "parts.scrollbar.thumb|scrollbar_thumb|panel_border"
    )
    assert(
      node.reveal == nil or (type(node.reveal) == "string" and #node.reveal > 0),
      "invalid reveal target"
    )
    local serialized = {
      kind = node.kind,
      id = id,
      text = node.text,
      label = node.label,
      list_item = node.role == "listitem",
      width = size(node.width),
      height = size(node.height),
      gap = math.min(65535, box.px(node.gap, 0, true)),
      padding = padding,
      full_bleed_x = node.full_bleed_x == true,
      fg = paint.fg or palette.fg,
      bg = paint.bg,
      alpha = paint.alpha or 255,
      border = paint.border,
      border_size = math.min(65535, box.px(paint.border_size, paint.border and 1 or 0, true)),
      radius = box.px(paint.radius, 0),
      bold = style.bold == true,
      hover_bg = type(style.hover) == "table" and style.hover.bg or nil,
      scroll = node.scroll == true,
      scroll_x = node.scroll_x == true,
      scrollbar_id = node.scrollbar_id and (namespace .. node.scrollbar_id),
      scrollbar_thumb_ratio = math.max(0, math.min(1, tonumber(node.scrollbar_thumb_ratio) or 0)),
      scrollbar_thumb_size = math.max(0, math.min(1, tonumber(node.scrollbar_thumb_size) or 1)),
      scrollbar_track_color = track_color,
      scrollbar_thumb_color = thumb_color,
      reveal = node.reveal and (namespace .. node.reveal),
      reveal_start = node.reveal_start == true,
      measure = node.measure == true,
      align_y = alignments[node.align_y or "start"],
      wrap = wraps[node.wrap or "words"],
      clickable = type(node.on_click) == "function",
      value = math.max(0, math.min(1, tonumber(node.value) or 0)),
      children = 0,
    }
    for _, side in ipairs(box.SIDES) do
      padding[side] = math.min(65535, padding[side])
    end
    nodes[#nodes + 1] = serialized
    local_ids[id] = local_id
    if serialized.scrollbar_id then
      local_ids[serialized.scrollbar_id] = node.scrollbar_id
    end
    if serialized.clickable then
      assert(node.id, "clickable layout nodes require stable explicit ids")
      callbacks[id] = node.on_click
    end
    if node.children then
      children(node.children, 0, serialized, depth)
    end
    subtree_ends[id] = #nodes
    assert(node.kind ~= 2 or serialized.children == 0, "text cannot have children")
  end
  visit(root, 0)
  for _, node in ipairs(nodes) do
    if node.reveal then
      assert(node.scroll or node.scroll_x, "reveal requires a scroll container")
      assert(ids[node.reveal], "unknown layout reveal target: " .. node.reveal)
      local target = ids[node.reveal]
      assert(
        target > ids[node.id] and target <= subtree_ends[node.id],
        "reveal target must be a descendant"
      )
      assert(nodes[target].kind ~= 2, "reveal target must be a container")
    end
  end
  return nodes, callbacks, local_ids
end
