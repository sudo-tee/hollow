local box = require("hollow.ui.style.box")
local c = require("hollow.ui.components")
local categories = require("hollow.ui.behaviors.categories")
local category_row = require("hollow.ui.components.category")
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
local MAX_LIST_ROWS = 20

-- `prepare_entries` drops empty details, so `detail_text` is nil or non-empty.
---@param entry HollowUiSelectEntry
---@return integer
local function entry_row_count(entry)
  if entry.is_group then
    return entry.row_units or 1
  end
  return entry.detail_text and 2 or 1
end

---@param ctx HollowUiLayoutContext
---@return { width: number, height: number }|nil
local function viewport_metrics(ctx)
  return ctx.metrics and ctx.metrics["select:viewport"]
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
        group = type(opts.group_by) == "function" and tostring(opts.group_by(item) or "") or nil,
      }
    end)
    :get()
end

---@param raw string
---@return string
local function normalize_hint_chord(raw)
  local ok, key, mods = pcall(hollow.keymap.parse_chord, raw)
  return ok and hollow.keymap.format_chord(key, mods) or raw
end

---@param opts HollowUiSelectOptions
---@param query string
---@param prepared HollowUiSelectEntry[]
---@param sections table
---@return HollowUiSelectEntry[]
local function filtered_entries(opts, query, prepared, sections)
  local fuzzy = opts.fuzzy ~= false
  local grouped_view = type(opts.group_by) == "function"
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

  if query ~= "" or grouped_view then
    hollow.tbl(entries):sort(function(a, b)
      if a.group ~= b.group then
        return a.group < b.group
      elseif query == "" then
        return a.source_index < b.source_index
      elseif a.score ~= b.score then
        return a.score > b.score
      elseif a.label_text ~= b.label_text then
        return a.label_text < b.label_text
      end
      return a.source_index < b.source_index
    end)
  end

  -- A filtered view that lands in a single group needs no header.
  if
    not grouped_view or (query ~= "" and entries[1] and entries[1].group == entries[#entries].group)
  then
    return entries
  end

  local grouped, previous, collapsed = {}, nil, false
  for _, entry in ipairs(entries) do
    if entry.group ~= previous then
      previous = entry.group
      collapsed = sections.is_collapsed(entry.group, query)
      grouped[#grouped + 1] = {
        item = type(opts.group_item) == "function" and opts.group_item(entry.group) or nil,
        is_group = true,
        group = entry.group,
        collapsed = collapsed,
        label_text = type(opts.group_label) == "function" and opts.group_label(entry.group)
          or entry.group,
        source_index = "group:" .. entry.group,
      }
    end
    if not collapsed then
      grouped[#grouped + 1] = entry
    end
  end
  return grouped
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

---@param entry HollowUiSelectEntry
---@param row { id: string, selected: boolean, hovered: boolean, line_h: integer }
---@param view table
---@param plain boolean
---@return HollowUiLayoutNode
local function render_group_entry(entry, row, view, plain)
  local theme, ctx, id = view.theme, view.ctx, row.id
  local cell_w = props.cell_w(ctx)
  local measured = viewport_metrics(ctx)
  local pixels = measured and measured.width
    or math.min(ctx.width or math.huge, (view.width or 60) * cell_w)
  local meta = view.group_meta and view.group_meta(entry.group) or ""
  return c.category({
    id = id,
    theme = theme,
    selected = row.selected,
    hovered = row.hovered,
    flat = true,
    label = entry.label_text,
    text = util.truncate_end(
      entry.label_text,
      math.max(0, math.floor(pixels / cell_w) - 9 - util.display_width(meta))
    ),
    collapsed = entry.collapsed,
    plain = plain,
    colors = view.group_colors and view.group_colors(entry.group),
    on_activate = function()
      view.on_activate(entry.source_index)
    end,
    c.when(meta ~= "", function()
      return c.text(meta, styles(theme).muted, { wrap = "none" })
    end),
    c.when(view.group_create and entry.item and entry.item.domain, function()
      return c.button({
        id = id .. ":create",
        text = " + ",
        label = "Create on " .. entry.item.domain,
        width = "3ch",
        height = row.line_h,
        appearance = "quiet",
        align_y = "center",
        theme = theme,
        on_click = function()
          view.group_create(entry.group)
        end,
      })
    end),
  })
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
  local row = {
    id = id,
    selected = index == view.selected,
    hovered = view.hovered_id == id,
    line_h = list_item.line_height(theme, ctx),
  }
  if entry.is_group then
    return render_group_entry(entry, row, view, plain)
  end

  local s = styles(theme, { selected = row.selected, hovered = row.hovered })
  local padding = box.normalize(list_row(theme).indicator.padding)
  local cell_w = props.cell_w(ctx)

  local function line(left)
    return {
      width = "grow",
      height = row.line_h,
      padding = { top = padding.top, bottom = padding.bottom, left = left },
    }
  end

  local function text_line(suffix, style, text, nodes, left)
    local content = plain and { ui.text(text) }
      or shared.highlight_inline_nodes(nodes, view.query, s.match)
    return c.rich(util.merge_tables({ prefix = id .. suffix, style = style, content }, line(left)))
  end

  local custom = not plain
    and view.render_label
    and view.render_label(entry.item, ctx, {
      query = view.query,
      selected = row.selected,
      hovered = row.hovered,
      theme = theme,
      id = id,
    })
  local has_detail = entry.detail_text ~= nil

  return c.list_item({
    id = id,
    theme = theme,
    selected = row.selected,
    hovered = row.hovered,
    label = has_detail and (entry.label_text .. "\n" .. entry.detail_text) or entry.label_text,
    height = row.line_h * (has_detail and 2 or 1),
    on_activate = function()
      view.on_activate(entry.source_index)
    end,
    c.column({
      custom and c.column({ custom }, line())
        or text_line(":label", s.label, entry.label_text, entry.label_nodes),
      c.when(has_detail, function()
        return text_line(":detail", s.detail, entry.detail_text, entry.detail_nodes, cell_w)
      end),
    }, {
      width = "grow",
      padding = { left = cell_w * (view.item_indent or 2) + padding.left - 2 },
    }),
  })
end

---@generic T
---@param list T[]
---@param pred fun(value: T): boolean
---@return integer|nil
local function index_where(list, pred)
  for index, value in ipairs(list) do
    if pred(value) then
      return index
    end
  end
end

-- Rows the list occupies, capped by the budget; an empty list keeps one row
-- for the "No matches" placeholder.
---@param entries HollowUiSelectEntry[]
---@param max_rows integer
---@return integer
local function visible_rows(entries, max_rows)
  local units = 0
  for _, entry in ipairs(entries) do
    units = units + entry_row_count(entry)
    if units >= max_rows then
      return max_rows
    end
  end
  return units
end

---@param opts HollowUiSelectOptions|nil
function ui.select.open(opts)
  opts = opts or {} --[[@as HollowUiSelectOptions]]

  local theme = shared.widget_theme("select", opts.theme)
  local backdrop = opts.backdrop
  if backdrop == nil then
    backdrop = theme.backdrop
  end
  local title = opts.prompt or "Select"
  local live_items = type(opts.items) == "function"
  local prepared = prepare_entries(opts)
  local actions = opts.actions or {}
  local max_rows = list_row_budget(opts)
  local clay_row_budget = math.min(MAX_LIST_ROWS, max_rows)
  local reveal_start = false
  local sections = categories.new()
  local category_units = 1

  local selectable, current_entries
  local filter = ui.text_input({
    initial = opts.query or "",
    on_change = function()
      local entries = current_entries()
      local first = 1
      while entries[first] and entries[first].is_group do
        first = first + 1
      end
      selectable.nav.index = entries[first] and first or 1
    end,
  })

  function current_entries()
    local entries = filtered_entries(opts, filter.value, prepared, sections)
    for _, entry in ipairs(entries) do
      if entry.is_group then
        entry.row_units = category_units
      end
    end
    return entries
  end

  local function activate(action_index, selected_index)
    local entries = current_entries()
    local entry = entries[clamp_index(selected_index, entries)]
    if action_index == 1 and entry and entry.is_group then
      sections.toggle(entry.group, filter.value)
      return
    end
    local action = actions[action_index]
    if action and type(action.fn) == "function" then
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
  if opts.group_by then
    nav.index = 2
  end

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

  -- Live sources rebuild every render; grouped views keep the selection on
  -- the same item id so headers appearing or collapsing do not shift it.
  local function refresh_entries()
    if not live_items then
      return current_entries()
    end
    local old = current_entries()[nav.index]
    local old_id = opts.group_by and old and type(old.item) == "table" and old.item.id
    prepared = prepare_entries(opts)
    local entries = current_entries()
    if old_id then
      nav.index = index_where(entries, function(entry)
        return type(entry.item) == "table" and entry.item.id == old_id
      end) or nav.index
    end
    return entries
  end

  -- Ignore stale hits when a filter removed the previously painted row.
  local function activate_source(source_index)
    local index = index_where(current_entries(), function(entry)
      return entry.source_index == source_index
    end)
    if index then
      nav.index, reveal_start = index, false
      activate(1, index)
    end
  end

  local function render(render_theme, state, ctx)
    local line_h = list_item.line_height(render_theme, ctx)
    local cell_h = props.cell_h(ctx)
    category_units = category_row.height(render_theme, ctx) / line_h

    local entries = refresh_entries()
    nav.index = clamp_index(nav.index, entries)
    local measured = viewport_metrics(ctx)
    if measured then
      clay_row_budget = math.max(1, math.min(MAX_LIST_ROWS, math.floor(measured.height / line_h)))
    end

    local hints = hint_props(actions, render_theme, ctx)
    local list_height = #entries == 0 and cell_h or visible_rows(entries, max_rows) * line_h
    local content_height = (4 + (hints and 2 or 0)) * cell_h + list_height

    local view = {
      query = filter.value,
      selected = nav.index,
      hovered_id = state and state.hovered_id,
      render_label = opts.layout_label,
      group_create = opts.group_create,
      group_colors = opts.group_colors,
      group_meta = opts.group_meta,
      item_indent = opts.item_indent,
      width = opts.width,
      theme = render_theme,
      ctx = ctx,
      on_activate = activate_source,
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
        title = title,
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
    title = title,
    theme = theme,
    layout_live = opts.layout_live == true or (opts.layout_live == nil and live_items),
    layout_events = opts.layout_events,
    semantic_hover = opts.semantic_hover ~= false and type(opts.layout_label) == "function",
    on_mount = opts.on_mount,
    layout_refresh_after = opts.layout_refresh_after,
    on_unmount = opts.on_unmount,
    render = render,
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
      local scrolled = name == "overlay:scrollbar"
        or (name == "overlay:scroll" and (payload and payload.delta or 0) ~= 0)
      if consumed and scrolled then
        reveal_start = true
      end
      return consumed
    end,
  })
end

function ui.select.close()
  ui.overlay.pop()
end
