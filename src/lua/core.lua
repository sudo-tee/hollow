---@type HollowHostBridge
local host_api = assert(rawget(_G, "host_api"), "global host_api bridge is missing")

---@type Hollow
local hollow = {
  keymap = {},
  config = {},
  term = {},
  events = {},
  ui = {},
  htp = {},
  process = {},
  platform = host_api.platform or {},
  util = {},
}

_G.hollow = hollow

if package ~= nil and package.loaded ~= nil then
  package.loaded.hollow = hollow
end

local actions = require("hollow.actions")
local config = require("hollow.config")
local defaults = require("hollow.defaults")
local events = require("hollow.events")
local htp = require("hollow.htp")
local keymap = require("hollow.keymap")
local state = require("hollow.state").new(host_api)
local term = require("hollow.term")
local util = require("hollow.util")

-- alias for backward compatibility.
hollow.util = util

config.setup(hollow, host_api, state)
local term_helpers = term.setup(hollow, host_api)
local ui_exports = require("hollow.ui")
for name, value in pairs(ui_exports) do
  hollow.ui[name] = value
end
actions.setup(hollow, host_api)
keymap.setup(hollow, host_api, state)
local events_runtime = events.setup(hollow, state, term_helpers)
htp.setup(hollow, host_api, state, util, term_helpers)

function hollow._emit_builtin_event(name, payload)
  local adapted = events_runtime.adapt_builtin_payload(name, payload)
  if
    name == "topbar:hover"
    or name == "topbar:leave"
    or name == "topbar:click"
    or name == "bottombar:hover"
    or name == "bottombar:leave"
    or name == "bottombar:click"
  then
    hollow.ui.handle_bar_node_event(name, adapted)
  end
  hollow.ui.dispatch_widget_event(name, adapted)
  events_runtime.emit_event(name, adapted, true)
end

function hollow.read_dir(path)
  return host_api.read_dir(path)
end

function hollow.process.run_child_process(args)
  return host_api.run_child_process(args)
end

function hollow.term.run_domain_process(args, domain)
  if type(args) ~= "table" then
    error("hollow.term.run_domain_process(args, domain?) expects args to be a table")
  end

  if domain == nil then
    local pane = hollow.term.current_pane()
    domain = pane and pane.domain or nil
  end

  if type(domain) ~= "string" or domain == "" then
    error("hollow.term.run_domain_process(args, domain?) could not resolve a domain")
  end

  return host_api.run_domain_process(domain, args)
end

function hollow.process.spawn(_opts)
  util.unsupported("hollow.process.spawn")
end

function hollow.process.exec(_opts)
  util.unsupported("hollow.process.exec")
end

defaults.setup(hollow)
