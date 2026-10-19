local harness = require("tests.harness")

describe("hollow.host.pty", function()
  local env, pty, domains

  before_each(function()
    env = harness.boot()
    pty = require("hollow.host.pty")
    domains = {}
    env.hollow.config.get = function(key)
      if key == "domains" then return domains end
    end
    env.hollow.platform = { is_windows = true }
  end)

  it("parses WSL launcher distros", function()
    assert.are.equal("Ubuntu", pty.wsl_distro("wsl.exe -d Ubuntu"))
    assert.are.equal("Arch", pty.wsl_distro('"C:\\Windows\\System32\\wsl.exe" --user me --distribution Arch --exec zsh'))
    assert.are.equal("Arch", pty.wsl_distro("wsl.exe ~ --shell-type login -d Arch"))
    assert.is_nil(pty.wsl_distro("wsl.exe"))
    assert.is_nil(pty.wsl_distro("wsl.exe -e bash -d x"))
    assert.is_nil(pty.wsl_distro("pwsh.exe -d Ubuntu"))
  end)

  it("selects explicit, implicit and native hosts", function()
    domains.box = { host = { type = "docker", container = "dev" } }
    domains.ubuntu = { wsl_distro = "Ubuntu" }
    domains.off = { wsl_distro = "Ubuntu", host = false }
    local spec, mode = pty.descriptor("box", "sh")
    assert.are.equal("docker", spec.type)
    assert.are.equal("explicit", mode)
    spec, mode = pty.descriptor("ubuntu", "pwsh.exe")
    assert.are.same({ type = "wsl", distro = "Ubuntu" }, spec)
    assert.are.equal("implicit", mode)
    assert.are.equal("Debian", (pty.descriptor(nil, "wsl.exe -d Debian")).distro)
    assert.is_nil(pty.descriptor("off", "wsl.exe -d Ubuntu"))
    env.hollow.platform = { is_windows = false }
    assert.is_nil(pty.descriptor("ubuntu", "wsl.exe -d Ubuntu"))
    assert.are.equal("explicit", select(2, pty.descriptor("box", "sh")))
  end)

  it("describes an implicit WSL connector synchronously", function()
    local host = env.hollow._pty_host(nil, "wsl.exe -d Ubuntu")
    assert.are.same({
      mode = "implicit",
      connector = { argv = { "wsl.exe", "--distribution", "Ubuntu", "--cd", "/", "--exec" } },
      agent = { timeout_ms = 60000 },
      path_style = "wsl",
    }, host)
  end)

  it("describes SSH as a remote shell connector", function()
    domains.ssh = { host = { type = "ssh", destination = "box", user = "me", port = 2222 } }
    local host = pty.request("ssh", "sh")
    assert.are.equal("explicit", host.mode)
    assert.is_true(host.connector.remote_shell)
    assert.are.equal("posix", host.path_style)
    local argv = host.connector.argv
    assert.are.equal("ssh", argv[1])
    assert.are.equal("box", argv[#argv])
    assert.are.same({ "-l", "me" }, { argv[#argv - 2], argv[#argv - 1] })
  end)

  it("describes containers, optionally through WSL, with agent options", function()
    domains.pod = { host = { type = "podman", container = "dev", agent_path = "/opt/hollow-agent", path_style = "wsl" } }
    local host = pty.request("pod", "sh")
    assert.are.same({ "podman", "exec", "-i", "dev" }, host.connector.argv)
    assert.are.equal("/opt/hollow-agent", host.agent.path)
    assert.are.equal("wsl", host.path_style)
    domains.box = { host = { type = "docker", container = "dev", context = "remote", via = { type = "wsl", distro = "Ubuntu" }, timeout_ms = 5000 } }
    host = pty.request("box", "sh")
    assert.are.same({ "wsl.exe", "--distribution", "Ubuntu", "--cd", "/", "--exec", "docker", "--context", "remote", "exec", "-i", "dev" }, host.connector.argv)
    assert.are.equal(5000, host.agent.timeout_ms)
  end)

  it("reports invalid or unsupported hosts as pane errors", function()
    domains.weird = { host = { type = "local" } }
    assert.are.same({ mode = "explicit", error = "unsupported host type: local" }, pty.request("weird", "sh"))
    domains.bad = { host = { type = "ssh", destination = "-oProxyCommand=x" } }
    local host = pty.request("bad", "sh")
    assert.are.equal("explicit", host.mode)
    assert.truthy(host.error:find("destination must be", 1, true) == 1)
  end)

  it("runs natively when no host applies", function()
    env.hollow.platform = { is_windows = false }
    assert.is_nil(pty.request(nil, "/bin/zsh"))
  end)
end)
