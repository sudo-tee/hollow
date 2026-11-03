-- One-shot actions and explicit (= prefixed) Lua, sharing the console engine.
local hollow = _G.hollow
local ui, c = hollow.ui, hollow.ui.components
local editor =
  require("hollow.ui.widgets.lua_repl.editor").new({ history_name = "command_line_history" })
local eval = require("hollow.ui.widgets.lua_repl.eval")
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")
local tools = require("hollow.ui.widgets.lua_repl.tools")
local view = require("hollow.ui.widgets.lua_repl.view")
local host = require("hollow.state").get().host_api
local M = {}
ui.command_line = M
local active, options, error_text

local function lua_mode()
  return editor.text:sub(1, 1) == "="
end

local function action_spec(name)
  for _, spec in ipairs(hollow.action.list()) do
    if spec.name == name then
      return spec
    end
  end
end

-- Find an unfinished top-level JSON key, ignoring braces/commas in strings.
local function key_query(source)
  local depth, quoted, escaped, start, expecting = 0, false, false, nil, false
  local used = {}
  for i = 1, #source do
    local ch = source:sub(i, i)
    if quoted then
      if escaped then
        escaped = false
      elseif ch == "\\" then
        escaped = true
      elseif ch == '"' then
        quoted = false
        if start then
          used[source:sub(start, i - 1)] = true
          start = nil
          expecting = false
        end
      end
    elseif ch == '"' then
      quoted = true
      if depth == 1 and expecting then
        start = i + 1
      end
    elseif ch == "{" or ch == "[" then
      depth = depth + 1
      expecting = ch == "{" and depth == 1
    elseif ch == "}" or ch == "]" then
      depth, expecting = depth - 1, false
    elseif depth == 1 and ch == "," then
      expecting = true
    elseif depth == 1 and ch == ":" then
      expecting = false
    end
  end
  if start then
    return start, source:sub(start), used
  elseif depth == 1 and expecting and not quoted then
    return #source + 1, "", used, true
  end
end

