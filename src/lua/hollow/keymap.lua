local M = {}
local util = require("hollow.util")

local function invalidate_bars()
  if type(_G.hollow) == "table" and type(_G.hollow.ui) == "table" then
    local topbar = _G.hollow.ui.topbar
    if type(topbar) == "table" and type(topbar.invalidate) == "function" then
      topbar.invalidate()
    end

    local bottombar = _G.hollow.ui.bottombar
    if type(bottombar) == "table" and type(bottombar.invalidate) == "function" then
      bottombar.invalidate()
    end
  end

  local ok_state, state = pcall(function()
    return require("hollow.state").get()
  end)
  if ok_state and type(state) == "table" and type(state.ui) == "table" then
    state.ui.topbar_cache_dirty = true
    state.ui.bottombar_cache_dirty = true
  end
end

local function push_leader_state(active, expires_at_ms)
  if type(_G.host_api) == "table" and type(_G.host_api.set_leader_state) == "function" then
    _G.host_api.set_leader_state(active, expires_at_ms or 0)
  end
end

local MODS_SHIFT = 0x01
local MODS_CTRL = 0x02
local MODS_ALT = 0x04
local MODS_SUPER = 0x08

local function bor(a, b)
  return a + b
end

local function add_mod(mods, flag)
  if mods % (flag * 2) >= flag then
    return mods
  end
  return mods + flag
end

local time_now_ms = function()
  return util.host_now_ms(nil)
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

local SHIFTED_CHAR_KEYS = {
  ["~"] = { key = "backquote", mods = MODS_SHIFT },
  ["!"] = { key = "digit_1", mods = MODS_SHIFT },
  ["@"] = { key = "digit_2", mods = MODS_SHIFT },
  ["#"] = { key = "digit_3", mods = MODS_SHIFT },
  ["$"] = { key = "digit_4", mods = MODS_SHIFT },
  ["%"] = { key = "digit_5", mods = MODS_SHIFT },
  ["^"] = { key = "digit_6", mods = MODS_SHIFT },
  ["&"] = { key = "digit_7", mods = MODS_SHIFT },
  ["*"] = { key = "digit_8", mods = MODS_SHIFT },
  ["("] = { key = "digit_9", mods = MODS_SHIFT },
  [")"] = { key = "digit_0", mods = MODS_SHIFT },
  ["_"] = { key = "minus", mods = MODS_SHIFT },
  ["+"] = { key = "equal", mods = MODS_SHIFT },
  ["{"] = { key = "bracket_left", mods = MODS_SHIFT },
  ["}"] = { key = "bracket_right", mods = MODS_SHIFT },
  ["|"] = { key = "backslash", mods = MODS_SHIFT },
  [":"] = { key = "semicolon", mods = MODS_SHIFT },
  ['"'] = { key = "quote", mods = MODS_SHIFT },
  ["<"] = { key = "comma", mods = MODS_SHIFT },
  [">"] = { key = "period", mods = MODS_SHIFT },
  ["?"] = { key = "slash", mods = MODS_SHIFT },
}

local PLAIN_CHAR_KEYS = {
  ["`"] = { key = "backquote", mods = 0 },
  ["1"] = { key = "digit_1", mods = 0 },
  ["2"] = { key = "digit_2", mods = 0 },
  ["3"] = { key = "digit_3", mods = 0 },
  ["4"] = { key = "digit_4", mods = 0 },
  ["5"] = { key = "digit_5", mods = 0 },
  ["6"] = { key = "digit_6", mods = 0 },
  ["7"] = { key = "digit_7", mods = 0 },
  ["8"] = { key = "digit_8", mods = 0 },
  ["9"] = { key = "digit_9", mods = 0 },
  ["0"] = { key = "digit_0", mods = 0 },
  ["-"] = { key = "minus", mods = 0 },
  ["="] = { key = "equal", mods = 0 },
  ["["] = { key = "bracket_left", mods = 0 },
  ["]"] = { key = "bracket_right", mods = 0 },
  [";"] = { key = "semicolon", mods = 0 },
  ["'"] = { key = "quote", mods = 0 },
  [","] = { key = "comma", mods = 0 },
  ["."] = { key = "period", mods = 0 },
  ["/"] = { key = "slash", mods = 0 },
}

