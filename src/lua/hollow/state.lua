local M = {}

function M.new(host_api)
  return {
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
      },
      handles = {},
      listeners = {},
      next_handle = 1,
    },
    keymap = {
      bindings = {},
      leader = nil,
      leader_timeout_ms = 1000,
      leader_pending_until = nil,
      leader_active_node = nil,
      leader_sequence_steps = {},
      leader_bindings = { children = {} },
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
end

return M
