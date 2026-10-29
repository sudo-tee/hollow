-- Hierarchical components and independently owned, invalidated surface snapshots.
local serialize = require("hollow.ui.layout_serialize")
local shared = require("hollow.ui.shared")
local ui = _G.hollow.ui
local M, Surface = {}, {}
Surface.__index = Surface
local next_id, revision = 0, 0
local shown, active

local function container(kind, children, opts)
  opts = opts or {}
  return {
    kind = kind,
    children = children or {},
    id = opts.id,
    label = opts.label,
    width = opts.width,
    height = opts.height,
    gap = opts.gap,
    padding = opts.padding,
    style = opts.style,
    scroll = opts.scroll,
    on_click = opts.on_click,
  }
end

function M.row(children, opts)
  return container(1, children, opts)
end
function M.column(children, opts)
  return container(0, children, opts)
end
function M.text(text, style)
  return { kind = 2, text = tostring(text or ""), style = style }
end

-- Custom-paint demonstration; not an arbitrary Lua drawing API.
function M.progress(value, opts)
  local node = container(3, {}, opts)
  node.value = value
  return node
end

function M.button(opts)
  opts = opts or {}
  local span = ui.button(opts)
  return M.column({ M.text(span.text, { fg = span.style.fg, bold = span.style.bold }) }, {
    id = opts.id,
    label = span.text,
    style = span.style,
    on_click = not opts.disabled and opts.on_click or nil,
  })
end

function M.new(opts)
  assert(
    type(opts) == "table" and type(opts.render) == "function",
    "layout.new requires render(ctx)"
  )
  next_id = next_id + 1
  return setmetatable({
    id = next_id,
    namespace = "layout:" .. next_id .. ":",
    render = opts.render,
    palette = opts.theme,
    frame = opts.frame,
    dirty = true,
    callbacks = {},
    local_ids = {},
  }, Surface)
end

function Surface:invalidate()
  if not self.destroyed then
    self.dirty = true
  end
end

function Surface:snapshot(ctx)
  assert(not self.destroyed, "layout surface is destroyed")
  ctx = ctx or {}
  local old = self.context or {}
  local palette_generation = shared.palette_generation()
  if self.palette_generation ~= palette_generation then
    self.dirty = true
  end
  for _, key in ipairs({ "width", "height", "cell_w", "cell_h" }) do
    if old[key] ~= ctx[key] then
      self.dirty = true
    end
  end
  if self.dirty then
    local nodes, callbacks, local_ids =
      serialize(self.render(ctx), self.palette or shared.palette("select"), self.namespace)
    revision = revision + 1
    self.nodes, self.callbacks, self.local_ids = nodes, callbacks, local_ids
    self.revision, self.context, self.dirty =
      revision, {
        width = ctx.width,
        height = ctx.height,
        cell_w = ctx.cell_w,
        cell_h = ctx.cell_h,
      }, false
    self.palette_generation = palette_generation
  end
  return self.nodes
end

function Surface:dispatch(id)
  if self.destroyed then
    return
  end
  local callback = self.callbacks[id]
  if callback then
    callback({ id = self.local_ids[id] })
  end
end

function Surface:local_id(id)
  return self.local_ids[id]
end

function Surface:destroy()
  self.destroyed, self.nodes, self.callbacks, self.local_ids = true, nil, {}, {}
  self.render, self.palette, self.frame, self.context = nil, nil, nil, nil
  if shown == self then
    shown = nil
  end
  if active == self then
    active, ui._layout_tree, ui._layout_frame = nil, nil, nil
  end
end

local function publish(surface, owner, ctx)
  local nodes = surface and surface:snapshot(ctx)
  active = surface
  ui._layout_tree = nodes
  ui._layout_revision = surface and surface.revision or 0
  ui._layout_surface_id = surface and surface.id or 0
  ui._layout_owner = owner or 0
  ui._layout_frame = surface and surface.frame
end

-- Standalone mounting convenience; modal surfaces are mounted by the overlay shell.
function Surface:show()
  self:snapshot(self.context)
  if shown and shown ~= self then
    shown:destroy()
  end
  shown = self
  publish(self, 0, self.context)
  return self
end

-- Called before atlas upload. Overlay ownership remains with the existing stack.
function ui._layout_prepare(width, height, cell_w, cell_h)
  local stack = require("hollow.state").get().ui.overlay_stack
  local ctx = { width = width, height = height, cell_w = cell_w, cell_h = cell_h }
  for index = #stack, 1, -1 do
    local widget = stack[index]
    if widget._layout_surface and not widget._layout_surface.destroyed then
      publish(widget._layout_surface, index, ctx)
      return
    end
    if widget._modal then
      publish(nil)
      return
    end
  end
  publish(shown, 0, ctx)
end

-- Compatibility convenience for the initial standalone experiment.
function M.show(root)
  local candidate = M.new({
    render = function()
      return root
    end,
  })
  if shown then
    candidate.id, candidate.namespace = shown.id, shown.namespace
  end
  candidate:snapshot()
  candidate:show()
end

function M.hide()
  if shown then
    shown:destroy()
  end
end

ui._layout_hide = M.hide
function ui._layout_click(id)
  if active then
    -- Accept local IDs for the original standalone convenience API.
    active:dispatch(active.callbacks[id] and id or (active.namespace .. id))
  end
end

function M.demo()
  return require("hollow.ui.layout_demo").open()
end

ui.layout = M
return M
