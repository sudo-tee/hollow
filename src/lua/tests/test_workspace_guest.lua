local harness = require("tests.harness")

describe("host-first workspace guests", function()
  local env, hollow, calls, hosts, warnings, pending
  local function resolved(value)
    return hollow.async.promise(function(resolve) resolve(value) end)
  end
  local function make_host(id)
    local host = { id = id, generation = "g1", closed = false, lists = {}, fs = {} }
    function host:status() return self.closed and "disconnected" or "ready" end
    function host:close() self.closed = true end
    function host.fs.list(path)
      host.lists[#host.lists + 1] = path
      return resolved({ entries = { { name = "project" } }, eof = true })
    end
    function host.fs.stat() return resolved({ kind = "directory" }) end
    return host
  end
  local function connector(kind)
    return function(opts)
      calls[#calls + 1] = { kind = kind, opts = opts }
      local host = make_host(kind .. #calls)
      hosts[#hosts + 1] = host
      return resolved(host)
    end
  end
  local function items(force)
    hollow.ui.workspace.known_workspaces(force)
    env.flush_deferred()
    return hollow.ui.workspace.known_workspaces()
  end
  before_each(function()
    env = harness.boot()
    hollow = env.hollow
    calls, hosts, warnings, pending = {}, {}, {}, {}
    hollow.ui.notify.warn = function(message) warnings[#warnings + 1] = message end
    hollow.host.wsl = connector("wsl")
    hollow.host.ssh = connector("ssh")
    hollow.host.podman = connector("podman")
    hollow.host.docker = connector("docker")
    hollow.host.local_host = connector("local")
    hollow.read_dir = function() error("legacy local scanning is forbidden") end
    hollow.term.run_domain_process = function() error("legacy SSH scanning is forbidden") end
  end)

  it("uses the native-local host by default, asynchronously", function()
    hollow.ui.workspace.configure({ sources = { { roots = { "C:/code" } } } })
    assert.are.equal("local", calls[1].kind)
    local result = items(true)
    assert.are.equal("C:/code/project", result[1].cwd)
    assert.are.equal("host", result[1].source)
    assert.are.equal(0, #warnings)
  end)

  it("shares persistent guest connections across sources, refreshes and reconfiguration", function()
    local sources = {
      { host = { type = "wsl", distro = "Ubuntu" }, roots = { "/one" } },
      { host = { distro = "Ubuntu", type = "wsl" }, roots = { "/two" } },
    }
    hollow.ui.workspace.configure({ sources = sources })
    assert.are.equal(2, #items(true))
    items(true)
    hollow.ui.workspace.clear_cache()
    items()
    hollow.ui.workspace.configure({ sources = sources })
    items(true)
    assert.are.equal(1, #calls)
    assert.is_false(hosts[1].closed)
    assert.are.equal("wsl", sources[1].host.type)
    assert.is_nil(sources[1].host.id)
  end)

  it("publishes a pending connection without falling back to local scans", function()
    local resolve
    hollow.host.wsl = function()
      calls[#calls + 1] = true
      return hollow.async.promise(function(r) resolve = r end)
    end
    hollow.ui.workspace.configure({ sources = { { host = { type = "wsl", distro = "Ubuntu" }, roots = { "/p" } } } })
    assert.are.equal(0, #items())
    items()
    assert.are.equal(1, #calls)
    resolve(make_host("ready"))
    assert.are.equal("/p/project", items()[1].cwd)
    assert.are.equal(0, #warnings)
  end)

  it("closes unused owned guests, but never borrowed ready/local hosts", function()
    local borrowed = make_host("borrowed")
    hollow.ui.workspace.configure({ sources = {
      { host = { type = "wsl", distro = "Ubuntu" }, roots = { "/p" } },
      { host = borrowed, roots = { "/borrowed" } },
      { roots = { "/local" } },
    } })
    local guest, local_host = hosts[1], hosts[2]
    hollow.ui.workspace.configure({ sources = {} })
    assert.is_true(guest.closed)
    assert.is_false(local_host.closed)
    assert.is_false(borrowed.closed)
  end)

  it("refreshes an already-open picker when bootstrap becomes ready", function()
    local resolve, options
    hollow.host.wsl = function()
      return hollow.async.promise(function(r) resolve = r end)
    end
    hollow.ui.select.open = function(opts) options = opts end
    hollow.ui.workspace.configure({ sources = { { host = { type = "wsl", distro = "Ubuntu" }, roots = { "/p" } } } })
    hollow.ui.workspace.open_switcher()
    assert.are.equal(1, #options.items()) -- Existing open workspace only.
    resolve(make_host("picker"))
    options.items() -- Connection revision starts asynchronous directory discovery.
    env.flush_deferred()
    assert.are.equal(2, #options.items())
    assert.are.equal("/p/project", options.items()[2].cwd)
  end)

  it("cancels removed bootstrap and closes any late guest completion", function()
    local resolve, cancelled
    hollow.host.wsl = function()
      local promise = hollow.async.promise(function(r) resolve = r end)
      function promise:cancel() cancelled = true end
      return promise
    end
    hollow.ui.workspace.configure({ sources = { { host = { type = "wsl", distro = "Ubuntu" }, roots = { "/p" } } } })
    hollow.ui.workspace.configure({ sources = {} })
    assert.is_true(cancelled)
    local late = make_host("late")
    resolve(late)
    assert.is_true(late.closed)
    assert.are.equal(0, #items())
  end)

  it("does not retry failed bootstrap on every scan; clear_cache explicitly retries", function()
    hollow.host.wsl = function()
      calls[#calls + 1] = true
      return hollow.async.promise(function(_, reject) reject({ code = "io_error", message = "offline" }) end)
    end
    hollow.ui.workspace.configure({ sources = { { host = { type = "wsl", distro = "Ubuntu" }, roots = { "/p" } } } })
    items(); items(true); items()
    assert.are.equal(1, #calls)
    assert.are.equal(1, #warnings)
    hollow.host.wsl = connector("wsl")
    hollow.ui.workspace.clear_cache()
    assert.are.equal("/p/project", items()[1].cwd)
    assert.are.equal(2, #calls)
  end)

  it("keeps disconnected hosts until explicit retry, without replaying work", function()
    hollow.ui.workspace.configure({ sources = { { host = { type = "wsl", distro = "Ubuntu" }, roots = { "/p" } } } })
    hosts[1].closed = true
    items(true)
    assert.are.equal(1, #calls)
    hollow.ui.workspace.clear_cache()
    items()
    assert.are.equal(2, #calls)
  end)

  it("supports SSH, Podman and Docker descriptors with copied connector options", function()
    for _, kind in ipairs({ "ssh", "podman", "docker" }) do
      local spec = { type = kind, destination = "build", container = "dev", timeout_ms = 1000 }
      hollow.ui.workspace.configure({ sources = { { host = spec, roots = { "/p" }, domain = "shell" } } })
      assert.are.equal("shell", items(true)[1].domain)
      assert.are.equal(kind, calls[#calls].kind)
      assert.is_nil(calls[#calls].opts.type)
      assert.are.equal(1000, calls[#calls].opts.timeout_ms)
      assert.are.equal(kind, spec.type)
    end
  end)

  it("does not start disabled or items-only guest sources", function()
    hollow.ui.workspace.configure({ sources = {
      { host = { type = "wsl", distro = "Ubuntu" }, roots = { "/p" }, default = false },
      { host = { type = "ssh", destination = "build" }, items = function() return { { name = "manual" } } end },
    } })
    assert.are.equal("manual", items()[1].name)
    assert.are.equal(0, #calls)
  end)

  it("migrates UNC config in memory, warning once about deployment and replacement", function()
    local raw = { name = "Ubuntu", domain = "UbuntuWSL", cwd_resolver = "wsl_unc",
      roots = { "\\\\wsl$\\Ubuntu\\home\\me\\projects" } }
    hollow.ui.workspace.configure({ sources = { raw } })
    local result = items(true)
    assert.are.equal("Ubuntu", calls[1].opts.distro)
    assert.are.equal("/home/me/projects/project", result[1].cwd)
    assert.are.equal("UbuntuWSL", result[1].domain)
    assert.is_nil(raw.host)
    assert.are.equal("wsl_unc", raw.cwd_resolver)
    assert.are.equal(1, #warnings)
    assert.matches("deploy", warnings[1])
    assert.matches("host =", warnings[1], 1, true)
    items(true)
    hollow.ui.workspace.configure({ sources = { raw } })
    assert.are.equal(1, #warnings)
    assert.are.equal(1, #calls)
  end)

  it("migrates legacy WSL and SSH resolvers using structured domains", function()
    hollow.config.set({ domains = {
      ubuntu = { wsl_distro = "Ubuntu" },
      build = { ssh = { alias = "trusted-alias", user = "alice" } },
    } })
    hollow.ui.workspace.configure({ sources = {
      { resolver = "wsl", domain = "ubuntu", roots = { "/p" } },
      { resolver = "ssh", domain = "build", roots = { "/srv" } },
    } })
    assert.are.equal(2, #items(true))
    assert.are.equal("Ubuntu", calls[1].opts.distro)
    assert.are.equal("trusted-alias", calls[2].opts.destination)
    assert.are.equal("alice", calls[2].opts.user)
  end)

  it("rejects ambiguous SSH, mixed distros, and mismatched domains without fallback", function()
    hollow.config.set({ domains = {
      other = { wsl_distro = "Other" },
      linux_ssh = { ssh = { backend = "wsl", host = "build" } },
    } })
    hollow.ui.workspace.configure({ sources = {
      { resolver = "ssh", domain = "unknown", roots = { "/p" } },
      { roots = { "\\\\wsl$\\Ubuntu\\p", "\\\\wsl$\\Other\\p" } },
      { domain = "other", roots = { "\\\\wsl$\\Ubuntu\\p" } },
      { roots = { "\\\\wsl$\\Ubuntu\\p", "C:/local" } },
      { resolver = "wsl", name = "Ubuntu", domain = "other", roots = { "/p" } },
      { resolver = "ssh", domain = "linux_ssh", roots = { "/p" } },
    } })
    assert.are.equal(0, #items(true))
    assert.are.equal(0, #calls)
    assert.are.equal(6, #warnings)
    items()
    assert.are.equal(6, #warnings)
  end)

  it("does not reinterpret explicit ready hosts through legacy domain settings", function()
    hollow.config.set({ domains = { remote = { ssh = { backend = "wsl", host = "build" } } } })
    local ready = make_host("caller")
    hollow.ui.workspace.configure({ sources = { { host = ready, domain = "remote", resolver = "ssh", roots = { "/p" } } } })
    assert.are.equal("/p/project", items(true)[1].cwd)
    assert.are.equal(0, #calls)
    assert.is_false(ready.closed)
  end)

  it("never interprets explicit host-native roots as UNC configuration", function()
    local ready = make_host("opaque")
    local root = "//wsl$/Ubuntu/literal"
    hollow.ui.workspace.configure({ sources = { { host = ready, roots = { root } } } })
    assert.are.equal(root .. "/project", items(true)[1].cwd)
    assert.are.equal(root, ready.lists[1])
    assert.are.equal(0, #warnings)
  end)

  it("honors explicit local resolvers even when pane domain is remote", function()
    hollow.config.set({ domains = { remote = { ssh = { backend = "wsl", host = "build" } } } })
    hollow.ui.workspace.configure({ sources = { { resolver = "local", domain = "remote", roots = { "C:/code" } } } })
    assert.are.equal("C:/code/project", items(true)[1].cwd)
    assert.are.equal("local", calls[1].kind)
  end)

  it("migrates a distro-root UNC path to the Linux filesystem root", function()
    hollow.ui.workspace.configure({ sources = { { roots = { "\\\\wsl.localhost\\Ubuntu" } } } })
    assert.are.equal("/project", items(true)[1].cwd)
    assert.are.equal("Ubuntu", calls[1].opts.distro)
  end)

  it("migrates project_roots through the same host discovery path", function()
    hollow.ui.workspace.configure({ project_roots = { "/projects" } })
    assert.are.equal("/projects/project", items(true)[1].cwd)
    assert.are.equal("local", calls[1].kind)
    assert.are.equal(1, #warnings)
    hollow.ui.workspace.configure({ project_roots = {} })
    assert.are.equal(0, #items())
  end)

  it("preserves custom cwd conversion only in the compatibility adapter", function()
    hollow.ui.workspace.configure({ sources = { {
      host = make_host("custom"), roots = { "/p" },
      cwd_resolver = function(cwd) return cwd .. "/child" end,
    } } })
    assert.are.equal("/p/project/child", items(true)[1].cwd)
  end)
end)
