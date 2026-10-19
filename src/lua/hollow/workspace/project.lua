-- Pane/layout bootstrap policy is separate from host-backed workspace discovery.
local hollow = _G.hollow
local M = {}

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
      hollow.workspace.bootstrap_project(cwd, domain)
      return
    end

    -- Preserve existing layout loading semantics until shell canonicalizes cwd.
    hollow.log("Waiting for WSL cwd resolution before workspace bootstrap: " .. cwd)
    local handle
    handle = hollow.events.on("term:cwd_changed", function(event)
      if event.pane == nil or event.pane.id ~= pane.id then return end
      hollow.events.off(handle)
      hollow.log("Bootstrapping workspace from resolved WSL cwd: " .. event.new_cwd)
      hollow.workspace.bootstrap_project(event.new_cwd, domain)
    end)
  end
end

return M
