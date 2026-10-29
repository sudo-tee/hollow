local shared = require("hollow.ui.shared")
local styles = require("hollow.ui.styles.notify")
local util = require("hollow.util")

---@type Hollow
local hollow = _G.hollow
local state = require("hollow.state").get()
---@type HollowUi
local ui = hollow.ui
local overlay_stack = state.ui.overlay_stack

ui.notify = ui.notify or {}

local function notification_style(theme, level)
  local variant = styles.slots.message.variants[level] and level or nil
  return styles(theme, { variant = variant }).message
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
  local activity_id = hollow.activity and hollow.activity._notification(message, opts)

  if opts.id ~= nil then
    for index = #overlay_stack, 1, -1 do
      local existing = overlay_stack[index]
      if
        existing
        and existing._kind == "overlay"
        and existing._notify == true
        and existing._notify_id == opts.id
      then
        ui.close_overlay_widget(existing)
      end
    end
  end

  local theme = shared.widget_theme("notify", opts.theme)
  local action = opts.action
  local level = opts.level or "info"
  local widget

  widget = ui.overlay.new({
    render = function()
      return ui.row({
        ui.text(notify_text(level, opts.title, message, action), notification_style(theme, level)),
      })
    end,
    align = opts.align or "top_right",
    chrome = opts.chrome or shared.theme_overlay_chrome(
      theme,
      theme.notify_levels[level] and ("notify_levels." .. level) or "title",
      2
    ),
    backdrop = opts.backdrop,
    on_key = function(key)
      if key == "escape" then
        if widget._activity_id then
          hollow.activity.dismiss(widget._activity_id)
        end
        ui.close_overlay_widget(widget)
        return true
      end

      return false
    end,
  })

  widget._palette = theme
  widget._notify = true
  widget._notify_id = opts.id
  widget._activity_id = activity_id
  ui.overlay.push(widget)

  local ttl = opts.ttl or 3000
  if type(ttl) == "number" and ttl > 0 then
    widget._expires_at = util.host_now_ms(state.host_api) + ttl
  end

  return widget
end

function ui.notify.clear(notification_id)
  if hollow.activity then
    hollow.activity._dismiss_notifications(notification_id)
  end
  for index = #overlay_stack, 1, -1 do
    local widget = overlay_stack[index]
    if
      widget
      and widget._kind == "overlay"
      and widget._notify == true
      and (notification_id == nil or widget._notify_id == notification_id)
    then
      ui.close_overlay_widget(widget)
    end
  end
end

-- Dismissal from the inbox also closes its toast; expiry only closes the overlay.
function ui.notify._dismiss_activity(id)
  for index = #overlay_stack, 1, -1 do
    local widget = overlay_stack[index]
    if widget._notify and widget._activity_id == id then
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
