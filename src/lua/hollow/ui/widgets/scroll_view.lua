local M = {}

local ScrollState = {}
ScrollState.__index = ScrollState

---@param opts { row_budget: integer, row_count_fn?: fun(item: any): integer }
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    scroll_top = 1,
    row_budget = opts.row_budget or 10,
    row_count_fn = opts.row_count_fn,
  }, ScrollState)
end

---@param items any[]
---@param cursor integer 1-based index into items
---@param row_budget integer|nil override the row budget for this frame
---@return integer start_idx, integer end_idx, boolean show_scrollbar, integer thumb_index, number thumb_ratio, number thumb_size
function ScrollState:update(items, cursor, row_budget)
  local budget = row_budget or self.row_budget
  local n = #items
  if n == 0 then
    self.scroll_top = 1
    return 1, 0, false, 1, 0, 1
  end

  local row_fn = self.row_count_fn or function()
    return 1
  end

  cursor = math.max(1, math.min(cursor, n))

  if cursor < self.scroll_top then
    local used = 0
    local new_top = cursor
    for i = cursor, 1, -1 do
      local needed = row_fn(items[i])
      if used + needed > budget then
        break
      end
      used = used + needed
      new_top = i
    end
    self.scroll_top = new_top
  end

  while self.scroll_top < cursor do
    local used = 0
    for i = self.scroll_top, cursor do
      used = used + row_fn(items[i])
      if used > budget then
        break
      end
    end
    if used > budget then
      self.scroll_top = self.scroll_top + 1
    else
      break
    end
  end

  if self.scroll_top > n then
    self.scroll_top = 1
  end

  local used = 0
  local start_idx = self.scroll_top
  local end_idx = n
  for i = start_idx, n do
    local needed = row_fn(items[i])
    if i > start_idx and used + needed > budget then
      end_idx = i - 1
      break
    end
    used = used + needed
    if used >= budget then
      end_idx = i
      break
    end
  end

  local visible_count = end_idx - start_idx + 1
  local show_scrollbar = n > visible_count and visible_count > 1
  local thumb_index = 1
  local thumb_ratio = 0
  local thumb_size = 1
  if show_scrollbar then
    thumb_index = 1 + math.floor(((cursor - 1) * (visible_count - 1)) / math.max(1, n - 1))
    local total_rows = 0
    for i = 1, n do
      total_rows = total_rows + row_fn(items[i])
    end
    thumb_size = math.min(1, used / math.max(1, total_rows))
    local max_top = self:max_scroll_top(items, budget)
    thumb_ratio = (self.scroll_top - 1) / math.max(1, max_top - 1)
  end

  return start_idx, end_idx, show_scrollbar, thumb_index, thumb_ratio, thumb_size
end

---@param items any[]
---@param row_budget integer|nil
---@return integer
function ScrollState:max_scroll_top(items, row_budget)
  local budget = row_budget or self.row_budget
  local row_fn = self.row_count_fn or function()
    return 1
  end
  local used = 0
  local top = #items

  for i = #items, 1, -1 do
    local needed = row_fn(items[i])
    if used > 0 and used + needed > budget then
      break
    end
    used = used + needed
    top = i
  end

  return math.max(1, top)
end

---@param items any[]
---@param direction integer
---@param row_budget integer|nil
---@return integer start_idx, integer end_idx
function ScrollState:scroll_by(items, direction, row_budget)
  local budget = row_budget or self.row_budget
  local n = #items
  if n == 0 then
    self.scroll_top = 1
    return 1, 0
  end

  local row_fn = self.row_count_fn or function()
    return 1
  end
  local max_top = self:max_scroll_top(items, budget)
  self.scroll_top = math.max(1, math.min(max_top, self.scroll_top + direction))

  local used = 0
  local end_idx = n
  for i = self.scroll_top, n do
    local needed = row_fn(items[i])
    if i > self.scroll_top and used + needed > budget then
      end_idx = i - 1
      break
    end
    used = used + needed
    if used >= budget then
      end_idx = i
      break
    end
  end

  return self.scroll_top, end_idx
end

return M
