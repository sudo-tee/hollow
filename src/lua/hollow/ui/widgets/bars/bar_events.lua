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
          style.id = next_auto_id()
        end
      end
      if type(style.id) == "string" and style.id ~= "" then
        local entry = handlers[style.id] or {}
        tbl(BAR_EVENT_FIELDS):each(function(field)
          if type(style[field]) == "function" then
            entry[field] = style[field]
          end
        end)
        handlers[style.id] = entry
      end
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
  return nil
end

---@param surface string|nil
---@param style any
---@return boolean
local function is_hovered_bar_style(surface, style)
  if surface ~= "topbar" and surface ~= "bottombar" then
    return false
  end
  if type(style) ~= "table" or type(style.id) ~= "string" or style.id == "" then
    return false
  end

  local hovered_key = M.hovered_key(surface)
  return hovered_key ~= nil and state.ui[hovered_key] == style.id
end

---@param surface string|nil
---@param style any
---@return any
function M.resolve_style(surface, style)
  if type(style) ~= "table" then
    return style
  end

  if not is_hovered_bar_style(surface, style) then
    return style
  end

  local hover = type(style.hover) == "table" and style.hover or nil
  if hover == nil then
    return style
  end

  return shared.merge_style_tables(style, hover)
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

function M.install(ui, active_widget, invalidate)
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
      return true
    end

    local function visit(node)
      if type(node) ~= "table" then
        return false
      end
      if node._type == "group" then
        return tbl(node.children):some(visit)
      end
      if node._type == "bar_custom" and node.id == id and type(node[field]) == "function" then
        node[field](payload)
        return true
      end
      local style = node.style
      if type(style) == "table" and style.id == id and type(style[field]) == "function" then
        style[field](payload)
        return true
      end
      return false
    end

    local widget = active_widget(surface)
    if widget == nil or type(id) ~= "string" or id == "" then
      return false
    end
    return tbl(shared.normalize_bar_items(shared.render_widget(widget))):some(visit)
  end
  function ui.handle_bar_node_event(kind, payload)
    local surface = kind:match("^(%a+bar):")
    if surface ~= "topbar" and surface ~= "bottombar" then
      return
    end
    local key = M.hovered_key(surface)
    if kind == surface .. ":leave" then
      local id = state.ui[key]
      if id then
        call(surface, id, "on_mouse_leave", { id = id })
        state.ui[key] = nil
        invalidate(surface)
      end
      return
    end
    local id = node_id(surface, payload)
    if not id then
      return
    end
    if kind == surface .. ":hover" and state.ui[key] ~= id then
      local old = state.ui[key]
      if old then
        call(surface, old, "on_mouse_leave", { id = old })
      end
      state.ui[key] = id
      call(surface, id, "on_mouse_enter", payload)
      invalidate(surface)
    elseif kind == surface .. ":click" then
      call(surface, id, "on_click", payload)
    end
  end
end
return M
