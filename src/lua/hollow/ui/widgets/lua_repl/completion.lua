-- Tab completion over the REPL draft. `M.menu` is the open menu, if any.
local editor = require("hollow.ui.widgets.lua_repl.editor")
local eval = require("hollow.ui.widgets.lua_repl.eval")
local tools = require("hollow.ui.widgets.lua_repl.tools")
local M = { menu = nil }

local function replace_word(value)
  local menu = M.menu
  editor.set(menu.before .. value .. menu.after, #menu.before + #value)
end

function M.close()
  M.menu = nil
end

function M.accept(index)
  replace_word(M.menu.items[index or M.menu.index])
  M.menu = nil
end

-- Moves through an open menu, or opens one for the word under the cursor.
function M.cycle(reverse)
  local menu = M.menu
  if menu then
    menu.index = (menu.index - 1 + (reverse and -1 or 1)) % #menu.items + 1
    return
  end
  menu = tools.complete(editor.text, editor.cursor, eval.env)
  if not menu then
    editor.insert("  ")
    return
  end
  menu.before = editor.text:sub(1, menu.start - 1)
  menu.after = editor.text:sub(menu.stop + 1)
  M.menu = menu
  if #menu.items == 1 then
    M.accept(1)
    return
  end
  -- Shell-style: extend to the shared prefix while keeping the menu open.
  if #menu.common > #menu.query then
    replace_word(menu.common)
    menu.query = menu.common
  end
  menu.index = reverse and #menu.items or 1
end

-- Full name of the highlighted candidate, for the signature hint.
function M.selected()
  local menu = M.menu
  return menu and (menu.path .. menu.items[menu.index]) or nil
end

return M
