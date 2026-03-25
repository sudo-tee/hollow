-- src/core/split.lua
-- Recursive binary split tree.
-- Each node is either a Leaf (wraps a Pane) or a Split (horizontal/vertical).
--
-- Layout: every node knows its pixel rect {x,y,w,h}.
-- Splits store a ratio (0..1) indicating where the divider falls.
-- Traversal is depth-first; the focused pane is tracked by the Tab above.

local Pane   = require("src.core.pane")
local Config = require("src.core.config")

-- ── Helpers ─────────────────────────────────────────────────────────────────
local CHAR_W = 8  -- will be overridden from renderer
local CHAR_H = 16
local CELL_W_PX = 8
local CELL_H_PX = 16

local function px_to_cells(w, h)
    return math.floor(w / CHAR_W), math.floor(h / CHAR_H)
end

-- ── Node types ───────────────────────────────────────────────────────────────

local Leaf = {}
Leaf.__index = Leaf

function Leaf.new(rect, opts)
    local self = setmetatable({}, Leaf)
    self.kind  = "leaf"
    self.rect  = rect
    opts = opts or {}
    opts.px_rect = rect
    opts.cell_w = CELL_W_PX
    opts.cell_h = CELL_H_PX
    local cols, rows = px_to_cells(rect.w, rect.h)
    self.pane  = Pane.new(cols, rows, opts)
    return self
end

function Leaf:get_pane_at(x, y)
    if x >= self.rect.x and x < self.rect.x + self.rect.w and
       y >= self.rect.y and y < self.rect.y + self.rect.h then
        return self.pane
    end
    return nil
end

function Leaf:all_panes(t)
    t = t or {}
    table.insert(t, self.pane)
    return t
end

function Leaf:relayout(rect)
    self.rect = rect
    self.pane.px_rect = rect
    local cols, rows = px_to_cells(rect.w, rect.h)
    self.pane:resize(cols, rows, CELL_W_PX, CELL_H_PX)
end

function Leaf:update() self.pane:update() end
function Leaf:destroy() self.pane:destroy() end


local SplitNode = {}
SplitNode.__index = SplitNode

-- dir = "h" (left|right) or "v" (top|bottom)
function SplitNode.new(rect, dir, ratio, child_a, child_b)
    local self = setmetatable({}, SplitNode)
    self.kind    = "split"
    self.rect    = rect
    self.dir     = dir   -- "h" or "v"
    self.ratio   = ratio or 0.5
    self.child_a = child_a
    self.child_b = child_b
    return self
end

function SplitNode:rects()
    local r = self.rect
    if self.dir == "h" then
        local split_x = r.x + math.floor(r.w * self.ratio)
        local gap = Config.get("split_gap") or 1
        return
            {x = r.x,         y = r.y, w = split_x - r.x - gap, h = r.h},
            {x = split_x + gap, y = r.y, w = r.w - (split_x - r.x) - gap, h = r.h}
    else
        local split_y = r.y + math.floor(r.h * self.ratio)
        local gap = Config.get("split_gap") or 1
        return
            {x = r.x, y = r.y,         w = r.w, h = split_y - r.y - gap},
            {x = r.x, y = split_y + gap, w = r.w, h = r.h - (split_y - r.y) - gap}
    end
end

function SplitNode:relayout(rect)
    self.rect = rect
    local ra, rb = self:rects()
    self.child_a:relayout(ra)
    self.child_b:relayout(rb)
end

function SplitNode:get_pane_at(x, y)
    return self.child_a:get_pane_at(x, y)
        or self.child_b:get_pane_at(x, y)
end

function SplitNode:all_panes(t)
    t = t or {}
    self.child_a:all_panes(t)
    self.child_b:all_panes(t)
    return t
end

function SplitNode:update()
    self.child_a:update()
    self.child_b:update()
end

function SplitNode:destroy()
    self.child_a:destroy()
    self.child_b:destroy()
end

-- ── Public API ───────────────────────────────────────────────────────────────

local M = {}

-- Override cell size used for px_to_cells
function M.set_cell_size(cw, ch, cell_w_px, cell_h_px)
    CHAR_W = cw
    CHAR_H = ch
    CELL_W_PX = cell_w_px or cw
    CELL_H_PX = cell_h_px or ch
end

-- Create a root leaf
function M.new_root(rect, opts)
    return Leaf.new(rect, opts)
end

-- Split an existing leaf node, returning the new root subtree
-- leaf_pane: the Pane whose Leaf we want to split
-- root: current root node
-- dir: "h" or "v"
-- returns new root node, new Pane
function M.split(root, target_pane, dir, opts)
    local function do_split(node)
        if node.kind == "leaf" then
            if node.pane == target_pane then
                -- Split this leaf
                local ra, rb = (function()
                    local r = node.rect
                    if dir == "h" then
                        local half = math.floor(r.w / 2)
                        return
                            {x=r.x, y=r.y, w=half, h=r.h},
                            {x=r.x+half, y=r.y, w=r.w-half, h=r.h}
                    else
                        local half = math.floor(r.h / 2)
                        return
                            {x=r.x, y=r.y, w=r.w, h=half},
                            {x=r.x, y=r.y+half, w=r.w, h=r.h-half}
                    end
                end)()
                node:relayout(ra)
                local new_leaf = Leaf.new(rb, opts)
                return SplitNode.new(node.rect, dir, 0.5, node, new_leaf),
                       new_leaf.pane
            end
            return node, nil
        else
            local new_a, pane_a = do_split(node.child_a)
            if pane_a then
                node.child_a = new_a
                return node, pane_a
            end
            local new_b, pane_b = do_split(node.child_b)
            if pane_b then
                node.child_b = new_b
                return node, pane_b
            end
            return node, nil
        end
    end
    return do_split(root)
end

-- Close a pane, pruning the tree. Returns new root (may be nil if last pane).
function M.close_pane(root, target_pane)
    if root.kind == "leaf" then
        if root.pane == target_pane then
            root:destroy()
            return nil
        end
        return root
    end

    local function prune(node, target)
        if node.kind == "leaf" then
            return node, node.pane == target
        end
        local new_a, killed_a = prune(node.child_a, target)
        if killed_a then
            node.child_a:destroy()
            -- Replace the split with the surviving child, relayouted
            node.child_b:relayout(node.rect)
            return node.child_b, false
        end
        local new_b, killed_b = prune(node.child_b, target)
        if killed_b then
            node.child_b:destroy()
            node.child_a:relayout(node.rect)
            return node.child_a, false
        end
        node.child_a = new_a
        node.child_b = new_b
        return node, false
    end

    local new_root, _ = prune(root, target_pane)
    return new_root
end

return M
