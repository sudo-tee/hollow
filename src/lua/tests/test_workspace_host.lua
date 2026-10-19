local harness = require("tests.harness")

describe("workspace host reads", function()
  local env, queue, calls, pending, host
  local function drain()
    while #queue > 0 do table.remove(queue, 1)() end
  end
  before_each(function()
    env = harness.boot()
    queue, calls, pending = {}, {}, {}
    env.host_api.defer = function(fn) queue[#queue + 1] = fn end
    env.host_api.read_file = function() error("must not read local workspace") end
    env.host_api.json_decode = function(text)
      if text == '{"tabs":[]}' or text == '{"tabs":[] }' then return { tabs = {} } end
      if text == '{"tabs":false}' then return { tabs = false } end
      error("invalid JSON")
    end
    host = { fs = {} }
    host.fs.read = function(path, opts)
      calls[#calls + 1] = { path = path, offset = opts.offset, limit = opts.limit }
      local resolve, reject
      local p = env.hollow.async.promise(function(r, j) resolve, reject = r, j end)
      function p:cancel() self.cancelled = true; return true end
      pending[#pending + 1] = { promise = p, resolve = resolve, reject = reject }
      return p
    end
  end)

  it("pages exact host path bytes without local reads or pane creation", function()
    local path = "/project \255/workspace.json"
    local p = env.hollow.workspace.load_host(host, path)
    assert.are.equal("pending", p:status())
    assert.are.equal(0, #calls)
    drain()
    pending[1].resolve({ bytes = '{"tabs":[', eof = false })
    drain()
    assert.are.same({ path = path, offset = 9, limit = 16384 }, calls[2])
    pending[2].resolve({ bytes = '] }', eof = true })
    assert.are.equal("fulfilled", p:status())
    assert.are.equal(path, p:value()._path)
    assert.are.same({}, p:value().tabs)
    assert.is_nil(env.recorded.new_workspace)
  end)

  it("rejects oversized valid JSON prefixes instead of truncating", function()
    local text = '{"tabs":[]}'
    local p = env.hollow.workspace.load_host(host, "/file", { max_bytes = #text })
    drain()
    pending[1].resolve({ bytes = text, eof = false })
    drain()
    assert.are.equal(1, calls[2].limit)
    pending[2].resolve({ bytes = " ", eof = true })
    assert.are.equal("resource_exhausted", p:error().code)
  end)

  it("accepts exact-limit EOF and validates JSON and workspace schema", function()
    for _, text in ipairs({ '{"tabs":[]}', '{"tabs":false}', 'broken' }) do
      local p = env.hollow.workspace.load_host(host, "/file", { max_bytes = #text })
      drain()
      pending[#pending].resolve({ bytes = text, eof = true })
      if text == '{"tabs":[]}' then assert.are.equal("fulfilled", p:status())
      else assert.are.equal("invalid_argument", p:error().code) end
    end
  end)

  it("cancels pending reads and ignores late completion without another page", function()
    local p = env.hollow.workspace.load_host(host, "/file")
    drain()
    assert.is_true(p:cancel())
    assert.is_true(pending[1].promise.cancelled)
    assert.is_false(p:cancel())
    pending[1].resolve({ bytes = "part", eof = false })
    drain()
    assert.are.equal("cancelled", p:error().code)
    assert.are.equal(1, #calls)
  end)

  it("can cancel before issuing any host read", function()
    local p = env.hollow.workspace.load_host(host, "/file")
    p:cancel(); drain()
    assert.are.equal(0, #calls)
    assert.are.equal("cancelled", p:error().code)
  end)

  it("rejects malformed and nonadvancing pages and preserves host errors", function()
    for _, page in ipairs({ { bytes = "", eof = false }, { bytes = 1, eof = true }, { bytes = "x" }, { bytes = string.rep("x", 16385), eof = true } }) do
      local p = env.hollow.workspace.load_host(host, "/file")
      drain(); pending[#pending].resolve(page)
      assert.are.equal("io_error", p:error().code)
    end
    local p = env.hollow.workspace.load_host(host, "/file")
    drain(); pending[#pending].reject({ code = "transport_disconnected", message = "gone" })
    assert.are.equal("transport_disconnected", p:error().code)
  end)

  it("rejects invalid arguments before I/O", function()
    for _, maximum in ipairs({ 0, -1, 1.5, 1048577, math.huge, "4", false }) do
      assert.has_error(function() env.hollow.workspace.load_host(host, "/file", { max_bytes = maximum }) end)
    end
    assert.has_error(function() env.hollow.workspace.load_host(host, "bad\0path") end)
    assert.has_error(function() env.hollow.workspace.load_host({}, "/file") end)
    assert.has_error(function() env.hollow.workspace.load_host(host, "/file", false) end)
    assert.are.equal(0, #calls)
  end)
end)
