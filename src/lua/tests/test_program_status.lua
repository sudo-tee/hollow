package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")
local status = require("hollow.program_status")

describe("program status", function()
  it("shows no badge without reports", function()
    assert.is_nil(status.badge({ { program_status = {} } }))
  end)

  it("prioritizes errors and blocked work across panes", function()
    assert.equals(
      "[permission] ",
      status.badge({
        { program_status = { { state = "working", progress = 30 } } },
        { program_status = { { state = "blocked", kind = "permission" } } },
      })
    )
    assert.equals(
      "[error] ",
      status.badge({
        {
          program_status = {
            { state = "blocked", kind = "auth" },
            { state = "error" },
          },
        },
      })
    )
  end)

  it("formats progress without rendering program-provided markup", function()
    assert.equals(
      "[working 0%] ",
      status.badge({
        {
          program_status = {
            { state = "working", progress = 0, title = "<fake>", message = "<script>" },
          },
        },
      })
    )
  end)

  it("adapts host status changes and invalidates bars", function()
    local env = harness.boot()
    local hollow = env.hollow
    hollow.ui.topbar.configure({})
    env.host_api.get_pane_program_status = function()
      return { { id = "build", state = "blocked", kind = "permission", app = "demo" } }
    end
    local state = require("hollow.state").get()
    local payload
    hollow.events.once("term:program_status_changed", function(value)
      payload = value
    end)
    state.ui.topbar_cache_dirty = false
    state.ui.bottombar_cache_dirty = false
    hollow._emit_builtin_event("term:program_status_changed", { pane_id = 101 })
    assert.equals(101, payload.pane.id)
    assert.equals("blocked", payload.pane.program_status[1].state)
    assert.equals("permission", hollow.term.current_pane().program_status[1].kind)
    assert.is_true(state.ui.topbar_cache_dirty)
    assert.is_true(state.ui.bottombar_cache_dirty)
  end)
end)
