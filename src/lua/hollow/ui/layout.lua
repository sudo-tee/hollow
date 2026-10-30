-- Hierarchical components and independently owned, invalidated surface snapshots.
local serialize = require("hollow.ui.layout_serialize")
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

---@param kind integer
---@param children table|nil
---@param opts HollowUiLayoutOptions|nil
---@return HollowUiLayoutNode
local function container(kind, children, opts)
  opts = opts or {}
  return {
    kind = kind,
    children = children or {},
    id = opts.id,
    label = opts.label,
    role = opts.role,
    width = opts.width,
    height = opts.height,
    min_width = opts.min_width,
    max_width = opts.max_width,
    min_height = opts.min_height,
    max_height = opts.max_height,
    border_width = opts.border_width,
    gap = opts.gap,
    padding = opts.padding,
    style = opts.style,
    scroll = opts.scroll,
    scroll_x = opts.scroll_x,
    scrollbar_id = opts.scrollbar_id,
    scrollbar_thumb_ratio = opts.scrollbar_thumb_ratio,
    scrollbar_thumb_size = opts.scrollbar_thumb_size,
    scrollbar_track_color = opts.scrollbar_track_color,
    scrollbar_thumb_color = opts.scrollbar_thumb_color,
    reveal = opts.reveal,
    reveal_start = opts.reveal_start,
    measure = opts.measure,
    align_y = opts.align_y,
    on_click = opts.on_click,
  }
end

---@param children table
---@param opts HollowUiLayoutOptions|nil
---@return HollowUiLayoutNode
function M.row(children, opts)
  return container(1, children, opts)
end
---@param children table
---@param opts HollowUiLayoutOptions|nil
---@return HollowUiLayoutNode
function M.column(children, opts)
  return container(0, children, opts)
end
---@param text any
---@param style HollowUiNodeStyle|nil
---@param opts HollowUiLayoutTextOptions|nil
---@return HollowUiLayoutNode
function M.text(text, style, opts)
  return {
    kind = 2,
    text = tostring(text or ""),
    style = style,
    wrap = opts and opts.wrap,
    text_align = opts and opts.text_align,
  }
end

-- Custom-paint demonstration; not an arbitrary Lua drawing API.
---@param value number
---@param opts HollowUiLayoutOptions|nil
---@return HollowUiLayoutNode
function M.progress(value, opts)
  local node = container(3, {}, opts)
  node.value = value
  return node
end

---@param opts HollowUiButtonOptions|nil
---@return HollowUiLayoutNode
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
    local nodes, callbacks, local_ids =
      serialize(self.render(render_ctx), self.palette or shared.palette("select"), self.namespace)
    revision = revision + 1
    self.nodes, self.callbacks, self.local_ids = nodes, callbacks, local_ids
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
function Surface:dispatch(id)
  if self.destroyed then
    return
  end
  local callback = self.callbacks[id]
  if callback then
    callback({ id = self.local_ids[id] })
  end
end

---@param id string
---@return string|nil
function Surface:local_id(id)
  return self.local_ids[id]
end

function Surface:destroy()
  self.destroyed, self.nodes, self.callbacks, self.local_ids = true, nil, {}, {}
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

function M.demo()
  return require("hollow.ui.layout_demo").open()
end

ui.layout = M
return M
