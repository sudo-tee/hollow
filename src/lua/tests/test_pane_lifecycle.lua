package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("pane lifecycle events", function()
  local env
  local hollow

  before_each(function()
    env = harness.boot()
    hollow = env.hollow
  end)

  it("adapts newly created panes and invalidates bar caches", function()
    hollow.ui.topbar.configure({})
    local created
    hollow.events.once("term:pane_created", function(event)
      created = event
    end)
    local state = env.state.get()
    state.ui.topbar_cache_dirty = false
    state.ui.bottombar_cache_dirty = false
    hollow._emit_builtin_event("term:pane_created", { pane_id = 101 })
    harness.assert_equal(created.pane.id, 101, "creation should include a full pane snapshot")
    harness.assert_equal(created.pane.cwd, "/tmp/project", "snapshot should include launch cwd")
    harness.assert_true(state.ui.topbar_cache_dirty, "creation should invalidate topbar")
    harness.assert_true(state.ui.bottombar_cache_dirty, "creation should invalidate bottombar")
  end)

  it("retains zero exit status and clears the running command without shell end hooks", function()
    hollow.htp._handle_emit("command_started", { command = "exec app" }, 101, 1000)
    local exited
    hollow.events.once("term:pane_exited", function(event)
      exited = event
    end)
    hollow._emit_builtin_event("term:pane_exited", { pane_id = 101, status = 0 })
    harness.assert_equal(exited.status, 0, "successful exit code must not be lost")
    harness.assert_equal(exited.pane.id, 101, "exit should include the exiting pane")
    harness.assert_true(not exited.pane.busy, "exited pane must not remain busy")
    harness.assert_equal(exited.pane.running, nil, "exit should clear running command")
  end)

  it("preserves signal and unknown exit statuses", function()
    local statuses = {}
    hollow.events.on("term:pane_exited", function(event)
      statuses[#statuses + 1] = { status = event.status }
    end)
    hollow._emit_builtin_event("term:pane_exited", { pane_id = 101, status = 137 })
    hollow._emit_builtin_event("term:pane_exited", { pane_id = 101 })
    harness.assert_equal(statuses[1].status, 137, "signal-derived exit code should be preserved")
    harness.assert_equal(statuses[2].status, nil, "unknown status must not become success")
  end)

  it("keeps the final closed snapshot but releases tags and command state", function()
    hollow.term.add_pane_tag("build", 101)
    hollow.htp._handle_emit("command_started", { command = "build" }, 101, 1000)
    local closed
    hollow.events.once("term:pane_closed", function(event)
      closed = event
    end)
    hollow._emit_builtin_event("term:pane_closed", { pane_id = 101 })
    harness.assert_equal(closed.pane.id, 101, "close should include a final snapshot")
    harness.assert_equal(closed.pane.tags[1], "build", "final snapshot should retain old tags")
    harness.assert_equal(closed.pane.running.command, "build", "snapshot should retain old command")
    harness.assert_equal(#hollow.term.get_pane_tags(101), 0, "closed pane tags should be released")
    harness.assert_true(
      not hollow.term.pane_by_id(101).busy,
      "closed command state must be released"
    )
    env.host_api.pane_exists = function()
      return false
    end
    harness.assert_equal(hollow.term.pane_by_id(101), nil, "closed pane should no longer resolve")
    harness.assert_equal(closed.pane.cwd, "/tmp/project", "saved snapshot must survive removal")
  end)
end)
