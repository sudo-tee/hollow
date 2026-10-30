-- One row, two nodes per tab, plus two per optional painted badge.
local c = require("hollow.ui.components")
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")
local sheet = require("hollow.ui.style.sheet")
local tab_recipe = require("hollow.ui.recipes.tab")

return function(opts)
  opts = opts or {}
  local theme = opts.theme or props.scope().theme
  local children = {}
  for _, tab in ipairs(opts.tabs or {}) do
    assert(type(tab.id) == "string" and tab.id ~= "", "tab requires an id")
    local style = shared.resolve_tokens(
      sheet.merge(tab_recipe(theme, { selected = tab.id == opts.active }).root, tab.style),
      theme
    )
    local content = { c.text(tab.label, style, { wrap = "none" }) }
    if tab.badge ~= nil then
      local badge = type(tab.badge) == "table" and tab.badge or { text = tab.badge }
      content[#content + 1] = c.badge({ text = badge.text, color = badge.color, theme = theme })
    end
    local callback
    if not opts.disabled and not tab.disabled and type(opts.on_select) == "function" then
      local id = tab.id
      callback = function()
        opts.on_select(id)
      end
    end
    children[#children + 1] = c.row(content, {
      id = tab.id,
      label = tab.label,
      role = "button",
      gap = tab.badge ~= nil and 4 or nil,
      style = style,
      on_click = callback,
    })
  end
  local root = {}
  for key, value in pairs(opts) do
    root[key] = value
  end
  root.on_click = not opts.disabled and opts.on_click or nil
  return c.row(children, root)
end
