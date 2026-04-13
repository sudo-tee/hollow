local M = {}

local MODS_SHIFT = 0x01
local MODS_CTRL = 0x02
local MODS_ALT = 0x04
local MODS_SUPER = 0x08

local function bor(a, b)
  return a + b
end

local time_now_ms = function()
  return math.floor(os.time() * 1000)
end

local function now_ms()
  return time_now_ms()
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
  elseif lower == "tab" then
    return "tab"
  elseif lower == "space" or key == " " then
    return "space"
  elseif lower == "pageup" or lower == "page_up" or lower == "pgup" then
    return "page_up"
  elseif lower == "pagedown" or lower == "page_down" or lower == "pgdown" or lower == "pgdn" then
    return "page_down"
  elseif lower == "home" then
    return "home"
  elseif lower == "end" then
    return "end"
  elseif lower == "insert" or lower == "ins" then
    return "insert"
  elseif lower == "delete" or lower == "del" then
    return "delete"
  elseif lower == "backslash" or lower == "bslash" or key == "\\" then
    return "backslash"
  end
  return lower
end

local function split_leader_chord(chord)
  if type(chord) ~= "string" then
    return false, chord, nil
  end

  local lower = chord:lower()
  if lower:sub(1, 8) == "<leader>" then
    return true, chord:sub(9), "vim"
  end

  return false, chord, nil
end

local function modifier_mask_from_token(token)
  local lower = token:lower()
  if lower == "ctrl" or lower == "c" then
    return MODS_CTRL
  elseif lower == "shift" or lower == "s" then
    return MODS_SHIFT
  elseif lower == "alt" or lower == "a" or lower == "m" or lower == "meta" then
    return MODS_ALT
  elseif lower == "super" or lower == "d" or lower == "cmd" or lower == "w" then
    return MODS_SUPER
  end
  return nil
end

local function parse_chord(chord)
  if type(chord) ~= "string" then
    error("key chord must be a string")
  end

  if chord == "" then
    error("key chord must not be empty")
  end

  if chord:find("+", 1, true) then
    error("legacy key chord syntax is not supported; use Vim-style chords like <C-t> or <leader>e")
  end

  if chord:sub(1, 1) == "<" then
    local close = chord:find(">", 1, true)
    if close ~= #chord then
      error("expected a single Vim-style key chord like <C-t> or a leader sequence like <leader>e")
    end

    local inner = chord:sub(2, -2)
    if inner == "" then
      error("key chord must not be empty")
    end

    local parts = {}
    for part in inner:gmatch("[^-]+") do
      table.insert(parts, part)
    end

    if #parts == 0 then
      error("key chord must not be empty")
    end

    local mods = 0
    local key = normalize_key_name(table.remove(parts))
    for _, mod in ipairs(parts) do
      local mask = modifier_mask_from_token(mod)
      if mask == nil then
        error("unknown modifier in key chord: " .. tostring(mod))
      end
      mods = bor(mods, mask)
    end
    return key, mods
  end

  if #chord ~= 1 then
    error("plain key chords must be a single character; use Vim-style tokens like <Tab> for special keys")
  end

  return normalize_key_name(chord), 0
end

