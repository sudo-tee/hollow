-- src/core/tab.lua
-- A Tab contains one split tree and tracks the focused pane.

local Split  = require("src.core.split")
local Config = require("src.core.config")

local Tab = {}
Tab.__index = Tab

local next_id = 1

function Tab.new(rect, opts)
    local self = setmetatable({}, Tab)
    self.id       = next_id; next_id = next_id + 1
    self.title    = opts and opts.title or "tab"
    self.rect     = rect   -- content area (pixels), below tab bar
    self.root     = Split.new_root(rect, opts)
    self.focused  = self.root.pane  -- the currently-focused Pane
    return self
end

-- ── Splits ───────────────────────────────────────────────────────────────────

function Tab:split_horizontal(opts)
    local new_root, new_pane = Split.split(self.root, self.focused, "h", opts)
    self.root    = new_root
    self.focused = new_pane
    return new_pane
end

function Tab:split_vertical(opts)
    local new_root, new_pane = Split.split(self.root, self.focused, "v", opts)
    self.root    = new_root
    self.focused = new_pane
    return new_pane
end

-- ── Focus navigation ─────────────────────────────────────────────────────────

function Tab:all_panes()
    return self.root:all_panes()
end

function Tab:focus_pane(pane)
    self.focused = pane
end

-- Cycle focus among panes (dir = 1 or -1)
function Tab:cycle_focus(dir)
    local panes = self:all_panes()
    if #panes <= 1 then return end
    for i, p in ipairs(panes) do
        if p == self.focused then
            local next_i = ((i - 1 + dir) % #panes) + 1
            self.focused = panes[next_i]
            return
        end
    end
end

-- ── Close pane ───────────────────────────────────────────────────────────────

-- Returns true if the tab is now empty (should be destroyed)
function Tab:close_focused()
    local old = self.focused
    local panes = self:all_panes()

    -- Pick a new pane to focus before destroying
    if #panes > 1 then
        for i, p in ipairs(panes) do
            if p == old then
                self.focused = panes[i > 1 and i - 1 or 2]
                break
            end
        end
    end

    self.root = Split.close_pane(self.root, old)
    return self.root == nil
end

-- ── Resize ───────────────────────────────────────────────────────────────────

function Tab:relayout(rect)
    self.rect = rect
    self.root:relayout(rect)
end

-- ── Update / title ───────────────────────────────────────────────────────────

function Tab:update()
    if self.root then self.root:update() end

    while self.root do
        local dead = nil
        for _, pane in ipairs(self:all_panes()) do
            if not pane:is_alive() then
                dead = pane
                break
            end
        end
        if not dead then
            break
        end
        self.root = Split.close_pane(self.root, dead)
        if self.root then
            local panes = self:all_panes()
            if self.focused == dead or not self.focused or not self.focused:is_alive() then
                self.focused = panes[1]
            end
        else
            self.focused = nil
        end
    end

    -- Tab title follows focused pane title
    if self.focused then
        self.title = self.focused.title
    end
end

function Tab:get_pane_at(x, y)
    return self.root and self.root:get_pane_at(x, y)
end

function Tab:destroy()
    if self.root then self.root:destroy() end
    self.root = nil
end

return Tab
