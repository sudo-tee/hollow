-- REPL layout, top to bottom: title, transcript, completion, input, key hints.
local ui = _G.hollow.ui
local c = ui.components
local completion = require("hollow.ui.widgets.lua_repl.completion")
local editor = require("hollow.ui.widgets.lua_repl.editor")
local eval = require("hollow.ui.widgets.lua_repl.eval")
local tools = require("hollow.ui.widgets.lua_repl.tools")
local transcript = require("hollow.ui.widgets.lua_repl.transcript")
local M = { SCROLLBAR = "repl:output:scrollbar" }

local GAP = 4
local MAX_CANDIDATES = 7
local MAX_INPUT_ROWS = 7
local KIND_LABELS = { ["function"] = "fn", boolean = "bool" }

local function text(value, style)
  return c.text(value, style, { wrap = "none" })
end

local function spacer()
  return c.column({}, { width = "grow" })
end

local function title_bar(theme, h, muted, below)
  return c.row({
    c.text("Lua REPL", { fg = theme.title, bold = true }),
    spacer(),
    ui.when(below > 0, function()
      return text(below .. " more below · Ctrl+End latest", muted)
    end),
  }, { width = "grow", height = h })
end

local function output_view(theme, h, ctx, opts, rows)
  local first, last, hidden = transcript.window(rows)
  local scrolled = hidden > 0
  local lines = ui.each({ unpack(transcript.lines, first, last) }, function(entry, i)
    return c.column({
      text(ui.when(entry.text == "", " ", entry.text), {
        fg = ui.when(entry.kind == "error", theme.error or "#ff7777", theme.fg),
        bold = entry.kind == "command",
      }),
    }, { id = "output:" .. (first + i - 1), height = h })
  end)
  return c.column(lines, {
    id = "repl:output",
    width = "grow",
    height = opts.height and "grow" or #lines * h,
    measure = true,
    scroll_x = true,
    padding = scrolled and { left = 0, right = math.max(8, ctx.cell_w or 8) } or nil,
    scrollbar_id = scrolled and M.SCROLLBAR or nil,
    scrollbar_thumb_ratio = scrolled and (last - rows) / hidden or nil,
    scrollbar_thumb_size = scrolled and rows / #transcript.lines or nil,
  })
end

-- Header plus a window of candidates centred on the selection.
local function candidate_rows(menu, theme, h, muted)
  local count = #menu.items
  local shown = math.min(MAX_CANDIDATES, count)
  local first = math.min(math.max(1, menu.index - math.floor(shown / 2)), count - shown + 1)
  local last = first + shown - 1
  local typed = #menu.query
  local header = c.row({
    text(ui.when(menu.path ~= "", menu.path, "globals"), { fg = theme.title, bold = true }),
    spacer(),
    text(
      ui.when(first > 1, "↑ ", "")
        .. ui.when(last < count, "↓ ", "")
        .. menu.index
        .. "/"
        .. count
        .. " matches",
      muted
    ),
  }, { width = "grow", height = h })
  local candidates = ui.each({ unpack(menu.items, first, last) }, function(name, i)
    local index = first + i - 1
    local selected = index == menu.index
    local kind = menu.kinds[name] or "?"
    return c.row({
      text(ui.when(selected, "▌ ", "  "), { fg = theme.title }),
      ui.when(typed > 0, function()
        return text(name:sub(1, typed), { fg = theme.title, bold = true })
      end),
      ui.when(#name > typed, function()
        return text(name:sub(typed + 1), {
          fg = ui.when(selected, theme.selected_fg or theme.title, theme.fg),
          bold = selected,
        })
      end),
      spacer(),
      text(KIND_LABELS[kind] or kind, muted),
    }, {
      id = "repl:candidate:" .. index,
      width = "grow",
      height = h,
      style = selected and { bg = theme.selected_bg or theme.cursor_bg } or nil,
      on_click = function()
        if completion.menu then
          completion.accept(index)
        end
      end,
    })
  end)
  return { header, candidates }, 1 + shown
