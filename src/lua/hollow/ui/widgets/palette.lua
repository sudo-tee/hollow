local shared = require("hollow.ui.shared")
local theme_api = require("hollow.theme")
local util = require("src.lua.hollow.util")
local hollow = _G.hollow
local ui = hollow.ui
ui.command_palette = ui.command_palette or {}

local CATEGORIES = {
  tab = { label = "Tab", order = 1 },
  pane = { label = "Pane", order = 2 },
  workspace = { label = "Workspace", order = 3 },
  window = { label = "Window", order = 4 },
  scroll = { label = "Scroll", order = 5 },
  copy_mode = { label = "Copy Mode", order = 6 },
  general = { label = "General", order = 7 },
  user = { label = "User", order = 8 },
}

local function category_label(cat)
  return CATEGORIES[cat] and CATEGORIES[cat].label or cat
end

local function category_order(cat)
  return CATEGORIES[cat] and CATEGORIES[cat].order or 99
end

--- Joins the truthy, non-empty arguments with spaces. Built for assembling
--- `searchable` strings without a chain of `(x or "") .. " " .. ...`.
local function words(...)
  local parts = {}
  for _, value in ipairs({ ... }) do
    if value ~= nil and value ~= "" then
      parts[#parts + 1] = tostring(value)
    end
  end
  return table.concat(parts, " ")
end

--- Advances `index` by `delta` positions, wrapping around a list of `count`
--- items. Returns `index` unchanged when there's nothing to cycle through.
local function cycle_index(index, delta, count)
  if count == 0 then
    return index
  end
  return (index + delta - 1) % count + 1
end

--- The fill color for a selectable row: selection beats hover beats fallback.
local function row_bg(theme, is_selected, is_hovered, fallback)
  if is_selected then
    return theme.selection_bg
  elseif is_hovered then
    return theme.hover_bg
  end
  return fallback
end

local MARKER_SELECTED = "> "
local MARKER_HOVERED = "\226\150\142 " -- ▎
local MARKER_NONE = "  "

--- The leading cursor glyph for a row, optionally indented (entry rows sit
--- two columns deeper than section headers).
local function marker(is_selected, is_hovered, indent)
  indent = indent or ""
  if is_selected then
    return indent .. MARKER_SELECTED
  elseif is_hovered then
    return indent .. MARKER_HOVERED
  end
  return indent .. MARKER_NONE
end

local DEFAULT_TOTAL_ROWS = 24
local DEFAULT_WIDTH = 100

local function list_row_budget(opts)
  local total = shared.normalize_overlay_size(opts.height)
    or shared.normalize_overlay_size(opts.max_height)
    or DEFAULT_TOTAL_ROWS
  return math.max(1, total - 5)
end

local ENTRY_DEFAULTS = {
  mode_label = "",
  desc = "",
  chords = {},
  workspace_targetable = false,
  category = "general",
}

local function new_entry(fields)
  local entry = util.merge_tables(util.clone_value(ENTRY_DEFAULTS), fields)
  entry.display_name = entry.display_name or entry.name
  entry.category_label = entry.category_label or category_label(entry.category)
  entry.searchable = entry.searchable or entry.name
  entry.searchable_lower = entry.searchable:lower()
  return entry
end

local providers = {}

function providers.actions()
  return hollow
    .tbl(hollow.action.list())
    :map(function(a)
      local chords = hollow
        .tbl(hollow.keymap.find_by_action(a.name, "normal"))
        :concat(hollow.keymap.find_by_action(a.name, "copy_mode"))
        :get()

      local category = a.category or "general"
      local display_name = a.name:gsub("_", " ")
      local mode_label = ""
      if category == "copy_mode" then
        display_name = display_name:gsub("^copy mode ", "")
        mode_label = "[cm]"
      end

      return new_entry({
        name = a.name,
        display_name = display_name,
        mode_label = mode_label,
        desc = a.desc or "",
        category = category,
        chords = chords,
        run = a.run,
        workspace_targetable = a.workspace_targetable or false,
        searchable = words(a.name, a.desc, category_label(category), category),
      })
    end)
    :get()
end

function providers.workspaces()
  return hollow
    .tbl(hollow.term.workspaces())
    :map(function(ws)
      local name = ws.name or ("Workspace " .. ws.index)
      return new_entry({
        name = name,
        mode_label = ws.is_active and "[current]" or "",
        category = "workspace",
        category_label = "Workspace",
        workspace_index = ws.index,
        workspace_id = ws.id,
        searchable = words(name, ws.index, "workspace"),
      })
    end)
    :get()
end

function providers.domains()
  -- A dict of name -> config, not a list, so it doesn't fit `map` -- it still
  -- needs its own pass to become an array, then a sort.
  local domains = hollow.config.get("domains") or {}
  local current = util.safe_call(hollow.term.current_domain, nil)
  local current_domain = current and current.name or nil

  local entries = {}
  for name, config in pairs(domains) do
    local shell = type(config) == "table" and config.shell or config
    local shell_str = type(shell) == "string" and shell or ""
    entries[#entries + 1] = new_entry({
      name = name,
      mode_label = (name == current_domain) and "[current]" or "",
      desc = shell_str ~= "" and ("(" .. shell_str .. ")") or "",
      category = "general",
      category_label = "Domain",
      domain_name = name,
      searchable = words(name, shell_str, "domain"),
    })
  end
  table.sort(entries, function(a, b)
    return a.name < b.name
  end)
  return entries
