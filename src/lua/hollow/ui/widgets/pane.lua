-- GUI panes own layout surfaces; native host owns their final destruction.
local ui = _G.hollow.ui
local host = require("hollow.state").get().host_api
local shared = require("hollow.ui.shared")
local M, instances = {}, {}
local Pane = {}
Pane.__index = Pane

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
  if self.mounted and self.opts.on_unmount then
    ok, err = pcall(self.opts.on_unmount, self.context)
  end
  self.surface:destroy()
  self.opts, self.context = nil, nil
  if not ok then
    error(err, 0)
  end
end

local function snapshot(self, ctx)
  ctx.state = self.opts.state
  ctx.theme = self.opts.theme or shared.palette("select")
  local old = self.context
  self.context = ctx
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
  local ok, nodes = pcall(self.surface.snapshot, self.surface, ctx)
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

local function create(opts, floating)
  assert(type(opts) == "table" and type(opts.render) == "function", "pane requires render(ctx)")
  local direction = opts.direction or "vertical"
  assert(direction == "vertical" or direction == "horizontal", "invalid pane direction")
  local ratio = opts.ratio or 0.5
  assert(type(ratio) == "number" and ratio > 0 and ratio < 1, "pane ratio must be in (0, 1)")
  assert(type(host.create_lua_pane) == "function", "Lua panes require GUI host")
  assert(opts.title == nil or type(opts.title) == "string", "pane title must be a string")
  assert(opts.state == nil or type(opts.state) == "table", "pane state must be a table")
  local owned = {}
  for key, value in pairs(opts) do
    owned[key] = value
  end
  owned.state = opts.state or {}
  local self = setmetatable({ opts = owned }, Pane)
  self.surface = ui.layout.new({ render = owned.render, theme = owned.theme })
  local owner = {
    direction = direction,
    ratio = ratio,
    floating = floating,
    invalidate = function()
      self.surface:invalidate()
    end,
    snapshot = function(_, ctx)
      return snapshot(self, ctx)
    end,
    destroy = function()
      destroy(self)
    end,
  }
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

function M.split(opts)
  return create(opts, false)
end

function M.float(opts)
  return create(opts, true)
end

function M.get(id)
  return instances[id]
end

ui.pane = M
return M
