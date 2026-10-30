-- Interactive console in the live runtime. This is intentionally not a sandbox.
local hollow = _G.hollow
local ui, shared = hollow.ui, require("hollow.ui.shared")
local layout = ui.layout
local host = require("hollow.state").get().host_api
local tools = require("hollow.ui.widgets.lua_repl.tools")
local console = {}
ui.lua_repl = console

local VISIBLE_CANDIDATES = 7
local OUTPUT_SCROLLBAR = "repl:output:scrollbar"
local KIND_LABELS = {
  ["function"] = "fn",
  table = "table",
  string = "string",
  number = "number",
  boolean = "bool",
  userdata = "userdata",
  thread = "thread",
}

local output, history, active = {}, {}, nil
local output_end, output_budget = 0, 1
local draft, cursor = "", 0
local function pack(...)
  return { n = select("#", ...), ... }
end

local function append(text, kind)
  text = tostring(text):sub(1, 8192):gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in (text .. "\n"):gmatch("(.-)\n") do
    output[#output + 1] = { text = line, kind = kind }
    if #output > 300 then
      table.remove(output, 1)
    end
  end
  output_end = #output
  if active then
    active.invalidate()
  end
end

-- Assignments reach the same globals as config/plugins. Only print is local to
-- console chunks; do not replace _G.print while arbitrary user code runs.
local env = setmetatable({
  print = function(...)
    local values = pack(...)
    for i = 1, values.n do
      values[i] = tools.format(values[i])
    end
    append(table.concat(values, "\t", 1, values.n), "result")
  end,
  inspect = tools.inspect,
}, { __index = _G, __newindex = _G })

local function insert(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  draft = draft:sub(1, cursor) .. text .. draft:sub(cursor + 1)
  cursor = cursor + #text
end

local function previous(pos)
  pos = math.max(0, pos - 1)
  while pos > 0 and (draft:byte(pos + 1) or 0) >= 128 and draft:byte(pos + 1) < 192 do
    pos = pos - 1
  end
  return pos
end

local function following(pos)
  pos = math.min(#draft, pos + 1)
  while pos < #draft and draft:byte(pos + 1) >= 128 and draft:byte(pos + 1) < 192 do
    pos = pos + 1
  end
  return pos
end

local function scroll_output(delta)
  output_end = math.max(1, math.min(#output, output_end + delta))
end

function console.open(opts)
  opts = opts or {}
  if active then
    return active
  end
  local history_index, saved = #history + 1, draft
  local completion
  local handle
  local function replace_completion(value)
    draft = completion.before .. value .. completion.after
    cursor = #completion.before + #value
  end
  local function complete(reverse)
    if completion then
      completion.index = ((completion.index + (reverse and -1 or 1) - 1) % #completion.items) + 1
      return
    end
    completion = tools.complete(draft, cursor, env)
    if not completion then
      insert("  ")
      return
    end
    completion.before, completion.after =
      draft:sub(1, completion.start - 1), draft:sub(completion.stop + 1)
    completion.index = 1
    if #completion.items == 1 then
      replace_completion(completion.items[1])
      completion = nil
      return
    end
    -- Shell-style: extend to the shared prefix while keeping the menu open.
    if #completion.common > #completion.query then
      replace_completion(completion.common)
      completion.query = completion.common
    end
    if reverse then
      completion.index = #completion.items
    end
  end
  local function accept_completion()
    replace_completion(completion.items[math.max(1, completion.index)])
    completion = nil
  end
  local function recall(delta)
    if history_index == #history + 1 then
      saved = draft
    end
    history_index = math.max(1, math.min(#history + 1, history_index + delta))
    draft = history[history_index] or saved
    cursor = #draft
  end
  local function submit(force)
    completion = nil
    if not draft:find("%S") then
      return
    end
    local source = draft
    if source:sub(1, 1) == "=" then
      source = source:sub(2)
    end
    local chunk = loadstring("return " .. source, "=Lua REPL")
    local err
    if not chunk then
      chunk, err = loadstring(source, "=Lua REPL")
    end
    if not chunk and not force and err:match("'<eof>'%s*$") then
      insert("\n")
      return
    end
    append("> " .. draft, "command")
    if history[#history] ~= draft then
      history[#history + 1] = draft
      if #history > 100 then
        table.remove(history, 1)
      end
    end
    draft, cursor, saved, history_index = "", 0, "", #history + 1
    if not chunk then
      append(err, "error")
      return
    end
    setfenv(chunk, env)
    local result = pack(xpcall(chunk, function(message)
      local trace = {}
      for line in (debug.traceback(tostring(message), 2) .. "\n"):gmatch("(.-)\n") do
        trace[#trace + 1] = line
        if #trace == 10 then
          trace[#trace + 1] = "..."
          break
        end
      end
      return table.concat(trace, "\n")
    end))
    if not result[1] then
      append(result[2], "error")
    elseif result.n > 1 then
      local values = {}
      for i = 2, result.n do
        values[#values + 1] = tools.format(result[i])
      end
      append(table.concat(values, "\t"), "result")
    end
  end
  local keys = ui.keys({
    escape = function()
      if completion then
        completion = nil
      else
        handle.close()
      end
    end,
    enter = function()
      if completion then
        accept_completion()
      else
        submit(false)
      end
    end,
    ["<C-enter>"] = function()
      submit(true)
    end,
    ["<S-enter>"] = function()
      insert("\n")
    end,
    ["<C-p>"] = function()
      recall(-1)
    end,
    ["<C-n>"] = function()
      recall(1)
    end,
    arrow_up = function()
      if completion then
        complete(true)
      else
        recall(-1)
      end
    end,
    arrow_down = function()
      if completion then
        complete(false)
      else
        recall(1)
      end
    end,
    ["<C-l>"] = function()
      output = {}
      output_end = 0
    end,
    ["<C-u>"] = function()
      draft, cursor = "", 0
    end,
    ["<C-v>|<C-S-v>|<S-insert>|<D-v>"] = function()
      if host.clipboard_read then
        insert(host.clipboard_read())
      end
    end,
    arrow_left = function()
      cursor = previous(cursor)
    end,
    arrow_right = function()
      cursor = following(cursor)
    end,
    home = function()
      cursor = #(draft:sub(1, cursor):match(".*\n") or "")
    end,
    ["end"] = function()
      cursor = (draft:find("\n", cursor + 1, true) or (#draft + 1)) - 1
    end,
    backspace = function()
      local pos = previous(cursor)
      draft, cursor = draft:sub(1, pos) .. draft:sub(cursor + 1), pos
    end,
    delete = function()
      draft = draft:sub(1, cursor) .. draft:sub(following(cursor) + 1)
    end,
    tab = function()
      complete(false)
    end,
    ["<S-tab>"] = function()
      complete(true)
    end,
    page_up = function()
      scroll_output(-10)
    end,
    page_down = function()
      scroll_output(10)
    end,
    ["<S-arrow_up>"] = function()
      scroll_output(-1)
    end,
    ["<S-arrow_down>"] = function()
      scroll_output(1)
    end,
    ["<C-home>"] = function()
      output_end = 1
    end,
    ["<C-end>"] = function()
      output_end = #output
    end,
    _else = function(key, mods)
      local text = shared.printable_char_for_key(key, mods)
      if text then
        insert(text)
      end
      -- Never let console keystrokes reach terminal shortcuts or the PTY.
      return true
    end,
  })
  handle = ui.modal({
    title = "Lua REPL",
    theme = shared.widget_theme("input", opts.theme),
    width = opts.width or 80,
    height = opts.height,
    align = "bottom",
    backdrop = false,
    keys = function(key, mods)
      if
        key ~= "tab"
        and key ~= "enter"
        and key ~= "escape"
        and key ~= "arrow_up"
        and key ~= "arrow_down"
      then
        completion = nil
      end
      local ok, err = pcall(keys, key, mods)
      if not ok then
        append(err, "error")
      end
      return true
    end,
    on_event = function(name, payload)
      local id = payload and payload.id
      if name == "overlay:scroll" then
        local delta = payload and payload.delta or 0
        if completion and type(id) == "string" and id:match("^repl:candidate:") then
          if delta ~= 0 then
            complete(delta > 0)
          end
        else
          scroll_output(-delta * 3)
        end
        return true
      elseif name == "overlay:scrollbar" and id == OUTPUT_SCROLLBAR then
        local hidden = math.max(0, #output - output_budget)
        output_end = output_budget + math.floor((payload.ratio or 0) * hidden + 0.5)
        return true
      end
      return false
    end,
    on_unmount = function()
      active = nil
    end,
    render = function()
      return {}
    end,
    layout_render = function(theme, _, ctx)
      local h = ctx.cell_h or 19
      local muted = { fg = theme.muted or theme.fg }
      local assist = {}
      if completion then
        local visible = math.min(VISIBLE_CANDIDATES, #completion.items)
        local first = math.max(1, completion.index - math.floor(visible / 2))
        first = math.min(first, #completion.items - visible + 1)
        local last = first + visible - 1
        assist[#assist + 1] = layout.row({
          layout.text(
            completion.path ~= "" and completion.path or "globals",
            { fg = theme.title, bold = true },
            { wrap = "none" }
          ),
          layout.column({}, { width = "grow" }),
          layout.text(
            (first > 1 and "↑ " or "")
              .. (last < #completion.items and "↓ " or "")
              .. completion.index
              .. "/"
              .. #completion.items
              .. " matches",
            muted,
            { wrap = "none" }
          ),
        }, { width = "grow", height = h })
        local typed = #completion.query
        for index = first, last do
          local selected = completion.index == index
          local name = completion.items[index]
          local fg = selected and (theme.selected_fg or theme.title) or theme.fg
          local kind = completion.kinds[name] or "?"
          local runs = {
            layout.text(selected and "▌ " or "  ", { fg = theme.title }, { wrap = "none" }),
          }
          if typed > 0 then
            runs[#runs + 1] = layout.text(
              name:sub(1, typed),
              { fg = theme.title, bold = true },
              { wrap = "none" }
            )
          end
          if #name > typed then
            runs[#runs + 1] = layout.text(
              name:sub(typed + 1),
              { fg = fg, bold = selected },
              { wrap = "none" }
            )
          end
          runs[#runs + 1] = layout.column({}, { width = "grow" })
          runs[#runs + 1] = layout.text(KIND_LABELS[kind] or kind, muted, { wrap = "none" })
          assist[#assist + 1] = layout.row(runs, {
            id = "repl:candidate:" .. index,
            width = "grow",
            height = h,
            style = selected and { bg = theme.selected_bg or theme.cursor_bg } or nil,
            on_click = function()
              if completion then
                completion.index = index
                accept_completion()
              end
            end,
          })
        end
      end
      local selected = completion
          and completion.index > 0
          and (completion.path .. completion.items[completion.index])
        or nil
      local hint = tools.hint(draft, cursor, env, selected)
      if hint then
        assist[#assist + 1] = layout.text(hint, { fg = theme.title }, { wrap = "none" })
      end
      local lines = {}
      local _, newlines = draft:gsub("\n", "")
      local input_rows = math.min(7, newlines + 1)
      local measured = ctx.metrics and ctx.metrics["repl:output"]
      local budget = math.max(
        1,
        math.floor(
          opts.height and measured and measured.height / h
            or ((opts.height or 20) - 5 - input_rows - #assist)
        )
      )
      if not opts.height then
        budget = math.min(12, budget)
      end
      output_budget = budget
      output_end = math.max(math.min(budget, #output), math.min(#output, math.floor(output_end)))
      local hidden = math.max(0, #output - budget)
      local below = #output - output_end
      for i = math.max(1, output_end - budget + 1), output_end do
        local entry = output[i]
        lines[#lines + 1] = layout.column({
          layout.text(entry.text == "" and " " or entry.text, {
            fg = entry.kind == "error" and (theme.error or "#ff7777") or theme.fg,
            bold = entry.kind == "command",
          }, { wrap = "none" }),
        }, { id = "output:" .. i, height = h })
      end
      local input_lines, offset = {}, 0
      for line in (draft .. "\n"):gmatch("(.-)\n") do
        local runs = { layout.text(offset == 0 and "> " or ".. ", { fg = theme.title }) }
        if cursor >= offset and cursor <= offset + #line then
          local col = cursor - offset
          local next_pos = following(cursor) - offset
          runs[#runs + 1] = layout.text(
            line:sub(1, col),
            { fg = theme.input_fg },
            { wrap = "none" }
          )
          runs[#runs + 1] = layout.column({
            layout.text(
              line:sub(col + 1, next_pos) ~= "" and line:sub(col + 1, next_pos) or " ",
              { fg = theme.cursor_fg },
              { wrap = "none" }
            ),
          }, {
            id = "repl:caret",
            style = { bg = theme.cursor_bg },
            height = h,
          })
          runs[#runs + 1] = layout.text(
            line:sub(next_pos + 1),
            { fg = theme.input_fg },
            { wrap = "none" }
          )
        else
          runs[#runs + 1] = layout.text(
            line == "" and " " or line,
            { fg = theme.input_fg },
            { wrap = "none" }
          )
        end
        input_lines[#input_lines + 1] = layout.row(runs, { height = h })
        offset = offset + #line + 1
      end
      local output_rows = math.min(budget, #output)
      local children = {
        layout.row({
          layout.text("Lua REPL", { fg = theme.title, bold = true }),
          layout.column({}, { width = "grow" }),
          below > 0 and layout.text(
            below .. " more below · Ctrl+End latest",
            muted,
            { wrap = "none" }
          ) or false,
        }, { width = "grow", height = h }),
        #lines > 0
            and layout.column(lines, {
              id = "repl:output",
              width = "grow",
              height = opts.height and "grow" or output_rows * h,
              measure = true,
              scroll_x = true,
              padding = hidden > 0 and { left = 0, right = math.max(8, ctx.cell_w or 8) } or nil,
              scrollbar_id = hidden > 0 and OUTPUT_SCROLLBAR or nil,
              scrollbar_thumb_ratio = hidden > 0 and (output_end - budget) / hidden or nil,
              scrollbar_thumb_size = hidden > 0 and budget / #output or nil,
            })
          or false,
        #assist > 0 and layout.column(assist, {
          id = "repl:completion",
          width = "grow",
          height = #assist * h,
          scroll_x = true,
          style = { bg = theme.input_bg },
        }) or false,
        layout.column(input_lines, {
          id = "repl:input",
          width = "grow",
          height = input_rows * h,
          scroll = true,
          scroll_x = true,
          reveal = "repl:caret",
          style = { bg = theme.input_bg },
        }),
        layout.column({
          layout.text(
            completion and "Tab/↑/↓ select · Enter insert · Esc dismiss"
              or (
                "Enter run · Tab complete · Esc close"
                .. (hidden > 0 and " · PgUp/PgDn scroll" or "")
              ),
            muted,
            { wrap = "none" }
          ),
        }, { id = "repl:footer", height = h, width = "grow", scroll_x = true }),
      }
      local child_count = 3 + (#lines > 0 and 1 or 0) + (#assist > 0 and 1 or 0)
      local preferred_height = (2 + output_rows + #assist + input_rows) * h + (child_count - 1) * 4
      return layout.column(children, { width = "grow", height = "grow", gap = 4 }), preferred_height
    end,
  })
  active = handle
  return handle
end

function console.close()
  if active then
    active.close()
  end
end

return console
