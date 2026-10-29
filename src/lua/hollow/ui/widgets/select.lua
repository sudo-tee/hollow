local list_style = require("hollow.ui.widgets.list_style")
local shared = require("hollow.ui.shared")
local util = require("hollow.util")

---@type Hollow
local hollow = _G.hollow
---@type HollowUi
local ui = hollow.ui

ui.select = ui.select or {}

local DEFAULT_TOTAL_ROWS = 14
local TITLE = ui.styles.title
local KEY_HINT = { fg = "panel_border", bold = true }
local MUTED = ui.styles.muted
local EMPTY = { fg = "empty" }
local DETAIL_INDENT = { padding = list_style.row_padding }
local COUNTER = { fg = "counter" }
local HINT_SEPARATOR = { fg = "divider" }

local function entry_styles(theme, selected, hovered)
  return {
    label = {
      fg = util.state_value(selected, hovered, theme.selection_fg, theme.hover_fg, theme.fg),
    },
    detail = {
      fg = util.state_value(
        selected,
        hovered,
        theme.selected_muted,
        theme.selected_muted,
        theme.detail
      ),
    },
  }
end

---@param opts HollowUiSelectOptions
---@return HollowUiTheme
local function resolve_select_theme(opts)
  return shared.widget_theme("select", opts.theme)
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
  local items = type(opts.items) == "function" and opts.items() or opts.items
  return hollow
    .tbl(items or {})
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

  if query ~= "" then
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
  return ui.row({ ui.text("No matches", ui.styled(theme, EMPTY)) })
end

---@param entry HollowUiSelectEntry
---@param is_selected boolean
---@param is_hovered boolean
---@param theme HollowUiTheme
---@param row_options table
---@param query string
---@return HollowUiRows
local function render_entry_rows(entry, is_selected, is_hovered, theme, row_options, query)
  local styles = entry_styles(theme, is_selected, is_hovered)
  local match_style = ui.styled(theme, KEY_HINT)
  local label_nodes = {
    list_style.indicator(ui, theme, is_selected, is_hovered),
    shared.highlight_inline_nodes(entry.label_nodes, query, match_style),
  }

  return ui.column({
    ui.row(
      { ui.group(label_nodes, styles.label) },
      list_style.row(row_options, theme, is_selected, is_hovered)
    ),
    ui.when(entry.detail_text and entry.detail_text ~= "", function()
      return ui.row({
        ui.group({
          ui.span("   ", ui.style(DETAIL_INDENT, styles.detail)),
          shared.highlight_inline_nodes(entry.detail_nodes, query, match_style),
        }, styles.detail),
      }, list_style.row(row_options, theme, is_selected, is_hovered))
    end),
  }).children
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
        ui.text(normalize_hint_chord(key_hint), ui.styled(theme, KEY_HINT)),
        ui.text(" " .. (action.desc or action.name or "action"), ui.styled(theme, MUTED)),
      }
    end)
    :get()

  if #hints == 0 then
    return nil
  end

  local hint_nodes = ui.join(hints, ui.text("  ", ui.styled(theme, HINT_SEPARATOR)))
  return { ui.divider(theme.divider), ui.row(hint_nodes) }
end

---@param opts HollowUiSelectOptions|nil
function ui.select.open(opts)
  opts = opts or {} --[[@as HollowUiSelectOptions]]

  local theme = resolve_select_theme(opts)
  local backdrop = opts.backdrop
  if backdrop == nil then
    backdrop = theme.backdrop
  end
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
      if type(opts.items) == "function" then
        prepared = prepare_entries(opts)
      end
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
            list_style.hovered(state, row_id),
            render_theme,
            row_options,
            filter.value
          )
        end)
        :get()

      local rows = {
        ui.row({
          ui.text((opts.prompt or "Select") .. ":", ui.styled(render_theme, TITLE)),
          ui.text(counter and ("  " .. counter) or "", ui.styled(render_theme, COUNTER)),
        }),
        ui.divider(render_theme.divider),
        ui.row({
          ui.text("Filter: ", ui.styled(render_theme, TITLE)),
          ui.group(filter.render(render_theme)),
        }),
        ui.divider(render_theme.divider),
        ui.when(#entries == 0, function()
          return render_empty_row(render_theme)
        end),
        entry_rows,
        render_hint_rows(actions, render_theme),
      }
      return ui.column(rows)
    end,
    width = opts.width,
    height = opts.height,
    max_height = opts.max_height,
    chrome = opts.chrome or shared.theme_overlay_chrome(theme),
    backdrop = backdrop,
    theme_backdrop = opts.backdrop == nil,
    keys = ui.keys(filter, nav, {
      ["escape|<C-[>"] = function()
        modal.close()
        ui.fire(opts.on_cancel)
      end,
      ["arrow_down|<C-j>"] = function()
        move_selection(1)
      end,
      ["arrow_up|<C-k>"] = function()
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
