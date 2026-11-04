-- Lightweight, pane-bound terminal Find; enters copy mode only on Tab handoff.
local hollow = _G.hollow
local ui, c = hollow.ui, hollow.ui.components
local host = require("hollow.state").get().host_api
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")
local M = {}
ui.find = M
local active, last_query, next_session = nil, "", 0

function M.close()
  if active then
    active.close()
  end
end

function M.open(opts)
  if active then
    return active
  end
  opts = opts or {}
  local pane = hollow.term.current_pane()
  if not pane or pane.kind == "lua" or require("hollow.copy_mode").is_active() then
    return nil
  end
  next_session = next_session + 1
  local session, pane_id = next_session, pane.id
  local progress = { match_count = 0, complete = false }
  local handle, listener, error_text
  local input
  local function send(operation, query)
    if not host.terminal_find(pane_id, session, operation, query or "") then
      error_text = "Rejected"
      if handle then
        handle.invalidate()
      end
      return false
    end
    error_text = nil
    return true
  end
  input = ui.text_input({
    initial = opts.query or last_query,
    on_change = function(value)
      -- Bound the same UTF-8 byte count as the native bridge.
      if #value > 8192 then
        error_text = "Too long"
        return
      end
      last_query = value
      progress = { match_count = 0, complete = value == "" }
      send("query", value)
    end,
  })
  -- Hand the query to copy mode for selection/yanking; `\V` keeps Find's
  -- literal, ASCII-case-insensitive semantics.
  local function to_copy_mode()
    local query = input.value
    M.close()
    require("hollow.copy_mode").enter()
    if query ~= "" then
      host.copy_mode_search_set_query("\\V" .. query)
    end
  end
  local keys = ui.keys(input, {
    enter = function()
      send("next")
    end,
    ["<S-enter>"] = function()
      send("prev")
    end,
    tab = to_copy_mode,
    escape = M.close,
  })
  handle = ui.modal({
    title = "Find in terminal",
    exclusive = false,
    theme = shared.widget_theme("input", opts.theme),
    width = opts.width or 60,
    align = "top_right",
    center_content = true,
    backdrop = false,
    layout_events = { "terminal_find:changed" },
    render = function(theme, _, ctx)
      local input_padding_y = 2
      local status = error_text
        or input.value ~= ""
          and string.format(
            "%d/%d%s",
            progress.match_index or 0,
            progress.match_count,
            progress.complete and "" or "…"
          )
      local row = c.row({
        c.icon({ name = "search", style = { bold = true } }),
        c.input({
          id = "find:input",
          behavior = input,
          placeholder = "Search scrollback",
          focused = true,
          focusable = false,
          padding = { x = props.cell_w(ctx) * 0.5, y = input_padding_y },
          theme = theme,
          ctx = ctx,
        }),
        c.when(status, function()
          return c.text(
            status,
            { fg = error_text and theme.error or theme.muted },
            { wrap = "none" }
          )
        end),
        c.button({
          id = "find:close",
          text = "×",
          appearance = "quiet",
          on_click = M.close,
          theme = theme,
          ctx = ctx,
        }),
      }, {
        id = "find:row",
        width = "grow",
        gap = props.cell_w(ctx),
        align_y = "center",
      })
      return row, props.cell_h(ctx) + input_padding_y * 2
    end,
    keys = function(key, mods)
      keys(key, mods)
      return true -- Never leak editing/navigation keys into the PTY.
    end,
    on_unmount = function()
      if listener then
        hollow.events.off(listener)
      end
      if active == handle then
        active = nil
      end
      host.terminal_find(pane_id, session, "close", "")
    end,
  })
  if not handle then
    return nil -- An unfinished exclusive dialog wins; no native state changed.
  end
  active = handle
  listener = hollow.events.on("terminal_find:changed", function(event)
    if event.pane_id ~= pane_id or event.session ~= session then
      return
    end
    if not event.active then
      M.close()
    elseif event.query == input.value then
      progress = event
      handle.invalidate()
    end
  end)
  last_query = input.value
  send("query", input.value)
  return handle
end

return M
