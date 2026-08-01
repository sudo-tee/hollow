local hollow = _G.hollow
local state = require("hollow.state").get()
local ui = hollow.ui
local bottombar = require("hollow.ui.widgets.bars.bottombar")
local cache = require("hollow.ui.widgets.bars.bar_cache")
local events = require("hollow.ui.widgets.bars.bar_events")
local mount = require("hollow.ui.widgets.bars.bar_mount")
local serializer = require("hollow.ui.widgets.bars.bar_serialize")
local sidebar = require("hollow.ui.widgets.bars.sidebar")
local topbar = require("hollow.ui.widgets.bars.topbar")
local function configured(surface)
  if surface == "topbar" then
    return topbar.widget()
  end
  if surface == "bottombar" then
    return bottombar.widget()
  end
end

local function active(surface)
  return mount.widget(surface, configured)
end

mount.install(cache.invalidate, configured)
sidebar.install()
events.install(ui, active, cache.invalidate)

local function state_for(surface)
  local widget = active(surface)
  if widget == nil then
    cache.sync_host(surface, false, nil, false)
    return nil
  end
  return serializer.serialize(widget, surface)
end

function ui._topbar_state()
  return state_for("topbar")
end

function ui._bottombar_state()
  return state_for("bottombar")
end

local function layout(surface)
  local widget = active(surface)
  if widget == nil then
    cache.sync_host(surface, false, nil, false)
    return nil
  end
  if cache.is_valid(surface) then
    return cache.layout(surface)
  end
  if serializer.serialize(widget, surface) == nil then
    return nil
  end
  return cache.set_layout(surface, serializer.surface_layout(widget))
end

function ui._topbar_layout()
  return layout("topbar")
end

function ui._bottombar_layout()
  return layout("bottombar")
end

function ui.topbar.configure(opts)
  topbar.configure(opts)
  cache.invalidate("topbar")
end

function ui._register_bar_invalidation_hooks()
  if state.ui._bar_invalidation_hooks_registered then
    return
  end

  state.ui._bar_invalidation_hooks_registered = true
  local function invalidate_bars()
    ui.topbar.invalidate()
    ui.bottombar.invalidate()
  end

  hollow.events.on("config:reloaded", invalidate_bars)
  for _, name in ipairs({
    "copy_mode:changed",
    "quick_select:changed",
    "term:tab_activated",
    "term:tab_closed",
    "term:pane_focused",
    "term:pane_layout_changed",
    "term:title_changed",
    "term:cwd_changed",
    "term:foreground_process_changed",
    "term:bell",
    "workspace:changed",
    "window:resized",
  }) do
    hollow.events.on(name, invalidate_bars)
  end
end
return ui
