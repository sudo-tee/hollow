local function fail(message)
  error(message, 0)
end

local function assert_true(value, message)
  if not value then
    fail(message or "expected truthy value")
  end
end

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    fail((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function reset_modules()
  for name in pairs(package.loaded) do
    if name == "core" or name == "hollow" or name:match("^hollow%.") then
      package.loaded[name] = nil
    end
  end

  _G.hollow = nil
  _G.host_api = nil
end

local function make_host_api()
  local key_handler = nil
  local recorded = {
    config = nil,
    domain_process = nil,
    new_tab_calls = 0,
    move_pane = nil,
  }

  local panes = {
    [101] = {
      pid = 4242,
      domain = "main",
      cwd = "/tmp/project",
      title = "shell",
      is_focused = true,
      is_floating = false,
      is_maximized = false,
      x = 10,
      y = 20,
      width = 120,
      height = 40,
      rows = 40,
      cols = 120,
    },
  }

  local tabs = {
    { id = 201, pane_ids = { 101 }, active_pane_id = 101 },
  }

  local workspaces = {
    { name = "main" },
  }

  local host_api = {
    platform = {
      is_macos = false,
      is_windows = false,
      is_wsl = false,
    },
  }

  function host_api.now_ms()
    return 1234
  end

  function host_api.on_key(callback)
    key_handler = callback
  end

  function host_api.read_dir(_path)
    return {}
  end

  function host_api.run_child_process(args)
    return { ok = true, args = args }
  end

  function host_api.run_domain_process(domain, args)
    recorded.domain_process = { domain = domain, args = args }
    return recorded.domain_process
  end

  function host_api.set_config(opts)
    recorded.config = opts
  end

  function host_api.reload_config()
    return true
  end

  function host_api.pane_exists(pane_id)
    return panes[pane_id] ~= nil
  end

  function host_api.get_pane_pid(pane_id)
    return panes[pane_id].pid
  end

  function host_api.get_pane_domain(pane_id)
    return panes[pane_id].domain
  end

  function host_api.get_pane_cwd(pane_id)
    return panes[pane_id].cwd
  end

  function host_api.get_pane_title(pane_id)
    return panes[pane_id].title
  end

  function host_api.pane_is_focused(pane_id)
    return panes[pane_id].is_focused
  end

  function host_api.pane_is_floating(pane_id)
    return panes[pane_id].is_floating
  end

  function host_api.pane_is_maximized(pane_id)
    return panes[pane_id].is_maximized
  end

  function host_api.get_pane_x(pane_id)
    return panes[pane_id].x
  end

  function host_api.get_pane_y(pane_id)
    return panes[pane_id].y
  end

  function host_api.get_pane_width(pane_id)
    return panes[pane_id].width
  end

  function host_api.get_pane_height(pane_id)
    return panes[pane_id].height
  end

  function host_api.get_pane_rows(pane_id)
    return panes[pane_id].rows
  end

  function host_api.get_pane_cols(pane_id)
    return panes[pane_id].cols
  end

  function host_api.current_pane_id()
    return 101
  end

  function host_api.get_tab_count()
    return #tabs
  end

  function host_api.get_tab_id_at(index)
    return tabs[index + 1] and tabs[index + 1].id or nil
  end

  function host_api.get_tab_index_by_id(tab_id)
    for index, tab in ipairs(tabs) do
      if tab.id == tab_id then
        return index - 1
      end
    end
    return nil
  end

  function host_api.get_tab_pane_count(tab_id)
    for _, tab in ipairs(tabs) do
      if tab.id == tab_id then
        return #tab.pane_ids
      end
    end
    return 0
  end

  function host_api.get_tab_pane_id_at(tab_id, index)
    for _, tab in ipairs(tabs) do
      if tab.id == tab_id then
        return tab.pane_ids[index + 1]
      end
    end
    return nil
  end

  function host_api.get_tab_active_pane_id(tab_id)
    for _, tab in ipairs(tabs) do
      if tab.id == tab_id then
        return tab.active_pane_id
      end
    end
    return nil
  end

  function host_api.current_tab_id()
    return tabs[1].id
  end

  function host_api.get_workspace_count()
    return #workspaces
  end

  function host_api.get_workspace_name(index)
    return workspaces[index + 1] and workspaces[index + 1].name or nil
  end

  function host_api.get_active_workspace_index()
    return 0
  end

  function host_api.set_workspace_name(name)
    workspaces[1].name = name
  end

  function host_api.new_workspace(_opts)
    return nil
  end

  function host_api.close_workspace()
    return nil
  end

  function host_api.next_workspace()
    return nil
  end

  function host_api.prev_workspace()
    return nil
  end

  function host_api.switch_workspace(_index)
    return nil
  end

  function host_api.new_tab(_opts)
    recorded.new_tab_calls = recorded.new_tab_calls + 1
  end

  function host_api.close_tab()
    return nil
  end

  function host_api.close_pane()
    return nil
  end

  function host_api.next_tab()
    return nil
  end

  function host_api.prev_tab()
    return nil
  end

  function host_api.split_pane(_opts)
    return nil
  end

  function host_api.focus_pane(_direction)
    return nil
  end

  function host_api.toggle_pane_maximized(_pane_id, _show_background)
    return nil
  end

  function host_api.set_pane_floating(_pane_id, _floating)
    return nil
  end

  function host_api.set_floating_pane_bounds(_pane_id, _x, _y, _width, _height)
    return nil
  end

  function host_api.move_pane(pane_id, direction, amount)
    recorded.move_pane = {
      pane_id = pane_id,
      direction = direction,
      amount = amount,
    }
  end

  function host_api.resize_pane(_axis, _amount)
    return nil
  end

  function host_api.copy_selection()
    return nil
  end

  function host_api.paste_clipboard()
    return nil
  end

  function host_api.scroll_active(_amount)
    return nil
  end

  function host_api.scroll_active_page(_amount)
    return nil
  end

  function host_api.scroll_active_top()
    return nil
  end

  function host_api.scroll_active_bottom()
    return nil
  end

  function host_api.get_window_width()
    return 1440
  end

  function host_api.get_window_height()
    return 900
  end

  return setmetatable(host_api, {
    __index = function()
      return function()
        return nil
      end
    end,
  }), recorded, function()
    return key_handler
  end
end

reset_modules()

local host_api, recorded, get_key_handler = make_host_api()
_G.host_api = host_api

require("core")

local hollow = _G.hollow
local state = require("hollow.state")
local util = require("hollow.util")
local config = require("hollow.config")
local term = require("hollow.term")
local actions = require("hollow.actions")
local keymap = require("hollow.keymap")
local events = require("hollow.events")
local htp = require("hollow.htp")
local defaults = require("hollow.defaults")
local ui = require("hollow.ui")
local ui_runtime = require("hollow.ui.runtime")
local ui_primitives = require("hollow.ui.primitives")
local ui_widgets_core = require("hollow.ui.widgets.core")
local ui_widgets_bars = require("hollow.ui.widgets.bars")
local ui_widgets_overlay = require("hollow.ui.widgets.overlay")
local ui_widgets_notify = require("hollow.ui.widgets.notify")
local ui_widgets_input = require("hollow.ui.widgets.input")
local ui_widgets_select = require("hollow.ui.widgets.select")
local ui_widgets_workspace = require("hollow.ui.widgets.workspace")

assert_true(hollow ~= nil, "core should initialize the global hollow table")
assert_equal(state.get().host_api, host_api, "state should retain the host bridge")
assert_true(type(util.host_now_ms) == "function", "util helper should be available")
assert_true(type(config.setup) == "function", "config module should load")
assert_true(type(term.setup) == "function", "term module should load")
assert_true(type(actions.setup) == "function", "actions module should load")
assert_true(type(keymap.setup) == "function", "keymap module should load")
assert_true(type(events.setup) == "function", "events module should load")
assert_true(type(htp.setup) == "function", "htp module should load")
assert_true(type(defaults.setup) == "function", "defaults module should load")
assert_true(type(ui.dispatch_widget_event) == "function", "ui exports should be merged onto hollow.ui")
assert_true(ui_runtime == true, "ui runtime should be loadable")
assert_true(ui_primitives == true, "ui primitives should be loadable")
assert_true(type(ui_widgets_core.mount_widget) == "function", "widget core helpers should load")
assert_true(ui_widgets_bars == true, "bars widget module should be loadable")
assert_true(ui_widgets_overlay == true, "overlay widget module should be loadable")
assert_true(ui_widgets_notify == true, "notify widget module should be loadable")
assert_true(ui_widgets_input == true, "input widget module should be loadable")
assert_true(ui_widgets_select == true, "select widget module should be loadable")
assert_true(ui_widgets_workspace == true, "workspace widget module should be loadable")

assert_equal(util.host_now_ms(host_api), 1234, "host_now_ms should prefer the host clock")
assert_equal(util.join_path("alpha", "beta"), "alpha/beta", "join_path should normalize path segments")

hollow.config.set({ theme = { accent = "#abcdef" } })
assert_equal(recorded.config.theme.accent, "#abcdef", "config.set should forward config to the host")
assert_equal(hollow.config.get("theme").accent, "#abcdef", "config.set should update stored state")

local snapshot = hollow.config.snapshot()
snapshot.theme.accent = "#000000"
assert_equal(hollow.config.get("theme").accent, "#abcdef", "config.snapshot should clone values")

local current_pane = hollow.term.current_pane()
assert_equal(current_pane.id, 101, "current_pane should return the focused pane")
assert_equal(hollow.term.current_workspace().name, "main", "current_workspace should snapshot workspace state")

local process_result = hollow.term.run_domain_process({ "echo", "ok" })
assert_equal(process_result.domain, "main", "run_domain_process should infer the current domain")
assert_equal(recorded.domain_process.args[1], "echo", "run_domain_process should pass through arguments")

local on_key = get_key_handler()
assert_true(type(on_key) == "function", "keymap setup should register a key handler")

local key, mods = hollow.keymap.parse_chord("<C-t>")
assert_true(on_key(key, mods), "default key bindings should consume mapped keys")
assert_equal(recorded.new_tab_calls, 1, "default action bindings should invoke host actions")

local event_payload = nil
hollow.events.once("custom:event", function(payload)
  event_payload = payload
end)
hollow.events.emit("custom:event", { value = 42 })
hollow.events.emit("custom:event", { value = 99 })
assert_equal(event_payload.value, 42, "once listeners should fire exactly once")

local ok_query, pane_query = hollow.htp._handle_query("pane", nil, 101)
assert_true(ok_query, "built-in HTP pane query should succeed")
assert_equal(pane_query.id, 101, "HTP pane query should expose pane snapshots")

local ok_emit = hollow.htp._handle_emit("move_pane", { direction = "left", amount = 0.2 }, 101)
assert_true(ok_emit, "built-in HTP emit handler should succeed")
assert_equal(recorded.move_pane.direction, "left", "HTP emit should dispatch term actions")
assert_equal(recorded.move_pane.amount, 0.2, "HTP emit should preserve payload values")

local widget = hollow.ui.notify.info("hello", { ttl = 100 })
assert_true(widget ~= nil, "notify should create an overlay widget")
assert_equal(hollow.ui.overlay.depth(), 1, "notify should push an overlay widget")
assert_true(hollow.ui._overlay_state() ~= nil, "overlay state should serialize active widgets")
hollow.ui.notify.clear()
assert_equal(hollow.ui.overlay.depth(), 0, "notify.clear should remove notify widgets")

print("runtime_test.lua: ok")