local function canonicalize_plain_char(ch)
  if type(ch) ~= "string" or #ch ~= 1 then
    return nil
  end

  local shifted = SHIFTED_CHAR_KEYS[ch]
  if shifted ~= nil then
    return shifted.key, shifted.mods
  end

  local plain = PLAIN_CHAR_KEYS[ch]
  if plain ~= nil then
    return plain.key, plain.mods
  end

  if ch:match("^%u$") then
    return ch:lower(), MODS_SHIFT
  end

  if ch:match("^%l$") then
    return ch, 0
  end

  return nil
end

local function canonicalize_runtime_key(key, mods)
  local canonical_key = key
  local canonical_mods = mods

  if type(key) == "string" and #key == 1 then
    local mapped_key, mapped_mods = canonicalize_plain_char(key)
    if mapped_key ~= nil then
      canonical_key = mapped_key
      local extra_mods = mapped_mods or 0
      if extra_mods % (MODS_SHIFT * 2) >= MODS_SHIFT then
        canonical_mods = add_mod(canonical_mods, MODS_SHIFT)
      end
      if extra_mods % (MODS_CTRL * 2) >= MODS_CTRL then
        canonical_mods = add_mod(canonical_mods, MODS_CTRL)
      end
      if extra_mods % (MODS_ALT * 2) >= MODS_ALT then
        canonical_mods = add_mod(canonical_mods, MODS_ALT)
      end
      if extra_mods % (MODS_SUPER * 2) >= MODS_SUPER then
        canonical_mods = add_mod(canonical_mods, MODS_SUPER)
      end
    else
      canonical_key = normalize_key_name(key)
    end
  else
    canonical_key = normalize_key_name(key)
  end

  return canonical_key, canonical_mods
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

  local key, mods = canonicalize_plain_char(chord)
  if key ~= nil then
    return key, mods
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

local function normalize_mode(mode)
  if mode == nil then
    return "normal"
  end
  if type(mode) ~= "string" or mode == "" then
    error("keymap mode must be a non-empty string")
  end
  return mode
end

local function get_mode_state(keymap_state, mode, create)
  local name = normalize_mode(mode)
  local state = keymap_state.modes[name]
  if state == nil and create == true then
    state = {
      bindings = {},
      sequence_bindings = {
        action = nil,
        desc = nil,
        children = {},
      },
      leader_bindings = {
        action = nil,
        desc = nil,
        children = {},
      },
    }
    keymap_state.modes[name] = state
  end
  return state, name
end

local function mode_for_lookup(opts)
  if type(opts) ~= "table" then
    return "normal"
  end
  return normalize_mode(opts.mode)
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

local function has_shift(mods)
  return type(mods) == "number" and mods % (MODS_SHIFT * 2) >= MODS_SHIFT
end

local function get_runtime_binding(store, key, mods)
  local binding = get_binding(store, key, mods)
  if binding ~= nil then
    return binding
  end

  if type(key) == "string" and #key == 1 and has_shift(mods) and not key:match("^%a$") then
    return get_binding(store, key, mods - MODS_SHIFT)
  end

  return nil
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
  elseif key == "slash" then
    return "/"
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

  local function lookup(candidate_key, candidate_mods)
    local key_bindings = node.children[candidate_key]
    if not key_bindings then
      return nil
    end
    return key_bindings[candidate_mods]
  end

  local child = lookup(key, mods)
  if child ~= nil then
    return child
  end

  if type(key) == "string" and #key == 1 and has_shift(mods) and not key:match("^%a$") then
    return lookup(key, mods - MODS_SHIFT)
  end

  return nil
end

local function reset_sequence_state(keymap_state)
  keymap_state.sequence_pending_until = nil
  keymap_state.sequence_active_node = nil
  keymap_state.sequence_steps = {}
  keymap_state.sequence_prefix = nil
  push_leader_state(false, 0)
  invalidate_bars()
end

