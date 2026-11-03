-- GUI panes own layout surfaces; native host owns their final destruction.
local ui = _G.hollow.ui
local host = require("hollow.state").get().host_api
local json = require("hollow.json")
local shared = require("hollow.ui.shared")
local M, instances = {}, {}
local factories = {}
local Pane = {}
Pane.__index = Pane

local function context(self, ctx)
  ctx.state = self.opts.state
  ctx.theme = self.opts.theme or shared.palette("select")
  ctx.hovered_id = self.hovered_id
  return ctx
end

local function focus(self, ctx, focused)
  if self.closed then
    return
  end
  self.context = context(self, ctx)
  self.context.focused = focused
  if self.mounted and self.focused ~= focused then
    self.focused = focused
    self.autofocus_pending = focused and ctx.keyboard_focus == true
    local first = (self.surface.focus_order or {})[1]
    if self.autofocus_pending and first then
      -- Focus immediately for incoming keys, then reconcile with the next
      -- snapshot in case controls changed while this pane was inactive.
      self.surface:focus(first)
    end
    self.surface:invalidate()
    if self.opts.on_focus then
      self.opts.on_focus(self.context, focused)
    end
  end
end

function Pane:invalidate()
  if not self.closed then
    self.surface:invalidate()
    host.invalidate_lua_pane(self.id)
  end
end

function Pane:set_title(title)
  assert(type(title) == "string", "pane title must be a string")
  if not self.closed then
    host.title_lua_pane(self.id, title)
  end
end

function Pane:close()
  if self.closed or self.closing then
    return false
  end
  self.closing = host.close_pane_by_id(self.id)
  return self.closing
end

local function destroy(self)
  if self.closed then
    return
  end
  self.closed, instances[self.id] = true, nil
  local ok, err = true, nil
  if self.mounted then
    if self.focused then
      self.focused, self.context.focused = false, false
      if self.opts.on_focus then
        ok, err = pcall(self.opts.on_focus, self.context, false)
      end
    end
    if self.opts.on_unmount then
      local unmount_ok, unmount_err = pcall(self.opts.on_unmount, self.context)
      if not unmount_ok then
        ok, err = false, unmount_err
      end
    end
  end
  self.surface:destroy()
  self.opts, self.context, self.snapshot_context = nil, nil, nil
  if not ok then
    error(err, 0)
  end
end

local function lifecycle(self, ctx)
  local old = self.snapshot_context
  self.context, self.snapshot_context = ctx, ctx
  if not self.mounted then
    self.mounted = true
    if self.opts.on_mount then
      self.opts.on_mount(ctx)
    end
  elseif
    self.opts.on_resize
    and (
      old.cols ~= ctx.cols
      or old.rows ~= ctx.rows
      or old.width ~= ctx.width
      or old.height ~= ctx.height
    )
  then
    self.opts.on_resize(ctx)
  end
  focus(self, ctx, ctx.focused)
  local nodes = self.surface:snapshot(ctx)
  if self.autofocus_pending then
    self.autofocus_pending = false
    -- Refocus only if the snapshot dropped focus (or had none); keys pressed
    -- since entry may already have moved it.
    local first = (self.surface.focus_order or {})[1]
    if not self.surface.focused and first and self.surface:focus(first) then
      nodes = self.surface:snapshot(ctx)
    end
  end
  return nodes
end

local function snapshot(self, ctx)
  context(self, ctx)
  -- Hook errors render the error row like render errors, never a blank pane.
  local ok, nodes = pcall(lifecycle, self, ctx)
  if ok then
    return nodes
  end
  if tostring(nodes):find("hollow.ui: unknown style token", 1, true) then
    error(nodes, 0)
  end
  -- Serialization failures also replace stale content/callbacks with an error row.
  self.surface.callbacks, self.surface.local_ids = {}, {}
  self.surface.focus_order, self.surface.key_handlers = {}, {}
  return {
    { kind = 0, id = self.surface.namespace .. "error", width = -1, height = -1, children = 1 },
    { kind = 2, fg = ctx.theme.fg, text = "Lua pane error: " .. tostring(nodes) },
  }
end

