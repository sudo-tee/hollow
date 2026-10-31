local box = require("hollow.ui.style.box")
local c = require("hollow.ui.components")
local list_item = require("hollow.ui.components.list_item")
local list_row = require("hollow.ui.recipes.list_row")
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")
local styles = require("hollow.ui.recipes.select")
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

---@param actions HollowUiSelectAction[]
---@param theme HollowUiTheme
---@param ctx HollowUiLayoutContext
---@return HollowUiHintsProps|nil
local function hint_props(actions, theme, ctx)
  local s = styles(theme)
  local hints = hollow
    .tbl(actions)
    :filter_map(function(action, index)
      local key_hint = action.key or (index == 1 and "<CR>" or nil)
      if not key_hint then
        return
      end
      return { normalize_hint_chord(key_hint), action.desc or action.name or "action" }
    end)
    :get()

  if #hints == 0 then
    return nil
  end

  hints.id, hints.width, hints.height, hints.scroll_x =
    "select:hints", "grow", props.cell_h(ctx), true
  hints.key_style, hints.description_style, hints.separator_style =
    s.key_hint, s.muted, s.hint_separator
  -- Three nodes per hint; long action lists collapse into one text node.
  hints.plain = #hints * 3 - 1 > 32
  return hints
end

---@param entry HollowUiSelectEntry
---@return string
local function entry_id(entry)
  return "select:item:" .. entry.source_index
end

-- One list item of one or two lines (label, optional detail). Custom
-- `layout_label` content replaces the label line when rendered rich.
---@param entry HollowUiSelectEntry
---@param index integer
---@param view table
---@param plain boolean
---@return HollowUiLayoutNode
local function render_entry(entry, index, view, plain)
  local theme, ctx = view.theme, view.ctx
  local id = entry_id(entry)
  local selected, hovered = index == view.selected, view.hovered_id == id
  local s = styles(theme, { selected = selected, hovered = hovered })
  local padding = box.normalize(list_row(theme).indicator.padding)
  local line_h = list_item.line_height(theme, ctx)
  local line =
    { width = "grow", height = line_h, padding = { top = padding.top, bottom = padding.bottom } }
  local label = plain and { ui.text(entry.label_text) }
    or shared.highlight_inline_nodes(entry.label_nodes, view.query, s.match)
  local lines =
    { c.rich(util.merge_tables({ prefix = id .. ":label", style = s.label, label }, line)) }
  local custom = not plain
    and view.render_label
    and view.render_label(entry.item, ctx, {
      query = view.query,
      selected = selected,
      hovered = hovered,
      theme = theme,
      id = id,
    })
  if custom then
    lines[1] = c.column({ custom }, line)
  end
  if entry.detail_text and entry.detail_text ~= "" then
    local detail = plain and { ui.text(entry.detail_text) }
      or shared.highlight_inline_nodes(entry.detail_nodes, view.query, s.match)
    local detail_line =
      util.merge_tables({ prefix = id .. ":detail", style = s.detail, detail }, line)
    detail_line.padding.left = props.cell_w(ctx)
    lines[2] = c.rich(detail_line)
  end
  return c.list_item({
    id = id,
    theme = theme,
    selected = selected,
    hovered = hovered,
    label = entry.detail_text
        and entry.detail_text ~= ""
        and (entry.label_text .. "\n" .. entry.detail_text)
      or entry.label_text,
    height = line_h * #lines,
    on_activate = function()
      view.on_activate(entry.source_index)
    end,
    c.column(
      lines,
      { width = "grow", padding = { left = props.cell_w(ctx) * 2 + padding.left - 2 } }
    ),
  })
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
      return clay_row_budget
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
    layout_live = opts.layout_live == true
      or (opts.layout_live == nil and type(opts.items) == "function"),
    layout_events = opts.layout_events,
    semantic_hover = opts.semantic_hover ~= false and type(opts.layout_label) == "function",
    on_mount = opts.on_mount,
    layout_refresh_after = opts.layout_refresh_after,
    on_unmount = opts.on_unmount,
    render = function(render_theme, state, ctx)
      if type(opts.items) == "function" then
        prepared = prepare_entries(opts)
      end
      local entries = current_entries()
      nav.index = clamp_index(nav.index, entries)
      local line_h = list_item.line_height(render_theme, ctx)
      local measured = ctx.metrics and ctx.metrics["select:viewport"]
      if measured then
        clay_row_budget = math.max(1, math.min(20, math.floor(measured.height / line_h)))
      end
      local hints = hint_props(actions, render_theme, ctx)
      local units = 0
      for _, entry in ipairs(entries) do
        units = math.min(list_row_budget(opts), units + entry_row_count(entry))
        if units >= list_row_budget(opts) then
          break
        end
      end
      local cell_h = props.cell_h(ctx)
      local list_height = #entries == 0 and cell_h or units * line_h
      local content_height = (4 + (hints and 2 or 0)) * cell_h + list_height
      local view = {
        query = filter.value,
        selected = nav.index,
        hovered_id = state and state.hovered_id,
        render_label = opts.layout_label,
        theme = render_theme,
        ctx = ctx,
        on_activate = function(source_index)
          -- Ignore stale hits when a filter removed the previously painted row.
          for index, entry in ipairs(current_entries()) do
            if entry.source_index == source_index then
              nav.index, reveal_start = index, false
              activate(1, index)
              return
            end
          end
        end,
      }
      local viewport = selectable.visible_range()
      local target = entries[reveal_start and viewport.start_idx or nav.index]
      local s = styles(render_theme)
      return c.picker({
        id = "select:picker",
        theme = render_theme,
        header = c.header({
          id = "select:header",
          width = "grow",
          height = cell_h,
          scroll_x = true,
          title = opts.prompt or "Select",
          prompt = true,
          meta = #entries > 0 and string.format("   %d/%d", nav.index, #entries) or "",
          meta_align = "inline",
          theme = render_theme,
          title_style = s.title,
          meta_style = s.counter,
        }),
        filter = filter,
        hints = hints,
        list = {
          id = "select:viewport",
          axis = "both",
          measure = true,
          reveal = target and entry_id(target),
          reveal_start = reveal_start,
          items = entries,
          selected = nav.index,
          viewport = viewport,
          -- Column-heavy windows stay conservative against Clay's fixed scroll pool.
          window = opts.layout_label and 23 or 24,
          render_item = function(entry, index, item_view)
            return render_entry(entry, index, view, item_view.plain)
          end,
          empty = c.empty({ text = "No matches", style = s.empty, wrap = "words" }),
        },
      }),
        content_height
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
        consumed
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
