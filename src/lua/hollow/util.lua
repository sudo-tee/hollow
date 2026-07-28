local M = {}

---@class HollowUtil
---@field clone_value fun(value:any, seen:table|nil): any
---@field merge_tables fun(dst:table, src:table): table
---@field unsupported fun(name:string)
---@field host_now_ms fun(host_api:table|nil): integer
---@field path_separator fun(path:string|nil): string
---@field normalize_path fun(path:string, separator:string|nil): string|nil
---@field join_path fun(...:string): string
---@field basepath fun(path:string): string|nil
---@field basename fun(path:string): string|nil
---@field safe_call fun(fn:function|nil, default:any, ...:any): any
---@field words fun(...:any): string
---@field cycle_index fun(index:integer, delta:integer, count:integer): integer
---@field state_value fun(is_selected:boolean, is_hovered:boolean, selected:any, hovered:any, fallback:any): any
---@field group_by fun(list:table, key_fn:fun(item:any):any): table, any[]
---@field has_any_key fun(t:table, keys:table): boolean
---@field utf8_len fun(s:string): integer
---@field pad_right fun(value:string, width:integer): string
---@field truncate_end fun(value:string, width:integer): string
---@field truncate_start fun(value:string, width:integer): string

---@param value any
---@param seen table|nil
---@return any
function M.clone_value(value, seen)
  if type(value) ~= "table" then
    return value
  end

  seen = seen or {}
  if seen[value] ~= nil then
    return seen[value]
  end

  local copy = {}
  seen[value] = copy
  for k, v in pairs(value) do
    copy[M.clone_value(k, seen)] = M.clone_value(v, seen)
  end
  return copy
end

