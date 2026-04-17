---@type HollowHostBridge
local host_api = host_api

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
}

_G.hollow = hollow

if package ~= nil and package.loaded ~= nil then
  package.loaded.hollow = hollow
end

local state = require("hollow.state").new(host_api)
local util = require("hollow.util")
local public_utils = require("hollow.utils")

hollow.utils = public_utils

require("hollow.config").setup(hollow, host_api, state, util)
local term_helpers = require("hollow.term").setup(hollow, host_api)
require("hollow.ui")
require("hollow.actions").setup(hollow, host_api)
require("hollow.keymap").setup(hollow, host_api, state)
local events_runtime = require("hollow.events").setup(hollow, state, term_helpers)
require("hollow.htp").setup(hollow, host_api, state, util, term_helpers)

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

function hollow.process.spawn(opts)
  util.unsupported("hollow.process.spawn")
end

function hollow.process.exec(opts)
  util.unsupported("hollow.process.exec")
end

require("hollow.defaults").setup(hollow)
