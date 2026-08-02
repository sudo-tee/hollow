local harness = {}
local luassert = require("luassert")

function harness.assert_true(value, message)
  luassert.is_true(value, message)
end

function harness.assert_equal(actual, expected, message)
  luassert.are.equal(expected, actual, message)
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
    quick_select = nil,
    workspace_default_cwd = nil,
    send_text = {},
    bell = nil,
    files = {},
    dirs = {},
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

  function host_api.data_dir()
    return "/tmp/hollow-test-data"
  end

  local function wildcard_to_lua_pattern(pattern)
    return "^" .. pattern:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1"):gsub("%*", ".*") .. "$"
  end

  function host_api.glob(pattern)
    local dir = pattern:match("^(.*)[/\\][^/\\]*$") or "."
    local name_pattern = pattern:match("[^/\\]*$") or pattern
    local matches = {}
    local lua_pattern = wildcard_to_lua_pattern(name_pattern)
    for path in pairs(recorded.files) do
      local path_dir = path:match("^(.*)[/\\][^/\\]*$") or "."
      local name = path:match("[^/\\]+$") or path
      if path_dir == dir and name:match(lua_pattern) then
        matches[#matches + 1] = path
      end
    end
    table.sort(matches)
    return matches
  end

  function host_api.is_dir(path)
    return recorded.dirs[path] == true
  end

  function host_api.mkdir_p(path)
    recorded.dirs[path] = true
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

  function host_api.run_process(cmd, args)
    recorded.process_run = { cmd = cmd, args = args }
    return { code = 0, stdout = "", stderr = "" }
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

  function host_api.pane_has_bell(pane_id)
    return panes[pane_id].has_bell or false
  end

  function host_api.set_pane_bell(pane_id, value)
    panes[pane_id].has_bell = value == true
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

  function host_api.get_workspace_tab_count(workspace_index)
    if workspaces[workspace_index + 1] == nil then
      return 0
    end
    return #tabs
  end

  function host_api.get_workspace_tab_id_at(workspace_index, tab_index)
    if workspaces[workspace_index + 1] == nil then
      return nil
    end
    return tabs[tab_index + 1] and tabs[tab_index + 1].id or nil
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
    hollow._emit_builtin_event("copy_mode:changed", {
      active = true,
      query = "",
      match_count = 0,
      match_index = nil,
      selecting = false,
      block = false,
    })
    return nil
  end

  function host_api.copy_mode_exit()
    recorded.copy_mode = { kind = "exit" }
    hollow._emit_builtin_event("copy_mode:changed", {
      active = false,
      query = "",
      match_count = 0,
      match_index = nil,
      selecting = false,
      block = false,
    })
    return nil
  end

  function host_api.copy_mode_move(direction, extend)
    recorded.copy_mode = { kind = "move", direction = direction, extend = extend }
    return nil
  end

  function host_api.copy_mode_begin_selection(block)
    recorded.copy_mode = { kind = "begin_selection", block = block == true }
    hollow._emit_builtin_event("copy_mode:changed", {
      active = true,
      query = "",
      match_count = 0,
      match_index = nil,
      selecting = true,
      block = block == true,
    })
    return nil
  end

  function host_api.copy_mode_clear_selection()
    recorded.copy_mode = { kind = "clear_selection" }
    hollow._emit_builtin_event("copy_mode:changed", {
      active = true,
      query = "",
      match_count = 0,
      match_index = nil,
      selecting = false,
      block = false,
    })
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
    hollow._emit_builtin_event("copy_mode:changed", {
      active = true,
      query = query,
      match_count = 0,
      match_index = nil,
      selecting = false,
      block = false,
    })
    return nil
  end

  function host_api.copy_mode_search_next()
    recorded.copy_mode = { kind = "search_next" }
    hollow._emit_builtin_event("copy_mode:changed", {
      active = true,
      query = "",
      match_count = 3,
      match_index = 1,
      selecting = false,
      block = false,
    })
    return nil
  end

  function host_api.copy_mode_search_prev()
    recorded.copy_mode = { kind = "search_prev" }
    hollow._emit_builtin_event("copy_mode:changed", {
      active = true,
      query = "",
      match_count = 3,
      match_index = 3,
      selecting = false,
      block = false,
    })
    return nil
  end

  function host_api.quick_select_start(action)
    recorded.quick_select = action
  end

  function host_api.quick_select_handlers(match_handler, action_handler)
    recorded.quick_select_match_handler = match_handler
    recorded.quick_select_action_handler = action_handler
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

  function host_api.bell_pane(pane_id)
    if panes[pane_id] == nil then
      return false
    end
    recorded.bell = pane_id
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
  }),
    recorded,
    function()
      return key_handler
    end,
    function()
      return gui_ready_handler
    end,
    function()
      while #deferred > 0 do
        local queued = deferred
        deferred = {}
        for _, callback in ipairs(queued) do
          callback()
        end
      end
    end
end

function harness.boot()
  reset_modules()

  local host_api, recorded, get_key_handler, get_gui_ready_handler, flush_deferred = make_host_api()
  _G.host_api = host_api

  require("core")

  local hollow = _G.hollow
  local state = require("hollow.state")

  return {
    host_api = host_api,
    recorded = recorded,
    hollow = hollow,
    state = state,
    get_key_handler = get_key_handler,
    get_gui_ready_handler = get_gui_ready_handler,
    flush_deferred = flush_deferred,
  }
end

return harness
