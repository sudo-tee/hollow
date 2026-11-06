package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("on-demand workspace domains", function()
  local env, hollow, opts, connects, lists, stats, queries, closed, hosts
  local function deferred()
    local resolve, reject
    local promise = hollow.async.promise(function(r, e)
      resolve, reject = r, e
    end)
    function promise:cancel()
      reject("Canceled")
    end
    return promise, resolve, reject
  end
  local function rows(kind, domain)
    local out = {}
    for _, item in ipairs(opts.items()) do
      if (not kind or item.source == kind) and (not domain or item.domain == domain) then
        out[#out + 1] = item
      end
    end
    return out
  end
  local function select(item)
    opts.actions[1].fn(item)
  end
  local function host()
    local value = { id = "remote-" .. #hosts, generation = "1", fs = {}, closed = false }
    function value:status()
      return self.closed and "closed" or "ready"
    end
    function value:close()
      self.closed = true
      closed = closed + 1
    end
    function value.fs.list(root, options)
      local p, resolve, reject = deferred()
      lists[#lists + 1] = { root = root, opts = options, resolve = resolve, reject = reject }
      return p
    end
    function value.fs.stat(path)
      local p, resolve, reject = deferred()
      stats[#stats + 1] = { path = path, resolve = resolve, reject = reject }
      return p
    end
    return value
  end

  before_each(function()
    env = harness.boot()
    hollow = env.hollow
    connects, lists, stats, queries, hosts, closed = {}, {}, {}, {}, {}, 0
    hollow.config.set({
      default_domain = "main",
      domains = {
        main = { shell = "sh" },
        remote = { persist = true, host = { type = "ssh", destination = "box" } },
      },
    })
    hollow.host.ssh = function()
      local p, resolve = deferred()
      connects[#connects + 1] = {
        resolve = function()
          local value = host()
          hosts[#hosts + 1] = value
          resolve(value)
        end,
      }
      return p
    end
    hollow.term.list_sessions = function(value)
      queries[#queries + 1] = value
      return true
    end
    hollow.ui.workspace.configure({
      sources = {
        {
          name = "SSH projects",
          domain = "remote",
          host = { type = "ssh", destination = "box" },
          roots = { "/projects" },
        },
      },
    })
    hollow.ui.select.open = function(value)
      opts = value
      opts.on_mount()
    end
    hollow.ui.workspace.open_switcher()
  end)

  it("starts neither SSH session listing nor project discovery until one explicit load", function()
    assert.equals(0, #connects)
    assert.equals(0, #queries)
    hollow.ui.workspace.items()
    hollow.ui.workspace.known_workspaces(true)
    assert.equals(0, #connects)
    local load = rows("session_load", "remote")[1]
    assert.equals("Load sessions and projects", load.name)
    select(load)
    assert.equals(1, #queries)
    assert.equals(1, #connects)
    assert.equals("Loading sessions and projects…", rows("session_load", "remote")[1].name)
    select(rows("session_load", "remote")[1])
    assert.equals(1, #connects)
    assert.equals(1, #queries)
  end)

  it("discovers configured SSH roots with bounded stats and original domain routing", function()
    select(rows("session_load", "remote")[1])
    connects[1].resolve()
    assert.equals("/projects", lists[1].root)
    local entries = {}
    for i = 1, 8 do
      entries[i] = { name = "project" .. i }
    end
    lists[1].resolve({ entries = entries, eof = true })
    assert.equals(4, #stats)
    -- Promises may complete out of order; each result must still be retained.
    for i = 4, 1, -1 do
      stats[i].resolve({ kind = i == 2 and "file" or "directory" })
    end
    assert.equals(8, #stats)
    for i = 5, 8 do
      stats[i].resolve({ kind = "directory" })
    end
    queries[1].on_complete({ success = true, sessions = {} })
    local projects = rows("host", "remote")
    assert.equals(7, #projects)
    assert.equals("/projects/project1", projects[1].cwd)
    assert.equals("No sessions", rows("session_load", "remote")[1].name)
    assert.equals(0, #rows("project_load", "remote"))
    assert.equals(1, closed)
    hollow.ui.workspace.open_switcher()
    assert.equals(1, #connects)
    assert.equals(1, #queries)
    assert.equals(7, #hollow.ui.workspace.known_workspaces())
  end)

  it("keeps empty project and session results visible", function()
    select(rows("session_load", "remote")[1])
    connects[1].resolve()
    lists[1].resolve({ entries = {}, eof = true })
    queries[1].on_complete({ success = true, sessions = {} })
    assert.equals("No projects", rows("project_load", "remote")[1].name)
    assert.equals("No sessions", rows("session_load", "remote")[1].name)
  end)

  it("ends stuck loads, cancels owned work, and fences stale callbacks after retry", function()
    select(rows("session_load", "remote")[1])
    connects[1].resolve()
    env.recorded.now_ms = env.recorded.now_ms + 16000
    assert.equals("failed", rows("project_load", "remote")[1].load_state)
    assert.equals(1, closed)
    select(rows("project_load", "remote")[1])
    assert.equals(2, #connects)
    lists[1].resolve({ entries = { "stale" }, eof = true })
    queries[1].on_complete({ success = true, sessions = { { id = "stale", panes = {} } } })
    assert.equals(0, #rows("host", "remote"))
    assert.equals("loading", rows("session_load", "remote")[1].load_state)
    connects[2].resolve()
    lists[2].resolve({ entries = {}, eof = true })
    queries[2].on_complete({ success = true, sessions = {} })
    assert.equals("No projects", rows("project_load", "remote")[1].name)
  end)

  it("invalidates project work when sources are reconfigured", function()
    select(rows("session_load", "remote")[1])
    connects[1].resolve()
    hollow.ui.workspace.configure({ sources = {} })
    lists[1].resolve({ entries = { "stale" }, eof = true })
    assert.equals(1, closed)
    assert.equals(0, #rows("host", "remote"))
  end)

  it("fences dynamic source changes and reports malformed discovery replies", function()
    local root = "/first"
    hollow.ui.workspace.configure({
      sources = function()
        return {
          { domain = "remote", host = { type = "ssh", destination = "box" }, roots = { root } },
        }
      end,
    })
    select(rows("session_load", "remote")[1])
    connects[1].resolve()
    root = "/second"
    assert.equals("idle", rows("project_load", "remote")[1].load_state)
    lists[1].resolve({ entries = { "stale" }, eof = true })
    select(rows("project_load", "remote")[1])
    connects[2].resolve()
    lists[2].resolve({ entries = {}, eof = false, next_offset = 0 })
    local failed = rows("project_load", "remote")[1]
    assert.equals("failed", failed.load_state)
    assert.is_truthy(failed.cwd:find("Invalid directory cursor", 1, true))
    assert.equals(0, #rows("host", "remote"))
  end)
end)