local function complete(source, cursor, env)
  if source:sub(1, 1) == "=" then
    local menu = tools.complete(source:sub(2), cursor - 1, env)
    if menu then
      menu.start, menu.stop = menu.start + 1, menu.stop + 1
    end
    return menu
  end
  local before = source:sub(1, cursor)
  local items, kinds, query, start, stop, path = {}, {}, before, 1, cursor, "actions"
  if not before:find("%s") then
    for _, spec in ipairs(hollow.action.list()) do
      if spec.name:sub(1, #query) == query then
        items[#items + 1], kinds[spec.name] = spec.name, "action"
      end
    end
    stop = cursor + #(source:sub(cursor + 1):match("^%S*") or "")
  else
    local name, args = before:match("^(%S+)%s+(.*)$")
    local spec = name and action_spec(name)
    local fields = spec and spec.arguments and spec.arguments._fields
    if not fields then
      return
    end
    local offset = #before - #args
    local used, needs_quote
    start, query, used, needs_quote = key_query(args)
    if not start then
      return
    end
    start, path = start + offset, name .. " arguments"
    local suffix = source:sub(cursor + 1)
    stop = cursor + #(suffix:match('^[%w_]*"?%s*:?%s*') or "")
    for field in pairs(fields) do
      if type(field) == "string" and not used[field] and field:sub(1, #query) == query then
        local encoded = hollow.json.encode(field)
        local value = (needs_quote and encoded or encoded:sub(2)) .. ": "
        items[#items + 1], kinds[value] = value, "field"
      end
    end
  end
  table.sort(items)
  while #items > 128 do
    table.remove(items)
  end
  if #items == 0 then
    return
  end
  local common = items[1]
  for i = 2, #items do
    while items[i]:sub(1, #common) ~= common do
      common = common:sub(1, -2)
    end
  end
  return {
    items = items,
    kinds = kinds,
    query = query,
    common = common,
    start = start,
    stop = stop,
    path = path,
  }
end

local completion = require("hollow.ui.widgets.lua_repl.completion").new(editor, eval.env, complete)

function M.close()
  if active then
    active.close()
  end
end

local function submit()
  if not editor.text:find("%S") then
    return
  end
  local source, is_lua = editor.text, lua_mode()
  local name, args
  if not is_lua then
    local raw
    name, raw = source:match("^%s*(%S+)%s*(.-)%s*$")
    if raw ~= "" then
      local ok, value = pcall(hollow.json.decode, raw)
      if not ok or type(value) ~= "table" or raw:sub(1, 1) ~= "{" then
        error_text = "Arguments must be a JSON object"
        return
      end
      args = value
    end
  end
  -- Actions/Lua may open another modal; release ours before dispatching.
  local opts = options
  M.close()
  local output, output_bytes = {}, 0
  local function append(text, kind)
    if kind == "error" then
      error_text = text
    end
    if output_bytes < 8192 then
      text = text:sub(1, 8192 - output_bytes)
      output[#output + 1], output_bytes = text, output_bytes + #text + 1
    end
  end
  error_text = nil
  local success
  if is_lua then
    success = eval.execute(source:sub(2), true, append) == "ok"
  else
    local result = hollow.action.invoke(name, args, { origin = "command_line" })
    success, error_text = result.success, result.error
  end
  if not success then
    error_text = ((error_text or ""):match("[^\n]+") or "Execution failed"):sub(1, 512)
    if not M.open({ width = opts.width, theme = opts.theme }) then
      ui.notify.error(error_text)
    end
    return
  end
  -- Restore submitted text in case executed code touched this widget's draft.
  editor.set(source)
  editor.commit()
  if #output > 0 then
    local preview, truncated = {}, output_bytes >= 8192
    for line in (table.concat(output, "\n") .. "\n"):gmatch("(.-)\n") do
      if #preview == 6 then
        truncated = true
        break
      end
      if #line > 240 then
        truncated = true
      end
      preview[#preview + 1] = line:sub(1, 240)
    end
    if truncated then
      preview[#preview + 1] = "… truncated; use REPL for full inspection"
    end
    ui.notify.show(table.concat(preview, "\n"), {
      title = "Lua result",
      id = "command_line:result",
      ttl = 6000,
    })
  end
end

local function promote()
  if not lua_mode() then
    return
  end
  local draft = editor.text:sub(2)
  M.close()
  ui.lua_repl.open({ text = draft })
end

local function render(theme, _, ctx)
  local h, muted = props.cell_h(ctx), { fg = theme.muted or theme.fg }
  local menu, rows = {}, 0
  if completion.menu then
    menu, rows = view.candidate_rows(completion.menu, theme, h, muted, completion, "cmdline")
  end
  local hint
  if lua_mode() then
    hint = tools.hint(editor.text:sub(2), editor.cursor - 1, eval.env, completion.selected())
  else
    local spec = action_spec(editor.text:match("^(%S+)"))
    hint = spec and (spec.desc .. (spec.arguments and " · JSON arguments" or ""))
  end
  local lines = editor.lines()
  local input_rows = math.min(3, #lines)
  local assist = (error_text and 1 or 0) + (hint and 1 or 0)
  return c.column({
    menu,
    ui.when(hint, function()
      return c.text(hint, muted, { wrap = "none" })
    end),
    ui.when(error_text, function()
      return c.text(error_text, { fg = theme.error or "#ff7777" }, { wrap = "none" })
    end),
    c.column(
      ui.each(lines, function(line)
        return view.input_line(
          line,
          theme,
          h,
          editor,
          "cmdline",
          lua_mode() and "Lua > " or "Action > "
        )
      end),
      {
        id = "cmdline:input",
        width = "grow",
        height = input_rows * h,
        scroll = true,
        scroll_x = true,
        reveal = "cmdline:caret",
        style = { bg = theme.input_bg },
      }
    ),
    c.hints({
      id = "cmdline:hints",
      height = h,
      width = "grow",
      plain = true,
      separator = " · ",
      description_style = muted,
      { "Enter", completion.menu and "insert" or "run" },
      { "Tab", "complete" },
      { "Esc", "close" },
      { "=", "Lua" },
      { "Ctrl+R", "REPL" },
    }),
  }, { width = "grow", height = "grow" }),
    (rows + assist + input_rows + 1) * h
end

function M.open(opts)
  if active then
    return active
  end
  opts = opts or {}
  local keys = ui.keys({
    escape = function()
      if completion.menu then
        completion.close()
      else
        M.close()
      end
    end,
    enter = function()
      if completion.menu then
        completion.accept()
      else
        submit()
      end
    end,
    tab = function()
      completion.cycle(false)
    end,
    ["<S-tab>"] = function()
      completion.cycle(true)
    end,
    arrow_up = function()
      if completion.menu then
        completion.cycle(true)
      else
        editor.recall(-1, true)
      end
    end,
    arrow_down = function()
      if completion.menu then
        completion.cycle(false)
      else
        editor.recall(1, true)
      end
    end,
    ["<C-p>"] = function()
      completion.close()
      editor.recall(-1)
    end,
    ["<C-n>"] = function()
      completion.close()
      editor.recall(1)
    end,
    ["<C-r>"] = promote,
    ["<C-u>"] = editor.clear,
    arrow_left = editor.left,
    arrow_right = editor.right,
    home = editor.line_start,
    ["end"] = editor.line_end,
    backspace = editor.backspace,
    delete = editor.delete,
    ["<C-v>|<C-S-v>|<S-insert>|<D-v>"] = function()
      if host.clipboard_read then
        editor.insert(host.clipboard_read())
      end
    end,
    _else = function(key, mods)
      local text = shared.printable_char_for_key(key, mods)
      if text then
        editor.insert(text)
      end
      return true
    end,
  })
  active = ui.modal({
    title = "Command line",
    theme = shared.widget_theme("input", opts.theme),
    width = opts.width or 80,
    align = "bottom",
    backdrop = false,
    render = render,
    keys = function(key, mods)
      local before, cursor, was_open = editor.text, editor.cursor, completion.menu ~= nil
      keys(key, mods)
      if editor.text ~= before or editor.cursor ~= cursor then
        error_text = nil
        if was_open and key ~= "enter" and key ~= "tab" then
          completion.refresh()
        end
      end
      return true
    end,
    on_event = function(name, payload)
      if name == "overlay:scroll" and completion.menu then
        local delta = payload and payload.delta or 0
        if delta ~= 0 then
          completion.cycle(delta > 0)
        end
        return true
      end
      return false
    end,
    on_unmount = function()
      active = nil
      completion.close()
    end,
  })
  if active then
    options = opts
    if opts.text ~= nil then
      editor.set(opts.text)
      error_text = nil
    end
    editor.start_history()
  end
  return active
end

return M
