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
--   4. draw cursor
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
local pane_canvas_cache = setmetatable({}, { __mode = "k" })
local codepoints_to_utf8

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

local function ensure_pane_canvas(pane, w, h)
	local cached = pane_canvas_cache[pane]
	if cached and cached.w == w and cached.h == h then
		return cached.canvas
	end
	local canvas = love.graphics.newCanvas(w, h)
	canvas:setFilter("linear", "linear")
	pane_canvas_cache[pane] = { canvas = canvas, w = w, h = h }
	return canvas
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

_style.size = ffi.sizeof("GhosttyStyle")

local function draw_pane_contents(pane, is_focused, ox, oy, pw, ph, scale, normal_font, bold_font, italic_font, bold_italic_font)
	local rs = pane.render_state
	local row_iter_box = pane.row_iter_box
	local cells_box = pane.row_cells_box
	if not rs then
		return
	end

	local cell_w = char_w * scale
	local cell_h = char_h * scale
	local baseline = baseline_offset * scale

	local colors_struct = gffi.rs_colors(rs)
	local def_fg_r, def_fg_g, def_fg_b
	local def_bg_r, def_bg_g, def_bg_b

	if colors_struct then
		def_fg_r = colors_struct.foreground.r / 255
		def_fg_g = colors_struct.foreground.g / 255
		def_fg_b = colors_struct.foreground.b / 255
		def_bg_r = colors_struct.background.r / 255
		def_bg_g = colors_struct.background.g / 255
		def_bg_b = colors_struct.background.b / 255
	else
		local c = cfg_colors or {}
		local fg = c.foreground or { 0.9, 0.9, 0.9 }
		local bg = c.background or { 0.0, 0.0, 0.0 }
		def_fg_r, def_fg_g, def_fg_b = fg[1], fg[2], fg[3]
		def_bg_r, def_bg_g, def_bg_b = bg[1], bg[2], bg[3]
	end

	love.graphics.setColor(def_bg_r, def_bg_g, def_bg_b, 1)
	love.graphics.rectangle("fill", ox, oy, pw, ph)
	love.graphics.setFont(normal_font)

	if not gffi.rs_get_row_iterator(rs, row_iter_box) then
		return
	end

	local row_y = 0
	while lib.ghostty_render_state_row_iterator_next(row_iter_box[0]) do
		local py = oy + row_y * cell_h
		if gffi.row_get_cells(row_iter_box[0], cells_box) then
			local col_x = 0
			while lib.ghostty_render_state_row_cells_next(cells_box[0]) do
				local cx = ox + col_x * cell_w
				_grapheme_len[0] = 0
				lib.ghostty_render_state_row_cells_get(cells_box[0], gffi.CELL_DATA.GRAPHEMES_LEN, _grapheme_len)
				local glen = tonumber(_grapheme_len[0])

				if glen == 0 then
					local res_bg = lib.ghostty_render_state_row_cells_get(cells_box[0], gffi.CELL_DATA.BG_COLOR, _bg_rgb)
					if res_bg == gffi.GHOSTTY_SUCCESS then
						love.graphics.setColor(_bg_rgb.r / 255, _bg_rgb.g / 255, _bg_rgb.b / 255, 1)
						love.graphics.rectangle("fill", cx, py, cell_w, cell_h)
					end
				else
					local clen = math.min(glen, 16)
					lib.ghostty_render_state_row_cells_get(cells_box[0], gffi.CELL_DATA.GRAPHEMES_BUF, _grapheme_buf)
					local cps = {}
					for i = 0, clen - 1 do
						cps[i + 1] = tonumber(_grapheme_buf[i])
					end
					local text = codepoints_to_utf8(cps, clen)

					_style.size = ffi.sizeof("GhosttyStyle")
					lib.ghostty_render_state_row_cells_get(cells_box[0], gffi.CELL_DATA.STYLE, _style)
					local bold = _style.bold
					local italic = _style.italic
					local underline = _style.underline ~= 0
					local inverse = _style.inverse

					local fg_r, fg_g, fg_b = def_fg_r, def_fg_g, def_fg_b
					local res_fg = lib.ghostty_render_state_row_cells_get(cells_box[0], gffi.CELL_DATA.FG_COLOR, _fg_rgb)
					if res_fg == gffi.GHOSTTY_SUCCESS then
						fg_r = _fg_rgb.r / 255
						fg_g = _fg_rgb.g / 255
						fg_b = _fg_rgb.b / 255
					end

					local bg_r, bg_g, bg_b = def_bg_r, def_bg_g, def_bg_b
					local has_bg = false
					local res_bg = lib.ghostty_render_state_row_cells_get(cells_box[0], gffi.CELL_DATA.BG_COLOR, _bg_rgb)
					if res_bg == gffi.GHOSTTY_SUCCESS then
						bg_r = _bg_rgb.r / 255
						bg_g = _bg_rgb.g / 255
						bg_b = _bg_rgb.b / 255
						has_bg = true
					end

					if inverse then
						fg_r, fg_g, fg_b, bg_r, bg_g, bg_b = bg_r, bg_g, bg_b, fg_r, fg_g, fg_b
						has_bg = true
					end

					if has_bg then
						love.graphics.setColor(bg_r, bg_g, bg_b, 1)
						love.graphics.rectangle("fill", cx, py, cell_w, cell_h)
					end

					if text then
						love.graphics.setColor(fg_r, fg_g, fg_b, 1)
						local draw_font = pick_style_font(bold, italic, normal_font, bold_font, italic_font, bold_italic_font)
						if draw_font ~= normal_font then
							love.graphics.setFont(draw_font)
						end
						love.graphics.print(text, cx, py + baseline)
						if draw_font ~= normal_font then
							love.graphics.setFont(normal_font)
						end
					end

					if underline then
						love.graphics.setColor(fg_r, fg_g, fg_b, 1)
						love.graphics.rectangle("fill", cx, py + cell_h - math.max(1, scale), cell_w, math.max(1, scale))
					end
				end

				col_x = col_x + 1
			end
		end
		lib.ghostty_render_state_row_set(row_iter_box[0], gffi.ROW_OPT.DIRTY, _bool_false)
		row_y = row_y + 1
	end

	_u32[0] = gffi.RS_DIRTY.FALSE
	lib.ghostty_render_state_set(rs, gffi.RS_OPT.DIRTY, _u32)

	if is_focused then
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
			love.graphics.rectangle("fill", ox + cx_col * cell_w, oy + cx_row * cell_h, cell_w, cell_h)
		end
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

