-- Bounded, session-local event storage. No terminal or UI dependencies.
local util = require("hollow.util")
local Store = {}
Store.__index = Store
Store.max_entries = 500
local severity = { info = 1, success = 1, warn = 2, error = 3 }

function Store.new(limit)
  return setmetatable({ entries = {}, next_id = 1, limit = limit or Store.max_entries }, Store)
end

function Store:find(id)
  for _, entry in ipairs(self.entries) do
    if entry.id == id then
      return entry
    end
  end
end

function Store:pending(key)
  for index = #self.entries, 1, -1 do
    local entry = self.entries[index]
    if entry.key == key and entry.pending then
      return entry
    end
  end
end

function Store:append(entry)
  entry = util.clone_value(entry)
  entry.id = self.next_id
  self.next_id = self.next_id + 1
  entry.count = entry.count or 1
  self.entries[#self.entries + 1] = entry
  if #self.entries > self.limit then
    table.remove(self.entries, 1)
  end
  return entry
end

function Store:dismiss(id)
  local entry = self:find(id)
  if not entry or not entry.pending then
    return false
  end
  entry.pending = false
  return true
end

function Store:list(view)
  local result = {}
  for index = #self.entries, 1, -1 do
    local entry = self.entries[index]
    if view == "history" or entry.pending then
      result[#result + 1] = util.clone_value(entry)
    end
  end
  table.sort(result, function(a, b)
    local a_time, b_time = a.timestamp_ms or 0, b.timestamp_ms or 0
    return a_time == b_time and a.id > b.id or a_time > b_time
  end)
  return result
end

function Store:summary()
  local count, level = 0, nil
  for _, entry in ipairs(self.entries) do
    if entry.pending then
      count = count + 1
      if (severity[entry.level] or 0) > (severity[level] or 0) then
        level = entry.level
      end
    end
  end
  return { count = count, level = level }
end

-- Clearing history must never silently acknowledge pending work.
function Store:clear_history()
  local retained = {}
  for _, entry in ipairs(self.entries) do
    if entry.pending then
      retained[#retained + 1] = entry
    end
  end
  self.entries = retained
end

return Store