-- Persist only bounded, plain JSON data, never closures, metatables or state.
local function copy_args(value, seen, depth, budget)
  local kind = type(value)
  if kind == "nil" or kind == "string" or kind == "boolean" then
    return value
  end
  if kind == "number" then
    assert(
      value == value and value > -math.huge and value < math.huge,
      "pane args require finite numbers"
    )
    return value
  end
  assert(kind == "table" and getmetatable(value) == nil, "pane args must be plain JSON data")
  seen, depth, budget = seen or {}, depth or 0, budget or { remaining = 4096 }
  assert(depth < 32 and not seen[value], "pane args are cyclic or too deep")
  seen[value] = true
  local out, strings, numbers, maximum = {}, 0, 0, 0
  for key, item in pairs(value) do
    budget.remaining = budget.remaining - 1
    assert(budget.remaining >= 0, "pane args exceed entry limit")
    if type(key) == "string" then
      strings = strings + 1
    else
      assert(type(key) == "number" and key >= 1 and key % 1 == 0, "invalid pane args key")
      numbers, maximum = numbers + 1, math.max(maximum, key)
    end
    out[key] = copy_args(item, seen, depth + 1, budget)
  end
  assert(numbers == 0 or (strings == 0 and maximum == numbers), "pane args arrays must be dense")
  seen[value] = nil
  return out
end

local function resolve(opts)
  assert(type(opts) == "table", "pane options must be a table")
  local module = opts.module
  assert(
    module == nil or (type(module) == "string" and module ~= "" and not module:find("\0", 1, true)),
    "invalid pane module"
  )
  assert(opts.args == nil or type(opts.args) == "table", "pane args must be a table")
  local args = copy_args(opts.args or {})
  local owned = {}
  if module and opts.render == nil then
    local factory = assert(factories[module], "unknown Lua pane factory: " .. module)
    local result = factory(copy_args(args))
    assert(type(result) == "table", "pane factory must return options")
    for key, value in pairs(result) do
      owned[key] = value
    end
  end
  for key, value in pairs(opts) do
    owned[key] = value
  end
  owned.module, owned.args = module, args
  return owned
end

