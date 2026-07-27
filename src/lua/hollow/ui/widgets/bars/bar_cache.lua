local hollow = _G.hollow
local state = require("hollow.state").get()
local ui = hollow.ui
local util = hollow.util
local M = {}
local BAR_CACHE_NO_EXPIRY = false
local CACHE_KEYS = {
  topbar = {
    state = "topbar_cache_state",
    layout = "topbar_cache_layout",
    dirty = "topbar_cache_dirty",
    expires = "topbar_cache_expires_at",
  },
  bottombar = {
    state = "bottombar_cache_state",
    layout = "bottombar_cache_layout",
    dirty = "bottombar_cache_dirty",
    expires = "bottombar_cache_expires_at",
  },
}

function M.sync_host(surface, dirty, expires_at, visible)
  if type(state.host_api) == "table" and type(state.host_api.set_bar_cache_state) == "function" then
    state.host_api.set_bar_cache_state(
      surface,
      dirty,
      type(expires_at) == "number" and math.floor(expires_at) or 0,
      visible
    )
  end
end

function M.invalidate(surface)
  local keys = CACHE_KEYS[surface]
  if keys == nil then
    return false
  end

  local visible = state.ui[keys.state] ~= nil
  state.ui[keys.dirty] = true
  state.ui[keys.state] = nil
  state.ui[keys.layout] = nil
  state.ui[keys.expires] = nil
  ui[keys.dirty] = true
  ui[keys.state] = nil
  ui[keys.layout] = nil
  ui[keys.expires] = nil
  M.sync_host(surface, true, nil, visible)
  return true
end

function M.current_time()
  return util.host_now_ms(state.host_api)
end

function M.is_valid(surface)
  local keys = CACHE_KEYS[surface]
  if keys == nil then
    return false
  end
  if state.ui[keys.dirty] then
    return false
  end
  if state.ui[keys.state] == nil or state.ui[keys.layout] == nil then
    return false
  end

  local expires_at = state.ui[keys.expires]
  return expires_at == BAR_CACHE_NO_EXPIRY
    or (type(expires_at) == "number" and expires_at > M.current_time())
end

function M.set(surface, payload, layout, expires_at)
  local keys = CACHE_KEYS[surface]
  if keys == nil then
    return payload
  end

  local cache_expiry = expires_at == nil and BAR_CACHE_NO_EXPIRY or expires_at
  state.ui[keys.state] = payload
  state.ui[keys.layout] = layout
  state.ui[keys.expires] = cache_expiry
  state.ui[keys.dirty] = false
  ui[keys.state] = payload
  ui[keys.layout] = layout
  ui[keys.expires] = cache_expiry
  ui[keys.dirty] = false
  M.sync_host(surface, false, expires_at, payload ~= nil)
  return payload
end

function M.set_layout(surface, layout)
  local keys = CACHE_KEYS[surface]
  if keys == nil then
    return layout
  end

  state.ui[keys.layout] = layout
  ui[keys.layout] = layout
  if state.ui[keys.state] ~= nil then
    state.ui[keys.dirty] = false
    ui[keys.dirty] = false
    M.sync_host(surface, false, state.ui[keys.expires], true)
  end
  return layout
end

function M.payload(surface)
  return state.ui[CACHE_KEYS[surface].state]
end

function M.layout(surface)
  return state.ui[CACHE_KEYS[surface].layout]
end

function M.min_expiry(current, candidate)
  if candidate == nil then
    return current
  end
  if current == nil or candidate < current then
    return candidate
  end
  return current
end

return M
