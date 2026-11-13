-- Keyboard-first card over a workspace whose session moved to another window.
-- Native code owns the reclaim state machine; this card only queues actions.
local hollow = _G.hollow
local ui = hollow.ui
local host = require("hollow.state").get().host_api
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")
local M = {}
local RETRY_MS = 200

-- current mirrors the latest session:takeover payload; nil hides the card.
local current, handle, nav, retry_pending

local steps = {
  idle = {
    body = "This view is frozen. Reclaim the session here, or close this local view.",
    actions = {
      { action = "reclaim", text = "Reclaim session", kind = "primary" },
      { action = "close", text = "Close local view" },
    },
    hints = { { "r", "reclaim" }, { "c", "close" } },
  },
  confirming = {
    body = "Reclaiming disconnects the other window. Continue?",
    actions = {
      { action = "confirm", text = "Confirm reclaim", kind = "destructive" },
      { action = "cancel", text = "Cancel" },
    },
    hints = { { "y", "confirm" }, { "n/Esc", "cancel" } },
  },
  connecting = {
    body = "Reclaiming the session. The frozen view stays until it is ready.",
    actions = {
      { text = "Reclaiming…", kind = "primary" },
      { action = "close", text = "Close local view" },
    },
    hints = { { "c", "close" } },
    selected = 2,
  },
  failed = {
    actions = {
      { action = "reclaim", text = "Retry reclaim", kind = "primary" },
      { action = "close", text = "Close local view" },
    },
    hints = { { "r", "retry" }, { "c", "close" } },
  },
}

local shortcuts = {
  idle = { r = "reclaim", c = "close" },
  confirming = { y = "confirm", n = "cancel", escape = "cancel" },
  connecting = { c = "close" },
  failed = { r = "reclaim", c = "close" },
}

local function body(view)
  if view.phase == "failed" then
    return "Reclaim failed: " .. (view.reason or "Unknown") .. ". The frozen view is kept."
  end
  return steps[view.phase].body
end

local function act(action)
  if action and current then
    host.session_takeover_action(current.workspace_id, action)
  end
end

local function activate(index)
  local step = current and steps[current.phase]
  act(step and step.actions[index] and step.actions[index].action)
end

local function keys(key, mods)
  if not current then
    return false
  end
  -- Leader chords and global bindings stay usable over the frozen workspace.
  if mods ~= "" and mods ~= "<S>" then
    return false
  end
  if key == "arrow_left" or key == "arrow_up" or (key == "tab" and mods == "<S>") then
    nav.prev()
  elseif key == "arrow_right" or key == "arrow_down" or key == "tab" then
    nav.next()
  elseif key == "enter" then
    activate(nav.index)
  elseif mods == "" then
    act(shortcuts[current.phase][key])
  end
  return true
end

local function render(theme, _, ctx)
  local c = ui.components
  local step = steps[current.phase]
  local actions = {}
  for index, item in ipairs(step.actions) do
    actions[index] = {
      id = "session_takeover:" .. (item.action or "pending"),
      text = item.text,
      kind = item.kind,
      disabled = item.action == nil,
      on_click = item.action and function()
        activate(index)
      end or nil,
    }
  end
  local hints = {
    width = "grow",
    height = props.cell_h(ctx),
    theme = theme,
    { "←/→", "select" },
    { "Enter", "choose" },
  }
  for _, hint in ipairs(step.hints) do
    hints[#hints + 1] = hint
  end
  return c.dialog({
    title = "Session active in another window",
    body = c.column({
      c.text(body(current), { fg = theme.fg }),
      c.gap({ height = props.cell_h(ctx) }),
      c.hints(hints),
    }, { width = "grow" }),
    actions = actions,
    selected = nav.index,
    action_padding = { x = props.cell_w(ctx), y = math.floor(props.cell_h(ctx) * 0.2) },
    theme = theme,
  })
end

local open

local function schedule_retry()
  if retry_pending or not current then
    return
  end
  retry_pending = true
  host.defer(function()
    retry_pending = false
    open()
  end, RETRY_MS)
end

open = function()
  if handle or not current then
    return
  end
  local opened
  opened = ui.modal({
    title = "Session active in another window",
    theme = shared.widget_theme("confirm"),
    width = 64,
    backdrop = true,
    exclusive = false,
    pass_unhandled_keys = true,
    render = render,
    keys = keys,
    on_unmount = function()
      if handle == opened then
        handle = nil
        -- Another surface dismissed the card; the workspace is still frozen.
        schedule_retry()
      end
    end,
  })
  if opened then
    handle = opened
  else
    -- An unfinished exclusive dialog owns the screen; never replace it.
    schedule_retry()
  end
end

local function close()
  local closing = handle
  handle = nil
  if closing then
    closing.close()
  end
end

function M.update(view)
  local phase = view and steps[view.phase] and view.phase or nil
  if not phase then
    current = nil
    close()
    return
  end
  local changed = not current or current.workspace_id ~= view.workspace_id or current.phase ~= phase
  current = { workspace_id = view.workspace_id, phase = phase, reason = view.reason }
  if changed or not nav then
    nav = ui.list_nav(#steps[phase].actions)
    nav.set(steps[phase].selected or 1)
  end
  if handle then
    handle.invalidate()
  else
    open()
  end
end

function M.setup()
  hollow.events.on("session:takeover", M.update)
end

return M
