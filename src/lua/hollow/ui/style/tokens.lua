-- Palette token resolution. A token is a (dotted) palette key such as
-- "muted" or "notify_levels.warn"; "muted|fg" falls back left to right.
-- Literal "#rrggbb" values pass through. A palette value that is itself a token
-- (theme `parts`, e.g. `parts.list_row.accent = "muted"`) resolves again, and a
-- `false` value stops the fallback chain to suppress the color. A literal may
-- end a chain (`"parts.scrollbar.track|#5a6375"`).

local util = require("hollow.util")

local M = {}

-- Every style field that may hold a color token.
M.COLOR_FIELDS = {
  "fg",
  "bg",
  "border",
  "close_fg",
  "close_bg",
  "close_hover_fg",
  "close_hover_bg",
  "selection_accent",
  -- Row paint options.
  "fill_bg",
  "accent_bar",
  "scrollbar_track_color",
  "scrollbar_thumb_color",
}

local function edit_distance(a, b)
  local prev = {}
  for j = 0, #b do
    prev[j] = j
  end
  for i = 1, #a do
    local row = { [0] = i }
    for j = 1, #b do
      row[j] = math.min(
        (row[j - 1] or 0) + 1,
        prev[j] + 1,
        prev[j - 1] + (a:sub(i, i) == b:sub(j, j) and 0 or 1)
      )
    end
    prev = row
  end
  return prev[#b]
end

local function closest_token(palette, token)
  local best, distance
  local function visit(tbl, prefix)
    for key, value in pairs(tbl) do
      if type(key) == "string" then
        local path = prefix .. key
        if type(value) == "table" then
          visit(value, path .. ".")
        elseif type(value) == "string" and value:sub(1, 1) == "#" then
          local d = edit_distance(token, path)
          if not distance or d < distance or (d == distance and path < best) then
            best, distance = path, d
          end
        end
      end
    end
  end
  visit(palette, "")
  return best
end

local MAX_DEPTH = 8

---@type fun(palette: table, token: string, depth?: integer): string|false|nil
local lookup

---@param palette table
---@param token string
---@param depth integer
---@return string|false|nil
local function lookup_one(palette, token, depth)
  if token:sub(1, 1) == "#" then
    return token
  end
  if token == "" or token:sub(1, 1) == "." or token:sub(-1) == "." or token:find("..", 1, true) then
    return nil
  end
  local resolved = palette
  for part in token:gmatch("[^.]+") do
    if type(resolved) ~= "table" then
      return nil
    end
    resolved = resolved[part]
  end
  if resolved == false then
    return false
  end
  if type(resolved) ~= "string" then
    return nil
  end
  if resolved:sub(1, 1) == "#" then
    return resolved
  end
  if depth < MAX_DEPTH then
    return lookup(palette, resolved, depth + 1)
  end
  return nil
end

-- "a|b" tries each token in turn, for optional palette fields with fallbacks.
---@param palette table
---@param token string
---@param depth? integer
---@return string|false|nil
function lookup(palette, token, depth)
  depth = depth or 0
  if not token:find("|", 1, true) then
    return lookup_one(palette, token, depth)
  end
  for part in token:gmatch("[^|]+") do
    local resolved = lookup_one(palette, part, depth)
    if resolved ~= nil then
      return resolved
    end
  end
  return nil
end

--- Resolve one color value. Non-strings and literals pass through. Unknown
--- tokens raise with a typo hint, unless `lenient` (then they resolve to nil).
---@param value any
---@param key string Field name used in error messages.
---@param palette table
---@param lenient? boolean
---@return any
function M.resolve_color(value, key, palette, lenient)
  if type(value) ~= "string" or value:sub(1, 1) == "#" then
    return value
  end
  local resolved = lookup(palette, value)
  if resolved == nil and not lenient then
    local hint = closest_token(palette, value)
    error(
      string.format(
        "hollow.ui: unknown style token %q for %s%s",
        value,
        key,
        hint and string.format(" (did you mean %q?)", hint) or ""
      )
    )
  end
  return resolved
end

--- Resolve color fields in place, including the nested `hover` layer.
--- Only use on tables the caller owns.
---@generic T: table
---@param style T
---@param palette table
---@param lenient? boolean
---@return T
function M.resolve_owned(style, palette, lenient)
  for _, key in ipairs(M.COLOR_FIELDS) do
    local value = style[key]
    if value ~= nil then
      style[key] = M.resolve_color(value, key, palette, lenient)
    end
  end
  if type(style.hover) == "table" then
    M.resolve_owned(style.hover, palette, lenient)
  end
  return style
end

---@generic T: table
---@param style T|nil
---@param palette table
---@return T
function M.resolve(style, palette)
  return M.resolve_owned(util.clone_value(style or {}), palette)
end

return M
