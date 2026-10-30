package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("Clay mux navigator", function()
  local env, ui, hollow
  before_each(function()
    env = harness.boot()
    hollow, ui = env.hollow, env.hollow.ui
  end)

  local function tree()
    ui._layout_prepare(800, 600, 8, 19)
    return ui._layout_tree
  end

  local function find(suffix)
    for _, node in ipairs(tree()) do
      if node.id and node.id:sub(-#suffix) == suffix then
        return node
      end
    end
  end

  local function text()
    local parts = {}
    for _, node in ipairs(tree()) do
      if node.kind == 2 then
        parts[#parts + 1] = node.text
      end
    end
    return table.concat(parts, "|")
  end

  it("reuses idle snapshots and coalesces event bursts", function()
    local original, calls = hollow.term.mux_tree, 0
    hollow.term.mux_tree = function()
      calls = calls + 1
      return original()
    end
    ui.mux_navigator.open()
    local first = tree()
    local initial = calls
    assert.equals(first, tree())
    assert.equals(initial, calls)
    hollow._emit_builtin_event("term:title_changed", { pane_id = 101 })
    hollow._emit_builtin_event("term:cwd_changed", { pane_id = 101 })
    assert.equals(initial, calls)
    tree()
    assert.equals(initial + 1, calls)
    ui.mux_navigator.close()
  end)

  it("uses Clay after close and reopen", function()
    ui.mux_navigator.open()
    assert.is_true(ui._overlay_state()[1].clay)
    assert.equals("Mux Navigator", find(":dialog").label)
    assert.is_not_nil(find(":mux:viewport"))
    ui.mux_navigator.close()
    ui.mux_navigator.open()
    assert.is_true(ui._overlay_state()[1].clay)
  end)

  it("collapses groups and restores stable identities, then focuses a pane", function()
    ui.mux_navigator.open()
    local pane = find(":mux-navigator:item:pane:101")
    assert.is_not_nil(pane)
    ui.dispatch_overlay_key("space", 0)
    assert.is_nil(find(":mux-navigator:item:pane:101"))
    ui.dispatch_overlay_key("space", 0)
    assert.equals(pane.id, find(":mux-navigator:item:pane:101").id)
    ui.dispatch_widget_event("overlay:click", { id = pane.id, index = 1 })
    assert.equals(101, env.recorded.focus_pane_by_id)
    assert.equals(0, #require("hollow.state").get().ui.overlay_stack)
  end)

  it("supports search, filter shortcuts and escape cancellation", function()
    ui.mux_navigator.open()
    ui.dispatch_overlay_key("slash", 0)
    for _, key in ipairs({ "1", "0", "1" }) do
      ui.dispatch_overlay_key(key, 0)
    end
    assert.is_truthy(text():find("Pane 1", 1, true))
    ui.dispatch_overlay_key("escape", 0)
    assert.is_truthy(text():find("search panes", 1, true))
    ui.dispatch_overlay_key("f", 0)
    assert.is_truthy(text():find("Pane attention", 1, true))
    ui.dispatch_overlay_key("escape", 0)
    assert.equals(0, #require("hollow.state").get().ui.overlay_stack)
  end)

  it("updates attention markers from fresh mux snapshots", function()
    env.host_api.set_pane_bell(101, false)
    ui.mux_navigator.open()
    local before = text()
    env.host_api.set_pane_bell(101, true)
    hollow._emit_builtin_event("term:bell", { pane_id = 101 })
    local after = text()
    assert.not_equals(before, after)
    assert.is_truthy(after:find(require("hollow.ui.icons").bell, 1, true))
    env.host_api.set_pane_bell(101, false)
  end)

  it("refreshes live pane state and bounds large trees with measured scrolling", function()
    local original = hollow.term.mux_tree
    local base = original()
    local pane = base[1].tabs[1].panes[1]
    local panes = {}
    for i = 1, 1100 do
      local copy = {}
      for k, v in pairs(pane) do
        copy[k] = v
      end
      copy.id, copy.title = i, "pane " .. i
      panes[i] = copy
    end
    base[1].tabs[1].panes = panes
    hollow.term.mux_tree = function()
      return base
    end
    ui.mux_navigator.open()
    assert.is_true(#tree() <= 512)
    local view = find(":mux:viewport")
    ui._layout_measure(ui._layout_surface_id, view.id, 400, 4 * 23)
    view = find(":mux:viewport")
    assert.is_string(view.scrollbar_id)
    assert.is_true(view.scrollbar_thumb_size < 0.01)
    ui.dispatch_overlay_key("page_down", 0)
    assert.is_truthy(find(":mux:viewport").reveal:find("pane:3", 1, true))
    ui.dispatch_overlay_key("home", 0)
    find(":mux:viewport")
    ui.dispatch_widget_event("overlay:scroll", { delta = -1 })
    assert.is_true(find(":mux:viewport").reveal_start)
    ui.dispatch_widget_event("overlay:scrollbar", { id = view.scrollbar_id, ratio = 1 })
    view = find(":mux:viewport")
    assert.equals(1, view.scrollbar_thumb_ratio)
    assert.is_true(view.reveal_start)
    assert.is_not_nil(find(":mux-navigator:item:pane:1100"))
    assert.is_true(#tree() <= 512)
    ui.dispatch_overlay_key("home", 0)
    assert.is_nil(find(":mux:viewport").reveal_start)
    panes[1].foreground_process = "updated process"
    hollow._emit_builtin_event("term:foreground_process_changed", { pane_id = 101 })
    assert.is_truthy(text():find("updated process", 1, true))
    hollow.term.mux_tree = original
  end)
end)
