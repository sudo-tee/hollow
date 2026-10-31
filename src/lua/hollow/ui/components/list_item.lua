-- Two shell nodes, plus one when an accent is painted; detail adds a column and
-- one text node. User content nodes are excluded.
local box = require("hollow.ui.style.box")
local c = require("hollow.ui.components")
local list_row = require("hollow.ui.recipes.list_row")
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")
local sheet = require("hollow.ui.style.sheet")
local M = {}

local function text_content(node, parts, depth)
  if type(node) ~= "table" or depth > 32 then
    return
  end
  if node.kind == 2 then
    parts[#parts + 1] = node.text or ""
    return
  end
  local children = node.kind ~= nil and node.children or node
  for index = 1, table.maxn(children or {}) do
    text_content(children[index], parts, depth + 1)
  end
end

local function gutter(color, radius)
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

local function render(value)
  local options, children = props.split(value)
  local theme = props.theme(options)
  local paint = list_row(theme, options).paint
  local style = shared.resolve_tokens(
    sheet.merge({
      bg = paint.fill_bg,
      radius = paint.fill_radius,
      hover = {
        bg = list_row(theme, { selected = options.selected, hovered = true }).paint.fill_bg,
      },
    }, options.style),
    theme
  )
  local accent = paint.accent_bar
  if options.accent == true then
    accent = paint.accent_bar or theme.panel_border
  elseif options.accent ~= nil then
    accent = options.accent
  end
  if accent then
    accent = shared.resolve_tokens({ bg = accent }, theme).bg
  end
  if options.label == nil then
    local parts = {}
    text_content(children, parts, 0)
    if #parts > 0 then
      options.label = table.concat(parts)
      if type(options.detail) == "string" and options.detail ~= "" then
        options.label = options.label .. "\n" .. options.detail
      end
    end
  end
  options.role = options.role or "listitem"
  options.width = options.width or "grow"
  options.style = style
  options.on_click = not options.disabled and (options.on_activate or options.on_click) or nil
  if options.detail ~= nil then
    local detail = type(options.detail) == "table" and options.detail
      or c.label({ text = options.detail, tone = "muted", theme = theme })
    children = { c.column({ children, detail }, { width = "grow" }) }
  end
  return c.row({ gutter(accent, style.radius), children }, options)
end

--- Height of one list line: cell height plus the row indicator padding.
---@param theme? HollowUiTheme
---@param ctx? HollowUiLayoutContext
---@return number
function M.line_height(theme, ctx)
  local padding = box.normalize(list_row(theme or props.theme()).indicator.padding)
  return props.cell_h(ctx) + padding.top + padding.bottom
end

return setmetatable(M, {
  __call = function(_, value)
    return render(value)
  end,
})