---@param dst table
---@param src table
---@return table
function M.merge_tables(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" then
      local current = dst[k]
      if type(current) ~= "table" then
        current = {}
        dst[k] = current
      end
      M.merge_tables(current, v)
    else
      dst[k] = v
    end
  end
  return dst
end

---@param fn (function|nil)
---@param default any
---@vararg any
---@return any
function M.safe_call(fn, default, ...)
  if type(fn) ~= "function" then
    return default
  end
  local ok, value = pcall(fn, ...)
  if ok and value ~= nil then
    return value
  end
  return default
end

---@vararg any
---@return string
function M.words(...)
  local hollow = _G.hollow
  local values = { ... }
  return hollow.tbl
    .range(1, select("#", ...))
    :filter_map(function(index)
      local value = values[index]
      return value ~= nil and value ~= "" and tostring(value) or nil
    end)
    :join(" ")
end

---@param index integer
---@param delta integer
---@param count integer
---@return integer
function M.cycle_index(index, delta, count)
  if count == 0 then
    return index
  end
  return (index + delta - 1) % count + 1
end

---@param is_selected boolean
---@param is_hovered boolean
---@param selected any
---@param hovered any
---@param fallback any
---@return any
function M.state_value(is_selected, is_hovered, selected, hovered, fallback)
  if is_selected then
    return selected
  elseif is_hovered then
    return hovered
  end
  return fallback
end

---@param name string
function M.unsupported(name)
  error(name .. " is not implemented yet")
end

---@param host_api HollowHostBridge|table|nil
---@return integer
function M.host_now_ms(host_api)
  if type(host_api) == "table" and type(host_api.now_ms) == "function" then
    local ok, value = pcall(host_api.now_ms)
    if ok and type(value) == "number" then
      return math.floor(value)
    end
  end

  return math.floor(os.time() * 1000)
end

-- Path utilities
---@return table
local function current_platform()
  local hollow = _G.hollow
  return type(hollow) == "table" and type(hollow.platform) == "table" and hollow.platform or {}
end

---@param path string|nil
---@return string
local function choose_separator(path)
  if type(path) == "string" and path:find("\\", 1, true) then
    return "\\"
  end

  if type(path) == "string" and path:find("/", 1, true) then
    return "/"
  end

  return current_platform().is_windows and "\\" or "/"
end

---@param path string
---@param separator string|nil
---@return string|nil
local function normalize_separators(path, separator)
  if type(path) ~= "string" then
    return nil
  end

  if separator == "\\" then
    return (path:gsub("/", "\\"))
  end

  return (path:gsub("\\", "/"))
end

---@param path string
---@param separator string
---@return string, string
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

---@param path string
---@param separator string
---@param root string
---@return string
local function trim_trailing_separators(path, separator, root)
  while #path > #root and path:sub(-1) == separator do
    path = path:sub(1, -2)
  end
  return path
end

---@param separator string
---@return string
local function separator_pattern(separator)
  return separator == "\\" and "\\" or "/"
end

---@param path string|nil
---@return string
function M.path_separator(path)
  return choose_separator(path)
end

---@param path string
---@param separator string|nil
---@return string|nil
function M.normalize_path(path, separator)
  separator = separator or choose_separator(path)
  return normalize_separators(path, separator)
end

---@vararg string
---@return string
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

---@param path string
---@return string|nil
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

---@param path string
---@return string|nil
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

--- Buckets `list` by `key_fn(item)`, preserving first-seen key order.
--- Returns (groups, ordered_keys).
---@param list table
---@param key_fn fun(item:any):any
---@return table groups
---@return any[] ordered_keys
function M.group_by(list, key_fn)
  local groups, order = {}, {}
  for _, item in ipairs(list) do
    local key = key_fn(item)
    if not groups[key] then
      groups[key] = {}
      order[#order + 1] = key
    end
    local bucket = groups[key]
    bucket[#bucket + 1] = item
  end
  return groups, order
end

---@param t table
---@param keys table
---@return boolean
function M.has_any_key(t, keys)
  for _, key in ipairs(keys) do
    if t[key] ~= nil then
      return true
    end
  end
  return false
end

function M.wsl_unc_to_linux_path(path)
  if type(path) ~= "string" then
    return nil
  end
  local normalized = path:gsub("\\", "/")
  if normalized == "" then
    return nil
  end

  return normalized:match("^//wsl%$/[^/]+(/.*)$")
    or normalized:match("^//wsl%.localhost/[^/]+(/.*)$")
end

function M.linux_to_wsl_unc_path(path, distro)
  if type(path) ~= "string" or type(distro) ~= "string" then
    return nil
  end
  local normalized = path:gsub("\\", "/")
  if normalized == "" then
    return nil
  end
  if normalized:sub(1, 1) ~= "/" then
    return nil
  end
  return "\\\\wsl.localhost\\" .. distro .. path:gsub("/", "\\")
end

---@param s string
---@return integer
function M.utf8_len(s)
  if type(s) ~= "string" then
    return 0
  end
  local _, count = s:gsub("[^\128-\193]", "")
  return count
end

---@param value any
---@param width integer
---@return string
function M.pad_right(value, width)
  value = tostring(value or "")
  local len = M.utf8_len(value)
  if len >= width then
    return value
  end
  return value .. string.rep(" ", width - len)
end

function M.pad_left(value, width)
  value = tostring(value or "")
  local len = M.utf8_len(value)
  if len >= width then
    return value
  end
  return string.rep(" ", width - len) .. value
end

---@param value any
---@param width integer
---@return string
function M.truncate_end(value, width)
  value = tostring(value or "")
  if M.utf8_len(value) <= width then
    return value
  end
  if width <= 3 then
    return value:sub(1, width)
  end
  return value:sub(1, width - 3) .. "..."
end

---@param value any
---@param width integer
---@return string
function M.truncate_start(value, width)
  value = tostring(value or "")
  local len = M.utf8_len(value)
  if len <= width then
    return value
  end
  if width <= 3 then
    return value:sub(len - width + 1)
  end
  return "..." .. value:sub(len - width + 4)
end

return M
