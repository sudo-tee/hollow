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

package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path

local function make_host_api()
  local key_handler = nil
  local gui_ready_handler = nil
  local deferred = {}
  local recorded = {
    config = nil,
    domain_process = nil,
    close_workspace = nil,
    new_tab_calls = 0,
    move_pane = nil,
    split_pane = nil,
    close_pane = nil,
    focus_pane = nil,
    focus_pane_by_id = nil,
    resize_pane = nil,
    close_tab_by_id = nil,
    switch_tab_by_id = nil,
    set_tab_title_by_id = nil,
    set_tab_title = nil,
    set_pane_foreground_process = nil,
    reload_config = 0,
    scroll = nil,
    copy_mode = nil,
    workspace_default_cwd = nil,
    send_text = {},
    files = {},
    deferred_calls = 0,
  }

  local panes = {
    [101] = {
      pid = 4242,
      domain = "main",
      cwd = "/tmp/project",
      text = "line one\nline two",
      tags = {},
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
  local next_pane_id = 102

  local tabs = {
    { id = 201, pane_ids = { 101 }, active_pane_id = 101 },
  }

  local workspaces = {
    { id = 41, name = "main" },
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

  function host_api.on_gui_ready(callback)
    gui_ready_handler = callback
  end

  function host_api.defer(callback)
    deferred[#deferred + 1] = callback
    recorded.deferred_calls = recorded.deferred_calls + 1
  end

  function host_api.read_dir(path)
    if path == "\\\\wsl$\\Ubuntu\\home\\francis\\Projects" then
      return {
        "\\\\wsl$\\Ubuntu\\home\\francis\\Projects\\alpha",
        "\\\\wsl$\\Ubuntu\\home\\francis\\Projects\\_scratch",
      }
    end
    return {}
  end

  function host_api.read_file(path)
    local value = recorded.files[path]
    if value == nil then
      error("missing file: " .. tostring(path), 0)
    end
    return value
  end

  function host_api.write_file(path, contents)
    recorded.files[path] = contents
    return true
  end

  function host_api.path_exists(path)
    return recorded.files[path] ~= nil
  end

  function host_api.default_config_path()
    return "src/lua/tests/fixtures/config/init.lua"
  end

  function host_api.json_encode(_value)
    error("json_encode is not available in the Lua stub runtime", 0)
  end

  function host_api.json_decode(text)
    if text == "__workspace_spec__" then
      return {
        tabs = {
          {
            panes = {
              { cwd = "/tmp/project", domain = "main" },
            },
          },
        },
      }
    end
    error("unexpected json_decode input in Lua stub runtime", 0)
  end

  function host_api.list_fonts()
    return {
      { family = "Consolas", styles = { "Regular", "Bold" } },
      { family = "Cascadia Mono", styles = { "Regular", "Italic", "Bold" } },
    }
  end

  function host_api.run_child_process(args, opts)
    recorded.child_process = { args = args, opts = opts }
    return { ok = true, args = args, opts = opts }
  end

  function host_api.run_domain_process(domain, args, opts)
    recorded.domain_process = { domain = domain, args = args, opts = opts }
    return recorded.domain_process
  end

  function host_api.set_config(opts)
    recorded.config = opts
  end

  function host_api.reload_config()
    recorded.reload_config = recorded.reload_config + 1
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

  function host_api.get_pane_text(pane_id)
    return panes[pane_id].text
  end

  function host_api.get_pane_title(pane_id)
    return panes[pane_id].title
  end

  function host_api.get_pane_foreground_process(pane_id)
    return panes[pane_id].foreground_process or ""
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

  local function current_active_pane_id()
    return tabs[1] and tabs[1].active_pane_id or 101
  end

  function host_api.current_pane_id()
    return current_active_pane_id()
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

  function host_api.get_workspace_id(index)
    return workspaces[index + 1] and workspaces[index + 1].id or nil
  end

  function host_api.get_active_workspace_index()
    return 0
  end

  function host_api.set_workspace_name(name)
    workspaces[1].name = name
  end

  function host_api.new_workspace(_opts)
    recorded.new_workspace = _opts
    if _opts ~= nil and type(_opts.on_complete) == "function" then
      _opts.on_complete({ success = true, workspace_index = 1 })
    end
    return nil
  end

  function host_api.close_workspace(index)
    recorded.close_workspace = index
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
    recorded.new_tab = _opts
    if _opts ~= nil and type(_opts.on_complete) == "function" then
      _opts.on_complete({ success = true, tab_id = 201 })
    end
  end

  function host_api.close_tab()
    return nil
  end

  function host_api.close_pane()
    recorded.close_pane = "active"
    return nil
  end

  function host_api.close_pane_by_id(pane_id)
    recorded.close_pane = pane_id
    return panes[pane_id] ~= nil
  end

  function host_api.next_tab()
    return nil
  end

  function host_api.prev_tab()
    return nil
  end

  function host_api.set_tab_title(title)
    recorded.set_tab_title = title
    panes[101].title = title
  end

  function host_api.set_tab_title_by_id(tab_id, title)
    recorded.set_tab_title_by_id = { tab_id = tab_id, title = title }
    if tab_id ~= 201 then
      return false
    end
    panes[101].title = title
    return true
  end

  function host_api.set_pane_foreground_process(pane_id, process)
    recorded.set_pane_foreground_process = { pane_id = pane_id, process = process }
    if panes[pane_id] ~= nil then
      panes[pane_id].foreground_process = process
    end
  end

  function host_api.split_pane(_opts)
    recorded.split_pane = _opts
    recorded.split_pane_calls = recorded.split_pane_calls or {}
    recorded.split_pane_calls[#recorded.split_pane_calls + 1] = _opts

    local pane_id = next_pane_id
    next_pane_id = next_pane_id + 1
    local active_pane_id = current_active_pane_id()
    local active_pane = panes[active_pane_id] or panes[101]
    panes[pane_id] = {
      pid = 4242 + pane_id,
      domain = _opts.domain or active_pane.domain,
      cwd = _opts.cwd or active_pane.cwd,
      text = "",
      tags = {},
      title = "shell",
      is_focused = true,
      is_floating = _opts.floating == true,
      is_maximized = _opts.fullscreen == true,
      x = active_pane.x,
      y = active_pane.y,
      width = active_pane.width,
      height = active_pane.height,
      rows = active_pane.rows,
      cols = active_pane.cols,
      foreground_process = _opts.command,
    }

    tabs[1].pane_ids[#tabs[1].pane_ids + 1] = pane_id
    tabs[1].active_pane_id = pane_id
    if panes[active_pane_id] ~= nil then
      panes[active_pane_id].is_focused = false
    end
    panes[pane_id].is_focused = true

    if type(_opts.on_complete) == "function" then
      _opts.on_complete({ success = true, pane_id = pane_id })
    end
    return nil
  end

  function host_api.set_workspace_default_cwd(cwd)
    recorded.workspace_default_cwd = cwd
  end

  function host_api.focus_pane(_direction)
    recorded.focus_pane = _direction
    return nil
  end

  function host_api.focus_pane_by_id(pane_id)
    recorded.focus_pane_by_id = pane_id
    if panes[pane_id] == nil then
      return false
    end
    for _, pane in pairs(panes) do
      pane.is_focused = false
    end
    tabs[1].active_pane_id = pane_id
    panes[pane_id].is_focused = true
    return true
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
    recorded.resize_pane = { axis = _axis, amount = _amount }
    return nil
  end

  function host_api.copy_selection()
    return nil
  end

  function host_api.paste_clipboard()
    return nil
  end

  function host_api.scroll_active(_amount)
    recorded.scroll = { kind = "delta", amount = _amount }
    return nil
  end

  function host_api.scroll_active_page(_amount)
    recorded.scroll = { kind = "page", amount = _amount }
    return nil
  end

  function host_api.scroll_active_top()
    recorded.scroll = { kind = "top" }
    return nil
  end

  function host_api.scroll_active_bottom()
    recorded.scroll = { kind = "bottom" }
    return nil
  end

  function host_api.copy_mode_enter()
    recorded.copy_mode = { kind = "enter" }
    hollow._emit_builtin_event("copy_mode:changed", { active = true, query = "", match_count = 0, match_index = nil, selecting = false, block = false })
    return nil
  end

  function host_api.copy_mode_exit()
    recorded.copy_mode = { kind = "exit" }
    hollow._emit_builtin_event("copy_mode:changed", { active = false, query = "", match_count = 0, match_index = nil, selecting = false, block = false })
    return nil
  end

  function host_api.copy_mode_move(direction, extend)
    recorded.copy_mode = { kind = "move", direction = direction, extend = extend }
    return nil
  end

  function host_api.copy_mode_begin_selection(block)
    recorded.copy_mode = { kind = "begin_selection", block = block == true }
    hollow._emit_builtin_event("copy_mode:changed", { active = true, query = "", match_count = 0, match_index = nil, selecting = true, block = block == true })
    return nil
  end

  function host_api.copy_mode_clear_selection()
    recorded.copy_mode = { kind = "clear_selection" }
    hollow._emit_builtin_event("copy_mode:changed", { active = true, query = "", match_count = 0, match_index = nil, selecting = false, block = false })
    return nil
  end

  function host_api.copy_mode_copy()
    recorded.copy_mode = { kind = "copy" }
    return nil
  end

  function host_api.copy_mode_open_search()
    recorded.copy_mode = { kind = "open_search" }
    hollow._emit_builtin_event("copy_mode:search_requested", {})
    return nil
  end

  function host_api.copy_mode_search_set_query(query)
    recorded.copy_mode = { kind = "search_set_query", query = query }
    hollow._emit_builtin_event("copy_mode:changed", { active = true, query = query, match_count = 0, match_index = nil, selecting = false, block = false })
    return nil
  end

  function host_api.copy_mode_search_next()
    recorded.copy_mode = { kind = "search_next" }
    hollow._emit_builtin_event("copy_mode:changed", { active = true, query = "", match_count = 3, match_index = 1, selecting = false, block = false })
    return nil
  end

  function host_api.copy_mode_search_prev()
    recorded.copy_mode = { kind = "search_prev" }
    hollow._emit_builtin_event("copy_mode:changed", { active = true, query = "", match_count = 3, match_index = 3, selecting = false, block = false })
    return nil
  end

  function host_api.switch_tab_by_id(tab_id)
    recorded.switch_tab_by_id = tab_id
    return true
  end

  function host_api.close_tab_by_id(tab_id)
    recorded.close_tab_by_id = tab_id
    return true
  end

  function host_api.send_text(text)
    recorded.send_text[#recorded.send_text + 1] = text
    return true
  end

  function host_api.send_text_to_pane(pane_id, text)
    if panes[pane_id] == nil then
      return false
    end
    recorded.send_text[#recorded.send_text + 1] = text
    return true
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
  end, function()
    return gui_ready_handler
  end, function()
    while #deferred > 0 do
      local queued = deferred
      deferred = {}
      for _, callback in ipairs(queued) do
        callback()
      end
    end
  end
end

reset_modules()

local host_api, recorded, get_key_handler, get_gui_ready_handler, flush_deferred = make_host_api()
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
local theme_api = require("hollow.theme")

assert_true(hollow ~= nil, "core should initialize the global hollow table")
assert_equal(state.get().host_api, host_api, "state should retain the host bridge")
assert_true(type(util.host_now_ms) == "function", "util helper should be available")
assert_true(type(config.setup) == "function", "config module should load")
assert_true(type(term.setup) == "function", "term module should load")
assert_true(type(actions.setup) == "function", "actions module should load")
assert_true(type(keymap.setup) == "function", "keymap module should load")
assert_true(type(events.setup) == "function", "events module should load")
assert_true(type(htp.setup) == "function", "htp module should load")
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
assert_true(type(theme_api.create) == "function", "theme module should expose create")
assert_true(type(theme_api.get) == "function", "theme module should expose get")

assert_equal(util.host_now_ms(host_api), 1234, "host_now_ms should prefer the host clock")
assert_equal(util.join_path("alpha", "beta"), "alpha/beta", "join_path should normalize path segments")

hollow.config.set({ theme = { ui = { accent = "#abcdef" } } })
assert_equal(recorded.config.theme.ui.accent, "#abcdef", "config.set should forward config to the host")
assert_equal(hollow.config.get("theme").ui.accent, "#abcdef", "config.set should update stored state")

local snapshot = hollow.config.snapshot()
snapshot.theme.ui.accent = "#000000"
assert_equal(hollow.config.get("theme").ui.accent, "#abcdef", "config.snapshot should clone values")

local derived_theme = theme_api.create({
  terminal = {
    foreground = "#eeeeee",
    background = "#111111",
    ansi = { "#010101", "#020202", "#030303", "#040404", "#050505", "#060606", "#070707", "#080808" },
    brights = { "#111111", "#121212", "#131313", "#141414", "#151515", "#161616", "#171717", "#181818" },
  },
})
assert_equal(derived_theme.palette.background, "#111111", "theme.create should derive background palette entries")
assert_equal(derived_theme.palette.bright_blue, "#151515", "theme.create should expose named bright ANSI colors")
assert_equal(derived_theme.ui.scrollbar.thumb, "#111111", "theme.create should derive scrollbar theme from the palette")

local built_in_theme = theme_api.get("kanagawa-wave")
assert_equal(built_in_theme.terminal.background, "#1f1f28", "theme.get should load built-in themes")
assert_equal(built_in_theme.palette.bright_red, "#e82424", "theme.get should derive palette names from terminal themes")

assert_equal(require("user_module").source, "config", "config directory should be added to package.path")

hollow.config.set({ lib_dir = "src/lua/tests/fixtures/lib" })
assert_equal(require("custom.module").source, "lib", "lib_dir should be added to package.path")

local external_theme = theme_api.get("external")
assert_equal(external_theme.terminal.background, "#121212", "theme.get should load themes from runtime package paths")

local current_theme = theme_api.current()
assert_equal(current_theme.ui.accent, "#abcdef", "theme.current should reflect the active configured theme")
local select_theme = theme_api.resolve_widget("select")
assert_true(type(select_theme) == "table", "theme.resolve_widget should expose flat widget theme values")
assert_equal(
  select_theme.panel_bg,
  current_theme.ui.tab_bar.background,
  "theme.resolve_widget should align overlay panel background with the tab bar background"
)

local current_pane = hollow.term.current_pane()
local current_domain = hollow.term.current_domain()
assert_equal(current_pane.id, 101, "current_pane should return the focused pane")
assert_equal(#current_pane.tags, 0, "current_pane should expose pane tags")
assert_equal(hollow.term.get_pane_text(101), "line one\nline two", "get_pane_text should return pane text")
assert_equal(#hollow.term.get_pane_tags(101), 0, "get_pane_tags should default to an empty list")
hollow.term.add_pane_tag("test-runner", 101)
assert_equal(hollow.term.get_pane_tags(101)[1], "test-runner", "add_pane_tag should attach tags to panes")
hollow.term.add_pane_tag("build", 101)
hollow.term.remove_pane_tag("build", 101)
assert_equal(#hollow.term.get_pane_tags(101), 1, "remove_pane_tag should delete a single tag")
assert_equal(hollow.term.pane_by_id(101).tags[1], "test-runner", "pane snapshots should include tags")
assert_equal(current_domain.name, "main", "current_domain should snapshot the focused pane domain")
assert_equal(current_domain.is_active, true, "current_domain should mark the active domain")
assert_equal(hollow.term.current_workspace().name, "main", "current_workspace should snapshot workspace state")
assert_equal(hollow.term.current_workspace().domain, "main", "current_workspace should expose its active domain")
hollow.term.close_workspace(41)
assert_equal(recorded.close_workspace, 41, "close_workspace should forward workspace ids")
hollow.term.close_workspace()
assert_equal(recorded.close_workspace, nil, "close_workspace should allow closing the active workspace")

local process_result = hollow.term.run_domain_process({ "echo", "ok" })
assert_equal(process_result.domain, "main", "run_domain_process should infer the current domain")
assert_equal(recorded.domain_process.args[1], "echo", "run_domain_process should pass through arguments")

hollow.process.run_child_process({ "echo", "ok" }, { hide_window = true })
assert_equal(recorded.child_process.opts.hide_window, true, "run_child_process should forward opts")

hollow.term.run_domain_process({ "echo", "ok" }, "main", { hide_window = true })
assert_equal(recorded.domain_process.opts.hide_window, true, "run_domain_process should forward opts")

local font_list = hollow.fonts.list()
assert_equal(font_list[1].family, "Consolas", "fonts.list should return host-provided families")
assert_equal(font_list[2].styles[2], "Italic", "fonts.list should preserve style arrays")
assert_true(#hollow.fonts.find("mono") >= 1, "fonts.find should match normalized family names")
assert_true(hollow.fonts.has("Cascadia Mono"), "fonts.has should detect installed families")
assert_true(hollow.fonts.has("Cascadia Mono", "Italic"), "fonts.has should detect installed styles")
assert_true(not hollow.fonts.has("Cascadia Mono", "Black"), "fonts.has should reject missing styles")
assert_equal(hollow.fonts.pick({ "Missing Font", "Cascadia Mono", "Consolas" }), "Cascadia Mono", "fonts.pick should return the first available family")
assert_equal(hollow.fonts.pick({ "Missing Font" }), nil, "fonts.pick should return nil when no candidate exists")

assert_true(type(hollow.json.encode) == "function", "json.encode should be exposed")
assert_true(type(hollow.json.decode) == "function", "json.decode should be exposed")
assert_true(type(hollow.async.run) == "function", "async.run should be exposed")
assert_true(type(hollow.async.await) == "function", "async.await should be exposed")

local async_value = nil
hollow.async.run(function()
  async_value = hollow.async.await(function(resolve)
    resolve("ok")
  end)
end)
assert_equal(async_value, "ok", "async.await should resume coroutines with resolved values")

local promise_value = nil
local promise = hollow.async.promise(function(resolve)
  resolve(42)
end)
promise:next(function(value)
  promise_value = value
  return value
end)
assert_equal(promise_value, 42, "async.promise should invoke chained handlers")

hollow.workspace.bootstrap({
  name = "proj",
  tabs = {
    {
      name = "editor",
      panes = {
        { cwd = ".", command = "nvim" },
        { cwd = "server", command = "npm run dev", size = 0.25 },
      },
    },
  },
}, { base_dir = "/tmp/project" })
flush_deferred()
assert_equal(recorded.workspace_default_cwd, "/tmp/project", "workspace bootstrap should set workspace default cwd")
assert_equal(recorded.split_pane.command, "npm run dev", "workspace bootstrap should create split panes")
assert_equal(recorded.split_pane.ratio, 0.25, "workspace bootstrap should map pane size to split ratio")
assert_equal(#recorded.split_pane_calls, 1, "workspace bootstrap should create one split for a two-pane tab")

hollow.workspace.bootstrap({
  tabs = {
    {
      panes = {
        { command = "nvim" },
        { command = "npm run dev", main = true },
      },
    },
  },
})
flush_deferred()
assert_equal(recorded.focus_pane_by_id, 103, "workspace bootstrap should focus the pane marked main")

local exported_main = hollow.workspace.export_current()
assert_equal(exported_main.tabs[1].panes[3].main, true, "workspace export should mark the focused pane as main")

local split_count_before_linear = #recorded.split_pane_calls
hollow.workspace.bootstrap({
  tabs = {
    {
      panes = {
        { command = "nvim", domain = "wsl" },
        { direction = "horizontal", domain = "wsl" },
        { direction = "vertical", domain = "wsl" },
      },
    },
  },
})
flush_deferred()
assert_equal(#recorded.split_pane_calls - split_count_before_linear, 2, "workspace bootstrap should create each linear split in sequence")
assert_equal(recorded.split_pane_calls[split_count_before_linear + 1].direction, "horizontal", "workspace bootstrap should preserve the second pane split direction")
assert_equal(recorded.split_pane_calls[split_count_before_linear + 2].direction, "vertical", "workspace bootstrap should preserve the third pane split direction")

local split_result = nil
hollow.term.split_pane({
  direction = "vertical",
  on_complete = function(result)
    split_result = result
  end,
})
assert_true(split_result ~= nil and split_result.success == true, "split_pane on_complete should receive a success result")
assert_true(type(split_result.pane_id) == "number", "split_pane on_complete should receive the created pane id")

hollow.term.set_pane_tags({ "test-runner", "primary" }, 101)
hollow.term.focus_pane_by_id(101)

assert_equal(hollow.workspace.project_local_path("/tmp/project"), "\\\\wsl.localhost\\main\\tmp\\project\\.hollow\\workspace.json", "workspace helper should resolve project-local path")

recorded.files["\\\\wsl.localhost\\main\\tmp\\project\\.hollow\\workspace.json"] = "present"
hollow.config.set({ workspace = { auto_bootstrap = "always", default_layout = "default" } })
assert_equal(hollow.workspace.resolve_auto_bootstrap_path(), "\\\\wsl.localhost\\main\\tmp\\project\\.hollow\\workspace.json", "auto bootstrap should prefer project-local workspace files")

local gui_ready = get_gui_ready_handler()
assert_true(type(gui_ready) == "function", "core should register a gui ready handler")
recorded.files["\\\\wsl.localhost\\main\\tmp\\project\\.hollow\\workspace.json"] = "__workspace_spec__"
gui_ready()
assert_equal(recorded.new_workspace.cwd, "/tmp/project", "auto bootstrap should run on gui ready using the active pane cwd")

recorded.new_workspace = nil
local deferred_calls_before_workspace_new = recorded.deferred_calls
hollow._emit_builtin_event("workspace:new", { workspace_index = 2 })
assert_true(recorded.deferred_calls > deferred_calls_before_workspace_new, "workspace:new auto bootstrap should defer layout restore")
assert_equal(recorded.new_workspace, nil, "workspace:new auto bootstrap should not run immediately")
flush_deferred()
assert_equal(recorded.new_workspace.cwd, "/tmp/project", "workspace:new auto bootstrap should run on the deferred tick")

local exported = hollow.workspace.export_current()
assert_equal(exported.name, "main", "workspace export should include active workspace name")
assert_equal(exported.tabs[1].panes[1].cwd, "/tmp/project", "workspace export should include pane cwd")
assert_equal(exported.tabs[1].panes[1].tags[1], "primary", "workspace export should include pane tags")
assert_equal(exported.tabs[1].panes[1].tags[2], "test-runner", "workspace export should preserve pane tags")

local on_key = get_key_handler()
assert_true(type(on_key) == "function", "keymap setup should register a key handler")

hollow.keymap.set("<C-S-t>", "new_tab")
local key, mods = hollow.keymap.parse_chord("<C-S-t>")
assert_true(on_key(key, mods), "registered key bindings should consume mapped keys")
assert_equal(recorded.new_tab_calls, 1, "registered action bindings should invoke host actions")

local mode_hits = {}
hollow.keymap.set("x", function()
  mode_hits[#mode_hits + 1] = "normal"
end)
hollow.keymap.set("x", function()
  mode_hits[#mode_hits + 1] = "copy_mode"
end, { mode = "copy_mode" })

assert_true(on_key("x", 0), "normal mode bindings should dispatch through the shared keymap")
assert_equal(mode_hits[#mode_hits], "normal", "normal mode should prefer the normal binding bucket")
assert_true(hollow.keymap.get("x") ~= nil, "keymap.get should read normal bindings by default")
assert_true(hollow.keymap.get("x", { mode = "copy_mode" }) ~= nil, "keymap.get should read mode-specific bindings")

hollow.action.copy_mode()
assert_equal(recorded.copy_mode.kind, "enter", "copy_mode action should enter copy mode")
assert_true(state.get().copy_mode.active, "copy_mode should become active after enter")
assert_equal(state.get().copy_mode.match_count, 0, "copy mode should initialize match count")

assert_true(on_key("x", 0), "copy mode should dispatch mode-specific bindings through the shared keymap")
assert_equal(mode_hits[#mode_hits], "copy_mode", "copy mode should prefer the copy_mode binding bucket")

hollow.keymap.set("j", "copy_mode_move_down", { mode = "copy_mode" })
hollow.keymap.set("gg", "copy_mode_top", { mode = "copy_mode" })
hollow.keymap.set("G", "copy_mode_bottom", { mode = "copy_mode" })
hollow.keymap.set("v", "copy_mode_begin_selection", { mode = "copy_mode" })
hollow.keymap.set("<C-v>", "copy_mode_begin_block_selection", { mode = "copy_mode" })
hollow.keymap.set("<Space>", "copy_mode_clear_selection", { mode = "copy_mode" })
hollow.keymap.set("/", "copy_mode_search", { mode = "copy_mode" })
hollow.keymap.set("n", "copy_mode_search_next", { mode = "copy_mode" })
hollow.keymap.set("N", "copy_mode_search_prev", { mode = "copy_mode" })
hollow.keymap.set("y", "copy_mode_copy_selection", { mode = "copy_mode" })

assert_true(on_key("j", 0), "copy mode should consume modal movement")
assert_equal(recorded.copy_mode.kind, "move", "copy mode movement should dispatch host move")
assert_equal(recorded.copy_mode.direction, "down", "copy mode j should move down")
assert_equal(recorded.copy_mode.extend, false, "copy mode movement should not extend before selection")

recorded.copy_mode = nil
assert_true(on_key("g", 0), "copy mode should consume the first g in gg")
assert_equal(recorded.copy_mode, nil, "the first g should wait for a second g before moving")

assert_true(on_key("g", 0), "copy mode should jump to the top on gg")
assert_equal(recorded.copy_mode.kind, "move", "gg should dispatch a host move")
assert_equal(recorded.copy_mode.direction, "top", "gg should move to the top")
assert_equal(recorded.copy_mode.extend, false, "gg should not extend before selection")

assert_true(on_key("g", 1), "copy mode should jump to the bottom on G")
assert_equal(recorded.copy_mode.kind, "move", "G should dispatch a host move")
assert_equal(recorded.copy_mode.direction, "bottom", "G should move to the bottom")
assert_equal(recorded.copy_mode.extend, false, "G should not extend before selection")

assert_true(on_key("v", 0), "copy mode should begin selection")
assert_equal(recorded.copy_mode.kind, "begin_selection", "copy mode v should begin selection")
assert_true(state.get().copy_mode.selecting, "copy mode should track selection state")
assert_true(not state.get().copy_mode.block, "copy mode v should use line selection mode")

assert_true(on_key("v", 2), "copy mode should begin block selection on ctrl-v")
assert_equal(recorded.copy_mode.kind, "begin_selection", "copy mode ctrl-v should begin selection")
assert_true(recorded.copy_mode.block, "copy mode ctrl-v should request block selection")
assert_true(state.get().copy_mode.block, "copy mode should track block selection state")

assert_true(on_key("j", 0), "copy mode should extend movement while selecting")
assert_equal(recorded.copy_mode.extend, true, "copy mode movement should extend after selection begins")

assert_true(on_key("space", 0), "copy mode should clear selection")
assert_equal(recorded.copy_mode.kind, "clear_selection", "copy mode space should clear selection")
assert_true(not state.get().copy_mode.selecting, "copy mode clear should clear selection state")
assert_true(not state.get().copy_mode.block, "copy mode clear should clear block selection state")

assert_true(on_key("slash", 0), "copy mode should open search")
assert_equal(recorded.copy_mode.kind, "open_search", "copy mode slash should request search")
assert_true(hollow.ui.overlay.depth() > 0, "copy mode search should open an input overlay")

local overlay_before_confirm = hollow.ui.overlay.depth()
assert_true(on_key("enter", 0), "search overlay should consume confirm")
assert_true(hollow.ui.overlay.depth() < overlay_before_confirm, "confirming search should close the input overlay")
assert_equal(recorded.copy_mode.kind, "search_set_query", "search confirm should set the host query")
assert_equal(recorded.copy_mode.query, "", "search confirm should forward the current query")

hollow.ui.workspace.configure({
  cache_ttl_ms = 0,
  sources = {
    {
      name = "Ubuntu",
      domain = "main",
      cwd_resolver = "wsl_unc",
      roots = {
        "\\\\wsl$\\Ubuntu\\home\\francis\\Projects",
      },
    },
  },
  filter_item = function(item)
    local basename = hollow.util.basename(item.cwd)
    return basename and basename:sub(1, 1) ~= "_"
  end,
})
local workspace_items = hollow.ui.workspace.items(true)
assert_equal(#workspace_items, 2, "workspace switcher should include open workspaces and UNC-scanned roots")
assert_equal(workspace_items[1].name, "main", "workspace switcher should dedupe an opened workspace against its known root entry")
assert_equal(workspace_items[1].cwd, "/tmp/project", "workspace switcher should preserve the remembered cwd for the opened workspace entry")
assert_equal(workspace_items[2].name, "alpha", "workspace switcher should keep UNC root entries without per-item path stats")
assert_equal(workspace_items[2].cwd, "/home/francis/Projects/alpha", "workspace switcher should still resolve UNC cwd for launch")

assert_true(on_key("n", 0), "copy mode should jump to next match")
assert_equal(recorded.copy_mode.kind, "search_next", "copy mode n should jump to next match")
assert_equal(state.get().copy_mode.match_count, 3, "copy mode should track match counts from host state")
assert_equal(state.get().copy_mode.match_index, 1, "copy mode should track active match index from host state")

assert_true(on_key("n", 1), "copy mode should jump to previous match on shifted n")
assert_equal(recorded.copy_mode.kind, "search_prev", "copy mode N should jump to previous match")
assert_equal(state.get().copy_mode.match_index, 3, "copy mode should update active match index on previous search")

assert_true(on_key("y", 0), "copy mode should copy and exit")
assert_equal(recorded.copy_mode.kind, "exit", "copy mode copy should exit after copying")
assert_true(not state.get().copy_mode.active, "copy mode should be inactive after copy+exit")

assert_true(hollow.keymap.del("x", { mode = "copy_mode" }), "keymap.del should remove mode-specific bindings")
assert_true(hollow.keymap.get("x", { mode = "copy_mode" }) == nil, "deleted mode-specific bindings should not resolve")

local event_payload = nil
hollow.events.once("custom:event", function(payload)
  event_payload = payload
end)
hollow.events.emit("custom:event", { value = 42 })
hollow.events.emit("custom:event", { value = 99 })
assert_equal(event_payload.value, 42, "once listeners should fire exactly once")

local built_in_error = pcall(function()
  hollow.events.emit("term:foreground_process_changed", {})
end)
assert_true(not built_in_error, "built-in events should not be emitted from Lua")

hollow.term.set_title("shell", 201)
local title_event = nil
hollow.events.once("term:title_changed", function(payload)
  title_event = payload
end)
hollow.term.set_title("editor", 201)
assert_equal(title_event.old_title, "shell", "title_changed should expose the previous title")
assert_equal(title_event.new_title, "editor", "title_changed should expose the updated title")
assert_equal(title_event.pane.id, 101, "title_changed should adapt pane snapshots")

hollow.term.set_pane_foreground_process(101, "nvim")
local process_event = nil
hollow.events.once("term:foreground_process_changed", function(payload)
  process_event = payload
end)
hollow.term.set_pane_foreground_process(101, "zig build")
assert_equal(process_event.old_process, "nvim", "foreground_process_changed should expose the previous process")
assert_equal(process_event.new_process, "zig build", "foreground_process_changed should expose the updated process")
assert_equal(process_event.pane.id, 101, "foreground_process_changed should adapt pane snapshots")

assert_equal(state.get().ui.topbar_cache_dirty, true, "foreground_process_changed should invalidate the topbar cache")
assert_equal(state.get().ui.bottombar_cache_dirty, true, "foreground_process_changed should invalidate the bottombar cache")

local ok_query, pane_query = hollow.htp._handle_query("pane", nil, 101)
assert_true(ok_query, "built-in HTP pane query should succeed")
assert_equal(pane_query.id, 101, "HTP pane query should expose pane snapshots")

local ok_domain_query, domain_query = hollow.htp._handle_query("current_domain", nil, 101)
assert_true(ok_domain_query, "built-in HTP current_domain query should succeed")
assert_equal(domain_query.name, "main", "HTP current_domain query should expose domain snapshots")

local ok_emit = hollow.htp._handle_emit("move_pane", { direction = "left", amount = 0.2 }, 101)
assert_true(ok_emit, "built-in HTP emit handler should succeed")
assert_equal(recorded.move_pane.direction, "left", "HTP emit should dispatch term actions")
assert_equal(recorded.move_pane.amount, 0.2, "HTP emit should preserve payload values")

local ok_panes_query, panes_query = hollow.htp._handle_query("panes", nil, 101)
assert_true(ok_panes_query, "built-in HTP panes query should succeed")
assert_equal(panes_query[1].id, 101, "HTP panes query should expose pane snapshots")

local ok_tagged_panes_query, tagged_panes_query = hollow.htp._handle_query("panes", { tag = "test-runner" }, 101)
assert_true(ok_tagged_panes_query, "HTP tagged panes query should succeed")
assert_equal(tagged_panes_query[1].id, 101, "HTP tagged panes query should filter by tag")

local ok_tab_query, tab_query = hollow.htp._handle_query("tab", { id = 201 }, 101)
assert_true(ok_tab_query, "built-in HTP tab query should succeed")
assert_equal(tab_query.id, 201, "HTP tab query should support targeted lookups")

local ok_workspace_query, workspace_query = hollow.htp._handle_query("workspace", { id = 41 }, 101)
assert_true(ok_workspace_query, "built-in HTP workspace query should succeed")
assert_equal(workspace_query.id, 41, "HTP workspace query should support targeted lookups")

local ok_close_pane = hollow.htp._handle_emit("close_pane", { id = 101 }, 101)
assert_true(ok_close_pane, "HTP close_pane should succeed")
assert_equal(recorded.close_pane, 101, "HTP close_pane should target pane ids")

local ok_focus_pane = hollow.htp._handle_emit("focus_pane", { direction = "right" }, 101)
assert_true(ok_focus_pane, "HTP focus_pane should succeed")
assert_equal(recorded.focus_pane, "right", "HTP focus_pane should forward direction")

local ok_resize_pane = hollow.htp._handle_emit("resize_pane", { axis = "horizontal", delta = 5 }, 101)
assert_true(ok_resize_pane, "HTP resize_pane should succeed")
assert_equal(recorded.resize_pane.axis, "horizontal", "HTP resize_pane should forward axis")
assert_equal(recorded.resize_pane.amount, 5, "HTP resize_pane should forward delta")

local ok_send_text = hollow.htp._handle_emit("send_text", { text = "ls\n", id = 101 }, 101)
assert_true(ok_send_text, "HTP send_text should succeed")
assert_equal(recorded.send_text[#recorded.send_text], "ls\n", "HTP send_text should forward text to the pane")

local ok_add_pane_tag = hollow.htp._handle_emit("add_pane_tag", { id = 101, tag = "ci" }, 101)
assert_true(ok_add_pane_tag, "HTP add_pane_tag should succeed")
assert_equal(hollow.term.get_pane_tags(101)[1], "ci", "HTP add_pane_tag should add a pane tag")

local ok_set_pane_tags = hollow.htp._handle_emit("set_pane_tags", { id = 101, tags = { "runner", "slow" } }, 101)
assert_true(ok_set_pane_tags, "HTP set_pane_tags should succeed")
assert_equal(hollow.term.get_pane_tags(101)[1], "runner", "HTP set_pane_tags should replace pane tags")
assert_equal(hollow.term.get_pane_tags(101)[2], "slow", "HTP set_pane_tags should keep all tags")

local ok_remove_pane_tag = hollow.htp._handle_emit("remove_pane_tag", { id = 101, tag = "runner" }, 101)
assert_true(ok_remove_pane_tag, "HTP remove_pane_tag should succeed")
assert_equal(hollow.term.get_pane_tags(101)[1], "slow", "HTP remove_pane_tag should remove only the requested tag")

local ok_pane_text, pane_text = hollow.htp._handle_query("pane_text", { id = 101 }, 101)
assert_true(ok_pane_text, "HTP pane_text should succeed")
assert_equal(pane_text, "line one\nline two", "HTP pane_text should return pane text")

local ok_close_tab = hollow.htp._handle_emit("close_tab", { id = 201 }, 101)
assert_true(ok_close_tab, "HTP close_tab should succeed")
assert_equal(recorded.close_tab_by_id, 201, "HTP close_tab should target tab ids")

local ok_focus_tab = hollow.htp._handle_emit("focus_tab", { id = 201 }, 101)
assert_true(ok_focus_tab, "HTP focus_tab should succeed")
assert_equal(recorded.switch_tab_by_id, 201, "HTP focus_tab should target tab ids")

local ok_set_tab_title = hollow.htp._handle_emit("set_tab_title", { id = 201, title = "editor" }, 101)
assert_true(ok_set_tab_title, "HTP set_tab_title should succeed")
assert_equal(recorded.set_tab_title_by_id.title, "editor", "HTP set_tab_title should forward title")

local ok_new_tab = hollow.htp._handle_emit("new_tab", { domain = "dev", command = "npm run dev" }, 101)
assert_true(ok_new_tab, "HTP new_tab should succeed")
assert_equal(recorded.new_tab.domain, "dev", "HTP new_tab should forward domain")
assert_equal(recorded.new_tab.command, "npm run dev", "HTP new_tab should forward command")

local ok_new_workspace = hollow.htp._handle_emit("new_workspace", { cwd = "/tmp/project", name = "proj" }, 101)
assert_true(ok_new_workspace, "HTP new_workspace should succeed")
assert_equal(recorded.new_workspace.name, "proj", "HTP new_workspace should forward payload")

local ok_set_workspace_name = hollow.htp._handle_emit("set_workspace_name", { id = 41, name = "renamed" }, 101)
assert_true(ok_set_workspace_name, "HTP set_workspace_name should succeed")
assert_equal(hollow.term.current_workspace().name, "renamed", "HTP set_workspace_name should update the active workspace")

local ok_reload_config = hollow.htp._handle_emit("reload_config", {}, 101)
assert_true(ok_reload_config, "HTP reload_config should succeed")
assert_equal(recorded.reload_config, 1, "HTP reload_config should call the host bridge")

local ok_set_theme = hollow.htp._handle_emit("set_theme", { name = "tokyonight" }, 101)
assert_true(ok_set_theme, "HTP set_theme should succeed")
assert_equal(hollow.config.get("theme"), "tokyonight", "HTP set_theme should update config state")

local ok_scroll = hollow.htp._handle_emit("scroll", { to = "page-down" }, 101)
assert_true(ok_scroll, "HTP scroll should succeed")
assert_equal(recorded.scroll.kind, "page", "HTP scroll should map to scroll actions")
assert_equal(recorded.scroll.amount, 1, "HTP scroll page-down should scroll one page")

local widget = hollow.ui.notify.info("hello", { ttl = 100 })
assert_true(widget ~= nil, "notify should create an overlay widget")
assert_equal(hollow.ui.overlay.depth(), 1, "notify should push an overlay widget")
assert_true(hollow.ui._overlay_state() ~= nil, "overlay state should serialize active widgets")
hollow.ui.notify.clear()
assert_equal(hollow.ui.overlay.depth(), 0, "notify.clear should remove notify widgets")

hollow.ui.workspace.open_switcher()
local workspace_overlay = hollow.ui._overlay_state()
assert_true(workspace_overlay ~= nil, "workspace switcher should create an overlay")
local resolved_select_theme = hollow.ui.resolve_theme("select")
assert_equal(
  workspace_overlay[1].chrome.bg,
  resolved_select_theme.panel_bg,
  "workspace switcher should use the select panel background"
)
assert_equal(
  workspace_overlay[1].chrome.alpha,
  255,
  "workspace switcher should default overlay chrome alpha to opaque"
)
assert_equal(
  workspace_overlay[1].rows[5].fill_bg,
  resolved_select_theme.selected_bg,
  "workspace switcher should use the select selected background for the active row"
)
assert_true(on_key("a", 0), "workspace switcher should consume first-key filtering")
workspace_overlay = hollow.ui._overlay_state()
assert_true(workspace_overlay ~= nil, "workspace switcher should remain open while filtering")
local filtered_workspace_text = ""
for _, row in ipairs(workspace_overlay[1].rows or {}) do
  for _, segment in ipairs(row.segments or {}) do
    filtered_workspace_text = filtered_workspace_text .. (segment.text or "")
  end
  filtered_workspace_text = filtered_workspace_text .. "\n"
end
assert_true(filtered_workspace_text:find("alpha", 1, true) ~= nil, "workspace switcher should match alpha on the first key")
hollow.ui.overlay.clear()

hollow.ui.select.open({
  items = {
    { name = "hollow", cwd = "/home/francis/Projects/hollow" },
    { name = "alpha", cwd = "/home/francis/Projects/alpha" },
  },
  fuzzy = false,
  label = function(item)
    return item.name .. " " .. item.cwd
  end,
  search_text = function(item)
    return item.name
  end,
})
assert_true(on_key("h", 0), "select should consume first key when search_text is provided")
local search_text_overlay = hollow.ui._overlay_state()
assert_true(search_text_overlay ~= nil, "search_text select overlay should remain open")
local search_text_overlay_text = ""
for _, row in ipairs(search_text_overlay[1].rows or {}) do
  for _, segment in ipairs(row.segments or {}) do
    search_text_overlay_text = search_text_overlay_text .. (segment.text or "")
  end
  search_text_overlay_text = search_text_overlay_text .. "\n"
end
assert_true(search_text_overlay_text:find("hollow", 1, true) ~= nil, "select should match using custom search_text")
hollow.ui.overlay.clear()

hollow.ui.workspace.open_switcher()
workspace_overlay = hollow.ui._overlay_state()
assert_true(workspace_overlay ~= nil, "workspace switcher should reopen for basename search test")
assert_true(on_key("h", 0), "workspace switcher should consume first key for basename search")
assert_true(on_key("o", 0), "workspace switcher should consume second key for basename search")
workspace_overlay = hollow.ui._overlay_state()
assert_true(workspace_overlay ~= nil, "workspace switcher should remain open during basename search")
local basename_search_text = ""
for _, row in ipairs(workspace_overlay[1].rows or {}) do
  for _, segment in ipairs(row.segments or {}) do
    basename_search_text = basename_search_text .. (segment.text or "")
  end
  basename_search_text = basename_search_text .. "\n"
end
assert_true(basename_search_text:find("alpha", 1, true) == nil, "workspace switcher search should not match every /home path entry")
hollow.ui.overlay.clear()

hollow.ui.select.open({
  items = { "alpha" },
  chrome = { bg = "#112233", alpha = 123 },
  backdrop = false,
})
local custom_overlay = hollow.ui._overlay_state()
assert_true(custom_overlay ~= nil, "custom select overlay should serialize")
assert_equal(custom_overlay[1].chrome.bg, "#112233", "custom overlay chrome bg should serialize")
assert_equal(custom_overlay[1].chrome.alpha, 123, "custom overlay chrome alpha should serialize")
hollow.ui.overlay.clear()

hollow.ui.input.open({
  prompt = "Rename workspace",
  default = "main",
  backdrop = true,
})
assert_true(on_key("arrow_left", 0), "input overlay with backdrop should consume arrow keys")
assert_true(on_key("x", 0), "input overlay should insert text at the moved cursor")
local input_overlay = hollow.ui._overlay_state()
assert_true(input_overlay ~= nil, "input overlay should stay open while editing")
local input_overlay_text = ""
for _, row in ipairs(input_overlay[1].rows or {}) do
  for _, segment in ipairs(row.segments or {}) do
    input_overlay_text = input_overlay_text .. (segment.text or "")
  end
  input_overlay_text = input_overlay_text .. "\n"
end
assert_true(input_overlay_text:find("maixn", 1, true) ~= nil, "input overlay should insert at the caret after moving left")
assert_true(on_key("f1", 0), "input overlay with backdrop should consume unmatched keys")
hollow.ui.overlay.clear()

hollow.ui.select.open({
  items = { "alpha", "beta" },
})
assert_true(on_key("a", 0), "select should consume printable filter input before cursor test")
assert_true(on_key("arrow_left", 0), "select filter should move cursor left")
assert_true(on_key("x", 0), "select filter should insert at the moved cursor")
local select_cursor_overlay = hollow.ui._overlay_state()
assert_true(select_cursor_overlay ~= nil, "select overlay should stay open during cursor editing")
local select_cursor_text = ""
for _, row in ipairs(select_cursor_overlay[1].rows or {}) do
  for _, segment in ipairs(row.segments or {}) do
    select_cursor_text = select_cursor_text .. (segment.text or "")
  end
  select_cursor_text = select_cursor_text .. "\n"
end
assert_true(select_cursor_text:find("Filter: xa", 1, true) ~= nil, "select filter should insert at the caret after moving left")
hollow.ui.overlay.clear()

hollow.ui.topbar.configure({
  separator = "|",
  cwd = false,
  key_legend = false,
  time = false,
  tabs = {
    fit = "content",
    format = function(tab)
      return "tab:" .. tab.title
    end,
  },
})

local configured_topbar = hollow.ui._topbar_state()
assert_true(configured_topbar ~= nil, "topbar.configure should provide a default topbar widget")
assert_equal(configured_topbar.items[1].kind, "segment", "configured topbar should serialize workspace content")
assert_equal(configured_topbar.items[2].kind, "segment", "configured topbar should serialize separators")
assert_equal(configured_topbar.items[3].kind, "tabs", "configured topbar should serialize tabs content")

hollow.ui.topbar.configure({
  separator = false,
  cwd = false,
  key_legend = false,
  time = false,
  workspace = false,
  tabs = {
    fit = "content",
    max_width = 20,
    format = function(tab)
      return {
        hollow.ui.span("prefix "),
        hollow.ui.span(tab.title),
      }
    end,
  },
})

local topbar_with_max_width = hollow.ui._topbar_state()
assert_equal(topbar_with_max_width.items[1].kind, "tabs", "tabs-only topbar should serialize a tabs item")
assert_equal(topbar_with_max_width.items[1].max_width, 20, "tabs max_width should be preserved in serialized topbar state")
assert_equal(topbar_with_max_width.items[1].tabs[1].text, "prefix shell", "short tab labels should remain unchanged under max_width")

_G.host_api.set_tab_title_by_id(201, "this is a very looooong name that should be shorter")
topbar_with_max_width = hollow.ui._topbar_state()
assert_equal(topbar_with_max_width.items[1].tabs[1].text, "prefix this is a...", "tabs max_width should truncate serialized tab text")
assert_true(
  topbar_with_max_width.items[1].tabs[1].segments ~= nil
    and topbar_with_max_width.items[1].tabs[1].segments[1].text == "prefix "
    and topbar_with_max_width.items[1].tabs[1].segments[2].text == "this is a...",
  "tabs max_width should truncate serialized formatted segments"
)

hollow.ui.topbar.mount(hollow.ui.topbar.new({
  render = function()
    return {}
  end,
}))
assert_true(hollow.ui._topbar_state() == nil, "topbar should auto-hide when no widgets render")
assert_true(hollow.ui._topbar_layout() == nil, "topbar layout should auto-hide when no widgets render")
hollow.ui.topbar.unmount()

hollow.ui.topbar.configure({
  cwd = false,
  key_legend = false,
  time = false,
  tabs = false,
  workspace = {
    style = function()
      local ui_theme = hollow.config.get("resolved_theme").ui
      return {
        bg = ui_theme.top_bar.background,
        fg = ui_theme.widgets.all.title,
      }
    end,
  },
})

local topbar_before_theme_change = hollow.ui._topbar_state()
assert_equal(
  topbar_before_theme_change.items[1].style.bg,
  hollow.config.get("resolved_theme").ui.top_bar.background,
  "workspace segment should use the current resolved topbar background"
)

hollow.config.set({ theme = "nord" })

local topbar_after_theme_change = hollow.ui._topbar_state()
assert_equal(
  topbar_after_theme_change.items[1].style.bg,
  hollow.config.get("resolved_theme").ui.top_bar.background,
  "theme changes should invalidate cached topbar workspace styles"
)

hollow.ui.topbar.mount(hollow.ui.topbar.new({
  render = function()
    return {
      hollow.ui.span("mounted")
    }
  end,
}))

local mounted_topbar = hollow.ui._topbar_state()
assert_equal(mounted_topbar.items[1].text, "mounted", "mounted topbar should override configured defaults")
hollow.ui.topbar.unmount()

assert_true(hollow.ui._bottombar_state() == nil, "bottombar should auto-hide when no special widgets render")
assert_true(hollow.ui._bottombar_layout() == nil, "bottombar layout should auto-hide when inactive")

hollow.keymap.set_leader("<C-Space>", { timeout_ms = 1200 })
hollow.keymap.set("<leader>x", function() end, { desc = "test leader" })
local leader_key, leader_mods = hollow.keymap.parse_chord("<C-Space>")
assert_true(on_key(leader_key, leader_mods), "leader key should activate leader mode")
local leader_bar = hollow.ui._bottombar_state()
assert_true(leader_bar ~= nil, "bottombar should show in leader mode")
assert_true(leader_bar.items[1].text:find("LEADER", 1, true) ~= nil, "leader mode widget should identify leader mode")
assert_true(#leader_bar.items >= 2, "leader mode should render the mode widget and legend region")
assert_true(leader_bar.items[#leader_bar.items].text:find("x", 1, true) ~= nil, "leader mode should show the next leader keys")
assert_true(on_key("z", 0), "unmatched leader continuation should clear leader mode")
assert_true(hollow.ui._bottombar_state() == nil, "bottombar should clear immediately after leader mode resets")

assert_true(on_key(leader_key, leader_mods), "leader key should activate leader mode again")

hollow.action.copy_mode()
local copy_bar = hollow.ui._bottombar_state()
assert_true(copy_bar ~= nil, "bottombar should show in copy mode")
assert_true(copy_bar.items[1].text:find("COPY", 1, true) ~= nil, "copy mode widget should identify copy mode")
assert_true(copy_bar.items[2].text:find("/search", 1, true) ~= nil, "copy mode should show search status")
assert_true(copy_bar.items[#copy_bar.items].text:find("move", 1, true) ~= nil, "copy mode should show key legend hints")

hollow.action.copy_mode_exit()
assert_true(hollow.ui._bottombar_state() == nil, "bottombar should hide again after special modes clear")

print("runtime_test.lua: ok")
