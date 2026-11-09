-- Example: a right-edge Lazygit PTY that survives hide/show toggles.
-- Load this during config setup (requires lazygit in the current domain).
-- This keeps the TUI alive while Hollow remains running; it is NOT
-- detached persistence across application restarts.
--
-- The pane is found by tag rather than a Lua table, so the toggle keeps
-- working after a config reload and for panes restored from a saved
-- workspace (tags, edge placement and hidden state are all exported).
local term = hollow.term
local TAG = "lazygit-sidebar"
local pending = {} -- tab IDs with a split in flight

local function find_panel(tab)
  for _, pane in ipairs(tab.panes or {}) do
    for _, tag in ipairs(pane.tags or {}) do
      if tag == TAG then return pane end
    end
  end
  return nil
end

hollow.keymap.set("<leader>lg", function()
  local tab = term.current_tab()
  if not tab then return end

  local pane = find_panel(tab)
  if pane then
    local show = pane.is_hidden
    term.set_pane_visible(pane.id, show)
    if show then term.focus_pane_by_id(pane.id) end
    return
  end

  local tab_id = tab.id
  if pending[tab_id] then return end
  pending[tab_id] = true
  term.split_pane({
    edge = "right",
    ratio = 0.30,
    command = "lazygit",
    command_mode = "spawn",
    close_on_exit = true,
    tag = TAG,
    on_complete = function()
      pending[tab_id] = nil
    end,
  })
end, { desc = "Toggle Lazygit PTY sidebar" })
