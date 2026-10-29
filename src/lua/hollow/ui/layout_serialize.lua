-- Tree validation and native-boundary serialization. No mounting or global callbacks.
local box = require("hollow.ui.style.box")
local shared = require("hollow.ui.shared")

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
  local nodes, callbacks, ids, local_ids = {}, {}, {}, {}
  local function visit(node, depth)
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
    ids[id] = true
    local style = shared.resolve_tokens(node.style or {}, palette)
    local paint = shared.normalize_surface_style(style, palette) or {}
    local padding_value = node.padding
    if padding_value == nil then
      padding_value = style.padding
    end
    local padding = box.normalize(padding_value, true)
    local serialized = {
      kind = node.kind,
      id = id,
      text = node.text,
      label = node.label,
      width = size(node.width),
      height = size(node.height),
      gap = math.min(65535, box.px(node.gap, 0, true)),
      padding = padding,
      fg = paint.fg or palette.fg,
      bg = paint.bg,
      alpha = paint.alpha or 255,
      border = paint.border,
      border_size = math.min(65535, box.px(paint.border_size, paint.border and 1 or 0, true)),
      radius = box.px(paint.radius, 0),
      bold = style.bold == true,
      hover_bg = type(style.hover) == "table" and style.hover.bg or nil,
      scroll = node.scroll == true,
      clickable = type(node.on_click) == "function",
      value = math.max(0, math.min(1, tonumber(node.value) or 0)),
      children = 0,
    }
    for _, side in ipairs(box.SIDES) do
      padding[side] = math.min(65535, padding[side])
    end
    nodes[#nodes + 1] = serialized
    if serialized.clickable then
      assert(node.id, "clickable layout nodes require stable explicit ids")
      callbacks[id] = node.on_click
      local_ids[id] = local_id
    end
    local function children(list, fragment_depth)
      assert(
        type(list) == "table" and fragment_depth <= 32,
        "invalid or excessively nested layout children"
      )
      for i = 1, table.maxn(list) do
        local child = list[i]
        if child ~= nil and type(child) ~= "boolean" then
          if type(child) == "table" and child.kind == nil then
            children(child, fragment_depth + 1)
          else
            serialized.children = serialized.children + 1
            visit(child, depth + 1)
          end
        end
      end
    end
    children(node.children or {}, 0)
    assert(node.kind ~= 2 or serialized.children == 0, "text cannot have children")
  end
  visit(root, 0)
  return nodes, callbacks, local_ids
end
