-- Bounded REPL output and its scroll position. Survives closing the console.
local M = { lines = {}, bottom = 0, rows = 1 }
local MAX_LINES, MAX_CHUNK = 300, 8192

function M.append(text, kind)
  text = tostring(text):sub(1, MAX_CHUNK):gsub("\r\n?", "\n")
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(M.lines, { text = line, kind = kind })
    if #M.lines > MAX_LINES then
      table.remove(M.lines, 1)
    end
  end
  M.bottom = #M.lines
  if M.on_change then
    M.on_change()
  end
end

function M.clear()
  M.lines, M.bottom = {}, 0
end

function M.scroll(delta)
  M.bottom = math.max(1, math.min(#M.lines, M.bottom + delta))
end

function M.oldest()
  M.bottom = 1
end

function M.latest()
  M.bottom = #M.lines
end

-- Scrollbar position: 0 shows the oldest lines, 1 the latest.
function M.scroll_to(ratio)
  local hidden = math.max(0, #M.lines - M.rows)
  M.bottom = M.rows + math.floor(ratio * hidden + 0.5)
end

-- Clamps the scroll position to `rows` visible lines.
-- Returns the first and last visible line and how many lines are hidden.
function M.window(rows)
  local count = #M.lines
  M.rows = rows
  M.bottom = math.max(math.min(rows, count), math.min(count, math.floor(M.bottom)))
  return math.max(1, M.bottom - rows + 1), M.bottom, math.max(0, count - rows)
end

return M
