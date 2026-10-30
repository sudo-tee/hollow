local box = require("hollow.ui.style.box")
local shared = require("hollow.ui.shared")
local styles = require("hollow.ui.recipes.notify")
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

local function notification_border(theme, level)
  local foreground = theme.notify_levels[level] or theme.title
  local background = theme.panel_bg
  local channels = {}
  for index = 2, 6, 2 do
    local fg = tonumber(foreground:sub(index, index + 1), 16)
    local bg = tonumber(background:sub(index, index + 1), 16)
    channels[#channels + 1] = math.floor(bg + (fg - bg) * 0.28 + 0.5)
  end
  return string.format("#%02x%02x%02x", unpack(channels))
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

-- Toasts sharing an anchor flow through one Clay column. Oldest stays nearest
-- the anchor; notification spacing remains independent of modal positioning.
local function toast_group(widget)
  local position
  for index, candidate in ipairs(overlay_stack) do
    if candidate == widget then
      position = index
      break
    end
  end
  if not position then
    return nil
  end
  for index = position + 1, #overlay_stack do
    local candidate = overlay_stack[index]
    if candidate._notify and candidate.align == widget.align then
      return nil
    end
  end
  local group = {}
  for index = position, 1, -1 do
    local candidate = overlay_stack[index]
    if candidate._notify and candidate.align == widget.align then
      group[#group + 1] = candidate
    end
  end
  return group
end

local function invalidate_toasts()
  for _, widget in ipairs(overlay_stack) do
    if widget._notify and widget._layout_surface then
      widget._layout_surface:invalidate()
    end
  end
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
    render = function(ctx)
      local children = {}
      local group = toast_group(widget) or {}
      for index = 1, #group do
        local toast = group[widget.align:find("bottom") and index or (#group - index + 1)]
        children[#children + 1] = toast._toast_render(ctx)
      end
      return ui.components.column(children, { gap = ctx.cell_h or 19 })
    end,
    on_unmount = invalidate_toasts,
    align = opts.align or "top_right",
    chrome = opts.chrome or shared.theme_overlay_chrome(theme, nil, 2),
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
  widget._layout_visible = function()
    return toast_group(widget) ~= nil
  end
  widget._toast_render = function(ctx)
    local text = notify_text(level, opts.title, message, action)
    local chrome = shared.normalize_overlay_chrome(widget.chrome, theme) or {}
    if not opts.chrome then
      chrome.border = notification_border(theme, level)
    end
    local padding = box.normalize(chrome.padding)
    local cell_w, cell_h = ctx.cell_w or 8, ctx.cell_h or 19
    padding.left, padding.right = padding.left + cell_w * 1.5, padding.right + cell_w * 1.5
    padding.top, padding.bottom = padding.top + cell_h, padding.bottom + cell_h * 0.5
    return ui.components.column(
      { ui.components.text(text, notification_style(theme, level), { wrap = "none" }) },
      {
        id = "notify:" .. tostring(widget._toast_id),
        label = text,
        padding = padding,
        style = chrome,
        on_click = function()
          if action and type(action.fn) == "function" then
            action.fn()
          end
          if widget._activity_id then
            hollow.activity.dismiss(widget._activity_id)
          end
          ui.close_overlay_widget(widget)
        end,
      }
    )
  end
  ui.notify._next_toast_id = (ui.notify._next_toast_id or 0) + 1
  widget._toast_id = ui.notify._next_toast_id
  ui.overlay.push(widget)
  widget._layout_surface.frame.margin =
    box.normalize((shared.normalize_overlay_chrome(widget.chrome, theme) or {}).margin)
  invalidate_toasts()

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
