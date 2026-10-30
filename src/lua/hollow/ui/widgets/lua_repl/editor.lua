-- REPL input: draft text, UTF-8 aware cursor and command history.
-- The draft and history survive closing the console.
local M = { text = "", cursor = 0 }
local MAX_HISTORY = 100
local history, history_index, saved = {}, 1, ""

local function continuation_byte(pos)
  local byte = M.text:byte(pos + 1)
  return byte ~= nil and byte >= 128 and byte < 192
end

function M.prev(pos)
  pos = math.max(0, pos - 1)
  while pos > 0 and continuation_byte(pos) do
    pos = pos - 1
  end
  return pos
end

function M.next(pos)
  pos = math.min(#M.text, pos + 1)
  while pos < #M.text and continuation_byte(pos) do
    pos = pos + 1
  end
  return pos
end

function M.set(text, cursor)
  M.text, M.cursor = text, cursor or #text
end

function M.clear()
  M.set("", 0)
end

function M.insert(text)
  text = text:gsub("\r\n?", "\n")
  local before, after = M.text:sub(1, M.cursor), M.text:sub(M.cursor + 1)
  M.set(before .. text .. after, M.cursor + #text)
end

function M.left()
  M.cursor = M.prev(M.cursor)
end

function M.right()
  M.cursor = M.next(M.cursor)
end

function M.line_start()
  M.cursor = #(M.text:sub(1, M.cursor):match(".*\n") or "")
end

function M.line_end()
  M.cursor = (M.text:find("\n", M.cursor + 1, true) or (#M.text + 1)) - 1
end

function M.backspace()
  local pos = M.prev(M.cursor)
  M.set(M.text:sub(1, pos) .. M.text:sub(M.cursor + 1), pos)
end

function M.delete()
  M.text = M.text:sub(1, M.cursor) .. M.text:sub(M.next(M.cursor) + 1)
end

-- Draft lines with the byte offset where each one starts.
function M.lines()
  local lines, offset = {}, 0
  for line in (M.text .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, { text = line, offset = offset })
    offset = offset + #line + 1
  end
  return lines
end

-- Starts history browsing from the current draft.
function M.start_history()
  history_index, saved = #history + 1, M.text
end

function M.recall(delta)
  if history_index == #history + 1 then
    saved = M.text
  end
  history_index = math.max(1, math.min(#history + 1, history_index + delta))
  M.set(history[history_index] or saved)
end

-- Records the submitted draft and clears it.
function M.commit()
  if history[#history] ~= M.text then
    table.insert(history, M.text)
    if #history > MAX_HISTORY then
      table.remove(history, 1)
    end
  end
  M.clear()
  history_index, saved = #history + 1, ""
end

return M
