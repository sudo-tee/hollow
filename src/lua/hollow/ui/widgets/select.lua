local shared = require("hollow.ui.shared")
local util   = require("hollow.util")

local table_unpack = table.unpack or unpack

local hollow = _G.hollow

hollow.ui.select = hollow.ui.select or {}

function hollow.ui.select.open(opts)
  opts = opts or {}
  local theme = shared.resolve_widget_theme("select")
  if type(opts.theme) == "table" then util.merge_tables(theme, util.clone_value(opts.theme)) end
  local backdrop = opts.backdrop ~= nil and opts.backdrop or theme.backdrop
  local fuzzy    = opts.fuzzy ~= false
  local items    = opts.items or {}
  local label    = opts.label or tostring
  local detail   = type(opts.detail) == "function" and opts.detail or nil
  local s        = { index = 1, query = opts.query or "", scroll_top = 1 }

  -- Filtering & scoring ------------------------------------------------------

  local function filtered_entries()
    local entries = {}
    for source_index, item in ipairs(items) do
      local label_nodes = shared.normalize_inline_nodes(label(item))
      local label_text  = shared.nodes_plain_text(label_nodes)
      local detail_nodes, detail_text
      if detail then
        local dv = detail(item)
        detail_nodes = shared.normalize_inline_nodes(dv)
        detail_text  = shared.nodes_plain_text(detail_nodes)
        if detail_text == "" then detail_nodes = nil; detail_text = nil end
      end
      local searchable = label_text
      if detail_text then searchable = searchable .. "\n" .. detail_text end
      local matches, score = shared.select_item_matches(s.query, searchable, fuzzy)
      if matches then
        entries[#entries + 1] = {
          item         = item,
          label_nodes  = label_nodes,
          label_text   = label_text,
          detail_nodes = detail_nodes,
          detail_text  = detail_text,
          source_index = source_index,
          score        = score or 0,
        }
      end
    end
    if fuzzy and s.query ~= "" then
      table.sort(entries, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.label_text ~= b.label_text then return a.label_text < b.label_text end
        return a.source_index < b.source_index
      end)
    end
    return entries
  end

  local function clamp_index(entries)
    if     #entries == 0        then s.index = 0
    elseif s.index < 1          then s.index = 1
    elseif s.index > #entries   then s.index = #entries end
  end

  -- Viewport -----------------------------------------------------------------

  local default_total_rows = 14

  local function entry_row_count(entry)
    return (entry.detail_text and entry.detail_text ~= "") and 2 or 1
  end

  local function list_row_budget()
    local total    = shared.normalize_overlay_size(opts.height)
      or shared.normalize_overlay_size(opts.max_height)
      or default_total_rows
    local reserved = 4
    if #(opts.actions or {}) > 0 then reserved = reserved + 2 end
    return math.max(1, total - reserved)
  end

  local function rows_between(entries, first, last)
    local used = 0
    if first == nil or last == nil then return used end
    for i = first, last do
      local e = entries[i]
      if e then used = used + entry_row_count(e) end
    end
    return used
  end

  local function visible_entries(entries)
    local budget     = list_row_budget()
    if #entries == 0 then s.scroll_top = 1; return {} end
    clamp_index(entries)
    local scroll_top = math.max(1, math.min(s.scroll_top or 1, #entries))
    if s.index < scroll_top then scroll_top = s.index end
    while scroll_top < s.index and rows_between(entries, scroll_top, s.index) > budget do
      scroll_top = scroll_top + 1
    end
    local visible, used, i = {}, 0, scroll_top
    while i <= #entries do
      local e = entries[i]
      local need = entry_row_count(e)
      if #visible > 0 and used + need > budget then break end
      visible[#visible + 1] = e
      used = used + need
      if used >= budget then break end
      i = i + 1
    end
    s.scroll_top = scroll_top
    return visible
  end

  local function selected_entry(entries) return entries[s.index] or nil end

  -- Actions ------------------------------------------------------------------

  local function invoke_action(action_index)
    local entries = filtered_entries()
    clamp_index(entries)
    local action = opts.actions and opts.actions[action_index]
    if action == nil then return false end
    local entry = entries[s.index]
    if entry and type(action.fn) == "function" then action.fn(entry.item) end
    return true
  end

  local function match_action_for_key(key, mods)
    for i, action in ipairs(opts.actions or {}) do
      local hint = action.key
      if type(hint) == "string" and hint ~= "" then
        local norm = hint:lower():gsub("<cr>", "<enter>")
        if norm == "<enter>" and key == "enter" and mods == "" then return i end
        local em, ek = norm:match("^<([csa%-d]+)%-(.+)>$")
        if em and ek then
          local parts = {}
          if em:find("c",1,true) then parts[#parts+1]="C" end
          if em:find("s",1,true) then parts[#parts+1]="S" end
          if em:find("a",1,true) then parts[#parts+1]="A" end
          if em:find("d",1,true) then parts[#parts+1]="D" end
          local canon = #parts > 0 and ("<"..table.concat(parts,"-")..">") or ""
          if canon == mods and ek == key then return i end
        elseif norm == key and mods == "" then
          return i
        end
      end
    end
    return nil
  end

  -- Rendering ----------------------------------------------------------------

  local function render_empty_row()
    local t = hollow.ui.tags
    return t.overlay_row(nil, t.text({ fg = theme.empty }, " No matches"))
  end

  local function render_entry_rows(entry, is_selected, show_scrollbar, vis_idx, thumb_idx)
    local t = hollow.ui.tags
    local label_nodes = {
      hollow.ui.span(is_selected and "> " or "  ",
        { fg = is_selected and theme.selected_fg or theme.fg, bold = is_selected }),
    }
    for _, n in ipairs(entry.label_nodes or {}) do label_nodes[#label_nodes+1] = n end

    local detail_row
    if entry.detail_text and entry.detail_text ~= "" then
      local dn = { hollow.ui.span("   ", { fg = is_selected and theme.selected_muted or theme.detail }) }
      for _, n in ipairs(entry.detail_nodes or {}) do dn[#dn+1] = n end
      detail_row = t.overlay_row(
        { fill_bg = is_selected and theme.selected_detail_bg or nil },
        hollow.ui.group(dn, { fg = is_selected and theme.selected_muted or theme.detail })
      )
    end

    return hollow.ui.rows(
      t.overlay_row({
        fill_bg              = is_selected and theme.selected_bg or nil,
        scrollbar_track      = show_scrollbar,
        scrollbar_thumb      = show_scrollbar and vis_idx == thumb_idx,
        scrollbar_track_color = theme.scrollbar_track,
        scrollbar_thumb_color = theme.scrollbar_thumb,
      }, hollow.ui.group(label_nodes,
           { fg = is_selected and theme.selected_fg or theme.fg, bold = is_selected })),
      detail_row
    )
  end

  local function normalize_hint_chord(raw)
    local parse = hollow.keymap.parse_chord
    local fmt   = hollow.keymap.format_chord
    if type(parse) ~= "function" or type(fmt) ~= "function" then return raw end
    local ok, key, mods = pcall(parse, raw)
    return ok and fmt(key, mods) or raw
  end

  local function render_hint_rows()
    local t          = hollow.ui.tags
    local hint_nodes = {}
    for _, action in ipairs(opts.actions or {}) do
      local key_hint = action.key
        or (action.name == (opts.actions[1] and opts.actions[1].name) and "<CR>" or nil)
      if key_hint then
        local chord = normalize_hint_chord(key_hint)
        local desc  = action.desc or action.name or "action"
        if #hint_nodes > 0 then hint_nodes[#hint_nodes+1] = t.text({ fg = theme.divider }, "  ") end
        hint_nodes[#hint_nodes+1] = t.text({ fg = theme.panel_border, bold = true }, chord)
        hint_nodes[#hint_nodes+1] = t.text({ fg = theme.muted }, " " .. desc)
      end
    end
    if #hint_nodes == 0 then return nil end
    return hollow.ui.rows(
      t.divider({ color = theme.divider }),
      t.overlay_row(nil, table_unpack(hint_nodes))
    )
  end

  local function append_rows(dst, value)
    if value == nil then return dst end
    for _, row in ipairs(hollow.ui.rows(value)) do dst[#dst+1] = row end
    return dst
  end

  -- Widget -------------------------------------------------------------------

  local widget
  widget = hollow.ui.overlay.new({
    render = function()
      local t          = hollow.ui.tags
      local entries    = filtered_entries()
      clamp_index(entries)
      local visible    = visible_entries(entries)
      local selected   = selected_entry(entries)
      local counter    = (#entries > 0) and string.format(" %d/%d", s.index, #entries) or nil
      local show_sb    = #entries > #visible and #visible > 1
      local thumb_idx  = 1
      if show_sb then
        thumb_idx = 1 + math.floor(((s.index - 1) * (#visible - 1)) / math.max(1, #entries - 1))
      end
      local rows = hollow.ui.rows(
        t.overlay_row(nil,
          t.text({ fg = theme.title, bold = true }, (opts.prompt or "Select") .. ":"),
          t.text({ fg = theme.counter }, counter and ("  " .. counter) or "")
        ),
        t.divider({ color = theme.divider }),
        t.overlay_row(nil,
          t.text({ fg = theme.title, bold = true }, "Filter: "),
          t.text({ fg = theme.input_fg, bg = theme.input_bg }, s.query),
          t.text({ fg = theme.cursor_fg, bg = theme.cursor_bg, bold = true }, " ")
        ),
        t.divider({ color = theme.divider })
      )
      if #entries == 0 then rows[#rows+1] = render_empty_row() end
      for vi, entry in ipairs(visible) do
        local is_sel = selected ~= nil and entry.source_index == selected.source_index
        append_rows(rows, render_entry_rows(entry, is_sel, show_sb, vi, thumb_idx))
      end
      append_rows(rows, render_hint_rows())
      return rows
    end,
    on_key = function(key, mods)
      local entries = filtered_entries()
      clamp_index(entries)
      if key == "escape" then
        hollow.ui.close_overlay_widget(widget)
        if type(opts.on_cancel) == "function" then opts.on_cancel() end
        return true
      end
      if key == "arrow_down" then
        if #entries > 0 then
          s.index = (s.index >= #entries) and 1 or math.max(1, s.index) + 1
          if s.index == 1 then s.scroll_top = 1 end
        end
        return true
      end
      if key == "arrow_up" then
        if #entries > 0 then
          s.index = (s.index <= 1) and #entries or math.max(1, s.index - 1)
        end
        return true
      end
      if key == "backspace" and mods == "" then
        s.query = s.query:sub(1, math.max(0, #s.query - 1))
        s.index = 1
        return true
      end
      local printable = shared.printable_char_for_key(key, mods)
      if printable ~= nil then s.query = s.query .. printable; s.index = 1; return true end
      local ai = match_action_for_key(key, mods or "")
      if ai ~= nil then return invoke_action(ai) end
      if key == "enter" then return invoke_action(1) end
      return false
    end,
    width      = opts.width,
    height     = opts.height,
    max_height = opts.max_height,
    chrome     = opts.chrome or { bg = theme.panel_bg, border = theme.panel_border },
    backdrop   = backdrop,
  })
  hollow.ui.overlay.push(widget)
end

function hollow.ui.select.close() hollow.ui.overlay.pop() end
