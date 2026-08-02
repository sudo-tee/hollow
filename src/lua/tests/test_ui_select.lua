package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("UI select test suite", function()
  local env
  local hollow
  local on_key

  setup(function()
    env = harness.boot()
    hollow = env.hollow
    on_key = env.get_key_handler()
  end)

  describe("select with search_text", function()
    it("consumes first key and matches using custom search_text", function()
      hollow.ui.select.open({
        items = {
          { name = "hollow", cwd = "/home/francis/Projects/hollow" },
          { name = "alpha", cwd = "/home/francis/Projects/alpha" },
        },
        fuzzy = false,
        label = function(item)
          return item.name .. " " .. item.cwd
        end,
        search_text = function(item)
          return item.name
        end,
      })
      harness.assert_true(
        on_key("h", 0),
        "select should consume first key when search_text is provided"
      )
      local search_text_overlay = hollow.ui._overlay_state()
      harness.assert_true(
        search_text_overlay ~= nil,
        "search_text select overlay should remain open"
      )
      local search_text_overlay_text = ""
      for _, row in ipairs(search_text_overlay[1].rows or {}) do
        for _, segment in ipairs(row.segments or {}) do
          search_text_overlay_text = search_text_overlay_text .. (segment.text or "")
        end
        search_text_overlay_text = search_text_overlay_text .. "\n"
      end
      harness.assert_true(
        search_text_overlay_text:find("hollow", 1, true) ~= nil,
        "select should match using custom search_text"
      )
      hollow.ui.overlay.clear()
    end)
  end)

  describe("scrollable select", function()
    local scroll_select_overlay
    local scroll_select_id
    local scroll_select_counter

    it("serializes a scrollbar", function()
      hollow.ui.select.open({
        items = {
          "item 1",
          "item 2",
          "item 3",
          "item 4",
          "item 5",
          "item 6",
          "item 7",
          "item 8",
        },
        max_height = 8,
      })
      scroll_select_overlay = hollow.ui._overlay_state()
      harness.assert_true(scroll_select_overlay ~= nil, "scrollable select should serialize")
      scroll_select_id = scroll_select_overlay[1].rows[5].scrollbar_id
      harness.assert_true(
        type(scroll_select_id) == "string",
        "select scrollbar should expose an interaction id"
      )
      harness.assert_equal(
        scroll_select_overlay[1].rows[5].scrollbar_thumb_ratio,
        0,
        "select scrollbar thumb should begin at top"
      )
      harness.assert_equal(
        scroll_select_overlay[1].rows[5].scrollbar_thumb_size,
        0.5,
        "select scrollbar thumb should represent visible list fraction"
      )
    end)

    it("moves selection inside the viewport", function()
      harness.assert_true(on_key("arrow_down", 0), "select should move selection before wheel test")
      harness.assert_true(on_key("arrow_down", 0), "select should move selection inside viewport")
    end)

    it("preserves selection while scrolling the viewport", function()
      hollow._emit_builtin_event(
        "overlay:scroll",
        { id = scroll_select_overlay[1].rows[5].id, delta = -1 }
      )
      scroll_select_overlay = hollow.ui._overlay_state()
      scroll_select_counter = scroll_select_overlay[1].rows[1].segments[2].text
      harness.assert_true(
        scroll_select_counter:find("3/8", 1, true) ~= nil,
        "mouse wheel should preserve selection while it remains visible"
      )
      harness.assert_equal(
        scroll_select_overlay[1].rows[5].scrollbar_thumb_ratio,
        0.25,
        "mouse wheel should move select viewport and scrollbar"
      )
    end)

    it("selects the final viewport start on scrollbar drag", function()
      hollow._emit_builtin_event("overlay:scrollbar", { id = scroll_select_id, ratio = 1 })
      scroll_select_overlay = hollow.ui._overlay_state()
      scroll_select_counter = scroll_select_overlay[1].rows[1].segments[2].text
      harness.assert_true(
        scroll_select_counter:find("5/8", 1, true) ~= nil,
        "dragging select scrollbar to bottom should select final viewport start"
      )
      harness.assert_equal(
        scroll_select_overlay[1].rows[5].scrollbar_thumb_ratio,
        1,
        "select scrollbar thumb should reach bottom"
      )
      hollow.ui.overlay.clear()
    end)
  end)

  describe("custom select chrome", function()
    it("serializes chrome bg and alpha", function()
      hollow.ui.select.open({
        items = { "alpha" },
        chrome = { bg = "#112233", alpha = 123 },
        backdrop = false,
      })
      local custom_overlay = hollow.ui._overlay_state()
      harness.assert_true(custom_overlay ~= nil, "custom select overlay should serialize")
      harness.assert_equal(
        custom_overlay[1].chrome.bg,
        "#112233",
        "custom overlay chrome bg should serialize"
      )
      harness.assert_equal(
        custom_overlay[1].chrome.alpha,
        123,
        "custom overlay chrome alpha should serialize"
      )
      hollow.ui.overlay.clear()
    end)
  end)

  describe("select filter cursor", function()
    it("inserts at the caret after moving left", function()
      hollow.ui.select.open({
        items = { "alpha", "beta" },
      })
      harness.assert_true(
        on_key("a", 0),
        "select should consume printable filter input before cursor test"
      )
      harness.assert_true(on_key("arrow_left", 0), "select filter should move cursor left")
      harness.assert_true(on_key("x", 0), "select filter should insert at the moved cursor")
      local select_cursor_overlay = hollow.ui._overlay_state()
      harness.assert_true(
        select_cursor_overlay ~= nil,
        "select overlay should stay open during cursor editing"
      )
      local select_cursor_text = ""
      for _, row in ipairs(select_cursor_overlay[1].rows or {}) do
        for _, segment in ipairs(row.segments or {}) do
          select_cursor_text = select_cursor_text .. (segment.text or "")
        end
        select_cursor_text = select_cursor_text .. "\n"
      end
      harness.assert_true(
        select_cursor_text:find("Filter: xa", 1, true) ~= nil,
        "select filter should insert at the caret after moving left"
      )
      hollow.ui.overlay.clear()
    end)
  end)
end)
