local harness = require("tests.harness")

describe("hollow.host.wsl", function()
  local env, queue, now

  local function fulfilled(value)
    return require("hollow.async").promise(function(resolve) resolve(value) end)
  end

  local function rejected(err)
    return require("hollow.async").promise(function(_, reject) reject(err) end)
  end

  local function deferred()
    local resolve, reject
    local promise = require("hollow.async").promise(function(r, j) resolve, reject = r, j end)
    return promise, resolve, reject
  end

  local function result(code, stdout, stderr)
    return { exit_code = code or 0, stdout = stdout or "", stderr = stderr or "" }
  end

  local function remote(argv)
    local exec
    for i, value in ipairs(argv) do if value == "--exec" then exec = i; break end end
    assert.is_truthy(exec, "native WSL command must use --exec")
    local out = {}
    for i = exec + 1, #argv do out[#out + 1] = argv[i] end
    return out
  end

  local function fixture(config)
    config = config or {}
    local calls, connects, closes = {}, {}, {}
    local native = { exec = function(_, options)
      assert.are.equal(16384, options.output_limit)
      assert.is_true(options.timeout_ms > 0)
      local argv = options.argv
      calls[#calls + 1] = { argv = argv, timeout_ms = options.timeout_ms }
      local args = remote(argv)
      local command = args[1]
      if config.pending_at and #calls == config.pending_at then
        local p, resolve, reject = deferred()
        config.pending = { promise = p, resolve = resolve, reject = reject, cancels = 0 }
        function p:cancel() config.pending.cancels = config.pending.cancels + 1 end
        return p
      end
      if config.native_error then return rejected(config.native_error) end
      if command == "uname" then return fulfilled(config.uname_error or result(0, config.arch or "x86_64\n")) end
      if command == "test" then return fulfilled(config.test_error or result(config.missing and 1 or 0)) end
      if command == "/bin/sh" then
        local script = args[3] or ""
        if script:find('printf "%s" "$HOME"', 1, true) then return fulfilled(result(0, config.home or "/home/worker")) end
        if script:find("sha256sum", 1, true) then
          if script:find("chmod", 1, true) and config.checksum_error then return fulfilled(result(43, "", "checksum mismatch")) end
          if script:find("chmod", 1, true) then return fulfilled(result(0)) end
          return fulfilled(result(config.cached and 0 or 1))
        end
        return fulfilled(result(0))
      end
      if command == "mktemp" then return fulfilled(result(0, (config.temp_path or (args[2]:gsub("X+$", "abcdef123456"))) .. "\n")) end
      if command == "wslpath" then return fulfilled(result(config.wslpath_code or 0, config.mapped or "/mnt/c/agent\n", config.wslpath_error or "")) end
      if command == "cp" then return fulfilled(config.cp_error and result(1, "", "copy failed") or result(0)) end
      return fulfilled(result(0))
    end }
    local hosts = {
      local_host = function() return config.local_error and rejected(config.local_error) or fulfilled(native) end,
      connect = function(options)
        connects[#connects + 1] = options
        if config.pending_connect then
          local p, resolve = deferred()
          config.resolve_connect = resolve
          return p
        end
        if config.connect_error then return rejected(config.connect_error) end
        return fulfilled({ close = function() closes[#closes + 1] = true end })
      end,
    }
    return { hosts = hosts, calls = calls, connects = connects, closes = closes, config = config, native = native }
  end

  local function start(f, opts)
    return require("hollow.host.wsl").connect(f.hosts, opts or { id = "agent", distro = "Ubuntu", agent_path = "/opt/hollow-agent" })
  end

  local function find_call(f, predicate)
    for _, call in ipairs(f.calls) do if predicate(remote(call.argv)) then return remote(call.argv), call end end
  end

  before_each(function()
    env = harness.boot()
    queue, now = {}, 0
    env.host_api.defer = function(fn, delay) queue[#queue + 1] = { fn = fn, delay = delay or 0 } end
    env.host_api.now_ms = function() return now end
  end)

  it("uses exact WSL argument boundaries and preserves configured user and distro bytes", function()
    local distro, user = "Ubuntu 'quoted'\n\255", "user name'\n\255"
    local f = fixture()
    assert.are.equal("fulfilled", start(f, { id = "x", distro = distro, user = user, wsl = "wsl-custom.exe", agent_path = "/agent with spaces'\n\255" }):status())
    assert.are.same({ "wsl-custom.exe", "--distribution", distro, "--user", user, "--cd", "/", "--exec", "uname", "-m" }, f.calls[1].argv)
    assert.are.same({ id = "x", argv = { "wsl-custom.exe", "--distribution", distro, "--user", user, "--cd", "/", "--exec", "/agent with spaces'\n\255", "stdio" } }, f.connects[1])
    for _, call in ipairs(f.calls) do
      for _, forbidden in ipairs({ "--pty", "-t", "--import", "--install", "--unregister", "--terminate", "--shutdown" }) do
        for _, value in ipairs(call.argv) do assert.are_not.equal(forbidden, value) end
      end
    end
  end)

  it("omits user flag by default and does not imply root or a default distro", function()
    local f = fixture()
    start(f, { id = "x", distro = "MyDistro", agent_path = "/agent" })
    assert.are.same({ "wsl.exe", "--distribution", "MyDistro", "--cd", "/", "--exec", "uname", "-m" }, f.calls[1].argv)
    assert.are.equal("MyDistro", f.calls[1].argv[3])
    assert.is_nil(f.calls[1].argv[4] == "--user" and f.calls[1].argv[5] or nil)
  end)

  it("validates distro and user before native effects", function()
    local effects = 0
    local hosts = { local_host = function() effects = effects + 1 end, connect = function() effects = effects + 1 end }
    for _, opts in ipairs({
      { id = "x", agent_path = "/agent" },
      { id = "x", distro = "--help", agent_path = "/agent" },
      { id = "x", distro = "bad\0distro", agent_path = "/agent" },
      { id = "x", distro = "Ubuntu", user = "-root", agent_path = "/agent" },
      { id = "x", distro = "Ubuntu", user = "bad\0user", agent_path = "/agent" },
    }) do assert.has_error(function() require("hollow.host.wsl").connect(hosts, opts) end) end
    assert.are.equal(0, effects)
  end)

  it("deep-copies distro, user, and artifact path before async uname", function()
    local f = fixture({ pending_at = 1 })
    local opts = { id = "x", distro = "Ubuntu", user = "alice", artifacts = { x86_64 = { path = "/trusted/agent", sha256 = string.rep("b", 64) } } }
    local p = start(f, opts)
    opts.distro, opts.user, opts.artifacts.x86_64.path = "Other", "bob", "/mutated"
    f.config.pending.resolve(result(0, "x86_64\n"))
    assert.are.equal("fulfilled", p:status(), p:error() and p:error().message)
    local path, call = find_call(f, function(a) return a[1] == "wslpath" end)
    assert.are.same({ "wslpath", "-a", "-u", "/trusted/agent" }, path)
    assert.are.equal("Ubuntu", call.argv[3]); assert.are.equal("alice", call.argv[5])
  end)

  it("supports x86 and ARM aliases and rejects unsupported architecture", function()
    for _, arch in ipairs({ "x86_64", "amd64", "aarch64", "arm64" }) do
      local f = fixture({ arch = arch .. "\n" })
      assert.are.equal("fulfilled", start(f):status())
    end
    local f = fixture({ arch = "riscv64\n" })
    assert.are.equal("unsupported_arch", start(f):error().code)
    assert.are.equal(0, #f.connects)
  end)

  it("tests preinstalled agent without wslpath, copy, or artifact discovery", function()
    local f = fixture()
    f.native.info = function() error("unexpected bundle discovery") end
    assert.are.equal("fulfilled", start(f, { id = "x", distro = "Ubuntu", agent_path = "/already/there" }):status())
    assert.is_truthy(find_call(f, function(a) return a[1] == "test" and a[2] == "-x" end))
    assert.is_nil(find_call(f, function(a) return a[1] == "wslpath" or a[1] == "cp" end))
  end)

  it("converts client path with remote wslpath then copies mapped path as argv data", function()
    local source = "C:\\path with spaces\\agent'\n\255"
    local mapped = "/mnt/c/path with spaces/agent'\n\255\n"
    local f = fixture({ mapped = mapped })
    local digest = string.rep("c", 64)
    local p = start(f, { id = "x", distro = "Ubuntu", artifacts = { x86_64 = { path = source, sha256 = digest } } })
    assert.are.equal("fulfilled", p:status())
    assert.are.same({ "wslpath", "-a", "-u", source }, find_call(f, function(a) return a[1] == "wslpath" end))
    local temporary = "/home/worker/.cache/hollow/agents/linux-x86_64/" .. digest .. "/.upload-abcdef123456"
    assert.are.same({ "cp", "--", mapped:sub(1, -2), temporary }, find_call(f, function(a) return a[1] == "cp" end))
    assert.are.same({ id = "x", argv = { "wsl.exe", "--distribution", "Ubuntu", "--cd", "/", "--exec", "/home/worker/.cache/hollow/agents/linux-x86_64/" .. digest .. "/hollow-agent", "stdio" } }, f.connects[1])
  end)

  it("preserves trailing whitespace except exactly one wslpath newline", function()
    local f = fixture({ mapped = "/mapped/name \t\n\n" })
    start(f, { id = "x", distro = "Ubuntu", artifacts = { x86_64 = { path = "/client", sha256 = string.rep("d", 64) } } })
    local cp = find_call(f, function(a) return a[1] == "cp" end)
    assert.are.equal("/mapped/name \t\n", cp[3])
  end)

  it("fails malformed wslpath output without copying", function()
    for _, mapped in ipairs({ "relative\n", "/bad\0path\n", "/missing-newline" }) do
      local f = fixture({ mapped = mapped })
      local p = start(f, { id = "x", distro = "Ubuntu", artifacts = { x86_64 = { path = "/client", sha256 = string.rep("e", 64) } } })
      assert.are.equal("agent_install_unavailable", p:error().code)
      assert.is_nil(find_call(f, function(a) return a[1] == "cp" end))
    end
  end)

  it("skips upload only after verified cache and maps upload/checksum failures", function()
    local digest = string.rep("f", 64)
    local cached = fixture({ cached = true })
    assert.are.equal("fulfilled", start(cached, { id = "x", distro = "Ubuntu", artifacts = { x86_64 = { path = "/client", sha256 = digest } } }):status())
    assert.is_nil(find_call(cached, function(a) return a[1] == "wslpath" or a[1] == "cp" end))
    local bad_path = fixture({ wslpath_code = 1, mapped = "", wslpath_error = "missing" })
    assert.are.equal("agent_install_unavailable", start(bad_path, { id = "x", distro = "Ubuntu", artifacts = { x86_64 = { path = "/client", sha256 = digest } } }):error().code)
    local bad_checksum = fixture({ checksum_error = true })
    assert.are.equal("checksum_mismatch", start(bad_checksum, { id = "x", distro = "Ubuntu", artifacts = { x86_64 = { path = "/client", sha256 = digest } } }):error().code)
    assert.is_truthy(find_call(bad_checksum, function(a) return a[1] == "rm" and a[2] == "-f" end))
    local bad_copy = fixture({ cp_error = true })
    assert.are.equal("agent_install_unavailable", start(bad_copy, { id = "x", distro = "Ubuntu", artifacts = { x86_64 = { path = "/client", sha256 = digest } } }):error().code)
    assert.is_truthy(find_call(bad_copy, function(a) return a[1] == "rm" and a[2] == "-f" end))
    assert.are.equal(0, #bad_copy.connects)
  end)

  it("maps missing native WSL and failed distro launch distinctly", function()
    local missing = fixture({ native_error = { code = "not_found", message = "wsl.exe missing" } })
    assert.are.equal("connector_unavailable", start(missing):error().code)
    local failed = fixture({ native_error = { code = "exit_error", message = "distro offline" } })
    assert.are.equal("distro_unavailable", start(failed):error().code)
    local launch_error = fixture({ uname_error = result(1, "", "unknown distribution or user") })
    assert.are.equal("distro_unavailable", start(launch_error):error().code)
  end)

  it("applies total deadline and cancels pending native command", function()
    local f = fixture({ pending_at = 1 })
    local p = start(f, { id = "x", distro = "Ubuntu", agent_path = "/agent", timeout_ms = 5 })
    now = 6
    table.remove(queue, 1).fn()
    assert.are.equal("timeout", p:error().code)
    assert.are.equal(1, f.config.pending.cancels)
    local g = fixture({ pending_at = 1 })
    local q = start(g)
    assert.is_true(q:cancel())
    assert.are.equal("cancelled", q:error().code)
    assert.are.equal(1, g.config.pending.cancels)
    g.config.pending.resolve(result(0, "x86_64\n"))
    assert.are.equal(1, #g.calls)
  end)

  it("waits for pending copy before removing owned temp and closes late connected host", function()
    local f = fixture()
    local base_exec = f.native.exec
    local resolve_cp
    f.native.exec = function(host, options)
      if remote(options.argv)[1] == "cp" then
        local p; p, resolve_cp = deferred(); f.calls[#f.calls + 1] = { argv = options.argv, timeout_ms = options.timeout_ms }; return p
      end
      return base_exec(host, options)
    end
    local opts = { id = "x", distro = "Ubuntu", artifacts = { x86_64 = { path = "/client", sha256 = string.rep("9", 64) } } }
    local p = start(f, opts)
    assert.is_true(p:cancel())
    local before = #f.calls
    resolve_cp(result(0))
    assert.is_true(#f.calls > before)
    assert.is_truthy(find_call(f, function(a) return a[1] == "rm" and a[2] == "-f" end))

    local g = fixture({ pending_connect = true })
    local late = start(g)
    assert.are.equal("pending", late:status())
    assert.is_true(late:cancel())
    g.config.resolve_connect({ close = function() g.closes[#g.closes + 1] = true end })
    assert.are.equal(1, #g.closes)
  end)

  it("discovers default bundle before first WSL command and honors directory override", function()
    local function bundle(f, directory)
      local body = string.rep("a", 64) .. "  linux-x86_64/hollow-agent\n" .. string.rep("b", 64) .. "  linux-aarch64/hollow-agent\n"
      f.native.info = function() return fulfilled({ executable_dir = "/opt/hollow" }) end
      f.native.fs = {
        read = function(path, opts)
          assert.are.equal(4096, opts.limit)
          if path == directory .. "/SHA256SUMS" then return fulfilled({ bytes = body, eof = true }) end
          return rejected({ code = "not_found", message = "missing" })
        end,
        stat = function() return fulfilled({ kind = "file", size = 1 }) end,
      }
    end
    local f = fixture()
    bundle(f, "/opt/hollow/agents")
    assert.are.equal("fulfilled", start(f, { id = "x", distro = "Ubuntu" }):status())
    assert.are.equal("uname", remote(f.calls[1].argv)[1])
    local explicit = fixture()
    bundle(explicit, "/custom/agents")
    assert.are.equal("fulfilled", start(explicit, { id = "x", distro = "Ubuntu", agent_dir = "/custom/agents" }):status())
    local cp = find_call(explicit, function(a) return a[1] == "wslpath" end)
    assert.are.equal("/custom/agents/linux-x86_64/hollow-agent", cp[4])
  end)
end)
