local g = hollow

g.log("loading native rewrite config")

g.set_config({
	backend = "sokol",
	font_size = 14.5,
	font_padding_x = 0,
	font_padding_y = 0,
	font_coverage_boost = 1.0,
	font_coverage_add = 0,
	font_lcd = false,
	font_embolden = 0.3,
	cols = 120,
	rows = 34,
	scrollback = 20000,
	window_title = "hollow",
	window_width = 1440,
	window_height = 900,
})

if g.platform.is_windows then
	g.set_config({
		shell = "wsl.exe",
		ghostty_library = "ghostty-vt.dll",
		luajit_library = "luajit-5.1.dll",
	})
else
	g.set_config({
		shell = g.platform.default_shell,
		ghostty_library = "ghostty-vt.so",
	})
end

-- Declarative Keymap System
local MODS_SHIFT = 0x01
local MODS_CTRL  = 0x02
local MODS_ALT   = 0x04
local MODS_SUPER = 0x08

local bindings = {}

local function parse_chord(chord)
	local mods = 0
	local parts = {}
	for part in chord:gmatch("[^+]+") do
		table.insert(parts, part:lower())
	end
	
	local key = table.remove(parts)
	for _, mod in ipairs(parts) do
		if mod == "ctrl" or mod == "c" then mods = bit.bor(mods, MODS_CTRL)
		elseif mod == "shift" or mod == "s" then mods = bit.bor(mods, MODS_SHIFT)
		elseif mod == "alt" or mod == "m" then mods = bit.bor(mods, MODS_ALT)
		elseif mod == "super" or mod == "cmd" or mod == "w" then mods = bit.bor(mods, MODS_SUPER)
		end
	end
	return key, mods
end

local function map(chord, action)
	local key, mods = parse_chord(chord)
	bindings[key] = bindings[key] or {}
	bindings[key][mods] = action
end

-- Key handler: called before the terminal sees each key.
g.on_key(function(key, mods)
	if bindings[key] and bindings[key][mods] then
		local action = bindings[key][mods]
		if type(action) == "function" then
			action()
		elseif type(action) == "string" then
			-- Built-in string actions
			if action == "split_vertical" then
				g.split_pane("vertical")
			elseif action == "split_horizontal" then
				g.split_pane("horizontal")
			end
			-- We will add more built-in string actions like new_tab, close_tab here
		end
		return true
	end
	return false
end)

-- Default Keybindings
map("ctrl+backslash", "split_vertical")
map("ctrl+shift+backslash", "split_horizontal")
-- map("ctrl+t", "new_tab")
-- map("ctrl+w", "close_tab")
-- map("ctrl+tab", "next_tab")
-- map("ctrl+shift+tab", "prev_tab")

