-- src/core/workspace.lua
-- A Workspace holds an ordered list of Tabs, one of which is active.
-- Multiple Workspaces live in the App (switchable like i3/Sway workspaces).

local Tab    = require("src.core.tab")
local Config = require("src.core.config")

local Workspace = {}
Workspace.__index = Workspace

local next_id = 1

function Workspace.new(rect, opts)
    local self = setmetatable({}, Workspace)
    self.id          = next_id; next_id = next_id + 1
    self.name        = (opts and opts.name) or ("workspace " .. self.id)
    self.rect        = rect   -- full content area (below status bar)
    self.tabs        = {}
    self.active_idx  = 1

    -- Create the first tab automatically
    self:new_tab(opts)
    return self
end

-- ── Tab management ───────────────────────────────────────────────────────────

function Workspace:tab_rect()
    -- Content area below the tab bar
    local tab_bar_h = Config.get("tab_bar_height") or 26
    local r = self.rect
    return {x = r.x, y = r.y + tab_bar_h, w = r.w, h = r.h - tab_bar_h}
end

function Workspace:new_tab(opts)
    local tab = Tab.new(self:tab_rect(), opts)
    table.insert(self.tabs, tab)
    self.active_idx = #self.tabs
    return tab
end

function Workspace:close_tab(idx)
    idx = idx or self.active_idx
    if self.tabs[idx] then
        self.tabs[idx]:destroy()
        table.remove(self.tabs, idx)
    end
    if #self.tabs == 0 then
        return true  -- workspace is empty, caller should destroy it
    end
    self.active_idx = math.min(self.active_idx, #self.tabs)
    return false
end

function Workspace:active_tab()
    return self.tabs[self.active_idx]
end

function Workspace:switch_tab(idx)
    if self.tabs[idx] then
        self.active_idx = idx
    end
end

function Workspace:next_tab()
    self.active_idx = (self.active_idx % #self.tabs) + 1
end

function Workspace:prev_tab()
    self.active_idx = ((self.active_idx - 2) % #self.tabs) + 1
end

-- ── Proxy to active tab ──────────────────────────────────────────────────────

function Workspace:focused_pane()
    local t = self:active_tab()
    return t and t.focused
end

function Workspace:split_horizontal(opts) return self:active_tab():split_horizontal(opts) end
function Workspace:split_vertical(opts)   return self:active_tab():split_vertical(opts) end

function Workspace:close_focused_pane()
    local tab = self:active_tab()
    if not tab then return end
    local tab_empty = tab:close_focused()
    if tab_empty then
        return self:close_tab()  -- returns true if workspace now empty
    end
    return false
end

function Workspace:cycle_focus(dir) self:active_tab():cycle_focus(dir) end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

function Workspace:update()
    local tab = self:active_tab()
    if not tab then
        return true
    end
    tab:update()
    if tab.root == nil then
        return self:close_tab(self.active_idx)
    end
    return false
end

function Workspace:relayout(rect)
    self.rect = rect
    for _, tab in ipairs(self.tabs) do
        tab:relayout(self:tab_rect())
    end
end

function Workspace:get_pane_at(x, y)
    local tab = self:active_tab()
    return tab and tab:get_pane_at(x, y)
end

function Workspace:destroy()
    for _, tab in ipairs(self.tabs) do tab:destroy() end
    self.tabs = {}
end

return Workspace
