local harness = require("tests.harness")

describe("owned terminal jobs", function()
  local env, seen, handle, clock
  before_each(function()
    env, seen, clock = harness.boot(), {}, 0
    handle = { pane_id = 42, tab_id = 5, workspace_id = 1, token = string.rep("a", 32), cursor = 9 }
    env.host_api.now_ms = function() return clock end
    env.host_api.term_job_request = function(request, callback)
      seen[#seen + 1] = request
      env.host_api.defer(function()
        if request.kind == "job_spawn" then callback({ success = true, payload = handle })
        elseif request.kind == "job_get" then callback({ success = true, payload = { pane_id = 42, state = "exited", status = 7, cursor = 10 } })
        elseif request.kind == "job_output" then callback({ success = true, payload = { encoding = "base64", data = "/w==", truncated = true, incomplete = false } })
        else callback({ success = true }) end
      end)
      return true
    end
  end)

  it("returns immediately and queues operations until spawn is ready", function()
    local job = env.hollow.term.jobs.spawn({ argv = { "make", "test", "", "$HOME" }, cwd = "/work", domain = "linux", user_shell = true })
    assert.is_nil(job:handle())
    assert.are.equal("pending", job:ready():status())
    local output
    job:output():next(function(value) output = value end)
    assert.are.equal(1, #seen)
    env.flush_deferred()
    assert.are.equal(42, job:handle().pane_id)
    assert.are.same({ "make", "test", "", "$HOME" }, seen[1].argv)
    assert.are.equal("linux", seen[1].domain)
    assert.is_true(seen[1].user_shell)
    assert.are.equal("base64", output.encoding)
    assert.are.equal("/w==", output.data)
    assert.is_true(output.truncated)
    assert.are.equal(handle.token, seen[2].token)
    job:ready():value().token = "changed"
    local snapshot = job:handle()
    snapshot.pane_id = 999
    job:get()
    assert.are.equal(42, seen[3].id)
    assert.are.equal(handle.token, seen[3].token)
  end)

  it("waits asynchronously and preserves nonzero completion without auto cleanup", function()
    local job = env.hollow.term.jobs.spawn({ cmd = "make && test" })
    local result
    job:wait():next(function(value) result = value end)
    assert.is_nil(result)
    env.flush_deferred()
    assert.are.equal(7, result.status)
    assert.are.equal(handle.token, result.token)
    assert.are.equal(5, result.tab_id)
    assert.are.equal(2, #seen)
  end)

  it("auto closes only after completion, including a failed workload", function()
    local job = env.hollow.term.jobs.spawn({ argv = { "false" } })
    local result
    job:wait({ auto_close = true }):next(function(value) result = value end)
    env.flush_deferred()
    assert.is_true(result.closed)
    assert.are.equal(7, result.status)
    assert.are.equal("job_cleanup", seen[3].kind)
    assert.are.equal(handle.token, seen[3].token)
  end)

  it("times out without cleanup and can wait again on the same job", function()
    local bridge = env.host_api.term_job_request
    env.host_api.term_job_request = function(request, callback)
      if request.kind == "job_get" and clock == 0 then
        seen[#seen + 1] = request
        env.host_api.defer(function()
          clock = 20
          callback({ success = true, payload = { state = "running" } })
        end)
        return true
      end
      return bridge(request, callback)
    end
    local job = env.hollow.term.jobs.spawn({ argv = { "make" } })
    local failure
    job:wait({ timeout_ms = 10, auto_close = true }):catch(function(err) failure = err end)
    env.flush_deferred()
    assert.are.equal("timeout", failure.code)
    assert.are.same(handle, failure.handle)
    assert.are.equal(2, #seen)
    local result
    job:wait():next(function(value) result = value end)
    env.flush_deferred()
    assert.are.equal(7, result.status)
    assert.are.equal("job_get", seen[3].kind)
  end)

  it("polls pending jobs with deferred reads, never blocking or respawning", function()
    local bridge, polls = env.host_api.term_job_request, 0
    env.host_api.term_job_request = function(request, callback)
      if request.kind == "job_get" then
        polls = polls + 1
        if polls == 1 then
          seen[#seen + 1] = request
          env.host_api.defer(function() callback({ success = true, payload = { state = "running" } }) end)
          return true
        end
      end
      return bridge(request, callback)
    end
    local done
    env.hollow.term.jobs.spawn({ argv = { "make" } }):wait():next(function(result) done = result end)
    env.flush_deferred()
    assert.are.equal(7, done.status)
    assert.are.equal(2, polls)
    assert.are.equal("job_spawn", seen[1].kind)
    assert.are.equal("job_get", seen[3].kind)
  end)

  it("rejects spawn, ownership, running-cleanup and enqueue errors", function()
    for _, code in ipairs({ "spawn_failed", "job_not_found", "job_running" }) do
      local bridge = env.host_api.term_job_request
      env.host_api.term_job_request = function(request, callback)
        if (code == "spawn_failed" and request.kind == "job_spawn") or (code ~= "spawn_failed" and request.kind == "job_cleanup") then
          env.host_api.defer(function() callback({ success = false, status = code, error = "refused" }) end)
          return true
        end
        return bridge(request, callback)
      end
      local failure
      env.hollow.term.jobs.spawn({ argv = { "make" } }):cleanup():catch(function(err) failure = err end)
      env.flush_deferred()
      assert.are.equal(code, failure.code)
      env.host_api.term_job_request = bridge
    end
    env.host_api.term_job_request = function() return nil, "ResourceExhausted" end
    local failure
    env.hollow.term.jobs.spawn({ argv = { "make" } }):wait():catch(function(err) failure = err end)
    assert.are.equal("request_failed", failure.code)
  end)

  it("validates options before submitting native work", function()
    for _, opts in ipairs({ {}, { argv = {} }, { argv = { "" } }, { argv = { "x\0" } }, { argv = { "make" }, cmd = "make" }, { cmd = "" }, { cmd = "make", user_shell = 1 }, { cmd = "make", wait = true } }) do
      assert.has_error(function() env.hollow.term.jobs.spawn(opts) end)
    end
    assert.are.equal(0, #seen)
    local job = env.hollow.term.jobs.spawn({ argv = { "make" } })
    for _, opts in ipairs({ { timeout_ms = -1 }, { timeout_ms = math.huge }, { auto_close = "yes" }, { typo = 1 } }) do
      assert.has_error(function() job:wait(opts) end)
    end
    env.flush_deferred()
    assert.are.equal(1, #seen)
  end)

  it("supports awaiting job operations inside a coroutine", function()
    local result
    env.hollow.async.run(function()
      local job = env.hollow.term.jobs.spawn({ argv = { "make" } })
      result = job:wait():await()
      assert.is_true(job:cleanup():await())
    end)
    assert.is_nil(result)
    env.flush_deferred()
    assert.are.equal(7, result.status)
  end)

  it("rejects malformed boundary values through option schemas", function()
    local invalid_options = {
      { argv = { [1] = "make", [3] = "test" } },
      { argv = { "make", extra = "test" } },
      { argv = { "make", 1 } },
      { argv = { "make", string.rep("x", 128 * 1024) } },
      { cmd = "make", cwd = "work\0dir" },
      { cmd = "make", domain = "" },
    }

    for _, opts in ipairs(invalid_options) do
      assert.has_error(function()
        env.hollow.term.jobs.spawn(opts)
      end)
    end

    assert.are.equal(0, #seen)
  end)

  it("preserves structured cleanup errors through coroutine waits", function()
    local bridge = env.host_api.term_job_request
    env.host_api.term_job_request = function(request, callback)
      if request.kind ~= "job_cleanup" then
        return bridge(request, callback)
      end

      env.host_api.defer(function()
        callback({ success = false, status = "job_running", error = "output still draining" })
      end)
      return true
    end

    local failure
    local job = env.hollow.term.jobs.spawn({ argv = { "make" } })

    job:wait({ auto_close = true }):catch(function(err)
      failure = err
    end)

    env.flush_deferred()

    assert.are.equal("job_running", failure.code)
    assert.are.equal("output still draining", failure.message)
    assert.are.equal(handle.pane_id, job:handle().pane_id)
  end)
end)
