local scroll_view = require("hollow.ui.widgets.scroll_view")

local M = {}

---@param n integer
---@param opts { row_count_fn?: (fun(item: any): integer), row_budget?: integer }
---@return table
function M.scroll_nav(n, opts)
  opts = opts or {}
  local self = {
    index = 1,
    count = math.max(1, n or 1),
    _visible_count = 1,
  }

  local sv = scroll_view.new({
    row_count_fn = opts.row_count_fn,
    row_budget = opts.row_budget,
  })

  function self.resize(new_n)
    self.count = math.max(1, new_n or 1)
    if self.index > self.count then
      self.index = self.count
    end
  end

  function self.visible_range(items, budget)
    self.count = math.max(1, #items)
    local s, e, bar, thumb = sv:update(items, self.index, budget)
    self._visible_count = math.max(1, e - s + 1)
    return s, e, bar, thumb
  end

  function self.page_down()
    self.index = math.min(self.count, self.index + self._visible_count)
  end

  function self.page_up()
    self.index = math.max(1, self.index - self._visible_count)
  end

  self.handlers = {
    page_down = function()
      self.page_down()
    end,
    page_up = function()
      self.page_up()
    end,
    home = function()
      self.index = 1
    end,
    ["end"] = function()
      self.index = self.count
    end,
  }

  return self
end

return M