-- ── Scratch FFI allocations (reused per frame) ───────────────────────────────
-- ── Draw one pane ─────────────────────────────────────────────────────────────
function M.draw_pane(pane, is_focused)
	local px = pane.px_rect
	if not pane.render_state or not px then
		return
	end
	if font_supersample > 1 and font_normal_ss then
		local cw = math.max(1, math.floor(px.w * font_supersample + 0.5))
		local ch = math.max(1, math.floor(px.h * font_supersample + 0.5))
		local canvas = ensure_pane_canvas(pane, cw, ch)
		local prev_canvas = love.graphics.getCanvas()
		love.graphics.push("all")
		love.graphics.setCanvas(canvas)
		love.graphics.clear(0, 0, 0, 0)
		love.graphics.origin()
		draw_pane_contents(
			pane,
			is_focused,
			0,
			0,
			cw,
			ch,
			font_supersample,
			font_normal_ss,
			font_bold_ss,
			font_italic_ss,
			font_bold_italic_ss
		)
		love.graphics.setCanvas(prev_canvas)
		love.graphics.pop()
		love.graphics.setScissor(px.x, px.y, px.w, px.h)
		love.graphics.setColor(1, 1, 1, 1)
		love.graphics.draw(canvas, px.x, px.y, 0, 1 / font_supersample, 1 / font_supersample)
		love.graphics.setScissor()
		love.graphics.setColor(1, 1, 1, 1)
		return
	end

	love.graphics.setScissor(px.x, px.y, px.w, px.h)
	draw_pane_contents(pane, is_focused, px.x, px.y, px.w, px.h, 1, font_normal, font_bold, font_italic, font_bold_italic)
	love.graphics.setScissor()
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
