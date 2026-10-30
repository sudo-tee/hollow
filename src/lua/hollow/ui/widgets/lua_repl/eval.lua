-- Runs REPL code in the live runtime. This is intentionally not a sandbox.
local tools = require("hollow.ui.widgets.lua_repl.tools")
local transcript = require("hollow.ui.widgets.lua_repl.transcript")
local M = {}
local MAX_TRACE_LINES = 10

local function pack(...)
  return { n = select("#", ...), ... }
end

local function format_values(values, first)
  local formatted = {}
  for i = first, values.n do
    formatted[i - first + 1] = tools.format(values[i])
  end
  return table.concat(formatted, "\t")
end

-- Assignments reach the same globals as config/plugins. Only print is local to
-- console chunks; do not replace _G.print while arbitrary user code runs.
M.env = setmetatable({
  print = function(...)
    transcript.append(format_values(pack(...), 1), "result")
  end,
  inspect = tools.inspect,
}, { __index = _G, __newindex = _G })

local function short_traceback(message)
  local trace = debug.traceback(tostring(message), 2)
  local head = trace:match("^" .. ("[^\n]*\n"):rep(MAX_TRACE_LINES))
  return head and (head .. "...") or trace
end

-- Expressions print their value, so try them before statements.
local function compile(source)
  source = source:gsub("^=", "")
  local chunk = loadstring("return " .. source, "=Lua REPL")
  if chunk then
    return chunk
  end
  return loadstring(source, "=Lua REPL")
end

-- Runs `source` and writes the command and its results to the transcript.
-- Returns false, without running anything, when the code is an unfinished block
-- and `force` is not set.
function M.run(source, force)
  local chunk, err = compile(source)
  if not chunk and not force and err:match("'<eof>'%s*$") then
    return false
  end
  transcript.append("> " .. source, "command")
  if not chunk then
    transcript.append(err, "error")
    return true
  end
  local result = pack(xpcall(setfenv(chunk, M.env), short_traceback))
  if not result[1] then
    transcript.append(result[2], "error")
  elseif result.n > 1 then
    transcript.append(format_values(result, 2), "result")
  end
  return true
end

return M
