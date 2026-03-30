hollow.keymap = {}
hollow.top_bar = {}
hollow.status = {}
local bindings = {}

local MODS_SHIFT = 0x01
local MODS_CTRL = 0x02
local MODS_ALT = 0x04
local MODS_SUPER = 0x08

local function parse_chord(chord)
	local mods = 0
	local parts = {}
	for part in chord:gmatch("[^+]+") do
		table.insert(parts, part:lower())
	end

	local key = table.remove(parts)
	for _, mod in ipairs(parts) do
		if mod == "ctrl" or mod == "c" then
			mods = bit.bor(mods, MODS_CTRL)
		elseif mod == "shift" or mod == "s" then
			mods = bit.bor(mods, MODS_SHIFT)
		elseif mod == "alt" or mod == "m" then
			mods = bit.bor(mods, MODS_ALT)
		elseif mod == "super" or mod == "cmd" or mod == "w" then
			mods = bit.bor(mods, MODS_SUPER)
		end
	end
	return key, mods
end

function hollow.keymap.set(chord, action)
	local key, mods = parse_chord(chord)
	bindings[key] = bindings[key] or {}
	bindings[key][mods] = action
end

function hollow.keymap.del(chord)
	local key, mods = parse_chord(chord)

	local key_bindings = bindings[key]
	if not key_bindings then
		return false
	end

	if key_bindings[mods] == nil then
		return false
	end

	key_bindings[mods] = nil

	-- Clean up empty key tables
	if next(key_bindings) == nil then
		bindings[key] = nil
	end

	return true
end

function hollow.top_bar.set(renderer)
	hollow.on_top_bar(renderer)
end

function hollow.top_bar.format_tab_title(renderer)
	hollow.on_top_bar(renderer)
end

function hollow.top_bar.format_workspace_title(renderer)
	hollow.on_workspace_title(renderer)
end

hollow.workspace = hollow.workspace or {}

function hollow.workspace.set_name(name)
	hollow.set_workspace_name(name)
end

function hollow.workspace.get_name(index)
	return hollow.get_workspace_name(index)
end

function hollow.status.set(renderer)
	hollow.on_status(renderer)
end

hollow.gui = hollow.gui or {}

function hollow.gui.on_ready(fn)
	hollow.on_gui_ready(fn)
end

hollow.action = {
	split_vertical = function()
		hollow.split_pane("vertical")
	end,
	split_horizontal = function()
		hollow.split_pane("horizontal")
	end,
	new_tab = function()
		hollow.new_tab()
	end,
	close_tab = function()
		hollow.close_tab()
	end,
	close_pane = function()
		hollow.close_pane()
	end,
	next_tab = function()
		hollow.next_tab()
	end,
	prev_tab = function()
		hollow.prev_tab()
	end,
	new_workspace = function()
		hollow.new_workspace()
	end,
	next_workspace = function()
		hollow.next_workspace()
	end,
	prev_workspace = function()
		hollow.prev_workspace()
	end,
	focus_pane_left = function()
		hollow.focus_pane("left")
	end,
	focus_pane_right = function()
		hollow.focus_pane("right")
	end,
	focus_pane_up = function()
		hollow.focus_pane("up")
	end,
	focus_pane_down = function()
		hollow.focus_pane("down")
	end,
	-- Resize: move the divider of the enclosing vertical split
	resize_pane_left = function()
		hollow.resize_pane("vertical", -0.05)
	end,
	resize_pane_right = function()
		hollow.resize_pane("vertical", 0.05)
	end,
	-- Resize: move the divider of the enclosing horizontal split
	resize_pane_up = function()
		hollow.resize_pane("horizontal", -0.05)
	end,
	resize_pane_down = function()
		hollow.resize_pane("horizontal", 0.05)
	end,
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
hollow.keymap.set("ctrl+shift+w", "close_pane")
hollow.keymap.set("ctrl+tab", "next_tab")
hollow.keymap.set("ctrl+shift+tab", "prev_tab")
hollow.keymap.set("ctrl+alt+n", "new_workspace")
hollow.keymap.set("ctrl+alt+arrow_right", "next_workspace")
hollow.keymap.set("ctrl+alt+arrow_left", "prev_workspace")
hollow.keymap.set("ctrl+shift+arrow_left", "focus_pane_left")
hollow.keymap.set("ctrl+shift+arrow_right", "focus_pane_right")
hollow.keymap.set("ctrl+shift+arrow_up", "focus_pane_up")
hollow.keymap.set("ctrl+shift+arrow_down", "focus_pane_down")
hollow.keymap.set("ctrl+alt+shift+arrow_left", "resize_pane_left")
hollow.keymap.set("ctrl+alt+shift+arrow_right", "resize_pane_right")
hollow.keymap.set("ctrl+alt+arrow_up", "resize_pane_up")
hollow.keymap.set("ctrl+alt+arrow_down", "resize_pane_down")
