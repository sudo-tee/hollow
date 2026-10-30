-- REPL-only inspection/introspection. Never evaluate code or invoke metamethods.
local signatures = require("hollow.ui.widgets.lua_repl.signatures")
local M = {}
local keywords = {}
for name in
  ("and break do else elseif end false for function if in local nil not or repeat return then true until while"):gmatch(
    "%S+"
  )
do
  keywords[name] = true
end
local function valid_name(name)
  return type(name) == "string" and name:match("^[%a_][%w_]*$") and not keywords[name]
end

function M.inspect(value)
  local seen, visiting, nodes, next_id = {}, {}, 0, 0
  local function render(item, depth)
    nodes = nodes + 1
    if nodes > 200 then
      return "<item limit>"
    end
    local kind = type(item)
    if kind == "string" then
      local text = string.format("%q", item:sub(1, 512))
      return text .. (#item > 512 and "..." or "")
    elseif kind ~= "table" then
      if kind == "nil" or kind == "number" or kind == "boolean" then
        return tostring(item)
      end
      return "<" .. kind .. ">"
    end
    if seen[item] then
      return (visiting[item] and "<cycle #" or "<ref #") .. seen[item] .. ">"
    end
    if depth >= 4 then
      return "<max depth>"
    end
    next_id = next_id + 1
    seen[item], visiting[item] = next_id, true
    local keys, truncated = {}, false
    for key in next, item do
      if #keys == 50 then
        truncated = true
        break
      end
      keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
      local ka, kb = type(a), type(b)
      if ka ~= kb then
        return ka < kb
      end
      if ka == "string" or ka == "number" then
        return a < b
      end
      if ka == "boolean" then
        return not a and b
      end
      return false
    end)
    local rows, indent = {}, string.rep("  ", depth + 1)
    for _, key in ipairs(keys) do
      if nodes >= 200 then
        truncated = true
        break
      end
      local name = valid_name(key) and key or ("[" .. render(key, depth + 1) .. "]")
      rows[#rows + 1] = indent .. name .. " = " .. render(rawget(item, key), depth + 1) .. ","
    end
    if truncated then
      rows[#rows + 1] = indent .. "... <item limit>"
    end
    visiting[item] = nil
    if #rows == 0 then
      return "{}"
    end
    return "{\n" .. table.concat(rows, "\n") .. "\n" .. string.rep("  ", depth) .. "}"
  end
  local text = render(value, 0)
  return #text > 8192 and (text:sub(1, 8170) .. "\n... <output limit>") or text
end

function M.format(value)
  return type(value) == "string" and value or M.inspect(value)
end

-- Table-valued __index supports ordinary Lua object methods. Function-valued
-- __index, __pairs and __tostring are never invoked by introspection.
local function tables(value)
  local out, seen = {}, {}
  while type(value) == "table" and not seen[value] and #out < 8 do
    out[#out + 1], seen[value] = value, true
    local mt = getmetatable(value)
    value = type(mt) == "table" and rawget(mt, "__index") or nil
  end
  return out
end

local function field(value, name)
  for _, t in ipairs(tables(value)) do
    local result = rawget(t, name)
    if result ~= nil then
      return result
    end
  end
end

local function resolve(path, env)
  local value = env
  for name in path:gmatch("[%a_][%w_]*") do
    value = field(value, name)
    if value == nil then
      break
    end
  end
  return value
end

-- Small lexer, not a Lua parser. Token positions let completion replace only
-- the identifier under the caret and preserve everything after it.
local function lex(source)
  local tokens, i = {}, 1
  while i <= #source do
    local start, char = i, source:sub(i, i)
    local comment = source:sub(i, i + 1) == "--"
    if comment then
      i = i + 2
      char = source:sub(i, i)
    end
    local equals = source:sub(i):match("^%[(=*)%[")
    if equals then
      local close = "]" .. equals .. "]"
      local pos = source:find(close, i + #equals + 2, true)
      if not pos then
        return tokens, true
      end
      i = pos + #close
      if not comment then
        tokens[#tokens + 1] = { text = "<literal>", start = start, stop = i - 1 }
      end
    elseif comment then
      local pos = source:find("\n", i, true)
      if not pos then
        return tokens, true
      end
      i = pos + 1
    elseif char == "'" or char == '"' then
      i = i + 1
      while i <= #source and source:sub(i, i) ~= char do
        i = i + (source:sub(i, i) == "\\" and 2 or 1)
      end
      if i > #source then
        return tokens, true
      end
      i = i + 1
      tokens[#tokens + 1] = { text = "<literal>", start = start, stop = i - 1 }
    elseif char:match("%s") then
      i = i + 1
    else
      local word = source:sub(i):match("^[%a_][%w_]*") or char
      i = i + #word
      tokens[#tokens + 1] = { text = word, start = start, stop = i - 1 }
    end
  end
  return tokens, false
end

local function identifier(token)
  return token and token.text:match("^[%a_][%w_]*$")
end

local function chain(tokens, last)
  if not identifier(tokens[last]) then
    return
  end
  local first = last
  while
    first > 2
    and (tokens[first - 1].text == "." or tokens[first - 1].text == ":")
    and identifier(tokens[first - 2])
  do
    first = first - 2
  end
  if first > 1 and (tokens[first - 1].text == "." or tokens[first - 1].text == ":") then
    return
  end
  local names = {}
  for i = first, last do
    names[#names + 1] = tokens[i].text
  end
  return table.concat(names), tokens[first].start
end

function M.complete(source, cursor, env)
  local prefix = source:sub(1, cursor)
  local tokens, blocked = lex(prefix)
  local last = tokens[#tokens]
  if blocked or not last or last.stop ~= cursor then
    return
  end
  local path, start, query, value
  if last.text == "." or last.text == ":" then
    path = chain(tokens, #tokens - 1)
    if not path then
      return
    end
    path, start, query = path .. last.text, cursor + 1, ""
    value = resolve(path, env)
  elseif identifier(last) then
    local full
    full, start = chain(tokens, #tokens)
    if not full then
      return
    end
    path, query = full:match("^(.*[%.:])([%w_]*)$")
    path, query = path or "", query or full
    start = cursor - #query + 1
    value = path == "" and env or resolve(path, env)
  else
    return
  end
  local seen, items, kinds, count = {}, {}, {}, 0
  for _, t in ipairs(tables(value)) do
    for name, item in next, t do
      count = count + 1
      if count > 4096 then
        break
      end
      if valid_name(name) and not seen[name] and name:sub(1, #query) == query then
        seen[name] = true
        items[#items + 1] = name
        kinds[name] = type(item)
      end
    end
    if count > 4096 then
      break
    end
  end
  -- Private `_names` sink below public API unless explicitly requested.
  local private_first = query:sub(1, 1) == "_"
  table.sort(items, function(a, b)
    local pa, pb = a:sub(1, 1) == "_", b:sub(1, 1) == "_"
    if pa ~= pb then
      return pa == private_first
    end
    return a < b
  end)
  while #items > 128 do
    table.remove(items)
  end
  if #items == 0 then
    return
  end
  local common = items[1]
  for i = 2, #items do
    while items[i]:sub(1, #common) ~= common do
      common = common:sub(1, -2)
    end
  end
  -- Consume an existing identifier suffix when completing in the middle.
  local suffix = source:sub(cursor + 1):match("^[%w_]*") or ""
  return {
    items = items,
    kinds = kinds,
    common = common,
    query = query,
    path = path,
    start = start,
    stop = cursor + #suffix,
  }
end

local function signature(path, env)
  local fn = resolve(path, env)
  if type(fn) ~= "function" then
    return
  end
  local annotation = signatures[path:gsub(":", ".")]
  if not annotation then
    -- Match aliases by function identity, never by invoking their contents.
    for canonical, hint in pairs(signatures) do
      if resolve(canonical, env) == fn then
        annotation = hint
        break
      end
    end
  end
  if annotation then
    return path .. annotation:gsub("^fun", "")
  end
  return path .. "(...)"
end

function M.hint(source, cursor, env, selected)
  if selected then
    return signature(selected, env)
  end
  local tokens, blocked = lex(source:sub(1, cursor))
  local path = not blocked and chain(tokens, #tokens)
  if path then
    local hint = signature(path, env)
    if hint then
      return hint
    end
  end
  local stack = {}
  for index, token in ipairs(tokens) do
    if token.text == "(" or token.text == "{" or token.text == "[" then
      stack[#stack + 1] =
        { kind = token.text, path = token.text == "(" and chain(tokens, index - 1) or nil }
    elseif token.text == ")" or token.text == "}" or token.text == "]" then
      table.remove(stack)
    end
  end
  for index = #stack, 1, -1 do
    if stack[index].path then
      return signature(stack[index].path, env)
    end
  end
end

return M
