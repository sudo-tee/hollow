local shared = require("hollow.ui.shared")
local theme_api = require("hollow.theme")
local util = require("hollow.util")
local w = require("hollow.ui.builder")

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

---@param opts HollowUiSelectOptions
---@param item any
---@return HollowUiRenderableNode[], string, HollowUiRenderableNode[]|nil, string|nil, string
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

  local searchable = nil
  if type(opts.search_text) == "function" then
    searchable = tostring(opts.search_text(item) or "")
  end
  if searchable == nil or searchable == "" then
    searchable = label_text
    if detail_text then
      searchable = searchable .. "\n" .. detail_text
    end
  end

  return label_nodes, label_text, detail_nodes, detail_text, searchable
end

---@param opts HollowUiSelectOptions
---@return HollowUiSelectEntry[]
local function prepared_entries(opts)
  local entries = {}

  for source_index, item in ipairs(opts.items or {}) do
    local label_nodes, label_text, detail_nodes, detail_text, searchable =
      build_entry_text(opts, item)

    entries[#entries + 1] = {
      item = item,
      label_nodes = label_nodes,
      label_text = label_text,
      detail_nodes = detail_nodes,
      detail_text = detail_text,
      searchable = searchable,
      searchable_lower = tostring(searchable):lower(),
      source_index = source_index,
    }
  end

  return entries
end

---@param opts HollowUiSelectOptions
---@param query string
---@param query_lower string
---@param prepared HollowUiSelectEntry[]
---@return HollowUiSelectEntry[]
local function filtered_entries(opts, query, query_lower, prepared)
  local entries = {}
  local fuzzy = opts.fuzzy ~= false

  for _, prepared_entry in ipairs(prepared) do
    local matches, score
    if fuzzy then
      matches, score = shared.select_item_matches(query, prepared_entry.searchable, true)
    else
      score = shared.plain_match_score_lower(prepared_entry.searchable_lower, query_lower)
      matches = score ~= nil
    end
    if matches then
      entries[#entries + 1] = {
        item = prepared_entry.item,
        label_nodes = prepared_entry.label_nodes,
        label_text = prepared_entry.label_text,
        detail_nodes = prepared_entry.detail_nodes,
        detail_text = prepared_entry.detail_text,
        source_index = prepared_entry.source_index,
        score = score or 0,
      }
    end
  end

  if fuzzy and query ~= "" then
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

