package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("UI input test suite", function()
  local env
  local hollow
  local on_key

  setup(function()
    env = harness.boot()
    hollow = env.hollow
    on_key = env.get_key_handler()
  end)

  describe("input overlay editing", function()
    it("inserts text at the caret after moving left", function()
      hollow.ui.input.open({
        prompt = "Rename workspace",
        default = "main",
        backdrop = true,
      })
      harness.assert_true(
        on_key("arrow_left", 0),
        "input overlay with backdrop should consume arrow keys"
      )
      harness.assert_true(on_key("x", 0), "input overlay should insert text at the moved cursor")
      local input_overlay = hollow.ui._overlay_state()
      harness.assert_true(input_overlay ~= nil, "input overlay should stay open while editing")
      local input_overlay_text = ""
      for _, row in ipairs(input_overlay[1].rows or {}) do
        for _, segment in ipairs(row.segments or {}) do
          input_overlay_text = input_overlay_text .. (segment.text or "")
        end
        input_overlay_text = input_overlay_text .. "\n"
      end
      harness.assert_true(
        input_overlay_text:find("maixn", 1, true) ~= nil,
        "input overlay should insert at the caret after moving left"
      )
      harness.assert_true(
        on_key("f1", 0),
        "input overlay with backdrop should consume unmatched keys"
      )
      hollow.ui.overlay.clear()
    end)
  end)

  describe("input overlay confirm", function()
    it("confirms and closes the overlay", function()
      local confirm_value = nil
      hollow.ui.input.open({
        prompt = "Enter test",
        default = "world",
        backdrop = true,
        on_confirm = function(value)
          confirm_value = value
        end,
      })
      harness.assert_true(on_key("enter", 0), "input overlay should consume enter")
      harness.assert_equal(confirm_value, "world", "on_confirm should receive the input value")
      harness.assert_equal(hollow.ui.overlay.depth(), 0, "overlay should close after enter")
      hollow.ui.overlay.clear()
    end)
  end)
end)
