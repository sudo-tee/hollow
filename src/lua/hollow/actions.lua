local M = {}

function M.setup(hollow, host_api)
  hollow.action = {
    split_vertical = function()
      host_api.split_pane({ direction = "vertical" })
    end,
    split_horizontal = function()
      host_api.split_pane({ direction = "horizontal" })
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
  }
end

return M