---@param index integer
---@param entries HollowUiSelectEntry[]
---@return integer
local function clamp_index(index, entries)
  if #entries == 0 then
    return 0
  elseif index < 1 then
    return 1
  elseif index > #entries then
    return #entries
  end
  return index
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
---@param is_hovered boolean
---@param theme HollowUiTheme
---@param row_options table
---@return HollowUiRows
local function render_entry_rows(entry, is_selected, is_hovered, theme, row_options)
  ---@type HollowUiTags
  local tags = ui.tags

  local indicator
  if is_selected then
    indicator = "> "
  elseif is_hovered then
    indicator = "▎ "
  else
    indicator = "  "
  end
  local indicator_fg = is_selected and theme.selection_fg
    or (is_hovered and theme.selection_fg or theme.fg)

  local label_nodes = {
    ui.span(indicator, {
      fg = indicator_fg,
      bold = is_selected or is_hovered,
    }),
  }

  for _, node in ipairs(entry.label_nodes or {}) do
    label_nodes[#label_nodes + 1] = node
  end

  local row_fill_bg
  if is_selected then
    row_fill_bg = theme.selection_bg
  elseif is_hovered then
    row_fill_bg = theme.hover_bg
  end
  local row_fg = is_selected and theme.selection_fg or (is_hovered and theme.hover_fg or theme.fg)

  local detail_row
  if entry.detail_text and entry.detail_text ~= "" then
    local detail_fg = is_selected and theme.selected_muted
      or (is_hovered and theme.selected_muted or theme.detail)
    local detail_bg = is_selected and theme.selected_detail_bg
      or (is_hovered and theme.hover_bg or nil)
    local detail_nodes = {
      ui.span("   ", { fg = detail_fg }),
    }
    for _, node in ipairs(entry.detail_nodes or {}) do
      detail_nodes[#detail_nodes + 1] = node
    end

    detail_row = tags.overlay_row({
      id = row_options.id,
      fill_bg = detail_bg,
      scrollbar_track = row_options.scrollbar_track,
      scrollbar_thumb = row_options.scrollbar_thumb,
      scrollbar_id = row_options.scrollbar_id,
      scrollbar_thumb_ratio = row_options.scrollbar_thumb_ratio,
      scrollbar_thumb_size = row_options.scrollbar_thumb_size,
      scrollbar_track_color = theme.scrollbar_track,
      scrollbar_thumb_color = theme.scrollbar_thumb,
    }, ui.group(detail_nodes, { fg = detail_fg }))
  end

  return ui.rows(
    tags.overlay_row(
      {
        id = row_options.id,
        fill_bg = row_fill_bg,
        scrollbar_track = row_options.scrollbar_track,
        scrollbar_thumb = row_options.scrollbar_thumb,
        scrollbar_id = row_options.scrollbar_id,
        scrollbar_thumb_ratio = row_options.scrollbar_thumb_ratio,
        scrollbar_thumb_size = row_options.scrollbar_thumb_size,
        scrollbar_track_color = theme.scrollbar_track,
        scrollbar_thumb_color = theme.scrollbar_thumb,
      },
      ui.group(label_nodes, {
        fg = row_fg,
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

  for _, action in ipairs(opts.actions or {}) do
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
---@param query string
---@param query_lower string
---@param selected_index integer
---@param action_index integer
---@param prepared HollowUiSelectEntry[]
---@return boolean
local function invoke_action(opts, query, query_lower, selected_index, action_index, prepared)
  local entries = filtered_entries(opts, query, query_lower, prepared)
  local idx = clamp_index(selected_index, entries)

  local action = opts.actions and opts.actions[action_index]
  if action == nil then
    return false
  end

  local entry = entries[idx]
  if type(action.fn) == "function" then
    action.fn(entry and entry.item or nil)
  end

  return true
end

---@param opts HollowUiSelectOptions|nil
function ui.select.open(opts)
  opts = opts or {} --[[@as HollowUiSelectOptions]]

  local theme = resolve_select_theme(theme_api.resolve_widget("select"), opts)
  local backdrop = opts.backdrop ~= nil and opts.backdrop or theme.backdrop
  local prepared = prepared_entries(opts)

  local selectable
  local filter = w.text_input({
    initial = opts.query or "",
    on_change = function()
      selectable.nav.index = 1
    end,
  })

  local function current_entries()
    return filtered_entries(opts, filter.value, filter.value:lower(), prepared)
  end

  selectable = w.selectable_list({
    id_prefix = "select",
    items = current_entries,
    row_budget = function()
      return list_row_budget(opts)
    end,
    row_count_fn = entry_row_count,
    on_activate = function(index)
      invoke_action(opts, filter.value, filter.value:lower(), index, 1, prepared)
    end,
  })
  local nav = selectable.nav

  local action_keys = {}
  for i, action in ipairs(opts.actions or {}) do
    local hint = action.key
    if hint and hint ~= "" then
      local idx = i
      action_keys[hint] = function()
        invoke_action(opts, filter.value, filter.value:lower(), nav.index, idx, prepared)
      end
    end
  end

  ---@type HollowUiBuilderModal
  local m
  m = w.modal({
    theme = theme,
    render = function(render_theme, state)
      local tags = ui.tags
      local entries = current_entries()
      nav.index = clamp_index(nav.index, entries)

      local viewport = selectable.visible_range()

      local counter = (#entries > 0) and string.format(" %d/%d", nav.index, #entries) or nil

      local rows = {
        tags.overlay_row(
          { hoverable = false },
          tags.text({ fg = render_theme.title, bold = true }, (opts.prompt or "Select") .. ":"),
          tags.text({ fg = render_theme.counter }, counter and ("  " .. counter) or "")
        ),
        tags.divider({ color = render_theme.divider }),
        tags.overlay_row(
          { hoverable = false },
          tags.text({ fg = render_theme.title, bold = true }, "Filter: "),
          table_unpack(filter.render(render_theme))
        ),
        tags.divider({ color = render_theme.divider }),
      }

      if #entries == 0 then
        rows[#rows + 1] = render_empty_row(render_theme)
      end

      local visible_index = 0
      for i = viewport.start_idx, viewport.end_idx do
        local entry = entries[i] --[[@as HollowUiSelectEntry]]
        visible_index = visible_index + 1
        local is_selected = (i == nav.index)
        local row_id, row_options = selectable.row(i, entry.source_index, visible_index, viewport)
        local is_hovered = (state and state.hovered_id == row_id)
        append_rows(
          rows,
          render_entry_rows(entry, is_selected, is_hovered, render_theme, row_options)
        )
      end

      append_rows(rows, render_hint_rows(opts, render_theme))
      return rows
    end,
    width = opts.width,
    height = opts.height,
    max_height = opts.max_height,
    chrome = opts.chrome or shared.theme_overlay_chrome(theme),
    backdrop = backdrop,
    keys = w.keys(filter, nav, {
      escape = function()
        m.close()
        w.fire(opts.on_cancel)
      end,
      arrow_down = function()
        local entries = current_entries()
        if #entries > 0 then
          nav.index = (nav.index >= #entries) and 1 or math.max(1, nav.index) + 1
        end
      end,
      arrow_up = function()
        local entries = current_entries()
        if #entries > 0 then
          nav.index = (nav.index <= 1) and #entries or math.max(1, nav.index - 1)
        end
      end,
      enter = function()
        invoke_action(opts, filter.value, filter.value:lower(), nav.index, 1, prepared)
      end,
    }, action_keys),
    on_event = selectable.on_event,
  })
end

function ui.select.close()
  ui.overlay.pop()
end
