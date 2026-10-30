-- Style layer merging and per-component stylesheets.
--
-- A stylesheet is a plain table of named slots. Each slot is a style table
-- whose color fields are palette tokens, plus optional nested layers:
--
--   label = {
--     fg = "fg",
--     hovered = { fg = "hover_fg" },          -- state layers
--     selected = { fg = "selection_fg" },
--     variants = { primary = { fg = "primary_fg" } },
--     sizes = { sm = { padding = { x = 6 } } },
--   }
--
-- Resolution order: base, variant, size, then each state in STATE_ORDER (base,
-- variant and size layers of that state). Sheet tokens missing from a (partial)
-- palette resolve to nil. `false` suppresses an earlier color.
--
-- Use views: `S(palette, props).slot` resolves (and memoizes) one slot. Dynamic
-- colors are concrete hex values layered at the call site with `ui.style`.

local box = require("hollow.ui.style.box")
local tokens = require("hollow.ui.style.tokens")
local util = require("hollow.util")

local M = {}

M.STATE_ORDER = { "hovered", "selected", "pressed", "focus_visible", "disabled" }

local NESTED = { hover = true }
for _, state in ipairs(M.STATE_ORDER) do
  NESTED[state] = true
end
local NAMED = { variants = true, sizes = true }

---@type fun(result: table, layer: table, skip_meta?: boolean): table
local merge_into

local function merge_named(result, layers)
  for name, layer in pairs(layers) do
    if type(layer) == "table" then
      result[name] = type(result[name]) == "table" and result[name] or {}
      merge_into(result[name], layer)
    else
      result[name] = layer
    end
  end
end

---@param result table
---@param layer table
---@param skip_meta? boolean Skip state/variant/size layers (sheet resolution).
function merge_into(result, layer, skip_meta)
  for key, value in pairs(layer) do
    if skip_meta and (NAMED[key] or (NESTED[key] and key ~= "hover")) then
      -- Applied separately by resolve().
    elseif key == "padding" or key == "margin" then
      local parsed = box.parse(value)
      if type(parsed) == "table" then
        result[key] = type(result[key]) == "table" and result[key] or {}
        for side, px in pairs(parsed) do
          result[key][side] = px
        end
      else
        result[key] = parsed
      end
    elseif NESTED[key] and type(value) == "table" then
      result[key] = type(result[key]) == "table" and result[key] or {}
      merge_into(result[key], value)
    elseif NAMED[key] and type(value) == "table" then
      result[key] = type(result[key]) == "table" and result[key] or {}
      merge_named(result[key], value)
    elseif type(value) == "table" then
      result[key] = type(result[key]) == "table" and result[key] or {}
      util.merge_tables(result[key], util.clone_value(value))
    else
      result[key] = value
    end
  end
  return result
end

M.merge_into = merge_into

--- Merge style layers left to right into a fresh table. Non-table layers
--- (`nil`, `false`) are skipped, so `cond and LAYER` composes naturally.
---@vararg HollowStyleLayer
---@return HollowUiNodeStyle
function M.merge(...)
  local result = {}
  for i = 1, select("#", ...) do
    local layer = select(i, ...)
    if type(layer) == "table" then
      merge_into(result, layer)
    end
  end
  return result
end

local function strip_false_colors(style)
  for _, key in ipairs(tokens.COLOR_FIELDS) do
    if style[key] == false then
      style[key] = nil
    end
  end
  return style
end

---@class HollowUiStyleProps: HollowUiVisualState
---@field variant? string
---@field size? string

--- Slots bound to a palette and props; `view.slot` resolves lazily.
---@class HollowUiStyleView
---@field [string] HollowUiNodeStyle

---@class HollowUiStylesheet
---@field name string
---@field slots table<string, table>
---@overload fun(palette: table, props?: HollowUiStyleProps): HollowUiStyleView
local Sheet = {}
Sheet.__index = Sheet

local SHEET, PALETTE, PROPS = {}, {}, {}

local function check_layer(layer, path, palette)
  for _, key in ipairs(tokens.COLOR_FIELDS) do
    if layer[key] ~= nil and layer[key] ~= false then
      tokens.resolve_color(layer[key], path .. "." .. key, palette)
    end
  end
  for key, value in pairs(layer) do
    if type(value) == "table" and (NESTED[key] or NAMED[key] or NAMED[path:match("[^.]+$")]) then
      check_layer(value, path .. "." .. key, palette)
    end
  end
end

-- Theme slot overrides live at `palette.styles.<sheet>.<slot>` (from
-- `theme.ui.widgets.<kind>.styles`). Sheet names are checked once per styles
-- table; a sheet's own section is checked strictly against each new palette.
local checked_names = setmetatable({}, { __mode = "k" })
-- Palettes reference their section keys. Weak values avoid retaining that cycle
-- on LuaJIT, whose weak-key tables do not have ephemeron semantics.
local checked_sections = setmetatable({}, { __mode = "kv" })

