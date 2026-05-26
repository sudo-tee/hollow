local M = {}

local function copy_mode_state()
  local state = require("hollow.state").get()
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

local function copy_mode_move(direction)
  return function()
    local cs = copy_mode_state()
    _G.host_api.copy_mode_move(direction, cs.selecting == true)
  end
end

function M.setup(hollow, host_api)
  local copy_mode = require("hollow.copy_mode")

  hollow.action = {
    split_vertical = function()
      host_api.split_pane({ direction = "vertical" })
    end,
    split_horizontal = function()
      host_api.split_pane({ direction = "horizontal" })
    end,
    maximize_pane = function()
      host_api.toggle_pane_maximized(nil, false)
    end,
    float_pane = function()
      host_api.set_pane_floating(nil, true)
    end,
    tile_pane = function()
      host_api.set_pane_floating(nil, false)
    end,
    new_tab = function()
      host_api.new_tab({})
    end,
    close_tab = function()
      host_api.close_tab()
    end,
    close_pane = function()
      host_api.close_pane()
    end,
    next_tab = function()
      host_api.next_tab()
    end,
    prev_tab = function()
      host_api.prev_tab()
    end,
    new_workspace = function()
      host_api.new_workspace()
    end,
    workspace_switcher = function()
      hollow.ui.workspace.open_switcher()
    end,
    create_workspace = function()
      hollow.ui.workspace.create()
    end,
    rename_workspace = function()
      hollow.ui.workspace.rename()
    end,
    close_workspace = function()
      hollow.ui.workspace.close()
    end,
    next_workspace = function()
      host_api.next_workspace()
    end,
    prev_workspace = function()
      host_api.prev_workspace()
    end,
    focus_pane_left = function()
      host_api.focus_pane("left")
    end,
    focus_pane_right = function()
      host_api.focus_pane("right")
    end,
    focus_pane_up = function()
      host_api.focus_pane("up")
    end,
    focus_pane_down = function()
      host_api.focus_pane("down")
    end,
    move_pane_left = function()
      host_api.move_pane(nil, "left", 0.08)
    end,
    move_pane_right = function()
      host_api.move_pane(nil, "right", 0.08)
    end,
    move_pane_up = function()
      host_api.move_pane(nil, "up", 0.08)
    end,
    move_pane_down = function()
      host_api.move_pane(nil, "down", 0.08)
    end,
    resize_pane_left = function()
      host_api.resize_pane("vertical", -0.05)
    end,
    resize_pane_right = function()
      host_api.resize_pane("vertical", 0.05)
    end,
    resize_pane_up = function()
      host_api.resize_pane("horizontal", -0.05)
    end,
    resize_pane_down = function()
      host_api.resize_pane("horizontal", 0.05)
    end,
    copy_selection = function()
      host_api.copy_selection()
    end,
    paste_clipboard = function()
      host_api.paste_clipboard()
    end,
    scrollback_line_up = function()
      host_api.scroll_active(-1)
    end,
    scrollback_line_down = function()
      host_api.scroll_active(1)
    end,
    scrollback_page_up = function()
      host_api.scroll_active_page(-1)
    end,
    scrollback_page_down = function()
      host_api.scroll_active_page(1)
    end,
    scrollback_top = function()
      host_api.scroll_active_top()
    end,
    scrollback_bottom = function()
      host_api.scroll_active_bottom()
    end,
    prompt_jump_prev = function()
      host_api.prompt_jump("prev")
    end,
    prompt_jump_next = function()
      host_api.prompt_jump("next")
    end,
    copy_mode = function()
      copy_mode.enter()
    end,
    copy_mode_search = function()
      if copy_mode.is_active() then
        host_api.copy_mode_open_search()
      else
        copy_mode.enter()
        host_api.copy_mode_open_search()
      end
    end,
    copy_mode_exit = function()
      host_api.copy_mode_exit()
    end,
    copy_mode_move_left = copy_mode_move("left"),
    copy_mode_move_down = copy_mode_move("down"),
    copy_mode_move_up = copy_mode_move("up"),
    copy_mode_move_right = copy_mode_move("right"),
    copy_mode_page_up = copy_mode_move("page_up"),
    copy_mode_page_down = copy_mode_move("page_down"),
    copy_mode_line_start = copy_mode_move("line_start"),
    copy_mode_line_end = copy_mode_move("line_end"),
    copy_mode_top = copy_mode_move("top"),
    copy_mode_bottom = copy_mode_move("bottom"),
    copy_mode_begin_selection = function()
      host_api.copy_mode_begin_selection(false)
    end,
    copy_mode_begin_block_selection = function()
      host_api.copy_mode_begin_selection(true)
    end,
    copy_mode_clear_selection = function()
      host_api.copy_mode_clear_selection()
    end,
    copy_mode_copy_selection = function()
      host_api.copy_mode_copy()
      host_api.copy_mode_exit()
    end,
    copy_mode_search_next = function()
      host_api.copy_mode_search_next()
    end,
    copy_mode_search_prev = function()
      host_api.copy_mode_search_prev()
    end,
  }
end

return M
