local shared = require("hollow.ui.shared")
local util = require("hollow.util")

local table_unpack = table.unpack or unpack

---@type Hollow
local hollow = _G.hollow
---@type HollowUi
local ui = hollow.ui

ui.select = ui.select or {}

local DEFAULT_TOTAL_ROWS = 14

---@param theme HollowUiTheme
---@param opts HollowUiSelectOptions
---@return HollowUiTheme
local function resolve_select_theme(theme, opts)
  if type(opts.theme) == "table" then
    util.merge_tables(theme, util.clone_value(opts.theme))
  end
  return theme
end

---@param entry HollowUiSelectEntry
---@return integer
local function entry_row_count(entry)
  return (entry.detail_text and entry.detail_text ~= "") and 2 or 1
end

---@param entries HollowUiSelectEntry[]
---@param first integer|nil
---@param last integer|nil
---@return integer
local function rows_between(entries, first, last)
  local used = 0
  if first == nil or last == nil then
    return used
  end

  for index = first, last do
    local entry = entries[index]
    if entry then
      used = used + entry_row_count(entry)
    end
  end

  return used
end

---@param opts HollowUiSelectOptions
---@return integer
local function list_row_budget(opts)
  local total = shared.normalize_overlay_size(opts.height)
    or shared.normalize_overlay_size(opts.max_height)
    or DEFAULT_TOTAL_ROWS
  local reserved = 4

  if #(opts.actions or {}) > 0 then
    reserved = reserved + 2
  end

  return math.max(1, total - reserved)
end

---@param raw string
---@return string
local function normalize_hint_chord(raw)
  local parse = hollow.keymap.parse_chord
  local format = hollow.keymap.format_chord
  if type(parse) ~= "function" or type(format) ~= "function" then
    return raw
  end

  local ok, key, mods = pcall(parse, raw)
  if ok then
    return format(key, mods)
  end

  return raw
end

