-- Unsafe pastes are already blocked natively, which holds the text per pane.
-- This dialog only answers by pane and generation; the text never reaches Lua.
local hollow = _G.hollow
local ui = hollow.ui
local host = require("hollow.state").get().host_api
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")
local M = {}
local active, request

local reasons = {
  newline = "It contains line breaks and the program has not enabled bracketed paste, so each line may run as a command.",
  terminator = "It contains a bracketed-paste end sequence that could make the program run the rest as commands.",
}

local function answer_request(req, allow)
  return host.paste_confirm(req.pane_id, req.generation, allow)
end

local function describe(req)
  local size = req.bytes < 1024 and string.format("%d bytes", req.bytes)
    or string.format("%.1f KiB", req.bytes / 1024)
  return string.format(
    "%s\n\nPasting %d line%s (%s). Set paste_protection = false to skip this check.",
    reasons[req.reason] or reasons.newline,
    req.lines,
    req.lines == 1 and "" or "s",
    size
  )
end

local function warn_blocked()
  ui.notify.warn("Unsafe terminal paste rejected.", { title = "Paste blocked" })
end

function M.open(req)
  -- Context-menu pastes may target a visible pane other than the focused one;
  -- native confirmation rechecks visibility and window focus.
  if not host.pane_exists(req.pane_id) or not ui.is_focused() then
    answer_request(req, false)
    return nil
  end
  if active then
    -- Native code replaced the held text; show the newest blocked paste.
    request = req
    return active
  end
  local handle, answered
  local nav = ui.list_nav(2)
  request = req
  local function answer(allow)
    answered = true
    local ok = answer_request(request, allow)
    handle.close()
    if allow and not ok then
      ui.notify.error("Paste failed: the pane changed or lost focus.")
    end
  end
  handle = ui.modal({
    title = "Paste anyway?",
    theme = shared.widget_theme("confirm"),
    width = 60,
    backdrop = true,
    render = function(theme, _, ctx)
      return ui.components.dialog({
        title = "Paste anyway?",
        body = describe(request),
        actions = {
          {
            id = "paste_confirm:cancel",
            text = "Cancel",
            kind = "primary",
            on_click = function()
              answer(false)
            end,
          },
          {
            id = "paste_confirm:allow",
            text = "Paste anyway",
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
      local req = request
      active, request = nil, nil
      if not answered then
        answer_request(req, false)
      end
    end,
  })
  if not handle then
    -- Do not replace or queue behind an unfinished exclusive dialog.
    request = nil
    answer_request(req, false)
    warn_blocked()
    return nil
  end
  active = handle
  return handle
end

function M.setup()
  hollow.events.on("term:paste_blocked", function(event)
    if type(event.pane_id) == "number" and type(event.generation) == "number" then
      M.open({
        pane_id = event.pane_id,
        generation = event.generation,
        bytes = event.bytes or 0,
        lines = event.lines or 1,
        reason = event.reason,
      })
    end
  end)
  hollow.events.on("term:pane_focused", function(event)
    if active and (not event.pane or event.pane.id ~= request.pane_id) then
      active.close()
    end
  end)
  hollow.events.on("term:pane_closed", function(event)
    if active and event.pane and event.pane.id == request.pane_id then
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
