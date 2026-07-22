---@type HollowHostBridge
local host_api = assert(rawget(_G, "host_api"), "global host_api bridge is missing")

---@type Hollow
local hollow = {
  keymap = {},
  config = {},
  fonts = {},
  term = {},
  events = {},
  async = {},
  ui = {},
  htp = {},
  fs = {},
  process = {},
  plugins = {},
  platform = host_api.platform or {},
  util = {},
}

_G.hollow = hollow

if package ~= nil and package.loaded ~= nil then
  package.loaded.hollow = hollow
end

local tbl = require("hollow.tbl")
local actions = require("hollow.actions")
local async = require("hollow.async")
local config = require("hollow.config")
local copy_mode = require("hollow.copy_mode")
local events = require("hollow.events")
local htp = require("hollow.htp")
local json = require("hollow.json")
local keymap = require("hollow.keymap")
local plugins = require("hollow.plugins")
local state = require("hollow.state").new(host_api)
local term = require("hollow.term")
local theme = require("hollow.theme")
local util = require("hollow.util")
local workspace = require("hollow.workspace")

hollow.tbl = tbl
hollow.util = util
hollow.async = async
hollow.theme = theme
hollow.json = json
hollow.workspace = workspace
hollow.copy_mode = copy_mode
hollow.plugins = plugins

config.setup(hollow, host_api, state)
local term_helpers = term.setup(hollow, host_api)
local ui_exports = require("hollow.ui")
for name, value in pairs(ui_exports) do
  hollow.ui[name] = value
end
actions.setup(hollow, host_api)
keymap.setup(hollow, host_api, state)
state.config.values.load_default_keymaps = true
local events_runtime = events.setup(hollow, state, term_helpers)
copy_mode.setup()
state.quick_select = state.quick_select or { active = false, action = "open" }
hollow.events.on("quick_select:changed", function(payload)
  state.quick_select.active = payload and payload.active == true
  state.quick_select.action = payload and payload.action or "open"
end)
if type(hollow.ui._register_bar_invalidation_hooks) == "function" then
  hollow.ui._register_bar_invalidation_hooks()
end
htp.setup(hollow, host_api, state, util, term_helpers)

function hollow.on_gui_ready(handler)
  return host_api.on_gui_ready(handler)
end

hollow.on_gui_ready(function()
  events_runtime.emit_event("gui:ready", {}, true)
  hollow.workspace.auto_bootstrap()
end)

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

function hollow.fs.data_dir()
  return host_api.data_dir()
end

function hollow.fs.glob(pattern)
  return host_api.glob(pattern)
end

function hollow.fs.is_dir(path)
  return host_api.is_dir(path)
end

function hollow.fs.mkdir_p(path)
  return host_api.mkdir_p(path)
end

function hollow.schedule(...)
  return host_api.schedule(...)
end

function hollow.defer(...)
  return host_api.defer(...)
end

local function format_log_value(value, seen, depth)
  local value_type = type(value)
  if value_type == "string" then
    return string.format("%q", value)
  end
  if value_type ~= "table" then
    return tostring(value)
  end

  seen = seen or {}
  if seen[value] then
    return "<cycle>"
  end
  if (depth or 0) >= 4 then
    return "<max-depth>"
  end

  seen[value] = true
  local parts = {}
  for key, item in pairs(value) do
    parts[#parts + 1] = "["
      .. format_log_value(key, seen, (depth or 0) + 1)
      .. "]="
      .. format_log_value(item, seen, (depth or 0) + 1)
  end
  seen[value] = nil
  table.sort(parts)
  return "{" .. table.concat(parts, ", ") .. "}"
end

function hollow.inspect(value)
  return format_log_value(value)
end

function hollow.log(...)
  local parts = {}
  local values = { ... }
  for index = 1, select("#", ...) do
    parts[index] = format_log_value(values[index])
  end
  host_api.log(table.concat(parts, " "))
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

function hollow.process.run_child_process(args, opts)
  return host_api.run_child_process(args, opts)
end

function hollow.process.run(cmd, args)
  return host_api.run_process(cmd, args or {})
end

function hollow.process.spawn(_opts)
  util.unsupported("hollow.process.spawn")
end

function hollow.process.exec(_opts)
  util.unsupported("hollow.process.exec")
end
