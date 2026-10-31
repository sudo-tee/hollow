-- Clay-backed composition; behavior stays with the modal and navigation helpers.
local c = require("hollow.ui.components")
local color = require("hollow.color")
local props = require("hollow.ui.components.props")
local variants = { default = true, primary = true, destructive = true }

return function(opts, theme, ctx)
  opts = opts or {}
  local positional = theme ~= nil or ctx ~= nil
  if not positional then
    local scope = props.scope()
    theme, ctx = opts.theme or scope.theme, scope.ctx
  end
  ctx = ctx or {}
  local cell_w, cell_h = props.cell_w(ctx), props.cell_h(ctx)
  local children = {}
  local body = opts.body
  if type(body) == "string" then
    body = c.text(body, { fg = theme.fg })
  end
  children[#children + 1] = body or c.text(opts.prompt, { fg = theme.fg })
  local actions = opts.actions or opts.footer
  if actions and #actions > 0 then
    local palette = setmetatable({
      button_emphasis_bg = theme.button_emphasis_bg
        or color.brighten_hex_color(theme.selected_bg, 0.25, theme.panel_bg),
    }, { __index = theme })
    local buttons = { c.column({}, { width = "grow" }) }
    for index, button in ipairs(actions) do
      local id = button.id or (opts.id and (opts.id .. ":action:" .. index))
      local node = c.button({
        appearance = "quiet",
        theme = palette,
        variant = variants[button.kind] and button.kind or "default",
        selected = opts.selected == index or (id ~= nil and opts.selected == id),
        hovered = opts.hovered == index,
        id = id,
        text = button.text,
        on_click = button.on_click,
        disabled = button.disabled,
        padding = { x = cell_w },
        style = { radius = theme.radius },
      })
      node.style.radius = theme.radius
      buttons[#buttons + 1] = node
    end
    children[#children + 1] = c.column({}, { height = cell_h })
    children[#children + 1] = c.row(buttons, { width = "grow", gap = cell_w * 2 })
  end
  local content_options = { width = "grow" }
  if not positional and (not opts.title or opts.title == "") then
    for key, value in pairs(opts) do
      content_options[key] = value
    end
    content_options.width = content_options.width or "grow"
    if opts.disabled then
      content_options.on_click = nil
    end
  end
  local content = c.column(children, content_options)
  if not opts.title or opts.title == "" then
    return content
  end
  local root = not positional
      and {
        id = opts.id,
        label = opts.label,
        role = opts.role,
        width = opts.width,
        height = opts.height,
        min_width = opts.min_width,
        max_width = opts.max_width,
        min_height = opts.min_height,
        max_height = opts.max_height,
        padding = opts.padding,
        style = opts.style,
        on_click = not opts.disabled and opts.on_click or nil,
      }
    or {}
  root[1], root[2] = c.text(opts.title, { fg = theme.title, bold = true }), content
  root.theme, root.divided = theme, true
  root.width = root.width or "grow"
  root.gap = not positional and (opts.gap or math.floor(cell_h * 0.5)) or math.floor(cell_h * 0.5)
  return c.stack(root)
end
