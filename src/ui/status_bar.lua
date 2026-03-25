-- src/ui/status_bar.lua
-- A fully scriptable status bar drawn at the bottom of the window.
-- Inspired by WezTerm's wezterm.status_bar_*
--
-- Each "segment" is a table: { text, fg, bg, sep }
-- Users call ghostty.status_bar.set_left({...}) / set_right({...})
-- from their init.lua.

local Config = require("src.core.config")

local M = {}

-- Segments (set by user scripts or defaults)
local left_segments  = {}
local right_segments = {}

local bar_h  = nil
local colors = nil
local font   = nil

local function init()
    if bar_h then return end
    bar_h  = Config.get("status_bar_height") or 22
    colors = Config.get("colors")
    font   = love.graphics.newFont(11)
end

-- ── Default segments ──────────────────────────────────────────────────────────

local function default_left(workspace, active_tab, focused_pane)
    local ws_name = workspace and workspace.name or "?"
    local segs = {
        { text = "  " .. ws_name .. "  ", fg = {1,1,1,1}, bg = {0.20,0.35,0.65,1} },
    }
    if focused_pane then
        local title = focused_pane.title or ""
        if title ~= "" then
            table.insert(segs, { text = "  " .. title .. "  ", fg = {0.80,0.80,0.80,1} })
        end
    end
    return segs
end

local function default_right(workspace, active_tab, focused_pane)
    local segs = {}
    -- Workspace index / count
    if workspace then
        table.insert(segs, { text = "  ws  ", fg = {0.55,0.55,0.55,1} })
    end
    -- Clock
    local t = os.date("%H:%M")
    table.insert(segs, { text = "  " .. t .. "  ", fg = {0.80,0.80,0.80,1}, bg = {0.10,0.10,0.15,1} })
    return segs
end

-- ── Public API (called by user scripts) ──────────────────────────────────────

function M.set_left(fn_or_table)
    left_segments = fn_or_table
end

function M.set_right(fn_or_table)
    right_segments = fn_or_table
end

-- ── Drawing ───────────────────────────────────────────────────────────────────

local function resolve_segments(def, workspace, active_tab, focused_pane)
    if type(def) == "function" then
        local ok, result = pcall(def, workspace, active_tab, focused_pane)
        if ok and type(result) == "table" then return result end
        return {}
    elseif type(def) == "table" and #def > 0 then
        return def
    end
    return {}
end

local function draw_segments(segs, start_x, y, align)
    -- align = "left" or "right"
    -- For right-aligned, measure total width first
    local total_w = 0
    local saved = love.graphics.getFont()
    love.graphics.setFont(font)

    local rendered = {}
    for _, seg in ipairs(segs) do
        local tw = font:getWidth(seg.text)
        table.insert(rendered, { seg = seg, tw = tw })
        total_w = total_w + tw
    end

    local x = start_x
    if align == "right" then
        x = start_x - total_w
    end

    for _, r in ipairs(rendered) do
        local seg = r.seg
        local tw  = r.tw

        -- Background
        local bg = seg.bg or colors.status_bar_bg
        love.graphics.setColor(bg[1], bg[2], bg[3], bg[4] or 1)
        love.graphics.rectangle("fill", x, y, tw, bar_h)

        -- Text
        local fg = seg.fg or colors.status_bar_fg
        love.graphics.setColor(fg[1], fg[2], fg[3], fg[4] or 1)
        local ty = math.floor(y + (bar_h - font:getHeight()) / 2)
        love.graphics.print(seg.text, math.floor(x), ty)

        x = x + tw
    end

    love.graphics.setFont(saved)
    love.graphics.setColor(1, 1, 1, 1)
end

function M.draw(workspace, active_tab, focused_pane)
    init()

    local win_w, win_h = love.graphics.getDimensions()
    local y = win_h - bar_h

    -- Background
    local bg = colors.status_bar_bg
    love.graphics.setColor(bg[1], bg[2], bg[3], bg[4])
    love.graphics.rectangle("fill", 0, y, win_w, bar_h)

    -- Separator line
    love.graphics.setColor(0.18, 0.18, 0.25, 1)
    love.graphics.rectangle("fill", 0, y, win_w, 1)

    -- Resolve segments (fallback to defaults if empty)
    local lsegs = resolve_segments(left_segments, workspace, active_tab, focused_pane)
    if #lsegs == 0 then lsegs = default_left(workspace, active_tab, focused_pane) end

    local rsegs = resolve_segments(right_segments, workspace, active_tab, focused_pane)
    if #rsegs == 0 then rsegs = default_right(workspace, active_tab, focused_pane) end

    draw_segments(lsegs, 0,     y, "left")
    draw_segments(rsegs, win_w, y, "right")
end

return M
