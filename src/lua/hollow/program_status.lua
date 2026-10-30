local M = {}

local priority = { done = 2, working = 3, blocked = 4, error = 5 }
local icons = { done = "✓", blocked = "!", error = "✗" }
local block_icons = { permission = "󰒃", question = "?", auth = "󰌾" }
local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local frame_ms = 100

---@param state 'idle'|'working'|'done'|'blocked'|'error'|nil
---@return HollowColor|nil
function M.color(state)
  local palette = require("hollow.theme").current().palette
  return ({
    working = palette.bright_blue,
    blocked = palette.bright_yellow,
    done = palette.bright_green,
    error = palette.bright_red,
  })[state]
end

-- Labels only: never interpret program-provided text as UI markup.
-- Returns text, state, and the next animation deadline (working only).
---@param panes HollowPane[]|nil
---@param now_ms number|nil
---@return string|nil label
---@return 'working'|'done'|'blocked'|'error'|nil state
---@return number|nil deadline
function M.badge(panes, now_ms)
  ---@type HollowProgramStatus|{ state: 'working', kind?: string, progress?: integer }|nil
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
    local activity = _G.hollow and _G.hollow.activity
    if
      activity
      and activity._shell_task(pane)
      and (not selected or priority.working > priority[selected.state])
    then
      selected = { state = "working" }
    end
  end
  if not selected then
    return nil
  end
  local label = icons[selected.state]
  local deadline
  if selected.state == "working" then
    local util = require("hollow.util")
    local now = now_ms or util.host_now_ms(require("hollow.state").get().host_api)
    local frame = math.floor(now / frame_ms)
    label = spinner[frame % #spinner + 1]
    deadline = (frame + 1) * frame_ms
  end
  if selected.state == "blocked" then
    label = block_icons[selected.kind] or label
  end
  if selected.progress ~= nil then
    label = label .. " " .. selected.progress .. "%"
  end
  return label .. " ", selected.state, deadline
end

---@param workspace HollowMuxWorkspace
---@return string|nil label
---@return 'working'|'done'|'blocked'|'error'|nil state
---@return number|nil deadline
function M.workspace_badge(workspace)
  ---@type HollowPane[]
  local panes = {}
  for _, tab in ipairs(workspace.tabs or {}) do
    for _, pane in ipairs(tab.panes or {}) do
      panes[#panes + 1] = pane
    end
  end
  return M.badge(panes)
end

---@param panes HollowPane[]|nil
---@return boolean
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
---@param pane HollowPane
---@return boolean
function M.pane_has_attention(pane)
  return pane.has_bell == true or M.needs_attention({ pane })
end

-- Only unread reports color bells; acknowledged status must not mask new attention.
---@param panes HollowPane[]|nil
---@return 'warn'|'error'|nil
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

---@param workspace HollowMuxWorkspace
---@return 'warn'|'error'|nil
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

---@param workspace HollowMuxWorkspace
---@return boolean
function M.workspace_needs_attention(workspace)
  for _, tab in ipairs(workspace.tabs or {}) do
    if M.needs_attention(tab.panes) then
      return true
    end
  end
  return false
end

return M
