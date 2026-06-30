local M = {}

---@class HollowColorModule
---@field is_hex_color fun(value:string): boolean
---@field normalize_hex_color fun(value:string, fallback:string|nil): string|nil
---@field adjust_hex_color fun(value:string, amount:number|string, fallback:string|nil): string|nil
---@field brighten_hex_color fun(value:string, amount:number|string, fallback:string|nil): string|nil
---@field darken_hex_color fun(value:string, amount:number|string, fallback:string|nil): string|nil
---@field contrast_hex_color fun(value:string, amount:number|string, fallback:string|nil): string|nil
---@field hex_from_hsl fun(h:number, s:number, l:number): string
---@field hex_luminance fun(hex:string): number

local HEX_COLOR_PATTERN = "^#%x%x%x%x%x%x$"

---@param value number
---@return integer
local function clamp_byte(value)
  return math.max(0, math.min(255, math.floor(value + 0.5)))
end

---@param value number|string
---@return number|nil
local function normalize_amount(value)
  local amount = tonumber(value)
  if amount == nil then
    return nil
  end
  return math.max(-1, math.min(1, amount))
end

---@param color string
---@return integer|nil, integer|nil, integer|nil
local function split_hex_channels(color)
  if type(color) ~= "string" or color:match(HEX_COLOR_PATTERN) == nil then
    return nil, nil, nil
  end
  return tonumber(color:sub(2, 3), 16), tonumber(color:sub(4, 5), 16), tonumber(color:sub(6, 7), 16)
end

---@param value string
---@return boolean
function M.is_hex_color(value)
  return type(value) == "string" and value:match(HEX_COLOR_PATTERN) ~= nil
end

---@param value string
---@param fallback string|nil
---@return string|nil
function M.normalize_hex_color(value, fallback)
  if M.is_hex_color(value) then
    return value
  end
  return fallback
end

---@param value string
---@param amount number|string
---@param fallback string|nil
---@return string|nil
function M.adjust_hex_color(value, amount, fallback)
  local color = M.normalize_hex_color(value, nil)
  local normalized_amount = normalize_amount(amount)
  if color == nil or normalized_amount == nil then
    return fallback
  end

  local red, green, blue = split_hex_channels(color)
  if red == nil or green == nil or blue == nil then
    return fallback
  end

  local function adjust(channel)
    local target = normalized_amount >= 0 and 255 or 0
    return clamp_byte(channel + (target - channel) * math.abs(normalized_amount))
  end

  return string.format("#%02x%02x%02x", adjust(red), adjust(green), adjust(blue))
end

---@param value string
---@param amount number|string
---@param fallback string|nil
---@return string|nil
function M.brighten_hex_color(value, amount, fallback)
  return M.adjust_hex_color(value, math.abs(tonumber(amount) or 0), fallback)
end

---@param value string
---@param amount number|string
---@param fallback string|nil
---@return string|nil
function M.darken_hex_color(value, amount, fallback)
  return M.adjust_hex_color(value, -math.abs(tonumber(amount) or 0), fallback)
end

---@param value string
---@param amount number|string
---@param fallback string|nil
---@return string|nil
function M.contrast_hex_color(value, amount, fallback)
  local color = M.normalize_hex_color(value, nil)
  local norm_amount = normalize_amount(amount)
  if color == nil or norm_amount == nil then
    return fallback
  end

  local red, green, blue = split_hex_channels(color)
  if red == nil then
    return fallback
  end

  -- RGB -> HSL
  local r, g, b = red / 255, green / 255, blue / 255
  local max_val = math.max(r, g, b)
  local min_val = math.min(r, g, b)
  local h, s, l = 0, 0, (max_val + min_val) / 2

  if max_val ~= min_val then
    local d = max_val - min_val
    s = l > 0.5 and d / (2 - max_val - min_val) or d / (max_val + min_val)
    if max_val == r then
      h = (g - b) / d
      if g < b then h = h + 6 end
    elseif max_val == g then
      h = (b - r) / d + 2
    else
      h = (r - g) / d + 4
    end
    h = h / 6
  end

  -- Move L toward opposite extreme (preserves hue + saturation)
  local target = l > 0.5 and 0 or 1
  l = l + (target - l) * norm_amount

  -- HSL -> RGB
  local function hue_to_rgb(p, q, t)
    if t < 0 then t = t + 1 end
    if t > 1 then t = t - 1 end
    if t < 1 / 6 then return p + (q - p) * 6 * t end
    if t < 1 / 2 then return q end
    if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
    return p
  end

  if s == 0 then
    r, g, b = l, l, l
  else
    local q = l < 0.5 and l * (1 + s) or l + s - l * s
    local p = 2 * l - q
    r = hue_to_rgb(p, q, h + 1 / 3)
    g = hue_to_rgb(p, q, h)
    b = hue_to_rgb(p, q, h - 1 / 3)
  end

  return string.format("#%02x%02x%02x",
    clamp_byte(r * 255),
    clamp_byte(g * 255),
    clamp_byte(b * 255)
  )
end

---@param h number hue 0--360
---@param s number saturation 0--1
---@param l number lightness 0--1
---@return string
function M.hex_from_hsl(h, s, l)
  local function hue_to_rgb(p, q, t)
    if t < 0 then t = t + 1 end
    if t > 1 then t = t - 1 end
    if t < 1 / 6 then return p + (q - p) * 6 * t end
    if t < 1 / 2 then return q end
    if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
    return p
  end

  local r, g, b
  if s == 0 then
    r, g, b = l, l, l
  else
    local q = l < 0.5 and l * (1 + s) or l + s - l * s
    local p = 2 * l - q
    r = hue_to_rgb(p, q, (h / 360) + 1 / 3)
    g = hue_to_rgb(p, q, h / 360)
    b = hue_to_rgb(p, q, (h / 360) - 1 / 3)
  end
  return string.format("#%02x%02x%02x",
    clamp_byte(r * 255),
    clamp_byte(g * 255),
    clamp_byte(b * 255)
  )
end

---@param hex string
---@return number
function M.hex_luminance(hex)
  if type(hex) ~= "string" then
    return 0
  end
  local r = tonumber(hex:sub(2, 3), 16) or 0
  local g = tonumber(hex:sub(4, 5), 16) or 0
  local b = tonumber(hex:sub(6, 7), 16) or 0
  return 0.299 * r + 0.587 * g + 0.114 * b
end

return M
