-- Keeps console histories between launches in the user data directory.
-- One entry per line; backslashes and newlines are escaped so multi-line
-- entries stay on one line. Read or write failures only lose history.
local util = require("hollow.util")
local host = require("hollow.state").get().host_api
local M = {}

local function path(name)
  return util.join_path(host.data_dir(), name or "lua_repl_history")
end

local function encode(entry)
  return (entry:gsub("\\", "\\\\"):gsub("\n", "\\n"))
end

local function decode(line)
  return (line:gsub("\\(.)", { ["\\"] = "\\", n = "\n" }))
end

function M.load(name)
  local ok, text = pcall(function()
    local file = path(name)
    return host.path_exists(file) and host.read_file(file) or ""
  end)
  local entries = {}
  for line in (ok and text or ""):gmatch("[^\r\n]+") do
    table.insert(entries, decode(line))
  end
  return entries
end

function M.save(entries, name)
  local lines = {}
  for i, entry in ipairs(entries) do
    lines[i] = encode(entry)
  end
  pcall(host.write_file, path(name), table.concat(lines, "\n") .. "\n")
end

return M
