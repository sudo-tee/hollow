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

local active, docked
-- True while dispatching a key from the docked pane rather than the modal.
local docked_key = false
transcript.on_change = function()
  if active then
    active.invalidate()
  end
  if docked then
    docked:invalidate()
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
  -- The docked pane stays open on Escape; it closes like any other pane.
  escape = menu_or(completion.close, function()
    console.close()
  end),
  enter = menu_or(bind(completion.accept), bind(submit, false)),
  ["<C-enter>"] = bind(submit, true),
  ["<S-enter>"] = bind(editor.insert, "\n"),
  ["<C-v>|<C-S-v>|<S-insert>|<D-v>"] = paste,
  tab = bind(completion.cycle, false),
  ["<S-tab>"] = bind(completion.cycle, true),

  arrow_up = menu_or(bind(completion.cycle, true), function()
    editor.recall(-1, true)
  end),
  arrow_down = menu_or(bind(completion.cycle, false), function()
    editor.recall(1, true)
  end),
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
      return true
    end
    -- The modal never lets keystrokes reach terminal shortcuts or the PTY. The
    -- docked pane releases unbound keys so pane focus/navigation bindings work.
    return not docked_key
  end,
}

local keys
local function on_key(key, mods)
  -- Built on first use: ui.keys needs the keymap, which loads after this module.
  keys = keys or ui.keys(KEY_ACTIONS)
  local was_open, before, cursor = completion.menu ~= nil, editor.text, editor.cursor
  local ok, handled = pcall(keys, key, mods)
  if was_open and not MENU_KEYS[key] then
    if editor.text ~= before or editor.cursor ~= cursor then
      completion.refresh()
    else
      completion.close()
    end
  end
  if not ok then
    transcript.append(handled, "error")
    return true
  end
  return handled or not docked_key
end

-- Chords bound with explicit non-Shift modifiers, as "<mods>:key".
local exact_chords
local function bound_exactly(key, mods)
  if not exact_chords then
    exact_chords = {}
    for spec in pairs(KEY_ACTIONS) do
      for alias in spec:gmatch("[^|]+") do
        if alias:sub(1, 1) == "<" then
          local k, m = hollow.keymap.parse_chord(alias)
          exact_chords[hollow.keymap.format_mods(m) .. ":" .. k] = true
        end
      end
    end
  end
  return exact_chords[mods .. ":" .. key] == true
end

local function on_docked_key(key, mods)
  -- Bare bindings match any modifiers, so Ctrl/Alt chords would otherwise be
  -- eaten (e.g. <C-S-Left> as arrow_left) instead of reaching pane focus/close.
  if mods ~= "" and mods ~= "<S>" and not bound_exactly(key, mods) then
    return false
  end
  docked_key = true
  local ok, handled = pcall(on_key, key, mods)
  docked_key = false
  if not ok then
    error(handled, 0)
  end
  return handled
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
  if opts.text ~= nil then
    editor.set(opts.text)
    completion.close()
    if active then
      active.invalidate()
    end
  end
  if active then
    return active
  end
  editor.start_history()
  active = ui.modal({
    title = "Lua REPL",
    exclusive = false,
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

-- Docked variant: the same console state rendered in a native Lua pane, which
-- survives config reload through this factory.
ui.pane.register("hollow.lua_repl", function()
  return {
    title = "Lua REPL",
    capture_keys = true,
    on_mount = function(ctx)
      docked = ui.pane.get(ctx.pane_id)
      editor.start_history()
    end,
    on_unmount = function(ctx)
      if docked and docked.id == ctx.pane_id then
        docked = nil
      end
    end,
    on_key = on_docked_key,
    on_pointer = function(event)
      if event.kind == "scroll" then
        return on_event("overlay:scroll", { delta = event.delta, id = event.id })
      end
    end,
    render = function(ctx)
      return (view.render(shared.widget_theme("input"), ctx, { height = ctx.rows, docked = true }))
    end,
  }
end)

--- Toggle the REPL as a split pane; the modal stays available separately.
function console.dock(opts)
  opts = opts or {}
  if docked then
    docked:close()
    return nil
  end
  return ui.pane.split({
    module = "hollow.lua_repl",
    direction = opts.direction or "horizontal",
    ratio = opts.ratio or 0.35,
  })
end

return console
