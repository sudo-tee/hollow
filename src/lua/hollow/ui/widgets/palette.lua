local shared = require("hollow.ui.shared")
local theme_api = require("hollow.theme")
local util = require("src.lua.hollow.util")
local w = require("hollow.ui.builder")
local table_unpack = table.unpack or unpack
local hollow = _G.hollow
local ui = hollow.ui
local tags = ui.tags
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

local DEFAULT_TOTAL_ROWS = 24
local DEFAULT_WIDTH = 100

local function list_row_budget(opts)
  local total = shared.normalize_overlay_size(opts.height)
    or shared.normalize_overlay_size(opts.max_height)
    or DEFAULT_TOTAL_ROWS
  return math.max(1, total - 5)
end

local function new_entry(fields)
  fields.display_name = fields.display_name or fields.name
  fields.mode_label = fields.mode_label or ""
  fields.desc = fields.desc or ""
  fields.chords = fields.chords or {}
  fields.workspace_targetable = fields.workspace_targetable or false
  fields.category = fields.category or "general"
  fields.category_label = fields.category_label or category_label(fields.category)
  fields.searchable = fields.searchable or fields.name
  fields.searchable_lower = fields.searchable:lower()
  return fields
end

local providers = {}

function providers.actions()
  local action_list = hollow.action.list()
  local entries = {}
  for _, a in ipairs(action_list) do
    local chords = util.safe_call(hollow.keymap.find_by_action, {}, a.name, "normal")
    local copy_chords = util.safe_call(hollow.keymap.find_by_action, {}, a.name, "copy_mode")
    for _, c in ipairs(copy_chords) do
      chords[#chords + 1] = c
    end
    local category = a.category or "general"
    local display_name = a.name:gsub("_", " ")
    local mode_label = ""
    if a.category == "copy_mode" then
      display_name = display_name:gsub("^copy mode ", "")
      mode_label = "[cm]"
    end
    entries[#entries + 1] = new_entry({
      name = a.name,
      display_name = display_name,
      mode_label = mode_label,
      desc = a.desc or "",
      category = category,
      chords = chords,
      run = a.run,
      workspace_targetable = a.workspace_targetable or false,
      searchable = a.name
        .. " "
        .. (a.desc or "")
        .. " "
        .. category_label(category)
        .. " "
        .. category,
    })
  end
  return entries
end

function providers.workspaces()
  local workspaces = hollow.term.workspaces()
  local entries = {}
  for _, ws in ipairs(workspaces) do
    local name = ws.name or ("Workspace " .. ws.index)
    entries[#entries + 1] = new_entry({
      name = name,
      mode_label = ws.is_active and "[current]" or "",
      category = "workspace",
      category_label = "Workspace",
      workspace_index = ws.index,
      workspace_id = ws.id,
      searchable = name .. " " .. ws.index .. " workspace",
    })
  end
  return entries
end

