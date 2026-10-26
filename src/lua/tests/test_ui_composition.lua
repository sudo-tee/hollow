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

  describe("exclusive modals", function()
    before_each(function()
      hollow.ui.overlay.clear()
    end)

    after_each(function()
      hollow.ui.overlay.clear()
    end)

    it("ignores new modals until the active modal closes", function()
      local old_key_calls = 0
      local unmounts = 0
      local first = hollow.ui.modal({
        render = function()
          return hollow.ui.row({ "first" })
        end,
        keys = function()
          old_key_calls = old_key_calls + 1
          return true
        end,
      })
      first.widget.on_unmount = function()
        unmounts = unmounts + 1
      end
      local second = hollow.ui.modal({
        render = function()
          return hollow.ui.row({ "second" })
        end,
      })
      harness.assert_equal(second, nil, "blocked modal should return nil")
      harness.assert_equal(hollow.ui.overlay.depth(), 1, "only one modal should remain")
      harness.assert_equal(unmounts, 0, "active modal should not unmount")
      hollow.ui.dispatch_overlay_key("x", 0)
      harness.assert_equal(old_key_calls, 1, "active modal should still receive keys")
      first.close()
      harness.assert_equal(unmounts, 1, "active modal should unmount once when closed")
      local next_modal = hollow.ui.modal({
        render = function()
          return hollow.ui.row({ "next" })
        end,
      })
      harness.assert_true(next_modal ~= nil, "new modal should open after previous closes")
      first.close()
      harness.assert_equal(hollow.ui.overlay.depth(), 1, "stale close must not close new modal")
      next_modal.close()
      harness.assert_equal(hollow.ui.overlay.depth(), 0, "new modal should close normally")
    end)

    it("preserves unfinished input when another picker is requested", function()
      local value
      hollow.ui.input.open({
        prompt = "Rename",
        default = "draft",
        on_confirm = function(result)
          value = result
        end,
      })
      hollow.ui.dispatch_overlay_key("x", 0)
      hollow.ui.workspace.open_switcher()
      harness.assert_equal(hollow.ui.overlay.depth(), 1, "switcher must not replace input")
      hollow.ui.dispatch_overlay_key("enter", 0)
      harness.assert_equal(value, "draftx", "original input and callback must survive")
      harness.assert_equal(hollow.ui.overlay.depth(), 0, "ignored switcher must not open later")
    end)

    it("preserves questions without firing callbacks for ignored dialogs", function()
      local answer
      local ignored_callbacks = 0
      hollow.ui.confirm.open({
        prompt = "Continue?",
        on_confirm = function(result)
          answer = result
        end,
      })
      hollow.ui.input.open({
        prompt = "Ignored",
        on_confirm = function()
          ignored_callbacks = ignored_callbacks + 1
        end,
        on_cancel = function()
          ignored_callbacks = ignored_callbacks + 1
        end,
      })
      hollow.ui.workspace.open_switcher()
      hollow.ui.dispatch_overlay_key("enter", 0)
      harness.assert_equal(answer, true, "original question should receive the answer")
      harness.assert_equal(ignored_callbacks, 0, "ignored dialogs should not fire callbacks")
      harness.assert_equal(hollow.ui.overlay.depth(), 0, "no ignored dialogs should remain")
    end)

    it("preserves notifications and direct overlays with separate layout contexts", function()
      local direct = hollow.ui.overlay.new({
        render = function()
          return hollow.ui.row({ "direct" })
        end,
      })
      hollow.ui.overlay.push(direct)
      hollow.ui.notify.info("notification", { ttl = 0 })
      local active = hollow.ui.modal({
        render = function()
          return hollow.ui.row({ "old" })
        end,
      })
      hollow.ui.modal({
        render = function()
          return hollow.ui.row({ "new" })
        end,
      })
      local overlays = hollow.ui._overlay_state()
      harness.assert_equal(#overlays, 3, "blocked modal should preserve other overlay kinds")
      harness.assert_equal(overlays[1].stack_context, "overlay", "direct overlay context")
      harness.assert_equal(overlays[2].stack_context, "notification", "notification context")
      harness.assert_equal(overlays[3].stack_context, "modal", "modal context")
      hollow.ui.notify.clear()
      harness.assert_equal(hollow.ui.overlay.depth(), 2, "clearing notifications must keep modal")
      active.close()
      harness.assert_equal(hollow.ui.overlay.depth(), 1, "closing modal must keep direct overlay")
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
