local shared = require("hollow.ui.shared")

local hollow      = _G.hollow
local state       = require("hollow.state").get()
local overlay_stack = state.ui.overlay_stack

hollow.ui.notify = hollow.ui.notify or {}

function hollow.ui.notify.show(message, opts)
  opts = opts or {}
  local theme = shared.resolve_widget_theme("notify")
  if type(opts.theme) == "table" then
    require("hollow.util").merge_tables(theme, require("hollow.util").clone_value(opts.theme))
  end
  local title       = opts.title and (opts.title .. ": ") or ""
  local ttl         = opts.ttl
  local action      = opts.action
  local level_color = theme.notify_levels[opts.level or "info"] or theme.title
  local widget
  widget = hollow.ui.overlay.new({
    render = function()
      local t      = hollow.ui.tags
      local prefix = "[" .. string.upper(opts.level or "info") .. "] "
      local action_text = action and ("  [" .. action.label .. "]") or ""
      return {
        t.overlay_row(nil,
          t.group({ bg = theme.panel_bg },
            t.text({ fg = theme.notify_fg, bg = theme.panel_bg, bold = true },
              prefix .. title .. message .. action_text)
          )
        ),
      }
    end,
    align   = opts.align,
    chrome  = opts.chrome or { bg = theme.panel_bg, border = level_color },
    backdrop = opts.backdrop,
    on_key  = function(key, mods)
      if key == "escape" or key == "enter" then
        hollow.ui.close_overlay_widget(widget)
        if action and key == "enter" and type(action.fn) == "function" then action.fn() end
        return true
      end
      return false
    end,
  })
  widget._notify = true
  hollow.ui.overlay.push(widget)
  if type(ttl) == "number" and ttl > 0 then
    widget._expires_at = shared.monotonic_now_ms() + ttl
  end
  return widget
end

function hollow.ui.notify.clear()
  for i = #overlay_stack, 1, -1 do
    local w = overlay_stack[i]
    if w and w._kind == "overlay" and w._notify == true then
      hollow.ui.close_overlay_widget(w)
    end
  end
end

function hollow.ui.notify.info(message, opts)
  opts = opts or {}; opts.level = opts.level or "info"; return hollow.ui.notify.show(message, opts)
end
function hollow.ui.notify.warn(message, opts)
  opts = opts or {}; opts.level = opts.level or "warn"; return hollow.ui.notify.show(message, opts)
end
function hollow.ui.notify.error(message, opts)
  opts = opts or {}; opts.level = opts.level or "error"; return hollow.ui.notify.show(message, opts)
end
