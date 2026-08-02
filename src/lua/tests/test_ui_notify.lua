package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("UI notify test suite", function()
  local env
  local hollow

  setup(function()
    env = harness.boot()
    hollow = env.hollow
  end)

  describe("notify", function()
    it("creates an overlay widget", function()
      local widget = hollow.ui.notify.info("hello", { ttl = 100 })
      harness.assert_true(widget ~= nil, "notify should create an overlay widget")
      harness.assert_equal(hollow.ui.overlay.depth(), 1, "notify should push an overlay widget")
      harness.assert_true(
        hollow.ui._overlay_state() ~= nil,
        "overlay state should serialize active widgets"
      )
    end)

    it("clears notify widgets", function()
      hollow.ui.notify.clear()
      harness.assert_equal(
        hollow.ui.overlay.depth(),
        0,
        "notify.clear should remove notify widgets"
      )
    end)
  end)

  describe("direct overlays", function()
    it("dispatches button callbacks and custom event handlers", function()
      local direct_button_clicked = false
      local direct_overlay_event = false
      local direct_overlay = hollow.ui.overlay.new({
        render = function()
          return hollow.ui.row({
            hollow.ui.button({
              id = "direct-overlay-button",
              text = "Run",
              on_click = function()
                direct_button_clicked = true
              end,
            }),
          })
        end,
        on_event = function(name)
          direct_overlay_event = name == "overlay:click"
        end,
      })
      hollow.ui.overlay.push(direct_overlay)
      hollow.ui._overlay_state()
      hollow._emit_builtin_event("overlay:click", { id = "direct-overlay-button" })
      harness.assert_true(
        direct_button_clicked,
        "ui.button callbacks should work in direct overlays"
      )
      harness.assert_true(
        direct_overlay_event,
        "ui.button dispatch should preserve custom overlay event handlers"
      )
      hollow.ui.overlay.clear()
    end)
  end)
end)
