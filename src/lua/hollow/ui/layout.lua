-- Surface engine: owned, invalidated Clay snapshots and native host hooks.
-- Node constructors live in `hollow.ui.components`.
local props = require("hollow.ui.components.props")
local serialize = require("hollow.ui.layout.serialize")
local shared = require("hollow.ui.shared")
---@type HollowUi
local ui = _G.hollow.ui
---@type HollowUiLayout
local M = {}
---@class HollowUiLayoutSurfaceImpl: HollowUiLayoutSurface
---@field render? fun(ctx: HollowUiLayoutContext): HollowUiLayoutNode
---@field palette? HollowUiTheme
---@field frame? HollowUiLayoutFrame
---@field dirty boolean
---@field destroyed? boolean
---@field invalidation_revision? integer
---@field palette_generation? integer
---@field revision? integer
---@field nodes? table[]
---@field context? HollowUiLayoutContext
---@field callbacks table<string, fun(event: { id: string })>
---@field local_ids table<string, string>
---@field metrics table<string, { width: number, height: number }>
local Surface = {}
Surface.__index = Surface
local next_id, revision = 0, 0
---@type HollowUiLayoutSurfaceImpl|nil
local shown
---@type HollowUiLayoutSurfaceImpl|nil
local active

---@param opts HollowUiLayoutSurfaceOptions
---@return HollowUiLayoutSurfaceImpl
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
    metrics = {},
  }, Surface)
end

function Surface:invalidate()
  if not self.destroyed then
    self.invalidation_revision = (self.invalidation_revision or 0) + 1
    self.dirty = true
  end
end

---@param ctx HollowUiLayoutContext|nil
---@return table[]
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
    local invalidation_revision = self.invalidation_revision
    ---@type HollowUiLayoutContext
    local render_ctx = {}
    for key, value in pairs(ctx) do
      render_ctx[key] = value
    end
    render_ctx.metrics = self.metrics
    local palette = self.palette or shared.palette("select")
    local previous = props._scope
    props._scope = { theme = palette, ctx = render_ctx }
    local ok, tree = pcall(self.render, render_ctx)
    props._scope = previous
    if not ok then
      error(tree, 0)
    end
    local nodes, callbacks, local_ids, focus_order, key_handlers = serialize(
      tree,
      palette,
      self.namespace,
      render_ctx,
      { id = self.focused, visible = self.focus_visible }
    )
    revision = revision + 1
    self.nodes, self.callbacks, self.local_ids = nodes, callbacks, local_ids
    self.focus_order, self.key_handlers = focus_order, key_handlers
    if self.focused and not self:focus_index(self.focused) then
      self.focused, self.focus_visible = nil, false
    end
    self.revision, self.context, self.dirty =
      revision, {
        width = ctx.width,
        height = ctx.height,
        cell_w = ctx.cell_w,
        cell_h = ctx.cell_h,
      }, self.invalidation_revision ~= invalidation_revision
    self.palette_generation = palette_generation
  end
  return self.nodes
end

---@param id string
local function activate(self, id)
  local callback = self.callbacks[id]
  if callback then
    callback({ id = self.local_ids[id] })
  end
end

-- Pointer activation. A clicked button takes focus without the focus ring, so
-- Tab continues from it; a clicked input is focused for typing.
---@param id string
function Surface:dispatch(id)
  if self.destroyed then
    return
  end
  if self:focus_index(id) then
    local visible = self.key_handlers[id] ~= nil
    if self.focus_visible or visible then
      self:invalidate()
      local host_api = require("hollow.state").get().host_api
      if type(host_api.request_redraw) == "function" then
        host_api.request_redraw()
      end
    end
    self.focused, self.focus_visible = id, visible
  end
  activate(self, id)
end

---@param id string Namespaced id.
---@return integer|nil
function Surface:focus_index(id)
  for index, focusable in ipairs(self.focus_order or {}) do
    if focusable == id then
      return index
    end
  end
end

--- Local id of the keyboard-focused node, if any.
---@return string|nil
function Surface:focused_id()
  return self.focused and self.local_ids[self.focused]
end

--- Focuses a node by local id and shows the focus ring.
---@param id string
---@return boolean
function Surface:focus(id)
  local namespaced = self.local_ids[id] and id or (self.namespace .. id)
  if self.destroyed or not self:focus_index(namespaced) then
    return false
  end
  self.focused, self.focus_visible = namespaced, true
  self:invalidate()
  return true
end

function Surface:blur()
  if self.focused then
    self.focused, self.focus_visible = nil, false
    self:invalidate()
  end
end

--- Moves keyboard focus through focusable nodes in tree order, wrapping.
---@param delta integer 1 for next, -1 for previous.
---@return boolean moved
function Surface:focus_move(delta)
  local order = self.focus_order or {}
  if self.destroyed or #order == 0 then
    return false
  end
  local current = self.focused and self:focus_index(self.focused)
  local index
  if not current then
    index = delta > 0 and 1 or #order
  else
    index = (current - 1 + delta) % #order + 1
  end
  self.focused, self.focus_visible = order[index], true
  self:invalidate()
  return true
end

