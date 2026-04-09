hollow.keymap = hollow.keymap or {}
hollow.config = hollow.config or {}
hollow.term = hollow.term or {}
hollow.events = hollow.events or {}
hollow.keys = hollow.keys or {}
hollow.ui = hollow.ui or {}
hollow.htp = hollow.htp or {}
hollow.process = hollow.process or {}

if package ~= nil and package.loaded ~= nil then
	package.loaded.hollow = hollow
end

local host = {
	set_config = hollow.set_config,
	new_tab = hollow.new_tab,
	close_tab = hollow.close_tab,
	switch_tab = hollow.switch_tab,
	new_workspace = hollow.new_workspace,
	next_workspace = hollow.next_workspace,
	prev_workspace = hollow.prev_workspace,
	set_workspace_name = hollow.set_workspace_name,
	get_workspace_name = hollow.get_workspace_name,
	get_workspace_count = hollow.get_workspace_count,
	get_active_workspace_index = hollow.get_active_workspace_index,
	set_tab_title = hollow.set_tab_title,
	set_status = hollow.on_status,
	send_text = hollow.send_text,
	switch_tab_by_id = hollow.switch_tab_by_id,
	close_tab_by_id = hollow.close_tab_by_id,
	set_tab_title_by_id = hollow.set_tab_title_by_id,
	send_text_to_pane = hollow.send_text_to_pane,
}

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

local config_state = {}
local builtin_event_names = {
	["config:reloaded"] = true,
	["term:title_changed"] = true,
	["term:tab_activated"] = true,
	["term:tab_closed"] = true,
	["term:pane_focused"] = true,
	["term:cwd_changed"] = true,
	["key:unhandled"] = true,
	["window:resized"] = true,
	["window:focused"] = true,
	["window:blurred"] = true,
}
local event_handles = {}
local event_listeners = {}
local next_event_handle = 1
local mounted_topbar = nil
local legacy_status_renderer = nil
local mounted_sidebar = nil
local sidebar_visible = false
local overlay_stack = {}
local notifications = {}
local clone_value
local merge_tables

local function window_size_snapshot()
	return {
		rows = 0,
		cols = 0,
		width = hollow.get_window_width and hollow.get_window_width() or 0,
		height = hollow.get_window_height and hollow.get_window_height() or 0,
	}
end

local function is_span_node(value)
	return type(value) == "table"
		and (value._type == "span" or value._type == "spacer" or value._type == "icon" or value._type == "group")
end

local function canonical_mods_from_mask(mods)
	local parts = {}
	if type(mods) ~= "number" then
		return "NONE"
	end
	if mods % (MODS_CTRL * 2) >= MODS_CTRL then
		table.insert(parts, "CTRL")
	end
	if mods % (MODS_SHIFT * 2) >= MODS_SHIFT then
		table.insert(parts, "SHIFT")
	end
	if mods % (MODS_ALT * 2) >= MODS_ALT then
		table.insert(parts, "ALT")
	end
	if mods % (MODS_SUPER * 2) >= MODS_SUPER then
		table.insert(parts, "SUPER")
	end
	if #parts == 0 then
		return "NONE"
	end
	return table.concat(parts, "|")
end

local function pane_snapshot(pane_id)
	if pane_id == nil or not hollow.pane_exists(pane_id) then
		return nil
	end
	return {
		id = pane_id,
		pid = hollow.get_pane_pid(pane_id),
		cwd = hollow.get_pane_cwd(pane_id),
		title = hollow.get_pane_title(pane_id),
		is_focused = hollow.pane_is_focused(pane_id),
		size = {
			rows = hollow.get_pane_rows(pane_id),
			cols = hollow.get_pane_cols(pane_id),
			width = hollow.get_pane_width(pane_id),
			height = hollow.get_pane_height(pane_id),
		},
	}
end

local function workspace_snapshot(index)
	local count = host.get_workspace_count and host.get_workspace_count() or 0
	if type(index) ~= "number" or index < 0 or index >= count then
		return nil
	end
	return {
		index = index + 1,
		name = host.get_workspace_name and host.get_workspace_name(index) or ("ws " .. tostring(index + 1)),
		is_active = index == (host.get_active_workspace_index and host.get_active_workspace_index() or 0),
	}
