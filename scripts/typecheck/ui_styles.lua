-- EmmyLua Rust authoring fixture. Not an application module or runtime test.
---@param ui HollowUi
---@param palette HollowUiTheme
---@param styles table<string, HollowUiNodeStyle>
---@param color HollowColorModule
---@param sheet HollowUiStylesheet
local function check(ui, palette, styles, color, sheet)
  ---@type HollowUiNodeStyle
  local base = {
    fg = "muted",
    padding = { 1.5, 8 },
    margin = { x = 2.5 },
    hover = { fg = "hover_fg", bg = "hover_bg" },
  }
  ---@type HollowUiNodeStyle
  local merged = ui.style(base, false, nil, { bg = false, padding = { right = 0 }, hover = false })
  ---@type HollowUiSpanNode
  local text = ui.text("Name", styles.name)
  ---@type HollowUiGroupNode
  local group = ui.text(ui.group({ text }))
  ---@type HollowUiNodeStyle
  local themed = ui.styled(palette, merged)
  ---@type HollowUiSpanNode
  local button =
    ui.button({ id = "typed:button", variant = "primary", size = "sm", theme = palette })
  ---@type HollowUiRowOptions
  local row = {
    style = { fg = false, bg = "panel_bg", hover = false },
    accent_bar = false,
    scrollbar_track_color = false,
  }
  ---@type HollowUiColorPair
  local colors = { fg = "fg", bg = "panel_bg" }
  ---@type string|nil
  local hex = color.brighten_hex_color("#123456", 0.2, nil)
  -- EmmyLua widens a generic boolean fallback to boolean, not a literal false.
  ---@type string|boolean|nil
  local suppressed = color.brighten_hex_color(false, 0.2, false)
  local view = sheet(palette, { selected = true })
  ---@type HollowUiNodeStyle
  local label = view.label
  ---@type HollowUiNodeStyle
  local detail = ui.style(view.detail, { fg = "#ff0000", bold = true })
  return { group, themed, button, row, colors, hex, suppressed, label, detail }
end

return check
