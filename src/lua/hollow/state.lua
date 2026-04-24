local M = {}

---@type HollowState|nil
local _instance = nil

---@return HollowKeymapSequenceNode
local function empty_sequence_node()
  return {
    action = nil,
    desc = nil,
    children = {},
  }
end

---@return HollowState
function M.get()
  if _instance == nil then
    error("hollow.state not initialized. Call hollow.state.new(host_api) first.")
  end
  return _instance
end

---@param host_api HollowHostBridge
---@return HollowState
function M.new(host_api)
  assert(_instance == nil, "hollow.state already initialized")

  ---@type HollowState
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
        ["term:pane_layout_changed"] = true,
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
      sequence_bindings = empty_sequence_node(),
      leader = nil,
      leader_bindings = empty_sequence_node(),
      sequence_timeout_ms = 1000,
      sequence_pending_until = nil,
      sequence_active_node = nil,
      sequence_steps = {},
      sequence_prefix = nil,
    },
    ui = {
      mounted_topbar = nil,
      topbar_hovered_id = nil,
      topbar_handlers = {},
      mounted_bottombar = nil,
      bottombar_hovered_id = nil,
      bottombar_handlers = {},
      mounted_sidebar = nil,
      sidebar_visible = false,
      overlay_stack = {},
      notifications = {},
      workspace_switcher = {
        known_workspaces = nil,
        sources = nil,
        format_item = nil,
        filter_item = nil,
        cache_ttl_ms = 5000,
        cache_loaded_at_ms = 0,
        cached_items = nil,
        last_opened = {},
        listeners_registered = false,
        project_roots = nil,
        status_column_width = nil,
        name_column_width = nil,
        column_gap = nil,
      },
    },
  }
  return _instance
end

return M
