local color = require("hollow.color")
local shared = require("hollow.ui.shared")
local hollow = _G.hollow
local state = require("hollow.state").get()
local ui = hollow.ui
local tbl = hollow.tbl
local util = hollow.util
local M = {}
local BAR_CACHE_NO_EXPIRY = false
local DEFAULT_TOPBAR_HEIGHT = 22
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

  local theme = shared.resolve_theme()
  value.style = M.merge_tables({
    fg = theme.ui.widgets.all.divider,
  }, value.style)
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
      local separator = configured_topbar_separator(opts.separator)
      local cwd = configured_topbar_cwd(ctx, opts.cwd)
      local key_legend = configured_topbar_bar_opts(opts.key_legend)
      local items = tbl({
          workspace ~= false and ui.bar.workspace(workspace),
          separator ~= nil and workspace ~= false and tabs ~= false and separator,
          tabs ~= false and ui.bar.tabs(tabs),
        })
        :filter(function(item)
          return item ~= false
        end)
        :get()
      local right_items = tbl({
          cwd or false,
          key_legend ~= false and ui.bar.key_legend(key_legend),
          configured_topbar_time(opts.time),
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
  opts = opts or {}
  local configured = clone_table(state.ui.configured_topbar)
  util.merge_tables(configured, opts)
  state.ui.configured_topbar = configured
  sync_topbar_config(configured)
end
return M
