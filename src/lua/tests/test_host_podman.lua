local harness = require("tests.harness")

describe("hollow.host.podman", function()
  local env, queue, now

  local function fulfilled(value)
    return require("hollow.async").promise(function(resolve) resolve(value) end)
  end

  local function rejected(error_value)
    return require("hollow.async").promise(function(_, reject) reject(error_value) end)
  end

  local function deferred()
    local resolve, reject
    local promise = require("hollow.async").promise(function(r, j) resolve, reject = r, j end)
    return promise, resolve, reject
  end

  local function result(code, stdout, stderr)
    return { exit_code = code or 0, stdout = stdout or "", stderr = stderr or "" }
  end

  local function fixture(config)
    config = config or {}
    local commands, connects, closes, cancels = {}, {}, {}, 0
    local immutable = config.container_id or string.rep("a", 64)
    local home = config.home or "/home/worker"
    local function execute(argv)
      commands[#commands + 1] = argv
      if argv[1] ~= (config.executable or "podman") then return result(127, "", "missing executable") end
      if argv[2] == "container" and argv[3] == "inspect" then
        if config.inspect_error then return config.inspect_error end
        return result(config.running == false and 0 or 0, immutable .. " " .. (config.running == false and "false" or "true") .. "\n")
      end
      if argv[2] == "exec" and argv[4] == "uname" then return result(0, config.arch or "x86_64\n") end
      if argv[2] == "exec" and argv[4] == "test" and argv[5] == "-x" then
        return config.test_error or result(config.executable_missing and 1 or 0, "", config.executable_missing and "not executable" or "")
      end
      if argv[2] == "exec" and argv[4] == "/bin/sh" then
        local script = argv[6] or ""
        if script:find("$HOME", 1, true) or script:find("HOME", 1, true) then return result(0, home) end
        if script:find("sha256sum", 1, true) then
          if script:find("chmod", 1, true) then
            if config.checksum_error then return result(43, "", "checksum mismatch") end
            return result(0)
          end
          return result(config.cached and 0 or 1)
        end
        if script:find("mktemp", 1, true) then
          local parent = config.temp_parent or home .. "/.cache/hollow/agents/linux-x86_64/" .. string.rep("b", 64)
          return result(0, parent .. "/.upload-abcdef123456\n")
        end
        if script:find("rm -f", 1, true) then return result(0) end
        return result(0)
      end
      if argv[2] == "exec" and argv[4] == "mktemp" then
        return result(0, argv[5]:gsub("XXXXXXXXXXXX$", "abcdef123456") .. "\n")
      end
      if argv[2] == "mkdir" then return result(0) end
      if argv[2] == "cp" then
        if config.cp_error then return result(1, "", "copy failed") end
        return result(0)
      end
      if argv[2] == "exec" and argv[4] == "chmod" then return result(0) end
      return result(0)
    end
    local native = { exec = function(_, options)
      assert.are.equal(16384, options.output_limit)
      assert.is_true(options.timeout_ms > 0)
      if config.exec_deferred_at and #commands + 1 == config.exec_deferred_at then
        local p, resolve, reject = deferred()
        config.pending_exec = { promise = p, resolve = resolve, reject = reject }
        commands[#commands + 1] = options.argv
        return p
      end
      if config.native_error then return rejected(config.native_error) end
      return fulfilled(execute(options.argv))
    end }
    local hosts = {
      local_host = function() return fulfilled(native) end,
      connect = function(options)
        connects[#connects + 1] = options
        if config.connect_error then return rejected(config.connect_error) end
        return fulfilled({ close = function() closes[#closes + 1] = true end })
      end,
    }
    return { hosts = hosts, commands = commands, connects = connects, closes = closes, config = config, native = native }
  end

  local function start(f, opts)
    opts = opts or { id = "agent", container = "worker", agent_path = "/opt/hollow-agent" }
    return require("hollow.host.podman").connect(f.hosts, opts)
  end

  before_each(function()
    env = harness.boot()
    queue, now = {}, 0
    env.host_api.defer = function(fn, delay) queue[#queue + 1] = { fn = fn, delay = delay or 0 } end
    env.host_api.now_ms = function() return now end
  end)

  it("resolves preinstalled agent with immutable container ID and plain connect options", function()
    local f = fixture({ arch = "amd64\n" })
    local p = start(f)
    assert.are.equal("fulfilled", p:status())
    assert.are.same({ id = "agent", argv = { "podman", "exec", "-i", string.rep("a", 64), "/opt/hollow-agent", "stdio" } }, f.connects[1])
    assert.are.equal(string.rep("a", 64), f.commands[2][3])
    assert.are.equal(string.rep("a", 64), f.commands[3][3])
    assert.are.equal(0, #f.closes)
  end)

  it("deep-copies options before async work", function()
    local f = fixture({ exec_deferred_at = 1 })
    local opts = { id = "agent", container = "worker", agent_path = "/opt/agent" }
    local p = start(f, opts)
    assert.are.equal("pending", p:status())
    opts.id, opts.container, opts.agent_path = "changed", "other", "/other"
    f.config.pending_exec.resolve(result(0, string.rep("a", 64) .. " true\n"))
    assert.are.equal("fulfilled", p:status())
    assert.are.equal("worker", f.commands[1][6])
    assert.are.same({ id = "agent", argv = { "podman", "exec", "-i", string.rep("a", 64), "/opt/agent", "stdio" } }, f.connects[1])
  end)

  it("validates all arguments before calling local_host", function()
    local effects = 0
    local hosts = { local_host = function() effects = effects + 1; return fulfilled({}) end, connect = function() effects = effects + 1 end }
    local podman = require("hollow.host.podman")
    for _, opts in ipairs({
      { id = "x", container = "--help", agent_path = "/agent" },
      { id = "x", container = "bad/name", agent_path = "/agent" },
      { id = "x", container = "worker", agent_path = "relative" },
      { id = "x\0y", container = "worker", agent_path = "/agent" },
      { id = "x", container = "worker", timeout_ms = 300001, agent_path = "/agent" },
    }) do assert.has_error(function() podman.connect(hosts, opts) end) end
    assert.are.equal(0, effects)
  end)

  it("rejects malformed artifact hash and path before side effects", function()
    local effects = 0
    local hosts = { local_host = function() effects = effects + 1 end, connect = function() end }
    for _, artifact in ipairs({
      { path = "/tmp/agent", sha256 = string.rep("a", 63) },
      { path = "relative", sha256 = string.rep("a", 64) },
      { path = "/tmp/agent\0bad", sha256 = string.rep("a", 64) },
    }) do
      assert.has_error(function() require("hollow.host.podman").connect(hosts, { id = "x", container = "worker", artifacts = { x86_64 = artifact } }) end)
    end
    assert.are.equal(0, effects)
  end)

  it("supports architecture aliases and rejects unsupported architectures", function()
    for alias in pairs({ amd64 = true, x86_64 = true }) do
      local f = fixture({ arch = alias .. "\n" })
      assert.are.equal("fulfilled", start(f):status())
    end
    for alias in pairs({ arm64 = true, aarch64 = true }) do
      local f = fixture({ arch = alias .. "\n" })
      assert.are.equal("fulfilled", start(f):status())
    end
    local f = fixture({ arch = "riscv64\n" })
    local p = start(f)
    assert.are.equal("unsupported_arch", p:error().code)
    assert.are.equal(0, #f.connects)
  end)

  it("rejects stopped container and never executes inside it", function()
    local f = fixture({ running = false })
    local p = start(f)
    assert.are.equal("container_unavailable", p:error().code)
    assert.are.equal(1, #f.commands)
  end)

  it("maps missing podman and propagates native exec errors", function()
    local f = fixture({ native_error = { code = "not_found", message = "podman missing" } })
    local p = start(f)
    assert.are.equal("connector_unavailable", p:error().code)
    local g = fixture({ native_error = { code = "permission_denied", message = "denied" } })
    local q = start(g)
    assert.are.equal("permission_denied", q:error().code)
  end)

  it("deploys artifact through rootless temporary upload and pinned ID", function()
    local f = fixture({})
    local digest = string.rep("b", 64)
    local p = start(f, { id = "agent", container = "worker", artifacts = { x86_64 = { path = "/tmp/local-agent", sha256 = digest } } })
    assert.are.equal("fulfilled", p:status())
    local cp
    for _, argv in ipairs(f.commands) do if argv[2] == "cp" then cp = argv end end
    assert.is_truthy(cp)
    assert.are.equal("/tmp/local-agent", cp[3])
    assert.is_truthy(cp[4]:match("^" .. string.rep("a", 64) .. ":"))
    for _, argv in ipairs(f.commands) do
      assert.is_not.equal("--user", argv[2])
      assert.is_not.equal("--privileged", argv[2])
      assert.is_not.equal("run", argv[2])
      assert.is_not.equal("rm", argv[2])
    end
    assert.are.same({ id = "agent", argv = { "podman", "exec", "-i", string.rep("a", 64), "/home/worker/.cache/hollow/agents/linux-x86_64/" .. digest .. "/hollow-agent", "stdio" } }, f.connects[1])
  end)

  it("preserves newline bytes in HOME when constructing installed target", function()
    local home = "/home/worker\nwith-newline\n"
    local f = fixture({ home = home })
    local digest = string.rep("c", 64)
    local p = start(f, { id = "agent", container = "worker", artifacts = { x86_64 = { path = "/tmp/a", sha256 = digest } } })
    assert.are.equal("fulfilled", p:status())
    assert.are.equal(home .. "/.cache/hollow/agents/linux-x86_64/" .. digest .. "/hollow-agent", f.connects[1].argv[5])
  end)

  it("fails checksum verification and does not launch connector", function()
    local f = fixture({ checksum_error = true })
    local digest = string.rep("d", 64)
    local p = start(f, { id = "agent", container = "worker", artifacts = { x86_64 = { path = "/tmp/a", sha256 = digest } } })
    assert.are.equal("checksum_mismatch", p:error().code)
    assert.are.equal(0, #f.connects)
    assert.are.equal("rm", f.commands[#f.commands][4])
  end)

  it("reports upload failure without launching connector", function()
    local f = fixture({ cp_error = true })
    local digest = string.rep("e", 64)
    local p = start(f, { id = "agent", container = "worker", artifacts = { x86_64 = { path = "/tmp/a", sha256 = digest } } })
    assert.are.equal("rejected", p:status())
    assert.are.equal("agent_install_unavailable", p:error().code)
    assert.are.equal(0, #f.connects)
    assert.are.equal("rm", f.commands[#f.commands][4])
  end)

  it("reuses only a verified cached executable without copying artifact", function()
    local f = fixture()
    local digest = string.rep("9", 64)
    f.native.exec = function(_, options)
      f.commands[#f.commands + 1] = options.argv
      local argv = options.argv
      if argv[2] == "container" then return fulfilled(result(0, string.rep("a", 64) .. " true\n")) end
      if argv[4] == "uname" then return fulfilled(result(0, "x86_64\n")) end
      if argv[4] == "/bin/sh" and (argv[6] or ""):find("$HOME", 1, true) then return fulfilled(result(0, "/home/worker")) end
      if argv[4] == "/bin/sh" and (argv[6] or ""):find("sha256sum", 1, true) then return fulfilled(result(0, "")) end
      return fulfilled(result(0))
    end
    local p = start(f, { id = "agent", container = "worker", artifacts = { x86_64 = { path = "/tmp/a", sha256 = digest } } })
    assert.are.equal("fulfilled", p:status())
    for _, argv in ipairs(f.commands) do assert.is_not.equal("cp", argv[2]) end
    assert.are.equal(1, #f.connects)
  end)

  it("waits for active upload operation before cleaning its owned temp on cancellation", function()
    local f = fixture()
    local cp_promise, resolve_cp
    local base_exec = f.native.exec
    f.native.exec = function(host, options)
      if options.argv[2] == "cp" then
        cp_promise, resolve_cp = deferred()
        f.commands[#f.commands + 1] = options.argv
        return cp_promise
      end
      return base_exec(host, options)
    end
    local digest = string.rep("8", 64)
    local p = start(f, { id = "agent", container = "worker", artifacts = { x86_64 = { path = "/tmp/a", sha256 = digest } } })
    assert.are.equal("pending", p:status())
    assert.is_true(p:cancel())
    assert.are.equal("cancelled", p:error().code)
    local before = #f.commands
    resolve_cp(result(0))
    assert.is_true(#f.commands > before)
    assert.are.equal(0, #f.connects)
    local cleaned = false
    for _, argv in ipairs(f.commands) do
      if argv[2] == "exec" and argv[4] == "rm" and argv[5] == "-f" and argv[6] == "--" then cleaned = true end
    end
    assert.is_true(cleaned)
  end)

  it("does not connect when final executable check fails", function()
    local f = fixture({ executable_missing = true })
    local p = start(f)
    assert.are.equal("agent_install_unavailable", p:error().code)
    assert.are.equal(0, #f.connects)
  end)

  it("closes a late connector host after cancellation", function()
    local f = fixture()
    local pending, resolve_connect
    f.hosts.connect = function(options)
      f.connects[#f.connects + 1] = options
      pending, resolve_connect = deferred()
      return pending
    end
    local p = start(f)
    assert.are.equal("pending", p:status())
    assert.is_true(p:cancel())
    assert.are.equal("cancelled", p:error().code)
    resolve_connect({ close = function() f.closes[#f.closes + 1] = true end })
    assert.are.equal(1, #f.closes)
  end)

  it("applies one deadline to every exec and rejects at total deadline", function()
    local f = fixture()
    f.config.exec_deferred_at = 1
    local p = start(f, { id = "agent", container = "worker", agent_path = "/opt/agent", timeout_ms = 5 })
    assert.are.equal("pending", p:status())
    now = 6
    local watchdog = table.remove(queue, 1)
    watchdog.fn()
    assert.are.equal("timeout", p:error().code)
    for _, argv in ipairs(f.commands) do assert.are.equal("podman", argv[1]) end
  end)

  it("passes shell paths and digests as argv data, never interpolated", function()
    local f = fixture({ home = "/home/a;touch /tmp/pwned" })
    local digest = string.rep("f", 64)
    local p = start(f, { id = "agent", container = "worker", artifacts = { x86_64 = { path = "/tmp/a;touch /tmp/pwned", sha256 = digest } } })
    assert.are.equal("fulfilled", p:status())
    local shell
    local cp
    for _, argv in ipairs(f.commands) do
      if argv[2] == "exec" and argv[4] == "/bin/sh" and (argv[6] or ""):find("sha256sum", 1, true) then shell = argv end
      if argv[2] == "cp" then cp = argv end
    end
    assert.is_truthy(shell)
    assert.is_truthy(shell[8]:find("/home/a;touch /tmp/pwned", 1, true))
    assert.is_nil(shell[6]:find("/home/a;touch /tmp/pwned", 1, true))
    assert.are.equal(digest, shell[9])
    assert.are.equal("/tmp/a;touch /tmp/pwned", cp[3])
  end)

  it("copies artifact options before architecture discovery completes", function()
    local f = fixture({ exec_deferred_at = 1 })
    local artifact = { path = "/trusted/agent", sha256 = string.rep("a", 64) }
    local opts = { id = "agent", container = "worker", artifacts = { x86_64 = artifact } }
    local p = start(f, opts)
    artifact.path, artifact.sha256 = "/different", string.rep("f", 64)
    f.config.pending_exec.resolve(result(0, string.rep("a", 64) .. " true\n"))
    assert.are.equal("fulfilled", p:status())
    local cp
    for _, argv in ipairs(f.commands) do if argv[2] == "cp" then cp = argv end end
    assert.are.equal("/trusted/agent", cp[3])
    assert.is_truthy(f.connects[1].argv[5]:find(string.rep("a", 64), 1, true))
  end)

  it("rejects a failed final protocol handshake", function()
    local f = fixture({ connect_error = { code = "protocol_mismatch", message = "incompatible agent" } })
    local p = start(f)
    assert.are.equal("rejected", p:status())
    assert.are.equal("agent_install_unavailable", p:error().code)
    assert.are.equal("incompatible agent", p:error().message)
  end)

  it("does not cancel the shared native-local connection", function()
    local f = fixture()
    local pending, resolve = deferred()
    local cancels = 0
    function pending:cancel() cancels = cancels + 1 end
    f.hosts.local_host = function() return pending end
    local p = start(f)
    p:cancel()
    resolve(f.native)
    assert.are.equal(0, cancels)
    assert.are.equal(0, #f.commands)
    assert.are.equal("cancelled", p:error().code)
  end)
end)
