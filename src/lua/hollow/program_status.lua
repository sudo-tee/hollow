local M = {}

local priority = { idle = 1, done = 2, working = 3, blocked = 4, error = 5 }
local labels =
  { idle = "idle", done = "done", working = "working", blocked = "needs input", error = "error" }
local block_labels = { permission = "permission", question = "question", auth = "auth" }

-- Labels only: never interpret program-provided text as UI markup.
function M.badge(panes)
  local selected
  for _, pane in ipairs(panes or {}) do
    for _, record in ipairs(pane.program_status or {}) do
      if
        priority[record.state]
        and (not selected or priority[record.state] > priority[selected.state])
      then
        selected = record
      end
    end
  end
  if not selected then
    return nil
  end
  local label = labels[selected.state]
  if selected.state == "blocked" then
    label = block_labels[selected.kind] or label
  end
  if selected.progress ~= nil then
    label = label .. " " .. selected.progress .. "%"
  end
  return "[" .. label .. "] "
end

function M.workspace_badge(workspace)
  local panes = {}
  for _, tab in ipairs(workspace.tabs or {}) do
    for _, pane in ipairs(tab.panes or {}) do
      panes[#panes + 1] = pane
    end
  end
  return M.badge(panes)
end

function M.needs_attention(panes)
  for _, pane in ipairs(panes or {}) do
    for _, record in ipairs(pane.program_status or {}) do
      if record.attention == true then
        return true
      end
    end
  end
  return false
end

-- Both sources share the existing bell UI; protocol state stays independent.
function M.pane_has_attention(pane)
  return pane.has_bell == true or M.needs_attention({ pane })
end

-- Only unread reports color bells; acknowledged status must not mask new attention.
function M.attention_level(panes)
  local level
  for _, pane in ipairs(panes or {}) do
    if pane.has_bell == true then
      level = level or "warn"
    end
    for _, record in ipairs(pane.program_status or {}) do
      if record.attention == true then
        if record.state == "error" then
          return "error"
        end
        level = "warn"
      end
    end
  end
  return level
end

function M.workspace_attention_level(workspace)
  local level
  for _, tab in ipairs(workspace.tabs or {}) do
    local tab_level = M.attention_level(tab.panes)
    if tab_level == "error" then
      return "error"
    end
    level = level or tab_level
  end
  return level
end

function M.workspace_needs_attention(workspace)
  for _, tab in ipairs(workspace.tabs or {}) do
    if M.needs_attention(tab.panes) then
      return true
    end
  end
  return false
end

return M
