local M = {}

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

function M.unsupported(name)
  error(name .. " is not implemented yet")
end

return M
