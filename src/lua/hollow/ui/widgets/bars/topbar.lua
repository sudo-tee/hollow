local attention = require("hollow.ui.widgets.attention")
local hidden_panes = require("hollow.ui.widgets.hidden_panes")
local shared = require("hollow.ui.shared")
local styles = require("hollow.ui.recipes.topbar")
local hollow = _G.hollow
local state = require("hollow.state").get()
local ui = hollow.ui
local tbl = hollow.tbl
local util = hollow.util
local M = {}
local DEFAULT_NEW_TAB_TEXT = "+"
local DEFAULT_SHIFTED_NEW_TAB_TEXT = ""
local DEFAULT_SPLIT_RIGHT_TEXT = "" -- Codicon split-horizontal: side-by-side panes.
local DEFAULT_SPLIT_DOWN_TEXT = "" -- Codicon split-vertical: stacked panes.
local RIGHT_GROUP_GAP = 8
local TOOLTIP_DELAY_MS = 500
local tooltip_ticket, tooltip = 0, nil
local DEFAULT_TOPBAR_LAYOUT = {
  padding = { left = 1, right = 1, top = 1, bottom = 1 },
}

function M.resolved_theme()
  return shared.resolve_topbar_theme()
end

---@param value any
---@return table|nil
local function optional_table(value)
  return type(value) == "table" and value or nil
end

---@param value any
---@return table
local function clone_table(value)
  return util.clone_value(type(value) == "table" and value or {})
end

---@param base table|nil
---@param overlay table|nil
---@return table
function M.merge_tables(base, overlay)
  local result = clone_table(base)
  if type(overlay) == "table" then
    util.merge_tables(result, overlay)
  end
  return result
end

---@param value any
---@return HollowUiRenderableNode|nil
local function configured_topbar_separator(value)
  if value == false then
    return nil
  end
  if type(value) == "string" then
    return ui.span(value)
  end
  if type(value) ~= "table" then
    return nil
  end

  local text = value.text
  if text == nil then
    text = value.value
  end
  if text == nil then
    return nil
  end

  value.style = M.merge_tables(styles(shared.bar_palette()).divider, value.style)
  return ui.text(text, value.style)
end

---@param ctx HollowWidgetCtx
---@param value any
---@return HollowUiRenderableNode|nil
local function configured_topbar_cwd(ctx, value)
  if value == false then
    return nil
  end

  local pane = ctx.term.pane
  local text = pane and pane.cwd or ""
  local style = nil
  if type(value) == "table" then
    style = value.style
    if type(value.format) == "function" then
      local ok, result = pcall(value.format, pane, ctx)
      if ok then
        text = result
      end
    end
  end

  if text == nil or text == "" then
    return nil
  end
  if type(text) == "string" then
    text = " " .. text .. " "
  end
  return ui.text(text, style)
end

---@param value any
---@return table|false
local function configured_topbar_bar_opts(value)
  if value == false then
    return false
  end
  return type(value) == "table" and value or {}
end

local function dismiss_tooltip()
  tooltip_ticket = tooltip_ticket + 1
  if tooltip then
    tooltip = nil
    ui.request_redraw()
  end
end

local function shortcut_hint(action)
  local bindings = hollow.keymap.find_by_action(action)
  table.sort(bindings, function(a, b)
    return #a < #b or (#a == #b and a < b)
  end)
  return bindings[1]
end

function M.with_tooltip(node, options, label, action)
  local text = options.tooltip
  if text == nil or text == true then
    text = label
  end
  if type(text) ~= "function" and (type(text) ~= "string" or text == "") then
    return node
  end
  local click = node.on_click
  node.on_click = function(event)
    dismiss_tooltip()
    click(event)
  end
  node.on_mouse_leave = dismiss_tooltip
  node.on_mouse_enter = function()
    dismiss_tooltip()
    local ticket = tooltip_ticket
    local mounted = state.ui.mounted_topbar
    state.host_api.defer(function()
      if
        tooltip_ticket == ticket
        and state.ui.topbar_hovered_id == node.id
        and state.ui.mounted_topbar == mounted
      then
        tooltip = {
          id = node.id,
          text = text,
          action = options.tooltip_shortcut ~= false and action,
          mounted = mounted,
        }
        ui.request_redraw()
      end
    end, TOOLTIP_DELAY_MS)
  end
  return node
end

function ui._topbar_tooltip()
  if
    not tooltip
    or state.ui.mounted_topbar ~= tooltip.mounted
    or state.ui.topbar_hovered_id ~= tooltip.id
  then
    return nil
  end
  for _, widget in ipairs(state.ui.overlay_stack) do
    if widget._modal then
      dismiss_tooltip()
      return nil
    end
  end
  local action = tooltip.action
  if type(action) == "function" then
    action = action()
  end
  local palette = shared.palette("overlay")
  return {
    id = tooltip.id,
    text = type(tooltip.text) == "function" and tooltip.text() or tooltip.text,
    shortcut = action and shortcut_hint(action) or nil,
    bg = palette.bg,
    fg = palette.fg,
    shortcut_fg = shared.palette("select").panel_border,
  }
end

