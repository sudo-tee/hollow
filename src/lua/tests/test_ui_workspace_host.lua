package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

local function deferred_promise(cancelled)
  local resolve, reject, settled = nil, nil, false
  local promise = {}
  function promise:next(ok, err)
    resolve, reject = ok, err
    return self
  end
  function promise:cancel()
    if cancelled then cancelled.count = cancelled.count + 1 end
  end
  return promise, function(value)
    if not settled and resolve then settled = true; resolve(value) end
  end, function(err)
    if not settled and reject then settled = true; reject(err) end
  end
end

describe("workspace host source", function()
  local env, hollow, pending, host, cancel_state, list_calls, stat_calls
  local function list_result(entries, next_offset, eof)
    return { entries = entries, next_offset = next_offset, eof = eof }
  end
  local function setup_host(id, generation)
    cancel_state = { count = 0 }
    host = { id = id or "host", generation = generation or "g1", fs = {} }
    function host.fs.list(path, opts)
      list_calls = list_calls + 1
      local p, resolve, reject = deferred_promise(cancel_state)
      pending[#pending + 1] = { kind = "list", path = path, opts = opts, resolve = resolve, reject = reject }
      return p
    end
    function host.fs.stat(path)
      stat_calls = stat_calls + 1
      local p, resolve, reject = deferred_promise(cancel_state)
      pending[#pending + 1] = { kind = "stat", path = path,
        resolve = function(kind) resolve({ kind = kind or "directory" }) end, reject = reject }
      return p
    end
  end
  local function configure(sources)
    hollow.ui.workspace.configure({ cache_ttl_ms = 100000, sources = sources })
  end
  local function call_for(kind, path)
    for i, operation in ipairs(pending) do
      if operation.kind == kind and (path == nil or operation.path == path) and not operation.used then
        operation.used = true
        return operation
      end
    end
  end

  before_each(function()
    env = harness.boot()
    hollow = env.hollow
    pending, list_calls, stat_calls = {}, 0, 0
    setup_host()
    hollow.read_dir = function() error("host source must not use local read_dir") end
    hollow.term.run_domain_process = function() error("host source must not invoke native/domain process") end
  end)

  it("keeps sync APIs immediate and preserves exact host path/name bytes", function()
    local root = "/projects/ "
    local rename, popen = os.rename, io.popen
    os.rename = function() error("host source must not path-probe locally") end
    io.popen = function() error("host source must not start a process") end
    configure({ { resolver = "ssh", domain = "remote", host = host, roots = { root } } })
    assert.are.equal(0, #hollow.ui.workspace.known_workspaces(true))
    os.rename, io.popen = rename, popen
    assert.are.equal(root, pending[1].path)
    pending[1].resolve(list_result({ { name = " alpha " }, { name = "line\nbreak" },
      { name = "bad/name" }, { name = "bad\\name" }, { name = ".." }, { name = "\255" } }, nil, true))
    env.flush_deferred()
    assert.are.equal(4, stat_calls)
    for _, operation in ipairs(pending) do if operation.kind == "stat" then operation.resolve() end end
    local items = hollow.ui.workspace.known_workspaces()
    assert.are.equal(4, #items)
    assert.are.equal(" alpha ", items[1].name)
    assert.are.equal(root .. "/ alpha ", items[1].cwd)
    assert.are.equal("line\nbreak", items[2].name)
    assert.are.equal("bad\\name", items[3].name)
    assert.are.equal("\255", items[4].name)
  end)

  it("follows eof and next_offset even when page is short", function()
    configure({ { host = host, roots = { "/p" } } })
    hollow.ui.workspace.known_workspaces(true)
    pending[1].resolve(list_result({ { name = "one" } }, 7, false))
    env.flush_deferred()
    assert.are.equal(2, #pending)
    assert.are.equal(7, pending[2].opts.offset)
    pending[2].resolve(list_result({ { name = "two" } }, nil, true))
    env.flush_deferred()
    assert.are.equal(2, stat_calls)
  end)

  it("caps stat concurrency at four", function()
    configure({ { host = host, roots = { "/p" } } })
    hollow.ui.workspace.known_workspaces(true)
    local entries = {}
    for i = 1, 20 do entries[i] = { name = "p" .. i } end
    pending[1].resolve(list_result(entries, nil, true))
    env.flush_deferred()
    assert.are.equal(4, stat_calls)
  end)

  it("isolates multiple sources on same host", function()
    configure({ { host = host, roots = { "/one" } }, { host = host, roots = { "/two" } } })
    hollow.ui.workspace.known_workspaces(true)
    pending[1].resolve(list_result({ { name = "same" } }, nil, true)); env.flush_deferred()
    local stat = call_for("stat")
    stat.resolve()
    local second_list = call_for("list", "/two")
    second_list.resolve(list_result({ { name = "same" } }, nil, true)); env.flush_deferred()
    call_for("stat").resolve()
    for _, op in ipairs(pending) do if op.kind == "stat" then op.resolve() end end
    local items = hollow.ui.workspace.known_workspaces()
    assert.are.equal(2, #items)
    assert.are_not.equal(items[1].id, items[2].id)
  end)

  it("cancels and ignores pending operations after reconfiguration", function()
    configure({ { host = host, roots = { "/old" } } })
    hollow.ui.workspace.known_workspaces(true)
    local old = pending[1]
    configure({ { host = host, roots = { "/new" } } })
    assert.is_true(cancel_state.count > 0)
    old.resolve(list_result({ { name = "stale" } }, nil, true))
    assert.are.equal(0, #hollow.ui.workspace.known_workspaces())
  end)

  it("invalidates immediately when host generation changes", function()
    configure({ { host = host, roots = { "/p" } } })
    hollow.ui.workspace.known_workspaces(true)
    local old = pending[1]
    host.generation = "g2"
    assert.are.equal(0, #hollow.ui.workspace.known_workspaces())
    assert.is_true(cancel_state.count > 0)
    old.resolve(list_result({ { name = "stale" } }, nil, true))
  end)

  it("cancels in-flight requests when cache clears", function()
    configure({ { host = host, roots = { "/p" } } })
    hollow.ui.workspace.known_workspaces(true)
    hollow.ui.workspace.clear_cache()
    assert.is_true(cancel_state.count > 0)
    pending[1].resolve(list_result({ { name = "stale" } }, nil, true))
    assert.are.equal(0, #hollow.ui.workspace.known_workspaces())
  end)

  it("caches terminal listing errors for cache ttl", function()
    configure({ { host = host, roots = { "/p" } } })
    hollow.ui.workspace.known_workspaces(true)
    pending[1].reject("unavailable")
    assert.are.equal(0, #hollow.ui.workspace.known_workspaces())
    assert.are.equal(1, list_calls)
  end)

  it("does not rescan after immediate fulfillment or cached publication", function()
    host.fs.list = function() list_calls = list_calls + 1; return { next = function(_, ok) ok(list_result({}, nil, true)) end } end
    configure({ { host = host, roots = { "/p" } } })
    hollow.ui.workspace.known_workspaces(true)
    assert.are.equal(1, list_calls)
    hollow.ui.workspace.known_workspaces()
    assert.are.equal(1, list_calls)
  end)

  it("refreshes open picker items after host scan revision changes", function()
    configure({ { host = host, roots = { "/p" } } })
    local options
    local old_open = hollow.ui.select.open
    hollow.ui.select.open = function(opts) options = opts end
    hollow.ui.workspace.open_switcher()
    hollow.ui.select.open = old_open
    pending[1].resolve(list_result({ { name = "live" } }, nil, true)); env.flush_deferred()
    local op = call_for("stat")
    op.resolve()
    local items = options.items()
    assert.are.equal("live", items[#items].name)
  end)

  it("treats malformed explicit host as host error, never legacy resolver", function()
    local invoked = false
    hollow.term.run_domain_process = function() invoked = true end
    configure({ { host = false, resolver = "ssh", domain = "x", roots = { "/p" } } })
    assert.are.equal(0, #hollow.ui.workspace.known_workspaces())
    assert.is_false(invoked)
  end)

  it("force refresh starts a new scan even when completed cache is fresh", function()
    host.fs.list = function()
      list_calls = list_calls + 1
      return { next = function(_, ok) ok(list_result({}, nil, true)) end }
    end
    configure({ { host = host, roots = { "/p" } } })
    hollow.ui.workspace.known_workspaces(true); env.flush_deferred()
    assert.are.equal(1, list_calls)
    hollow.ui.workspace.known_workspaces(true); env.flush_deferred()
    assert.are.equal(2, list_calls)
  end)

  it("terminates a malformed non-promise without retrying on every query", function()
    host.fs.list = function() list_calls = list_calls + 1; return nil end
    configure({ { host = host, roots = { "/p" } } })
    hollow.ui.workspace.known_workspaces(true); env.flush_deferred()
    hollow.ui.workspace.known_workspaces(); env.flush_deferred()
    assert.are.equal(1, list_calls)
  end)

  it("rejects empty nonterminal pages instead of unbounded pagination", function()
    configure({ { host = host, roots = { "/p" } } })
    hollow.ui.workspace.known_workspaces(true)
    pending[1].resolve(list_result({}, 1, false)); env.flush_deferred()
    hollow.ui.workspace.known_workspaces()
    assert.are.equal(1, list_calls)
  end)

  it("does not merge same named paths from different hosts", function()
    local other = { id = "different", generation = "g1", fs = host.fs }
    configure({ { host = host, roots = { "/p" } }, { host = other, roots = { "/p" } } })
    hollow.ui.workspace.known_workspaces(true)
    pending[1].resolve(list_result({ { name = "same" } }, nil, true)); env.flush_deferred()
    call_for("stat").resolve()
    pending[#pending].resolve(list_result({ { name = "same" } }, nil, true)); env.flush_deferred()
    call_for("stat").resolve()
    local items = {}
    for _, item in ipairs(hollow.ui.workspace.items()) do
      if item.host_id then items[#items + 1] = item end
    end
    assert.are.equal(2, #items)
    assert.are_not.equal(items[1].id, items[2].id)
  end)
end)
