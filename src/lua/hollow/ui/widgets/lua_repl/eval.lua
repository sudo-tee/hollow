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
local function environment(append)
  return setmetatable({
    print = function(...)
      append(format_values(pack(...), 1), "result")
    end,
    inspect = tools.inspect,
  }, { __index = _G, __newindex = _G })
end
M.env = environment(transcript.append)

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

-- Shared evaluator. Sends results/prints/errors to `append`, never replaces
-- global print, and returns "ok", "error" or "incomplete". The optional start
-- hook runs only after incomplete-input detection (used for transcript echo).
function M.execute(source, force, append, env, before_run)
  local chunk, err = compile(source)
  if not chunk and not force and err:match("'<eof>'%s*$") then
    return "incomplete"
  end
  if before_run then
    before_run()
  end
  if not chunk then
    append(err, "error")
    return "error"
  end
  local result = pack(xpcall(setfenv(chunk, env or environment(append)), short_traceback))
  if not result[1] then
    append(result[2], "error")
    return "error"
  elseif result.n > 1 then
    append(format_values(result, 2), "result")
  end
  return "ok"
end

function M.run(source, force)
  return M.execute(source, force, transcript.append, M.env, function()
    transcript.append("> " .. source, "command")
  end) ~= "incomplete"
end

return M
