-- Docked sidebar host: lifecycle and focus for a split Lua pane.
-- Edge and docked hosts share one sidebar component tree.
local hollow = _G.hollow
local state = require("hollow.state").get()
local ui = hollow.ui
local c = ui.components
local content = require("hollow.ui.widgets.sidebar_content")
local shared = require("hollow.ui.shared")
local util = require("hollow.util")

local MODULE = "hollow.sidebar"
local docked
-- Set while dock() closes the pane to hide the sidebar rather than undock it.
local hide_on_close = false

local function refresh_layout()
  if type(state.host_api.request_layout_refresh) == "function" then
    state.host_api.request_layout_refresh()
  end
end

ui.pane.register(MODULE, function()
  local handlers, ids, hovered = {}, {}, nil
  return {
    title = "Sidebar",
    on_mount = function(ctx)
      docked = ui.pane.get(ctx.pane_id)
      state.ui.sidebar_docked = true
      refresh_layout()
    end,
    on_unmount = function(ctx)
      if docked and docked.id == ctx.pane_id then
        docked = nil
        state.ui.sidebar_docked = false
        -- Closing the pane undocks back to the overlay unless dock()/toggle hid it.
        state.ui.sidebar_visible = state.ui.mounted_sidebar ~= nil and not hide_on_close
        hide_on_close = false
        refresh_layout()
      end
    end,
    render = function(ctx)
      local widget = state.ui.mounted_sidebar
      if not widget then
        return c.column(
          { c.text("No sidebar mounted", { fg = ctx.theme.muted or ctx.theme.fg }) },
          {
            width = "grow",
            height = "grow",
            padding = 8,
          }
        )
      end
      -- Pane hover is reported by node id; fire the span enter/leave handlers.
      local now = ctx.hovered_id and ids[ctx.hovered_id] or nil
      if now ~= hovered then
        content.call(handlers, hovered, "on_mouse_leave", { id = hovered })
        content.call(handlers, now, "on_mouse_enter", { id = now })
        hovered = now
      end
      local tree
      tree, handlers, ids = content.render(widget, ctx)
      return tree
    end,
  }
end)

local M = {}

function M.is_docked()
  return docked ~= nil or state.ui.sidebar_docked == true
end

function M.invalidate()
  if docked then
    docked:invalidate()
    return true
  end
  return false
end

--- Close the docked pane; `hide` leaves the sidebar hidden instead of an overlay.
function M.close(hide)
  if not docked then
    return false
  end
  hide_on_close = hide == true
  return docked:close()
end

function M.dock(opts)
  opts = opts or {}
  local widget = state.ui.mounted_sidebar
  if not widget or docked then
    return nil
  end
  local current = util.safe_call(hollow.term.current_pane, nil)
  local size = current and current.size or {}
  local window_width = shared.window_size_snapshot().width
  local width = math.max(1, math.floor(tonumber(widget.width) or 24))
  -- Edge panes split the whole layout, so size them against the window.
  local ratio = opts.ratio
  if not ratio then
    local cell_w = (size.cols or 0) > 0 and (size.width or 0) / size.cols or 0
    ratio = cell_w > 0 and window_width > 0 and width * cell_w / window_width or 0.25
    ratio = math.max(0.1, math.min(0.5, ratio))
  end
  local previous = current and current.id
  local pane = ui.pane.split({
    module = MODULE,
    edge = opts.edge or (widget.side == "right" and "right" or "left"),
    ratio = ratio,
    on_complete = function(result)
      if not result.success then
        docked = nil
        state.ui.sidebar_docked = false
        refresh_layout()
      elseif previous and opts.focus ~= true then
        -- A sidebar is chrome: keep focus on the pane the user was working in.
        pcall(hollow.term.focus_pane_by_id, previous)
      end
    end,
  })
  if pane then
    docked = pane
    state.ui.sidebar_docked = true
    refresh_layout()
  end
  return pane
end

return M
