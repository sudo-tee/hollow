hollow.keymap = {}
local bindings = {}

local MODS_SHIFT = 0x01
local MODS_CTRL  = 0x02
local MODS_ALT   = 0x04
local MODS_SUPER = 0x08

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

function hollow.keymap.set(chord, action)
	local key, mods = parse_chord(chord)
	bindings[key] = bindings[key] or {}
	bindings[key][mods] = action
end

hollow.action = {
    split_vertical = function() hollow.split_pane("vertical") end,
    split_horizontal = function() hollow.split_pane("horizontal") end,
    new_tab = function() hollow.new_tab() end,
    close_tab = function() hollow.close_tab() end,
    next_tab = function() hollow.next_tab() end,
    prev_tab = function() hollow.prev_tab() end,
}

hollow.on_key(function(key, mods)
	if bindings[key] and bindings[key][mods] then
		local action = bindings[key][mods]
		if type(action) == "function" then
			action()
		elseif type(action) == "string" and hollow.action[action] then
			hollow.action[action]()
		end
		return true
	end
	return false
end)

-- Default bindings
hollow.keymap.set("ctrl+backslash", "split_vertical")
hollow.keymap.set("ctrl+shift+backslash", "split_horizontal")
hollow.keymap.set("ctrl+t", "new_tab")
hollow.keymap.set("ctrl+w", "close_tab")
hollow.keymap.set("ctrl+tab", "next_tab")
hollow.keymap.set("ctrl+shift+tab", "prev_tab")
