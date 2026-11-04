package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local clay = require("tests.clay_helpers")
local harness = require("tests.harness")

describe("terminal clipboard read approval", function()
  local env, ui, host, calls
  before_each(function()
    env = harness.boot()
    ui = env.hollow.ui
    host = require("hollow.state").get().host_api
    calls = {}
    host.clipboard_read_authorize = function(id, allow, generation)
      calls[#calls + 1] = { id = id, allow = allow, generation = generation }
      return true
    end
  end)

  it("defaults to deny and requires a separate explicit Allow once selection", function()
    env.hollow.action.allow_clipboard_read()
    assert.equals(0, #calls)
    assert.is_true(ui.dispatch_overlay_key("enter", 0))
    assert.is_false(calls[1].allow)
    env.hollow.action.allow_clipboard_read()
    assert.is_true(ui.dispatch_overlay_key("arrow_right", 0))
    assert.is_true(ui.dispatch_overlay_key("enter", 0))
    assert.is_true(calls[2].allow)
    assert.equals(calls[1].id, calls[2].id)
  end)

  it("uses padded semantic buttons while keeping Deny selected", function()
    env.hollow.action.allow_clipboard_read()
    local deny = assert(clay.label(ui, "Deny"))
    local allow = assert(clay.label(ui, "Allow once"))
    assert.same({ top = 3, right = 8, bottom = 3, left = 8 }, deny.padding)
    assert.same(deny.padding, allow.padding)
    assert.equals(deny.hover_bg, deny.bg)
    assert.is_not_nil(deny.bg)
    assert.is_nil(allow.bg)
    assert.is_not_nil(allow.hover_bg)
    assert.is_not.equals(deny.hover_bg, allow.hover_bg)
    assert.equals(allow.hover_bg, clay.text_node(ui, "Allow once").fg)
    ui.dispatch_overlay_key("arrow_right", 0)
    allow = assert(clay.label(ui, "Allow once"))
    assert.equals(allow.hover_bg, allow.bg)
    assert.equals(allow.hover_fg, clay.text_node(ui, "Allow once").fg)
  end)

  it("cancellation and an existing exclusive dialog never grant access", function()
    env.hollow.action.allow_clipboard_read()
    assert.is_true(ui.dispatch_overlay_key("escape", 0))
    assert.equals(0, #calls)
    ui.input.open({ default = "unfinished" })
    env.hollow.action.allow_clipboard_read()
    assert.equals(0, #calls)
    assert.equals(1, ui.overlay.depth())
  end)

  it("supports explicit revocation without reading clipboard data", function()
    env.hollow.action.revoke_clipboard_read()
    assert.equals(1, #calls)
    assert.is_false(calls[1].allow)
  end)

  local function request(generation, pane_id)
    env.hollow._emit_builtin_event("term:clipboard_read_requested", {
      pane_id = pane_id or env.hollow.term.current_pane().id,
      generation = generation,
    })
  end

  it(
    "automatically asks after a denial with Deny selected and consent bound to generation",
    function()
      request(7)
      assert.equals(1, ui.overlay.depth())
      assert.equals(0, #calls)
      request(7) -- Duplicate events cannot revoke or replace the visible request.
      assert.equals(1, ui.overlay.depth())
      assert.equals(0, #calls)
      assert.is_true(ui.dispatch_overlay_key("enter", 0))
      assert.is_false(calls[1].allow)
      assert.equals(7, calls[1].generation)
      env.recorded.now_ms = env.recorded.now_ms + 5000
      request(8)
      assert.is_true(ui.dispatch_overlay_key("arrow_right", 0))
      assert.is_true(ui.dispatch_overlay_key("enter", 0))
      assert.is_true(calls[2].allow)
      assert.equals(8, calls[2].generation)
    end
  )

  it(
    "throttles repeat prompts and cancels rather than queueing behind exclusive dialogs",
    function()
      request(1)
      ui.dispatch_overlay_key("escape", 0)
      request(2)
      assert.equals(0, ui.overlay.depth())
      assert.equals(2, calls[2].generation)
      assert.is_false(calls[2].allow)
      env.recorded.now_ms = env.recorded.now_ms + 5000
      ui.input.open({ default = "unfinished" })
      request(3)
      assert.equals(1, ui.overlay.depth())
      assert.equals(3, calls[3].generation)
      assert.is_false(calls[3].allow)
      ui.dispatch_overlay_key("escape", 0)
      env.flush_deferred()
      assert.equals(0, ui.overlay.depth())
    end
  )

  it("never prompts for another pane or retains a prompt after window focus loss", function()
    request(10, env.hollow.term.current_pane().id + 100)
    assert.equals(0, ui.overlay.depth())
    assert.is_false(calls[1].allow)
    request(11)
    assert.equals(1, ui.overlay.depth())
    env.hollow._emit_builtin_event("window:blurred", {})
    assert.equals(0, ui.overlay.depth())
    assert.equals(11, calls[2].generation)
    assert.is_false(calls[2].allow)
  end)
end)
