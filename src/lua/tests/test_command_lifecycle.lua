package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("command lifecycle persistence", function()
  local env

  before_each(function()
    env = harness.boot()
  end)

  it("preserves running commands and their receipt timestamps across runtime recreation", function()
    env.hollow.htp._handle_emit("command_started", { command = "sleep 60" }, 101, 1000)
    local saved = env.hollow.util.clone_value(env.hollow.term._export_command_states())

    env = harness.boot()
    env.recorded.now_ms = 2000
    env.hollow.term._restore_command_states(saved)
    local pane = env.hollow.term.pane_by_id(101)
    harness.assert_true(pane.busy, "reload should preserve busy state")
    harness.assert_equal(pane.running.command, "sleep 60", "reload should preserve command text")
    harness.assert_equal(pane.running.ms, 1000, "reload should preserve the start timestamp")

    local finished
    env.hollow.events.once("term:command_finished", function(event)
      finished = event
    end)
    env.hollow.htp._handle_emit("command_ended", { exit_code = 7 }, 101, 61000)
    harness.assert_equal(
      finished.command,
      "sleep 60",
      "completion should pair with pre-reload command"
    )
    harness.assert_equal(finished.took_ms, 60000, "completion should retain full duration")

    saved = env.hollow.util.clone_value(env.hollow.term._export_command_states())
    env = harness.boot()
    env.hollow.term._restore_command_states(saved)
    pane = env.hollow.term.pane_by_id(101)
    harness.assert_true(not pane.busy, "completed command should remain idle")
    harness.assert_equal(pane.last.command, "sleep 60", "reload should preserve last command")
    harness.assert_equal(pane.last.status, 7, "reload should preserve exit status")
    harness.assert_equal(pane.last.took_ms, 60000, "reload should preserve completed duration")
  end)

  it("does not restore state onto a replaced or missing pane", function()
    env.hollow.htp._handle_emit("command_started", { command = "old command" }, 101, 1000)
    local saved = env.hollow.term._export_command_states()
    saved[1].pid = saved[1].pid + 1
    saved[2] = { pane_id = 999, pid = 1, running = saved[1].running }
    env.hollow.term._restore_command_states(saved)
    harness.assert_true(
      not env.hollow.term.pane_by_id(101).busy,
      "replaced pane must not inherit state"
    )
    harness.assert_equal(
      #env.hollow.term._export_command_states(),
      0,
      "missing pane should be ignored"
    )
  end)

  it("uses receipt cwd even when the pane cwd has already changed", function()
    local started
    env.hollow.events.once("term:command_started", function(event)
      started = event
    end)
    env.host_api.get_pane_cwd = function()
      return "/destination"
    end
    env.hollow.htp._handle_emit(
      "command_started",
      { command = "cd /destination" },
      101,
      1000,
      "/origin"
    )
    harness.assert_equal(started.cwd, "/origin", "event should retain cwd at the stream boundary")
    harness.assert_equal(
      started.pane.cwd,
      "/destination",
      "pane snapshot should still reflect current cwd"
    )
  end)

  it("prefers shell cwd when earlier OSC 7 has not been parsed yet", function()
    local started
    env.hollow.events.once("term:command_started", function(event)
      started = event
    end)
    env.hollow.htp._handle_emit(
      "command_started",
      { command = "cd /destination", cwd = "/origin" },
      101,
      1000,
      "/stale"
    )
    harness.assert_equal(started.cwd, "/origin", "shell cwd should override stale host cwd")
  end)

  it("does not use source receipt cwd for another target pane", function()
    local started
    env.hollow.events.once("term:command_started", function(event)
      started = event
    end)
    env.hollow.htp._handle_emit(
      "command_started",
      { pane_id = 101, command = "test" },
      102,
      1000,
      "/source"
    )
    harness.assert_equal(started.cwd, "/tmp/project", "target pane should use its own cwd")
  end)
end)
