package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

local function overlay_text(hollow)
  local lines = {}
  for _, row in ipairs(hollow.ui._overlay_state()[1].rows) do
    local text = ""
    for _, segment in ipairs(row.segments or {}) do
      text = text .. (segment.text or "")
    end
    lines[#lines + 1] = text
  end
  return table.concat(lines, "\n")
end

local function bell_colors(hollow)
  local colors = {}
  for _, row in ipairs(hollow.ui._overlay_state()[1].rows) do
    for _, segment in ipairs(row.segments or {}) do
      if (segment.text or ""):find("󰂚", 1, true) then
        colors[#colors + 1] = segment.fg
      end
    end
  end
  return colors
end

describe("program status in navigation overlays", function()
  local env, hollow, tree, working, blocked, failed

  before_each(function()
    env = harness.boot()
    hollow = env.hollow
    working = { { state = "working", progress = 25 } }
    blocked = { { state = "blocked", kind = "permission", attention = true } }
    failed = { { state = "error", attention = true } }
    local function pane(id, status)
      return { id = id, title = "shell", cwd = "/tmp/project", program_status = status }
    end
    tree = {
      {
        id = 41,
        index = 1,
        name = "main",
        is_active = true,
        tabs = {
          { id = 11, index = 1, title = "build", panes = { pane(101, working) } },
          {
            id = 12,
            index = 2,
            title = "tests",
            panes = { pane(102, blocked), pane(103, failed) },
          },
        },
      },
    }
    hollow.term.mux_tree = function()
      return tree
    end
  end)

  after_each(function()
    hollow.ui.overlay.clear()
  end)

  it("colors pane bells by unread status", function()
    local levels = require("hollow.theme").resolve_widget("select").notify_levels
    hollow.ui.mux_navigator.open({ max_height = 20 })
    assert.same({ levels.warn, levels.error }, bell_colors(hollow))
    failed[1].attention = false
    tree[1].tabs[2].panes[2].has_bell = true
    assert.same({ levels.warn, levels.warn }, bell_colors(hollow))
  end)

  it("refreshes aggregate workspace bell color without reopening", function()
    local levels = require("hollow.theme").resolve_widget("select").notify_levels
    hollow.ui.workspace.open_switcher()
    assert.same({ levels.error }, bell_colors(hollow))
    failed[1].attention = false
    assert.same({ levels.warn }, bell_colors(hollow))
    blocked[1].attention = false
    assert.same({}, bell_colors(hollow))
  end)

  it("uses highest unfocused attention severity for the topbar bell", function()
    local levels = require("hollow.theme").resolve_widget("select").notify_levels
    local button = require("hollow.ui.widgets.attention").topbar_button()
    assert.equals(levels.error, button.render().style.fg)
    tree[1].tabs[2].panes[2].is_focused = true
    assert.equals(levels.warn, button.render().style.fg)
    blocked[1].attention = false
    assert.is_nil(button.render())
    tree[1].tabs[2].panes[1].has_bell = true
    assert.equals(levels.warn, button.render().style.fg)
  end)

  it("shows pane badges and aggregate tab/workspace badges, including collapsed rows", function()
    hollow.ui.mux_navigator.open({ max_height = 20 })
    local text = overlay_text(hollow)
    assert.is_truthy(text:find("main [error]", 1, true))
    assert.is_truthy(text:find("Tab 1 [working 25%] : build", 1, true))
    assert.is_truthy(text:find("Tab 2 [error] : tests", 1, true))
    assert.is_truthy(text:find("Pane 1 [permission] : shell", 1, true))
    assert.is_truthy(text:find("Pane 2 [error] : shell", 1, true))
    env.get_key_handler()("h", 0)
    text = overlay_text(hollow)
    assert.is_truthy(text:find("main [error]", 1, true))
    assert.is_nil(text:find("Tab 1", 1, true))
  end)

  it("refreshes navigator progress and clears without reopening or resetting search", function()
    hollow.ui.mux_navigator.open({ query = "main", max_height = 20 })
    overlay_text(hollow)
    working[1].progress = 80
    tree[1].tabs[2].panes[1].program_status = {}
    tree[1].tabs[2].panes[2].program_status = {}
    hollow._emit_builtin_event("term:program_status_changed", { pane_id = 101 })
    local text = overlay_text(hollow)
    assert.is_truthy(text:find("main [working 80%]", 1, true))
    assert.is_nil(text:find("[error]", 1, true))
    assert.is_nil(text:find("[permission]", 1, true))
    assert.is_truthy(text:find("/ main", 1, true))
    assert.equals(1, hollow.ui.overlay.depth())
  end)

  it("aggregates workspace status from inactive tabs without changing bell ordering", function()
    tree[1].tabs[2].panes[1].has_bell = true
    hollow.ui.workspace.configure({
      known_workspaces = function()
        return { "known" }
      end,
    })
    local items = hollow.ui.workspace.items()
    assert.equals("[error] ", items[1].program_status_badge)
    assert.is_true(items[1].has_bell)
    assert.is_nil(items[2].program_status_badge)
    hollow.ui.workspace.open_switcher()
    local text = overlay_text(hollow)
    assert.is_truthy(text:find("[error]", 1, true))
    assert.is_truthy(text:find("󰂚", 1, true))
  end)

  it("refreshes open switcher status without rediscovery and preserves filter", function()
    local discoveries = 0
    hollow.ui.workspace.configure({
      cache_ttl_ms = 0,
      known_workspaces = function()
        discoveries = discoveries + 1
        return { "known" }
      end,
    })
    hollow.ui.workspace.open_switcher()
    overlay_text(hollow)
    local initial_discoveries = discoveries
    env.get_key_handler()("m", 0)
    tree[1].tabs[2].panes[1].program_status = {}
    tree[1].tabs[2].panes[2].program_status = {}
    working[1].progress = 90
    hollow._emit_builtin_event("term:program_status_changed", { pane_id = 101 })
    local text = overlay_text(hollow)
    assert.is_truthy(text:find("[working 90%]", 1, true))
    assert.is_nil(text:find("[error]", 1, true))
    assert.is_truthy(text:find("Filter: m", 1, true))
    assert.is_nil(text:find("known", 1, true))
    tree[1].tabs[1].panes[1].program_status = {}
    hollow._emit_builtin_event("term:program_status_changed", { pane_id = 101 })
    assert.is_nil(overlay_text(hollow):find("[working", 1, true))
    assert.equals(initial_discoveries, discoveries)
    assert.equals(1, hollow.ui.overlay.depth())
  end)

  it("passes live badges to custom workspace formatters", function()
    local seen
    hollow.ui.workspace.open_switcher({
      format_item = function(item)
        seen = item.program_status_badge
        return item.name .. " " .. (seen or "")
      end,
    })
    overlay_text(hollow)
    assert.equals("[error] ", seen)
    tree[1].tabs[2].panes[2].program_status = {}
    overlay_text(hollow)
    assert.equals("[permission] ", seen)
  end)

  it(
    "acknowledges picker bells without losing badges, preserves real bells, and re-arms",
    function()
      hollow.ui.mux_navigator.open({ max_height = 20 })
      assert.is_truthy(overlay_text(hollow):find("󰂚 Pane 1 [permission]", 1, true))
      blocked[1].attention = false
      failed[1].attention = false
      hollow._emit_builtin_event("term:program_status_changed", { pane_id = 102 })
      local text = overlay_text(hollow)
      assert.is_nil(text:find("󰂚", 1, true))
      assert.is_truthy(text:find("○ Pane 1 [permission]", 1, true))
      assert.is_truthy(text:find("○ Pane 2 [error]", 1, true))
      assert.is_truthy(text:find("[permission]", 1, true))
      assert.is_truthy(text:find("[error]", 1, true))
      hollow.ui.overlay.clear()
      hollow.ui.workspace.open_switcher()
      text = overlay_text(hollow)
      assert.is_nil(text:find("󰂚", 1, true))
      assert.is_truthy(text:find("[error]", 1, true))
      blocked[1].attention = true
      hollow._emit_builtin_event("term:program_status_changed", { pane_id = 102 })
      assert.is_truthy(overlay_text(hollow):find("󰂚", 1, true))
      hollow.ui.overlay.clear()
      blocked[1].attention = false
      tree[1].tabs[2].panes[1].has_bell = true
      hollow.ui.workspace.open_switcher()
      assert.is_truthy(overlay_text(hollow):find("󰂚", 1, true))
    end
  )

  it("reuses one existing topbar bell and its filter for OSC and status attention", function()
    tree[1].is_active = false
    tree[2] = { id = 42, index = 2, name = "other", is_active = true, tabs = {} }
    local button = require("hollow.ui.widgets.attention").topbar_button()
    assert.equals("attention-button", button.id)
    assert.equals("󰂚 ", button.render().text)
    tree[1].tabs[2].panes[1].has_bell = true
    assert.equals("󰂚 ", button.render().text) -- Both sources still render one icon.
    button.on_click()
    local text = overlay_text(hollow)
    assert.is_truthy(text:find("[permission]", 1, true))
    assert.is_truthy(text:find("[error]", 1, true))
    assert.is_nil(text:find("[working", 1, true))
    hollow.ui.overlay.clear()
    blocked[1].attention = false
    failed[1].attention = false
    assert.equals("󰂚 ", button.render().text) -- OSC bell remains independently pending.
    tree[1].tabs[2].panes[1].has_bell = false
    assert.is_nil(button.render())
    assert.equals("[error] ", require("hollow.program_status").workspace_badge(tree[1]))
    failed[1].attention = true
    assert.equals("󰂚 ", button.render().text)
    for _, span in ipairs(hollow.ui.workspace.topbar_button()) do
      assert.is_nil((span.text or ""):find("󰂚", 1, true))
    end
  end)

  it("groups OSC bells and unread status together in workspace ordering", function()
    tree[2] = {
      id = 42,
      index = 2,
      name = "other",
      is_active = false,
      tabs = { { id = 13, panes = { { id = 104, cwd = "/tmp/other" } } } },
    }
    assert.equals(41, hollow.ui.workspace.items()[1].workspace_id)
    tree[2].tabs[1].panes[1].has_bell = true
    assert.equals(42, hollow.ui.workspace.items()[1].workspace_id)
    blocked[1].attention = false
    failed[1].attention = false
    assert.equals(42, hollow.ui.workspace.items()[1].workspace_id)
  end)

  it("keeps inactive workspace badges live in both pickers through real Lua snapshots", function()
    -- Do not mock mux_tree: exercise workspace -> tab -> pane snapshots.
    local host = _G.host_api
    host.split_pane({}) -- Allocate the background pane in the host fixture.
    host.current_pane_id = function()
      return 101
    end
    host.current_tab_id = function()
      return 11
    end
    host.pane_is_focused = function(id)
      return id == 101
    end
    host.get_workspace_count = function()
      return 2
    end
    host.get_workspace_id = function(index)
      return 41 + index
    end
    host.get_workspace_name = function(index)
      return index == 0 and "main" or "background"
    end
    host.get_workspace_tab_count = function()
      return 1
    end
    host.get_workspace_tab_id_at = function(index)
      return 11 + index
    end
    host.get_tab_pane_count = function()
      return 1
    end
    host.get_tab_pane_id_at = function(tab)
      return tab == 11 and 101 or 102
    end
    host.get_tab_active_pane_id = host.get_tab_pane_id_at
    host.pane_exists = function()
      return true
    end
    host.get_pane_program_status = function(id)
      return id == 102 and blocked or {}
    end
    -- Reload term API to remove the per-test mux_tree stub.
    require("hollow.term").setup(hollow, host)
    local snapshots = hollow.term.mux_tree()
    assert.is_false(snapshots[2].is_active)
    assert.equals("blocked", snapshots[2].tabs[1].panes[1].program_status[1].state)
    hollow.ui.mux_navigator.open({ max_height = 20 })
    assert.is_truthy(overlay_text(hollow):find("background [permission]", 1, true))
    assert.is_truthy(overlay_text(hollow):find("󰂚 Pane 1 [permission]", 1, true))
    blocked[1] = { state = "working", progress = 80 }
    hollow._emit_builtin_event("term:program_status_changed", { pane_id = 102 })
    assert.is_truthy(overlay_text(hollow):find("background [working 80%]", 1, true))
    assert.is_nil(overlay_text(hollow):find("󰂚 Pane 1 [working", 1, true))
    hollow.ui.overlay.clear()
    hollow.ui.workspace.open_switcher()
    assert.is_truthy(overlay_text(hollow):find("[working 80%]", 1, true))
    blocked[1] = { state = "blocked", kind = "auth", attention = true }
    hollow._emit_builtin_event("term:program_status_changed", { pane_id = 102 })
    assert.is_truthy(overlay_text(hollow):find("[auth]", 1, true))
    assert.is_truthy(overlay_text(hollow):find("󰂚", 1, true))
    local items = hollow.ui.workspace.items()
    for _, item in ipairs(items) do
      if item.workspace_id == 42 then
        assert.is_true(item.program_status_attention)
        assert.is_false(item.has_bell)
      end
    end
    blocked[1] = nil
    hollow._emit_builtin_event("term:program_status_changed", { pane_id = 102 })
    assert.is_nil(overlay_text(hollow):find("[auth]", 1, true))
    assert.is_nil(overlay_text(hollow):find("󰂚", 1, true))
  end)
end)
