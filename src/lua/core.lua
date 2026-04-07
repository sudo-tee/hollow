hollow.keymap = {}
hollow.top_bar = {}
hollow.status = {}

local bindings = {}
local leader_bindings = { children = {} }
local leader = nil
local leader_timeout_ms = 1000
local leader_pending_until = nil
local leader_active_node = nil
local leader_sequence_steps = {}

local MODS_SHIFT = 0x01
local MODS_CTRL = 0x02
local MODS_ALT = 0x04
local MODS_SUPER = 0x08

-- Lua 5.1 compatible bit operations
-- Since we only OR distinct bit flags, addition works the same as bit.bor
local function bor(a, b)
	return a + b
end

local function now_ms()
	return math.floor(os.clock() * 1000)
end

local function is_sequence_modifier_token(token)
	return token == "ctrl"
		or token == "shift"
		or token == "alt"
		or token == "super"
		or token == "cmd"
end

local function normalize_key_name(key)
	local lower = key:lower()
	if lower == "left" then
		return "arrow_left"
	elseif lower == "right" then
		return "arrow_right"
	elseif lower == "up" then
		return "arrow_up"
	elseif lower == "down" then
		return "arrow_down"
	elseif lower == "esc" then
		return "escape"
	elseif lower == "cr" or lower == "return" then
		return "enter"
	elseif lower == "bs" then
		return "backspace"
	end
	return lower
end

local function split_leader_chord(chord)
	if type(chord) ~= "string" then
		return false, chord, nil
	end

	local lower = chord:lower()
	if lower:sub(1, 7) == "leader+" then
		return true, chord:sub(8), "legacy"
	elseif lower:sub(1, 8) == "<leader>" then
		return true, chord:sub(9), "vim"
	end

	return false, chord, nil
end

local function parse_chord(chord)
	if type(chord) == "string" and chord:sub(1, 1) == "<" and chord:sub(-1) == ">" then
		local inner = chord:sub(2, -2)
		local parts = {}
		for part in inner:gmatch("[^-]+") do
			table.insert(parts, part)
		end

		if #parts > 0 then
			local mods = 0
			local key = normalize_key_name(table.remove(parts))
			for _, mod in ipairs(parts) do
				local lower = mod:lower()
				if lower == "ctrl" or lower == "c" then
					mods = bor(mods, MODS_CTRL)
				elseif lower == "shift" or lower == "s" then
					mods = bor(mods, MODS_SHIFT)
				elseif lower == "alt" or lower == "a" or lower == "m" or lower == "meta" then
					mods = bor(mods, MODS_ALT)
				elseif lower == "super" or lower == "d" or lower == "cmd" or lower == "w" then
					mods = bor(mods, MODS_SUPER)
				end
			end
			return key, mods
		end
	end

	local mods = 0
	local parts = {}
	for part in chord:gmatch("[^+]+") do
		table.insert(parts, part:lower())
	end

	local key = normalize_key_name(table.remove(parts))
	for _, mod in ipairs(parts) do
		if mod == "ctrl" or mod == "c" then
			mods = bor(mods, MODS_CTRL)
		elseif mod == "shift" or mod == "s" then
			mods = bor(mods, MODS_SHIFT)
		elseif mod == "alt" or mod == "m" then
			mods = bor(mods, MODS_ALT)
		elseif mod == "super" or mod == "cmd" or mod == "w" then
			mods = bor(mods, MODS_SUPER)
		end
	end
	return key, mods
end

local function parse_vim_sequence(chord)
	local steps = {}
	local i = 1
	while i <= #chord do
		local ch = chord:sub(i, i)
		if ch == "<" then
			local close = chord:find(">", i, true)
			if not close then
				return nil
			end
			table.insert(steps, chord:sub(i, close))
			i = close + 1
		else
			table.insert(steps, ch)
			i = i + 1
		end
	end
	if #steps == 0 then
		return nil
	end
	return steps
end

local function parse_leader_sequence(chord, style)
	if style == "vim" then
		return parse_vim_sequence(chord)
	end

	local steps = {}
	local current = {}

	for part in chord:gmatch("[^+]+") do
		local token = part:lower()
		table.insert(current, token)
		if not is_sequence_modifier_token(token) then
			table.insert(steps, table.concat(current, "+"))
			current = {}
		end
	end

	if #current ~= 0 or #steps == 0 then
		return nil
	end

	return steps
end

local function normalize_binding(action_or_opts, maybe_opts)
	local binding = {
		action = action_or_opts,
		desc = nil,
	}

	if type(action_or_opts) == "table" and maybe_opts == nil then
		binding.action = action_or_opts.action
		binding.desc = action_or_opts.desc
	elseif type(maybe_opts) == "table" then
		binding.desc = maybe_opts.desc
	end

	return binding
