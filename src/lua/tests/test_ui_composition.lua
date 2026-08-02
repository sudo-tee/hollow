package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("UI composition test suite", function()
  local env
  local hollow

  setup(function()
    env = harness.boot()
    hollow = env.hollow
  end)

  describe("unified composition API", function()
    it("creates explicit row and column nodes", function()
      local sample_row = hollow.ui.row({ "hello", hollow.ui.text(" world", { bold = true }) }, {
        id = "sample-row",
      })
      local sample_column = hollow.ui.column({ sample_row, hollow.ui.divider("#112233") })
      harness.assert_equal(sample_row._type, "row", "ui.row should create an explicit row node")
      harness.assert_equal(
        sample_row.children[1].text,
        "hello",
        "ui.row should normalize inline strings"
      )
      harness.assert_equal(
        sample_row.hoverable,
        true,
        "rows with ids should be hoverable by default"
      )
      harness.assert_equal(
        sample_column._type,
        "column",
        "ui.column should create an explicit column node"
      )
      harness.assert_equal(#sample_column.children, 2, "ui.column should retain its rows")
    end)

    it("does not expose ambiguous tag and rows facades", function()
      harness.assert_true(hollow.ui.tags == nil, "the ambiguous tag facade should not be exposed")
      harness.assert_true(
        hollow.ui.rows == nil,
        "anonymous row-list inference should not be exposed"
      )
    end)
  end)

  describe("ui.keys dispatch", function()
    it("dispatches explicit key handlers", function()
      local enter_called = false
      local escape_called = false
      local k = hollow.ui.keys({
        enter = function()
          enter_called = true
        end,
        escape = function()
          escape_called = true
        end,
      })
      harness.assert_true(k("enter", "") == true, "ui.keys should dispatch enter")
      harness.assert_true(enter_called, "enter handler should fire")
      harness.assert_true(k("escape", "") == true, "ui.keys should dispatch escape")
      harness.assert_true(escape_called, "escape handler should fire")
      harness.assert_true(k("unknown", "") == false, "ui.keys should not dispatch unknown keys")
    end)

    it("dispatches nav keys from list_nav", function()
      local enter_called = false
      local nav = hollow.ui.list_nav(5)
      local k2 = hollow.ui.keys(nav, {
        enter = function()
          enter_called = true
        end,
      })
      harness.assert_true(k2("tab", "") == true, "ui.keys should dispatch tab from nav")
      harness.assert_true(
        k2("arrow_right", "") == true,
        "ui.keys should dispatch arrow_right from nav"
      )
      harness.assert_true(
        k2("arrow_left", "") == true,
        "ui.keys should dispatch arrow_left from nav"
      )
      harness.assert_true(k2("shift_tab", "") == true, "ui.keys should dispatch shift_tab from nav")
      harness.assert_true(k2("enter", "") == true, "ui.keys should dispatch enter from second arg")
      harness.assert_true(k2("unknown", "") == false, "ui.keys should not dispatch unknown")
    end)

    it("dispatches text_input keys and printable input", function()
      local ti_enter = false
      local ti_escape = false
      local ti = hollow.ui.text_input({ initial = "test" })
      local k3 = hollow.ui.keys(ti, {
        enter = function()
          ti_enter = true
        end,
        escape = function()
          ti_escape = true
        end,
      })
      harness.assert_true(
        k3("arrow_left", "") == true,
        "ui.keys should dispatch arrow_left from text_input"
      )
      harness.assert_true(
        k3("arrow_right", "") == true,
        "ui.keys should dispatch arrow_right from text_input"
      )
      harness.assert_true(
        k3("backspace", "") == true,
        "ui.keys should dispatch backspace from text_input"
      )
      harness.assert_true(
        k3("enter", "") == true,
        "ui.keys should dispatch enter from second arg (with text_input)"
      )
      harness.assert_true(ti_enter, "enter handler should fire with text_input")
      harness.assert_true(
        k3("escape", "") == true,
        "ui.keys should dispatch escape from second arg (with text_input)"
      )
      harness.assert_true(ti_escape, "escape handler should fire with text_input")
      harness.assert_true(k3("x", "") == true, "ui.keys should dispatch printable via _else")
    end)
  end)
end)