end

local function filtered_entries(all_entries, query)
  local scored = hollow
    .tbl(all_entries)
    :filter_map(function(entry)
      if query == "" then
        return util.merge_tables(entry, { score = 0 })
      end
      local matches, score = shared.select_item_matches(query, entry.searchable, true)
      if not matches then
        return
      end
      return util.merge_tables(entry, { score = score or 0 })
    end)
    :get()

  if query == "" then
    return scored
  end

  table.sort(scored, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.category < b.category
  end)
  return scored
end

local function grouped_entries(entries, collapsed)
  collapsed = collapsed or {}
  local groups, order = util.group_by(entries, function(entry)
    return entry.category
  end)
  table.sort(order, function(a, b)
    return category_order(a) < category_order(b)
  end)

  local flat = {}
  for _, cat in ipairs(order) do
    local items = groups[cat]
    flat[#flat + 1] = { _type = "header", label = items[1].category_label, category = cat }
    if not collapsed[cat] then
      for _, item in ipairs(items) do
        flat[#flat + 1] = { _type = "item", item = item }
      end
    end
  end
  return flat
end

--- Where `index` sits among just the selectable items in `flat` (headers
--- don't count), plus how many selectable items there are in total.
local function item_position(flat, index)
  local position, total = 0, 0
  for idx, entry in ipairs(flat) do
    if entry._type == "item" then
      total = total + 1
      if idx <= index then
        position = total
      end
    end
  end
  return position, total
end

---@param theme HollowUiTheme
---@param label string
---@param is_selected boolean
---@param is_hovered boolean
---@param is_collapsed boolean
---@param row_options table
---@return HollowUiRowNode
local function render_section_header(
  theme,
  label,
  is_selected,
  is_hovered,
  is_collapsed,
  row_options
)
  local arrow = is_collapsed and "\226\150\182" or "\226\150\188"
  local final_opts = util.merge_tables(util.clone_value(row_options), {
    fill_bg = row_bg(theme, is_selected, is_hovered, theme.selected_detail_bg or theme.panel_bg),
    scrollbar_track_color = theme.scrollbar_track,
    scrollbar_thumb_color = theme.scrollbar_thumb,
  })
  return ui.row({
    ui.text(marker(is_selected, is_hovered) .. arrow .. " " .. label, {
      fg = theme.title,
      bold = true,
    }),
  }, final_opts)
end

---@param entry table
---@param is_selected boolean
---@param is_hovered boolean
---@param theme HollowUiTheme
---@param row_options table
---@return HollowUiRowNode
local function render_entry_row(entry, is_selected, is_hovered, theme, row_options)
  local chord_text = #entry.chords > 0 and ("  " .. table.concat(entry.chords, " ")) or ""
  local label_text = (entry.mode_label ~= "" and (entry.mode_label .. " ") or "")
    .. (entry.desc ~= "" and entry.desc or entry.display_name)
  local emphasize = is_selected or is_hovered
  local fg = emphasize and theme.selected_fg or theme.fg

  local label_nodes = {
    ui.span(marker(is_selected, is_hovered, "  "), { fg = fg, bold = emphasize }),
    ui.span(label_text, { fg = fg }),
  }
  if chord_text ~= "" then
    label_nodes[#label_nodes + 1] = ui.spacer()
    label_nodes[#label_nodes + 1] = ui.span(chord_text, { fg = theme.panel_border or theme.muted })
  end

  local final_opts = util.merge_tables(util.clone_value(row_options), {
    fill_bg = row_bg(theme, is_selected, is_hovered, nil),
    scrollbar_track_color = theme.scrollbar_track,
    scrollbar_thumb_color = theme.scrollbar_thumb,
  })
  return ui.row({ ui.group(label_nodes) }, final_opts)
end

---@param opts table|nil
function ui.command_palette.open(opts)
  opts = opts or {}
  local theme = theme_api.resolve_widget("select")
  if type(opts.theme) == "table" then
    util.merge_tables(theme, util.clone_value(opts.theme))
  end
  local backdrop = opts.backdrop ~= nil and opts.backdrop or theme.backdrop
  local all_entries = opts.entries or providers.actions()
  local filter = ui.text_input({ initial = opts.query or "" })
  local collapsed = {}
  local nav
  local modal

  local function current_flat()
    return grouped_entries(filtered_entries(all_entries, filter.value), collapsed)
  end

  local function activate(index)
    local flat = current_flat()
    index = math.max(1, math.min(#flat, index or nav.index))
    local entry = flat[index]
    if entry and entry._type == "header" then
      collapsed[entry.category] = not collapsed[entry.category]
      return
    end
    if entry and entry._type == "item" then
      modal.close()
      util.safe_call(entry.item.run)
      util.safe_call(opts.on_confirm, nil, entry.item)
    end
  end

  local selectable = ui.selectable_list({
    id_prefix = "palette",
    items = current_flat,
    row_budget = function()
      return list_row_budget(opts)
    end,
    on_activate = activate,
  })
  nav = selectable.nav

  local function render_content(_, state)
    local flat = current_flat()
    nav.index = math.max(1, math.min(#flat, nav.index or 1))
    local item_idx, total_items = item_position(flat, nav.index)
    local counter = (total_items > 0) and string.format(" %d/%d", item_idx, total_items) or nil
    local viewport = selectable.visible_range()

    local rows = {
      ui.row({
        ui.text((opts.prompt or "Command Palette") .. ":", { fg = theme.title, bold = true }),
        ui.text(counter and ("  " .. counter) or "", { fg = theme.counter }),
      }),
      ui.divider(theme.divider),
      ui.row({
        ui.text("Filter: ", { fg = theme.title, bold = true }),
        ui.group(filter.render(theme)),
      }),
      ui.divider(theme.divider),
    }

    if #flat == 0 then
      rows[#rows + 1] = ui.row({ ui.text("No matches", { fg = theme.empty }) })
    else
      local visible_index = 0
      for idx = viewport.start_idx, viewport.end_idx do
        local entry = flat[idx]
        visible_index = visible_index + 1
        local row_id, row_options = selectable.row(idx, idx, visible_index, viewport)
        local is_selected = (idx == nav.index)
        local is_hovered = state and state.hovered_id == row_id
        if entry._type == "header" then
          rows[#rows + 1] = render_section_header(
            theme,
            entry.label,
            is_selected,
            is_hovered,
            collapsed[entry.category],
            row_options
          )
        elseif entry._type == "item" then
          rows[#rows + 1] =
            render_entry_row(entry.item, is_selected, is_hovered, theme, row_options)
        end
      end
    end

    rows[#rows + 1] = ui.divider(theme.divider)
    rows[#rows + 1] = ui.row({
      ui.text("<CR>", { fg = theme.panel_border, bold = true }),
      ui.text(" execute  ", { fg = theme.muted }),
      ui.text("<Esc>", { fg = theme.panel_border, bold = true }),
      ui.text(" dismiss", { fg = theme.muted }),
    })
    return ui.column(rows)
  end

  modal = ui.modal({
    theme = theme,
    render = render_content,
    keys = ui.keys(filter, nav, {
      escape = function()
        modal.close()
        util.safe_call(opts.on_cancel)
      end,
      arrow_down = function()
        nav.index = cycle_index(nav.index, 1, #current_flat())
      end,
      arrow_up = function()
        nav.index = cycle_index(nav.index, -1, #current_flat())
      end,
      enter = function()
        activate(nav.index)
      end,
    }),
    on_event = selectable.on_event,
    width = opts.width or DEFAULT_WIDTH,
    height = opts.height,
    max_height = opts.max_height,
    chrome = opts.chrome or shared.theme_overlay_chrome(theme),
    backdrop = backdrop,
  })
end

function ui.command_palette.close()
  ui.overlay.pop()
end

ui.command_palette.build_workspace_entries = providers.workspaces
ui.command_palette.build_domain_entries = providers.domains
return {}
