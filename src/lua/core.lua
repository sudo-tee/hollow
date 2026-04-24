---@type HollowHostBridge
local host_api = assert(rawget(_G, "host_api"), "global host_api bridge is missing")

---@type Hollow
local hollow = {
  keymap = {},
  config = {},
  fonts = {},
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
if type(hollow.ui._register_bar_invalidation_hooks) == "function" then
  hollow.ui._register_bar_invalidation_hooks()
end
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

function hollow.fonts.list()
  return host_api.list_fonts()
end

local function normalize_font_query(value)
  return (tostring(value or ""):lower():gsub("[^%w]", ""))
end

function hollow.fonts.find(query)
  local normalized_query = normalize_font_query(query)
  if normalized_query == "" then
    return hollow.fonts.list()
  end

  local matches = {}
  for _, font in ipairs(hollow.fonts.list()) do
    local family_match = normalize_font_query(font.family):find(normalized_query, 1, true) ~= nil
    local style_match = false
    if not family_match then
      for _, style in ipairs(font.styles or {}) do
        if normalize_font_query(style):find(normalized_query, 1, true) ~= nil then
          style_match = true
          break
        end
      end
    end
    if family_match or style_match then
      matches[#matches + 1] = font
    end
  end
  return matches
end

function hollow.fonts.has(family, style)
  local family_query = normalize_font_query(family)
  if family_query == "" then
    return false
  end

  local style_query = style ~= nil and normalize_font_query(style) or nil
  for _, font in ipairs(hollow.fonts.list()) do
    if normalize_font_query(font.family) == family_query then
      if style_query == nil or style_query == "" then
        return true
      end
      for _, font_style in ipairs(font.styles or {}) do
        if normalize_font_query(font_style) == style_query then
          return true
        end
      end
      return false
    end
  end
  return false
end

function hollow.fonts.pick(candidates, style)
  if type(candidates) ~= "table" then
    error("hollow.fonts.pick(candidates, style?) expects candidates to be a table")
  end

  for _, family in ipairs(candidates) do
    if hollow.fonts.has(family, style) then
      return family
    end
  end
  return nil
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
