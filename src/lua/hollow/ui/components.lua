-- Clay node constructors and composed components, exposed as `hollow.ui.components`.
-- Render trees are built here and mounted by `hollow.ui.layout` surfaces.
---@type HollowUi
local ui = _G.hollow.ui
local props = require("hollow.ui.components.props")
---@type HollowUiComponents
local M = {}

-- Composites require this module, so they load on first access.
local lazy = {
  badge = "hollow.ui.components.badge",
  dialog = "hollow.ui.components.dialog",
  empty = "hollow.ui.components.empty",
  header = "hollow.ui.components.header",
  hints = "hollow.ui.components.hints",
  icon = "hollow.ui.components.icon",
  input = "hollow.ui.components.input",
  kbd = "hollow.ui.components.kbd",
  label = "hollow.ui.components.label",
  list = "hollow.ui.components.list",
  list_item = "hollow.ui.components.list_item",
  panel = "hollow.ui.components.panel",
  picker = "hollow.ui.components.picker",
  pill = "hollow.ui.components.pill",
  rich = "hollow.ui.components.rich",
  scroll = "hollow.ui.components.scroll",
  stack = "hollow.ui.components.stack",
  tabs = "hollow.ui.components.tabs",
  title = "hollow.ui.components.title",
  toast = "hollow.ui.components.toast",
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
    on_click = not opts.disabled and opts.on_click or nil,
  }
end

---@param children table
---@param opts HollowUiLayoutOptions|nil
---@return HollowUiLayoutNode
function M.row(children, opts)
  opts, children = props.split(children, opts)
  return container(1, children, opts)
end
---@param children table
---@param opts HollowUiLayoutOptions|nil
---@return HollowUiLayoutNode
function M.column(children, opts)
  opts, children = props.split(children, opts)
  return container(0, children, opts)
end
---@param text any
---@param style HollowUiNodeStyle|nil
---@param opts HollowUiLayoutTextOptions|nil
---@return HollowUiLayoutNode
function M.text(text, style, opts)
  if type(text) == "table" and style == nil and opts == nil then
    local p = text
    text, style, opts = p.text or p[1], p.style, p
  end
  return {
    kind = 2,
    text = tostring(text or ""),
    style = style,
    wrap = opts and opts.wrap,
    text_align = opts and opts.text_align,
  }
end

-- Each spacer or gap contributes one container node.
function M.spacer()
  return M.column({}, { width = "grow" })
end

function M.gap(value)
  if type(value) == "table" then
    return M.column({}, value)
  end
  return M.column({}, { width = value })
end

M.when, M.each, M.join = ui.when, ui.each, ui.join

-- Custom-paint demonstration; not an arbitrary Lua drawing API.
---@param value number
---@param opts HollowUiLayoutOptions|nil
---@return HollowUiLayoutNode
function M.progress(value, opts)
  local node = container(3, {}, opts)
  node.value = value
  return node
end

-- Two nodes: a painted container and its text. `appearance = "quiet"` uses the
-- `dialog` slot (text-colored until hovered or selected); `"solid"` uses `root`.
---@param value HollowUiButtonOptions|nil
---@return HollowUiLayoutNode
function M.button(value)
  local opts = props.split(value)
  local appearance = opts.appearance or "solid"
  assert(appearance == "solid" or appearance == "quiet", "unknown button appearance")
  local theme = props.theme(opts)
  local recipe = require("hollow.ui.recipes.button")
  local slot = appearance == "quiet" and "dialog" or "root"
  local style = recipe(theme, opts)[slot]
  if appearance == "quiet" then
    local hover = recipe(theme, {
      variant = opts.variant,
      size = opts.size,
      selected = opts.selected,
      hovered = true,
    })[slot]
    style.hover = { fg = hover.fg, bg = hover.bg }
  end
  style = ui.styled(theme, style, opts.style)
  if opts.disabled then
    style.hover = nil
  end
  opts.label = opts.label or opts.text or ""
  opts.style = style
  return M.column(
    { M.text(opts.text, { fg = style.fg, bold = style.bold }, { wrap = "none" }) },
    opts
  )
end

function M.demo()
  return require("hollow.ui.components.demo").open()
end

ui.components = M
return M
