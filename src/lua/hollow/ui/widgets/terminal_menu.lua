local M = {}
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
    elseif type(entry) == "string" and labels[entry] then
      local action = entry
      local value = host.menu_query(id, action)
      local label = value == 2 and toggled[action] or labels[action]
      if action == "dock" and pane and pane.dock then
        label = "Undock"
      end
      local item = {
        label = label,
        icon = action_icons[action],
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
