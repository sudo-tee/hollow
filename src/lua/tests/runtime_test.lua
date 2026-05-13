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
  local recorded = {
    config = nil,
    domain_process = nil,
    close_workspace = nil,
    new_tab_calls = 0,
    move_pane = nil,
    split_pane = nil,
    close_pane = nil,
    focus_pane = nil,
    resize_pane = nil,
    close_tab_by_id = nil,
    switch_tab_by_id = nil,
    set_tab_title_by_id = nil,
    reload_config = 0,
    scroll = nil,
    workspace_default_cwd = nil,
    send_text = {},
    files = {},
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

  function host_api.read_dir(_path)
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
    return "/home/test/.config/hollow/init.lua"
  end

  function host_api.json_encode(_value)
    error("json_encode is not available in the Lua stub runtime", 0)
  end

  function host_api.json_decode(_text)
    error("json_decode is not available in the Lua stub runtime", 0)
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

  function host_api.split_pane(_opts)
    recorded.split_pane = _opts
    return nil
  end

  function host_api.set_workspace_default_cwd(cwd)
    recorded.workspace_default_cwd = cwd
  end

  function host_api.focus_pane(_direction)
    recorded.focus_pane = _direction
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

  function host_api.switch_tab_by_id(tab_id)
    recorded.switch_tab_by_id = tab_id
    return true
  end

  function host_api.close_tab_by_id(tab_id)
    recorded.close_tab_by_id = tab_id
    return true
  end

  function host_api.set_tab_title_by_id(tab_id, title)
    recorded.set_tab_title_by_id = { tab_id = tab_id, title = title }
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
  end
end

reset_modules()

local host_api, recorded, get_key_handler, get_gui_ready_handler = make_host_api()
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

assert_equal(util.host_now_ms(host_api), 1234, "host_now_ms should prefer the host clock")
assert_equal(util.join_path("alpha", "beta"), "alpha/beta", "join_path should normalize path segments")

hollow.config.set({ theme = { accent = "#abcdef" } })
assert_equal(recorded.config.theme.accent, "#abcdef", "config.set should forward config to the host")
assert_equal(hollow.config.get("theme").accent, "#abcdef", "config.set should update stored state")

local snapshot = hollow.config.snapshot()
snapshot.theme.accent = "#000000"
assert_equal(hollow.config.get("theme").accent, "#abcdef", "config.snapshot should clone values")

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
assert_equal(recorded.workspace_default_cwd, "/tmp/project", "workspace bootstrap should set workspace default cwd")
assert_equal(recorded.split_pane.command, "npm run dev", "workspace bootstrap should create split panes")
assert_equal(recorded.split_pane.ratio, 0.25, "workspace bootstrap should map pane size to split ratio")
hollow.term.set_pane_tags({ "test-runner", "primary" }, 101)

assert_equal(hollow.workspace.project_local_path("/tmp/project"), "\\\\wsl.localhost\\main\\tmp\\project\\.hollow\\workspace.json", "workspace helper should resolve project-local path")

recorded.files["\\\\wsl.localhost\\main\\tmp\\project\\.hollow\\workspace.json"] = "present"
hollow.config.set({ workspace = { auto_bootstrap = "always", default_layout = "default" } })
assert_equal(hollow.workspace.resolve_auto_bootstrap_path(), "\\\\wsl.localhost\\main\\tmp\\project\\.hollow\\workspace.json", "auto bootstrap should prefer project-local workspace files")

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

print("runtime_test.lua: ok")
