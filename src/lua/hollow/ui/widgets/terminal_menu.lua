local M = {}
local actions = require("hollow.actions")
local icons = require("hollow.ui.icons")
local groups = {
  "copy",
  "paste",
  "separator",
  "split_right",
  "split_down",
  "separator",
  "float",
  "hide",
  "zoom",
  "dock",
  "move",
  "separator",
  "close",
}
local labels = {
  copy = "Copy",
  paste = "Paste",
  split_right = "Split Right",
  split_down = "Split Down",
  float = "Float",
  hide = "Hide",
  zoom = "Zoom",
  dock = "Dock",
  close = "Close Pane",
}
local toggled = { float = "Unfloat", zoom = "Unzoom", dock = "Undock" }
local action_icons = {
  copy = icons.copy,
  paste = icons.paste,
  split_right = icons.split_right,
  split_down = icons.split_down,
  float = icons.window_float,
  hide = icons.pane_hidden,
  zoom = icons.window_zoom,
  dock = icons.pin,
  close = icons.close,
}
local dock_edges = {
  { label = "Left", action = "dock_left" },
  { label = "Right", action = "dock_right" },
  { label = "Top", action = "dock_top" },
  { label = "Bottom", action = "dock_bottom" },
}

local move_directions = {
  { label = "Left", icon = icons.arrow_left, action = "move_left" },
  { label = "Right", icon = icons.arrow_right, action = "move_right" },
  { label = "Top", icon = icons.arrow_up, action = "move_top" },
  { label = "Bottom", icon = icons.arrow_down, action = "move_bottom" },
}

local function move_item(hollow, host, id, pane)
  local submenu = {}
  local available = false
  local function add(label, icon, enabled, action)
    available = available or enabled
    submenu[#submenu + 1] = { label = label, icon = icon, disabled = not enabled, action = action }
  end
  for _, direction in ipairs(move_directions) do
    local action = direction.action
    add(direction.label, direction.icon, host.menu_query(id, action) ~= nil, function()
      host.menu_action(id, action, 1)
    end)
  end
  local workspace = hollow.term.current_workspace()
  local can_transfer = pane
    and not pane.dock
    and workspace
    and (workspace.session_state == nil or workspace.session_state == "attached")
  local tab = can_transfer and hollow.term.current_tab()
  local has_other_tab = false
  if tab then
    for _, candidate in ipairs(hollow.term.tabs()) do
      if candidate.id ~= tab.id then
        has_other_tab = true
        break
      end
    end
  end
  add("Tab", icons.tab, has_other_tab, function()
    hollow.action.move_pane_to_tab(id)
  end)
  add(
    "Workspace",
    icons.folder,
    tab and next(actions.workspace_move_destinations(hollow, workspace, "pane")) ~= nil,
    function()
      hollow.action.move_pane_to_workspace(id)
    end
  )
  return { label = "Move", icon = icons.move, disabled = not available, submenu = submenu }
end

function M.open(hollow, host, event)
  local id = event.pane_id
  local pane = hollow.term.pane_by_id(id)
  local function valid()
    return hollow.config.get("terminal_menu") ~= false and host.menu_query(id, "target") ~= nil
  end
  local selection = host.menu_query(id, "copy")
  local config = hollow.config.get("terminal_menu_items")
  local items = {}
  for _, entry in ipairs(type(config) == "table" and config or groups) do
    if entry == "separator" then
      items[#items + 1] = { separator = true }
    elseif entry == "move" then
      items[#items + 1] = move_item(hollow, host, id, pane)
    elseif type(entry) == "string" and labels[entry] then
      local action = entry
      local value = host.menu_query(id, action)
      local label = value == 2 and toggled[action] or labels[action]
      if action == "dock" and pane and pane.dock then
        label = "Undock"
      end
      local item = {
        label = label,
        icon = label == toggled.dock and icons.pin_off or action_icons[action],
        disabled = value == nil,
        action = function()
          host.menu_action(id, action, value)
        end,
      }
      if action == "dock" and label == "Dock" then
        item.action = nil
        item.submenu = {}
        local any = false
        for _, edge in ipairs(dock_edges) do
          local edge_action = edge.action
          local available = value ~= nil and host.menu_query(id, edge_action) ~= nil
          any = any or available
          item.submenu[#item.submenu + 1] = {
            label = edge.label,
            disabled = not available,
            action = function()
              host.menu_action(id, edge_action, 1)
            end,
          }
        end
        item.disabled = not any
      end
      items[#items + 1] = item
    elseif
      type(entry) == "table"
      and type(entry.label) == "string"
      and type(entry.action) == "function"
    then
      local callback = entry.action
      items[#items + 1] = {
        label = entry.label,
        icon = entry.icon,
        action = function()
          local pane = valid() and hollow.term.pane_by_id(id)
          if pane then
            callback(pane)
          end
        end,
      }
    end
  end
  return hollow.ui.menu({
    anchor = { x = event.x, y = event.y },
    items = items,
    valid = valid,
    on_close = function(reason)
      if selection and (reason == "escape" or reason == "outside") then
        host.menu_action(id, "copy", selection)
      end
    end,
  })
end

return M
