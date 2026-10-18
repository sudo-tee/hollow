local harness = require("tests.harness")

describe("hollow.host.docker context policy", function()
  local now, queue
  local function ready(value)
    return require("hollow.async").promise(function(resolve) resolve(value) end)
  end
  local function pending()
    local resolve
    local p = require("hollow.async").promise(function(r) resolve = r end)
    return p, resolve
  end
  local function fixture(config)
    config = config or {}
    local calls, connects = {}, {}
    local id, digest = string.rep("a", 64), string.rep("b", 64)
    local hosts = {}
    hosts.local_host = function()
      return ready({ exec = function(_, opts)
        assert.are.equal(16384, opts.output_limit)
        assert.is_true(opts.timeout_ms > 0)
        local argv = opts.argv
        calls[#calls + 1] = argv
        assert.are.equal(config.executable or "docker", argv[1])
        assert.are.same({ "--context", config.context or "build cluster" }, { argv[2], argv[3] })
        local result = { exit_code = 0, stdout = "", stderr = "" }
        if argv[4] == "container" then
          assert.are.same({ "container", "inspect", "--format", "{{.Id}} {{.State.Running}}", "worker" }, { argv[4], argv[5], argv[6], argv[7], argv[8] })
          if config.inspect_pending then
            local p, resolve = pending()
            config.resolve_inspect = resolve
            return p
          end
          result.stdout = id .. " true\n"
        elseif argv[4] == "cp" then
          result.exit_code = config.copy_error and 1 or 0
        else
          assert.are.equal("exec", argv[4])
          assert.are.equal(id, argv[5])
          if argv[6] == "uname" then result.stdout = "x86_64\n"
          elseif argv[6] == "/bin/sh" then
            if argv[8]:find("$HOME", 1, true) then result.stdout = "/home/worker"
            elseif argv[8]:find("exec 3<", 1, true) then
              if config.restage_pending then
                local p, resolve = pending()
                config.resolve_restage, config.stage_cancels = resolve, 0
                function p:cancel() config.stage_cancels = config.stage_cancels + 1 end
                return p
              end
              result.exit_code = config.restage_error and 1 or 0
            elseif not argv[8]:find("chmod", 1, true) then result.exit_code = 1 end
          elseif argv[6] == "mktemp" then result.stdout = argv[7]:gsub("XXXXXXXXXXXX$", "abcdef123456") .. "\n" end
        end
        return ready(result)
      end })
    end
    hosts.connect = function(opts) connects[#connects + 1] = opts; return ready({}) end
    return { hosts = hosts, calls = calls, connects = connects, config = config, id = id, digest = digest }
  end
  local function start(f, opts)
    return require("hollow.host.docker").connect(f.hosts, opts or {
      id = "docker-host", container = "worker", context = "build cluster", agent_path = "/opt/agent",
    })
  end
  before_each(function()
    local env = harness.boot()
    now, queue = 0, {}
    env.host_api.now_ms = function() return now end
    env.host_api.defer = function(fn) queue[#queue + 1] = fn end
  end)

  it("preserves explicit context on inspect, probes and persistent transport", function()
    local f = fixture()
    assert.are.equal("fulfilled", start(f):status())
    assert.are.same({ "docker", "--context", "build cluster", "exec", "-i", f.id, "/opt/agent", "stdio" }, f.connects[1].argv)
    assert.are.equal(3, #f.calls)
  end)

  it("copies context and executable before asynchronous inspect completes", function()
    local f = fixture({ inspect_pending = true, context = "remote", executable = "/opt/Docker CLI/docker" })
    local opts = { id = "docker-host", container = "worker", context = "remote", docker = "/opt/Docker CLI/docker", agent_path = "/opt/agent" }
    local p = start(f, opts)
    opts.context, opts.docker, opts.container = "changed", "other", "other"
    f.config.resolve_inspect({ exit_code = 0, stdout = f.id .. " true\n" })
    assert.are.equal("fulfilled", p:status())
    assert.are.same({ "/opt/Docker CLI/docker", "--context", "remote", "exec", "-i", f.id, "/opt/agent", "stdio" }, f.connects[1].argv)
  end)

  it("applies context to upload, verification and owned-temp cleanup", function()
    local f = fixture({ copy_error = true })
    local p = start(f, { id = "docker-host", container = "worker", context = "build cluster", artifacts = { x86_64 = { path = "/local/agent", sha256 = f.digest } } })
    assert.are.equal("agent_install_unavailable", p:error().code)
    local cp, rm
    for _, argv in ipairs(f.calls) do
      if argv[4] == "cp" then cp = argv end
      if argv[6] == "rm" then rm = argv end
    end
    local target = "/home/worker/.cache/hollow/agents/linux-x86_64/" .. f.digest .. "/.upload-abcdef123456"
    assert.are.same({ "docker", "--context", "build cluster", "cp", "/local/agent", f.id .. ":" .. target }, cp)
    assert.are.same({ "docker", "--context", "build cluster", "exec", f.id, "rm", "-f", "--", target }, rm)
    assert.are.equal(0, #f.connects)
  end)

  it("validates context and executable before any native side effects", function()
    local effects = 0
    local hosts = { local_host = function() effects = effects + 1 end }
    for _, value in ipairs({ "", "-help", "bad\0context", string.rep("x", 257), false, {} }) do
      assert.has_error(function() require("hollow.host.docker").connect(hosts, { id = "x", container = "worker", context = value, agent_path = "/agent" }) end)
    end
    assert.has_error(function() require("hollow.host.docker").connect(hosts, { id = "x", container = "worker", docker = "", agent_path = "/agent" }) end)
    assert.are.equal(0, effects)
  end)

  it("restages copied data as configured user before checksum or execution", function()
    local f = fixture({ restage_error = true })
    local p = start(f, { id = "x", container = "worker", context = "build cluster", artifacts = { x86_64 = { path = "/local/agent", sha256 = f.digest } } })
    assert.are.equal("agent_install_unavailable", p:error().code)
    local stage, cleaned
    for _, argv in ipairs(f.calls) do
      if argv[8] and argv[8]:find("exec 3<", 1, true) then
        stage = argv
        assert.is_truthy(argv[8]:find('set -C; umask 077; cat <&3 > "$1"', 1, true))
      end
      if argv[6] == "rm" then cleaned = argv end
      assert.is_falsy(argv[8] and argv[8]:find("chmod", 1, true))
    end
    assert.is_truthy(stage)
    assert.is_truthy(cleaned)
    assert.are.equal(0, #f.connects)
  end)

  it("forwards opaque context bytes as one argv item without shell syntax", function()
    local context = "build ';not-a-shell\n\255"
    local f = fixture({ context = context })
    assert.are.equal("fulfilled", start(f, { id = "x", container = "worker", context = context, agent_path = "/agent" }):status())
    assert.are.equal(context, f.connects[1].argv[3])
  end)

  it("drains cancelled restaging before context-specific owned-temp cleanup", function()
    local f = fixture({ restage_pending = true })
    local p = start(f, { id = "x", container = "worker", context = "build cluster", artifacts = { x86_64 = { path = "/local/agent", sha256 = f.digest } } })
    assert.are.equal("pending", p:status())
    local count = #f.calls
    assert.is_true(p:cancel())
    assert.are.equal("cancelled", p:error().code)
    assert.are.equal(1, f.config.stage_cancels)
    assert.are.equal(count, #f.calls)
    f.config.resolve_restage({ exit_code = 0 })
    assert.are.equal(count + 1, #f.calls)
    assert.are.equal("rm", f.calls[#f.calls][6])
    assert.are.equal(0, #f.connects)
  end)
end)
