local shared = require("hollow.ui.shared")
local theme_api = require("hollow.theme")
local util = require("hollow.util")

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

local function words(...)
  local values = { ... }
  return hollow.tbl
    .range(1, select("#", ...))
    :filter_map(function(index)
      local value = values[index]
      return value ~= nil and value ~= "" and tostring(value) or nil
    end)
    :join(" ")
end

local function cycle_index(index, delta, count)
  if count == 0 then
    return index
  end
  return (index + delta - 1) % count + 1
end

local MARKER_SELECTED = "> "
local MARKER_HOVERED = "\226\150\142 " -- ▎
local MARKER_NONE = "  "

local function marker(is_selected, is_hovered, indent)
  return (indent or "")
    .. util.state_value(is_selected, is_hovered, MARKER_SELECTED, MARKER_HOVERED, MARKER_NONE)
end

local DEFAULT_TOTAL_ROWS = 24
local DEFAULT_WIDTH = 100

local function list_row_budget(opts)
  local total = shared.normalize_overlay_size(opts.height)
    or shared.normalize_overlay_size(opts.max_height)
    or DEFAULT_TOTAL_ROWS
  return math.max(1, total - 5)
end

local function resolve_theme(opts)
  local theme = theme_api.resolve_widget("select")
  if type(opts.theme) == "table" then
    util.merge_tables(theme, util.clone_value(opts.theme))
  end
  return theme
end

local function styled_row_options(row_options, theme, fill_bg)
  return util.merge_tables(hollow.tbl(row_options):entries(), {
    fill_bg = fill_bg,
    scrollbar_track_color = theme.scrollbar_track,
    scrollbar_thumb_color = theme.scrollbar_thumb,
  })
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
  return hollow
    .tbl(entries)
    :sort(function(a, b)
      return a.name < b.name
    end)
    :get()
end

local function filtered_entries(all_entries, query)
  local entries = hollow
    .tbl(all_entries)
    :filter_map(function(entry)
      if query == "" then
        return util.merge_tables(hollow.tbl(entry):entries(), { score = 0 })
      end
      local matches, score = shared.select_item_matches(query, entry.searchable, true)
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
      elseif a.name ~= b.name then
        return a.name < b.name
      end
      return a.category < b.category
    end)
  end

  return entries
end

local function grouped_entries(entries, collapsed)
  collapsed = collapsed or {}
  local groups, order = util.group_by(entries, function(entry)
    return entry.category
  end)
  return hollow
    .tbl(order)
    :sort(function(a, b)
      return category_order(a) < category_order(b)
    end)
    :flat_map(function(category)
      local items = groups[category]
      local children = collapsed[category] and {}
        or hollow
          .tbl(items)
          :map(function(item)
            return { _type = "item", item = item }
          end)
          :get()
      return hollow
        .tbl({
          { _type = "header", label = items[1].category_label, category = category },
        })
        :concat(children)
        :get()
    end)
    :get()
end

local function item_position(flat, index)
  local is_item = function(entry)
    return entry._type == "item"
  end
  return hollow.tbl(flat):take(index):count(is_item), hollow.tbl(flat):count(is_item)
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
  return ui.row(
    {
      ui.text(marker(is_selected, is_hovered) .. arrow .. " " .. label, {
        fg = theme.title,
        bold = true,
      }),
    },
    styled_row_options(
      row_options,
      theme,
      util.state_value(
        is_selected,
        is_hovered,
        theme.selection_bg,
        theme.hover_bg,
        theme.selected_detail_bg or theme.panel_bg
      )
    )
  )
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
  local fg =
    util.state_value(is_selected, is_hovered, theme.selected_fg, theme.selected_fg, theme.fg)
  local label_nodes = hollow
    .tbl({
      ui.span(marker(is_selected, is_hovered, "  "), { fg = fg, bold = emphasize }),
      ui.span(label_text, { fg = fg }),
    })
    :concat(chord_text ~= "" and {
      ui.spacer(),
      ui.span(chord_text, { fg = theme.panel_border or theme.muted }),
    } or {})
    :get()
  local fill_bg = util.state_value(is_selected, is_hovered, theme.selection_bg, theme.hover_bg)
  return ui.row({ ui.group(label_nodes) }, styled_row_options(row_options, theme, fill_bg))
end

---@param opts table|nil
function ui.command_palette.open(opts)
  opts = opts or {}
  local theme = resolve_theme(opts)
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
    local entry_rows = #flat > 0
        and hollow.tbl
          .range(viewport.start_idx, viewport.end_idx)
          :filter_map(function(index, visible_index)
            local entry = flat[index]
            local row_id, row_options = selectable.row(index, index, visible_index, viewport)
            local is_selected = index == nav.index
            local is_hovered = state and state.hovered_id == row_id
            if entry._type == "header" then
              return render_section_header(
                theme,
                entry.label,
                is_selected,
                is_hovered,
                collapsed[entry.category],
                row_options
              )
            elseif entry._type == "item" then
              return render_entry_row(entry.item, is_selected, is_hovered, theme, row_options)
            end
          end)
          :get()
      or {
        ui.row({ ui.text("No matches", { fg = theme.empty }) }),
      }

    local rows = hollow
      .tbl({
        ui.row({
          ui.text((opts.prompt or "Command Palette") .. ":", {
            fg = theme.title,
            bold = true,
          }),
          ui.text(counter and ("  " .. counter) or "", { fg = theme.counter }),
        }),
        ui.divider(theme.divider),
        ui.row({
          ui.text("Filter: ", { fg = theme.title, bold = true }),
          ui.group(filter.render(theme)),
        }),
        ui.divider(theme.divider),
      })
      :concat(entry_rows, {
        ui.divider(theme.divider),
        ui.row({
          ui.text("<CR>", { fg = theme.panel_border, bold = true }),
          ui.text(" execute  ", { fg = theme.muted }),
          ui.text("<Esc>", { fg = theme.panel_border, bold = true }),
          ui.text(" dismiss", { fg = theme.muted }),
        }),
      })
      :get()
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
