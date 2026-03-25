-- src/renderer/terminal.lua
-- Renders panes using the ghostty render_state row/cell iterator API.
--
-- This follows ghostling's render_terminal() pattern exactly:
--   1. ghostty_render_state_colors_get → get palette/default fg/bg
--   2. ghostty_render_state_get(RS_DATA_ROW_ITERATOR, &row_iter) → populate iterator
--   3. while row_iterator_next(row_iter):
--        ghostty_render_state_row_get(ROW_DATA_CELLS, &cells) → attach cells to row
--        while row_cells_next(cells):
--          read GRAPHEMES_LEN, GRAPHEMES_BUF, STYLE, FG_COLOR, BG_COLOR
--          draw background quad, glyph, underline, bold
--   4. draw cursor (as screen-space overlay, not baked into the pane canvas)
--
-- HiDPI notes:
--   • conf.lua must set t.window.highdpi = true
--   • Fonts are loaded at LOGICAL size (no manual DPI multiply).
--     Love2D's HiDPI path rasterises at the correct physical resolution
--     internally, so multiplying by getDPIScale() would double-scale and
--     produce blurry output.
--   • All draw coordinates are logical pixels.  The OS compositor handles
--     the physical→display mapping.
--   • Font atlas filter is "linear"/"linear" — nearest is only correct for
--     integer 1× displays; on any HiDPI or fractional-DPI display it
--     produces jagged glyphs.
--
-- Dirty-row pane caching:
--   Each pane has a persistent canvas.  Frames where the render state is
--   not dirty skip all row iteration and just blit the cached canvas.
--   When the render state is dirty the renderer iterates rows and redraws
--   only the rows that carry the per-row DIRTY flag, preserving unchanged
--   rows in the canvas.  A full invalidation (resize, font change, initial
--   render) forces a clear + full redraw.
local ffi = require("ffi")
local bit = require("bit")
local gffi = require("src.core.ghostty_ffi")
local Config = require("src.core.config")
local lib = gffi.lib
local M = {}

-- ── Renderer state ────────────────────────────────────────────────────────────
local font_normal = nil
local font_bold = nil
local font_italic = nil
local font_bold_italic = nil
local font_normal_ss = nil
local font_bold_ss = nil
local font_italic_ss = nil
local font_bold_italic_ss = nil
local char_w = 8
local char_h = 16
local baseline_offset = 0 -- pixels from cell top to font baseline
local cfg_colors = nil
local font_supersample = 1
-- pane_canvas_cache[pane] = { canvas, w, h, dirty_all }
local pane_canvas_cache = setmetatable({}, { __mode = "k" })
local codepoints_to_utf8

-- ── Per-frame renderer statistics ────────────────────────────────────────────
-- Counters are reset by M.begin_frame() and finalized by M.end_frame().
-- Overhead is a handful of integer increments per draw operation — low
-- enough to keep enabled during development.
local stats = {
	frame_time_ms          = 0,
	panes_drawn            = 0,
	canvas_full_redraws    = 0,
	canvas_partial_redraws = 0,
	canvas_skipped         = 0,
	rows_redrawn           = 0,
	cells_visited          = 0,
	glyph_draws            = 0,
	bg_rect_draws          = 0,
	underline_draws        = 0,
	font_switches          = 0,
	set_color_calls        = 0,
}
local _frame_start_time = 0
local _debug_overlay_enabled = false
local _debug_font = nil -- lazily created small font for the overlay

-- ── Load a font at LOGICAL size ───────────────────────────────────────────────
-- Do NOT multiply size by getDPIScale() here.  With t.window.highdpi = true
-- Love2D handles the physical rasterisation automatically.  If you also
-- multiply the size you end up loading at (size * dpi²) which is too large
-- and then gets scaled back down blurry.
local function load_font(path, size, hinting)
	-- Try Love2D virtual FS first (relative paths / files inside project dir)
	if love.filesystem.getInfo(path) then
		print("[renderer] Loading font from virtual FS: " .. path)
		return love.graphics.newFont(path, size, hinting)
	end
	-- Fall back to native IO for absolute paths outside the project dir
	local f, err = io.open(path, "rb")
	if not f then
		error("Could not open file " .. path .. ": " .. tostring(err))
	end
	local data = f:read("*a")
	f:close()
	local filedata = love.filesystem.newFileData(data, path)
	return love.graphics.newFont(filedata, size, hinting)
