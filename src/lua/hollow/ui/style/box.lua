-- CSS-like box shorthand shared by padding and margin.
--
-- Accepted forms: `n`, `{ top, right, bottom, left }` (CSS order, missing
-- sides mirror), `{ x = n, y = n }`, `{ horizontal = n, vertical = n }` and
-- explicit sides. Explicit sides beat axes, axes beat array entries.

local M = {}

local SIDES = { "top", "right", "bottom", "left" }
M.SIDES = SIDES

---@param value any
---@return boolean
local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--- Expand shorthand into only the sides it names. Non-box values (`nil`,
--- `false`, strings) are returned unchanged so merges can keep their meaning.
---@param value any
---@return any
function M.parse(value)
  if type(value) == "number" then
    return { top = value, right = value, bottom = value, left = value }
  end
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  if value[1] ~= nil then
    local top = value[1]
    local right = value[2] or top
    out.top, out.right, out.bottom, out.left = top, right, value[3] or top, value[4] or right
  end
  local x, y = value.x or value.horizontal, value.y or value.vertical
  out.top, out.bottom = value.top or y or out.top, value.bottom or y or out.bottom
  out.left, out.right = value.left or x or out.left, value.right or x or out.right
  return out
end

--- Sanitize one pixel value: non-numeric or non-finite input uses `default`, negatives clamp
--- to zero, and `integer` floors for native surface geometry.
---@param value any
---@param default number
---@param integer? boolean
---@return number
function M.px(value, default, integer)
  if not finite(value) then
    return default
  end
  local number = value
  if integer then
    number = math.floor(number)
  end
  return number < 0 and 0 or number
end

--- Complete box with every side present and sanitized.
---@param value any
---@param integer? boolean
---@return { top: number, right: number, bottom: number, left: number }
function M.normalize(value, integer)
  local parsed = type(value) == "table" and M.parse(value) or nil
  local all = type(value) == "number" and value or 0
  local top = parsed and parsed.top or all
  local right = parsed and parsed.right or top
  local bottom = parsed and parsed.bottom or top
  local left = parsed and parsed.left or right
  return {
    top = M.px(top, 0, integer),
    right = M.px(right, 0, integer),
    bottom = M.px(bottom, 0, integer),
    left = M.px(left, 0, integer),
  }
end

---@param box { top: number, right: number, bottom: number, left: number }
---@return boolean
function M.is_empty(box)
  return box.top <= 0 and box.right <= 0 and box.bottom <= 0 and box.left <= 0
end

return M
