-- Optional title over a divided content column of body and right-aligned quiet
-- buttons. Behavior stays with the modal and navigation helpers.
local c = require("hollow.ui.components")
local color = require("hollow.color")
local props = require("hollow.ui.components.props")
local variants = { default = true, primary = true, destructive = true }

local function actions_row(opts, theme, cell_w)
  local palette = setmetatable({
    button_emphasis_bg = theme.button_emphasis_bg
      or color.brighten_hex_color(theme.selected_bg, 0.25, theme.panel_bg),
  }, { __index = theme })
  local buttons = c.each(opts.actions, function(action, index)
    local id = action.id or (opts.id and (opts.id .. ":action:" .. index))
    local node = c.button({
      appearance = "quiet",
      theme = palette,
      variant = variants[action.kind] and action.kind or "default",
      selected = opts.selected == index or (id ~= nil and opts.selected == id),
      hovered = opts.hovered == index,
      id = id,
      text = action.text,
      on_click = action.on_click,
      disabled = action.disabled,
      padding = { x = cell_w },
    })
    -- Dialog buttons follow the theme radius, square when it is unset.
    node.style.radius = theme.radius
    return node
  end)
  return c.row({ c.spacer(), buttons }, { width = "grow", gap = cell_w * 2 })
end

return function(value)
  local opts = props.split(value)
  local theme, ctx = props.theme(opts), props.ctx(opts)
  local cell_w, cell_h = props.cell_w(ctx), props.cell_h(ctx)
  local body = opts.body
  if body == nil or type(body) == "string" then
    body = c.text(body, { fg = theme.fg })
  end
  local has_actions = opts.actions and #opts.actions > 0
  local children = {
    body,
    c.when(has_actions, function()
      return { c.gap({ height = cell_h }), actions_row(opts, theme, cell_w) }
    end),
  }
  opts.width = opts.width or "grow"
  if not opts.title or opts.title == "" then
    return c.column(children, opts)
  end
  opts[1] = c.text(opts.title, { fg = theme.title, bold = true })
  opts[2] = c.column(children, { width = "grow" })
  opts.divided = true
  opts.gap = opts.gap or math.floor(cell_h * 0.5)
  opts.theme = theme
  return c.stack(opts)
end
