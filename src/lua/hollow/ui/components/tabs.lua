-- One row, two nodes per tab, plus two per optional painted badge.
local c = require("hollow.ui.components")
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")
local sheet = require("hollow.ui.style.sheet")
local tab_recipe = require("hollow.ui.recipes.tab")

return function(value)
  local opts = props.split(value)
  local theme = props.theme(opts)
  return c.row(
    c.each(opts.tabs, function(tab)
      assert(type(tab.id) == "string" and tab.id ~= "", "tab requires an id")
      local style = shared.resolve_tokens(
        sheet.merge(tab_recipe(theme, { selected = tab.id == opts.active }).root, tab.style),
        theme
      )
      local badge = type(tab.badge) == "table" and tab.badge or { text = tab.badge }
      local selectable = not opts.disabled
        and not tab.disabled
        and type(opts.on_select) == "function"
      return c.row({
        c.text(tab.label, style, { wrap = "none" }),
        c.when(tab.badge ~= nil, function()
          return c.badge({ text = badge.text, color = badge.color, theme = theme })
        end),
      }, {
        id = tab.id,
        label = tab.label,
        role = "button",
        gap = tab.badge ~= nil and 4 or nil,
        style = style,
        on_click = selectable and function()
          opts.on_select(tab.id)
        end or nil,
      })
    end),
    opts
  )
end
