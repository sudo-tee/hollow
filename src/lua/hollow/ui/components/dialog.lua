-- Clay-backed composition; behavior stays with the modal and navigation helpers.
local button_styles = require("hollow.ui.recipes.button")
local c = require("hollow.ui.components")
local color = require("hollow.color")
local variants = { default = true, primary = true, destructive = true }

return function(opts, theme, ctx)
  local cell_w, cell_h = ctx.cell_w or 8, ctx.cell_h or 19
  local children = {}
  children[#children + 1] = opts.body or c.text(opts.prompt, { fg = theme.fg })
  if opts.footer and #opts.footer > 0 then
    local palette = setmetatable({
      button_emphasis_bg = theme.button_emphasis_bg
        or color.brighten_hex_color(theme.selected_bg, 0.25, theme.panel_bg),
    }, { __index = theme })
    local buttons = { c.column({}, { width = "grow" }) }
    for index, button in ipairs(opts.footer) do
      local style = button_styles(palette, {
        variant = variants[button.kind] and button.kind or "default",
        selected = opts.selected == index,
        hovered = opts.hovered == index,
      }).dialog
      style.radius = theme.radius
      style.hover = {
        bg = button_styles(palette, {
          variant = variants[button.kind] and button.kind or "default",
          selected = opts.selected == index,
          hovered = true,
        }).dialog.bg,
      }
      buttons[#buttons + 1] = c.column({ c.text(button.text, style, { wrap = "none" }) }, {
        id = button.id,
        label = button.text,
        on_click = button.on_click,
        padding = { x = cell_w },
        style = style,
      })
    end
    children[#children + 1] = c.column({}, { height = cell_h })
    children[#children + 1] = c.row(buttons, { width = "grow", gap = cell_w * 2 })
  end
  local content = c.column(children, { width = "grow" })
  if not opts.title or opts.title == "" then
    return content
  end
  return c.column({
    c.text(opts.title, { fg = theme.title, bold = true }),
    content,
  }, {
    width = "grow",
    gap = math.floor(cell_h * 0.5),
    border_width = { between_children = 1 },
    style = { border = theme.divider },
  })
end
