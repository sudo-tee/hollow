package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("keymap test suite", function()
  local env
  local hollow
  local recorded
  local state
  local on_key
  local mode_hits = {}

  setup(function()
    env = harness.boot()
    hollow = env.hollow
    recorded = env.recorded
    state = env.state
    on_key = env.get_key_handler()
  end)

  describe("key bindings", function()
    it("consumes mapped keys", function()
      hollow.keymap.set("<C-S-t>", "new_tab")
      local key, mods = hollow.keymap.parse_chord("<C-S-t>")
      harness.assert_true(on_key(key, mods), "registered key bindings should consume mapped keys")
    end)

    it("invokes host actions for registered bindings", function()
      harness.assert_equal(
        recorded.new_tab_calls,
        1,
        "registered action bindings should invoke host actions"
      )
    end)

    it("does not overwrite explicit bindings with defaults", function()
      local hits = 0
      hollow.keymap.default("<C-A-Up>", "resize_pane_up")
      hollow.keymap.set("<C-A-Up>", function()
        hits = hits + 1
      end)
      hollow.keymap.apply_defaults()

      local key, mods = hollow.keymap.parse_chord("<C-A-Up>")
      harness.assert_true(on_key(key, mods), "explicit binding should consume the key")
      harness.assert_equal(hits, 1, "defaults should not replace explicit bindings")
    end)
  end)

  describe("mode-aware bindings", function()
    it("registers mode-specific bindings", function()
      hollow.keymap.set("x", function()
        mode_hits[#mode_hits + 1] = "normal"
      end)
      hollow.keymap.set("x", function()
        mode_hits[#mode_hits + 1] = "copy_mode"
      end, { mode = "copy_mode" })
    end)

    it("dispatches normal bindings through the shared keymap", function()
      harness.assert_true(
        on_key("x", 0),
        "normal mode bindings should dispatch through the shared keymap"
      )
      harness.assert_equal(
        mode_hits[#mode_hits],
        "normal",
        "normal mode should prefer the normal binding bucket"
      )
    end)

    it("reads bindings by default mode", function()
      harness.assert_true(
        hollow.keymap.get("x") ~= nil,
        "keymap.get should read normal bindings by default"
      )
    end)

    it("reads mode-specific bindings", function()
      harness.assert_true(
        hollow.keymap.get("x", { mode = "copy_mode" }) ~= nil,
        "keymap.get should read mode-specific bindings"
      )
    end)
  end)

  describe("copy mode", function()
    it("enters copy mode via the copy_mode action", function()
      hollow.action.copy_mode()
      harness.assert_equal(
        recorded.copy_mode.kind,
        "enter",
        "copy_mode action should enter copy mode"
      )
    end)

    it("becomes active after enter", function()
      harness.assert_true(
        state.get().copy_mode.active,
        "copy_mode should become active after enter"
      )
      harness.assert_equal(
        state.get().copy_mode.match_count,
        0,
        "copy mode should initialize match count"
      )
    end)

    it("dispatches mode-specific bindings in copy mode", function()
      harness.assert_true(
        on_key("x", 0),
        "copy mode should dispatch mode-specific bindings through the shared keymap"
      )
      harness.assert_equal(
        mode_hits[#mode_hits],
        "copy_mode",
        "copy mode should prefer the copy_mode binding bucket"
      )
    end)

    it("deletes mode-specific bindings", function()
      harness.assert_true(
        hollow.keymap.del("x", { mode = "copy_mode" }),
        "keymap.del should remove mode-specific bindings"
      )
      harness.assert_true(
        hollow.keymap.get("x", { mode = "copy_mode" }) == nil,
        "deleted mode-specific bindings should not resolve"
      )
    end)
  end)
end)
