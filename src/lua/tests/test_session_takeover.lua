package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local clay = require("tests.clay_helpers")
local harness = require("tests.harness")

describe("session takeover card", function()
  local env, ui, calls
  before_each(function()
    env = harness.boot()
    ui = env.hollow.ui
    calls = {}
    require("hollow.state").get().host_api.session_takeover_action = function(id, action)
      calls[#calls + 1] = { id, action }
    end
  end)

  local function takeover(phase, reason)
    env.hollow._emit_builtin_event(
      "session:takeover",
      { workspace_id = 12, phase = phase, reason = reason }
    )
  end

  local function key(name, mods)
    return ui.dispatch_overlay_key(name, mods or 0)
  end

  it("opens for a taken workspace and closes when it is released", function()
    takeover("idle")
    assert.equals(1, ui.overlay.depth())
    assert.is_not_nil(clay.label(ui, "Reclaim session"))
    takeover("none")
    assert.equals(0, ui.overlay.depth())
  end)

  it("confirms in place and binds actions to the workspace", function()
    takeover("idle")
    assert.is_true(key("r"))
    takeover("confirming")
    assert.equals(1, ui.overlay.depth())
    assert.is_not_nil(clay.label(ui, "Confirm reclaim"))
    assert.is_true(key("escape"))
    assert.is_true(key("enter"))
    assert.is_true(key("arrow_right"))
    assert.is_true(key("enter"))
    assert.same({ { 12, "reclaim" }, { 12, "cancel" }, { 12, "confirm" }, { 12, "cancel" } }, calls)
  end)

  it("closes the local view with c or the second button", function()
    takeover("idle")
    key("c")
    key("arrow_right")
    key("enter")
    assert.same({ { 12, "close" }, { 12, "close" } }, calls)
  end)

  it("passes modified keys to the keymap but swallows plain typing", function()
    takeover("idle")
    assert.is_false(ui.dispatch_overlay_key("r", 2))
    assert.is_true(key("x"))
    assert.equals(0, #calls)
  end)

  it("keeps reclaim disabled while connecting and offers retry after failure", function()
    takeover("connecting")
    key("r")
    key("enter")
    assert.same({ { 12, "close" } }, calls)
    takeover("failed", "Timeout")
    assert.is_not_nil(clay.text_node(ui, "Reclaim failed: Timeout. The frozen view is kept."))
    key("enter")
    assert.same({ 12, "reclaim" }, calls[2])
  end)

  it("waits for an unfinished exclusive dialog instead of replacing it", function()
    ui.input.open({ default = "unfinished" })
    takeover("idle")
    assert.equals(1, ui.overlay.depth())
  end)
end)
