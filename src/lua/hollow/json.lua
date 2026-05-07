local M = {}

local host_api = assert(rawget(_G, "host_api"), "global host_api bridge is missing")

function M.encode(value)
  return host_api.json_encode(value)
end

function M.decode(text)
  if type(text) ~= "string" then
    error("hollow.json.decode(text) expects a string")
  end
  return host_api.json_decode(text)
end

return M
