local harness = require("tests.harness")

describe("hollow.host.ssh", function()
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

  -- Decode only the literal shell words emitted by ssh.lua; never execute a shell.
  local function decode_remote(text)
    assert.is_truthy(text:match("^exec%s"), "remote command must begin with exec")
    local words, i = { "exec" }, 5
    while i <= #text do
      while text:sub(i, i):match("%s") do i = i + 1 end
      if i > #text then break end
      local word, quote = {}, nil
      while i <= #text do
        local c = text:sub(i, i)
        if quote == "'" then
          if c == "'" then quote = nil else word[#word + 1] = c end
        elseif quote == '"' then
          if c == '"' then quote = nil else word[#word + 1] = c end
        elseif c == "'" or c == '"' then quote = c
        elseif c:match("%s") then break
        else error("unexpected unquoted byte in remote command: " .. c .. " in " .. text) end
        i = i + 1
      end
      assert.is_nil(quote, "unterminated remote quoting")
      words[#words + 1] = table.concat(word)
      while text:sub(i, i):match("%s") do i = i + 1 end
    end
    return words
  end

  local function remote(argv)
    return decode_remote(argv[#argv])
  end

  local function fixture(config)
    config = config or {}
    local calls, connects, closes = {}, {}, {}
    local native = { exec = function(_, options)
      assert.are.equal(16384, options.output_limit)
      assert.is_true(options.timeout_ms > 0)
      local argv = options.argv
      calls[#calls + 1] = { argv = argv, timeout_ms = options.timeout_ms }
      if type(argv[1]) == "string" and argv[1]:match("^scp") then
        if config.scp_pending then
          local p, resolve = deferred(); config.pending_scp = { promise = p, resolve = resolve, cancels = 0 }
          function p:cancel() config.pending_scp.cancels = config.pending_scp.cancels + 1 end
          return p
        end
        return fulfilled(config.scp_result or result(0))
      end
      local args = remote(argv)
      local command = args[2]
      if config.pending_at and #calls == config.pending_at then
        local p, resolve, reject = deferred()
        config.pending = { promise = p, resolve = resolve, reject = reject, cancels = 0 }
        function p:cancel() config.pending.cancels = config.pending.cancels + 1 end
        return p
      end
      if config.native_error then return rejected(config.native_error) end
      if command == "uname" then return fulfilled(config.uname_result or result(0, config.arch or "x86_64\n")) end
      if command == "test" then return fulfilled(config.test_result or result(config.missing and 1 or 0)) end
      if command == "/bin/sh" then
        local script = args[4] or ""
        if script:find('printf "%s" "$HOME"', 1, true) then return fulfilled(result(0, config.home or "/home/worker")) end
        if script:find("sha256sum", 1, true) then
          if script:find("chmod", 1, true) and config.checksum_error then return fulfilled(result(43, "", "checksum mismatch")) end
          if script:find("chmod", 1, true) then return fulfilled(result(config.install_error and 1 or 0, "", config.install_error and "install failed" or "")) end
          return fulfilled(result(config.cached and 0 or 1))
        end
        return fulfilled(result(0))
      end
      if command == "mkdir" then return fulfilled(result(0)) end
      if command == "mktemp" then return fulfilled(result(0, (config.temp_path or args[3]:gsub("X+$", "abcdef123456")) .. "\n")) end
      if command == "rm" then return fulfilled(result(0)) end
      return fulfilled(result(0))
    end }
    local hosts = {
      local_host = function() return config.local_error and rejected(config.local_error) or fulfilled(native) end,
      connect = function(options)
        connects[#connects + 1] = options
        if config.pending_connect then
          local p, resolve = deferred(); config.resolve_connect = resolve; return p
        end
        if config.connect_error then return rejected(config.connect_error) end
        return fulfilled({ close = function() closes[#closes + 1] = true end })
      end,
    }
    return { hosts = hosts, calls = calls, connects = connects, closes = closes, config = config, native = native }
  end

  local digest = string.rep("a", 64)
  local function start(f, opts)
    return require("hollow.host.ssh").connect(f.hosts, opts or { id = "agent", destination = "host", agent_path = "/opt/hollow-agent" })
  end

  local function find(f, predicate)
    for _, call in ipairs(f.calls) do
      local args = type(call.argv[1]) == "string" and call.argv[1]:match("^scp") and call.argv or remote(call.argv)
      if predicate(args, call.argv) then return args, call.argv end
    end
  end

  local function options(argv)
    local out = {}
    for i = 1, #argv - 1 do if argv[i] == "-o" then out[argv[i + 1]] = true end end
    return out
  end

  local function bundle(f)
    local body = digest .. "  linux-x86_64/hollow-agent\n" .. string.rep("b", 64) .. "  linux-aarch64/hollow-agent\n"
    f.native.info = function() return fulfilled({ executable_dir = "/opt/hollow" }) end
    f.native.fs = {
      read = function(path, opts)
        assert.are.equal(4096, opts.limit)
        if path == "/opt/hollow/agents/SHA256SUMS" then return fulfilled({ bytes = body, eof = true }) end
        return rejected({ code = "not_found", message = "missing" })
      end,
      stat = function() return fulfilled({ kind = "file", size = 1 }) end,
    }
  end

  before_each(function()
    env = harness.boot()
    queue, now = {}, 0
    env.host_api.defer = function(fn, delay) queue[#queue + 1] = { fn = fn, delay = delay or 0 } end
    env.host_api.now_ms = function() return now end
  end)

  it("uses strict non-tty OpenSSH policy without unsafe options", function()
    local f = fixture(); start(f)
    local argv = f.connects[1].argv
    assert.are.equal("ssh", argv[1])
    assert.are.equal("-T", argv[2])
    local o = options(argv)
    for _, value in ipairs({ "BatchMode=yes", "StrictHostKeyChecking=yes", "ControlMaster=no", "ControlPath=none", "ControlPersist=no", "RemoteCommand=none", "RequestTTY=no", "PermitLocalCommand=no", "ClearAllForwardings=yes", "ForwardAgent=no", "ForwardX11=no", "EscapeChar=none" }) do assert.is_true(o[value], value) end
    for _, value in ipairs(argv) do assert.are_not.equal("-tt", value); assert.are_not.equal("-t", value) end
    for _, value in ipairs({ "StrictHostKeyChecking=accept-new", "StrictHostKeyChecking=no", "UserKnownHostsFile=/dev/null" }) do assert.is_nil(o[value]) end
  end)

  it("forces SFTP batch copy and aligns SCP identity, config, known_hosts, and port", function()
    local f = fixture({ missing = true })
    start(f, { id = "i", destination = "host", ssh = "ssh-custom", scp = "scp-custom", identity_file = "/keys/id", config_file = "/cfg/ssh", known_hosts = "/known/hosts", port = 2222,
      artifacts = { x86_64 = { path = "/bundle/agent", sha256 = digest } } })
    local scp = find(f, function(a) return a[1] == "scp-custom" end)
    assert.is_truthy(scp)
    local argv
    for _, call in ipairs(f.calls) do if call.argv[1] == "scp-custom" then argv = call.argv end end
    assert.are.same({ "scp-custom", "-q", "-B", "-s", "-S", "ssh-custom" }, { argv[1], argv[2], argv[3], argv[4], argv[5], argv[6] })
    assert.is_truthy(options(argv)["UserKnownHostsFile=\"/known/hosts\""])
    assert.is_truthy(options(argv)["IdentitiesOnly=yes"])
    local pos = {}; for i, value in ipairs(argv) do pos[value] = i end
    assert.are.equal("/keys/id", argv[pos["-i"] + 1]); assert.are.equal("/cfg/ssh", argv[pos["-F"] + 1]); assert.are.equal("2222", argv[pos["-P"] + 1])
    assert.is_nil(pos["-p"])
    assert.are.equal("/bundle/agent", argv[#argv - 1])
    assert.are.equal("host:/home/worker/.cache/hollow/agents/linux-x86_64/" .. digest .. "/.upload-abcdef123456", argv[#argv])
  end)

  it("uses -p for SSH and omits -l unless explicit user provided", function()
    local f = fixture(); start(f, { id = "x", destination = "example", port = 22, agent_path = "/agent" })
    local a = f.connects[1].argv
    local foundp, founduser = false, false
    for i, v in ipairs(a) do if v == "-p" and a[i + 1] == "22" then foundp = true end; if v == "-l" then founduser = true end end
    assert.is_true(foundp); assert.is_false(founduser)
    local g = fixture(); start(g, { id = "x", destination = "example", user = "alice", artifacts = { x86_64 = { path = "/a", sha256 = digest } } })
    local has_l = false
    for i, v in ipairs(g.connects[1].argv) do if v == "-l" and g.connects[1].argv[i + 1] == "alice" then has_l = true end end
    assert.is_true(has_l)
    local cp = find(g, function(a) return a[1] == "scp" end)
    assert.are.equal("alice@example:/home/worker/.cache/hollow/agents/linux-x86_64/" .. digest .. "/.upload-abcdef123456", cp[#cp])
  end)

  it("transports malicious preinstalled path as one quoted remote argument", function()
    local path = "/opt/a';touch/tmp/pwn"
    local f = fixture(); start(f, { id = "x", destination = "host", agent_path = path })
    assert.are.same({ "exec", "uname", "-m" }, remote(f.calls[1].argv))
    assert.are.same({ "exec", "test", "-x", path }, remote(f.calls[2].argv))
    assert.are.same({ "exec", path, "stdio" }, remote(f.connects[1].argv))
    assert.is_truthy(f.connects[1].argv[#f.connects[1].argv]:find("'\"'\"'", 1, true))
  end)

  it("quotes HOME and shell script arguments while preserving newline, quote, and digest bytes", function()
    local home = "/home/a'\nline"
    local artifact = "/tmp/a'\nsource"
    local f = fixture({ home = home })
    start(f, { id = "x", destination = "host", artifacts = { x86_64 = { path = artifact, sha256 = digest } } })
    local home_args = find(f, function(a) return a[2] == "/bin/sh" and a[4]:find("$HOME", 1, true) end)
    assert.are.same({ "exec", "/bin/sh", "-c", 'printf "%s" "$HOME"' }, home_args)
    local verify = find(f, function(a) return a[2] == "/bin/sh" and a[4]:find("sha256sum", 1, true) end)
    assert.are.equal(home .. "/.cache/hollow/agents/linux-x86_64/" .. digest .. "/hollow-agent", verify[6])
    assert.are.equal(digest, verify[7])
    local scp = find(f, function(a) return a[1] == "scp" end)
    assert.are.equal(artifact, scp[#scp - 1])
  end)

  it("deep-copies SSH settings and artifact data while uname is pending", function()
    local f = fixture({ pending_at = 1 })
    local opts = { id = "x", destination = "trusted", user = "alice", ssh = "ssh-original", agent_path = "/agent" }
    local p = start(f, opts)
    opts.destination, opts.user, opts.executable, opts.agent_path = "mutated", "bob", "evil", "/other"
    f.config.pending.resolve(result(0, "x86_64\n"))
    assert.are.equal("fulfilled", p:status())
    assert.are.same({ "ssh-original", "-T" }, { f.connects[1].argv[1], f.connects[1].argv[2] })
    assert.are.equal("trusted", f.connects[1].argv[#f.connects[1].argv - 1])
    assert.are.equal("alice", f.connects[1].argv[#f.connects[1].argv - 2])
  end)

  it("accepts architecture aliases and rejects unsupported architecture before connect", function()
    for _, arch in ipairs({ "x86_64", "amd64", "aarch64", "arm64" }) do assert.are.equal("fulfilled", start(fixture({ arch = arch .. "\n" })):status()) end
    local f = fixture({ arch = "riscv64\n" }); local p = start(f)
    assert.are.equal("unsupported_arch", p:error().code); assert.are.equal(0, #f.connects)
  end)

  it("validates destination, user, paths, and port before any native side effects", function()
    local effects = 0
    local hosts = { local_host = function() effects = effects + 1; return fulfilled({}) end, connect = function() effects = effects + 1 end }
    local base = { id = "x", destination = "host", agent_path = "/agent" }
    local cases = {
      { destination = "-oProxyCommand=bad" }, { destination = "bad host" }, { destination = "bad\nname" },
      { user = "-oProxyCommand=bad" }, { user = "bad user" }, { user = "bad\nname" },
      { port = 0 }, { port = 65536 }, { port = 1.5 }, { port = 0/0 },
      { known_hosts = "relative" }, { identity_file = "relative" }, { config_file = "relative" },
      { known_hosts = "/known\nhosts" },
    }
    for _, change in ipairs(cases) do
      local opts = {}; for k, v in pairs(base) do opts[k] = v end; for k, v in pairs(change) do opts[k] = v end
      assert.has_error(function() require("hollow.host.ssh").connect(hosts, opts) end)
    end
    assert.are.equal(0, effects)
  end)

  it("escapes known_hosts config token percent, backslash, and double quote", function()
    local f = fixture()
    local path = '/tmp/a%\\"b'
    start(f, { id = "x", destination = "host", agent_path = "/agent", known_hosts = path })
    local expected = 'UserKnownHostsFile="/tmp/a%%\\\\\\"b"'
    assert.is_truthy(options(f.connects[1].argv)[expected])
  end)

  it("skips copy for a verified cache hit", function()
    local f = fixture({ cached = true })
    local p = start(f, { id = "x", destination = "host", artifacts = { x86_64 = { path = "/bundle", sha256 = digest } } })
    assert.are.equal("fulfilled", p:status())
    assert.is_nil(find(f, function(a) return a[1] == "scp" or a[2] == "mkdir" or a[2] == "mktemp" end))
    assert.are.equal(1, #f.connects)
  end)

  it("skips artifact discovery for an explicit preinstalled path", function()
    local f = fixture(); f.native.info = function() error("unexpected discovery") end
    assert.are.equal("fulfilled", start(f):status())
    assert.is_nil(f.native.fs)
    assert.is_nil(find(f, function(a) return a[1] == "scp" or a[2] == "mkdir" or a[2] == "mktemp" end))
  end)

  it("discovers default artifacts before first SSH command", function()
    local f = fixture(); bundle(f)
    local p_info, resolve = deferred(); local info = f.native.info; f.native.info = function() return p_info end
    local p = start(f, { id = "x", destination = "host" })
    assert.are.equal("pending", p:status()); assert.are.equal(0, #f.calls)
    f.native.info = info; resolve({ executable_dir = "/opt/hollow" })
    assert.are.equal("fulfilled", p:status()); assert.are.equal("uname", remote(f.calls[1].argv)[2])
  end)

  it("uses artifact bundle SHA path unchanged in remote cache target", function()
    local f = fixture({ cached = true }); local weird = "/tmp/release/agent'\n"
    start(f, { id = "x", destination = "host", artifacts = { x86_64 = { path = weird, sha256 = digest:upper() } } })
    local verify = find(f, function(a) return a[2] == "/bin/sh" and a[4]:find("sha256sum", 1, true) end)
    assert.are.equal("/home/worker/.cache/hollow/agents/linux-x86_64/" .. digest .. "/hollow-agent", verify[6])
    assert.are.equal(digest, verify[7])
  end)

  it("reports SCP and checksum errors and never connects", function()
    local opts = { id = "x", destination = "host", artifacts = { x86_64 = { path = "/bundle", sha256 = digest } } }
    local cp = fixture({ missing = true, scp_result = result(1, "", "copy failed") })
    local failed = start(cp, opts)
    assert.are.equal("agent_install_unavailable", failed:error().code); assert.are.equal(0, #cp.connects)
    local bad = fixture({ missing = true, checksum_error = true }); local checksum = start(bad, opts)
    assert.are.equal("checksum_mismatch", checksum:error().code); assert.are.equal(0, #bad.connects)
    assert.is_truthy(find(bad, function(a) return a[2] == "rm" and a[4] == "--" end))
  end)

  it("maps missing SSH and authentication/host-key remote errors to ssh_unavailable", function()
    local missing = fixture({ native_error = { code = "not_found", message = "ssh missing" } })
    assert.are.equal("connector_unavailable", start(missing):error().code)
    local auth = fixture({ uname_result = result(255, "", "Host key verification failed") })
    local p = start(auth); assert.are.equal("ssh_unavailable", p:error().code); assert.is_truthy(p:error().message:find("Host key", 1, true))
  end)

  it("forwards cancellation to active SCP and removes upload after it completes", function()
    local f = fixture({ missing = true, scp_pending = true })
    local p = start(f, { id = "x", destination = "host", artifacts = { x86_64 = { path = "/bundle", sha256 = digest } } })
    assert.are.equal("pending", p:status()); assert.is_true(p:cancel()); assert.are.equal(1, f.config.pending_scp.cancels)
    local before = #f.calls; f.config.pending_scp.resolve(result(0)); assert.is_true(#f.calls > before)
    assert.is_truthy(find(f, function(a) return a[2] == "rm" and a[4] == "--" end)); assert.are.equal(0, #f.connects)
  end)

  it("enforces one deadline while SCP active and cancels the active tool", function()
    local f = fixture({ missing = true, scp_pending = true })
    local p = start(f, { id = "x", destination = "host", timeout_ms = 5, artifacts = { x86_64 = { path = "/bundle", sha256 = digest } } })
    now = 6; table.remove(queue, 1).fn()
    assert.are.equal("timeout", p:error().code); assert.are.equal(1, f.config.pending_scp.cancels)
    f.config.pending_scp.resolve(result(0)); assert.is_truthy(find(f, function(a) return a[2] == "rm" and a[4] == "--" end))
  end)

  it("closes a late final SSH host after cancellation", function()
    local f = fixture({ pending_connect = true }); local p = start(f)
    assert.are.equal("pending", p:status()); assert.is_true(p:cancel())
    f.config.resolve_connect({ close = function() f.closes[#f.closes + 1] = true end })
    assert.are.equal(1, #f.closes); assert.are.equal("cancelled", p:error().code)
  end)

  it("maps missing SFTP server errors to install unavailable", function()
    local f = fixture({ missing = true, scp_result = result(1, "", "subsystem request failed on channel 0") })
    local p = start(f, { id = "x", destination = "host", artifacts = { x86_64 = { path = "/bundle", sha256 = digest } } })
    assert.are.equal("agent_install_unavailable", p:error().code); assert.are.equal(0, #f.connects)
  end)
end)