end

-- Apply shared settings to every loaded font object.
-- "linear" filtering is correct for HiDPI / fractional-DPI displays.
-- "nearest" only works cleanly on integer-scale (1×) displays and produces
-- jagged diagonals on everything else.
local function configure_font(font)
	font:setFilter("linear", "linear")
	font:setLineHeight(1.0) -- control row height through char_h directly
	return font
end

-- ── Style-variant path helpers ────────────────────────────────────────────────
local function style_candidates(path, from_pat, repls)
	local out, seen = {}, {}
	if type(repls) == "string" then
		repls = { repls }
	end
	for _, repl in ipairs(repls) do
		local candidate, n = path:gsub(from_pat, repl, 1)
		if n > 0 and candidate ~= path and not seen[candidate] then
			seen[candidate] = true
			out[#out + 1] = candidate
		end
	end
	return out
end

local function font_exists(path)
	if love.filesystem.getInfo(path) then
		return true
	end
	local f = io.open(path, "rb")
	if f then
		f:close()
		return true
	end
	return false
end

local function derive_font_variant(base_path, kind)
	if not base_path then
		return nil
	end
	local candidates = {}
	local function add(list)
		for _, item in ipairs(list) do
			candidates[#candidates + 1] = item
		end
	end
	if kind == "bold" then
		add(style_candidates(base_path, "Regular([%._-])", "Bold%1"))
		add(style_candidates(base_path, "Regular%.", { "Bold.", "Medium." }))
		add(style_candidates(base_path, "%-Regular", { "-Bold", "-Medium" }))
	elseif kind == "italic" then
		add(style_candidates(base_path, "Regular([%._-])", "Italic%1"))
		add(style_candidates(base_path, "Regular%.", { "Italic." }))
		add(style_candidates(base_path, "%-Regular", { "-Italic" }))
	elseif kind == "bold_italic" then
		add(style_candidates(base_path, "Regular([%._-])", "BoldItalic%1"))
		add(style_candidates(base_path, "Regular%.", { "BoldItalic.", "MediumItalic." }))
		add(style_candidates(base_path, "%-Regular", { "-BoldItalic", "-MediumItalic" }))
	end
	for _, candidate in ipairs(candidates) do
		if font_exists(candidate) then
			return candidate
		end
	end
	return nil
end

local function load_font_family(font_path, font_size, font_hinting)
	local family = {}
	local font_bold_path = Config.get("font_bold_path")
	local font_italic_path = Config.get("font_italic_path")
	local font_bold_italic_path = Config.get("font_bold_italic_path")

	if font_path then
		family.normal = configure_font(load_font(font_path, font_size, font_hinting))
	else
		family.normal = configure_font(love.graphics.newFont(font_size, font_hinting))
	end

	family.bold = family.normal
	family.italic = family.normal
	family.bold_italic = family.normal

	if font_path then
		local bold_path = font_bold_path or derive_font_variant(font_path, "bold")
		local italic_path = font_italic_path or derive_font_variant(font_path, "italic")
		local bold_italic_path = font_bold_italic_path or derive_font_variant(font_path, "bold_italic")

		if bold_path then
			family.bold = configure_font(load_font(bold_path, font_size, font_hinting))
			print("[renderer] Loading bold font: " .. bold_path)
		end
		if italic_path then
			family.italic = configure_font(load_font(italic_path, font_size, font_hinting))
			print("[renderer] Loading italic font: " .. italic_path)
		end
		if bold_italic_path then
			family.bold_italic = configure_font(load_font(bold_italic_path, font_size, font_hinting))
			print("[renderer] Loading bold italic font: " .. bold_italic_path)
		end
	end

	return family
end

-- ── Stats API ─────────────────────────────────────────────────────────────────

-- Call once at the start of each draw frame (before drawing any panes).
function M.begin_frame()
	_frame_start_time = love.timer.getTime()
	stats.panes_drawn            = 0
	stats.canvas_full_redraws    = 0
	stats.canvas_partial_redraws = 0
	stats.canvas_skipped         = 0
	stats.rows_redrawn           = 0
	stats.cells_visited          = 0
	stats.glyph_draws            = 0
	stats.bg_rect_draws          = 0
	stats.underline_draws        = 0
	stats.font_switches          = 0
	stats.set_color_calls        = 0
end

-- Call once at the end of each draw frame (after drawing everything).
function M.end_frame()
	stats.frame_time_ms = (love.timer.getTime() - _frame_start_time) * 1000
end

-- Returns the current stats table (read-only; reset each frame).
function M.get_stats()
	return stats
end

-- Enable or disable the on-screen debug overlay.
function M.set_debug_overlay(enabled)
	_debug_overlay_enabled = enabled
end

-- Draw a small overlay in the top-right corner showing per-frame stats.
-- Call after all panes and UI elements have been drawn.
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
	local s = stats
	local lines = {
		string.format("frame: %.2f ms", s.frame_time_ms),
		string.format("panes: %d  full:%d  part:%d  skip:%d",
			s.panes_drawn, s.canvas_full_redraws,
			s.canvas_partial_redraws, s.canvas_skipped),
		string.format("rows:%d  cells:%d  glyphs:%d",
			s.rows_redrawn, s.cells_visited, s.glyph_draws),
		string.format("bgr:%d  ul:%d  fsw:%d  clr:%d",
			s.bg_rect_draws, s.underline_draws,
			s.font_switches, s.set_color_calls),
	}
	local pad_x, pad_y = 6, 4
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

-- ── Cache management ──────────────────────────────────────────────────────────

-- Mark every cached pane canvas as needing a full redraw.
-- Call after font or config changes that affect rendering output.
function M.invalidate_all()
	for _, cached in pairs(pane_canvas_cache) do
		cached.dirty_all = true
	end
end

-- Return the cache record for this pane at the given canvas dimensions,
-- creating a new canvas (and marking dirty_all) if dimensions changed.
local function ensure_pane_canvas(pane, w, h)
	local cached = pane_canvas_cache[pane]
	if cached and cached.w == w and cached.h == h then
		return cached
	end
	local canvas = love.graphics.newCanvas(w, h)
	canvas:setFilter("linear", "linear")
	cached = { canvas = canvas, w = w, h = h, dirty_all = true }
	pane_canvas_cache[pane] = cached
	return cached
end

-- Composite the pane canvas onto the screen at the pane's logical position.
local function blit_canvas(cached, px, scale)
	love.graphics.setScissor(px.x, px.y, px.w, px.h)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.draw(cached.canvas, px.x, px.y, 0, 1 / scale, 1 / scale)
	love.graphics.setScissor()
end

local function pick_style_font(is_bold, is_italic, normal_font, bold_font, italic_font, bold_italic_font)
	if is_bold and is_italic then
		return bold_italic_font
	elseif is_bold then
		return bold_font
	elseif is_italic then
		return italic_font
	end
	return normal_font
end

-- ── Scratch FFI allocations (reused per frame) ───────────────────────────────
local _grapheme_len = ffi.new("uint32_t[1]")
local _grapheme_buf = ffi.new("uint32_t[16]")
local _style = ffi.new("GhosttyStyle")
local _fg_rgb = ffi.new("GhosttyColorRgb")
local _bg_rgb = ffi.new("GhosttyColorRgb")
local _u16 = ffi.new("uint16_t[1]")
local _u32 = ffi.new("uint32_t[1]")
local _bool = ffi.new("bool[1]")
local _bool_false = ffi.new("bool[1]", { false })
local _row_dirty_flag = ffi.new("bool[1]")

_style.size = ffi.sizeof("GhosttyStyle")

-- ── Color helper ──────────────────────────────────────────────────────────────
-- Extract default fg/bg colours from the render state colours struct,
-- falling back to config values when ghostty returns no colours.
local function get_pane_colors(rs)
	local colors_struct = gffi.rs_colors(rs)
	local fg_r, fg_g, fg_b, bg_r, bg_g, bg_b
	if colors_struct then
		fg_r = colors_struct.foreground.r / 255
		fg_g = colors_struct.foreground.g / 255
		fg_b = colors_struct.foreground.b / 255
		bg_r = colors_struct.background.r / 255
		bg_g = colors_struct.background.g / 255
		bg_b = colors_struct.background.b / 255
	else
		local c = cfg_colors or {}
		local fg = c.foreground or { 0.9, 0.9, 0.9 }
		local bg = c.background or { 0.0, 0.0, 0.0 }
		fg_r, fg_g, fg_b = fg[1], fg[2], fg[3]
		bg_r, bg_g, bg_b = bg[1], bg[2], bg[3]
	end
	return fg_r, fg_g, fg_b, bg_r, bg_g, bg_b, colors_struct
end

-- ── Draw rows to canvas ───────────────────────────────────────────────────────
-- Renders terminal cell content into the currently-bound canvas.
-- Call with the canvas already set and the graphics origin reset to (0,0).
--
--   pane          : the pane being rendered
--   dirty_only    : true → only redraw rows that carry the per-row DIRTY flag
--                   false → redraw all rows (used for full-invalidation frames)
--   ox, oy        : canvas draw origin (always 0,0 for our canvas-based path)
--   pw, ph        : canvas dimensions in pixels
--   scale         : font_supersample or 1
--   *_font        : resolved font objects for the four style variants
--   def_fg/bg_*   : default foreground / background colours (0-1 floats)
--
-- The function clears per-row dirty flags as it processes rows, then clears
-- the pane-level dirty flag when done.
local function draw_rows_to_canvas(
	pane, dirty_only, ox, oy, pw, ph, scale,
	normal_font, bold_font, italic_font, bold_italic_font,
	def_fg_r, def_fg_g, def_fg_b, def_bg_r, def_bg_g, def_bg_b
)
	local rs = pane.render_state
	local row_iter_box = pane.row_iter_box
	local cells_box = pane.row_cells_box
	if not rs then
		return
	end

	local cell_w = char_w * scale
	local cell_h = char_h * scale
	local baseline = baseline_offset * scale

	if not dirty_only then
		-- Full redraw: paint default background over entire canvas first.
		love.graphics.setColor(def_bg_r, def_bg_g, def_bg_b, 1)
		love.graphics.rectangle("fill", ox, oy, pw, ph)
		stats.set_color_calls = stats.set_color_calls + 1
		stats.bg_rect_draws   = stats.bg_rect_draws + 1
	end

	love.graphics.setFont(normal_font)

	if not gffi.rs_get_row_iterator(rs, row_iter_box) then
		return
	end

	local row_y = 0
	while lib.ghostty_render_state_row_iterator_next(row_iter_box[0]) do
		local py = oy + row_y * cell_h

		local should_draw = true
		if dirty_only then
			_row_dirty_flag[0] = false
			lib.ghostty_render_state_row_get(row_iter_box[0], gffi.ROW_DATA.DIRTY, _row_dirty_flag)
			should_draw = _row_dirty_flag[0]
		end

		if should_draw then
			if dirty_only then
				-- Partial redraw: clear just this row with default bg before
				-- redrawing, so that cells that disappeared don't leave ghosts.
				love.graphics.setColor(def_bg_r, def_bg_g, def_bg_b, 1)
				love.graphics.rectangle("fill", ox, py, pw, cell_h)
				stats.set_color_calls = stats.set_color_calls + 1
				stats.bg_rect_draws   = stats.bg_rect_draws + 1
			end

			stats.rows_redrawn = stats.rows_redrawn + 1

			if gffi.row_get_cells(row_iter_box[0], cells_box) then
				local col_x = 0
				while lib.ghostty_render_state_row_cells_next(cells_box[0]) do
					local cx = ox + col_x * cell_w
					stats.cells_visited = stats.cells_visited + 1

					_grapheme_len[0] = 0
					lib.ghostty_render_state_row_cells_get(
						cells_box[0], gffi.CELL_DATA.GRAPHEMES_LEN, _grapheme_len)
					local glen = tonumber(_grapheme_len[0])

					if glen == 0 then
						local res_bg = lib.ghostty_render_state_row_cells_get(
							cells_box[0], gffi.CELL_DATA.BG_COLOR, _bg_rgb)
						if res_bg == gffi.GHOSTTY_SUCCESS then
							love.graphics.setColor(
								_bg_rgb.r / 255, _bg_rgb.g / 255, _bg_rgb.b / 255, 1)
							love.graphics.rectangle("fill", cx, py, cell_w, cell_h)
							stats.set_color_calls = stats.set_color_calls + 1
							stats.bg_rect_draws   = stats.bg_rect_draws + 1
						end
					else
						local clen = math.min(glen, 16)
						lib.ghostty_render_state_row_cells_get(
							cells_box[0], gffi.CELL_DATA.GRAPHEMES_BUF, _grapheme_buf)
						local cps = {}
						for i = 0, clen - 1 do
							cps[i + 1] = tonumber(_grapheme_buf[i])
						end
						local text = codepoints_to_utf8(cps, clen)

						_style.size = ffi.sizeof("GhosttyStyle")
						lib.ghostty_render_state_row_cells_get(
							cells_box[0], gffi.CELL_DATA.STYLE, _style)
						local bold      = _style.bold
						local italic    = _style.italic
						local underline = _style.underline ~= 0
						local inverse   = _style.inverse

						local fg_r, fg_g, fg_b = def_fg_r, def_fg_g, def_fg_b
						local res_fg = lib.ghostty_render_state_row_cells_get(
							cells_box[0], gffi.CELL_DATA.FG_COLOR, _fg_rgb)
						if res_fg == gffi.GHOSTTY_SUCCESS then
							fg_r = _fg_rgb.r / 255
							fg_g = _fg_rgb.g / 255
							fg_b = _fg_rgb.b / 255
						end

						local bg_r, bg_g, bg_b = def_bg_r, def_bg_g, def_bg_b
						local has_bg = false
						local res_bg = lib.ghostty_render_state_row_cells_get(
							cells_box[0], gffi.CELL_DATA.BG_COLOR, _bg_rgb)
						if res_bg == gffi.GHOSTTY_SUCCESS then
							bg_r   = _bg_rgb.r / 255
							bg_g   = _bg_rgb.g / 255
							bg_b   = _bg_rgb.b / 255
							has_bg = true
						end

						if inverse then
							fg_r, fg_g, fg_b, bg_r, bg_g, bg_b =
								bg_r, bg_g, bg_b, fg_r, fg_g, fg_b
							has_bg = true
						end

						if has_bg then
							love.graphics.setColor(bg_r, bg_g, bg_b, 1)
							love.graphics.rectangle("fill", cx, py, cell_w, cell_h)
							stats.set_color_calls = stats.set_color_calls + 1
							stats.bg_rect_draws   = stats.bg_rect_draws + 1
						end

						if text then
							love.graphics.setColor(fg_r, fg_g, fg_b, 1)
							stats.set_color_calls = stats.set_color_calls + 1
							local draw_font = pick_style_font(
								bold, italic, normal_font, bold_font, italic_font, bold_italic_font)
							if draw_font ~= normal_font then
								love.graphics.setFont(draw_font)
								stats.font_switches = stats.font_switches + 1
							end
							love.graphics.print(text, cx, py + baseline)
							stats.glyph_draws = stats.glyph_draws + 1
							if draw_font ~= normal_font then
								love.graphics.setFont(normal_font)
								stats.font_switches = stats.font_switches + 1
							end
						end

						if underline then
							love.graphics.setColor(fg_r, fg_g, fg_b, 1)
							love.graphics.rectangle(
								"fill", cx, py + cell_h - math.max(1, scale),
								cell_w, math.max(1, scale))
							stats.set_color_calls = stats.set_color_calls + 1
							stats.underline_draws = stats.underline_draws + 1
						end
					end

					col_x = col_x + 1
				end
			end

			-- Clear the per-row dirty flag now that we have redrawn this row.
			lib.ghostty_render_state_row_set(row_iter_box[0], gffi.ROW_OPT.DIRTY, _bool_false)
		end
		-- (Non-dirty rows: iterator already positioned; no cell iteration needed.)

		row_y = row_y + 1
	end

	-- Clear the pane-level dirty flag so idle frames can skip redrawing.
	_u32[0] = gffi.RS_DIRTY.FALSE
	lib.ghostty_render_state_set(rs, gffi.RS_OPT.DIRTY, _u32)
end

-- ── Draw cursor overlay ───────────────────────────────────────────────────────
-- Draws the cursor rectangle directly onto the screen (not into the canvas)
-- so that cursor state changes (movement, blink) do not invalidate the
-- cached pane canvas.
local function draw_cursor_overlay(pane, is_focused, ox, oy, cell_w, cell_h,
	colors_struct, def_fg_r, def_fg_g, def_fg_b)
	if not is_focused then
		return
	end
	local rs = pane.render_state
	_bool[0] = false
	lib.ghostty_render_state_get(rs, gffi.RS_DATA.CURSOR_VISIBLE, _bool)
	local cursor_visible = _bool[0]
	_bool[0] = false
	lib.ghostty_render_state_get(rs, gffi.RS_DATA.CURSOR_VIEWPORT_HAS_VALUE, _bool)
	local cursor_in_vp = _bool[0]
	if cursor_visible and cursor_in_vp then
		_u16[0] = 0
		lib.ghostty_render_state_get(rs, gffi.RS_DATA.CURSOR_VIEWPORT_X, _u16)
		local cx_col = tonumber(_u16[0])
		_u16[0] = 0
		lib.ghostty_render_state_get(rs, gffi.RS_DATA.CURSOR_VIEWPORT_Y, _u16)
		local cx_row = tonumber(_u16[0])
		local cur_r, cur_g, cur_b
		if colors_struct and colors_struct.cursor_has_value then
			cur_r = colors_struct.cursor.r / 255
			cur_g = colors_struct.cursor.g / 255
			cur_b = colors_struct.cursor.b / 255
		else
			cur_r, cur_g, cur_b = def_fg_r, def_fg_g, def_fg_b
		end
		love.graphics.setColor(cur_r, cur_g, cur_b, 0.85)
		love.graphics.rectangle(
			"fill",
			ox + cx_col * cell_w,
			oy + cx_row * cell_h,
			cell_w, cell_h)
	end
end

-- ── Init ──────────────────────────────────────────────────────────────────────
function M.init(font_path, font_size)
	-- Use logical size only.  HiDPI rasterisation is handled by Love2D when
	-- t.window.highdpi = true is set in conf.lua.
	font_size = font_size or 14
	local font_hinting = Config.get("font_hinting") or "normal"
	font_supersample = math.max(1, math.floor(Config.get("font_supersample") or 1))

	local family = load_font_family(font_path, font_size, font_hinting)
	font_normal = family.normal
	font_bold = family.bold
	font_italic = family.italic
	font_bold_italic = family.bold_italic
	love.graphics.setFont(font_normal)

	font_normal_ss = nil
	font_bold_ss = nil
	font_italic_ss = nil
	font_bold_italic_ss = nil
	if font_supersample > 1 then
		local ss_family = load_font_family(font_path, font_size * font_supersample, font_hinting)
		font_normal_ss = ss_family.normal
		font_bold_ss = ss_family.bold
		font_italic_ss = ss_family.italic
		font_bold_italic_ss = ss_family.bold_italic
	end

	-- ── Cell metrics ──────────────────────────────────────────────────────────
	-- Use integer cell dimensions to avoid accumulated sub-pixel drift across
	-- columns / rows.
	char_w = math.floor(font_normal:getWidth("W") + 0.5)
	char_h = math.floor(font_normal:getHeight() + 0.5)

	-- Baseline offset: distance from cell top to where Love2D places the
	-- glyph origin.  Derived from the font's own ascent metric so we don't
	-- need a magic vertical_nudge constant.
	-- Love2D prints from the top of the cell by default (origin = top-left),
	-- so normally baseline_offset = 0 is correct.  If glyphs appear clipped
	-- at the top, increase this by 1–2 px.
	baseline_offset = 0

	-- Guard against degenerate metrics
	if char_w < 1 then
		char_w = 8
	end
	if char_h < 1 then
		char_h = 16
	end

	cfg_colors = Config.get("colors")

	-- Font or config changed: all cached pane canvases are now stale.
	M.invalidate_all()

	print(
		string.format(
			"[renderer] cell=%dx%d  dpi=%.2f  font_size=%d  hinting=%s  supersample=%dx  baseline_offset=%d",
			char_w,
			char_h,
			love.window.getDPIScale(),
			font_size,
			font_hinting,
			font_supersample,
			baseline_offset
		)
	)
end

function M.char_size()
	return char_w, char_h
end

-- Physical pixel size of one cell (informational — drawing uses logical coords)
function M.char_pixel_size()
	local scale = love.window.getDPIScale()
	return math.max(1, math.floor(char_w * scale + 0.5)), math.max(1, math.floor(char_h * scale + 0.5))
end

-- ── UTF-8 encoding (LuaJIT / Lua 5.1 has no utf8.char) ───────────────────────
local utf8_cache = {}
local function utf8_char(cp)
	if cp <= 0 then
		return nil
	end
	if utf8_cache[cp] then
		return utf8_cache[cp]
	end
	local s
	if cp < 0x80 then
		s = string.char(cp)
	elseif cp < 0x800 then
		s = string.char(bit.bor(0xC0, bit.rshift(cp, 6)), bit.bor(0x80, bit.band(cp, 0x3F)))
	elseif cp < 0x10000 then
		s = string.char(
			bit.bor(0xE0, bit.rshift(cp, 12)),
			bit.bor(0x80, bit.band(bit.rshift(cp, 6), 0x3F)),
			bit.bor(0x80, bit.band(cp, 0x3F))
		)
	elseif cp <= 0x10FFFF then
		s = string.char(
			bit.bor(0xF0, bit.rshift(cp, 18)),
			bit.bor(0x80, bit.band(bit.rshift(cp, 12), 0x3F)),
			bit.bor(0x80, bit.band(bit.rshift(cp, 6), 0x3F)),
			bit.bor(0x80, bit.band(cp, 0x3F))
		)
	else
		s = "?"
	end
	utf8_cache[cp] = s
	return s
end

function codepoints_to_utf8(cps, len)
	if len == 0 then
		return nil
	end
	local parts = {}
	for i = 1, len do
		local s = utf8_char(cps[i])
		if s then
			parts[#parts + 1] = s
		end
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts)
end

-- ── Draw one pane ─────────────────────────────────────────────────────────────
function M.draw_pane(pane, is_focused)
	local px = pane.px_rect
	if not pane.render_state or not px then
		return
	end

	stats.panes_drawn = stats.panes_drawn + 1

	local rs = pane.render_state

	-- Choose font family based on supersample setting.
	local use_ss = font_supersample > 1 and font_normal_ss ~= nil
	local scale = use_ss and font_supersample or 1
	local nf  = use_ss and font_normal_ss     or font_normal
	local bf  = use_ss and font_bold_ss       or font_bold
	local itf = use_ss and font_italic_ss     or font_italic
	local bif = use_ss and font_bold_italic_ss or font_bold_italic

	-- Canvas dimensions: supersample path uses a larger off-screen canvas.
	local cw = math.max(1, math.floor(px.w * scale + 0.5))
	local ch = math.max(1, math.floor(px.h * scale + 0.5))

	-- Get/create the persistent per-pane canvas (dirty_all = true on first use
	-- or whenever dimensions changed, e.g. after a resize).
	local cached = ensure_pane_canvas(pane, cw, ch)

	-- Check the pane-level dirty flag from the render state.
	_u32[0] = 0
	lib.ghostty_render_state_get(rs, gffi.RS_DATA.DIRTY, _u32)
	local rs_dirty = _u32[0] ~= 0

	-- Resolve default colours (needed for both canvas drawing and cursor).
	local def_fg_r, def_fg_g, def_fg_b, def_bg_r, def_bg_g, def_bg_b, colors_struct =
		get_pane_colors(rs)

	if not rs_dirty and not cached.dirty_all then
		-- ── Idle frame ────────────────────────────────────────────────────────
		-- Nothing changed in the terminal: blit the cached canvas and draw
		-- the cursor overlay without iterating any rows.
		stats.canvas_skipped = stats.canvas_skipped + 1
		blit_canvas(cached, px, scale)
		-- Cursor overlay uses logical (screen-space) cell dimensions.
		draw_cursor_overlay(pane, is_focused,
			px.x, px.y, char_w, char_h, colors_struct, def_fg_r, def_fg_g, def_fg_b)
		love.graphics.setColor(1, 1, 1, 1)
		return
	end

	-- ── Canvas update ─────────────────────────────────────────────────────────
	local prev_canvas = love.graphics.getCanvas()
	love.graphics.push("all")
	love.graphics.setCanvas(cached.canvas)
	love.graphics.origin()

	local dirty_only = not cached.dirty_all
	if cached.dirty_all then
		-- Full invalidation: draw_rows_to_canvas will paint the default bg over
		-- the entire canvas, so no explicit canvas clear is needed.
		stats.canvas_full_redraws = stats.canvas_full_redraws + 1
	else
		stats.canvas_partial_redraws = stats.canvas_partial_redraws + 1
	end

	draw_rows_to_canvas(
		pane, dirty_only, 0, 0, cw, ch, scale,
		nf, bf, itf, bif,
		def_fg_r, def_fg_g, def_fg_b, def_bg_r, def_bg_g, def_bg_b)

	cached.dirty_all = false

	love.graphics.setCanvas(prev_canvas)
	love.graphics.pop()

	-- ── Composite + cursor ────────────────────────────────────────────────────
	blit_canvas(cached, px, scale)
	-- Cursor overlay uses logical (screen-space) cell dimensions, not canvas-
	-- space ones, because it is drawn directly onto the screen after blitting.
	draw_cursor_overlay(pane, is_focused,
		px.x, px.y, char_w, char_h, colors_struct, def_fg_r, def_fg_g, def_fg_b)
	love.graphics.setColor(1, 1, 1, 1)
end

-- ── Draw split dividers ───────────────────────────────────────────────────────
function M.draw_splits(root)
	if not root or root.kind == "leaf" then
		return
	end
	local c = cfg_colors or {}
	local sl = c.split_line or { 0.3, 0.3, 0.3, 1 }
	love.graphics.setColor(sl[1], sl[2], sl[3], sl[4] or 1)
	local function walk(node)
		if node.kind ~= "split" then
			return
		end
		local ra, rb = node:rects()
		if node.dir == "h" then
			love.graphics.rectangle("fill", ra.x + ra.w, node.rect.y, 1, node.rect.h)
		else
			love.graphics.rectangle("fill", node.rect.x, ra.y + ra.h, node.rect.w, 1)
		end
		walk(node.child_a)
		walk(node.child_b)
	end
	walk(root)
	love.graphics.setColor(1, 1, 1, 1)
end

return M
