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
-- Dirty-row pane caching:
--   Each pane has a persistent canvas.  Frames where the render state is
--   not dirty skip all row iteration and just blit the cached canvas.
--   When the render state is dirty the renderer iterates rows and redraws
--   only the rows that carry the per-row DIRTY flag, preserving unchanged
--   rows in the canvas.  A full invalidation (resize, font change, initial
--   render) forces a clear + full redraw.
--
-- Companion modules:
--   src/renderer/font.lua  — font loading and family utilities
--   src/renderer/stats.lua — per-frame stats counters and debug overlay
local ffi    = require("ffi")
local bit    = require("bit")
local gffi   = require("src.core.ghostty_ffi")
local Config = require("src.core.config")
local Font   = require("src.renderer.font")
local Stats  = require("src.renderer.stats")
local lib    = gffi.lib
local M      = {}

-- Alias the live stats table so the draw path can increment counters with no
-- function-call overhead:  stats.glyph_draws = stats.glyph_draws + 1
local stats = Stats.stats
local stats_flags = Stats.flags

-- ── Stats / debug overlay API (delegated to stats.lua) ────────────────────────
-- Callers (app.lua, api/init.lua) continue to use Renderer.begin_frame() etc.
M.begin_frame        = Stats.begin_frame
M.end_frame          = Stats.end_frame
M.get_stats          = Stats.get_stats
M.set_debug_overlay  = Stats.set_debug_overlay
M.draw_debug_overlay = Stats.draw_debug_overlay
M.toggle_debug_overlay = Stats.toggle_debug_overlay
M.get_debug_overlay = Stats.get_debug_overlay

-- ── Renderer state ────────────────────────────────────────────────────────────
local font_normal         = nil
local font_bold           = nil
local font_italic         = nil
local font_bold_italic    = nil
local font_normal_ss      = nil
local font_bold_ss        = nil
local font_italic_ss      = nil
local font_bold_italic_ss = nil
local char_w          = 8
local char_h          = 16
local baseline_offset = 0   -- pixels from cell top to font baseline
local cfg_colors      = nil
local font_supersample = 1
-- pane_canvas_cache[pane] = { canvas, w, h, dirty_all }
local pane_canvas_cache = setmetatable({}, { __mode = "k" })
local codepoints_to_utf8
local byte_to_float = {}

for i = 0, 255 do
	byte_to_float[i] = i / 255
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

local function stat_inc(key)
	if stats_flags.counters_enabled then
		stats[key] = stats[key] + 1
	end
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
		fg_r = byte_to_float[colors_struct.foreground.r]
		fg_g = byte_to_float[colors_struct.foreground.g]
		fg_b = byte_to_float[colors_struct.foreground.b]
		bg_r = byte_to_float[colors_struct.background.r]
		bg_g = byte_to_float[colors_struct.background.g]
		bg_b = byte_to_float[colors_struct.background.b]
	else
		local c = cfg_colors or {}
		local fg = c.foreground or { 0.9, 0.9, 0.9 }
		local bg = c.background or { 0.0, 0.0, 0.0 }
		fg_r, fg_g, fg_b = fg[1], fg[2], fg[3]
		bg_r, bg_g, bg_b = bg[1], bg[2], bg[3]
	end
	return fg_r, fg_g, fg_b, bg_r, bg_g, bg_b, colors_struct
end

