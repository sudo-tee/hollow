local shared = require("hollow.ui.shared")
local util = require("hollow.util")

---@type Hollow
local hollow = _G.hollow
local state = require("hollow.state").get()
---@type HollowUi
local ui = hollow.ui
local overlay_stack = state.ui.overlay_stack

ui.notify = ui.notify or {}

---@param theme HollowUiTheme
---@param opts HollowUiNotifyOptions
---@return HollowUiTheme
local function merged_theme(theme, opts)
  if type(opts.theme) ~= "table" then
    return theme
  end

  util.merge_tables(theme, util.clone_value(opts.theme))
  return theme
end

---@param level string|nil
---@param title string|nil
---@param message string
---@param action HollowUiNotifyAction|nil
---@return string
local function notify_text(level, title, message, action)
  local prefix = "[" .. string.upper(level or "info") .. "] "
  local title_text = title and (title .. ": ") or ""
  local action_text = action and ("  [" .. action.label .. "]") or ""
  return prefix .. title_text .. message .. action_text
end

---@param message string
---@param opts HollowUiNotifyOptions|nil
---@return HollowUiWidget
function ui.notify.show(message, opts)
  opts = opts or {}

  local theme = merged_theme(shared.resolve_widget_theme("notify"), opts)
  local action = opts.action
  local level = opts.level or "info"
  local level_color = theme.notify_levels[level] or theme.title
  local widget

  widget = ui.overlay.new({
    render = function()
      ---@type HollowUiTags
      local tags = ui.tags
      return {
        tags.overlay_row(
          nil,
          tags.group(
            { bg = theme.panel_bg },
            tags.text(
              { fg = theme.notify_fg, bg = theme.panel_bg, bold = true },
              notify_text(level, opts.title, message, action)
            )
          )
        ),
      }
    end,
    align = opts.align or "top_right",
    chrome = opts.chrome or { bg = theme.panel_bg, border = level_color },
    backdrop = opts.backdrop,
    on_key = function(key)
      if key ~= "escape" and key ~= "enter" then
        return false
      end

      ui.close_overlay_widget(widget)
      if action and key == "enter" and type(action.fn) == "function" then
        action.fn()
      end
      return true
    end,
  })

  widget._notify = true
  ui.overlay.push(widget)

  if type(opts.ttl) == "number" and opts.ttl > 0 then
    widget._expires_at = shared.monotonic_now_ms() + opts.ttl
  end

  return widget
end

function ui.notify.clear()
  for index = #overlay_stack, 1, -1 do
    local widget = overlay_stack[index]
    if widget and widget._kind == "overlay" and widget._notify == true then
      ui.close_overlay_widget(widget)
    end
  end
end

---@param level string
---@return fun(message:string, opts:HollowUiNotifyOptions|nil):HollowUiWidget
local function level_notifier(level)
  return function(message, opts)
    opts = opts or {}
    opts.level = opts.level or level
    return ui.notify.show(message, opts)
  end
end

ui.notify.info = level_notifier("info")
ui.notify.warn = level_notifier("warn")
ui.notify.error = level_notifier("error")
