-- Interactive Lua console in the live runtime. This is intentionally not a sandbox.
--   editor.lua      draft text, cursor and history
--   eval.lua        runs code and writes results
--   transcript.lua  output lines and scrolling
--   completion.lua  Tab completion menu
--   view.lua        layout
local hollow = _G.hollow
local ui, shared = hollow.ui, require("hollow.ui.shared")
local host = require("hollow.state").get().host_api
local completion = require("hollow.ui.widgets.lua_repl.completion")
local editor = require("hollow.ui.widgets.lua_repl.editor")
local eval = require("hollow.ui.widgets.lua_repl.eval")
local transcript = require("hollow.ui.widgets.lua_repl.transcript")
local view = require("hollow.ui.widgets.lua_repl.view")
local console = {}
ui.lua_repl = console

local active
transcript.on_change = function()
  if active then
    active.invalidate()
  end
end

-- Keys that keep the completion menu open; any other key closes it.
local MENU_KEYS = { tab = true, enter = true, escape = true, arrow_up = true, arrow_down = true }

local function bind(fn, arg)
  return function()
    fn(arg)
  end
end

-- `with_menu` runs while the completion menu is open, `otherwise` when it is not.
local function menu_or(with_menu, otherwise)
  return function()
    if completion.menu then
      with_menu()
    else
      otherwise()
    end
  end
end

local function submit(force)
  completion.close()
  if not editor.text:find("%S") then
    return
  end
  if eval.run(editor.text, force) then
    editor.commit()
  else
    editor.insert("\n")
  end
end

local function paste()
  if host.clipboard_read then
    editor.insert(host.clipboard_read())
  end
end

-- Handlers receive (key, mods); only _else uses them.
local KEY_ACTIONS = {
  escape = menu_or(completion.close, function()
    console.close()
  end),
  enter = menu_or(bind(completion.accept), bind(submit, false)),
  ["<C-enter>"] = bind(submit, true),
  ["<S-enter>"] = bind(editor.insert, "\n"),
  ["<C-v>|<C-S-v>|<S-insert>|<D-v>"] = paste,
  tab = bind(completion.cycle, false),
  ["<S-tab>"] = bind(completion.cycle, true),

  arrow_up = menu_or(bind(completion.cycle, true), bind(editor.recall, -1)),
  arrow_down = menu_or(bind(completion.cycle, false), bind(editor.recall, 1)),
  ["<C-p>"] = bind(editor.recall, -1),
  ["<C-n>"] = bind(editor.recall, 1),

  arrow_left = editor.left,
  arrow_right = editor.right,
  home = editor.line_start,
  ["end"] = editor.line_end,
  backspace = editor.backspace,
  delete = editor.delete,
  ["<C-u>"] = editor.clear,

  page_up = bind(transcript.scroll, -10),
  page_down = bind(transcript.scroll, 10),
  ["<S-arrow_up>"] = bind(transcript.scroll, -1),
  ["<S-arrow_down>"] = bind(transcript.scroll, 1),
  ["<C-home>"] = transcript.oldest,
  ["<C-end>"] = transcript.latest,
  ["<C-l>"] = transcript.clear,

  _else = function(key, mods)
    local text = shared.printable_char_for_key(key, mods)
    if text then
      editor.insert(text)
    end
    -- Never let console keystrokes reach terminal shortcuts or the PTY.
    return true
  end,
}

local keys
local function on_key(key, mods)
  -- Built on first use: ui.keys needs the keymap, which loads after this module.
  keys = keys or ui.keys(KEY_ACTIONS)
  if not MENU_KEYS[key] then
    completion.close()
  end
  local ok, err = pcall(keys, key, mods)
  if not ok then
    transcript.append(err, "error")
  end
  return true
end

local function on_event(name, payload)
  payload = payload or {}
  if name == "overlay:scroll" then
    local delta = payload.delta or 0
    local over_menu = type(payload.id) == "string" and payload.id:match("^repl:candidate:")
    if completion.menu and over_menu then
      if delta ~= 0 then
        completion.cycle(delta > 0)
      end
    else
      transcript.scroll(-delta * 3)
    end
    return true
  elseif name == "overlay:scrollbar" and payload.id == view.SCROLLBAR then
    transcript.scroll_to(payload.ratio or 0)
    return true
  end
  return false
end

function console.open(opts)
  opts = opts or {}
  if active then
    return active
  end
  editor.start_history()
  active = ui.modal({
    title = "Lua REPL",
    theme = shared.widget_theme("input", opts.theme),
    width = opts.width or 80,
    height = opts.height,
    align = "bottom",
    backdrop = false,
    keys = on_key,
    on_event = on_event,
    on_unmount = function()
      active = nil
    end,
    render = function(theme, _, ctx)
      return view.render(theme, ctx, opts)
    end,
  })
  return active
end

function console.close()
  if active then
    active.close()
  end
end

return console
