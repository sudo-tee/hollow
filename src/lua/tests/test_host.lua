local harness = require("tests.harness")

describe("hollow.host connector", function()
  local env
  local queue
  local function step()
    local fn = table.remove(queue, 1)
    assert.is_truthy(fn)
    fn()
  end

  before_each(function()
    env = harness.boot()
    queue = {}
    env.host_api.defer = function(fn) queue[#queue + 1] = fn end
  end)

  local function native_host(status)
    local handle = { generation = "private" }
    env.host_api.host_connect = function(opts)
      assert.are.equal("stable", opts.id)
      assert.is_table(opts.argv)
      return handle
    end
    env.host_api.host_status = function()
      return status(), nil
    end
    env.host_api.host_close = function() return true end
    return handle
  end

  local function ready_host()
    native_host(function() return "ready" end)
    local promise = require("hollow.host").connect({ id = "stable", argv = { "connector", "--flag" } })
    step()
    return promise:value()
  end

  it("connects asynchronously and exposes ready host without native handle", function()
    local state = "connecting"
    native_host(function() return state end)
    local promise = require("hollow.host").connect({ id = "stable", argv = { "connector", "--flag" } })
    assert.are.equal("pending", promise:status())
    assert.are.equal(1, #queue)
    step()
    assert.are.equal("pending", promise:status())
    state = "ready"
    step()
    local host = promise:value()
    assert.are.equal("stable", host.id)
    assert.is_nil(host.handle)
    assert.are.equal("ready", host:status())
  end)

  it("polls requests, forwards cancel once, and resolves nonzero exits", function()
    local host = ready_host()
    local polls, cancels = 0, 0
    env.host_api.host_start = function(_, op, opts)
      assert.are.equal("exec", op)
      assert.are.same({ argv = { "tool", "arg" }, cwd = "/tmp" }, opts)
      return { generation = "ticket" }
    end
    env.host_api.host_cancel = function() cancels = cancels + 1; return true end
    env.host_api.host_poll = function()
      polls = polls + 1
      if polls == 1 then return nil end
      return { exit_code = 9, stdout = "\0\255", stderr = "failed" }
    end
    local promise = host:exec({ argv = { "tool", "arg" }, cwd = "/tmp" })
    assert.are.equal("pending", promise:status())
    promise:cancel(); promise:cancel()
    assert.are.equal(1, cancels)
    step(); assert.are.equal("pending", promise:status())
    step()
    assert.are.equal("fulfilled", promise:status())
    assert.are.equal(9, promise:value().exit_code)
    assert.are.equal("\0\255", promise:value().stdout)
  end)

  it("rejects structured failures and stops after disconnect", function()
    local state = "connecting"
    native_host(function() return state end)
    local promise = require("hollow.host").connect({ id = "stable", argv = { "connector" } })
    state = "disconnected"
    step()
    assert.are.equal("rejected", promise:status())
    assert.are.equal("transport_disconnected", promise:error().code)
    assert.are.equal(0, #queue)
  end)

  it("preserves binary read results and rejects invalid path and argv values", function()
    local host = ready_host()
    assert.has_error(function() host.fs.stat("bad\0path") end)
    assert.has_error(function() host:exec({ argv = { [1] = "x", [3] = "z" } }) end)
    env.host_api.host_start = function() return {} end
    env.host_api.host_poll = function() return { bytes = "\0\255" } end
    local promise = host.fs.read("/bytes")
    step()
    assert.are.equal("\0\255", promise:value().bytes)
  end)

  it("rejects structured operation errors and settles terminal results once", function()
    local host = ready_host()
    env.host_api.host_start = function() return { generation = "ticket" } end
    local polls = 0
    env.host_api.host_poll = function()
      polls = polls + 1
      return { error = { code = "not_found", message = "missing", truncated = false } }
    end
    local promise = host.fs.stat("/missing")
    step()
    assert.are.equal("rejected", promise:status())
    assert.are.equal(0, #queue)
    assert.are.equal("not_found", promise:error().code)
    assert.are.equal(1, polls)
  end)

  it("keeps stable identity when connect options change before readiness", function()
    native_host(function() return "ready" end)
    local opts = { id = "stable", argv = { "connector" } }
    local promise = require("hollow.host").connect(opts)
    opts.id = "different"
    step()
    assert.are.equal("stable", promise:value().id)
  end)

  it("cancels pending connections without publishing a late ready host", function()
    local closes = 0
    native_host(function() return "ready" end)
    env.host_api.host_close = function() closes = closes + 1; return true end
    local promise = require("hollow.host").connect({ id = "stable", argv = { "connector" } })
    assert.is_true(promise:cancel())
    assert.is_false(promise:cancel())
    step()
    assert.are.equal("rejected", promise:status())
    assert.are.equal("cancelled", promise:error().code)
    assert.are.equal(1, closes)
    assert.is_nil(promise:value())
    assert.are.equal(0, #queue)
  end)

  it("preserves empty argv bytes and rejects excessive numeric options", function()
    local host = ready_host()
    env.host_api.host_start = function(_, _, opts)
      assert.are.same({ "tool", "", "\255" }, opts.argv)
      return {}
    end
    env.host_api.host_poll = function() return { exit_code = 0, stdout = "", stderr = "" } end
    local result = host:exec({ argv = { "tool", "", "\255" } })
    step()
    assert.are.equal("fulfilled", result:status())
    assert.has_error(function() host:exec({ argv = { "tool" }, timeout_ms = 86400001 }) end)
    assert.has_error(function() host.fs.list("/", { limit = 257 }) end)
    assert.has_error(function() host.fs.list("/", { limit = 0 }) end)
    assert.has_error(function() host.fs.read("/", { limit = 16385 }) end)
  end)

  it("connects native-local once and reconnects explicitly after close", function()
    local connections, closes = 0, 0
    env.host_api.host_connect = function(opts)
      assert.are.same({ id = "local", backend = "local" }, opts)
      connections = connections + 1
      return { generation = tostring(connections) }
    end
    env.host_api.host_status = function() return "ready" end
    env.host_api.host_close = function() closes = closes + 1; return true end
    local hosts = require("hollow.host")
    local first = hosts.local_host()
    assert.are.equal(first, hosts.local_host())
    step()
    assert.are.equal("1", first:value().generation)
    assert.are.equal(first, hosts.local_host())
    assert.is_true(first:value():close())
    local second = hosts.local_host()
    step()
    assert.are.equal("2", second:value().generation)
    assert.are.equal(2, connections)
    assert.are.equal(1, closes)
    assert.has_error(function() hosts.connect({ id = "x", backend = "local", argv = { "not-run" } }) end)
  end)

  it("bounds all connector bootstraps together and releases capacity on rejection", function()
    local hosts = require("hollow.host")
    local rejects = {}
    package.loaded["hollow.host.podman"] = { connect = function()
      return require("hollow.async").promise(function(_, reject) rejects[#rejects + 1] = reject end)
    end }
    for _, name in ipairs({ "wsl", "ssh", "docker" }) do package.loaded["hollow.host." .. name] = package.loaded["hollow.host.podman"] end
    for _, name in ipairs({ "podman", "wsl", "ssh", "docker" }) do assert.are.equal("pending", hosts[name]({}):status()) end
    local full = hosts.docker({})
    assert.are.equal("resource_exhausted", full:error().code)
    rejects[1]({ code = "cancelled", message = "test" })
    assert.are.equal("pending", hosts.docker({}):status())
    assert.are.equal(5, #rejects)
    for _, name in ipairs({ "podman", "wsl", "ssh", "docker" }) do package.loaded["hollow.host." .. name] = nil end
  end)
end)
