local hollow = _G.hollow
local ui = hollow.ui
local host = require("hollow.state").get().host_api
local components = require("hollow.ui.components")
local surface, current

local function button(label, action, variant)
  local workspace_id = current.workspace_id
  return components.button({
    id = tostring(workspace_id) .. ":" .. current.phase .. ":" .. (action or "pending"),
    text = label,
    variant = variant,
    size = "sm",
    disabled = action == nil,
    on_click = action and function()
      host.session_banner_action(workspace_id, action)
    end or nil,
  })
end

function ui._session_banner_prepare(width, height, cell_w, cell_h, workspace_id, phase, message)
  current = { workspace_id = workspace_id, phase = phase, message = message }
  if not surface then
    surface = ui.layout.new({
      render = function(ctx)
        local confirming = current.phase == "confirming"
        local connecting = current.phase == "connecting"
        local actions = components.row({
          button(
            connecting and "Reclaiming..." or confirming and "Confirm reclaim" or "Reclaim session",
            not connecting and (confirming and "confirm" or "reclaim") or nil,
            "primary"
          ),
          button(confirming and "Cancel" or "Close local view", confirming and "cancel" or "close"),
        }, { gap = 8, align_y = "center" })
        local text = components.column(
          { components.text(current.message, nil, { wrap = "none" }) },
          { width = "grow" }
        )
        local narrow = ctx.width < ctx.cell_w * 90
        return (narrow and components.column or components.row)({ text, actions }, {
          width = "grow",
          height = "grow",
          padding = { left = 8, right = 8 },
          gap = 8,
          align_y = "center",
        })
      end,
    })
  end
  surface:invalidate()
  local nodes = surface:snapshot({
    width = width,
    height = height,
    cell_w = cell_w,
    cell_h = cell_h,
  })
  return nodes, surface.revision, surface.id
end

function ui._session_banner_click(event)
  if surface then
    surface:dispatch(event.id)
  end
end
