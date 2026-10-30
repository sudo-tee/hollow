-- Tree validation and native-boundary serialization. No mounting or global callbacks.
--
-- Snapshot nodes are sparse: false, zero and default fields are omitted and the
-- native parser supplies the defaults (`alpha` 255, `scrollbar_thumb_size` 1).
-- Only nodes that need a stable Clay identity carry an `id`: the root, explicit
-- ids, scroll viewports and measured nodes. Anonymous nodes are identified by
-- their preorder index natively.
local box = require("hollow.ui.style.box")
local color = require("hollow.color")
local shared = require("hollow.ui.shared")
local tokens = require("hollow.ui.style.tokens")
local wraps = { words = 0, newlines = 1, none = 2 }
local alignments = { start = 0, center = 1, ["end"] = 2 }
local text_alignments = { left = 0, center = 1, right = 2 }
local EMPTY = {}

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

-- Returns nil for zero so sparse nodes omit the field.
local function nonzero(value)
  if value ~= 0 then
    return value
  end
  return nil
end

---@param root HollowUiLayoutNode
---@param palette HollowUiTheme
---@param namespace string
---@return table[] nodes
---@return table<string, fun(event: { id: string })> callbacks
---@return table<string, string> local_ids
return function(root, palette, namespace)
  ---@type table[], table<string, fun(event: { id: string })>, table<string, integer>, table<string, string>, integer[]
  local nodes, callbacks, ids, local_ids, subtree_ends = {}, {}, {}, {}, {}
  -- Callers may mutate style tables between snapshots, so memoize by identity
  -- only within this call.
  local styles, text_styles = {}, {}
  ---@param source HollowUiNodeStyle|nil
  local function container_style(source)
    local entry = styles[source or EMPTY]
    if not entry then
      local style = shared.resolve_tokens(source or EMPTY, palette)
      entry = { style = style, paint = shared.normalize_surface_style(style) or EMPTY }
      styles[source or EMPTY] = entry
    end
    return entry
  end
  ---@param source HollowUiNodeStyle|nil
  local function text_style(source)
    local entry = text_styles[source or EMPTY]
    if not entry then
      source = source or EMPTY
      local fg = color.normalize_hex_color(tokens.resolve_color(source.fg, "fg", palette), nil)
      entry = { fg = fg or palette.fg, bold = source.bold == true or nil }
      text_styles[source] = entry
    end
    return entry
  end
  local scrollbar_defaults = {}
  local function scrollbar_color(key, value, fallback)
    if value then
      return shared.resolve_tokens({ [key] = value }, palette)[key]
    end
    if scrollbar_defaults[key] == nil then
      scrollbar_defaults[key] = shared.resolve_tokens({ [key] = fallback }, palette)[key] or false
    end
    return scrollbar_defaults[key] or nil
  end
  ---@type fun(node: HollowUiLayoutNode, depth: integer)
  local visit
  ---@param list table
  ---@param fragment_depth integer
  ---@param serialized table
  ---@param depth integer
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
          serialized.children = (serialized.children or 0) + 1
          visit(child, depth + 1)
        end
      end
    end
  end
  visit = function(node, depth)
    assert(type(node) == "table" and node.kind ~= nil, "expected layout node")
    assert(depth <= 32 and #nodes < 512, "layout tree exceeds prototype limits")
    local kind = node.kind
    assert(
      type(kind) == "number" and kind % 1 == 0 and kind >= 0 and kind <= 3,
      "unknown layout node"
    )
    assert(node.align_y == nil or alignments[node.align_y] ~= nil, "invalid vertical alignment")
    assert(
      node.role == nil or node.role == "button" or node.role == "listitem",
      "invalid layout role"
    )
    assert(node.wrap == nil or wraps[node.wrap] ~= nil, "invalid text wrap mode")
    local text_align = text_alignments[node.text_align] or node.text_align
    assert(
      text_align == nil or text_align == 0 or text_align == 1 or text_align == 2,
      "invalid text alignment"
    )
    assert(
      node.scrollbar_id == nil
        or (
          type(node.scrollbar_id) == "string"
          and #node.scrollbar_id > 0
          and #namespace + #node.scrollbar_id <= 128
        ),
      "invalid scrollbar id"
    )
    assert(
      node.reveal == nil or (type(node.reveal) == "string" and #node.reveal > 0),
      "invalid reveal target"
    )
    local index = #nodes + 1
    local clickable = type(node.on_click) == "function"
    local serialized = {
      kind = nonzero(kind),
      text = node.text,
      label = node.label,
      list_item = node.role == "listitem" or nil,
      wrap = nonzero(wraps[node.wrap or "words"]),
      text_align = nonzero(text_align or 0),
      clickable = clickable or nil,
      measure = node.measure == true or nil,
    }
    local id
    if node.id ~= nil or depth == 0 or node.scroll or node.scroll_x or node.measure then
      local local_id = node.id or ("auto:" .. index)
      assert(type(local_id) == "string" and #local_id > 0, "invalid layout id")
      id = namespace .. local_id
      assert(#id <= 128, "invalid layout id")
      assert(not ids[id], "duplicate layout id: " .. id)
      ids[id] = index
      local_ids[id] = local_id
      serialized.id = id
    end
    if kind == 2 then
      local style = text_style(node.style)
      serialized.fg, serialized.bold = style.fg, style.bold
    else
      local entry = container_style(node.style)
      local style, paint = entry.style, entry.paint
      local padding_value = node.padding
      if padding_value == nil then
        padding_value = style.padding
      end
      local padding = box.normalize(padding_value, true)
      if not box.is_empty(padding) then
        for _, side in ipairs(box.SIDES) do
          padding[side] = math.min(65535, padding[side])
        end
        serialized.padding = padding
      end
      serialized.width = nonzero(size(node.width))
      serialized.height = nonzero(size(node.height))
      for _, key in ipairs({ "min_width", "max_width", "min_height", "max_height" }) do
        if node[key] ~= nil then
          assert(
            type(node[key]) == "number" and node[key] >= 0 and node[key] < 65536,
            "invalid layout constraint"
          )
          serialized[key] = node[key]
        end
      end
      serialized.gap = nonzero(math.min(65535, box.px(node.gap, 0, true)))
      serialized.bg = paint.bg
      if paint.bg and paint.alpha and paint.alpha ~= 255 then
        serialized.alpha = paint.alpha
      end
      serialized.border = paint.border
      local widths = node.border_width or style.border_width
      if widths then
        assert(type(widths) == "table", "invalid border widths")
        serialized.border_width = {}
        for _, side in ipairs({ "left", "right", "top", "bottom", "between_children" }) do
          serialized.border_width[side] = math.min(65535, box.px(widths[side], 0, true))
        end
      else
        local width = math.min(65535, box.px(paint.border_size, paint.border and 1 or 0, true))
        if width > 0 then
          serialized.border_width = { left = width, right = width, top = width, bottom = width }
        end
      end
      serialized.radius = nonzero(box.px(paint.radius, 0))
      serialized.hover_bg = type(style.hover) == "table" and style.hover.bg or nil
      serialized.scroll = node.scroll == true or nil
      serialized.scroll_x = node.scroll_x == true or nil
      serialized.reveal = node.reveal and (namespace .. node.reveal)
      serialized.reveal_start = node.reveal_start == true or nil
      serialized.align_y = nonzero(alignments[node.align_y or "start"])
      if kind == 3 then
        serialized.value = nonzero(math.max(0, math.min(1, tonumber(node.value) or 0)))
      end
      if node.scrollbar_id then
        local scrollbar_id = namespace .. node.scrollbar_id
        serialized.scrollbar_id = scrollbar_id
        local_ids[scrollbar_id] = node.scrollbar_id
        serialized.scrollbar_thumb_ratio =
          nonzero(math.max(0, math.min(1, tonumber(node.scrollbar_thumb_ratio) or 0)))
        local thumb_size = math.max(0, math.min(1, tonumber(node.scrollbar_thumb_size) or 1))
        if thumb_size ~= 1 then
          serialized.scrollbar_thumb_size = thumb_size
        end
        serialized.scrollbar_track_color = scrollbar_color(
          "scrollbar_track_color",
          node.scrollbar_track_color,
          "parts.scrollbar.track|scrollbar_track|#5a6375"
        )
        serialized.scrollbar_thumb_color = scrollbar_color(
          "scrollbar_thumb_color",
          node.scrollbar_thumb_color,
          "parts.scrollbar.thumb|scrollbar_thumb|panel_border"
        )
      end
    end
    nodes[index] = serialized
    if clickable then
      assert(node.id, "clickable layout nodes require stable explicit ids")
      callbacks[id] = node.on_click
    end
    if node.children then
      children(node.children, 0, serialized, depth)
    end
    subtree_ends[index] = #nodes
    assert(kind ~= 2 or serialized.children == nil, "text cannot have children")
  end
  visit(root, 0)
  for index, node in ipairs(nodes) do
    if node.reveal then
      assert(node.scroll or node.scroll_x, "reveal requires a scroll container")
      local target = ids[node.reveal]
      assert(target, "unknown layout reveal target: " .. node.reveal)
      assert(target > index and target <= subtree_ends[index], "reveal target must be a descendant")
      assert(nodes[target].kind ~= 2, "reveal target must be a container")
    end
  end
  return nodes, callbacks, local_ids
end
