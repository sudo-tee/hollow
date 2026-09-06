local harness = require("tests.harness")

describe("asynchronous processes", function()
  local env
  before_each(function() env = harness.boot() end)

  it("returns immediately, polls pending work and completes once", function()
    local polls, completed = 0, 0
    env.host_api.process_start = function(opts)
      assert.are.same({ "git", "status" }, opts.cmd)
      assert.are.equal("/tmp", opts.cwd)
      return 1
    end
    env.host_api.process_poll = function()
      polls = polls + 1
      if polls == 1 then return nil end
      return { code = 0, stdout = "clean", stderr = "" }
    end
    local handle = env.hollow.process.spawn({
      cmd = { "git", "status" }, cwd = "/tmp",
      on_complete = function() completed = completed + 1 end,
    })
    assert.are.equal("running", handle:status())
    assert.are.equal(0, polls)
    local received
    handle:next(function(result) received = result end)
    env.flush_deferred()
    assert.are.equal("finished", handle:status())
    assert.are.equal("clean", received.stdout)
    assert.are.equal(1, completed)
    assert.are.equal(received, handle:result())
  end)

  it("supports cancellation without canceling a reused native slot", function()
    local canceled = 0
    env.host_api.process_start = function() return 1 end
    env.host_api.process_cancel = function() canceled = canceled + 1 end
    env.host_api.process_poll = function() return { code = -1, error = "Canceled", canceled = true } end
    local handle = env.hollow.process.spawn({ cmd = "sleep" })
    handle:cancel()
    env.flush_deferred()
    handle:cancel()
    assert.are.equal(1, canceled)
    assert.is_true(handle:result().canceled)
  end)

  it("exec rejects infrastructure failures and preserves nonzero exit codes", function()
    env.host_api.process_start = function() return 1 end
    env.host_api.process_poll = function() return { code = 7, stdout = "", stderr = "failed" } end
    local value
    env.hollow.process.exec({ cmd = "tool" }):next(function(result) value = result end)
    env.flush_deferred()
    assert.are.equal(7, value.code)
    env.host_api.process_poll = function() return { code = -1, error = "Timeout" } end
    local failure
    env.hollow.process.exec({ cmd = "tool" }):catch(function(result) failure = result end)
    env.flush_deferred()
    assert.are.equal("Timeout", failure.error)
  end)

  it("validates options before starting native work", function()
    env.host_api.process_start = function() error("must not start") end
    assert.has_error(function() env.hollow.process.spawn({ cmd = {} }) end, "process.spawn requires cmd argv")
    assert.has_error(function() env.hollow.process.spawn({ cmd = "tool", timeout_ms = -1 }) end, "timeout_ms must be a positive integer")
    assert.has_error(function() env.hollow.process.spawn({ cmd = "tool", env = { BAD = 1 } }) end, "env must contain valid string keys and values")
  end)
end)
