--- List navigation behavior.
---
--- State + key handlers for navigating a list of items.
--- Wraps by default at boundaries.

local M = {}

---@param n integer
---@return table
function M.list_nav(n)
  local self = {
    index = 1,
    count = math.max(1, n or 1),
  }

  function self.resize(new_n)
    self.count = math.max(1, new_n or 1)
    if self.index > self.count then
      self.index = self.count
    end
  end

  function self.set(i)
    if i >= 1 and i <= self.count then
      self.index = i
    end
  end

  function self.next()
    self.index = self.index + 1
    if self.index > self.count then
      self.index = 1
    end
  end

  function self.prev()
    self.index = self.index - 1
    if self.index < 1 then
      self.index = self.count
    end
  end

  function self.move(delta)
    if delta > 0 then
      for _ = 1, delta do
        self.next()
      end
    else
      for _ = 1, -delta do
        self.prev()
      end
    end
  end

  function self.first()
    self.index = 1
  end

  function self.last()
    self.index = self.count
  end

  self.handlers = {
    ["tab|arrow_right"] = function()
      self.next()
    end,
    ["shift_tab|arrow_left"] = function()
      self.prev()
    end,
  }

  return self
end

return M
