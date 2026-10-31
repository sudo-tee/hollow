-- One row plus inline runs; painted runs need a container, and a spacer
-- splits the content into two additional rows for left/right alignment.
local box = require("hollow.ui.style.box")
local c = require("hollow.ui.components")
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")
local util = require("hollow.util")

return function(children, style, opts)
  if style == nil and opts == nil then
    opts, children = props.split(children)
    style = opts.style
  end
  opts = opts or {}
  local flat = shared.flatten_span_nodes(children, style)
  if #flat > 32 then
    return c.row({ c.text(shared.nodes_plain_text(children), style, { wrap = "none" }) }, opts)
  end
  local runs = {}
  local spacer
  for index, span in ipairs(flat) do
    if span.spacer then
      runs[#runs + 1] = c.column({}, { width = "grow" })
      spacer = spacer or #runs
    else
      local text = c.text(span.text, span.style, { wrap = "none" })
      local paint = span.style or {}
      if
        paint.bg
        or paint.border
        or paint.radius
        or type(paint.on_click) == "function"
        or not box.is_empty(box.normalize(paint.padding))
      then
        text = c.column({ text }, {
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
    return c.row({
      c.row(left, { width = "grow", scroll_x = true, align_y = opts.align_y }),
      c.row(right, { align_y = opts.align_y }),
    }, opts)
  end
  return c.row(runs, opts)
end
