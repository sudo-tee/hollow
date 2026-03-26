-- src/ui/tab_bar.lua
-- Draws the tab bar at the top of each workspace content area.
-- Supports click-to-switch. Tab titles follow the focused pane's OSC-2 title.

local Config = require("src.core.config")
local Window = require("src.core.window")

local M = {}

local tab_bar_h = nil
local colors    = nil
local font      = nil

local function init()
    if tab_bar_h then return end
    tab_bar_h = Config.get("tab_bar_height") or 26
    colors    = Config.get("colors")
    font      = love.graphics.newFont(12)
end

-- Stored tab rects for hit-testing
local tab_rects = {}
local plus_rect = nil

local function point_in_rect(x, y, rect)
    return rect and x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h
end

function M.draw(workspace, active_tab)
    init()

    local r = workspace.rect
    local y = r.y
    local bar_bg = colors.tab_bar_bg
    love.graphics.setColor(bar_bg[1], bar_bg[2], bar_bg[3], bar_bg[4])
    love.graphics.rectangle("fill", r.x, y, r.w, tab_bar_h)

    tab_rects = {}
    plus_rect = nil

    local x = r.x
    local tab_pad_x = 14
    local min_tab_w = 100
    local saved_font = love.graphics.getFont()
    love.graphics.setFont(font)

    for i, tab in ipairs(workspace.tabs) do
        local is_active = (tab == active_tab)
        local title = tab.title or ("Tab " .. i)
        local tw = math.max(min_tab_w, font:getWidth(title) + tab_pad_x * 2)

        -- Background
        local bg = is_active and colors.tab_active or colors.tab_inactive
        love.graphics.setColor(bg[1], bg[2], bg[3], bg[4])
        love.graphics.rectangle("fill", x, y, tw, tab_bar_h)

        -- Active indicator (bottom line)
        if is_active then
            local cur = Config.get("colors").cursor
            love.graphics.setColor(cur[1], cur[2], cur[3], 1)
            love.graphics.rectangle("fill", x, y + tab_bar_h - 2, tw, 2)
        end

        -- Title
        local fg = colors.tab_text
        local alpha = is_active and 1.0 or 0.55
        love.graphics.setColor(fg[1], fg[2], fg[3], alpha)
        local ty = math.floor(y + (tab_bar_h - font:getHeight()) / 2)
        love.graphics.print(title, math.floor(x + tab_pad_x), ty)

        -- Bell indicator
        if tab.focused and tab.focused.bell then
            love.graphics.setColor(1, 0.4, 0.4, 1)
            love.graphics.circle("fill", x + tw - 8, y + 8, 4)
        end

        tab_rects[i] = {x = x, y = y, w = tw, h = tab_bar_h, tab = tab, idx = i}
        x = x + tw

        -- Separator
        love.graphics.setColor(0.15, 0.15, 0.20, 1)
        love.graphics.rectangle("fill", x, y, 1, tab_bar_h)
        x = x + 1
    end

    -- "+" new tab button
    local plus_w = 30
    love.graphics.setColor(0.18, 0.18, 0.25, 1)
    love.graphics.rectangle("fill", x, y, plus_w, tab_bar_h)
    love.graphics.setColor(0.60, 0.60, 0.60, 1)
    local ty = math.floor(y + (tab_bar_h - font:getHeight()) / 2)
    love.graphics.print("+", math.floor(x + 9), ty)
    plus_rect = {x = x, y = y, w = plus_w, h = tab_bar_h}

    love.graphics.setFont(saved_font)
    love.graphics.setColor(1, 1, 1, 1)
end

function M.mousepressed(workspace, x, y, button)
    if button ~= 1 then return false end

    local r = workspace.rect
    if y < r.y or y >= r.y + tab_bar_h or x < r.x or x >= r.x + r.w then
        return false
    end

    if point_in_rect(x, y, plus_rect) then
        workspace:new_tab()
        return true
    end

    for _, rect in ipairs(tab_rects) do
        if point_in_rect(x, y, rect) then
            workspace:switch_tab(rect.idx)
            return true
        end
    end

    if Window.begin_drag() then
        return true
    end

    return true
end

return M