end

local function set_binding(store, chord, action, opts)
	local key, mods = parse_chord(chord)
	store[key] = store[key] or {}
	store[key][mods] = normalize_binding(action, opts)
end

local function del_binding(store, chord)
	local key, mods = parse_chord(chord)
	local key_bindings = store[key]
	if not key_bindings or key_bindings[mods] == nil then
		return false
	end

	key_bindings[mods] = nil
	if next(key_bindings) == nil then
		store[key] = nil
	end

	return true
end

local function get_binding(store, key, mods)
	local key_bindings = store[key]
	if not key_bindings then
		return nil
	end
	return key_bindings[mods]
end

local function reset_leader_state()
	leader_pending_until = nil
	leader_active_node = nil
	leader_sequence_steps = {}
end

local function has_mod(mods, flag)
	return mods % (flag * 2) >= flag
end

local function format_key_name(key)
	if key == "arrow_left" then
		return "Left"
	elseif key == "arrow_right" then
		return "Right"
	elseif key == "arrow_up" then
		return "Up"
	elseif key == "arrow_down" then
		return "Down"
	elseif key == "escape" then
		return "Esc"
	elseif key == "enter" then
		return "CR"
	elseif key == "backspace" then
		return "BS"
	elseif key == "tab" then
		return "Tab"
	elseif key == "space" then
		return "Space"
	end
	return key
end

local function format_chord(key, mods)
	local key_name = format_key_name(key)
	local special = key_name ~= key or #key ~= 1
	if mods == 0 and not special then
		return key_name
	end

	local parts = {}
	if has_mod(mods, MODS_CTRL) then
		table.insert(parts, "C")
	end
	if has_mod(mods, MODS_SHIFT) then
		table.insert(parts, "S")
	end
	if has_mod(mods, MODS_ALT) then
		table.insert(parts, "M")
	end
	if has_mod(mods, MODS_SUPER) then
		table.insert(parts, "D")
	end
	table.insert(parts, key_name)
	return "<" .. table.concat(parts, "-") .. ">"
end

local function copy_list(items)
	local out = {}
	for i, value in ipairs(items) do
		out[i] = value
	end
	return out
end

local function has_sequence_children(node)
	return node ~= nil and node.children ~= nil and next(node.children) ~= nil
end

local function get_leader_next_keys(node)
	local items = {}
	if node == nil or node.children == nil then
		return items
	end

	for key, modmap in pairs(node.children) do
		for mods, child in pairs(modmap) do
			table.insert(items, {
				key = format_chord(key, mods),
				desc = child.desc,
				complete = child.action ~= nil,
				has_children = has_sequence_children(child),
			})
		end
	end

	table.sort(items, function(a, b)
		return a.key < b.key
	end)
	return items
end

local function format_next_items(items)
	local out = {}
	for _, item in ipairs(items) do
		local text = item.key
		if item.desc and item.desc ~= "" then
			text = text .. ":" .. item.desc
		end
		table.insert(out, text)
	end
	return out
end

local function ensure_sequence_child(node, chord)
	local key, mods = parse_chord(chord)
	node.children[key] = node.children[key] or {}
	node.children[key][mods] = node.children[key][mods] or {
		action = nil,
		desc = nil,
		children = {},
	}
	return node.children[key][mods]
end

local function get_sequence_child(node, key, mods)
	if node == nil or node.children == nil then
		return nil
	end

	local key_bindings = node.children[key]
	if not key_bindings then
		return nil
	end

	return key_bindings[mods]
end

local function set_leader_binding(chord, style, action, opts)
	local steps = parse_leader_sequence(chord, style)
	if not steps then
		error("invalid leader sequence: " .. tostring(chord))
	end
	local binding = normalize_binding(action, opts)

	local node = leader_bindings
	for _, step in ipairs(steps) do
		node = ensure_sequence_child(node, step)
	end
	node.action = binding.action
	node.desc = binding.desc
end

local function del_leader_binding(chord, style)
	local steps = parse_leader_sequence(chord, style)
	if not steps then
		return false
	end

	local path = {}
	local node = leader_bindings
	for _, step in ipairs(steps) do
		local key, mods = parse_chord(step)
		local next_node = get_sequence_child(node, key, mods)
		if not next_node then
			return false
		end
		table.insert(path, { parent = node, key = key, mods = mods, node = next_node })
		node = next_node
	end

	if node.action == nil then
		return false
	end

	node.action = nil
	node.desc = nil

	for i = #path, 1, -1 do
		local item = path[i]
		if item.node.action ~= nil or has_sequence_children(item.node) then
			break
		end

		item.parent.children[item.key][item.mods] = nil
		if next(item.parent.children[item.key]) == nil then
			item.parent.children[item.key] = nil
		end
	end

	return true
