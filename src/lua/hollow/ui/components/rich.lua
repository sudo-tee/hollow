-- One row plus inline runs (`ui.text`, `ui.span`, groups or fragments). Painted
-- or clickable runs need a container, and a spacer splits the content into two
-- additional rows for left/right alignment. `plain` (or more than 32 runs)
-- collapses the content into one text node. `style` is inherited by the runs;
-- the row itself is unpainted.
--
-- Without an explicit height, padded runs set the row height to the cell height
-- plus their largest top and bottom padding, and center unpadded text.
local box = require("hollow.ui.style.box")
local c = require("hollow.ui.components")
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")
local util = require("hollow.util")
local M = {}

local MAX_RUNS = 32

local function painted(style)
  return style.bg
    or style.border
    or style.radius
    or type(style.on_click) == "function"
    or not box.is_empty(box.normalize(style.padding))
end

-- Largest vertical run padding, and whether some visible text sits higher.
local function extents(flat)
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
  return top, bottom, center
end

local function flatten(children, style)
  return shared.flatten_span_nodes(
    shared.collect_inline(children, "hollow.ui.components.rich", true),
    style
  )
end

--- Row height for inline content: cell height plus the largest run padding.
---@param children table
---@param ctx? HollowUiLayoutContext
---@return number
function M.height(children, ctx)
  local top, bottom = extents(flatten(children))
  return props.cell_h(ctx) + top + bottom
end

local function run(span, index, prefix)
  local text = c.text(span.text, span.style, { wrap = "none" })
  local paint = span.style or {}
  if not painted(paint) then
    return text
  end
  local clickable = type(paint.on_click) == "function"
  return c.column({ text }, {
    style = paint,
    id = clickable and (prefix .. ":run:" .. index) or nil,
    label = span.text,
    on_click = clickable and function(event)
      local payload = util.clone_value(event)
      payload.id = paint.id
      paint.on_click(payload)
    end or nil,
  })
end

local function render(value)
  local opts, children = props.split(value)
  local style = opts.style
  opts.style = nil
  local flat = flatten(children, style)
  local top, bottom, center = extents(flat)
  if opts.height == nil and top + bottom > 0 then
    opts.height = props.cell_h(props.ctx(opts)) + top + bottom
    opts.align_y = opts.align_y or (center and "center" or nil)
  end
  if opts.plain or #flat > MAX_RUNS then
    local parts = {}
    for _, span in ipairs(flat) do
      parts[#parts + 1] = not span.spacer and span.text or nil
    end
    return c.row({ c.text(table.concat(parts), style, { wrap = "none" }) }, opts)
  end
  local prefix = opts.prefix or opts.id or "rich"
  local runs, spacer = {}, nil
  for index, span in ipairs(flat) do
    if span.spacer then
      runs[#runs + 1] = c.spacer()
      spacer = spacer or #runs
    else
      runs[#runs + 1] = run(span, index, prefix)
    end
  end
  if not spacer then
    return c.row(runs, opts)
  end
  local left, right = {}, {}
  for index, item in ipairs(runs) do
    if index < spacer then
      left[#left + 1] = item
    elseif index > spacer then
      right[#right + 1] = item
    end
  end
  return c.row({
    c.row(left, { width = "grow", scroll_x = true, align_y = opts.align_y }),
    c.row(right, { align_y = opts.align_y }),
  }, opts)
end

return setmetatable(M, {
  __call = function(_, value)
    return render(value)
  end,
})