---@param hint string
---@param key string
---@param mods string
---@return boolean
local function action_matches_hint(hint, key, mods)
  local normalized = hint:lower():gsub("<cr>", "<enter>")
  if normalized == "<enter>" and key == "enter" and mods == "" then
    return true
  end

  local encoded_mods, encoded_key = normalized:match("^<([csa%-d]+)%-(.+)>$")
  if encoded_mods ~= nil and encoded_key ~= nil then
    local parts = {}
    if encoded_mods:find("c", 1, true) then
      parts[#parts + 1] = "C"
    end
    if encoded_mods:find("s", 1, true) then
      parts[#parts + 1] = "S"
    end
    if encoded_mods:find("a", 1, true) then
      parts[#parts + 1] = "A"
    end
    if encoded_mods:find("d", 1, true) then
      parts[#parts + 1] = "D"
    end

    local canonical_mods = #parts > 0 and ("<" .. table.concat(parts, "-") .. ">") or ""
    return canonical_mods == mods and encoded_key == key
  end

  return normalized == key and mods == ""
end

---@param opts HollowUiSelectOptions
---@param key string
---@param mods string
---@return integer|nil
local function match_action_for_key(opts, key, mods)
  for index, action in ipairs(opts.actions or {}) do
    local hint = action.key
    if type(hint) == "string" and hint ~= "" and action_matches_hint(hint, key, mods) then
      return index
    end
  end

  return nil
end

---@param opts HollowUiSelectOptions
---@param item any
---@return HollowUiRenderableNode[], string, HollowUiRenderableNode[]|nil, string|nil
local function build_entry_text(opts, item)
  local label_value = (opts.label or tostring)(item)
  local label_nodes = shared.normalize_inline_nodes(label_value)
  local label_text = shared.nodes_plain_text(label_nodes)

  local detail_nodes = nil
  local detail_text = nil
  if type(opts.detail) == "function" then
    detail_nodes = shared.normalize_inline_nodes(opts.detail(item))
    detail_text = shared.nodes_plain_text(detail_nodes)
    if detail_text == "" then
      detail_nodes = nil
      detail_text = nil
    end
  end

  return label_nodes, label_text, detail_nodes, detail_text
end

---@param opts HollowUiSelectOptions
---@param local_state HollowUiSelectState
---@return HollowUiSelectEntry[]
local function filtered_entries(opts, local_state)
  local entries = {}
  local fuzzy = opts.fuzzy ~= false

  for source_index, item in ipairs(opts.items or {}) do
    local label_nodes, label_text, detail_nodes, detail_text = build_entry_text(opts, item)
    local searchable = label_text
    if detail_text then
      searchable = searchable .. "\n" .. detail_text
    end

    local matches, score = shared.select_item_matches(local_state.query, searchable, fuzzy)
    if matches then
      entries[#entries + 1] = {
        item = item,
        label_nodes = label_nodes,
        label_text = label_text,
        detail_nodes = detail_nodes,
        detail_text = detail_text,
        source_index = source_index,
        score = score or 0,
      }
    end
  end

  if fuzzy and local_state.query ~= "" then
    table.sort(entries, function(a, b)
      if a.score ~= b.score then
        return a.score > b.score
      end
      if a.label_text ~= b.label_text then
        return a.label_text < b.label_text
      end
      return a.source_index < b.source_index
    end)
  end

  return entries
end

---@param local_state HollowUiSelectState
---@param entries HollowUiSelectEntry[]
local function clamp_index(local_state, entries)
  if #entries == 0 then
    local_state.index = 0
  elseif local_state.index < 1 then
    local_state.index = 1
  elseif local_state.index > #entries then
    local_state.index = #entries
  end
end

---@param opts HollowUiSelectOptions
---@param local_state HollowUiSelectState
---@param entries HollowUiSelectEntry[]
---@return HollowUiSelectEntry[]
local function visible_entries(opts, local_state, entries)
  local budget = list_row_budget(opts)
  if #entries == 0 then
    local_state.scroll_top = 1
    return {}
  end

  clamp_index(local_state, entries)

  local scroll_top = math.max(1, math.min(local_state.scroll_top or 1, #entries))
  if local_state.index < scroll_top then
    scroll_top = local_state.index
  end
  while
    scroll_top < local_state.index
    and rows_between(entries, scroll_top, local_state.index) > budget
  do
    scroll_top = scroll_top + 1
  end

  local visible = {}
  local used = 0
  local index = scroll_top
  while index <= #entries do
    local entry = entries[index]
    local needed = entry_row_count(entry)
    if #visible > 0 and used + needed > budget then
      break
    end

    visible[#visible + 1] = entry
    used = used + needed
    if used >= budget then
      break
    end
    index = index + 1
  end

  local_state.scroll_top = scroll_top
  return visible
end

---@param local_state HollowUiSelectState
---@param entries HollowUiSelectEntry[]
---@return HollowUiSelectEntry|nil
local function selected_entry(local_state, entries)
  return entries[local_state.index] or nil
end

---@param rows HollowUiRows
---@param value any
local function append_rows(rows, value)
  if value == nil then
    return
  end

  for _, row in ipairs(ui.rows(value)) do
    rows[#rows + 1] = row
  end
end

---@param theme HollowUiTheme
---@return HollowUiOverlayRow
local function render_empty_row(theme)
  ---@type HollowUiTags
  local tags = ui.tags
  return tags.overlay_row(nil, tags.text({ fg = theme.empty }, " No matches"))
end

---@param entry HollowUiSelectEntry
---@param is_selected boolean
---@param theme HollowUiTheme
---@param show_scrollbar boolean
---@param visible_index integer
---@param thumb_index integer
---@return HollowUiRows
local function render_entry_rows(
  entry,
  is_selected,
  theme,
  show_scrollbar,
  visible_index,
  thumb_index
)
  ---@type HollowUiTags
  local tags = ui.tags
  local label_nodes = {
    ui.span(is_selected and "> " or "  ", {
      fg = is_selected and theme.selected_fg or theme.fg,
      bold = is_selected,
    }),
  }

  for _, node in ipairs(entry.label_nodes or {}) do
    label_nodes[#label_nodes + 1] = node
  end

  local detail_row
  if entry.detail_text and entry.detail_text ~= "" then
    local detail_nodes = {
      ui.span("   ", { fg = is_selected and theme.selected_muted or theme.detail }),
    }
    for _, node in ipairs(entry.detail_nodes or {}) do
      detail_nodes[#detail_nodes + 1] = node
    end

    detail_row = tags.overlay_row(
      { fill_bg = is_selected and theme.selected_detail_bg or nil },
      ui.group(detail_nodes, { fg = is_selected and theme.selected_muted or theme.detail })
    )
  end

  return ui.rows(
    tags.overlay_row(
      {
        fill_bg = is_selected and theme.selected_bg or nil,
        scrollbar_track = show_scrollbar,
        scrollbar_thumb = show_scrollbar and visible_index == thumb_index,
        scrollbar_track_color = theme.scrollbar_track,
        scrollbar_thumb_color = theme.scrollbar_thumb,
      },
      ui.group(label_nodes, {
        fg = is_selected and theme.selected_fg or theme.fg,
        bold = is_selected,
      })
    ),
    detail_row
  )
end

---@param opts HollowUiSelectOptions
---@param theme HollowUiTheme
---@return HollowUiRows|nil
local function render_hint_rows(opts, theme)
  ---@type HollowUiTags
  local tags = ui.tags
  local hint_nodes = {}

  for index, action in ipairs(opts.actions or {}) do
    local key_hint = action.key
      or (action.name == (opts.actions[1] and opts.actions[1].name) and "<CR>" or nil)
    if key_hint then
      local chord = normalize_hint_chord(key_hint)
      local description = action.desc or action.name or "action"
      if #hint_nodes > 0 then
        hint_nodes[#hint_nodes + 1] = tags.text({ fg = theme.divider }, "  ")
      end
      hint_nodes[#hint_nodes + 1] = tags.text({ fg = theme.panel_border, bold = true }, chord)
      hint_nodes[#hint_nodes + 1] = tags.text({ fg = theme.muted }, " " .. description)
    end
  end

  if #hint_nodes == 0 then
    return nil
  end

  return ui.rows(
    tags.divider({ color = theme.divider }),
    tags.overlay_row(nil, table_unpack(hint_nodes))
  )
end

---@param opts HollowUiSelectOptions
---@param local_state HollowUiSelectState
---@return boolean
local function invoke_action(opts, local_state, action_index)
  local entries = filtered_entries(opts, local_state)
  clamp_index(local_state, entries)

  local action = opts.actions and opts.actions[action_index]
  if action == nil then
    return false
  end

  local entry = entries[local_state.index]
  if entry and type(action.fn) == "function" then
    action.fn(entry.item)
  end

  return true
end

---@param opts HollowUiSelectOptions|nil
function ui.select.open(opts)
  opts = opts or {}

  local theme = resolve_select_theme(shared.resolve_widget_theme("select"), opts)
  local backdrop = opts.backdrop ~= nil and opts.backdrop or theme.backdrop
  local local_state = {
    index = 1,
    query = opts.query or "",
    scroll_top = 1,
  }

  local widget
  widget = ui.overlay.new({
    render = function()
      ---@type HollowUiTags
      local tags = ui.tags
      local entries = filtered_entries(opts, local_state)
      clamp_index(local_state, entries)

      local visible = visible_entries(opts, local_state, entries)
      local selected = selected_entry(local_state, entries)
      local counter = (#entries > 0) and string.format(" %d/%d", local_state.index, #entries) or nil
      local show_scrollbar = #entries > #visible and #visible > 1
      local thumb_index = 1
      if show_scrollbar then
        thumb_index = 1
          + math.floor(((local_state.index - 1) * (#visible - 1)) / math.max(1, #entries - 1))
      end

      local rows = ui.rows(
        tags.overlay_row(
          nil,
          tags.text({ fg = theme.title, bold = true }, (opts.prompt or "Select") .. ":"),
          tags.text({ fg = theme.counter }, counter and ("  " .. counter) or "")
        ),
        tags.divider({ color = theme.divider }),
        tags.overlay_row(
          nil,
          tags.text({ fg = theme.title, bold = true }, "Filter: "),
          tags.text({ fg = theme.input_fg, bg = theme.input_bg }, local_state.query),
          tags.text({ fg = theme.cursor_fg, bg = theme.cursor_bg, bold = true }, " ")
        ),
        tags.divider({ color = theme.divider })
      )

      if #entries == 0 then
        rows[#rows + 1] = render_empty_row(theme)
      end

      for visible_index, entry in ipairs(visible) do
        local is_selected = selected ~= nil and entry.source_index == selected.source_index
        append_rows(
          rows,
          render_entry_rows(entry, is_selected, theme, show_scrollbar, visible_index, thumb_index)
        )
      end

      append_rows(rows, render_hint_rows(opts, theme))
      return rows
    end,
    on_key = function(key, mods)
      local entries = filtered_entries(opts, local_state)
      clamp_index(local_state, entries)

      if key == "escape" then
        ui.close_overlay_widget(widget)
        if type(opts.on_cancel) == "function" then
          opts.on_cancel()
        end
        return true
      end

      if key == "arrow_down" then
        if #entries > 0 then
          local_state.index = (local_state.index >= #entries) and 1
            or math.max(1, local_state.index) + 1
          if local_state.index == 1 then
            local_state.scroll_top = 1
          end
        end
        return true
      end

      if key == "arrow_up" then
        if #entries > 0 then
          local_state.index = (local_state.index <= 1) and #entries
            or math.max(1, local_state.index - 1)
        end
        return true
      end

      if key == "backspace" and mods == "" then
        local_state.query = local_state.query:sub(1, math.max(0, #local_state.query - 1))
        local_state.index = 1
        return true
      end

      local printable = shared.printable_char_for_key(key, mods)
      if printable ~= nil then
        local_state.query = local_state.query .. printable
        local_state.index = 1
        return true
      end

      local action_index = match_action_for_key(opts, key, mods or "")
      if action_index ~= nil then
        return invoke_action(opts, local_state, action_index)
      end

      if key == "enter" then
        return invoke_action(opts, local_state, 1)
      end

      return false
    end,
    width = opts.width,
    height = opts.height,
    max_height = opts.max_height,
    chrome = opts.chrome or { bg = theme.panel_bg, border = theme.panel_border },
    backdrop = backdrop,
  })

  ui.overlay.push(widget)
end

function ui.select.close()
  ui.overlay.pop()
end
