-- Example: a right-edge Claude Code PTY dock that survives hide/show toggles
-- and stays on screen across tab switches.
-- Load this during config setup (requires `claude` in the current domain).
-- This keeps the TUI alive while Hollow remains running; it is NOT
-- detached persistence across application restarts.
--
-- The dock is workspace-scoped, so each workspace gets its own agent started
-- in that workspace's directory. Use `dock = "global"` for a single agent
-- that follows you across workspaces.
--
-- The pane is found by tag rather than a Lua table, so the toggle keeps
-- working after a config reload and for docks restored from a saved
-- workspace (tags, dock placement and hidden state are all exported).
local term = hollow.term
local TAG = "claude-dock"
local pending = {} -- workspace IDs with a split in flight

local function find_panel(workspace_id)
  for _, pane in ipairs(term.docks()) do
    if pane.dock.workspace_id == workspace_id then
      for _, tag in ipairs(pane.tags or {}) do
        if tag == TAG then return pane end
      end
    end
  end
  return nil
end

hollow.keymap.set("<leader>ai", function()
  local workspace = term.current_workspace()
  if not workspace then return end

  local pane = find_panel(workspace.id)
  if pane then
    local show = pane.is_hidden
    term.set_pane_visible(pane.id, show)
    if show then term.focus_pane_by_id(pane.id) end
    return
  end

  local workspace_id = workspace.id
  if pending[workspace_id] then return end
  pending[workspace_id] = true
  term.split_pane({
    edge = "right",
    dock = "workspace",
    ratio = 0.35,
    command = "claude",
    command_mode = "spawn",
    close_on_exit = true,
    tag = TAG,
    on_complete = function()
      pending[workspace_id] = nil
    end,
  })
end, { desc = "Toggle Claude Code dock" })
