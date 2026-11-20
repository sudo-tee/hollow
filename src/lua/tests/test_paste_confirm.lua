package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local clay = require("tests.clay_helpers")
local harness = require("tests.harness")

describe("blocked paste confirmation", function()
  local env, ui, calls
  before_each(function()
    env = harness.boot()
    ui = env.hollow.ui
    calls = {}
    require("hollow.state").get().host_api.paste_confirm = function(id, generation, allow)
      calls[#calls + 1] = { id = id, generation = generation, allow = allow }
      return true
    end
  end)

  local function blocked(generation, pane_id)
    env.hollow._emit_builtin_event("term:paste_blocked", {
      pane_id = pane_id or env.hollow.term.current_pane().id,
      generation = generation,
      bytes = 18,
      lines = 2,
      reason = "newline",
    })
  end

  it("defaults to Cancel and pastes only after selecting Paste anyway", function()
    blocked(1)
    assert.is_not_nil(clay.label(ui, "Cancel"))
    assert.is_not_nil(clay.label(ui, "Paste anyway"))
    assert.is_true(ui.dispatch_overlay_key("enter", 0))
    assert.same({ id = env.hollow.term.current_pane().id, generation = 1, allow = false }, calls[1])
    blocked(2)
    assert.is_true(ui.dispatch_overlay_key("arrow_right", 0))
    assert.is_true(ui.dispatch_overlay_key("enter", 0))
    assert.equals(2, calls[2].generation)
    assert.is_true(calls[2].allow)
    assert.equals(2, #calls)
  end)

  it("denies on escape and answers the newest blocked paste", function()
    blocked(3)
    blocked(4)
    assert.equals(1, ui.overlay.depth())
    assert.equals(0, #calls)
    assert.is_true(ui.dispatch_overlay_key("escape", 0))
    assert.same(4, calls[1].generation)
    assert.is_false(calls[1].allow)
  end)

  it("confirms for an existing unfocused pane", function()
    local host = require("hollow.state").get().host_api
    local exists = host.pane_exists
    host.pane_exists = function(id)
      return id == 202 or exists(id)
    end
    blocked(8, 202)
    assert.equals(1, ui.overlay.depth())
    assert.is_true(ui.dispatch_overlay_key("arrow_right", 0))
    assert.is_true(ui.dispatch_overlay_key("enter", 0))
    assert.same({ id = 202, generation = 8, allow = true }, calls[1])
  end)

  it("denies missing panes, focus loss, and exclusive dialogs", function()
    blocked(5, env.hollow.term.current_pane().id + 100)
    assert.equals(0, ui.overlay.depth())
    assert.is_false(calls[1].allow)
    blocked(6)
    env.hollow._emit_builtin_event("window:blurred", {})
    assert.equals(0, ui.overlay.depth())
    assert.equals(6, calls[2].generation)
    assert.is_false(calls[2].allow)
    env.hollow._emit_builtin_event("window:focused", {})
    env.flush_deferred()
    ui.input.open({ default = "unfinished" })
    blocked(7)
    assert.is_nil(clay.label(ui, "Paste anyway"))
    assert.is_not_nil(clay.text_node(ui, "Paste blocked"))
    assert.equals(7, calls[3].generation)
    assert.is_false(calls[3].allow)
  end)
end)
