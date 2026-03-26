-- src/renderer/stats.lua
-- Per-frame renderer statistics and on-screen debug overlay.
--
-- Usage:
--   local Stats = require("src.renderer.stats")
--   local stats = Stats.stats   -- alias for zero-overhead counter increments
--
--   Stats.begin_frame()          -- reset counters, record frame start time
--   -- ... draw things, increment stats.xxx fields inline ...
--   Stats.end_frame()            -- compute frame_time_ms
--   Stats.draw_debug_overlay()   -- optional HUD (only shown when enabled)

local M = {}

-- ── Stats table ───────────────────────────────────────────────────────────────
-- Exposed directly (as M.stats) so the hot draw path can write counters
-- without incurring Lua function-call overhead:
--   stats.glyph_draws = stats.glyph_draws + 1
M.stats = {
	frame_time_ms = 0,
	fps = 0,
	panes_drawn = 0,
	canvas_full_redraws = 0,
	canvas_partial_redraws = 0,
	canvas_skipped = 0,
	rows_redrawn = 0,
	cells_visited = 0,
	glyph_draws = 0,
	bg_rect_draws = 0,
	underline_draws = 0,
	font_switches = 0,
	set_color_calls = 0,
}

local _frame_start_time = 0
local _debug_overlay_enabled = false
local _debug_font = nil -- lazily created small font for the overlay
-- Exponential moving average for FPS smoothing so the HUD is readable.
local _fps_ema = 0
local _ema_alpha = 1 / 30 -- smoothing over ~30 frames (adjustable)
-- HUD update throttle: update displayed text at most every 200ms
local _hud_update_interval = 0.2
local _last_hud_update_time = 0
local _cached_lines = nil

-- ── Frame lifecycle ───────────────────────────────────────────────────────────

-- Reset all counters and record the frame start time.
-- Call once at the beginning of each draw frame, before drawing any panes.
function M.begin_frame()
	_frame_start_time = love.timer.getTime()
	local s = M.stats
	-- Reset frame timing values; fps computed in end_frame
	s.frame_time_ms = 0
	s.fps = 0
	s.panes_drawn = 0
	s.canvas_full_redraws = 0
	s.canvas_partial_redraws = 0
	s.canvas_skipped = 0
	s.rows_redrawn = 0
	s.cells_visited = 0
	s.glyph_draws = 0
	s.bg_rect_draws = 0
	s.underline_draws = 0
	s.font_switches = 0
	s.set_color_calls = 0
end

-- Compute frame_time_ms from the start time recorded by begin_frame().
-- Call once at the end of each draw frame.
function M.end_frame()
	M.stats.frame_time_ms = (love.timer.getTime() - _frame_start_time) * 1000
	-- Compute FPS (guard against zero frame time)
	local ft = M.stats.frame_time_ms
	if ft > 0 then
		M.stats.fps = 1000 / ft
	else
		M.stats.fps = 0
	end
	-- Update smoothed FPS (exponential moving average)
	if _fps_ema == 0 then
		_fps_ema = M.stats.fps
	else
		_fps_ema = _fps_ema + (M.stats.fps - _fps_ema) * _ema_alpha
	end
	M.stats.fps_smoothed = _fps_ema
end

-- Returns the current stats table.  Values are reset by begin_frame().
function M.get_stats()
	return M.stats
end

-- ── Debug overlay ─────────────────────────────────────────────────────────────

-- Enable or disable the on-screen debug overlay.
function M.set_debug_overlay(enabled)
	_debug_overlay_enabled = enabled
end

-- Toggle the on-screen debug overlay and return the new state.
function M.toggle_debug_overlay()
	_debug_overlay_enabled = not _debug_overlay_enabled
	return _debug_overlay_enabled
end

function M.get_debug_overlay()
	return _debug_overlay_enabled
end

-- Draw a compact stats HUD in the top-right corner of the window.
-- Call after all panes and other UI elements have been drawn.
function M.draw_debug_overlay()
	if not _debug_overlay_enabled then
		return
	end
	if not _debug_font then
		-- Size 10 is intentionally small — the overlay is a compact status
		-- widget and should not obscure terminal content.
		_debug_font = love.graphics.newFont(10)
	end
    local win_w = love.graphics.getWidth()
    local s = M.stats
    -- Throttle HUD text updates so the overlay is readable. Use cached
    -- lines when called more frequently than _hud_update_interval.
    local now = love.timer.getTime()
    if not _cached_lines or (now - _last_hud_update_time) >= _hud_update_interval then
        local fps = s.fps_smoothed or s.fps or 0
        _cached_lines = {
            string.format("frame: %.2f ms  fps: %.1f", s.frame_time_ms, fps),
            string.format(
                "panes: %d  full:%d  part:%d  skip:%d",
                s.panes_drawn,
                s.canvas_full_redraws,
                s.canvas_partial_redraws,
                s.canvas_skipped
            ),
            string.format("rows:%d  cells:%d  glyphs:%d", s.rows_redrawn, s.cells_visited, s.glyph_draws),
            string.format(
                "bgr:%d  ul:%d  fsw:%d  clr:%d",
                s.bg_rect_draws,
                s.underline_draws,
                s.font_switches,
                s.set_color_calls
            ),
        }
        _last_hud_update_time = now
    end
    local lines = _cached_lines
	local pad_x = 6
	local pad_y = 4
	local line_h = 14
	local box_w = 244
	local box_h = #lines * line_h + pad_y * 2
	local bx = win_w - box_w - 4
	local by = 4

	local saved_font = love.graphics.getFont()
	love.graphics.setFont(_debug_font)
	love.graphics.setColor(0, 0, 0, 0.72)
	love.graphics.rectangle("fill", bx, by, box_w, box_h)
	love.graphics.setColor(0.9, 0.9, 0.2, 1)
	for i, line in ipairs(lines) do
		love.graphics.print(line, bx + pad_x, by + pad_y + (i - 1) * line_h)
	end
	love.graphics.setFont(saved_font)
	love.graphics.setColor(1, 1, 1, 1)
end

return M
