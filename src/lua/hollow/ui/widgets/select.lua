local list_row = require("hollow.ui.styles.list_row")
local shared = require("hollow.ui.shared")
local styles = require("hollow.ui.styles.select")
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
  return ui.row({ ui.text("No matches", styles(theme).empty) })
end

---@param entry HollowUiSelectEntry
---@param is_selected boolean
---@param is_hovered boolean
---@param theme HollowUiTheme
---@param row_options table
---@param query string
---@return HollowUiRows
local function render_entry_rows(entry, is_selected, is_hovered, theme, row_options, query)
  local s = styles(theme, { selected = is_selected, hovered = is_hovered })
  local row_s = list_row(theme, { selected = is_selected, hovered = is_hovered })
  local label_nodes = {
    ui.text("  ", row_s.indicator),
    shared.highlight_inline_nodes(entry.label_nodes, query, s.match),
  }

  return ui.column({
    ui.row({ ui.group(label_nodes, s.label) }, util.merge_tables(row_options, row_s.paint)),
    ui.when(entry.detail_text and entry.detail_text ~= "", function()
      return ui.row({
        ui.group({
          ui.span("   ", s.detail_indent),
          shared.highlight_inline_nodes(entry.detail_nodes, query, s.match),
        }, s.detail),
      }, util.merge_tables(row_options, row_s.paint))
    end),
  }).children
end

---@param actions HollowUiSelectAction[]
---@param theme HollowUiTheme
---@return HollowUiRows|nil
local function render_hint_rows(actions, theme)
  local s = styles(theme)
  local hints = hollow
    .tbl(actions)
    :filter_map(function(action, index)
      local key_hint = action.key or (index == 1 and "<CR>" or nil)
      if not key_hint then
        return
      end
      return {
        ui.text(normalize_hint_chord(key_hint), s.key_hint),
        ui.text(" " .. (action.desc or action.name or "action"), s.muted),
      }
    end)
    :get()

  if #hints == 0 then
    return nil
  end

  local hint_nodes = ui.join(hints, ui.text("  ", s.hint_separator))
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
  local clay = ui.layout.resolve_backend(opts.layout, "legacy") == "clay"
  local clay_row_budget = math.min(20, list_row_budget(opts))
  local reveal_start = false

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
      return clay and clay_row_budget or list_row_budget(opts)
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
  local keys = ui.keys(filter, nav, {
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
  }, action_keys)
  modal = ui.modal({
    title = opts.prompt or "Select",
    theme = theme,
    layout_live = clay and type(opts.items) == "function",
    layout_render = clay
        and function(render_theme, state, ctx)
          if type(opts.items) == "function" then
            prepared = prepare_entries(opts)
          end
          local entries = current_entries()
          nav.index = clamp_index(nav.index, entries)
          local component = require("hollow.ui.builder.components.layout_select")
          local measured = ctx.metrics and ctx.metrics["select:viewport"]
          if measured then
            clay_row_budget = math.max(
              1,
              math.min(20, math.floor(measured.height / component.line_height(render_theme, ctx)))
            )
          end
          local hints = render_hint_rows(actions, render_theme)
          local units = 0
          for _, entry in ipairs(entries) do
            units = math.min(list_row_budget(opts), units + entry_row_count(entry))
            if units >= list_row_budget(opts) then
              break
            end
          end
          local list_height = #entries == 0 and (ctx.cell_h or 19)
            or units * component.line_height(render_theme, ctx)
          local content_height = (4 + (hints and 2 or 0)) * (ctx.cell_h or 19) + list_height
          return component.render({
            prompt = opts.prompt,
            entries = entries,
            selected = nav.index,
            query = filter.value,
            filter = filter,
            viewport = selectable.visible_range(),
            hovered_id = state and state.hovered_id,
            hints = hints,
            reveal_start = reveal_start,
            render_label = opts.layout_label,
            on_activate = function(_, source_index)
              -- Ignore stale hits when a filter removed the previously painted row.
              for index, entry in ipairs(current_entries()) do
                if entry.source_index == source_index then
                  nav.index, reveal_start = index, false
                  activate(1, index)
                  return
                end
              end
            end,
          }, render_theme, ctx),
            content_height
        end
      or nil,
    render = function(render_theme, state)
      if type(opts.items) == "function" then
        prepared = prepare_entries(opts)
      end
      local entries = current_entries()
      nav.index = clamp_index(nav.index, entries)
      local viewport = selectable.visible_range()
      local s = styles(render_theme)
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
            shared.node_state(state, row_id).hovered,
            render_theme,
            row_options,
            filter.value
          )
        end)
        :get()

      local rows = {
        ui.row({
          ui.text((opts.prompt or "Select") .. ":", s.title),
          ui.text(counter and ("  " .. counter) or "", s.counter),
        }),
        ui.divider(render_theme.divider),
        ui.row({
          ui.text("Filter: ", s.title),
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
    keys = function(key, mods)
      local consumed = keys(key, mods)
      if consumed then
        reveal_start = false
      end
      return consumed
    end,
    on_event = function(name, payload)
      local consumed = selectable.on_event(name, payload)
      if
        clay
        and consumed
        and (
          name == "overlay:scrollbar"
          or (name == "overlay:scroll" and (payload and payload.delta or 0) ~= 0)
        )
      then
        reveal_start = true
      end
      return consumed
    end,
  })
end

function ui.select.close()
  ui.overlay.pop()
end
