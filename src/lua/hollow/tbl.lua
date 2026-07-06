---@class HollowTblInstance
---@field _data table

local Tbl = {}
Tbl.__index = Tbl

local function identity(x)
  return x
end

---@param t table|nil
---@return HollowTblInstance
function Tbl.new(t)
  return setmetatable({ _data = t or {} }, Tbl)
end

--- Unwrap to plain table. Terminal — breaks the chain.
---@return table
function Tbl:get()
  return self._data
end

--- Call fn(v, i, t) for each element. Side-effect only; returns self.
---@param fn fun(v:any, i:integer, t:table)
---@return HollowTblInstance
function Tbl:each(fn)
  for i, v in ipairs(self._data) do
    fn(v, i, self._data)
  end
  return self
end

--- Transform every element via fn(v, i, t) -> new_v.
---@param fn fun(v:any, i:integer, t:table):any
---@return HollowTblInstance
function Tbl:map(fn)
  local out = {}
  for i, v in ipairs(self._data) do
    out[i] = fn(v, i, self._data)
  end
  self._data = out
  return self
end

--- Keep elements where fn(v, i, t) returns truthy.
---@param fn fun(v:any, i:integer, t:table):boolean
---@return HollowTblInstance
function Tbl:filter(fn)
  local out = {}
  for i, v in ipairs(self._data) do
    if fn(v, i, self._data) then
      out[#out + 1] = v
    end
  end
  self._data = out
  return self
end

--- Filter + transform in one pass. Return nil from fn to drop the element.
---@param fn fun(v:any, i:integer, t:table):any|nil
---@return HollowTblInstance
function Tbl:filter_map(fn)
  local out = {}
  for i, v in ipairs(self._data) do
    local result = fn(v, i, self._data)
    if result ~= nil then
      out[#out + 1] = result
    end
  end
  self._data = out
  return self
end

--- Keep first n elements.
---@param n integer
---@return HollowTblInstance
function Tbl:take(n)
  local len = #self._data
  if n >= len then
    return self
  end
  local out = {}
  for i = 1, n do
    out[i] = self._data[i]
  end
  self._data = out
  return self
end

--- Drop first n elements.
---@param n integer
---@return HollowTblInstance
function Tbl:skip(n)
  local out = {}
  for i = n + 1, #self._data do
    out[#out + 1] = self._data[i]
  end
  self._data = out
  return self
end

--- Flatten one level of nesting. Non-table elements pass through.
---@return HollowTblInstance
function Tbl:flatten()
  local out = {}
  for _, v in ipairs(self._data) do
    if type(v) == "table" then
      for _, inner in ipairs(v) do
        out[#out + 1] = inner
      end
    else
      out[#out + 1] = v
    end
  end
  self._data = out
  return self
end

--- Map then flatten one level. fn returns a table (flattened) or scalar.
---@param fn fun(v:any, i:integer, t:table):table|any
---@return HollowTblInstance
function Tbl:flat_map(fn)
  local out = {}
  for i, v in ipairs(self._data) do
    local result = fn(v, i, self._data)
    if type(result) == "table" then
      for _, inner in ipairs(result) do
        out[#out + 1] = inner
      end
    else
      out[#out + 1] = result
    end
  end
  self._data = out
  return self
end

--- Fold left. Terminal — returns the accumulated value, not a Tbl.
--- If initial is nil the first element is used as the seed.
---@param fn fun(acc:any, v:any, i:integer, t:table):any
---@param initial any|nil
---@return any
function Tbl:reduce(fn, initial)
  local data = self._data
  local acc = initial
  local start = 1
  if acc == nil then
    acc = data[1]
    start = 2
  end
  for i = start, #data do
    acc = fn(acc, data[i], i, data)
  end
  return acc
end

--- True if fn(v, i, t) is truthy for any element. Terminal.
---@param fn fun(v:any, i:integer, t:table):boolean
---@return boolean
function Tbl:some(fn)
  for i, v in ipairs(self._data) do
    if fn(v, i, self._data) then
      return true
    end
  end
  return false
end

--- True if fn(v, i, t) is truthy for all elements. Terminal.
---@param fn fun(v:any, i:integer, t:table):boolean
---@return boolean
function Tbl:every(fn)
  for i, v in ipairs(self._data) do
    if not fn(v, i, self._data) then
      return false
    end
  end
  return true
end

--- Return (value, index) of first match, or nil. Terminal.
---@param fn fun(v:any, i:integer, t:table):boolean
---@return any, integer|nil
function Tbl:find(fn)
  for i, v in ipairs(self._data) do
    if fn(v, i, self._data) then
      return v, i
    end
  end
  return nil
end

--- First element, nil if empty. Terminal.
---@return any|nil
function Tbl:first()
  return self._data[1]
end

--- Last element, nil if empty. Terminal.
---@return any|nil
function Tbl:last()
  return self._data[#self._data]
end

--- Number of elements. Terminal.
---@return integer
function Tbl:len()
  return #self._data
end

--- Count elements matching fn, or total count if fn omitted. Terminal.
---@param fn? fun(v:any):boolean
---@return integer
function Tbl:count(fn)
  if not fn then
    return #self._data
  end
  local n = 0
  for _, v in ipairs(self._data) do
    if fn(v) then
      n = n + 1
    end
  end
  return n
end

--- Element at 1-based index n. Terminal.
---@param n integer
---@return any|nil
function Tbl:nth(n)
  return self._data[n]
end

--- Sort in-place. fn(a, b) returns true when a should precede b.
---@param fn? fun(a:any, b:any):boolean
---@return HollowTblInstance
function Tbl:sort(fn)
  table.sort(self._data, fn)
  return self
end

--- Reverse element order.
---@return HollowTblInstance
function Tbl:reverse()
  local n = #self._data
  local out = {}
  for i = n, 1, -1 do
    out[#out + 1] = self._data[i]
  end
  self._data = out
  return self
end

--- Remove consecutive duplicates. Optional fn extracts a comparison key.
---@param fn? fun(v:any):any
---@return HollowTblInstance
function Tbl:uniq(fn)
  fn = fn or identity
  local seen = {}
  local out = {}
  for _, v in ipairs(self._data) do
    local key = fn(v)
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = v
    end
  end
  self._data = out
  return self
end

--- Append elements or whole tables to the end.
---@vararg any
---@return HollowTblInstance
function Tbl:concat(...)
  for _, other in ipairs({ ... }) do
    if type(other) == "table" then
      for _, v in ipairs(other) do
        self._data[#self._data + 1] = v
      end
    else
      self._data[#self._data + 1] = other
    end
  end
  return self
end

--- Join elements into string via table.concat. Terminal.
---@param sep? string
---@return string
function Tbl:join(sep)
  return table.concat(self._data, sep or "")
end

--- Group elements by key fn. Returns a hash table { key = { element, ... } }. Terminal.
---@param fn fun(v:any):any
---@return table<any, any[]>
function Tbl:group_by(fn)
  local out = {}
  for _, v in ipairs(self._data) do
    local key = fn(v)
    if not out[key] then
      out[key] = {}
    end
    out[key][#out[key] + 1] = v
  end
  return out
end

--- Split into groups of n. Last chunk may be shorter.
---@param n integer
---@return HollowTblInstance
function Tbl:chunk(n)
  local out = {}
  for i = 1, #self._data, n do
    local c = {}
    for j = i, math.min(i + n - 1, #self._data) do
      c[#c + 1] = self._data[j]
    end
    out[#out + 1] = c
  end
  self._data = out
  return self
end

--- Shallow copy of hash-table entries. Terminal.
---@return table
function Tbl:entries()
  local out = {}
  for k, v in pairs(self._data) do
    out[k] = v
  end
  return out
end

--- Map over key-value pairs. fn(k, v) returns (new_k, new_v). Terminal.
---@param fn fun(k:any, v:any):any, any
---@return table
function Tbl:map_entries(fn)
  local out = {}
  for k, v in pairs(self._data) do
    local nk, nv = fn(k, v)
    out[nk] = nv
  end
  return out
end

--- Select specific keys from hash. Terminal.
---@vararg any
---@return table
function Tbl:pick(...)
  local keys = { ... }
  local out = {}
  for _, k in ipairs(keys) do
    out[k] = self._data[k]
  end
  return out
end

--- Omit specific keys from hash. Terminal.
---@vararg any
---@return table
function Tbl:omit(...)
  local reject = {}
  for _, k in ipairs({ ... }) do
    reject[k] = true
  end
  local out = {}
  for k, v in pairs(self._data) do
    if not reject[k] then
      out[k] = v
    end
  end
  return out
end

---@class HollowTblModule
---@field new fun(t:table|nil): HollowTblInstance
---@field range fun(start:integer, stop:integer, step?:integer): HollowTblInstance

---@param t table|nil
---@return HollowTblInstance
local function call_handler(_, t)
  return Tbl.new(t)
end

local M = {}

--- Create a new Tbl wrapper around a table.
--- Equivalent to calling the module function: `hollow.tbl(t)`.
---@param t table|nil
---@return HollowTblInstance
function M.new(t)
  return Tbl.new(t)
end

--- Create a Tbl over an integer range [start, stop] with optional step.
---@param start integer
---@param stop integer
---@param step? integer
---@return HollowTblInstance
function M.range(start, stop, step)
  step = step or 1
  local out = {}
  local i = 1
  local v = start
  while (step > 0 and v <= stop) or (step < 0 and v >= stop) do
    out[i] = v
    i = i + 1
    v = v + step
  end
  return Tbl.new(out)
end

setmetatable(M, { __call = call_handler })
return M
