package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local clay = require("tests.clay_helpers")
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

    it("replaces and clears notifications by ID", function()
      hollow.ui.notify.show("other", { id = "osc99:other" })
      hollow.ui.notify.show("old", { id = "osc99:1" })
      hollow.ui.notify.show("new", { id = "osc99:1" })
      harness.assert_equal(
        hollow.ui.overlay.depth(),
        2,
        "same notification ID should replace existing toast"
      )
      hollow.ui.notify.clear("osc99:1")
      harness.assert_equal(
        hollow.ui.overlay.depth(),
        1,
        "clear(id) should dismiss only matching toast"
      )
      hollow.ui.notify.clear()
    end)

    it("expires lower toasts before snapshotting and keeps draw owner indices stable", function()
      local ui = hollow.ui
      local start = env.recorded.now_ms
      local lower = ui.notify.info("expires first", { ttl = 10 })
      local newer = ui.notify.info("survives", { ttl = 100 })
      ui.input.open({ prompt = "Keep modal" })
      local stack = require("hollow.state").get().ui.overlay_stack
      local modal = stack[3]
      env.recorded.now_ms = start + 11
      ui._layout_prepare(1200, 900, 8, 19)
      assert.equals(2, #stack)
      assert.equals(newer, stack[1])
      assert.equals(modal, stack[2])
      assert.is_true(lower._layout_surface.destroyed)
      local snapshots = ui._overlay_state()
      assert.equals(newer._layout_surface.id, snapshots[1].layout.surface_id)
      assert.equals(modal._layout_surface.id, snapshots[2].layout.surface_id)
      -- Time can advance while drawing. Reading serialized owners must not expire
      -- or reindex this already-prepared frame.
      env.recorded.now_ms = start + 101
      for index = 1, 2 do
        assert.is_true(ui._layout_prepare_overlay(index, 1200, 900, 8, 19))
        assert.equals(index, ui._layout_owner)
        assert.equals(snapshots[index].layout.surface_id, ui._layout_surface_id)
        assert.equals(2, #ui._overlay_state())
      end
      ui._layout_prepare(1200, 900, 8, 19)
      assert.equals(1, #stack)
      assert.equals(modal, stack[1])
      assert.is_true(ui._layout_prepare_overlay(1, 1200, 900, 8, 19))
      assert.equals(modal._layout_surface.id, ui._layout_surface_id)
      ui.overlay.clear()
    end)
  end)

  describe("direct overlays", function()
    it("dispatches button callbacks and custom event handlers", function()
      local direct_button_clicked = false
      local direct_overlay_event = false
      local direct_overlay = hollow.ui.overlay.new({
        render = function()
          return hollow.ui.layout.row({
            hollow.ui.layout.button({
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
      hollow._emit_builtin_event(
        "overlay:click",
        { id = clay.find(hollow.ui, ":direct-overlay-button").id }
      )
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