local function parse_vim_sequence(chord)
  if type(chord) ~= "string" or chord == "" then
    return nil
  end

  if chord:find("+", 1, true) then
    return nil
  end

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

  return nil
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
  elseif key == "page_up" then
    return "PageUp"
  elseif key == "page_down" then
    return "PageDown"
  elseif key == "home" then
    return "Home"
  elseif key == "end" then
    return "End"
  elseif key == "insert" then
    return "Insert"
  elseif key == "delete" then
    return "Del"
  elseif key == "backslash" then
    return "\\"
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
    table.insert(parts, "A")
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
  node.children[key][mods] = node.children[key][mods]
    or {
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

local function reset_sequence_state(keymap_state)
  keymap_state.sequence_pending_until = nil
  keymap_state.sequence_active_node = nil
  keymap_state.sequence_steps = {}
  keymap_state.sequence_prefix = nil
end

local function set_sequence_state(keymap_state, node, prefix, steps)
  keymap_state.sequence_active_node = node
  keymap_state.sequence_prefix = prefix
  keymap_state.sequence_steps = steps or {}
  keymap_state.sequence_pending_until = now_ms() + keymap_state.sequence_timeout_ms
end

local function set_leader_binding(keymap_state, chord, style, action, opts)
  local steps = parse_leader_sequence(chord, style)
  if not steps then
    error("invalid leader sequence: " .. tostring(chord))
  end
  local binding = normalize_binding(action, opts)

  local node = keymap_state.leader_bindings
  for _, step in ipairs(steps) do
    node = ensure_sequence_child(node, step)
  end
  node.action = binding.action
  node.desc = binding.desc
end

local function set_sequence_binding(root, steps, action, opts)
  local binding = normalize_binding(action, opts)
  local node = root
  for _, step in ipairs(steps) do
    node = ensure_sequence_child(node, step)
  end
  node.action = binding.action
  node.desc = binding.desc
end

local function del_leader_binding(keymap_state, chord, style)
  local steps = parse_leader_sequence(chord, style)
  if not steps then
    return false
  end

  local path = {}
  local node = keymap_state.leader_bindings
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

local function del_sequence_binding(root, steps)
  local path = {}
  local node = root
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

local function get_sequence_binding(root, steps)
  local node = root
  for _, step in ipairs(steps) do
    local key, mods = parse_chord(step)
    node = get_sequence_child(node, key, mods)
    if node == nil then
      return nil
    end
  end
  if node.action == nil then
    return nil
  end
  return node
end

local function run_action(hollow, binding)
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

local function is_sequence_active(keymap_state)
  if keymap_state.sequence_pending_until == nil then
    return false
  end

  if now_ms() > keymap_state.sequence_pending_until then
    reset_sequence_state(keymap_state)
    return false
  end

  return true
end

local function format_mods(mods)
  local parts = {}
  if type(mods) ~= "number" then
    return ""
  end
  if mods % (MODS_CTRL * 2) >= MODS_CTRL then
    table.insert(parts, "C")
  end
  if mods % (MODS_SHIFT * 2) >= MODS_SHIFT then
    table.insert(parts, "S")
  end
  if mods % (MODS_ALT * 2) >= MODS_ALT then
    table.insert(parts, "A")
  end
  if mods % (MODS_SUPER * 2) >= MODS_SUPER then
    table.insert(parts, "D")
  end
  if #parts == 0 then
    return ""
  end
  return "<" .. table.concat(parts, "-") .. ">"
end

---@param hollow Hollow
---@param host_api HollowHostBridge
---@param state HollowState
function M.setup(hollow, host_api, state)
  local keymap_state = state.keymap

  time_now_ms = function()
    if type(host_api.now_ms) == "function" then
      local ok, value = pcall(host_api.now_ms)
      if ok and type(value) == "number" then
        return math.floor(value)
      end
    end
    return math.floor(os.time() * 1000)
  end

  hollow.keymap.format_mods = format_mods
  hollow.keymap.format_chord = format_chord
  hollow.keymap.parse_chord = parse_chord

  function hollow.keymap.set(chord, action, opts)
    local use_leader, resolved, style = split_leader_chord(chord)
    if use_leader then
      set_leader_binding(keymap_state, resolved, style, action, opts)
    else
      local steps = parse_vim_sequence(resolved)
      if steps ~= nil and #steps > 1 then
        set_sequence_binding(keymap_state.sequence_bindings, steps, action, opts)
      else
        set_binding(keymap_state.bindings, resolved, action, opts)
      end
    end
  end

  function hollow.keymap.del(chord)
    local use_leader, resolved, style = split_leader_chord(chord)
    if use_leader then
      return del_leader_binding(keymap_state, resolved, style)
    end
    local steps = parse_vim_sequence(resolved)
    if steps ~= nil and #steps > 1 then
      return del_sequence_binding(keymap_state.sequence_bindings, steps)
    end
    return del_binding(keymap_state.bindings, resolved)
  end

  function hollow.keymap.get(chord)
    local use_leader, resolved = split_leader_chord(chord)
    if use_leader then
      local steps = parse_vim_sequence(resolved)
      if steps == nil then
        return nil
      end
      local binding = get_sequence_binding(keymap_state.leader_bindings, steps)
      return binding and binding.action or nil
    end
    local steps = parse_vim_sequence(resolved)
    if steps ~= nil and #steps > 1 then
      local binding = get_sequence_binding(keymap_state.sequence_bindings, steps)
      return binding and binding.action or nil
    end
    local key, mods = parse_chord(resolved)
    local binding = get_binding(keymap_state.bindings, key, mods)
    return binding and binding.action or nil
  end

  function hollow.keymap.set_leader(chord, opts)
    if chord == nil then
      keymap_state.leader = nil
      reset_sequence_state(keymap_state)
      return
    end

    local key, mods = parse_chord(chord)
    keymap_state.leader = { key = key, mods = mods }
    reset_sequence_state(keymap_state)

    if type(opts) == "table" and type(opts.timeout_ms) == "number" and opts.timeout_ms > 0 then
      keymap_state.sequence_timeout_ms = math.floor(opts.timeout_ms)
    end
  end

  function hollow.keymap.clear_leader()
    keymap_state.leader = nil
    reset_sequence_state(keymap_state)
  end

  function hollow.keymap.is_leader_active()
    return is_sequence_active(keymap_state)
  end

  function hollow.keymap.get_leader_state()
    if not is_sequence_active(keymap_state) then
      return nil
    end

    local node = keymap_state.sequence_active_node
    local next_items = get_leader_next_keys(node)
    local prefix = keymap_state.sequence_prefix or ""
    local steps = copy_list(keymap_state.sequence_steps)
    local display = prefix
    if #steps > 0 then
      if display ~= "" then
        display = display .. " " .. table.concat(steps, " ")
      else
        display = table.concat(steps, " ")
      end
    end
    return {
      active = true,
      prefix = prefix,
      sequence = steps,
      display = display,
      next = next_items,
      next_display = format_next_items(next_items),
      desc = node.desc,
      remaining_ms = math.max(0, keymap_state.sequence_pending_until - now_ms()),
      timeout_ms = keymap_state.sequence_timeout_ms,
      complete = node.action ~= nil,
    }
  end

  host_api.on_key(function(key, mods)
    if hollow.ui.dispatch_overlay_key(key, mods) then
      return true
    end

    if is_sequence_active(keymap_state) then
      local node = get_sequence_child(keymap_state.sequence_active_node, key, mods)
      if node ~= nil then
        keymap_state.sequence_active_node = node
        table.insert(keymap_state.sequence_steps, format_chord(key, mods))
        keymap_state.sequence_pending_until = now_ms() + keymap_state.sequence_timeout_ms
        if node.action ~= nil and not has_sequence_children(node) then
          reset_sequence_state(keymap_state)
          return run_action(hollow, node)
        end
        return true
      end
      reset_sequence_state(keymap_state)
      return true
    end

    if keymap_state.leader ~= nil and key == keymap_state.leader.key and mods == keymap_state.leader.mods then
      set_sequence_state(keymap_state, keymap_state.leader_bindings, "<leader>", {})
      return true
    end

    local sequence_node = get_sequence_child(keymap_state.sequence_bindings, key, mods)
    if sequence_node ~= nil then
      if sequence_node.action ~= nil and not has_sequence_children(sequence_node) then
        return run_action(hollow, sequence_node)
      end
      set_sequence_state(keymap_state, sequence_node, format_chord(key, mods), {})
      return true
    end

    local action = get_binding(keymap_state.bindings, key, mods)
    if action ~= nil then
      return run_action(hollow, action)
    end

    return false
  end)

end

return M
