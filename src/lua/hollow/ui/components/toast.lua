-- Level icon beside a content column: optional title, message, and a row of
-- action buttons. The panel stays one click target; buttons are nested targets.
local c = require("hollow.ui.components")
local icons = require("hollow.ui.icons")
local props = require("hollow.ui.components.props")
local recipe = require("hollow.ui.recipes.notify")
local shared = require("hollow.ui.shared")
local sheet = require("hollow.ui.style.sheet")

local level_icons = {
  info = "notify_info",
  success = "notify_success",
  warn = "notify_warn",
  error = "notify_error",
}

local function icon_glyph(value, level)
  if value == false then
    return nil
  end
  if value == nil then
    value = level_icons[level] or "notify_info"
  end
  return icons[value] or value
end

-- `action` is the single-action shorthand for `actions`.
local function action_list(options)
  if options.actions then
    return options.actions
  end
  return options.action and { options.action } or {}
end

local function actions_row(actions, options, theme, cell_w)
  local buttons = c.each(actions, function(action, index)
    return c.button({
      id = options.id and (options.id .. ":action:" .. index),
      theme = theme,
      text = action.label or action.text,
      variant = action.kind or (index == 1 and "primary" or "default"),
      size = "sm",
      on_click = action.on_click or action.fn,
    })
  end)
  return c.row({ c.spacer(), buttons }, { width = "grow", gap = cell_w })
end

return function(value)
  local options = props.split(value)
  local theme, ctx = props.theme(options), props.ctx(options)
  local cell_w, cell_h = props.cell_w(ctx), props.cell_h(ctx)
  local level = options.level or "info"
  local variant = recipe.slots.message.variants[level] and level or nil
  local slots = recipe(theme, { variant = variant })
  local accent = shared.resolve_tokens(sheet.merge(slots.message, options.text_style), theme)
  local body = shared.resolve_tokens(slots.body, theme)
  local text = tostring(options.text or "")
  local title = options.title ~= "" and options.title or nil
  local glyph = icon_glyph(options.icon, level)
  local actions = action_list(options)

  local content = c.column({
    c.when(title ~= nil, function()
      return c.text(title, accent, { wrap = "none" })
    end),
    c.text(text, title and body or accent, { wrap = "none" }),
    c.when(#actions > 0, function()
      return {
        c.gap({ height = math.floor(cell_h * 0.5) }),
        actions_row(actions, options, theme, cell_w),
      }
    end),
  }, { width = "grow" })

  options.theme = theme
  options.inset = options.inset or "modal"
  options.label = options.label or (title and (title .. ": " .. text) or text)
  options.action, options.actions, options.title, options.icon = nil, nil, nil, nil
  options[1] = c.row({
    -- Nerd Font glyphs measure one cell but paint wider; reserve two.
    c.when(glyph ~= nil, function()
      return c.column(
        { c.text(glyph, { fg = accent.fg }, { wrap = "none" }) },
        { width = cell_w * 2 }
      )
    end),
    content,
  }, { gap = cell_w })
  return c.panel(options)
end