local function set_sequence_state(keymap_state, node, prefix, steps)
  keymap_state.sequence_active_node = node
  keymap_state.sequence_prefix = prefix
  keymap_state.sequence_steps = steps or {}
  keymap_state.sequence_pending_until = time_now_ms() + keymap_state.sequence_timeout_ms
  push_leader_state(true, keymap_state.sequence_pending_until)
  invalidate_bars()
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

  if time_now_ms() > keymap_state.sequence_pending_until then
    reset_sequence_state(keymap_state)
    return false
  end

  return true
end

local function collect_simple_bindings(store, mode, out)
  for key, modmap in pairs(store) do
    for mods, binding in pairs(modmap) do
      out[#out + 1] = {
        action = binding.action,
        chord = format_chord(key, mods),
        desc = binding.desc,
        mode = mode,
      }
    end
  end
end

local function collect_sequence_bindings(node, prefix, mode, out)
  if not node or not node.children then
    return
  end
  for key, modmap in pairs(node.children) do
    for mods, child in pairs(modmap) do
      local chord = prefix .. " " .. format_chord(key, mods)
      if child.action ~= nil then
        out[#out + 1] = {
          action = child.action,
          chord = chord,
          desc = child.desc,
          mode = mode,
        }
      end
      collect_sequence_bindings(child, chord, mode, out)
    end
  end
end

