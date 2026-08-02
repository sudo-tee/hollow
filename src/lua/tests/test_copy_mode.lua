package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("copy mode test suite", function()
  local env
  local hollow
  local recorded
  local state
  local on_key

  setup(function()
    env = harness.boot()
    hollow = env.hollow
    recorded = env.recorded
    state = env.state
    on_key = env.get_key_handler()
  end)

  describe("copy mode setup", function()
    it("registers modal key bindings", function()
      hollow.keymap.set("j", "copy_mode_move_down", { mode = "copy_mode" })
      hollow.keymap.set("gg", "copy_mode_top", { mode = "copy_mode" })
      hollow.keymap.set("G", "copy_mode_bottom", { mode = "copy_mode" })
      hollow.keymap.set("v", "copy_mode_begin_selection", { mode = "copy_mode" })
      hollow.keymap.set("<C-v>", "copy_mode_begin_block_selection", { mode = "copy_mode" })
      hollow.keymap.set("<Space>", "copy_mode_clear_selection", { mode = "copy_mode" })
      hollow.keymap.set("/", "copy_mode_search", { mode = "copy_mode" })
      hollow.keymap.set("n", "copy_mode_search_next", { mode = "copy_mode" })
      hollow.keymap.set("N", "copy_mode_search_prev", { mode = "copy_mode" })
      hollow.keymap.set("y", "copy_mode_copy_selection", { mode = "copy_mode" })
    end)

    it("enters copy mode", function()
      hollow.action.copy_mode()
    end)
  end)

  describe("modal movement", function()
    it("moves down on j", function()
      harness.assert_true(on_key("j", 0), "copy mode should consume modal movement")
      harness.assert_equal(
        recorded.copy_mode.kind,
        "move",
        "copy mode movement should dispatch host move"
      )
      harness.assert_equal(recorded.copy_mode.direction, "down", "copy mode j should move down")
      harness.assert_equal(
        recorded.copy_mode.extend,
        false,
        "copy mode movement should not extend before selection"
      )
    end)
  end)

  describe("gg sequence", function()
    it("waits for a second g before moving", function()
      recorded.copy_mode = nil
      harness.assert_true(on_key("g", 0), "copy mode should consume the first g in gg")
      harness.assert_equal(
        recorded.copy_mode,
        nil,
        "the first g should wait for a second g before moving"
      )
    end)

    it("jumps to the top on gg", function()
      harness.assert_true(on_key("g", 0), "copy mode should jump to the top on gg")
      harness.assert_equal(recorded.copy_mode.kind, "move", "gg should dispatch a host move")
      harness.assert_equal(recorded.copy_mode.direction, "top", "gg should move to the top")
      harness.assert_equal(
        recorded.copy_mode.extend,
        false,
        "gg should not extend before selection"
      )
    end)

    it("jumps to the bottom on G", function()
      harness.assert_true(on_key("g", 1), "copy mode should jump to the bottom on G")
      harness.assert_equal(recorded.copy_mode.kind, "move", "G should dispatch a host move")
      harness.assert_equal(recorded.copy_mode.direction, "bottom", "G should move to the bottom")
      harness.assert_equal(recorded.copy_mode.extend, false, "G should not extend before selection")
    end)
  end)

  describe("selection", function()
    it("begins selection on v", function()
      harness.assert_true(on_key("v", 0), "copy mode should begin selection")
      harness.assert_equal(
        recorded.copy_mode.kind,
        "begin_selection",
        "copy mode v should begin selection"
      )
      harness.assert_true(state.get().copy_mode.selecting, "copy mode should track selection state")
      harness.assert_true(
        not state.get().copy_mode.block,
        "copy mode v should use line selection mode"
      )
    end)

    it("begins block selection on ctrl-v", function()
      harness.assert_true(on_key("v", 2), "copy mode should begin block selection on ctrl-v")
      harness.assert_equal(
        recorded.copy_mode.kind,
        "begin_selection",
        "copy mode ctrl-v should begin selection"
      )
      harness.assert_true(
        recorded.copy_mode.block,
        "copy mode ctrl-v should request block selection"
      )
      harness.assert_true(
        state.get().copy_mode.block,
        "copy mode should track block selection state"
      )
    end)

    it("extends movement while selecting", function()
      harness.assert_true(on_key("j", 0), "copy mode should extend movement while selecting")
      harness.assert_equal(
        recorded.copy_mode.extend,
        true,
        "copy mode movement should extend after selection begins"
      )
    end)

    it("clears selection on space", function()
      harness.assert_true(on_key("space", 0), "copy mode should clear selection")
      harness.assert_equal(
        recorded.copy_mode.kind,
        "clear_selection",
        "copy mode space should clear selection"
      )
      harness.assert_true(
        not state.get().copy_mode.selecting,
        "copy mode clear should clear selection state"
      )
      harness.assert_true(
        not state.get().copy_mode.block,
        "copy mode clear should clear block selection state"
      )
    end)
  end)

  describe("search", function()
    it("opens search on slash", function()
      harness.assert_true(on_key("slash", 0), "copy mode should open search")
      harness.assert_equal(
        recorded.copy_mode.kind,
        "open_search",
        "copy mode slash should request search"
      )
      harness.assert_true(
        hollow.ui.overlay.depth() > 0,
        "copy mode search should open an input overlay"
      )
    end)

    it("confirms search and closes the input overlay", function()
      local overlay_before_confirm = hollow.ui.overlay.depth()
      harness.assert_true(on_key("enter", 0), "search overlay should consume confirm")
      harness.assert_true(
        hollow.ui.overlay.depth() < overlay_before_confirm,
        "confirming search should close the input overlay"
      )
      harness.assert_equal(
        recorded.copy_mode.kind,
        "search_set_query",
        "search confirm should set the host query"
      )
      harness.assert_equal(
        recorded.copy_mode.query,
        "",
        "search confirm should forward the current query"
      )
    end)

    it("jumps to the next match on n", function()
      harness.assert_true(on_key("n", 0), "copy mode should jump to next match")
      harness.assert_equal(
        recorded.copy_mode.kind,
        "search_next",
        "copy mode n should jump to next match"
      )
      harness.assert_equal(
        state.get().copy_mode.match_count,
        3,
        "copy mode should track match counts from host state"
      )
      harness.assert_equal(
        state.get().copy_mode.match_index,
        1,
        "copy mode should track active match index from host state"
      )
    end)

    it("jumps to the previous match on shifted n", function()
      harness.assert_true(on_key("n", 1), "copy mode should jump to previous match on shifted n")
      harness.assert_equal(
        recorded.copy_mode.kind,
        "search_prev",
        "copy mode N should jump to previous match"
      )
      harness.assert_equal(
        state.get().copy_mode.match_index,
        3,
        "copy mode should update active match index on previous search"
      )
    end)
  end)

  describe("copy and exit", function()
    it("copies and exits on y", function()
      harness.assert_true(on_key("y", 0), "copy mode should copy and exit")
      harness.assert_equal(
        recorded.copy_mode.kind,
        "exit",
        "copy mode copy should exit after copying"
      )
      harness.assert_true(
        not state.get().copy_mode.active,
        "copy mode should be inactive after copy+exit"
      )
    end)
  end)
end)