end

local function run_action(binding)
	if binding == nil then
		return false
	end

	local action = binding.action
	if type(action) == "function" then
		action()
		return true
	end

	if type(action) == "string" and hollow.action[action] then
		hollow.action[action]()
		return true
	end

	return false
end

local function is_leader_active()
	if leader_pending_until == nil then
		return false
	end

	if now_ms() > leader_pending_until then
		reset_leader_state()
		return false
	end

	return true
end

function hollow.keymap.set(chord, action, opts)
	local use_leader, resolved, style = split_leader_chord(chord)
	if use_leader then
		set_leader_binding(resolved, style, action, opts)
	else
		set_binding(bindings, resolved, action, opts)
	end
end

function hollow.keymap.del(chord)
	local use_leader, resolved, style = split_leader_chord(chord)
	if use_leader then
		return del_leader_binding(resolved, style)
	end
	return del_binding(bindings, resolved)
end

function hollow.keymap.get(chord)
	local use_leader, resolved, style = split_leader_chord(chord)
	if use_leader then
		return nil
	end
	local key, mods = parse_chord(resolved)
	return get_binding(bindings, key, mods)
end

function hollow.keymap.set_leader(chord, opts)
	if chord == nil then
		leader = nil
		reset_leader_state()
		return
	end

	local key, mods = parse_chord(chord)
	leader = { key = key, mods = mods }
	reset_leader_state()

	if type(opts) == "table" and type(opts.timeout_ms) == "number" and opts.timeout_ms > 0 then
		leader_timeout_ms = math.floor(opts.timeout_ms)
	end
end

function hollow.keymap.clear_leader()
	leader = nil
	reset_leader_state()
end

function hollow.keymap.is_leader_active()
	return is_leader_active()
end

function hollow.keymap.get_leader_state()
	if not is_leader_active() then
		return nil
	end

	local node = leader_active_node or leader_bindings
	return {
		active = true,
		prefix = "<leader>",
		sequence = copy_list(leader_sequence_steps),
		display = #leader_sequence_steps > 0
			and ("<leader> " .. table.concat(leader_sequence_steps, " "))
			or "<leader>",
		next = get_leader_next_keys(node),
		next_display = format_next_items(get_leader_next_keys(node)),
		desc = node.desc,
		remaining_ms = math.max(0, leader_pending_until - now_ms()),
		timeout_ms = leader_timeout_ms,
		complete = node.action ~= nil,
	}
end

hollow.get_leader_state = hollow.keymap.get_leader_state
hollow.is_leader_active = hollow.keymap.is_leader_active

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
	copy_selection = function()
		hollow.copy_selection()
	end,
	paste_clipboard = function()
		hollow.paste_clipboard()
	end,
	scrollback_line_up = function()
		hollow.scroll_active(-1)
	end,
	scrollback_line_down = function()
		hollow.scroll_active(1)
	end,
	scrollback_page_up = function()
		hollow.scroll_active_page(-1)
	end,
	scrollback_page_down = function()
		hollow.scroll_active_page(1)
	end,
	scrollback_top = function()
		hollow.scroll_active_top()
	end,
	scrollback_bottom = function()
		hollow.scroll_active_bottom()
	end,
}

hollow.clipboard = hollow.clipboard or {}

function hollow.clipboard.copy()
	hollow.copy_selection()
end

function hollow.clipboard.paste()
	hollow.paste_clipboard()
end

hollow.on_key(function(key, mods)
	if is_leader_active() then
		local node = get_sequence_child(leader_active_node or leader_bindings, key, mods)
		if node ~= nil then
			leader_active_node = node
			table.insert(leader_sequence_steps, format_chord(key, mods))
			leader_pending_until = now_ms() + leader_timeout_ms
			if node.action ~= nil and not has_sequence_children(node) then
				reset_leader_state()
				return run_action(node)
			end
			return true
		end
		reset_leader_state()
		return true
	end

	if leader ~= nil and key == leader.key and mods == leader.mods then
		leader_active_node = leader_bindings
		leader_sequence_steps = {}
		leader_pending_until = now_ms() + leader_timeout_ms
		return true
	end

	local action = get_binding(bindings, key, mods)
	if action ~= nil then
		return run_action(action)
	end

	return false
end)

-- Default bindings
hollow.keymap.set("ctrl+shift+v", "paste_clipboard")
hollow.keymap.set("shift+insert", "paste_clipboard")
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
hollow.keymap.set("alt+shift+page_up", "scrollback_page_up")
hollow.keymap.set("alt+shift+page_down", "scrollback_page_down")
hollow.keymap.set("ctrl+shift+home", "scrollback_top")
hollow.keymap.set("ctrl+shift+end", "scrollback_bottom")