local function configured_topbar_new_tab(value)
  if value == false then
    return nil
  end

  local options = type(value) == "table" and value or {}
  local id = options.id or "new-tab-button"
  local s = styles(shared.bar_palette())
  local style = M.merge_tables(s.new_tab, options.style)
  style.id = id

  return M.with_tooltip(
    ui.bar.custom({
      id = id,
      style = style,
      render = function()
        local shifted = state.ui.topbar_hovered_id == id and state.ui.topbar_hovered_shifted
        if shifted then
          return options.shifted_text or DEFAULT_SHIFTED_NEW_TAB_TEXT
        end
        return options.text or DEFAULT_NEW_TAB_TEXT
      end,
      on_click = function(event)
        if event and event.shifted then
          hollow.action.new_tab_in_domain({ insert_at_end = true })
        else
          hollow.action.new_tab({ insert_at_end = true })
        end
      end,
    }),
    options,
    function()
      return state.ui.topbar_hovered_shifted and "New tab in a different domain" or "New tab"
    end,
    function()
      return state.ui.topbar_hovered_shifted and "new_tab_in_domain" or "new_tab"
    end
  )
end

local function configured_topbar_button(value, id, text, on_click, recipe, label, action)
  if value ~= true and type(value) ~= "table" then
    return false
  end

  local options = type(value) == "table" and value or {}
  id = options.id or id
  local style = M.merge_tables(styles(shared.bar_palette())[recipe or "new_tab"], options.style)
  style.id = id

  return M.with_tooltip(
    ui.bar.custom({
      id = id,
      style = style,
      render = function()
        return options.text or text
      end,
      on_click = on_click,
    }),
    options,
    label,
    action
  )
end

local function split_right()
  hollow.action.split_vertical()
end

local function split_down()
  hollow.action.split_horizontal()
end

local function minimize_window()
  state.host_api.request_window_minimize()
end

local function close_window()
  state.host_api.request_window_close()
end

local function configured_topbar_time(value)
  if value == false then
    return false
  end

  local format = "%H:%M"
  local opts
  if type(value) == "string" then
    format = value
  elseif type(value) == "table" then
    format = value.format or format
    opts = value.style ~= nil and { style = value.style } or nil
  end
  return ui.bar.time(format, opts)
end

---@return HollowUiWidget|nil
function M.widget()
  local opts = optional_table(state.ui.configured_topbar)
  if opts == nil then
    return nil
  end

  return ui.new_widget("topbar", {
    height = tonumber(opts.height) or M.resolved_theme().height,
    style = M.merge_tables({ bg = M.resolved_theme().background }, opts.style),
    layout = type(opts.layout) == "table" and opts.layout or DEFAULT_TOPBAR_LAYOUT,
    render = function(ctx)
      local workspace = configured_topbar_bar_opts(opts.workspace)
      local tabs = configured_topbar_bar_opts(opts.tabs)
      local new_tab = configured_topbar_new_tab(opts.new_tab)
      local right_split = configured_topbar_button(
        opts.split_right,
        "split-right-button",
        DEFAULT_SPLIT_RIGHT_TEXT,
        split_right,
        "split_button",
        "Split right",
        "split_vertical"
      )
      local down_split = configured_topbar_button(
        opts.split_down,
        "split-down-button",
        DEFAULT_SPLIT_DOWN_TEXT,
        split_down,
        "split_button",
        "Split down",
        "split_horizontal"
      )
      local minimize = configured_topbar_button(
        opts.minimize,
        "window-minimize-button",
        "−",
        minimize_window,
        nil,
        "Minimize window"
      )
      local close = configured_topbar_button(
        opts.close,
        "window-close-button",
        "X",
        close_window,
        "close_button",
        "Close window"
      )
      local expanding_tabs = tabs ~= false and tabs.fit ~= "content"
      local separator = configured_topbar_separator(opts.separator)
      local cwd = configured_topbar_cwd(ctx, opts.cwd)
      local key_legend = configured_topbar_bar_opts(opts.key_legend)
      local items = tbl({
          workspace ~= false and ui.bar.workspace(workspace),
          separator ~= nil and workspace ~= false and tabs ~= false and separator,
          expanding_tabs and new_tab or false,
          tabs ~= false and ui.bar.tabs(tabs),
          not expanding_tabs and new_tab or false,
        })
        :filter(function(item)
          return item ~= false
        end)
        :get()
      local right_items = tbl({
          opts.hidden_panes ~= false and hidden_panes.topbar_button(ctx),
          M.with_tooltip(attention.topbar_button(), {}, "Activity Center", "activity_center"),
          right_split,
          down_split,
          cwd or false,
          key_legend ~= false and ui.bar.key_legend(key_legend),
          configured_topbar_time(opts.time),
          -- Space after the activity group, even when window controls are hidden.
          -- An empty span reserves width without painting or taking clicks.
          ui.span("", { padding = { right = RIGHT_GROUP_GAP } }),
          minimize,
          close,
        })
        :filter(function(item)
          return item ~= false
        end)
        :get()

      if #right_items > 0 then
        tbl(items):concat({ ui.spacer() }, right_items)
      end

      return items
    end,
  })
end
local function visible_bar_item_count(items)
  return tbl(items):count(function(item)
    return item.kind ~= "spacer"
  end)
end

local function sync_topbar_config(opts)
  local topbar_theme = M.resolved_theme()
  local style = M.merge_tables({ bg = topbar_theme.background }, opts.style)
  local config_opts = {
    top_bar_height = tonumber(opts.height) or topbar_theme.height,
  }

  if style.bg ~= nil then
    config_opts.top_bar_bg = style.bg
  end

  hollow.config.set(config_opts)
end
function M.configure(opts)
  dismiss_tooltip()
  opts = opts or {}
  local configured = clone_table(state.ui.configured_topbar)
  util.merge_tables(configured, opts)
  state.ui.configured_topbar = configured
  sync_topbar_config(configured)
end
return M
