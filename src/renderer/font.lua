-- src/renderer/font.lua
-- Font loading utilities for the terminal renderer.
--
-- Handles:
--   • Loading font files at LOGICAL size (never multiply by DPIScale here —
--     Love2D handles physical rasterisation automatically with highdpi=true).
--   • Applying "linear" filter settings for HiDPI / fractional-DPI displays.
--   • Deriving bold/italic/bold_italic variant paths from a regular font path.
--   • Loading all four style variants as a family table.

local Config = require("src.core.config")
local M = {}

local function resolved_font_filter()
	local filter = Config.get("font_filter") or "linear"
	if filter ~= "nearest" and filter ~= "linear" then
		filter = "linear"
	end
	return filter
end

-- ── Internal helpers ──────────────────────────────────────────────────────────

-- Load a single font file at the given logical size.
-- Tries Love2D virtual FS first, then falls back to native IO for absolute
-- paths that live outside the project directory.
local function load_font(path, size, hinting)
	if love.filesystem.getInfo(path) then
		print("[renderer] Loading font from virtual FS: " .. path)
		return love.graphics.newFont(path, size, hinting)
	end
	local f, err = io.open(path, "rb")
	if not f then
		error("Could not open file " .. path .. ": " .. tostring(err))
	end
	local data = f:read("*a")
	f:close()
	local filedata = love.filesystem.newFileData(data, path)
	return love.graphics.newFont(filedata, size, hinting)
end

local function configure_font(font)
	local filter = resolved_font_filter()
	font:setFilter(filter, filter)
	font:setLineHeight(1.0) -- control row height through char_h directly
	return font
end

function M.get_filter()
	return resolved_font_filter()
end

-- Produce candidate paths by applying a single substitution to path.
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

-- Derive the file path for a style variant (bold/italic/bold_italic) of
-- base_path by trying common naming conventions.  Returns the first path
-- that exists on disk, or nil if none is found.
local function derive_variant(base_path, kind)
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

-- ── Public API ────────────────────────────────────────────────────────────────

-- Load the four-variant font family { normal, bold, italic, bold_italic }.
-- Style variants fall back to normal when no separate file is found.
-- Explicit override paths can be set via config keys font_bold_path,
-- font_italic_path, and font_bold_italic_path.
function M.load_family(font_path, font_size, font_hinting)
	local family       = {}
	local bold_path        = Config.get("font_bold_path")
	local italic_path      = Config.get("font_italic_path")
	local bold_italic_path = Config.get("font_bold_italic_path")

	if font_path then
		family.normal = configure_font(load_font(font_path, font_size, font_hinting))
	else
		family.normal = configure_font(love.graphics.newFont(font_size, font_hinting))
	end

	family.bold       = family.normal
	family.italic     = family.normal
	family.bold_italic = family.normal

	if font_path then
		bold_path        = bold_path        or derive_variant(font_path, "bold")
		italic_path      = italic_path      or derive_variant(font_path, "italic")
		bold_italic_path = bold_italic_path or derive_variant(font_path, "bold_italic")

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

return M
