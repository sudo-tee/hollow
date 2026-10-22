local harness = require("tests.harness")

describe("asynchronous project bootstrap", function()
  local env, queue, reads, pending, bootstraps, current_workspace, current_pane
  local connections, read_hosts, closed, guest
  local function drain()
    while #queue > 0 do table.remove(queue, 1)() end
  end

  before_each(function()
    env = harness.boot()
    queue, reads, pending, bootstraps = {}, {}, {}, {}
    connections, read_hosts, closed = {}, {}, 0
    current_workspace = { id = 10 }
    current_pane = { id = 101, domain = "UbuntuWSL" }
    env.hollow.term.current_workspace = function() return current_workspace end
    env.hollow.term.current_pane = function() return current_pane end
    env.hollow.config.set({
      domains = { UbuntuWSL = { host = { type = "wsl", distro = "Ubuntu" } } },
      workspace = { default_layout = "/config/layouts/default.json" },
    })
    env.host_api.defer = function(fn) queue[#queue + 1] = fn end
    env.host_api.path_exists = function() error("UI thread must not probe files") end
    env.host_api.read_file = function() error("UI thread must not read files") end
    env.host_api.json_decode = function(text)
      if text ~= "layout" then error("invalid JSON") end
      return { tabs = {} }
    end
    env.hollow.workspace.bootstrap = function(spec, opts)
      bootstraps[#bootstraps + 1] = { spec = spec, opts = opts }
    end
    local function make_host(name)
      local host = { fs = {} }
      function host:close() closed = closed + 1 end
      function host:status() return "ready" end
      host.fs.read = function(path)
        reads[#reads + 1] = path
        read_hosts[#read_hosts + 1] = name
        return env.hollow.async.promise(function(resolve, reject)
          pending[#pending + 1] = { resolve = resolve, reject = reject }
        end)
      end
      return host
    end
    guest = make_host("guest")
    local host = make_host("local")
    require("hollow.host").local_host = function()
      return env.hollow.async.promise(function(resolve) resolve(host) end)
    end
    for _, kind in ipairs({ "wsl", "ssh", "docker", "podman" }) do
      env.hollow.host[kind] = function(opts)
        connections[#connections + 1] = { kind = kind, opts = opts }
        return env.hollow.async.promise(function(resolve) resolve(guest) end)
      end
    end
  end)

  it("reads project layout asynchronously through agent with guest-native paths", function()
    env.hollow.workspace.project_local_path = function() error("must not convert to UNC") end
    local result = env.hollow.workspace.bootstrap_project_async("/project")
    assert.are.equal("pending", result:status())
    assert.are.equal(0, #reads)
    drain()
    assert.are.equal("/project/.hollow/workspace.json", reads[1])
    assert.are.equal("guest", read_hosts[1])
    assert.are.equal(0, #bootstraps)
    pending[1].resolve({ bytes = "layout", eof = true })
    assert.is_true(result:value())
    assert.are.equal(1, #reads)
    assert.are.equal(1, #bootstraps)
    assert.are.equal("/project", bootstraps[1].opts.base_dir)
    assert.is_false(bootstraps[1].opts.replace_current)
    assert.are.equal(1, closed)
  end)

  it("uses WSL host distro rather than terminal domain label for lookup", function()
    env.hollow.config.set({ domains = {
      UbuntuWSL = { host = { type = "wsl", distro = "Ubuntu-26.04" } },
    } })
    env.hollow.workspace.bootstrap_project_async("/project")
    drain()
    assert.are.equal("/project/.hollow/workspace.json", reads[1])
    assert.are.equal("Ubuntu-26.04", connections[1].opts.distro)
  end)

  it("loads default layout asynchronously when project layout is absent", function()
    local result = env.hollow.workspace.bootstrap_project_async("/project")
    drain()
    pending[1].reject({ code = "not_found" })
    drain()
    assert.are.equal("/config/layouts/default.json", reads[2])
    assert.are.same({ "guest", "local" }, read_hosts)
    pending[2].resolve({ bytes = "layout", eof = true })
    assert.is_true(result:value())
    assert.are.equal("/config/layouts", bootstraps[1].opts.base_dir)
  end)

  it("reuses discovery host and does not close its borrowed connection", function()
    require("hollow.workspace.hosts").prepare({ {
      host = { type = "wsl", distro = "Ubuntu" }, roots = { "/projects" },
    } })
    local result = env.hollow.workspace.bootstrap_project_async("/project")
    drain()
    pending[1].resolve({ bytes = "layout", eof = true })
    assert.is_true(result:value())
    assert.are.equal(1, #connections)
    assert.are.equal(0, closed)
  end)

  it("keeps borrowed discovery host alive until layout read finishes", function()
    local hosts = require("hollow.workspace.hosts")
    hosts.prepare({ {
      host = { type = "wsl", distro = "Ubuntu" }, roots = { "/projects" },
    } })
    local result = env.hollow.workspace.bootstrap_project_async("/project")
    drain()
    hosts.prepare({})
    assert.are.equal(0, closed)
    pending[1].resolve({ bytes = "layout", eof = true })
    assert.is_true(result:value())
    assert.are.equal(1, closed)
  end)

  it("uses agent for legacy WSL domain without UNC conversion", function()
    env.hollow.platform.is_windows = true
    env.hollow.config.set({ domains = { LegacyWSL = {
      wsl_distro = "Ubuntu", shell = "wsl.exe -d Ubuntu -u francis",
    } } })
    env.hollow.workspace.bootstrap_project_async("/project", "LegacyWSL")
    drain()
    assert.are.equal("/project/.hollow/workspace.json", reads[1])
    assert.are.equal("guest", read_hosts[1])
    assert.are.equal("Ubuntu", connections[1].opts.distro)
    assert.are.equal("francis", connections[1].opts.user)
  end)

  it("never reads local project or default layout on agent connection failure", function()
    env.hollow.host.wsl = function()
      return env.hollow.async.promise(function(_, reject)
        reject({ code = "transport_disconnected", message = "offline" })
      end)
    end
    local result = env.hollow.workspace.bootstrap_project_async("/project")
    drain()
    assert.are.equal("transport_disconnected", result:error().code)
    assert.are.equal(0, #reads)
  end)

  it("awaits a pending connection before reading and releases it afterward", function()
    local connected
    env.hollow.host.wsl = function()
      return env.hollow.async.promise(function(resolve) connected = resolve end)
    end
    local result = env.hollow.workspace.bootstrap_project_async("/project")
    assert.are.equal("pending", result:status())
    assert.are.equal(0, #reads)
    connected(guest)
    drain()
    pending[1].resolve({ bytes = "layout", eof = true })
    assert.is_true(result:value())
    assert.are.equal(1, closed)
  end)

  it("rejects bootstrap exceptions instead of leaving the promise pending", function()
    env.hollow.workspace.bootstrap = function() error("bootstrap failed") end
    local result = env.hollow.workspace.bootstrap_project_async("/project")
    drain()
    pending[1].resolve({ bytes = "layout", eof = true })
    assert.are.equal("rejected", result:status())
    assert.matches("bootstrap failed", result:error(), 1, true)
    assert.are.equal(1, closed)
  end)

  it("does not fall back to client files on guest I/O failure", function()
    local result = env.hollow.workspace.bootstrap_project_async("/project")
    drain()
    pending[1].reject({ code = "permission_denied" })
    assert.are.equal("permission_denied", result:error().code)
    assert.are.same({ "guest" }, read_hosts)
    assert.are.equal(1, closed)
  end)

  it("supports SSH and container hosts without changing host-native paths", function()
    for _, kind in ipairs({ "ssh", "docker", "podman" }) do
      env.hollow.config.set({ domains = { UbuntuWSL = { host = { type = kind } } } })
      local result = env.hollow.workspace.bootstrap_project_async("/srv/project")
      drain()
      assert.are.equal("/srv/project/.hollow/workspace.json", reads[#reads])
      assert.are.equal("guest", read_hosts[#read_hosts])
      assert.are.equal(kind, connections[#connections].kind)
      pending[#pending].resolve({ bytes = "layout", eof = true })
      assert.is_true(result:value())
    end
  end)

  it("uses native-local worker for a local terminal domain", function()
    env.hollow.config.set({ domains = { UbuntuWSL = { host = false } } })
    local result = env.hollow.workspace.bootstrap_project_async("/project")
    drain()
    assert.are.equal("local", read_hosts[1])
    assert.are.equal(0, #connections)
    pending[1].resolve({ bytes = "layout", eof = true })
    assert.is_true(result:value())
  end)

  it("resolves false when neither layout exists", function()
    local result = env.hollow.workspace.bootstrap_project_async("/project")
    drain()
    pending[1].reject({ code = "not_found" })
    drain()
    pending[2].reject({ code = "not_found" })
    assert.is_false(result:value())
    assert.are.equal(0, #bootstraps)
  end)

  it("rejects invalid project layouts without silently loading default", function()
    local result = env.hollow.workspace.bootstrap_project_async("/project")
    drain()
    pending[1].resolve({ bytes = "invalid", eof = true })
    assert.are.equal("invalid_argument", result:error().code)
    assert.are.equal(1, #reads)
    assert.are.equal(0, #bootstraps)
  end)

  it("does not apply late layouts to another workspace or pane", function()
    for _, change in ipairs({ "workspace", "pane" }) do
      current_workspace, current_pane = { id = 10 }, { id = 101, domain = "UbuntuWSL" }
      local result = env.hollow.workspace.bootstrap_project_async("/project")
      drain()
      if change == "workspace" then current_workspace = { id = 11 }
      else current_pane = { id = 102 } end
      pending[#pending].resolve({ bytes = "layout", eof = true })
      assert.is_false(result:value())
    end
    assert.are.equal(0, #bootstraps)
  end)

  it("does not start fallback lookup after workspace closes", function()
    local result = env.hollow.workspace.bootstrap_project_async("/project")
    drain()
    current_workspace = nil
    pending[1].reject({ code = "not_found" })
    drain()
    assert.is_false(result:value())
    assert.are.equal(1, #reads)
  end)
end)