local function resolve_style_color(style_color, colors_struct, def_r, def_g, def_b)
	local tag = style_color.tag
	if tag == 2 then
		local rgb = style_color.value.rgb
		return byte_to_float[rgb.r], byte_to_float[rgb.g], byte_to_float[rgb.b], true
	elseif tag == 1 and colors_struct then
		local rgb = colors_struct.palette[style_color.value.palette]
		return byte_to_float[rgb.r], byte_to_float[rgb.g], byte_to_float[rgb.b], true
	end
	return def_r, def_g, def_b, false
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
	def_fg_r, def_fg_g, def_fg_b, def_bg_r, def_bg_g, def_bg_b, colors_struct
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
	local counters_enabled = stats_flags.counters_enabled
	local current_font = normal_font
	local current_r, current_g, current_b = -1, -1, -1

	local run_parts = {}
	local run_len = 0
	local run_x = 0
	local run_font = nil
	local run_fg_r, run_fg_g, run_fg_b = 0, 0, 0

	local function set_color_if_needed(r, g, b, a)
		if current_r ~= r or current_g ~= g or current_b ~= b then
			love.graphics.setColor(r, g, b, a or 1)
			current_r, current_g, current_b = r, g, b
			if counters_enabled then
				stats.set_color_calls = stats.set_color_calls + 1
			end
		end
	end

	local function set_font_if_needed(font)
		if current_font ~= font then
			love.graphics.setFont(font)
			current_font = font
			if counters_enabled then
				stats.font_switches = stats.font_switches + 1
			end
		end
	end

	local function flush_text_run(py)
		if run_len == 0 then
			return
		end
		set_font_if_needed(run_font)
		set_color_if_needed(run_fg_r, run_fg_g, run_fg_b, 1)
		love.graphics.print(table.concat(run_parts, "", 1, run_len), run_x, py + baseline)
		if counters_enabled then
			stats.glyph_draws = stats.glyph_draws + 1
		end
		for i = 1, run_len do
			run_parts[i] = nil
		end
		run_len = 0
	end

	if not dirty_only then
		-- Full redraw: paint default background over entire canvas first.
		set_color_if_needed(def_bg_r, def_bg_g, def_bg_b, 1)
		love.graphics.rectangle("fill", ox, oy, pw, ph)
		if counters_enabled then
			stats.bg_rect_draws = stats.bg_rect_draws + 1
		end
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
			run_len = 0
			if dirty_only then
				-- Partial redraw: clear just this row with default bg before
				-- redrawing, so that cells that disappeared don't leave ghosts.
				set_color_if_needed(def_bg_r, def_bg_g, def_bg_b, 1)
				love.graphics.rectangle("fill", ox, py, pw, cell_h)
				if counters_enabled then
					stats.bg_rect_draws = stats.bg_rect_draws + 1
				end
			end

			if counters_enabled then
				stats.rows_redrawn = stats.rows_redrawn + 1
			end

			if gffi.row_get_cells(row_iter_box[0], cells_box) then
				local col_x = 0
				while lib.ghostty_render_state_row_cells_next(cells_box[0]) do
					local cx = ox + col_x * cell_w
					if counters_enabled then
						stats.cells_visited = stats.cells_visited + 1
					end

					_grapheme_len[0] = 0
					lib.ghostty_render_state_row_cells_get(
						cells_box[0], gffi.CELL_DATA.GRAPHEMES_LEN, _grapheme_len)
					local glen = _grapheme_len[0]

					if glen == 0 then
						local res_bg = lib.ghostty_render_state_row_cells_get(
							cells_box[0], gffi.CELL_DATA.BG_COLOR, _bg_rgb)
						if res_bg == gffi.GHOSTTY_SUCCESS then
							flush_text_run(py)
							set_color_if_needed(
								byte_to_float[_bg_rgb.r], byte_to_float[_bg_rgb.g], byte_to_float[_bg_rgb.b], 1)
							love.graphics.rectangle("fill", cx, py, cell_w, cell_h)
							if counters_enabled then
								stats.bg_rect_draws = stats.bg_rect_draws + 1
							end
						else
							if run_len == 0 then
								run_x = cx
								run_font = normal_font
								run_fg_r, run_fg_g, run_fg_b = def_fg_r, def_fg_g, def_fg_b
							elseif run_font ~= normal_font or run_fg_r ~= def_fg_r or run_fg_g ~= def_fg_g or run_fg_b ~= def_fg_b then
								flush_text_run(py)
								run_x = cx
								run_font = normal_font
								run_fg_r, run_fg_g, run_fg_b = def_fg_r, def_fg_g, def_fg_b
							end
							run_len = run_len + 1
							run_parts[run_len] = " "
						end
					else
						local clen = math.min(glen, 16)
						lib.ghostty_render_state_row_cells_get(
							cells_box[0], gffi.CELL_DATA.GRAPHEMES_BUF, _grapheme_buf)

						_style.size = ffi.sizeof("GhosttyStyle")
						lib.ghostty_render_state_row_cells_get(
							cells_box[0], gffi.CELL_DATA.STYLE, _style)
						local bold      = _style.bold
						local italic    = _style.italic
						local underline = _style.underline ~= 0
						local inverse   = _style.inverse

						local handled_plain_ascii = false
						if not bold and not italic and not underline and not inverse
							and _style.fg_color.tag == 0 and _style.bg_color.tag == 0 and clen == 1 then
							local cp = tonumber(_grapheme_buf[0])
							if cp >= 32 and cp < 127 then
								if run_len == 0 then
									run_x = cx
									run_font = normal_font
									run_fg_r, run_fg_g, run_fg_b = def_fg_r, def_fg_g, def_fg_b
								elseif run_font ~= normal_font or run_fg_r ~= def_fg_r or run_fg_g ~= def_fg_g or run_fg_b ~= def_fg_b then
									flush_text_run(py)
									run_x = cx
									run_font = normal_font
									run_fg_r, run_fg_g, run_fg_b = def_fg_r, def_fg_g, def_fg_b
								end
								run_len = run_len + 1
								run_parts[run_len] = string.char(cp)
								handled_plain_ascii = true
							end
						end

						if not handled_plain_ascii then
							local text = codepoints_to_utf8(_grapheme_buf, clen)
							local fg_r, fg_g, fg_b = resolve_style_color(
								_style.fg_color, colors_struct, def_fg_r, def_fg_g, def_fg_b)

							local bg_r, bg_g, bg_b, has_bg = resolve_style_color(
								_style.bg_color, colors_struct, def_bg_r, def_bg_g, def_bg_b)

							if inverse then
								fg_r, fg_g, fg_b, bg_r, bg_g, bg_b =
									bg_r, bg_g, bg_b, fg_r, fg_g, fg_b
								has_bg = true
							end

							local draw_font = pick_style_font(
								bold, italic, normal_font, bold_font, italic_font, bold_italic_font)

							if has_bg then
								flush_text_run(py)
								set_color_if_needed(bg_r, bg_g, bg_b, 1)
								love.graphics.rectangle("fill", cx, py, cell_w, cell_h)
								if counters_enabled then
									stats.bg_rect_draws = stats.bg_rect_draws + 1
								end
							end

							if text then
								if not has_bg and not underline then
									if run_len == 0 then
										run_x = cx
										run_font = draw_font
										run_fg_r, run_fg_g, run_fg_b = fg_r, fg_g, fg_b
									elseif run_font ~= draw_font or run_fg_r ~= fg_r or run_fg_g ~= fg_g or run_fg_b ~= fg_b then
										flush_text_run(py)
										run_x = cx
										run_font = draw_font
										run_fg_r, run_fg_g, run_fg_b = fg_r, fg_g, fg_b
									end
									run_len = run_len + 1
									run_parts[run_len] = text
								else
									flush_text_run(py)
									set_font_if_needed(draw_font)
									set_color_if_needed(fg_r, fg_g, fg_b, 1)
									love.graphics.print(text, cx, py + baseline)
									if counters_enabled then
										stats.glyph_draws = stats.glyph_draws + 1
									end
								end
							end

							if underline then
								flush_text_run(py)
								set_color_if_needed(fg_r, fg_g, fg_b, 1)
								love.graphics.rectangle(
									"fill", cx, py + cell_h - math.max(1, scale),
									cell_w, math.max(1, scale))
								if counters_enabled then
									stats.underline_draws = stats.underline_draws + 1
								end
							end
						end
					end

					col_x = col_x + 1
				end
				flush_text_run(py)
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

	local family = Font.load_family(font_path, font_size, font_hinting)
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
		local ss_family = Font.load_family(font_path, font_size * font_supersample, font_hinting)
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
	if len == 1 then
		return utf8_char(tonumber(cps[0] or cps[1]))
	end
	local parts = {}
	local base = cps[0] ~= nil and 0 or 1
	for i = 0, len - 1 do
		local s = utf8_char(tonumber(cps[base + i]))
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

	stat_inc("panes_drawn")

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
		stat_inc("canvas_skipped")
		blit_canvas(cached, px, scale)
		-- Cursor overlay uses logical (screen-space) cell dimensions.
		draw_cursor_overlay(pane, is_focused,
			px.x, px.y, char_w, char_h, colors_struct, def_fg_r, def_fg_g, def_fg_b)
		love.graphics.setColor(1, 1, 1, 1)
		return
	end

	-- ── Canvas update ─────────────────────────────────────────────────────────
	local prev_canvas = love.graphics.getCanvas()
	love.graphics.setCanvas(cached.canvas)
	love.graphics.origin()

	local dirty_only = not cached.dirty_all and _u32[0] == gffi.RS_DIRTY.TRUE
	if cached.dirty_all or _u32[0] == gffi.RS_DIRTY.FULL then
		-- Full invalidation: draw_rows_to_canvas will paint the default bg over
		-- the entire canvas, so no explicit canvas clear is needed.
		stat_inc("canvas_full_redraws")
	else
		stat_inc("canvas_partial_redraws")
	end

	draw_rows_to_canvas(
		pane, dirty_only, 0, 0, cw, ch, scale,
		nf, bf, itf, bif,
		def_fg_r, def_fg_g, def_fg_b, def_bg_r, def_bg_g, def_bg_b, colors_struct)

	cached.dirty_all = false

	love.graphics.setCanvas(prev_canvas)

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