end

-- One draft line; the line holding the cursor draws it as a highlighted cell.
local function input_line(line, theme, h)
  local value, offset = line.text, line.offset
  local plain = { fg = theme.input_fg }
  local has_cursor = editor.cursor >= offset and editor.cursor <= offset + #value
  return c.row({
    c.text(ui.when(offset == 0, "> ", ".. "), { fg = theme.title }),
    ui.when(has_cursor, function()
      local col = editor.cursor - offset
      local next_col = editor.next(editor.cursor) - offset
      local under = value:sub(col + 1, next_col)
      return {
        text(value:sub(1, col), plain),
        c.column({
          text(ui.when(under ~= "", under, " "), { fg = theme.cursor_fg }),
        }, { id = "repl:caret", style = { bg = theme.cursor_bg }, height = h }),
        text(value:sub(next_col + 1), plain),
      }
    end, function()
      return text(ui.when(value == "", " ", value), plain)
    end),
  }, { height = h })
end

local function key_hints(muted, h, scrolled)
  local hints = ui.when(
    completion.menu,
    "Tab/↑/↓ select · Enter insert · Esc dismiss",
    "Enter run · Tab complete · Esc close" .. ui.when(scrolled, " · PgUp/PgDn scroll", "")
  )
  return c.column(
    { text(hints, muted) },
    { id = "repl:footer", height = h, width = "grow", scroll_x = true }
  )
end

-- Transcript rows: fill an explicit modal height, otherwise show at most 12.
local function transcript_rows(ctx, opts, h, other_rows)
  local measured = ctx.metrics and ctx.metrics["repl:output"]
  if opts.height and measured then
    return math.max(1, math.floor(measured.height / h))
  end
  local rows = math.max(1, (opts.height or 20) - 5 - other_rows)
  return opts.height and rows or math.min(12, rows)
end

-- Returns the layout and the height it needs when the modal has no fixed height.
function M.render(theme, ctx, opts)
  local h = ctx.cell_h or 19
  local muted = { fg = theme.muted or theme.fg }

  local menu, menu_rows = {}, 0
  if completion.menu then
    menu, menu_rows = candidate_rows(completion.menu, theme, h, muted)
  end
  local hint = tools.hint(editor.text, editor.cursor, eval.env, completion.selected())
  local assist_rows = menu_rows + (hint and 1 or 0)

  local lines = editor.lines()
  local input_rows = math.min(MAX_INPUT_ROWS, #lines)

  local rows = transcript_rows(ctx, opts, h, input_rows + assist_rows)
  local _, last, hidden = transcript.window(rows)
  local output_rows = math.min(rows, #transcript.lines)

  local sections = 3 + (output_rows > 0 and 1 or 0) + (assist_rows > 0 and 1 or 0)
  local height = (2 + output_rows + assist_rows + input_rows) * h + (sections - 1) * GAP

  return c.column({
    title_bar(theme, h, muted, #transcript.lines - last),
    ui.when(output_rows > 0, function()
      return output_view(theme, h, ctx, opts, rows)
    end),
    ui.when(assist_rows > 0, function()
      return c.column({
        menu,
        ui.when(hint, function()
          return text(hint, { fg = theme.title })
        end),
      }, {
        id = "repl:completion",
        width = "grow",
        height = assist_rows * h,
        scroll_x = true,
        style = { bg = theme.input_bg },
      })
    end),
    c.column(
      ui.each(lines, function(line)
        return input_line(line, theme, h)
      end),
      {
        id = "repl:input",
        width = "grow",
        height = input_rows * h,
        scroll = true,
        scroll_x = true,
        reveal = "repl:caret",
        style = { bg = theme.input_bg },
      }
    ),
    key_hints(muted, h, hidden > 0),
  }, { width = "grow", height = "grow", gap = GAP }),
    height
end

return M
