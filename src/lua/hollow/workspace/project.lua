-- Pane/layout bootstrap policy is separate from host-backed workspace discovery.
local hollow = _G.hollow
local M = {}

local function bootstrap(cwd, domain)
  hollow.workspace.bootstrap_project_async(cwd, domain):catch(function(err)
    hollow.log("Workspace project bootstrap failed: ", err)
  end)
end

function M.on_complete(cwd, domain)
  if type(cwd) ~= "string" or not cwd:find("%S") then return nil end
  return function(result)
    if result == nil or result.success ~= true then return end
    local config = hollow.config.snapshot()
    local domain_config = (config.domains or {})[domain]
    local pane = type(domain_config) == "table"
      and domain_config.wsl_distro ~= nil
      and hollow.term.current_pane()
    if not pane then
      bootstrap(cwd, domain)
      return
    end

    -- Preserve existing layout loading semantics until shell canonicalizes cwd.
    hollow.log("Waiting for WSL cwd resolution before workspace bootstrap: " .. cwd)
    local handle
    handle = hollow.events.on("term:cwd_changed", function(event)
      if event.pane == nil or event.pane.id ~= pane.id then return end
      hollow.events.off(handle)
      local current = hollow.term.current_pane()
      if current == nil or current.id ~= pane.id then return end
      hollow.log("Bootstrapping workspace from resolved WSL cwd: " .. event.new_cwd)
      bootstrap(event.new_cwd, domain)
    end)
  end
end

return M
