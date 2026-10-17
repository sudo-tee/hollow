-- WSL only selects the Linux environment and opens a binary-clean transport.
-- Filesystem/process RPCs and all PTYs remain independent of this connector.
local M = {}
local bootstrap = require("hollow.host.bootstrap")

function M.connect(hosts, options)
  local opts = bootstrap.configuration(options, "wsl", "wsl.exe")
  opts.distro = bootstrap.string(options.distro, "distro")
  if #opts.distro > 256 or opts.distro:sub(1, 1) == "-" then error("invalid WSL distro name", 2) end
  if options.user ~= nil then
    opts.user = bootstrap.string(options.user, "user")
    if #opts.user > 256 or opts.user:sub(1, 1) == "-" then error("invalid WSL user", 2) end
  end
  local function remote(args)
    local argv = { "--distribution", opts.distro }
    if opts.user then argv[#argv + 1] = "--user"; argv[#argv + 1] = opts.user end
    argv[#argv + 1] = "--cd"; argv[#argv + 1] = "/"
    argv[#argv + 1] = "--exec"
    for _, value in ipairs(args) do argv[#argv + 1] = value end
    return argv
  end
  return bootstrap.connect(hosts, opts, {
    label = "WSL",
    unavailable = "distro_unavailable",
    prepare = function(_, ready) ready() end,
    remote = remote,
    transport = function(path) return remote({ path, "stdio" }) end,
    upload = function(ctx, path, target, done)
      -- Never guess a /mnt/<drive> layout or quote paths into a shell command.
      -- wslpath runs inside the selected distro, under the selected user.
      ctx.command(remote({ "wslpath", "-a", "-u", path }), "agent_install_unavailable", function(result)
        local mapped = result.stdout
        if type(mapped) ~= "string" or mapped:sub(-1) ~= "\n" then
          ctx.fail("agent_install_unavailable", "invalid wslpath response; configure agent_path"); return
        end
        mapped = mapped:sub(1, -2) -- remove only the command's final newline
        if mapped:sub(1, 1) ~= "/" or mapped:find("\0", 1, true) then
          ctx.fail("agent_install_unavailable", "artifact path is not accessible in selected distro; configure agent_path"); return
        end
        ctx.command(remote({ "cp", "--", mapped, target }), "agent_install_unavailable", function() done() end)
      end)
    end,
  })
end

return M
