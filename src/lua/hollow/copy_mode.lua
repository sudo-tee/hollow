local M = {}

---@type Hollow
local hollow = _G.hollow
local function runtime_state()
  return require("hollow.state").get()
end

local function host_api()
  return runtime_state().host_api
end

local function copy_state()
  local state = runtime_state()
  state.copy_mode = state.copy_mode
    or {
      active = false,
      query = "",
      selecting = false,
      pending_g = false,
      match_count = 0,
      match_index = nil,
      block = false,
    }
  return state.copy_mode
end

local function close_search_prompt()
  local cs = copy_state()
  if cs.prompt_depth ~= nil then
    while hollow.ui.overlay.depth() > 0 and hollow.ui.overlay.depth() >= cs.prompt_depth do
      hollow.ui.overlay.pop()
    end
    cs.prompt_depth = nil
  end
end

local function sync_active(active)
  local cs = copy_state()
  cs.active = active == true
  if not cs.active then
    cs.selecting = false
    cs.pending_g = false
    close_search_prompt()
  else
    cs.selecting = false
    cs.pending_g = false
  end
end

local function open_search()
  local cs = copy_state()
  close_search_prompt()
  cs.prompt_depth = hollow.ui.overlay.depth() + 1
  hollow.ui.input.open({
    prompt = "Scrollback search",
    default = cs.query,
    width = 48,
    backdrop = false,
    align = "bottom_left",
    on_confirm = function(value)
      cs.query = value or ""
      host_api().copy_mode_search_set_query(cs.query)
    end,
  })
end

function M.enter()
  host_api().copy_mode_enter()
end

function M.exit()
  host_api().copy_mode_exit()
end

function M.is_active()
  return copy_state().active == true
end

function M.setup()
  hollow.events.on("copy_mode:changed", function(payload)
    local cs = copy_state()
    sync_active(payload and payload.active == true)
    cs.query = payload and payload.query or ""
    cs.match_count = payload and payload.match_count or 0
    cs.match_index = payload and payload.match_index or nil
    cs.selecting = payload and payload.selecting == true or false
    cs.block = payload and payload.block == true or false
  end)

  hollow.events.on("copy_mode:search_requested", function()
    if copy_state().active then
      open_search()
    end
  end)
end

return M