--- Routes a key to the visibly focused node: its `on_key` first, then
--- Enter/Space activate it.
---@param key string
---@param mods string Canonical modifiers, e.g. "" or "<S>".
---@return boolean consumed
function Surface:focus_key(key, mods)
  local id = self.focus_visible and self.focused
  if self.destroyed or not id then
    return false
  end
  local handler = self.key_handlers and self.key_handlers[id]
  if handler and handler(key, mods) then
    self:invalidate()
    return true
  end
  if (key == "enter" or key == "space") and (mods or "") == "" and self.callbacks[id] then
    activate(self, id)
    self:invalidate()
    return true
  end
  return false
end

---@param id string
---@return string|nil
function Surface:local_id(id)
  return self.local_ids[id]
end

function Surface:destroy()
  self.destroyed, self.nodes, self.callbacks, self.local_ids = true, nil, {}, {}
  self.focus_order, self.key_handlers, self.focused = {}, {}, nil
  self.render, self.palette, self.frame, self.context = nil, nil, nil, nil
  self.metrics = {}
  if shown == self then
    shown = nil
  end
  if active == self then
    active, ui._layout_tree, ui._layout_frame = nil, nil, nil
  end
end

---@param surface HollowUiLayoutSurfaceImpl|nil
---@param owner integer|nil
---@param ctx HollowUiLayoutContext|nil
local function publish(surface, owner, ctx)
  local nodes = surface and surface:snapshot(ctx)
  active = surface
  ui._layout_tree = nodes
  ui._layout_revision = surface and surface.revision or 0
  ui._layout_surface_id = surface and surface.id or 0
  ui._layout_owner = owner or 0
  ui._layout_frame = surface and surface.frame
end

-- Native renderer selects each overlay before reading the existing globals.
-- False means this entry belongs to another toast's combined column.
---@param index integer
---@param width number
---@param height number
---@param cell_w number
---@param cell_h number
---@return boolean
function ui._layout_prepare_overlay(index, width, height, cell_w, cell_h)
  local widget = require("hollow.state").get().ui.overlay_stack[index]
  if
    not widget
    or not widget._layout_surface
    or widget._layout_surface.destroyed
    or (widget._layout_visible and not widget._layout_visible())
  then
    publish(nil)
    return false
  end
  local ctx = { width = width, height = height, cell_w = cell_w, cell_h = cell_h }
  publish(widget._layout_surface, index, ctx)
  return true
end

-- Standalone mounting convenience; modal surfaces are mounted by the overlay shell.
---@return HollowUiLayoutSurfaceImpl
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
---@param width number
---@param height number
---@param cell_w number
---@param cell_h number
function ui._layout_prepare(width, height, cell_w, cell_h)
  if ui._expire_overlays then
    ui._expire_overlays()
  end
  local stack = require("hollow.state").get().ui.overlay_stack
  local ctx = { width = width, height = height, cell_w = cell_w, cell_h = cell_h }
  for _, widget in ipairs(stack) do
    local surface = widget._layout_surface
    widget._layout_snapshot = nil
    if
      surface
      and not surface.destroyed
      and (not widget._layout_visible or widget._layout_visible())
    then
      if widget._layout_live then
        surface:invalidate()
      end
      local nodes = surface:snapshot(ctx)
      widget._layout_snapshot = {
        nodes = nodes,
        revision = surface.revision,
        surface_id = surface.id,
        frame = surface.frame,
      }
    end
  end
  for index = #stack, 1, -1 do
    local widget = stack[index]
    if widget._layout_snapshot then
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

-- Convenience for standalone layouts.
---@param root HollowUiLayoutNode
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
-- Native feedback is delivered under the Lua lock after layout. Only changed
-- viewport dimensions invalidate a snapshot; ordinary scrolling does not.
---@param surface_id integer
---@param id string
---@param width number
---@param height number
function ui._layout_measure(surface_id, id, width, height)
  local surface = active
  if not surface or surface.id ~= surface_id then
    for _, widget in ipairs(require("hollow.state").get().ui.overlay_stack) do
      if widget._layout_surface and widget._layout_surface.id == surface_id then
        surface = widget._layout_surface
        break
      end
    end
  end
  if not surface or surface.destroyed or surface.id ~= surface_id then
    return
  end
  local local_id = surface:local_id(id)
  if not local_id then
    return
  end
  local previous = surface.metrics[local_id]
  if not previous or previous.width ~= width or previous.height ~= height then
    surface.metrics[local_id] = { width = width, height = height }
    surface:invalidate()
  end
end

---@param id string
function ui._layout_click(id)
  if active then
    -- Accept local IDs for the original standalone convenience API.
    active:dispatch(active.callbacks[id] and id or (active.namespace .. id))
  end
end

--- Toggles Clay's built-in inspector over the active layout surface.
---@param enabled boolean
function M.debug(enabled)
  ui._layout_debug = enabled == true
end

---@param enabled boolean
function M.debug_grid(enabled)
  ui._layout_debug_grid = enabled == true
end

-- Inspector panel width in pixels, shared by both inspectors. The host clamps
-- it to the window and writes the applied width back, including after drags.
---@param width number|nil
---@return number|nil
function M.debug_width(width)
  if width == nil then
    return ui._layout_debug_width or 400
  end
  assert(type(width) == "number" and width == width, "inspector width must be a number")
  ui._layout_debug_width = width
end

ui.layout = M
return M
