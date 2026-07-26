local shared = require("hollow.ui.shared")
local theme_api = require("hollow.theme")
local util = require("hollow.util")

---@type Hollow
local hollow = _G.hollow
---@type HollowUi
local ui = hollow.ui

ui.select = ui.select or {}

local DEFAULT_TOTAL_ROWS = 14

---@param opts HollowUiSelectOptions
---@return HollowUiTheme
local function resolve_select_theme(opts)
  local theme = theme_api.resolve_widget("select")
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
  local footer_rows = #(opts.actions or {}) > 0 and 2 or 0
  return math.max(1, total - 4 - footer_rows)
end

---@param value any
---@return HollowUiRenderableNode[], string
local function inline_content(value)
  local nodes = shared.normalize_inline_nodes(value)
  return nodes, shared.nodes_plain_text(nodes)
end

---@param opts HollowUiSelectOptions
---@return HollowUiSelectEntry[]
local function prepare_entries(opts)
  return hollow
    .tbl(opts.items or {})
    :map(function(item, source_index)
      local label_nodes, label_text = inline_content((opts.label or tostring)(item))
      local detail_nodes, detail_text
      if type(opts.detail) == "function" then
        detail_nodes, detail_text = inline_content(opts.detail(item))
        if detail_text == "" then
          detail_nodes, detail_text = nil, nil
        end
      end

      local searchable = type(opts.search_text) == "function"
          and tostring(opts.search_text(item) or "")
        or ""
      if searchable == "" then
        searchable = detail_text and (label_text .. "\n" .. detail_text) or label_text
      end

      return {
        item = item,
        label_nodes = label_nodes,
        label_text = label_text,
        detail_nodes = detail_nodes,
        detail_text = detail_text,
        searchable = searchable,
        searchable_lower = searchable:lower(),
        source_index = source_index,
      }
    end)
    :get()
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
---@param query string
---@param prepared HollowUiSelectEntry[]
---@return HollowUiSelectEntry[]
local function filtered_entries(opts, query, prepared)
  local fuzzy = opts.fuzzy ~= false
  local query_lower = query:lower()
  local entries = hollow
    .tbl(prepared)
    :filter_map(function(entry)
      local matches, score
      if fuzzy then
        matches, score = shared.select_item_matches(query, entry.searchable, true)
      else
        score = shared.plain_match_score_lower(entry.searchable_lower, query_lower)
        matches = score ~= nil
      end
      if not matches then
        return
      end
      return util.merge_tables(hollow.tbl(entry):entries(), { score = score or 0 })
    end)
    :get()

  if fuzzy and query ~= "" then
    hollow.tbl(entries):sort(function(a, b)
      if a.score ~= b.score then
        return a.score > b.score
      elseif a.label_text ~= b.label_text then
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

---@param theme HollowUiTheme
---@return HollowUiRowNode
local function render_empty_row(theme)
  return ui.row({ ui.text("No matches", { fg = theme.empty }) })
end

local function styled_row_options(row_options, theme, fill_bg)
  return util.merge_tables(hollow.tbl(row_options):entries(), {
    fill_bg = fill_bg,
    scrollbar_track_color = theme.scrollbar_track,
    scrollbar_thumb_color = theme.scrollbar_thumb,
  })
end

---@param entry HollowUiSelectEntry
---@param is_selected boolean
---@param is_hovered boolean
---@param theme HollowUiTheme
---@param row_options table
---@return HollowUiRows
local function render_entry_rows(entry, is_selected, is_hovered, theme, row_options)
  local emphasized = is_selected or is_hovered
  local indicator = util.state_value(is_selected, is_hovered, "> ", "▎ ", "  ")
  local indicator_fg =
    util.state_value(is_selected, is_hovered, theme.selection_fg, theme.selection_fg, theme.fg)
  local row_fg =
    util.state_value(is_selected, is_hovered, theme.selection_fg, theme.hover_fg, theme.fg)
  local row_bg = util.state_value(is_selected, is_hovered, theme.selection_bg, theme.hover_bg)
  local label_nodes = hollow
    .tbl({ ui.span(indicator, { fg = indicator_fg, bold = emphasized }) })
    :concat(entry.label_nodes or {})
    :get()

  local rows = {
    ui.row(
      { ui.group(label_nodes, { fg = row_fg }) },
      styled_row_options(row_options, theme, row_bg)
    ),
  }

  if entry.detail_text and entry.detail_text ~= "" then
    local detail_fg = util.state_value(
      is_selected,
      is_hovered,
      theme.selected_muted,
      theme.selected_muted,
      theme.detail
    )
    local detail_bg =
      util.state_value(is_selected, is_hovered, theme.selected_detail_bg, theme.hover_bg)
    local detail_nodes =
      hollow.tbl({ ui.span("   ", { fg = detail_fg }) }):concat(entry.detail_nodes or {}):get()
    rows[#rows + 1] = ui.row(
      { ui.group(detail_nodes, { fg = detail_fg }) },
      styled_row_options(row_options, theme, detail_bg)
    )
  end

  return rows
end

---@param actions HollowUiSelectAction[]
---@param theme HollowUiTheme
---@return HollowUiRows|nil
local function render_hint_rows(actions, theme)
  local hints = hollow
    .tbl(actions)
    :filter_map(function(action, index)
      local key_hint = action.key or (index == 1 and "<CR>" or nil)
      if not key_hint then
        return
      end
      return {
        ui.text(normalize_hint_chord(key_hint), { fg = theme.panel_border, bold = true }),
        ui.text(" " .. (action.desc or action.name or "action"), { fg = theme.muted }),
      }
    end)
    :get()

  if #hints == 0 then
    return nil
  end

  local hint_nodes = hollow
    .tbl(hints)
    :flat_map(function(nodes, index)
      if index == 1 then
        return nodes
      end
      return hollow.tbl({ ui.text("  ", { fg = theme.divider }) }):concat(nodes):get()
    end)
    :get()
  return { ui.divider(theme.divider), ui.row(hint_nodes) }
end

---@param opts HollowUiSelectOptions|nil
function ui.select.open(opts)
  opts = opts or {} --[[@as HollowUiSelectOptions]]

  local theme = resolve_select_theme(opts)
  local backdrop = opts.backdrop ~= nil and opts.backdrop or theme.backdrop
  local prepared = prepare_entries(opts)
  local actions = opts.actions or {}

  local selectable
  local filter = ui.text_input({
    initial = opts.query or "",
    on_change = function()
      selectable.nav.index = 1
    end,
  })

  local function current_entries()
    return filtered_entries(opts, filter.value, prepared)
  end

  local function activate(action_index, selected_index)
    local action = actions[action_index]
    if not action then
      return
    end
    local entries = current_entries()
    local entry = entries[clamp_index(selected_index, entries)]
    if type(action.fn) == "function" then
      action.fn(entry and entry.item or nil)
    end
  end

  selectable = ui.selectable_list({
    id_prefix = "select",
    items = current_entries,
    row_budget = function()
      return list_row_budget(opts)
    end,
    row_count_fn = entry_row_count,
    on_activate = function(index)
      activate(1, index)
    end,
  })
  local nav = selectable.nav

  local action_keys = hollow.tbl(actions):reduce(function(keys, action, action_index)
    if action.key and action.key ~= "" then
      keys[action.key] = function()
        activate(action_index, nav.index)
      end
    end
    return keys
  end, {})

  local function move_selection(delta)
    local count = #current_entries()
    if count > 0 then
      nav.index = (nav.index + delta - 1) % count + 1
    end
  end

  ---@type HollowUiModalHandle
  local modal
  modal = ui.modal({
    theme = theme,
    render = function(render_theme, state)
      local entries = current_entries()
      nav.index = clamp_index(nav.index, entries)
      local viewport = selectable.visible_range()
      local counter = (#entries > 0) and string.format(" %d/%d", nav.index, #entries) or nil
      local entry_rows = hollow.tbl
        .range(viewport.start_idx, viewport.end_idx)
        :flat_map(function(index, visible_index)
          local entry = entries[index] --[[@as HollowUiSelectEntry]]
          local row_id, row_options =
            selectable.row(index, entry.source_index, visible_index, viewport)
          return render_entry_rows(
            entry,
            index == nav.index,
            state and state.hovered_id == row_id,
            render_theme,
            row_options
          )
        end)
        :get()

      local rows = hollow
        .tbl({
          ui.row({
            ui.text((opts.prompt or "Select") .. ":", {
              fg = render_theme.title,
              bold = true,
            }),
            ui.text(counter and ("  " .. counter) or "", { fg = render_theme.counter }),
          }),
          ui.divider(render_theme.divider),
          ui.row({
            ui.text("Filter: ", { fg = render_theme.title, bold = true }),
            ui.group(filter.render(render_theme)),
          }),
          ui.divider(render_theme.divider),
        })
        :concat(
          #entries == 0 and { render_empty_row(render_theme) } or {},
          entry_rows,
          render_hint_rows(actions, render_theme) or {}
        )
        :get()
      return ui.column(rows)
    end,
    width = opts.width,
    height = opts.height,
    max_height = opts.max_height,
    chrome = opts.chrome or shared.theme_overlay_chrome(theme),
    backdrop = backdrop,
    keys = ui.keys(filter, nav, {
      escape = function()
        modal.close()
        ui.fire(opts.on_cancel)
      end,
      arrow_down = function()
        move_selection(1)
      end,
      arrow_up = function()
        move_selection(-1)
      end,
      enter = function()
        activate(1, nav.index)
      end,
    }, action_keys),
    on_event = selectable.on_event,
  })
end

function ui.select.close()
  ui.overlay.pop()
end
