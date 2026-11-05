local shared = require("hollow.ui.shared")
local hollow = _G.hollow
local state = require("hollow.state").get()
local tbl = hollow.tbl
local util = hollow.util
local M = {}
local BAR_EVENT_FIELDS = {
  "on_click",
  "on_mouse_enter",
  "on_mouse_leave",
}

--- Merge `source`'s event callbacks into the handler entry for `id`.
---@param handlers table<string, table<string, function>>
---@param id string|nil
---@param source table
function M.add_handlers(handlers, id, source)
  if type(id) ~= "string" or id == "" then
    return
  end
  local entry = handlers[id] or {}
  for _, field in ipairs(BAR_EVENT_FIELDS) do
    if type(source[field]) == "function" then
      entry[field] = source[field]
    end
  end
  handlers[id] = entry
end

--- Assign auto-ids to handler/hover spans and register events in one walk.
--- Mutates original span style so `serialize_bar_value` sees the id.
---@param next_auto_id fun():string
function M.register(value, handlers, next_auto_id)
  tbl(shared.normalize_inline_nodes(value)):each(function(node)
    if node._type == "group" then
      M.register(node.children, handlers, next_auto_id)
    elseif node._type == "span" and type(node.style) == "table" then
      local style = node.style
      if not (type(style.id) == "string" and style.id ~= "") then
        local has_handler = tbl(BAR_EVENT_FIELDS):some(function(field)
          return type(style[field]) == "function"
        end)
        if has_handler or type(style.hover) == "table" then
          -- The node gets its own style before assigning identity. Configs may
          -- reuse a preset or the same style table on several sibling spans.
          style = util.clone_value(style)
          node.style = style
          style.id = next_auto_id()
        end
      end
      M.add_handlers(handlers, style.id, style)
    end
  end)
end

---@param surface string
---@return string|nil
function M.hovered_key(surface)
  if surface == "topbar" then
    return "topbar_hovered_id"
  end
  if surface == "bottombar" then
    return "bottombar_hovered_id"
  end
  if surface == "sidebar" then
    return "sidebar_hovered_id"
  end
  return nil
end

---@param surface string
---@return string|nil
function M.hovered_shifted_key(surface)
  if surface == "topbar" then
    return "topbar_hovered_shifted"
  end
  if surface == "bottombar" then
    return "bottombar_hovered_shifted"
  end
  if surface == "sidebar" then
    return "sidebar_hovered_shifted"
  end
  return nil
end

---@param surface string|nil
---@param style any
---@return any
function M.resolve_style(surface, style)
  local key = M.hovered_key(surface)
  return key and shared.apply_hover(style, state.ui[key]) or style
end

---@param surface string|nil
---@param value any
---@return any
function M.resolve_value(surface, value)
  if type(value) ~= "table" then
    return value
  end

  local resolved = util.clone_value(value)
  if type(resolved.style) == "table" then
    resolved.style = M.resolve_style(surface, resolved.style)
  end

  if resolved._type == nil then
    tbl(resolved):each(function(item, index)
      resolved[index] = M.resolve_value(surface, item)
    end)
  elseif resolved._type == "group" and type(resolved.children) == "table" then
    resolved.children = tbl(resolved.children)
      :map(function(child)
        return M.resolve_value(surface, child)
      end)
      :get()
  end

  return resolved
end

function M.install(ui, invalidate)
  local function node_id(surface, payload)
    if type(payload) ~= "table" then
      return nil
    end
    if type(payload.id) == "string" and payload.id ~= "" then
      return payload.id
    end
    local node = payload[surface .. "_node"]
    return type(node) == "table" and node.id or nil
  end
  local function call(surface, id, field, payload)
    local handlers = state.ui[surface .. "_handlers"]
    local handler = type(handlers) == "table" and handlers[id]
    if type(handler) == "table" and type(handler[field]) == "function" then
      handler[field](payload)
    end
  end
  function ui.handle_bar_node_event(kind, payload)
    local surface = kind:match("^(%a+bar):")
    if surface ~= "topbar" and surface ~= "bottombar" and surface ~= "sidebar" then
      return
    end
    local key = M.hovered_key(surface)
    local shifted_key = M.hovered_shifted_key(surface)
    if kind == surface .. ":leave" then
      local id = state.ui[key]
      if id then
        call(surface, id, "on_mouse_leave", { id = id })
      end
      state.ui[key] = nil
      state.ui[shifted_key] = false
      if id then
        invalidate(surface)
      end
      return
    end
    local id = node_id(surface, payload)
    if not id then
      return
    end
    if kind == surface .. ":hover" then
      local shifted = payload.shifted == true
      if state.ui[key] ~= id then
        local old = state.ui[key]
        if old then
          call(surface, old, "on_mouse_leave", { id = old })
        end
        state.ui[key] = id
        state.ui[shifted_key] = shifted
        call(surface, id, "on_mouse_enter", payload)
        invalidate(surface)
      elseif state.ui[shifted_key] ~= shifted then
        state.ui[shifted_key] = shifted
        invalidate(surface)
      end
    elseif kind == surface .. ":click" then
      call(surface, id, "on_click", payload)
    end
  end
end
return M