local function new_instance(opts, floating, placement, name)
  assert(type(opts) == "table" and type(opts.render) == "function", "pane requires render(ctx)")
  local direction = opts.direction or "vertical"
  assert(direction == "vertical" or direction == "horizontal", "invalid pane direction")
  local edge = opts.edge
  assert(
    edge == nil or edge == "left" or edge == "right" or edge == "top" or edge == "bottom",
    "invalid pane edge"
  )
  local ratio = opts.ratio or 0.5
  assert(type(ratio) == "number" and ratio > 0 and ratio < 1, "pane ratio must be in (0, 1)")
  assert(type(host.create_lua_pane) == "function", "Lua panes require GUI host")
  assert(opts.title == nil or type(opts.title) == "string", "pane title must be a string")
  assert(opts.state == nil or type(opts.state) == "table", "pane state must be a table")
  local owned = opts
  owned.state = opts.state or {}
  local self = setmetatable({ opts = owned }, Pane)
  self.surface = ui.layout.new({ render = owned.render, theme = owned.theme })
  local owner = {
    direction = direction,
    ratio = ratio,
    floating = floating,
    _descriptor = json.encode({
      kind = "lua",
      module = owned.module,
      args = owned.args,
      title = owned.title,
      placement = placement or "split",
      edge = owned.edge,
      name = name,
      floating = floating,
      x = owned.x,
      y = owned.y,
      width = owned.width,
      height = owned.height,
      fullscreen = owned.fullscreen,
    }),
    complete = function(_, success)
      if owned.on_complete then
        owned.on_complete({ success = success, pane_id = success and self.id or nil })
      end
    end,
    invalidate = function()
      self.surface:invalidate()
    end,
    snapshot = function(_, ctx)
      return snapshot(self, ctx)
    end,
    destroy = function()
      destroy(self)
    end,
    focus = function(_, ctx, focused)
      focus(self, ctx, focused)
    end,
    geometry = function(_, bounds)
      self.surface.focus_bounds = bounds
    end,
    -- Automation input (send-keys/send-text): terminal bytes decoded to keys.
    input = function(_, text)
      return M._input(self, text)
    end,
    -- True consumes clicks/wheel; for hover it requests a repaint.
    pointer = function(_, kind, id, detail, x, y)
      if self.closed or self.closing then
        return false
      end
      local was_visible = self.surface.focus_visible
      if kind ~= "hover" then
        self.surface:pointer_mode()
      elseif x and y and x >= 0 and y >= 0 then
        -- Anchor resets on each key, so jitter and layout-driven hovers keep
        -- the ring; only deliberate motion hides it.
        self.pointer_x, self.pointer_y = x, y
        self.anchor_x, self.anchor_y = self.anchor_x or x, self.anchor_y or y
        if math.abs(x - self.anchor_x) >= 4 or math.abs(y - self.anchor_y) >= 4 then
          self.surface:pointer_mode()
        end
      end
      if kind ~= "hover" and owned.on_pointer and self.context then
        local event = {
          kind = kind,
          id = id and self.surface:local_id(id) or nil,
          button = kind == "click" and detail or nil,
          delta = kind == "scroll" and detail or nil,
        }
        if owned.on_pointer(event, self.context) == true then
          self:invalidate()
          return true
        end
      end
      if kind == "click" then
        if id and (detail == nil or detail == "left") then
          self.surface:dispatch(id)
          self.surface:pointer_mode()
          self.surface:invalidate()
        end
      elseif kind == "hover" then
        local hovered_id = id and self.surface:local_id(id) or nil
        local changed = self.hovered_id ~= hovered_id or self.surface.focus_visible ~= was_visible
        self.hovered_id = hovered_id
        if self.context then
          self.context.hovered_id = self.hovered_id
        end
        if changed then
          self.surface:invalidate()
        end
        return changed
      end
      return false
    end,
  }
  assert(#owner._descriptor <= 65536, "pane descriptor exceeds 64 KiB")
  return self, owner
end

local function create(opts, floating, placement, name)
  opts = resolve(opts)
  local self, owner = new_instance(opts, floating, placement, name)
  self.id = host.create_lua_pane(owner)
  if not self.id then
    self.surface:destroy()
    return nil
  end
  instances[self.id] = self
  if opts.title then
    self:set_title(opts.title)
  end
  return self
end

function M.register(name, factory)
  assert(
    type(name) == "string" and name ~= "" and not name:find("\0", 1, true),
    "invalid pane factory name"
  )
  assert(type(factory) == "function", "pane factory must be a function")
  factories[name] = factory
end

-- Workspace bootstrap selects a native insertion target without a seed PTY.
function M._create(opts, placement, name)
  return create(opts, opts.floating == true, placement, name)
end

-- The native reload path attaches this new owner to the existing pane ID/tree.
function M._restore(id, descriptor)
  descriptor = json.decode(descriptor)
  local opts = resolve({
    module = descriptor.module,
    args = descriptor.args,
    title = descriptor.title,
    edge = descriptor.edge,
  })
  local self, owner = new_instance(opts, false)
  self.id, instances[id] = id, self
  if opts.title then
    self:set_title(opts.title)
  end
  return owner
end

function M.split(opts)
  return create(opts, false)
end

function M.float(opts)
  return create(opts, true)
end

function M.get(id)
  return instances[id]
end

local function focused_instance()
  if next(instances) == nil then
    return nil
  end
  local id = host.current_pane_id and host.current_pane_id()
  local self = instances[id]
  if not self or self.closed or self.closing or not self.mounted or not self.focused then
    return nil
  end
  return self
end

function M._captures_keys()
  local self = focused_instance()
  return self ~= nil and self.opts.capture_keys == true
end

local ARROWS = {
  arrow_left = "left",
  arrow_right = "right",
  arrow_up = "up",
  arrow_down = "down",
}

local function dispatch(self, key, mods)
  local canonical_mods = _G.hollow.keymap.format_mods(mods)
  self.anchor_x, self.anchor_y = self.pointer_x, self.pointer_y
  local was_visible = self.surface.focus_visible
  local ok, handled = pcall(function()
    if self.surface:focus_key(key, canonical_mods, true) then
      return true
    end
    if self.opts.on_key and self.opts.on_key(key, canonical_mods, self.context) == true then
      return true
    end
    local direction = canonical_mods == "" and ARROWS[key]
    if direction then
      return self.surface:focus_direction(direction)
    end
    return key == "tab"
      and (canonical_mods == "" or canonical_mods == "<S>")
      and self.surface:focus_move(canonical_mods == "<S>" and -1 or 1)
  end)
  if not ok then
    _G.hollow.log("Lua pane key: " .. tostring(handled))
    return false
  end
  if handled then
    self:invalidate()
    return true
  end
  if self.surface.focus_visible ~= was_visible then
    self:invalidate()
  end
  return false
end

-- Called by the shared keymap, under the Lua lock. Overlays and pending global
-- sequences take priority; plain pane keys precede unmodified global bindings.
function M._dispatch_key(key, mods)
  local self = focused_instance()
  if not self then
    return false
  end
  return dispatch(self, key, mods)
end

local SHIFT, CTRL, ALT = 0x01, 0x02, 0x04
local CONTROL_KEYS = {
  ["\r"] = "enter",
  ["\n"] = "enter",
  ["\t"] = "tab",
  ["\8"] = "backspace",
  ["\127"] = "backspace",
  ["\27"] = "escape",
  [" "] = "space",
}
local CSI_KEYS = {
  A = "arrow_up",
  B = "arrow_down",
  C = "arrow_right",
  D = "arrow_left",
  H = "home",
  F = "end",
}
local TILDE_KEYS = {
  ["1"] = "home",
  ["2"] = "insert",
  ["3"] = "delete",
  ["4"] = "end",
  ["5"] = "page_up",
  ["6"] = "page_down",
  ["7"] = "home",
  ["8"] = "end",
}

-- xterm modifier parameter: 1 + shift(1) + alt(2) + ctrl(4).
local function xterm_mods(param)
  local bits = math.max(0, (tonumber(param) or 1) - 1)
  local mods = 0
  if bits % 2 == 1 then
    mods = mods + SHIFT
  end
  if math.floor(bits / 2) % 2 == 1 then
    mods = mods + ALT
  end
  if math.floor(bits / 4) % 2 == 1 then
    mods = mods + CTRL
  end
  return mods
end

local function char_key(char)
  local named = CONTROL_KEYS[char]
  if named then
    return named, 0
  end
  local byte = char:byte()
  if #char == 1 and byte >= 1 and byte <= 26 then
    return string.char(byte + 96), CTRL
  end
  if #char == 1 and (byte < 32 or byte == 127) then
    return nil
  end
  -- Same canonical names as native key events ("A" -> a + Shift, "-" -> minus).
  local ok, key, mods = pcall(_G.hollow.keymap.parse_chord, char)
  if ok and key then
    return key, mods
  end
  return char, 0
end

--- Decode terminal input bytes, as produced by `send-keys`, into key events.
--- Unknown escape sequences are dropped.
---@param text string
---@return { [1]: string, [2]: integer }[]
function M._decode_input(text)
  local events, index = {}, 1
  while index <= #text do
    local params, final, after = text:match("^\27%[([%d;]*)([%a~])()", index)
    if not final then
      final, after = text:match("^\27O([ABCDHF])()", index)
      params = ""
    end
    if final then
      local fields = {}
      for field in params:gmatch("%d+") do
        fields[#fields + 1] = field
      end
      local key, mods
      if final == "~" then
        key, mods = TILDE_KEYS[fields[1] or ""], xterm_mods(fields[2])
      elseif final == "Z" then
        key, mods = "tab", SHIFT
      else
        key, mods = CSI_KEYS[final], xterm_mods(fields[2])
      end
      if key then
        events[#events + 1] = { key, mods }
      end
      index = after
    else
      local alt = 0
      if text:sub(index, index) == "\27" and index < #text then
        alt, index = ALT, index + 1
      end
      local char = text:match("^[%z\1-\127\194-\244][\128-\191]*", index) or text:sub(index, index)
      local key, mods = char_key(char)
      if key then
        events[#events + 1] = { key, mods + alt }
      end
      index = index + #char
    end
  end
  return events
end

function M._input(self, text)
  if self.closed or self.closing or not self.mounted then
    return false
  end
  for _, event in ipairs(M._decode_input(text)) do
    dispatch(self, event[1], event[2])
  end
  return true
end

--- Feed terminal input bytes to a Lua pane as key events, whether or not it
--- has focus. Returns false for unknown or unmounted panes.
function M._send_input(id, text)
  local self = instances[id]
  return self ~= nil and M._input(self, text)
end

ui.pane = M
return M
