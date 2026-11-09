-- Example: a right-edge Lazygit PTY dock that survives hide/show toggles
-- and stays on screen across tab switches.
-- Load this during config setup (requires lazygit in the current domain).
-- This keeps the TUI alive while Hollow remains running; it is NOT
-- detached persistence across application restarts.
--
-- The pane is found by tag rather than a Lua table, so the toggle keeps
-- working after a config reload and for docks restored from a saved
-- workspace (tags, dock placement and hidden state are all exported).
-- Use `dock = "workspace"` for one Lazygit per workspace instead.
local term = hollow.term
local TAG = "lazygit-dock"
local pending = false -- a split is in flight

local function find_panel()
  for _, pane in ipairs(term.docks()) do
    for _, tag in ipairs(pane.tags or {}) do
      if tag == TAG then return pane end
    end
  end
  return nil
end

hollow.keymap.set("<leader>lg", function()
  local pane = find_panel()
  if pane then
    local show = pane.is_hidden
    term.set_pane_visible(pane.id, show)
    if show then term.focus_pane_by_id(pane.id) end
    return
  end

  if pending then return end
  pending = true
  term.split_pane({
    edge = "right",
    dock = "global",
    ratio = 0.30,
    command = "lazygit",
    command_mode = "spawn",
    close_on_exit = true,
    tag = TAG,
    on_complete = function()
      pending = false
    end,
  })
end, { desc = "Toggle Lazygit PTY dock" })
