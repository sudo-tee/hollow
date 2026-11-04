-- Clipboard requests are already denied by the synchronous native callback.
-- This dialog authorizes one retry; it never retains a native request pointer.
local hollow = _G.hollow
local ui = hollow.ui
local host = require("hollow.state").get().host_api
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")
local M = {}
local active, active_pane, active_generation, last_prompt_ms

local function deny(pane_id, generation)
  if generation then
    host.clipboard_read_authorize(pane_id, false, generation)
  end
end

function M.open(pane_id, generation)
  local pane = hollow.term.current_pane()
  if not pane or pane.id ~= pane_id or pane.kind == "lua" or not ui.is_focused() then
    deny(pane_id, generation)
    return nil
  end
  if active then
    if pane_id ~= active_pane or generation ~= active_generation then
      deny(pane_id, generation)
    end
    return active
  end
  local now = hollow.util.host_now_ms(host)
  if generation and last_prompt_ms and now - last_prompt_ms < 5000 then
    deny(pane_id, generation)
    return nil
  end
  local handle, answered
  local nav = ui.list_nav(2)
  local function answer(allow)
    answered = true
    local ok = host.clipboard_read_authorize(pane_id, allow, generation)
    handle.close()
    if allow then
      if ok then
        ui.notify.info("Next clipboard read approved for this pane; retry within 30 seconds.")
      else
        ui.notify.error(
          "Clipboard approval failed: request expired, pane changed, or text exceeds 48 KiB."
        )
      end
    end
  end
  handle = ui.modal({
    title = "Allow next clipboard read?",
    theme = shared.widget_theme("confirm"),
    width = 60,
    backdrop = true,
    render = function(theme, _, ctx)
      return ui.components.dialog({
        title = "Allow next clipboard read?",
        body = (generation and "The current request was denied. " or "")
          .. "Programs in this pane, including remote programs, could read a snapshot of your clipboard once. Approval expires in 30 seconds. Retry in the application after approving.",
        actions = {
          {
            id = "clipboard:deny",
            text = "Deny",
            kind = "primary",
            on_click = function()
              answer(false)
            end,
          },
          {
            id = "clipboard:allow",
            text = "Allow once",
            kind = "destructive",
            on_click = function()
              answer(true)
            end,
          },
        },
        selected = nav.index,
        action_padding = { x = props.cell_w(ctx), y = math.floor(props.cell_h(ctx) * 0.2) },
        theme = theme,
      })
    end,
    keys = ui.keys(nav, {
      enter = function()
        answer(nav.index == 2)
      end,
      escape = function()
        handle.close()
      end,
      _else = function()
        return true
      end,
    }),
    on_unmount = function()
      active, active_pane, active_generation = nil, nil, nil
      if not answered then
        deny(pane_id, generation)
      end
    end,
  })
  if not handle then
    -- Do not replace or queue behind an unfinished exclusive dialog.
    deny(pane_id, generation)
    return nil
  end
  active, active_pane, active_generation = handle, pane_id, generation
  last_prompt_ms = now
  return handle
end

function M.setup()
  hollow.events.on("term:clipboard_read_requested", function(event)
    if type(event.pane_id) == "number" and type(event.generation) == "number" then
      M.open(event.pane_id, event.generation)
    end
  end)
  hollow.events.on("term:pane_focused", function(event)
    if active and (not event.pane or event.pane.id ~= active_pane) then
      active.close()
    end
  end)
  hollow.events.on("term:pane_closed", function(event)
    if active and event.pane and event.pane.id == active_pane then
      active.close()
    end
  end)
  hollow.events.on("window:blurred", function()
    if active then
      active.close()
    end
  end)
end

return M
