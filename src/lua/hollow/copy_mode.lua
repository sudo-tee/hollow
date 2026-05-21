local M = {}

---@type Hollow
local hollow = _G.hollow
---@type HollowUi
local ui = hollow.ui

local function runtime_state()
  return require("hollow.state").get()
end

local function host_api()
  return runtime_state().host_api
end

local function shared()
  return require("hollow.ui.shared")
end

local function theme_api()
  return require("hollow.theme")
end

local function copy_state()
  local state = runtime_state()
  state.copy_mode = state.copy_mode or {
    active = false,
    query = "",
    hud = nil,
    selecting = false,
    pending_g = false,
    match_count = 0,
    match_index = nil,
    block = false,
  }
  return state.copy_mode
end

local function current_theme()
  return theme_api().resolve_widget("select")
end

local function unpack_values(list)
  return unpack(list)
end

local function hint(key, desc, key_style, desc_style)
  return {
    ui.tags.text(key_style, key),
    ui.tags.text(desc_style, " " .. desc),
  }
end

local function hud_widget()
  local cs = copy_state()
  if cs.hud ~= nil then
    return cs.hud
  end

  cs.hud = ui.overlay.new({
    align = "bottom_center",
    width = 58,
    backdrop = false,
    chrome = shared().theme_overlay_chrome(current_theme(), nil, 1),
    render = function()
      local current = copy_state()
      if not current.active then
        return ui.rows()
      end

      local tags = ui.tags
      local theme = current_theme()
      local key_style = { fg = theme.panel_border, bold = true }
      local desc_style = { fg = theme.muted }
      local status = "copy"
      if current.match_count > 0 then
        status = string.format("%s  %d/%d", status, current.match_index or 0, current.match_count)
      elseif current.query ~= "" then
        status = status .. "  0/0"
      end
      if current.selecting then
        status = status .. (current.block and "  blk" or "  sel")
      end

      local rows = {
        tags.overlay_row(
          nil,
          tags.text({ fg = theme.title, bold = true }, status),
          tags.text({ fg = theme.counter }, current.query ~= "" and ("  /" .. current.query) or "")
        ),
        tags.divider({ color = theme.divider }),
      }
      rows[#rows + 1] = tags.overlay_row(
        nil,
        unpack_values(hint("<h/j/k/l>", "move", key_style, desc_style)),
        tags.text({ fg = theme.divider }, "  "),
        unpack_values(hint("<gg/G>", "ends", key_style, desc_style)),
        tags.text({ fg = theme.divider }, "  "),
        unpack_values(hint("<v>", "select", key_style, desc_style)),
        tags.text({ fg = theme.divider }, "  "),
        unpack_values(hint("<C-v>", "block", key_style, desc_style))
      )
      rows[#rows + 1] = tags.overlay_row(
        nil,
        unpack_values(hint("<Space>", "clear", key_style, desc_style)),
        tags.text({ fg = theme.divider }, "  "),
        unpack_values(hint("</>", "search", key_style, desc_style)),
        tags.text({ fg = theme.divider }, "  "),
        unpack_values(hint("<n/N>", "match", key_style, desc_style)),
        tags.text({ fg = theme.divider }, "  "),
        unpack_values(hint("<y>", "copy", key_style, desc_style)),
        tags.text({ fg = theme.divider }, "  "),
        unpack_values(hint("<q>", "exit", key_style, desc_style))
      )
      return ui.rows(rows)
    end,
  })
  return cs.hud
end

local function close_search_prompt()
  local cs = copy_state()
  if cs.prompt_depth ~= nil then
    while ui.overlay.depth() > 0 and ui.overlay.depth() >= cs.prompt_depth do
      ui.overlay.pop()
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
    if cs.hud ~= nil then
      ui.close_overlay_widget(cs.hud)
    end
  else
    cs.selecting = false
    cs.pending_g = false
    if cs.hud ~= nil then
      ui.close_overlay_widget(cs.hud)
    end
    ui.overlay.push(hud_widget())
  end
end

local function move(direction, extend)
  host_api().copy_mode_move(direction, extend == true)
  return true
end

local function open_search()
  local cs = copy_state()
  close_search_prompt()
  cs.prompt_depth = ui.overlay.depth() + 1
  ui.input.open({
    prompt = "Scrollback search",
    default = cs.query,
    width = 48,
    backdrop = false,
    chrome = shared().theme_overlay_chrome(current_theme(), current_theme().accent, 1),
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
