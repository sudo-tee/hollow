package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local clay = require("tests.clay_helpers")
local harness = require("tests.harness")

describe("UI hidden panes test suite", function()
  local env
  local hollow
  local recorded
  local host_api
  local on_key
  local hidden_panes
  local icons
  local hidden_id

  setup(function()
    env = harness.boot()
    hollow = env.hollow
    recorded = env.recorded
    host_api = env.host_api
    on_key = env.get_key_handler()
    hidden_panes = require("hollow.ui.widgets.hidden_panes")
    icons = require("hollow.ui.icons")
    hollow.term.split_pane({
      command = "lazygit",
      command_mode = "spawn",
      on_complete = function(result)
        hidden_id = result.pane_id
      end,
    })
    hollow.term.focus_pane_by_id(101)
  end)

  local function ctx()
    return require("hollow.ui.shared").widget_ctx()
  end

  local function find_topbar_item(id)
    for _, item in ipairs(hollow.ui._topbar_state().items or {}) do
      if item.id == id then
        return item
      end
    end
    return nil
  end

  describe("topbar badge", function()
    it("is absent while every pane is visible", function()
      harness.assert_equal(
        hidden_panes.topbar_button(ctx()),
        false,
        "no badge without hidden panes"
      )
    end)

    it("counts the active tab's hidden panes", function()
      host_api.set_pane_visible(hidden_id, false)
      local button = hidden_panes.topbar_button(ctx())
      harness.assert_true(button ~= false, "badge should appear for hidden panes")
      harness.assert_equal(button.render().text, icons.pane_hidden .. " 1", "badge shows count")
    end)

    it("is part of the configured topbar and can be disabled", function()
      hollow.ui.topbar.configure({ cwd = false, key_legend = false, time = false })
      hollow._emit_builtin_event("term:pane_layout_changed", { pane_id = hidden_id })
      harness.assert_true(
        find_topbar_item("hidden-panes-button") ~= nil,
        "default topbar should include the hidden panes badge"
      )
      hollow.ui.topbar.configure({ hidden_panes = false })
      hollow._emit_builtin_event("term:pane_layout_changed", { pane_id = hidden_id })
      harness.assert_true(
        find_topbar_item("hidden-panes-button") == nil,
        "hidden_panes = false should remove the badge"
      )
      hollow.ui.topbar.configure({ hidden_panes = true })
    end)

    it("opens the navigator on the hidden filter when clicked", function()
      hidden_panes.topbar_button(ctx()).on_click()
      local text = clay.text(hollow.ui)
      harness.assert_true(text:find("Hidden panes", 1, true) ~= nil, "hidden filter active")
      harness.assert_true(text:find("(hidden)", 1, true) ~= nil, "hidden pane tagged")
      harness.assert_true(
        text:find("1 hidden", 1, true) ~= nil,
        "tab row summarizes hidden pane count"
      )
      hollow.ui.overlay.clear()
    end)
  end)

  describe("mux navigator", function()
    it("filters to hidden panes only", function()
      hollow.ui.mux_navigator.open({ filter = "hidden", max_height = 12 })
      local text = clay.text(hollow.ui)
      harness.assert_true(text:find("lazygit", 1, true) ~= nil, "hidden pane listed")
      harness.assert_true(text:find("Pane 1:", 1, true) == nil, "visible pane filtered out")
      hollow.ui.overlay.clear()
    end)

    it("shows then focuses a hidden pane on activation", function()
      recorded.focus_pane_by_id = nil
      hollow.ui.mux_navigator.open({ filter = "hidden", max_height = 12 })
      harness.assert_true(on_key("enter", 0), "workspace row should activate")
      harness.assert_equal(recorded.set_pane_visible.id, hidden_id, "reveals hidden pane")
      harness.assert_equal(recorded.set_pane_visible.visible, true, "reveal shows the pane")
      harness.assert_equal(recorded.focus_pane_by_id, hidden_id, "then focuses it")
    end)

    it("toggles visibility of the selected pane with v", function()
      hollow.term.focus_pane_by_id(101)
      hollow.ui.mux_navigator.open({ max_height = 12 })
      -- Rows: workspace, tab, pane 101, pane 102.
      on_key("arrow_down", 0)
      on_key("arrow_down", 0)
      on_key("arrow_down", 0)
      harness.assert_true(on_key("v", 0), "v should be handled")
      harness.assert_equal(recorded.set_pane_visible.id, hidden_id, "v targets selected pane")
      harness.assert_equal(recorded.set_pane_visible.visible, false, "v hides a visible pane")
      harness.assert_true(on_key("v", 0), "v should be handled again")
      harness.assert_equal(recorded.set_pane_visible.visible, true, "v shows a hidden pane")
      hollow.ui.overlay.clear()
    end)
  end)
end)
