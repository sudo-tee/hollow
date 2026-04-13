local M = {}

local _instance = nil

function M.get()
  return _instance
end

function M.new(host_api)
  assert(_instance == nil, "hollow.state already initialized")
  _instance = {
    host_api = host_api,
    config = {
      values = {},
    },
    events = {
        builtin_names = {
        ["config:reloaded"] = true,
        ["term:title_changed"] = true,
        ["term:tab_activated"] = true,
        ["term:tab_closed"] = true,
        ["term:pane_focused"] = true,
        ["term:cwd_changed"] = true,
        ["key:unhandled"] = true,
        ["window:resized"] = true,
        ["window:focused"] = true,
        ["window:blurred"] = true,
        ["topbar:hover"] = true,
        ["topbar:leave"] = true,
        ["topbar:click"] = true,
        ["bottombar:hover"] = true,
        ["bottombar:leave"] = true,
        ["bottombar:click"] = true,
        ["selection:begin"] = true,
        ["selection:cleared"] = true,
      },
      handles = {},
      listeners = {},
      next_handle = 1,
    },
    keymap = {
      bindings = {},
      sequence_bindings = { children = {} },
      leader = nil,
      leader_bindings = { children = {} },
      sequence_timeout_ms = 1000,
      sequence_pending_until = nil,
      sequence_active_node = nil,
      sequence_steps = {},
      sequence_prefix = nil,
    },
    ui = {
      mounted_topbar = nil,
      topbar_hovered_id = nil,
      mounted_bottombar = nil,
      bottombar_hovered_id = nil,
      mounted_sidebar = nil,
      sidebar_visible = false,
      overlay_stack = {},
      notifications = {},
    },
  }
  return _instance
end

return M
