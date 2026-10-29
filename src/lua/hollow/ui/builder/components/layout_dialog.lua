-- Clay-backed composition; behavior stays with the modal and navigation helpers.
local button_styles = require("hollow.ui.styles.button")
local color = require("hollow.color")
local layout = _G.hollow.ui.layout
local variants = { default = true, primary = true, destructive = true }

return function(opts, theme, ctx)
  local cell_w, cell_h = ctx.cell_w or 8, ctx.cell_h or 19
  local palette = setmetatable({
    button_emphasis_bg = theme.button_emphasis_bg
      or color.brighten_hex_color(theme.selected_bg, 0.25, theme.panel_bg),
  }, { __index = theme })
  local buttons = { layout.column({}, { width = "grow" }) }
  for index, button in ipairs(opts.footer) do
    local style = button_styles(palette, {
      variant = variants[button.kind] and button.kind or "default",
      selected = opts.selected == index,
      hovered = opts.hovered == index,
    }).dialog
    style.radius = theme.radius
    buttons[#buttons + 1] = layout.column({ layout.text(button.text, style) }, {
      id = button.id,
      label = button.text,
      on_click = button.on_click,
      padding = { x = cell_w },
      style = style,
    })
  end
  local children = {}
  if opts.title and opts.title ~= "" then
    children[#children + 1] = layout.text(opts.title, { fg = theme.title, bold = true })
    children[#children + 1] = layout.column(
      {},
      { width = "grow", height = 1, style = { bg = theme.divider } }
    )
  end
  children[#children + 1] = layout.text(opts.prompt, { fg = theme.fg })
  children[#children + 1] = layout.column({}, { height = cell_h })
  children[#children + 1] = layout.row(buttons, { width = "grow", gap = cell_w * 2 })
  return layout.column(children, { width = "grow" })
end
