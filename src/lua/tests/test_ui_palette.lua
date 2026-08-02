package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("UI palette test suite", function()
  local env
  local hollow

  setup(function()
    env = harness.boot()
    hollow = env.hollow
  end)

  describe("command palette", function()
    local palette_entries = {}
    local selected_palette_item = nil
    local scroll_palette_overlay
    local scroll_palette_id
    local scroll_palette_counter
    local first_palette_item_id

    it("builds a scrollable palette", function()
      for i = 1, 8 do
        palette_entries[#palette_entries + 1] = {
          name = "palette_item_" .. i,
          display_name = "Palette item " .. i,
          mode_label = "",
          desc = "Palette item " .. i,
          category = "general",
          category_label = "General",
          chords = {},
          searchable = "Palette item " .. i,
        }
      end

      hollow.ui.command_palette.open({
        entries = palette_entries,
        max_height = 8,
        on_confirm = function(item)
          selected_palette_item = item.name
        end,
      })
      scroll_palette_overlay = hollow.ui._overlay_state()
      harness.assert_true(
        scroll_palette_overlay ~= nil,
        "scrollable command palette should serialize"
      )
      harness.assert_equal(
        scroll_palette_overlay[1].rows[1].hoverable,
        false,
        "command palette title should not be hoverable"
      )
      harness.assert_equal(
        scroll_palette_overlay[1].rows[3].hoverable,
        false,
        "command palette filter should not be hoverable"
      )
      scroll_palette_id = scroll_palette_overlay[1].rows[5].scrollbar_id
      harness.assert_true(
        type(scroll_palette_overlay[1].rows[5].id) == "string",
        "command palette rows should expose interaction ids"
      )
      harness.assert_true(
        type(scroll_palette_id) == "string",
        "command palette scrollbar should expose an interaction id"
      )
    end)

    it("clamps selection on mouse wheel", function()
      hollow._emit_builtin_event("overlay:scroll", {
        id = scroll_palette_overlay[1].rows[5].id,
        delta = -1,
      })
      scroll_palette_overlay = hollow.ui._overlay_state()
      scroll_palette_counter = scroll_palette_overlay[1].rows[1].segments[2].text
      harness.assert_true(
        scroll_palette_counter:find("1/8", 1, true) ~= nil,
        "mouse wheel should clamp command palette selection when it leaves viewport"
      )
      first_palette_item_id = scroll_palette_overlay[1].rows[5].id
    end)

    it("activates an item on mouse click", function()
      hollow._emit_builtin_event("overlay:click", { id = first_palette_item_id })
      harness.assert_equal(
        selected_palette_item,
        "palette_item_1",
        "mouse click should activate command palette item"
      )
      harness.assert_equal(
        hollow.ui.overlay.depth(),
        0,
        "command palette click should close overlay"
      )
    end)

    it("updates selection on scrollbar drag", function()
      hollow.ui.command_palette.open({ entries = palette_entries, max_height = 8 })
      scroll_palette_overlay = hollow.ui._overlay_state()
      scroll_palette_id = scroll_palette_overlay[1].rows[5].scrollbar_id
      hollow._emit_builtin_event("overlay:scrollbar", { id = scroll_palette_id, ratio = 1 })
      scroll_palette_overlay = hollow.ui._overlay_state()
      scroll_palette_counter = scroll_palette_overlay[1].rows[1].segments[2].text
      harness.assert_true(
        scroll_palette_counter:find("6/8", 1, true) ~= nil,
        "dragging command palette scrollbar should update selection"
      )
      harness.assert_equal(
        scroll_palette_overlay[1].rows[5].scrollbar_thumb_ratio,
        1,
        "command palette scrollbar thumb should reach bottom"
      )
      hollow.ui.overlay.clear()
    end)
  end)
end)
