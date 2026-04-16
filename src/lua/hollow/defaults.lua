local M = {}

function M.setup(hollow)
  hollow.keymap.set("<C-S-c>", "copy_selection")
  hollow.keymap.set("<C-S-v>", "paste_clipboard")
  hollow.keymap.set("<S-Insert>", "paste_clipboard")
  hollow.keymap.set("<C-\\>", "split_vertical")
  hollow.keymap.set("<C-S-\\>", "split_horizontal")
  hollow.keymap.set("<C-t>", "new_tab")
  hollow.keymap.set("<C-w>", "close_tab")
  hollow.keymap.set("<C-S-w>", "close_pane")
  hollow.keymap.set("<C-Tab>", "next_tab")
  hollow.keymap.set("<C-S-Tab>", "prev_tab")
  hollow.keymap.set("<C-A-n>", "new_workspace")
  hollow.keymap.set("<C-A-Right>", "next_workspace")
  hollow.keymap.set("<C-A-Left>", "prev_workspace")
  hollow.keymap.set("<C-S-Left>", "focus_pane_left")
  hollow.keymap.set("<C-S-Right>", "focus_pane_right")
  hollow.keymap.set("<C-S-Up>", "focus_pane_up")
  hollow.keymap.set("<C-S-Down>", "focus_pane_down")
  hollow.keymap.set("<C-S-m>", "maximize_pane")
  hollow.keymap.set("<C-A-S-m>", "maximize_pane_background")
  hollow.keymap.set("<C-S-f>", "float_pane")
  hollow.keymap.set("<C-A-S-f>", "tile_pane")
  hollow.keymap.set("<C-A-h>", "move_pane_left")
  hollow.keymap.set("<C-A-l>", "move_pane_right")
  hollow.keymap.set("<C-A-k>", "move_pane_up")
  hollow.keymap.set("<C-A-j>", "move_pane_down")
  hollow.keymap.set("<C-A-S-Left>", "resize_pane_left")
  hollow.keymap.set("<C-A-S-Right>", "resize_pane_right")
  hollow.keymap.set("<C-A-Up>", "resize_pane_up")
  hollow.keymap.set("<C-A-Down>", "resize_pane_down")
  hollow.keymap.set("<A-S-PageUp>", "scrollback_page_up")
  hollow.keymap.set("<A-S-PageDown>", "scrollback_page_down")
  hollow.keymap.set("<C-S-Home>", "scrollback_top")
  hollow.keymap.set("<C-S-End>", "scrollback_bottom")

  local is_mac = hollow.platform.is_macos
  local copy_chord = is_mac and "<D-S-c>" or "<C-S-c>"
  local paste_chord = is_mac and "<D-S-v>" or "<C-S-v>"

  local selection_hint_widget = nil

  hollow.events.on("selection:begin", function()
    if hollow.config.get("selection_hint") == false then
      return
    end
    if selection_hint_widget ~= nil then
      return
    end
    local widget
    widget = hollow.ui.overlay.new({
      align = "top_right",
      backdrop = false,
      render = function()
        ---@type HollowUiTags
        local t = hollow.ui.tags
        local theme = hollow.ui.resolve_theme("overlay")
        return {
          t.overlay_row(
            nil,
            t.text({ fg = theme.panel_border, bold = true }, copy_chord),
            t.text({ fg = theme.muted }, " copy"),
            t.text({ fg = theme.divider }, "   "),
            t.text({ fg = theme.panel_border, bold = true }, paste_chord),
            t.text({ fg = theme.muted }, " paste")
          ),
        }
      end,
      on_event = function(name)
        if name == "selection:cleared" then
          hollow.ui.overlay.remove(widget)
          selection_hint_widget = nil
        end
      end,
      chrome = false,
    })
    selection_hint_widget = widget
    hollow.ui.overlay.push(widget)
  end)
end

return M
