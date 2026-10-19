local harness = require("tests.harness")

describe("hollow.host connectors", function()
  local env, connects
  local digest = string.rep("a", 64)

  before_each(function()
    env = harness.boot()
    connects = {}
    env.host_api.defer = function() end
    env.host_api.host_connect = function(opts)
      connects[#connects + 1] = opts
      return { generation = "1" }
    end
  end)

  local function target(kind, opts)
    return require("hollow.host.options").target(kind, opts)
  end

  local function index(argv)
    local pos = {}
    for i, value in ipairs(argv) do pos[value] = pos[value] or i end
    return pos
  end

  it("runs WSL commands in the selected distro and user", function()
    assert.are.same({ argv = { "wsl.exe", "--distribution", "Ubuntu", "--cd", "/", "--exec" } }, target("wsl", { distro = "Ubuntu" }).connector)
    assert.are.same(
      { "C:\\wsl.exe", "--distribution", "Arch Linux", "--user", "me", "--cd", "/", "--exec" },
      target("wsl", { distro = "Arch Linux", user = "me", wsl = "C:\\wsl.exe" }).connector.argv
    )
    for _, bad in ipairs({ {}, { distro = "-d" }, { distro = "x", user = "-u" }, { distro = "x\0y" } }) do
      assert.has_error(function() target("wsl", bad) end)
    end
  end)

  it("uses strict non-tty OpenSSH policy and a remote-shell connector", function()
    local connector = target("ssh", {
      destination = "box", user = "alice", port = 2222, ssh = "ssh-custom",
      identity_file = "/keys/id", config_file = "/cfg/ssh", known_hosts = '/tmp/a%\\"b',
    }).connector
    assert.is_true(connector.remote_shell)
    local argv = connector.argv
    assert.are.same({ "ssh-custom", "-T" }, { argv[1], argv[2] })
    assert.are.equal("box", argv[#argv])
    local pos = index(argv)
    for _, policy in ipairs({ "BatchMode=yes", "StrictHostKeyChecking=yes", "ControlMaster=no", "RemoteCommand=none", "RequestTTY=no", "EscapeChar=none", "IdentitiesOnly=yes" }) do
      assert.is_truthy(pos[policy], policy)
    end
    assert.is_truthy(pos['UserKnownHostsFile="/tmp/a%%\\\\\\"b"'])
    assert.are.equal("/keys/id", argv[pos["-i"] + 1])
    assert.are.equal("/cfg/ssh", argv[pos["-F"] + 1])
    assert.are.equal("2222", argv[pos["-p"] + 1])
    assert.are.equal("alice", argv[pos["-l"] + 1])
    assert.is_nil(index(target("ssh", { destination = "box" }).connector.argv)["-l"])
  end)

  it("validates SSH options", function()
    local cases = {
      { destination = "-oProxyCommand=bad" }, { destination = "bad host" }, { destination = "bad\nname" },
      { destination = "h", user = "-oProxyCommand=bad" }, { destination = "h", user = "bad user" },
      { destination = "h", port = 0 }, { destination = "h", port = 65536 }, { destination = "h", port = 1.5 },
      { destination = "h", known_hosts = "relative" }, { destination = "h", identity_file = "relative" },
      { destination = "h", config_file = "/cfg\nssh" },
    }
    for _, opts in ipairs(cases) do
      assert.has_error(function() target("ssh", opts) end)
    end
  end)

  it("execs into existing containers, optionally through WSL", function()
    assert.are.same({ "podman", "exec", "-i", "dev" }, target("podman", { container = "dev" }).connector.argv)
    assert.are.same(
      { "wsl.exe", "--distribution", "Ubuntu", "--cd", "/", "--exec", "/usr/bin/docker", "--context", "remote", "exec", "-i", "dev" },
      target("docker", { container = "dev", context = "remote", docker = "/usr/bin/docker", via = { type = "wsl", distro = "Ubuntu" } }).connector.argv
    )
    local cases = {
      { container = "-it" }, { container = "a b" }, { container = "dev", context = "-x" },
      { container = "dev", via = { type = "ssh" } }, { container = "dev", via = { type = "wsl", distro = "U", agent_path = "/a" } },
    }
    for _, opts in ipairs(cases) do
      assert.has_error(function() target("docker", opts) end)
    end
  end)

  it("validates where the agent comes from", function()
    local agent = target("wsl", {
      distro = "U", agent_dir = "C:\\hollow\\agents", timeout_ms = 5000,
      artifacts = { x86_64 = { path = "/bundle/agent", sha256 = string.rep("A", 64) } },
    }).agent
    assert.are.same({ dir = "C:\\hollow\\agents", timeout_ms = 5000, artifacts = { x86_64 = { path = "/bundle/agent", sha256 = digest } } }, agent)
    assert.are.same({ path = "/opt/hollow-agent", timeout_ms = 60000 }, target("wsl", { distro = "U", agent_path = "/opt/hollow-agent" }).agent)
    local cases = {
      { agent_path = "relative" }, { agent_dir = "relative" }, { timeout_ms = 0 }, { timeout_ms = 300001 },
      { artifacts = { riscv64 = { path = "/a", sha256 = digest } } },
      { artifacts = { x86_64 = { path = "relative", sha256 = digest } } },
      { artifacts = { x86_64 = { path = "/a", sha256 = "abc" } } },
    }
    for _, change in ipairs(cases) do
      change.distro = "U"
      assert.has_error(function() target("wsl", change) end)
    end
    assert.has_error(function() target("local", {}) end, "unsupported host type: local")
  end)

  it("connects through native deploy with copied options", function()
    local opts = { id = "box", container = "dev", agent_path = "/agent" }
    local promise = require("hollow.host").podman(opts)
    assert.are.equal("pending", promise:status())
    assert.are.same({
      id = "box",
      connector = { argv = { "podman", "exec", "-i", "dev" }, remote_shell = false },
      agent = { path = "/agent", timeout_ms = 60000 },
    }, connects[1])
    assert.has_error(function() require("hollow.host").wsl({ distro = "U" }) end)
    assert.are.equal(1, #connects)
  end)
end)