local function find_action_in_store(store, needle, out)
  for key, modmap in pairs(store) do
    for mods, binding in pairs(modmap) do
      if type(binding.action) == "string" and binding.action == needle then
        out[#out + 1] = format_chord(key, mods)
      end
    end
  end
end

local function find_action_in_sequences(node, needle, prefix, out)
  if not node or not node.children then
    return
  end
  for key, modmap in pairs(node.children) do
    for mods, child in pairs(modmap) do
      local chord = prefix .. format_chord(key, mods)
      if type(child.action) == "string" and child.action == needle then
        out[#out + 1] = chord
      end
      find_action_in_sequences(child, needle, chord .. " ", out)
    end
  end
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
    return util.host_now_ms(host_api)
  end

  hollow.keymap.format_mods = format_mods
  hollow.keymap.format_chord = format_chord
  hollow.keymap.parse_chord = parse_chord

  function hollow.keymap.set(chord, action, opts)
    local mode_state = get_mode_state(keymap_state, type(opts) == "table" and opts.mode or nil, true)
    local use_leader, resolved, style = split_leader_chord(chord)
    if use_leader then
      set_leader_binding(mode_state, resolved, style, action, opts)
    else
      local steps = parse_vim_sequence(resolved)
      if steps ~= nil and #steps > 1 then
        set_sequence_binding(mode_state.sequence_bindings, steps, action, opts)
      else
        set_binding(mode_state.bindings, resolved, action, opts)
      end
    end
  end

  function hollow.keymap.del(chord, opts)
    local mode_state = get_mode_state(keymap_state, mode_for_lookup(opts), false)
    if mode_state == nil then
      return false
    end
    local use_leader, resolved, style = split_leader_chord(chord)
    if use_leader then
      return del_leader_binding(mode_state, resolved, style)
    end
    local steps = parse_vim_sequence(resolved)
    if steps ~= nil and #steps > 1 then
      return del_sequence_binding(mode_state.sequence_bindings, steps)
    end
    return del_binding(mode_state.bindings, resolved)
  end

  function hollow.keymap.get(chord, opts)
    local mode_state = get_mode_state(keymap_state, mode_for_lookup(opts), false)
    if mode_state == nil then
      return nil
    end
    local use_leader, resolved = split_leader_chord(chord)
    if use_leader then
      local steps = parse_vim_sequence(resolved)
      if steps == nil then
        return nil
      end
      local binding = get_sequence_binding(mode_state.leader_bindings, steps)
      return binding and binding.action or nil
    end
    local steps = parse_vim_sequence(resolved)
    if steps ~= nil and #steps > 1 then
      local binding = get_sequence_binding(mode_state.sequence_bindings, steps)
      return binding and binding.action or nil
    end
    local key, mods = parse_chord(resolved)
    local binding = get_binding(mode_state.bindings, key, mods)
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

  function hollow.keymap.default(chord, action, opts)
    table.insert(keymap_state.pending_defaults, { chord = chord, action = action, opts = opts })
  end

  function hollow.keymap.apply_defaults()
    local pending = keymap_state.pending_defaults
    keymap_state.pending_defaults = {}

    if state.config.values.load_default_keymaps ~= false then
      for _, entry in ipairs(pending) do
        hollow.keymap.set(entry.chord, entry.action, entry.opts)
      end
    end

    if type(hollow.events) == "table" and type(hollow.events.emit) == "function" then
      hollow.events.emit("config:ready", {})
    end
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
      mode = keymap_state.active_mode,
      prefix = prefix,
      sequence = steps,
      display = display,
      next = next_items,
      next_display = format_next_items(next_items),
      desc = node.desc,
      remaining_ms = math.max(0, keymap_state.sequence_pending_until - time_now_ms()),
      timeout_ms = keymap_state.sequence_timeout_ms,
      complete = node.action ~= nil,
    }
  end

  function hollow.keymap.list_bindings(mode)
    local mode_state = get_mode_state(keymap_state, mode, false)
    if mode_state == nil then
      return {}
    end
    local out = {}
    collect_simple_bindings(mode_state.bindings, mode or "normal", out)
    collect_sequence_bindings(mode_state.sequence_bindings, "", mode or "normal", out)
    collect_sequence_bindings(mode_state.leader_bindings, "<leader>", mode or "normal", out)
    return out
  end

  function hollow.keymap.find_by_action(action_name, mode)
    local mode_state = get_mode_state(keymap_state, mode, false)
    if mode_state == nil then
      return {}
    end
    local out = {}
    find_action_in_store(mode_state.bindings, action_name, out)
    find_action_in_sequences(mode_state.sequence_bindings, action_name, "", out)
    find_action_in_sequences(mode_state.leader_bindings, action_name, "<leader>", out)
    return out
  end

  host_api.on_key(function(key, mods)
    key, mods = canonicalize_runtime_key(key, mods)

    local suppressed = keymap_state.suppress_next_key
    if suppressed ~= nil and suppressed.key == key and suppressed.mods == mods then
      keymap_state.suppress_next_key = nil
      return true
    end
    keymap_state.suppress_next_key = nil

    if hollow.ui.dispatch_overlay_key(key, mods) then
      return true
    end

    local next_mode = type(hollow.copy_mode) == "table"
        and type(hollow.copy_mode.is_active) == "function"
        and hollow.copy_mode.is_active()
        and "copy_mode"
      or "normal"

    if next_mode ~= keymap_state.active_mode then
      reset_sequence_state(keymap_state)
      keymap_state.active_mode = next_mode
    end

    local mode_state = get_mode_state(keymap_state, keymap_state.active_mode, true)

    if is_sequence_active(keymap_state) then
      local node = get_sequence_child(keymap_state.sequence_active_node, key, mods)
      if node ~= nil then
        keymap_state.sequence_active_node = node
        table.insert(keymap_state.sequence_steps, format_chord(key, mods))
        keymap_state.sequence_pending_until = time_now_ms() + keymap_state.sequence_timeout_ms
        push_leader_state(true, keymap_state.sequence_pending_until)
        invalidate_bars()
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
      if mode_state.leader_bindings.action == nil and not has_sequence_children(mode_state.leader_bindings) then
        return keymap_state.active_mode ~= "normal"
      end
      set_sequence_state(keymap_state, mode_state.leader_bindings, "<leader>", {})
      keymap_state.suppress_next_key = { key = key, mods = mods }
      return true
    end

    local sequence_node = get_sequence_child(mode_state.sequence_bindings, key, mods)
    if sequence_node ~= nil then
      if sequence_node.action ~= nil and not has_sequence_children(sequence_node) then
        return run_action(hollow, sequence_node)
      end
      set_sequence_state(keymap_state, sequence_node, format_chord(key, mods), {})
      return true
    end

    local action = get_runtime_binding(mode_state.bindings, key, mods)
    if action ~= nil then
      return run_action(hollow, action)
    end

    if keymap_state.active_mode ~= "normal" then
      return true
    end

    return false
  end)

end

return M