function providers.domains()
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
      searchable = name .. " " .. shell_str .. " domain",
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
  if #entries == 0 then
    return {}
  end
  collapsed = collapsed or {}
  local groups = {}
  local order = {}
  for _, entry in ipairs(entries) do
    local cat = entry.category
    if not groups[cat] then
      groups[cat] = { label = entry.category_label, items = {} }
      order[#order + 1] = cat
    end
    groups[cat].items[#groups[cat].items + 1] = entry
  end
  table.sort(order, function(a, b)
    return category_order(a) < category_order(b)
  end)
  local flat = {}
  for _, cat in ipairs(order) do
    flat[#flat + 1] = { _type = "header", label = groups[cat].label, category = cat }
    if not collapsed[cat] then
      for _, item in ipairs(groups[cat].items) do
        flat[#flat + 1] = { _type = "item", item = item }
      end
    end
  end
  return flat
end

---@param theme HollowUiTheme
---@param label string
---@param is_selected boolean
---@param is_hovered boolean
---@param is_collapsed boolean
---@param row_options table
---@return HollowUiOverlayRow
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
    fill_bg = is_selected and theme.selection_bg
      or (is_hovered and theme.hover_bg or (theme.selected_detail_bg or theme.panel_bg)),
    scrollbar_track_color = theme.scrollbar_track,
    scrollbar_thumb_color = theme.scrollbar_thumb,
  })
  return tags.overlay_row(
    final_opts,
    tags.text(
      { fg = theme.title, bold = true },
      (is_selected and "> " or (is_hovered and "\226\150\142 " or "  ")) .. arrow .. " " .. label
    )
  )
end

---@param entry table
---@param is_selected boolean
---@param is_hovered boolean
---@param theme HollowUiTheme
---@param row_options table
---@return HollowUiRows
local function render_entry_row(entry, is_selected, is_hovered, theme, row_options)
  local chord_text = #entry.chords > 0 and ("  " .. table.concat(entry.chords, " ")) or ""
  local label_text = (entry.mode_label ~= "" and (entry.mode_label .. " ") or "")
    .. (entry.desc ~= "" and entry.desc or entry.display_name)

  local emphasize = is_selected or is_hovered
  local label_nodes = {
    ui.span(is_selected and "  > " or (is_hovered and "  \226\150\142 " or "    "), {
      fg = emphasize and theme.selected_fg or theme.fg,
      bold = emphasize,
    }),
    ui.span(label_text, { fg = emphasize and theme.selected_fg or theme.fg }),
  }
  if chord_text ~= "" then
    label_nodes[#label_nodes + 1] = ui.spacer()
    label_nodes[#label_nodes + 1] = ui.span(chord_text, { fg = theme.panel_border or theme.muted })
  end

  local final_opts = util.merge_tables(util.clone_value(row_options), {
    fill_bg = is_selected and theme.selection_bg or (is_hovered and theme.hover_bg or nil),
    scrollbar_track_color = theme.scrollbar_track,
    scrollbar_thumb_color = theme.scrollbar_thumb,
  })
  return ui.rows(tags.overlay_row(final_opts, ui.group(label_nodes)))
end

---@param opts table|nil
function ui.command_palette.open(opts)
  opts = opts or {}
  local theme = theme_api.resolve_widget("select")
  if type(opts.theme) == "table" then
    local u = require("hollow.util")
    u.merge_tables(theme, u.clone_value(opts.theme))
  end
  local backdrop = opts.backdrop ~= nil and opts.backdrop or theme.backdrop
  local all_entries = opts.entries or providers.actions()
  local filter = w.text_input({ initial = opts.query or "" })
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

  local selectable = w.selectable_list({
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
    local item_idx, total_items = 0, 0
    for idx, entry in ipairs(flat) do
      if entry._type == "item" then
        total_items = total_items + 1
        if idx <= nav.index then
          item_idx = total_items
        end
      end
    end
    local counter = (total_items > 0) and string.format(" %d/%d", item_idx, total_items) or nil
    local viewport = selectable.visible_range()
    local rows = ui.rows(
      tags.overlay_row(
        { hoverable = false },
        tags.text({ fg = theme.title, bold = true }, (opts.prompt or "Command Palette") .. ":"),
        tags.text({ fg = theme.counter }, counter and ("  " .. counter) or "")
      ),
      tags.divider({ color = theme.divider }),
      tags.overlay_row(
        { hoverable = false },
        tags.text({ fg = theme.title, bold = true }, "Filter: "),
        table_unpack(filter.render(theme))
      ),
      tags.divider({ color = theme.divider })
    )
    if #flat == 0 then
      rows[#rows + 1] = tags.overlay_row(nil, tags.text({ fg = theme.empty }, " No matches"))
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
          hollow.tbl(rows):concat(
            ui.rows(render_entry_row(entry.item, is_selected, is_hovered, theme, row_options))
          )
        end
      end
    end
    hollow.tbl(rows):concat(ui.rows(tags.divider({ color = theme.divider }))):concat(
      ui.rows(
        tags.overlay_row(
          nil,
          tags.text({ fg = theme.panel_border, bold = true }, "<CR>"),
          tags.text({ fg = theme.muted }, " execute  "),
          tags.text({ fg = theme.panel_border, bold = true }, "<Esc>"),
          tags.text({ fg = theme.muted }, " dismiss")
        )
      )
    )
    return rows
  end

  modal = w.modal({
    theme = theme,
    render = render_content,
    keys = w.keys(filter, nav, {
      escape = function()
        modal.close()
        util.safe_call(opts.on_cancel)
      end,
      arrow_down = function()
        local flat = current_flat()
        if #flat > 0 then
          nav.index = nav.index + 1
          if nav.index > #flat then
            nav.index = 1
          end
        end
      end,
      arrow_up = function()
        local flat = current_flat()
        if #flat > 0 then
          nav.index = nav.index - 1
          if nav.index < 1 then
            nav.index = #flat
          end
        end
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
