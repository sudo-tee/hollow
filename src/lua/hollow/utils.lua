local M = {}

local HEX_COLOR_PATTERN = "^#%x%x%x%x%x%x$"

local function current_platform()
  local hollow = _G.hollow
  return type(hollow) == "table" and type(hollow.platform) == "table" and hollow.platform or {}
end

local function clamp_byte(value)
  return math.max(0, math.min(255, math.floor(value + 0.5)))
end

local function normalize_amount(value)
  local amount = tonumber(value)
  if amount == nil then
    return nil
  end

  return math.max(-1, math.min(1, amount))
end

local function split_hex_channels(color)
  if type(color) ~= "string" or color:match(HEX_COLOR_PATTERN) == nil then
    return nil, nil, nil
  end

  return tonumber(color:sub(2, 3), 16), tonumber(color:sub(4, 5), 16), tonumber(color:sub(6, 7), 16)
end

local function choose_separator(path)
  if type(path) == "string" and path:find("\\", 1, true) then
    return "\\"
  end

  return current_platform().is_windows and "\\" or "/"
end

local function normalize_separators(path, separator)
  if type(path) ~= "string" then
    return nil
  end

  if separator == "\\" then
    return (path:gsub("/", "\\"))
  end

  return (path:gsub("\\", "/"))
end

local function split_root(path, separator)
  if separator == "\\" then
    local drive_root = path:match("^%a:\\")
    if drive_root ~= nil then
      return drive_root, path:sub(#drive_root + 1)
    end

    local drive = path:match("^%a:")
    if drive ~= nil then
      return drive, path:sub(#drive + 1)
    end
  end

  if path:sub(1, 1) == separator then
    return separator, path:sub(2)
  end

  return "", path
end

local function trim_trailing_separators(path, separator, root)
  while #path > #root and path:sub(-1) == separator do
    path = path:sub(1, -2)
  end

  return path
end

local function separator_pattern(separator)
  return separator == "\\" and "\\" or "/"
end

function M.is_hex_color(value)
  return type(value) == "string" and value:match(HEX_COLOR_PATTERN) ~= nil
end

function M.normalize_hex_color(value, fallback)
  if M.is_hex_color(value) then
    return value
  end

  return fallback
end

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

function M.brighten_hex_color(value, amount, fallback)
  return M.adjust_hex_color(value, math.abs(tonumber(amount) or 0), fallback)
end

function M.darken_hex_color(value, amount, fallback)
  return M.adjust_hex_color(value, -math.abs(tonumber(amount) or 0), fallback)
end

function M.path_separator(path)
  return choose_separator(path)
end

function M.normalize_path(path, separator)
  separator = separator or choose_separator(path)
  return normalize_separators(path, separator)
end

function M.join_path(...)
  local parts = { ... }
  local separator = choose_separator(parts[1])
  local pattern = separator_pattern(separator)
  local result = ""

  for _, part in ipairs(parts) do
    if type(part) == "string" and part ~= "" then
      local normalized = normalize_separators(part, separator)
      local part_root, part_rest = split_root(normalized, separator)
      part_rest = part_rest:gsub("^[" .. pattern .. "]+", "")
      part_rest = part_rest:gsub("[" .. pattern .. "]+$", "")

      if part_root ~= "" then
        result = part_root
      end

      if part_rest ~= "" then
        if result == "" or result:sub(-1) == separator then
          result = result .. part_rest
        else
          result = result .. separator .. part_rest
        end
      end
    end
  end

  return result
end

function M.basepath(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local separator = choose_separator(path)
  local normalized = normalize_separators(path, separator)
  local root, rest = split_root(normalized, separator)
  rest = trim_trailing_separators(rest, separator, "")
  if rest == "" then
    return root ~= "" and root or "."
  end

  local last = rest:match("^.*()" .. (separator == "\\" and "\\" or "/"))
  if last == nil then
    return root ~= "" and root or "."
  end

  local parent = rest:sub(1, last - 1)
  return parent == "" and (root ~= "" and root or ".") or (root .. parent)
end

function M.basename(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  if path:match("^[/\\]+$") then
    return path:sub(1, 1)
  end

  if path:match("^%a:[/\\]*$") then
    return path:gsub("[/\\]+$", "")
  end

  path = path:gsub("[/\\]+$", "")
  return (path:gsub("(.*[/\\])(.*)", "%2"))
end

return M