end

local function tab_snapshot(tab_id, index)
	if tab_id == nil then
		return nil
	end
	local panes = {}
	local pane_count = hollow.get_tab_pane_count(tab_id) or 0
	for i = 0, pane_count - 1 do
		local pane = pane_snapshot(hollow.get_tab_pane_id_at(tab_id, i))
		if pane ~= nil then
			panes[#panes + 1] = pane
		end
	end
	local pane = pane_snapshot(hollow.get_tab_active_pane_id(tab_id))
	return {
		id = tab_id,
		title = pane and pane.title or "",
		index = index + 1,
		is_active = tab_id == hollow.current_tab_id(),
		panes = panes,
		pane = pane,
	}
end

local function widget_ctx()
	local current_tab = hollow.term.current_tab()
	local current_pane = hollow.term.current_pane()
	return {
		term = {
			tab = current_tab,
			pane = current_pane,
			tabs = hollow.term.tabs(),
			workspace = hollow.term.current_workspace and hollow.term.current_workspace() or nil,
			workspaces = hollow.term.workspaces and hollow.term.workspaces() or {},
		},
		size = window_size_snapshot(),
		time = {
			epoch_ms = math.floor(os.time() * 1000),
			iso = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		},
	}
end

local function normalize_widget_rows(rendered)
	if type(rendered) ~= "table" then
		return { {} }
	end

	local first = rendered[1]
	if first == nil or is_span_node(first) then
		return { rendered }
	end

	local rows = {}
	for _, row in ipairs(rendered) do
		if type(row) == "table" then
			rows[#rows + 1] = row
		end
	end
	return rows
end

local function render_widget_rows(widget)
	if widget == nil or type(widget.render) ~= "function" then
		return { {} }
	end
	local ok, rendered = pcall(widget.render, widget_ctx())
	if not ok then
		return { {} }
	end
	return normalize_widget_rows(rendered)
end

local function flatten_span_nodes(nodes, inherited_style, out)
	out = out or {}
	inherited_style = inherited_style or {}
	for _, node in ipairs(nodes or {}) do
		if type(node) == "table" then
			if node._type == "group" then
				local merged_style = clone_value(inherited_style)
				if type(node.style) == "table" then
					merge_tables(merged_style, node.style)
				end
				flatten_span_nodes(node.children or {}, merged_style, out)
			elseif node._type == "spacer" then
				out[#out + 1] = { text = " ", spacer = true, style = clone_value(inherited_style) }
			elseif node._type == "icon" then
				local style = clone_value(inherited_style)
				if type(node.style) == "table" then
					merge_tables(style, node.style)
				end
				out[#out + 1] = { text = node.name or "", style = style }
			elseif node._type == "span" then
				local style = clone_value(inherited_style)
				if type(node.style) == "table" then
					merge_tables(style, node.style)
				end
				out[#out + 1] = { text = node.text or "", style = style }
			end
		end
	end
	return out
end

local function style_to_segment(text, style)
	local segment = { text = text }
	if type(style) == "table" then
		segment.bold = style.bold == true
		if type(style.fg) == "string" and style.fg:match("^#%x%x%x%x%x%x$") then
			segment.fg = style.fg
		end
		if type(style.bg) == "string" and style.bg:match("^#%x%x%x%x%x%x$") then
			segment.bg = style.bg
		end
	end
	return segment
end

local function topbar_segments_from_widget(side)
	if mounted_topbar == nil then
		return nil
	end
	local rows = render_widget_rows(mounted_topbar)
	local flattened = flatten_span_nodes(rows[1] or {})
	local spacer_index = nil
	for i, node in ipairs(flattened) do
		if node.spacer then
			spacer_index = i
			break
		end
	end
	local selected = {}
	if spacer_index == nil then
		if side == "left" then
			selected = flattened
		else
			selected = {}
		end
	elseif side == "left" then
		for i = 1, spacer_index - 1 do
			selected[#selected + 1] = flattened[i]
		end
	else
		for i = spacer_index + 1, #flattened do
			selected[#selected + 1] = flattened[i]
		end
	end

	local segments = {}
	for _, node in ipairs(selected) do
		segments[#segments + 1] = style_to_segment(node.text or "", node.style)
	end
	return segments
end

local function dispatch_widget_event(name, e)
	local widgets = {}
	if mounted_topbar ~= nil then
		widgets[#widgets + 1] = mounted_topbar
	end
	if mounted_sidebar ~= nil then
		widgets[#widgets + 1] = mounted_sidebar
	end
	for _, widget in ipairs(overlay_stack) do
		widgets[#widgets + 1] = widget
	end
	for _, widget in ipairs(widgets) do
		if type(widget.on_event) == "function" then
			widget.on_event(name, e)
		end
	end
end

local function dispatch_overlay_key(key, mods)
	local canonical_mods = canonical_mods_from_mask(mods)
	for i = #overlay_stack, 1, -1 do
		local widget = overlay_stack[i]
		if type(widget.on_key) == "function" then
			local ok, consumed = pcall(widget.on_key, key, canonical_mods)
			if ok and consumed then
				return true
			end
		end
	end
	return false
end

local function widget_fill_segments(row)
	local flattened = flatten_span_nodes(row or {})
	local segments = {}
	for _, node in ipairs(flattened) do
		if not node.spacer then
			segments[#segments + 1] = style_to_segment(node.text or "", node.style)
		end
	end
	return segments
end

local function trim_row_for_width(row, max_chars)
	local flattened = flatten_span_nodes(row or {})
	local segments = {}
	local remaining = math.max(0, math.floor(max_chars or 0))
	for _, node in ipairs(flattened) do
		if remaining <= 0 then
			break
		end
		if not node.spacer then
			local text = node.text or ""
			if #text > remaining then
				text = text:sub(1, remaining)
			end
			if #text > 0 then
				segments[#segments + 1] = style_to_segment(text, node.style)
				remaining = remaining - #text
			end
		end
	end
	return segments
end

clone_value = function(value, seen)
	if type(value) ~= "table" then
		return value
	end

	seen = seen or {}
	if seen[value] ~= nil then
		return seen[value]
	end

	local copy = {}
	seen[value] = copy
	for k, v in pairs(value) do
		copy[clone_value(k, seen)] = clone_value(v, seen)
	end
	return copy
end


merge_tables = function(dst, src)
	for k, v in pairs(src) do
		if type(v) == "table" then
			local current = dst[k]
			if type(current) ~= "table" then
				current = {}
				dst[k] = current
			end
			merge_tables(current, v)
		else
			dst[k] = v
		end
	end
	return dst
end

local function unsupported(name)
	error(name .. " is not implemented yet")
end

local function normalize_key_mods(mods)
	if mods == nil or mods == "" or mods == "NONE" then
		return {}
	end

	if type(mods) ~= "string" then
		error("mods must be a string")
	end

	local seen = {}
	for token in mods:gmatch("[^|]+") do
		local upper = token:upper()
		if upper ~= "CTRL" and upper ~= "SHIFT" and upper ~= "ALT" and upper ~= "SUPER" and upper ~= "NONE" then
			error("unknown modifier: " .. tostring(token))
		end
		if upper ~= "NONE" then
			seen[upper] = true
		end
	end

	local ordered = {}
	if seen.CTRL then
		table.insert(ordered, "ctrl")
	end
	if seen.SHIFT then
		table.insert(ordered, "shift")
	end
	if seen.ALT then
		table.insert(ordered, "alt")
	end
	if seen.SUPER then
		table.insert(ordered, "super")
	end
	return ordered
end

local function make_chord(mods, key)
	if type(key) ~= "string" then
		error("key must be a string")
	end

	local parts = normalize_key_mods(mods)
	table.insert(parts, key)
	return table.concat(parts, "+")
end

local function remove_event_handle(handle)
	local listener = event_handles[handle]
	if listener == nil then
		return false
	end

	event_handles[handle] = nil
	local listeners = event_listeners[listener.name]
	if listeners ~= nil then
		for i, item in ipairs(listeners) do
			if item == handle then
				table.remove(listeners, i)
				break
			end
		end
		if #listeners == 0 then
			event_listeners[listener.name] = nil
		end
	end
	return true
end

local function emit_event(name, payload, allow_builtin)
	if builtin_event_names[name] and not allow_builtin then
		error("cannot emit built-in event from Lua: " .. tostring(name))
	end

	local listeners = event_listeners[name]
	if listeners == nil then
		return
	end

	local e = payload
	if e == nil then
		e = {}
	elseif type(e) ~= "table" then
		e = { value = e }
	end

	local handles = {}
	for i, handle in ipairs(listeners) do
		handles[i] = handle
	end
	for _, handle in ipairs(handles) do
		local listener = event_handles[handle]
		if listener ~= nil then
			listener.handler(e)
			if listener.once then
				remove_event_handle(handle)
			end
		end
	end
end

local function adapt_builtin_payload(name, payload)
	if type(payload) ~= "table" then
		return payload
	end

	if name == "term:tab_activated" then
		return { tab = hollow.term.tab_by_id(payload.tab_id) }
	end
	if name == "term:tab_closed" then
		return { tab_id = payload.tab_id }
	end
	if name == "term:pane_focused" then
		return { pane = pane_snapshot(payload.pane_id) }
	end
	if name == "term:title_changed" then
		return {
			pane = pane_snapshot(payload.pane_id),
			old_title = payload.old_title,
			new_title = payload.new_title,
		}
	end
	if name == "term:cwd_changed" then
		return {
			pane = pane_snapshot(payload.pane_id),
			old_cwd = payload.old_cwd,
			new_cwd = payload.new_cwd,
		}
	end
	if name == "window:resized" then
		return { size = payload }
	end
	if name == "key:unhandled" then
		return {
			key = payload.key,
			mods = canonical_mods_from_mask(payload.mods),
		}
	end
	return payload
end

local function validate_widget_opts(opts)
	if type(opts) ~= "table" then
		error("widget opts must be a table")
	end
	if type(opts.render) ~= "function" then
		error("widget opts.render must be a function")
	end
	return opts
end

local function make_widget(kind, opts)
	opts = validate_widget_opts(opts)
	return {
		_kind = kind,
		render = opts.render,
		on_event = opts.on_event,
		on_key = opts.on_key,
		on_mount = opts.on_mount,
		on_unmount = opts.on_unmount,
		height = opts.height,
		width = opts.width,
		side = opts.side,
		hidden = opts.hidden,
		reserve = opts.reserve,
	}
end

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

function hollow.config.set(opts)
	if type(opts) ~= "table" then
		error("hollow.config.set(opts) expects a table")
	end
	merge_tables(config_state, clone_value(opts))
	host.set_config(opts)
end

function hollow.config.get(key)
	return config_state[key]
end

function hollow.config.snapshot()
	return clone_value(config_state)
end

function hollow.config.reload()
	if not hollow.reload_config() then
		error("hollow.config.reload() failed")
	end
end

function hollow.events.on(name, handler)
	if type(name) ~= "string" then
		error("event name must be a string")
	end
	if type(handler) ~= "function" then
		error("event handler must be a function")
	end

	local handle = next_event_handle
	next_event_handle = next_event_handle + 1
	event_handles[handle] = { name = name, handler = handler, once = false }
	event_listeners[name] = event_listeners[name] or {}
	table.insert(event_listeners[name], handle)
	return handle
end

function hollow.events.off(handle)
	remove_event_handle(handle)
end

function hollow.events.once(name, handler)
	local handle = hollow.events.on(name, handler)
	event_handles[handle].once = true
	return handle
end

function hollow.events.emit(name, payload)
	emit_event(name, payload, false)
end

function hollow._emit_builtin_event(name, payload)
	local adapted = adapt_builtin_payload(name, payload)
	dispatch_widget_event(name, adapted)
	emit_event(name, adapted, true)
end

function hollow.keys.bind(binds)
	if type(binds) ~= "table" then
		error("hollow.keys.bind(binds) expects a table")
	end
	for _, bind in ipairs(binds) do
		hollow.keys.bind_one(bind)
	end
end

function hollow.keys.bind_one(bind)
	if type(bind) ~= "table" then
		error("bind must be a table")
	end
	return hollow.keymap.set(make_chord(bind.mods, bind.key), bind.action, { desc = bind.desc })
end

function hollow.keys.unbind(mods, key)
	return hollow.keymap.del(make_chord(mods, key))
end

function hollow.term.current_tab()
	local tab_id = hollow.current_tab_id()
	if tab_id == nil then
		return nil
	end
	local index = hollow.get_tab_index_by_id(tab_id)
	if index == nil then
		return nil
	end
	return tab_snapshot(tab_id, index)
end

function hollow.term.current_pane()
	local pane_id = hollow.current_pane_id()
	return pane_snapshot(pane_id)
end

function hollow.term.tabs()
	local tabs = {}
	local count = hollow.get_tab_count()
	for i = 0, count - 1 do
		local tab_id = hollow.get_tab_id_at(i)
		if tab_id ~= nil then
			tabs[#tabs + 1] = tab_snapshot(tab_id, i)
		end
	end
	return tabs
end

function hollow.term.workspaces()
	local workspaces = {}
	local count = host.get_workspace_count and host.get_workspace_count() or 0
	for i = 0, count - 1 do
		local ws = workspace_snapshot(i)
		if ws ~= nil then
			workspaces[#workspaces + 1] = ws
		end
	end
	return workspaces
end

function hollow.term.current_workspace()
	local index = host.get_active_workspace_index and host.get_active_workspace_index() or 0
	return workspace_snapshot(index)
end

function hollow.term.set_workspace_name(name)
	if type(name) ~= "string" then
		error("hollow.term.set_workspace_name(name) expects a string")
	end
	host.set_workspace_name(name)
end

function hollow.term.new_workspace()
	host.new_workspace()
end

function hollow.term.next_workspace()
	host.next_workspace()
end

function hollow.term.prev_workspace()
	host.prev_workspace()
end

function hollow.term.tab_by_id(id)
	for _, tab in ipairs(hollow.term.tabs()) do
		if tab.id == id then
			return tab
		end
	end
	return nil
end

function hollow.term.new_tab(opts)
	if opts ~= nil and type(opts) ~= "table" then
		error("hollow.term.new_tab(opts) expects a table or nil")
	end
	if opts ~= nil and next(opts) ~= nil then
		unsupported("hollow.term.new_tab(opts)")
	end
	host.new_tab()
	return nil
end

function hollow.term.focus_tab(id)
	if type(id) ~= "number" then
		error("hollow.term.focus_tab(id) expects a tab id")
	end
	if not host.switch_tab_by_id(id) then
		error("unknown tab id: " .. tostring(id))
	end
end

function hollow.term.close_tab(id)
	if type(id) ~= "number" then
		error("hollow.term.close_tab(id) expects a tab id")
	end
	if not host.close_tab_by_id(id) then
		error("unknown tab id: " .. tostring(id))
	end
end

function hollow.term.set_title(title, tab_id)
	if type(title) ~= "string" then
		error("hollow.term.set_title(title) expects a string")
	end
	if tab_id ~= nil then
		if not host.set_tab_title_by_id(tab_id, title) then
			error("unknown tab id: " .. tostring(tab_id))
		end
		return
	end
	host.set_tab_title(title)
end

function hollow.term.send_text(text, pane_id)
	if type(text) ~= "string" then
		error("hollow.term.send_text(text) expects a string")
	end
	if pane_id ~= nil then
		if not host.send_text_to_pane(pane_id, text) then
			error("unknown pane id: " .. tostring(pane_id))
		end
		return
	end
	host.send_text(text)
end

function hollow.ui.span(text, style)
	return { _type = "span", text = text, style = style }
end

function hollow.ui.spacer()
	return { _type = "spacer" }
end

function hollow.ui.icon(name, style)
	return { _type = "icon", name = tostring(name or ""), style = style }
end

function hollow.ui.group(children, style)
	return { _type = "group", children = children or {}, style = style }
end

hollow.ui.topbar = hollow.ui.topbar or {}

function hollow.ui.topbar.new(opts)
	return make_widget("topbar", opts)
end

function hollow.ui.topbar.mount(widget)
	if mounted_topbar ~= nil and mounted_topbar.on_unmount then
		mounted_topbar.on_unmount()
	end
	mounted_topbar = widget
	if widget.on_mount then
		widget.on_mount()
	end
	host.set_status(function(side, active_tab_index, tab_count)
		if mounted_topbar == nil then
			return legacy_status_renderer and legacy_status_renderer(side, active_tab_index, tab_count) or nil
		end
		return topbar_segments_from_widget(side)
	end)
end

function hollow.ui.topbar.unmount()
	local widget = mounted_topbar
	if widget and widget.on_unmount then
		widget.on_unmount()
	end
	mounted_topbar = nil
	host.set_status(legacy_status_renderer)
end

function hollow.ui.topbar.invalidate()
	return mounted_topbar ~= nil
end

hollow.ui.sidebar = hollow.ui.sidebar or {}

function hollow.ui.sidebar.new(opts)
	return make_widget("sidebar", opts)
end

function hollow.ui.sidebar.mount(widget)
	if mounted_sidebar ~= nil and mounted_sidebar.on_unmount then
		mounted_sidebar.on_unmount()
	end
	mounted_sidebar = widget
	sidebar_visible = widget.hidden ~= true
	if widget.on_mount then
		widget.on_mount()
	end
end

function hollow.ui.sidebar.unmount()
	if mounted_sidebar and mounted_sidebar.on_unmount then
		mounted_sidebar.on_unmount()
	end
	mounted_sidebar = nil
	sidebar_visible = false
end

function hollow.ui.sidebar.toggle()
	if mounted_sidebar == nil then
		return false
	end
	sidebar_visible = not sidebar_visible
	return sidebar_visible
end

function hollow.ui.sidebar.invalidate()
	return mounted_sidebar ~= nil
end

hollow.ui.overlay = hollow.ui.overlay or {}

function hollow.ui.overlay.new(opts)
	return make_widget("overlay", opts)
end

function hollow.ui.overlay.push(widget)
	table.insert(overlay_stack, widget)
	if widget.on_mount then
		widget.on_mount()
	end
end

function hollow.ui.overlay.pop()
	local widget = table.remove(overlay_stack)
	if widget and widget.on_unmount then
		widget.on_unmount()
	end
	return widget
end

function hollow.ui.overlay.clear()
	while #overlay_stack > 0 do
		hollow.ui.overlay.pop()
	end
end

function hollow.ui.overlay.depth()
	return #overlay_stack
end

function hollow.ui._sidebar_state()
	if mounted_sidebar == nil or not sidebar_visible then
		return nil
	end
	local rows = render_widget_rows(mounted_sidebar)
	local side = mounted_sidebar.side == "right" and "right" or "left"
	local width = tonumber(mounted_sidebar.width) or 24
	local segments = {}
	for i, row in ipairs(rows) do
		segments[i] = trim_row_for_width(row, width)
	end
	return {
		side = side,
		width = math.max(1, math.floor(width)),
		reserve = mounted_sidebar.reserve == true,
		rows = segments,
	}
end

function hollow.ui._overlay_state()
	if #overlay_stack == 0 then
		return nil
	end
	local rows = {}
	for _, widget in ipairs(overlay_stack) do
		local widget_rows = render_widget_rows(widget)
		local seg_rows = {}
		for i, row in ipairs(widget_rows) do
			seg_rows[i] = widget_fill_segments(row)
		end
		rows[#rows + 1] = seg_rows
	end
	return rows
end

hollow.ui.notify = hollow.ui.notify or {}

function hollow.ui.notify.show(message, opts)
	opts = opts or {}
	local title = opts.title and (opts.title .. ": ") or ""
	local ttl = opts.ttl
	local action = opts.action
	local widget = hollow.ui.overlay.new({
		render = function()
			local prefix = "[" .. string.upper(opts.level or "info") .. "] "
			local action_text = action and ("  [" .. action.label .. "]") or ""
			return {
				{
					hollow.ui.group({
						hollow.ui.span(prefix .. title .. message .. action_text, {
							fg = opts.level == "error" and "#ffb4a9" or "#d8dee9",
							bg = "#1f2430",
							bold = true,
						}),
					}, { bg = "#1f2430" }),
				},
			}
		end,
		on_key = function(key)
			if key == "escape" or key == "enter" then
				hollow.ui.overlay.pop()
				if action and key == "enter" and type(action.fn) == "function" then
					action.fn()
				end
				return true
			end
			return false
		end,
	})
	hollow.ui.overlay.push(widget)
	if type(ttl) == "number" and ttl > 0 then
		widget._expires_at = now_ms() + ttl
	end
	return widget
end

function hollow.ui.notify.clear()
	notifications = {}
end

function hollow.ui.notify.info(message, opts)
	opts = opts or {}
	if opts.level == nil then
		opts.level = "info"
	end
	return hollow.ui.notify.show(message, opts)
end

function hollow.ui.notify.warn(message, opts)
	opts = opts or {}
	if opts.level == nil then
		opts.level = "warn"
	end
	return hollow.ui.notify.show(message, opts)
end

function hollow.ui.notify.error(message, opts)
	opts = opts or {}
	if opts.level == nil then
		opts.level = "error"
	end
	return hollow.ui.notify.show(message, opts)
end

hollow.ui.input = hollow.ui.input or {}

function hollow.ui.input.open(opts)
	local state = {
		prompt = opts.prompt or "",
		value = opts.default or "",
	}
	local widget
	widget = hollow.ui.overlay.new({
		render = function()
			return {
				{
					hollow.ui.span(state.prompt .. state.value, {
						fg = "#d8dee9",
						bg = "#20242f",
					}),
				},
			}
		end,
		on_key = function(key)
			if key == "escape" then
				hollow.ui.overlay.pop()
				if type(opts.on_cancel) == "function" then
					opts.on_cancel()
				end
				return true
			end
			if key == "enter" then
				hollow.ui.overlay.pop()
				if type(opts.on_confirm) == "function" then
					opts.on_confirm(state.value)
				end
				return true
			end
			if key == "backspace" then
				state.value = state.value:sub(1, math.max(0, #state.value - 1))
				return true
			end
			if #key == 1 then
				state.value = state.value .. key
				return true
			end
			return false
		end,
	})
	hollow.ui.overlay.push(widget)
end

function hollow.ui.input.close()
	hollow.ui.overlay.pop()
end

hollow.ui.select = hollow.ui.select or {}

function hollow.ui.select.open(opts)
	local state = { index = 1 }
	local items = opts.items or {}
	local label = opts.label or tostring
	local widget
	widget = hollow.ui.overlay.new({
		render = function()
			local rows = {}
			rows[#rows + 1] = {
				hollow.ui.span((opts.prompt or "Select") .. ":", { fg = "#88c0d0", bold = true }),
			}
			for i, item in ipairs(items) do
				local prefix = i == state.index and "> " or "  "
				rows[#rows + 1] = {
					hollow.ui.span(prefix .. label(item), {
						fg = i == state.index and "#eceff4" or "#d8dee9",
						bg = i == state.index and "#3b4252" or nil,
						bold = i == state.index,
					}),
				}
			end
			return rows
		end,
		on_key = function(key)
			if key == "escape" then
				hollow.ui.overlay.pop()
				if type(opts.on_cancel) == "function" then
					opts.on_cancel()
				end
				return true
			end
			if key == "arrow_down" then
				state.index = math.min(#items, state.index + 1)
				return true
			end
			if key == "arrow_up" then
				state.index = math.max(1, state.index - 1)
				return true
			end
			if key == "enter" then
				local action = opts.actions and opts.actions[1]
				local item = items[state.index]
				if action and item ~= nil then
					action.fn(item)
				end
				return true
			end
			return false
		end,
	})
	hollow.ui.overlay.push(widget)
end

function hollow.ui.select.close()
	hollow.ui.overlay.pop()
end

function hollow.htp.on_query(channel, handler)
	unsupported("hollow.htp.on_query")
end

function hollow.htp.on_emit(channel, handler)
	unsupported("hollow.htp.on_emit")
end

function hollow.htp.off_query(channel)
	unsupported("hollow.htp.off_query")
end

function hollow.htp.off_emit(channel)
	unsupported("hollow.htp.off_emit")
end

function hollow.process.spawn(opts)
	unsupported("hollow.process.spawn")
end

function hollow.process.exec(opts)
	unsupported("hollow.process.exec")
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

hollow.on_key(function(key, mods)
	if dispatch_overlay_key(key, mods) then
		return true
	end

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