local function check_sheet_names(styles)
  for name, section in pairs(styles) do
    local ok, target = pcall(require, "hollow.ui.recipes." .. tostring(name))
    if not ok or getmetatable(target) ~= Sheet then
      error(string.format("hollow.ui: unknown theme style sheet %q", tostring(name)))
    end
    if type(section) ~= "table" then
      error(string.format("hollow.ui: theme styles.%s must be a table", name))
    end
  end
end

local function check_section(self, section, palette)
  for slot, layer in pairs(section) do
    local spec = self.slots[slot]
    if spec == nil then
      error(string.format("hollow.ui: unknown style slot %q in %s", tostring(slot), self.name))
    end
    if type(layer) ~= "table" then
      error(string.format("hollow.ui: theme styles.%s.%s must be a table", self.name, slot))
    end
    for _, field in ipairs({ "variants", "sizes" }) do
      for name in pairs(layer[field] or {}) do
        if not (spec[field] and spec[field][name]) then
          error(
            string.format(
              "hollow.ui: unknown %s %s %s",
              self.name,
              field:sub(1, -2),
              tostring(name)
            )
          )
        end
      end
    end
    check_layer(layer, "styles." .. self.name .. "." .. slot, palette)
  end
end

---@param self HollowUiStylesheet
---@param palette table
---@return table|nil
local function theme_section(self, palette)
  local styles = palette.styles
  if styles == nil then
    return nil
  end
  if type(styles) ~= "table" then
    error("hollow.ui: theme styles must be a table")
  end
  if not checked_names[styles] then
    check_sheet_names(styles)
    checked_names[styles] = true
  end
  local section = styles[self.name]
  if section ~= nil and checked_sections[section] ~= palette then
    check_section(self, section, palette)
    checked_sections[section] = palette
  end
  return section
end

local function named_layer(spec, field, name, sheet_name)
  if name == nil or spec[field] == nil then
    return nil
  end
  local layer = spec[field][name]
  if layer == nil then
    error(
      string.format("hollow.ui: unknown %s %s %s", sheet_name, field:sub(1, -2), tostring(name))
    )
  end
  return layer
end

-- Resolve one slot against `palette`, applying `props`.
---@param self HollowUiStylesheet
---@param slot string
---@param palette table
---@param props? HollowUiStyleProps
---@return HollowUiNodeStyle
local function resolve(self, slot, palette, props)
  local spec = self.slots[slot]
  if spec == nil then
    error(string.format("hollow.ui: unknown style slot %q in %s", tostring(slot), self.name))
  end
  props = props or {}
  -- Theme layers follow the sheet's at each step, so a themed base color does
  -- not mask the sheet's state colors.
  local section = theme_section(self, palette)
  local themed = section and section[slot]
  local layers = {
    spec,
    themed,
    named_layer(spec, "variants", props.variant, self.name),
    themed and themed.variants and themed.variants[props.variant],
    named_layer(spec, "sizes", props.size, self.name),
    themed and themed.sizes and themed.sizes[props.size],
  }
  local result = {}
  for i = 1, 6 do
    if layers[i] then
      merge_into(result, layers[i], true)
    end
  end
  for _, state in ipairs(M.STATE_ORDER) do
    if props[state] then
      for i = 1, 6 do
        local layer = layers[i] and layers[i][state]
        if type(layer) == "table" then
          merge_into(result, layer, true)
        end
      end
    end
  end
  tokens.resolve_owned(result, palette, true)
  return strip_false_colors(result)
end

local View = {}
View.__index = function(view, slot)
  local style = resolve(rawget(view, SHEET), slot, rawget(view, PALETTE), rawget(view, PROPS))
  rawset(view, slot, style)
  return style
end

--- Bind a palette and props; slots resolve lazily and are memoized per view.
---@param palette table
---@param props? HollowUiStyleProps
---@return HollowUiStyleView
function Sheet:__call(palette, props)
  if type(palette) ~= "table" then
    error(string.format("hollow.ui: %s styles require a palette", self.name))
  end
  return setmetatable({ [SHEET] = self, [PALETTE] = palette, [PROPS] = props }, View)
end

--- Strictly resolve every token of every slot and layer; for tests.
---@param palette table
function Sheet:check(palette)
  for slot, spec in pairs(self.slots) do
    check_layer(spec, self.name .. "." .. slot, palette)
  end
end

--- Define a stylesheet. Slot tables are treated as immutable.
---@param name string
---@param slots table<string, table>
---@return HollowUiStylesheet
function M.define(name, slots)
  return setmetatable({ name = name, slots = slots }, Sheet)
end

return M
