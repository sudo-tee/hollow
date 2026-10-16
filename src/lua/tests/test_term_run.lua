package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("promise-based terminal commands", function()
  local env, hollow, deferred

  local function emit(name, payload, pane_id)
    return hollow.htp._handle_emit(name, payload or {}, pane_id or 101, env.recorded.now_ms)
  end

  local function ready(pane_id)
    emit("prompt_ready", {}, pane_id)
  end

  local function complete(status, pane_id)
    emit("command_started", { command = "shell-expanded command" }, pane_id)
    env.recorded.now_ms = env.recorded.now_ms + 100
    emit("command_ended", { exit_code = status }, pane_id)
    ready(pane_id)
  end

  local function tick(ms)
    env.recorded.now_ms = env.recorded.now_ms + ms
    local batch = deferred
    deferred = {}
    for _, item in ipairs(batch) do item.callback() end
  end

  before_each(function()
    env = harness.boot()
    hollow = env.hollow
    deferred = {}
    env.host_api.defer = function(callback, delay)
      deferred[#deferred + 1] = { callback = callback, delay = delay }
    end
  end)

  it("requires affirmative shell readiness rather than idle command state", function()
    assert.is_false(hollow.term.pane_by_id(101).busy)
    assert.is_false(hollow.term.pane_by_id(101).at_prompt)
    local promise = hollow.term.run("true", { pane_id = 101 })
    assert.equals("rejected", promise:status())
    assert.matches("shell integration", promise:error())
    assert.equals(0, #env.recorded.send_text)
  end)

  it("sends Enter and resolves metadata only after command completion and prompt readiness", function()
    ready()
    local promise = hollow.term.run("cargo test", { pane_id = 101 })
    assert.equals("cargo test\r", env.recorded.send_text[1])
    assert.is_false(hollow.term.pane_by_id(101).at_prompt)
    ready() -- Repaint before the command starts must not complete the run.
    emit("command_ended", { exit_code = 0 }) -- Unpaired completion must not match.
    assert.equals("pending", promise:status())
    emit("command_started", { command = "cargo test" })
    env.recorded.now_ms = env.recorded.now_ms + 500
    emit("command_ended", { exit_code = 7 })
    assert.equals("pending", promise:status())
    ready()
    assert.equals("fulfilled", promise:status())
    assert.same({ pane_id = 101, command = "cargo test", status = 7, took_ms = 500 }, promise:value())
    assert.is_nil(promise:value().output)
    tick(25) -- Completed poll becomes a no-op.
    assert.equals(0, #deferred)
  end)

  it("captures the focused pane at submission", function()
    local pane_id = hollow.term.current_pane().id
    ready(pane_id)
    local promise = hollow.term.run("true")
    env.host_api.current_pane_id = function() return 102 end
    complete(0, pane_id)
    assert.equals(pane_id, promise:value().pane_id)
  end)

  it("allows a callback to submit the next run", function()
    ready()
    local second
    hollow.term.run("first", { pane_id = 101 }):next(function()
      second = hollow.term.run("second", { pane_id = 101 })
    end)
    complete(0)
    assert.equals("pending", second:status())
    complete(0)
    assert.equals("fulfilled", second:status())
    assert.equals("second\r", env.recorded.send_text[2])
  end)

  it("supports sequential coroutine awaits", function()
    ready()
    local result
    hollow.async.run(function()
      hollow.term.run("first", { pane_id = 101 }):await()
      result = hollow.term.run("second", { pane_id = 101 }):await()
    end)
    complete(0)
    assert.is_nil(result)
    complete(2)
    assert.equals(2, result.status)
  end)

  it("registers tracking before sending input even for synchronous completion", function()
    ready()
    env.host_api.send_text_to_pane = function(pane_id, text)
      assert.equals(101, pane_id)
      assert.equals("true\r", text)
      complete(0)
      return true
    end
    assert.equals("fulfilled", hollow.term.run("true", { pane_id = 101 }):status())
  end)

  it("rejects concurrent runs but allows independent panes", function()
    env.host_api.split_pane({})
    ready(101)
    ready(102)
    local first = hollow.term.run("first", { pane_id = 101 })
    local duplicate = hollow.term.run("duplicate", { pane_id = 101 })
    local other = hollow.term.run("other", { pane_id = 102 })
    assert.equals("rejected", duplicate:status())
    assert.matches("already pending", duplicate:error())
    complete(0, 102)
    assert.equals("fulfilled", other:status())
    assert.equals("pending", first:status())
    complete(0, 101)
    assert.equals("fulfilled", first:status())
  end)

  it("rejects busy panes and alternate screens without sending input", function()
    ready()
    emit("command_started", { command = "sleep 60" })
    assert.equals("rejected", hollow.term.run("true", { pane_id = 101 }):status())
    emit("command_ended", { exit_code = 0 })
    ready()
    env.host_api.get_pane_active_screen = function() return "alternate" end
    assert.equals("rejected", hollow.term.run("true", { pane_id = 101 }):status())
    assert.equals(0, #env.recorded.send_text)
  end)

  it("times out without sending cancellation and frees tracking", function()
    ready()
    local promise = hollow.term.run("sleep 60", { pane_id = 101, timeout_ms = 50 })
    assert.equals(25, deferred[1].delay)
    emit("command_started", { command = "sleep 60" })
    tick(25)
    assert.equals("pending", promise:status())
    tick(25)
    assert.equals("rejected", promise:status())
    assert.matches("not cancelled", promise:error())
    assert.is_true(hollow.term.pane_by_id(101).busy)
    assert.equals(1, #env.recorded.send_text)
    assert.equals(0, #deferred)
    emit("command_ended", { exit_code = 0 })
    ready()
    local next_run = hollow.term.run("true", { pane_id = 101 })
    complete(0)
    assert.equals("fulfilled", next_run:status())
    assert.equals("rejected", promise:status())
  end)

  it("times out when a command never starts or never returns to a prompt", function()
    ready()
    local promise = hollow.term.run("# comment", { pane_id = 101, timeout_ms = 10 })
    tick(10)
    assert.equals("rejected", promise:status())
    ready()
    promise = hollow.term.run("true", { pane_id = 101, timeout_ms = 10 })
    emit("command_started", { command = "true" })
    emit("command_ended", { exit_code = 0 })
    tick(10)
    assert.equals("rejected", promise:status())
  end)

  it("enforces the deadline even when completion runs before the deferred timeout check", function()
    ready()
    local promise = hollow.term.run("true", { pane_id = 101, timeout_ms = 50 })
    complete(0)
    assert.equals("rejected", promise:status())
    assert.matches("timed out", promise:error())
  end)

  it("rejects completion from a replacement pane before polling", function()
    ready()
    local promise = hollow.term.run("true", { pane_id = 101 })
    local pid = env.host_api.get_pane_pid
    env.host_api.get_pane_pid = function(id) return pid(id) + 1 end
    complete(0)
    assert.equals("rejected", promise:status())
    assert.matches("replaced", promise:error())
  end)

  it("does not turn an unknown exit status into success", function()
    ready()
    local promise = hollow.term.run("true", { pane_id = 101 })
    complete(nil)
    assert.equals("fulfilled", promise:status())
    assert.is_nil(promise:value().status)
  end)

  for _, event in ipairs({ "term:pane_exited", "term:pane_closed" }) do
    it("rejects and releases tracking on " .. event, function()
      ready()
      local promise = hollow.term.run("exec app", { pane_id = 101 })
      emit("command_started", { command = "exec app" })
      hollow._emit_builtin_event(event, { pane_id = 101, status = 0 })
      assert.equals("rejected", promise:status())
      assert.is_false(hollow.term.pane_by_id(101).at_prompt)
      tick(25)
      assert.equals(0, #deferred)
    end)
  end

  it("detects pane disappearance and replacement while waiting", function()
    for _, replaced in ipairs({ false, true }) do
      ready()
      local promise = hollow.term.run("true", { pane_id = 101 })
      local exists, pid = env.host_api.pane_exists, env.host_api.get_pane_pid
      if replaced then
        env.host_api.get_pane_pid = function(id) return pid(id) + 1 end
      else
        env.host_api.pane_exists = function() return false end
      end
      tick(25)
      assert.equals("rejected", promise:status())
      env.host_api.pane_exists, env.host_api.get_pane_pid = exists, pid
    end
  end)

  it("rejects unknown panes and send failures", function()
    assert.equals("rejected", hollow.term.run("true", { pane_id = 999 }):status())
    for _, throws in ipairs({ false, true }) do
      ready()
      env.host_api.send_text_to_pane = function()
        if throws then error("write failed") end
        return false
      end
      local promise = hollow.term.run("true", { pane_id = 101 })
      assert.equals("rejected", promise:status())
      tick(25)
      assert.equals(0, #deferred)
    end
  end)

  it("does not let custom HTP handlers suppress readiness tracking", function()
    hollow.htp.on_emit("prompt_ready", function() error("plugin failed") end)
    assert.is_false(emit("prompt_ready"))
    local promise = hollow.term.run("true", { pane_id = 101 })
    complete(0)
    assert.equals("fulfilled", promise:status())
  end)

  it("rejects overlapping lifecycle starts rather than returning the wrong result", function()
    ready()
    local promise = hollow.term.run("true", { pane_id = 101 })
    emit("command_started", { command = "true" })
    emit("command_started", { command = "other controller" })
    assert.equals("rejected", promise:status())
    assert.matches("interrupted", promise:error())
  end)

  it("preserves readiness across runtime recreation", function()
    ready()
    local saved = hollow.term._export_command_states()
    env = harness.boot()
    hollow = env.hollow
    hollow.term._restore_command_states(saved)
    assert.is_true(hollow.term.pane_by_id(101).at_prompt)
    emit("command_started", { command = "true" })
    assert.is_false(hollow.term.pane_by_id(101).at_prompt)
  end)

  it("validates commands and options before sending input", function()
    for _, command in ipairs({ "", "  ", "true\r", "a\nb", "\27[31m", "a\0b", false, 3 }) do
      assert.has_error(function() hollow.term.run(command) end)
    end
    assert.has_error(function() hollow.term.run("true", false) end)
    for _, timeout in ipairs({ 0, -1, 1.5, math.huge, 0/0, "30", false }) do
      assert.has_error(function() hollow.term.run("true", { timeout_ms = timeout }) end)
    end
    for _, id in ipairs({ "101", false, -1, 0, 1.5, math.huge, 0/0 }) do
      assert.has_error(function() hollow.term.run("true", { pane_id = id }) end)
    end
    assert.equals(0, #env.recorded.send_text)
  end)
end)
