-- Shared disclosure row for palette categories and grouped selectors.
local c = require("hollow.ui.components")
local icons = require("hollow.ui.icons")
local list_row = require("hollow.ui.recipes.list_row")
local props = require("hollow.ui.components.props")
local rich = require("hollow.ui.components.rich")
local ui = _G.hollow.ui
local M = {}

local function title_nodes(options, theme)
  local styles =
    list_row(theme, { variant = "section", selected = options.selected, hovered = options.hovered })
  local arrow = options.collapsed and icons.collapsed or icons.expanded
  return {
    -- ui.text(" ", styles.section_indicator),
    ui.text(
      arrow .. " " .. (options.text or options.label),
      ui.style(
        options.title_style or styles.section_title,
        options.colors and { fg = options.colors.fg }
      )
    ),
  }
end

---@param theme HollowUiTheme
---@param ctx HollowUiLayoutContext
---@param title_style? HollowUiNodeStyle
---@return number
function M.height(theme, ctx, title_style)
  return rich.height(title_nodes({ label = "", title_style = title_style }, theme), ctx)
end

return setmetatable(M, {
  __call = function(_, value)
    local options, trailing = props.split(value)
    local theme = props.theme(options)
    local title = c.rich({
      width = "grow",
      prefix = options.id,
      plain = options.plain,
      title_nodes(options, theme),
    })
    local content = title
    if #trailing > 0 then
      content = c.row({ title, trailing }, { width = "grow", align_y = "center" })
    end
    -- Flat headers drop the section fill and read as colored titles.
    options.variant, options.theme = options.flat and "selectable" or "section", theme
    options.flat = nil
    options.style = ui.style(options.style, options.colors and { bg = options.colors.bg })
    options[1] = content
    return c.list_item(options)
  end,
})
