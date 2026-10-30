-- Clay node constructors and composed components, exposed as `hollow.ui.components`.
-- Render trees are built here and mounted by `hollow.ui.layout` surfaces.
---@type HollowUi
local ui = _G.hollow.ui
---@type HollowUiComponents
local M = {}

-- Composites require this module, so they load on first access.
local lazy = {
  dialog = "hollow.ui.components.dialog",
  input = "hollow.ui.components.input",
  select = "hollow.ui.components.select",
}
setmetatable(M, {
  __index = function(self, key)
    local path = lazy[key]
    if path then
      local value = require(path)
      rawset(self, key, value)
      return value
    end
  end,
})

---@param kind integer
---@param children table|nil
---@param opts HollowUiLayoutOptions|nil
---@return HollowUiLayoutNode
local function container(kind, children, opts)
  opts = opts or {}
  return {
    kind = kind,
    children = children or {},
    id = opts.id,
    label = opts.label,
    role = opts.role,
    width = opts.width,
    height = opts.height,
    min_width = opts.min_width,
    max_width = opts.max_width,
    min_height = opts.min_height,
    max_height = opts.max_height,
    border_width = opts.border_width,
    gap = opts.gap,
    padding = opts.padding,
    style = opts.style,
    scroll = opts.scroll,
    scroll_x = opts.scroll_x,
    scrollbar_id = opts.scrollbar_id,
    scrollbar_thumb_ratio = opts.scrollbar_thumb_ratio,
    scrollbar_thumb_size = opts.scrollbar_thumb_size,
    scrollbar_track_color = opts.scrollbar_track_color,
    scrollbar_thumb_color = opts.scrollbar_thumb_color,
    reveal = opts.reveal,
    reveal_start = opts.reveal_start,
    measure = opts.measure,
    align_y = opts.align_y,
    on_click = opts.on_click,
  }
end

---@param children table
---@param opts HollowUiLayoutOptions|nil
---@return HollowUiLayoutNode
function M.row(children, opts)
  return container(1, children, opts)
end
---@param children table
---@param opts HollowUiLayoutOptions|nil
---@return HollowUiLayoutNode
function M.column(children, opts)
  return container(0, children, opts)
end
---@param text any
---@param style HollowUiNodeStyle|nil
---@param opts HollowUiLayoutTextOptions|nil
---@return HollowUiLayoutNode
function M.text(text, style, opts)
  return {
    kind = 2,
    text = tostring(text or ""),
    style = style,
    wrap = opts and opts.wrap,
    text_align = opts and opts.text_align,
  }
end

-- Custom-paint demonstration; not an arbitrary Lua drawing API.
---@param value number
---@param opts HollowUiLayoutOptions|nil
---@return HollowUiLayoutNode
function M.progress(value, opts)
  local node = container(3, {}, opts)
  node.value = value
  return node
end

---@param opts HollowUiButtonOptions|nil
---@return HollowUiLayoutNode
function M.button(opts)
  opts = opts or {}
  local span = ui.button(opts)
  return M.column({ M.text(span.text, { fg = span.style.fg, bold = span.style.bold }) }, {
    id = opts.id,
    label = span.text,
    style = span.style,
    on_click = not opts.disabled and opts.on_click or nil,
  })
end

function M.demo()
  return require("hollow.ui.components.demo").open()
end

ui.components = M
return M
