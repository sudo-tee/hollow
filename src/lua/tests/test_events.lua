package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("events test suite", function()
  local env
  local hollow
  local recorded
  local state

  setup(function()
    env = harness.boot()
    hollow = env.hollow
    recorded = env.recorded
    state = env.state
  end)

  describe("event listeners", function()
    local event_payload

    it("fires once listeners exactly once", function()
      hollow.ui.topbar.configure({})
      hollow.events.once("custom:event", function(payload)
        event_payload = payload
      end)
      hollow.events.emit("custom:event", { value = 42 })
      hollow.events.emit("custom:event", { value = 99 })
      harness.assert_equal(event_payload.value, 42, "once listeners should fire exactly once")
    end)
  end)

  describe("built-in events", function()
    it("cannot be emitted from Lua", function()
      local built_in_error = pcall(function()
        hollow.events.emit("term:foreground_process_changed", {})
      end)
      harness.assert_true(not built_in_error, "built-in events should not be emitted from Lua")
    end)
  end)

  describe("term:title_changed", function()
    local title_event

    it("exposes the previous and updated titles", function()
      hollow.term.set_title("shell", 201)
      hollow.events.once("term:title_changed", function(payload)
        title_event = payload
      end)
      hollow.term.set_title("editor", 201)
      harness.assert_equal(
        title_event.old_title,
        "shell",
        "title_changed should expose the previous title"
      )
      harness.assert_equal(
        title_event.new_title,
        "editor",
        "title_changed should expose the updated title"
      )
      harness.assert_equal(title_event.pane.id, 101, "title_changed should adapt pane snapshots")
    end)
  end)

  describe("term:foreground_process_changed", function()
    local process_event

    it("exposes the previous and updated processes", function()
      hollow.term.set_pane_foreground_process(101, "nvim")
      hollow.events.once("term:foreground_process_changed", function(payload)
        process_event = payload
      end)
      state.get().ui.topbar_cache_dirty = false
      state.get().ui.bottombar_cache_dirty = false
      hollow.term.set_pane_foreground_process(101, "zig build")
      harness.assert_equal(
        process_event.old_process,
        "nvim",
        "foreground_process_changed should expose the previous process"
      )
      harness.assert_equal(
        process_event.new_process,
        "zig build",
        "foreground_process_changed should expose the updated process"
      )
      harness.assert_equal(
        process_event.pane.id,
        101,
        "foreground_process_changed should adapt pane snapshots"
      )
    end)

    it("invalidates bar caches", function()
      harness.assert_equal(
        state.get().ui.topbar_cache_dirty,
        true,
        "foreground_process_changed should invalidate the topbar cache"
      )
      harness.assert_equal(
        state.get().ui.bottombar_cache_dirty,
        true,
        "foreground_process_changed should invalidate the bottombar cache"
      )
    end)
  end)

  describe("term:bell", function()
    local bell_event

    it("fires when emitted by the host", function()
      hollow.events.once("term:bell", function(payload)
        bell_event = payload
      end)
      state.get().ui.topbar_cache_dirty = false
      state.get().ui.bottombar_cache_dirty = false
      hollow._emit_builtin_event("term:bell", { pane_id = 101 })
      harness.assert_true(bell_event ~= nil, "term:bell should fire when emitted by the host")
      harness.assert_equal(
        bell_event.pane.id,
        101,
        "term:bell payload should expose a pane snapshot"
      )
    end)

    it("invalidates bar caches", function()
      harness.assert_equal(
        state.get().ui.topbar_cache_dirty,
        true,
        "term:bell should invalidate the topbar cache"
      )
      harness.assert_equal(
        state.get().ui.bottombar_cache_dirty,
        true,
        "term:bell should invalidate the bottombar cache"
      )
    end)
  end)
end)
