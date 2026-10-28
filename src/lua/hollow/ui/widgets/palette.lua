local icons = require("hollow.ui.icons")
local list_style = require("hollow.ui.widgets.list_style")
local shared = require("hollow.ui.shared")
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

local DEFAULT_TOTAL_ROWS = 24
local DEFAULT_WIDTH = 100
local SECTION_TITLE = { fg = "title", bold = true, padding = list_style.section_padding }
local TITLE = ui.styles.title
local MUTED = ui.styles.muted
local KEY_HINT = { fg = "panel_border", bold = true }
local DOMAIN_BULLET = { fg = "muted", bold = false }
local DOMAIN_ACTIVE = { bold = true }

local function list_row_budget(opts)
  local total = shared.normalize_overlay_size(opts.height)
    or shared.normalize_overlay_size(opts.max_height)
    or DEFAULT_TOTAL_ROWS
  return math.max(1, total - 5)
end

local function resolve_theme(opts)
  return shared.widget_theme("select", opts.theme)
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
  local snapshots
  return hollow
    .tbl(hollow.action.list())
    :filter_map(function(a)
      if a.available then
        snapshots = snapshots
          or {
            pane = hollow.term.current_pane(),
            tab = hollow.term.current_tab(),
            workspace = hollow.term.current_workspace(),
          }
        local ok, available = pcall(a.available, {
          name = a.name,
          origin = "palette",
          args = { n = 0 },
          pane = snapshots.pane,
          tab = snapshots.tab,
          workspace = snapshots.workspace,
        })
        if not ok or available ~= true then
          return nil
        end
      end

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
        run = function()
          local result = hollow.action.invoke(a.name, nil, { origin = "palette" })
          if not result.success then
            hollow.ui.notify.error(result.error)
          end
        end,
        workspace_targetable = a.workspace_targetable or false,
        searchable = util.words(a.name, a.desc, category_label(category), category),
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
        searchable = util.words(name, ws.index, "workspace"),
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
      is_active = name == current_domain,
      desc = shell_str,
      category = "general",
      category_label = "Domain",
      domain_name = name,
      searchable = util.words(name, shell_str, "domain"),
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
  local arrow = is_collapsed and icons.collapsed or icons.expanded
  return ui.row(
    {
      list_style.indicator(
        ui,
        theme,
        is_selected,
        is_hovered,
        nil,
        list_style.section_indicator_padding
      ),
      ui.text(arrow .. " " .. label, ui.styled(theme, SECTION_TITLE)),
    },
    list_style.row(
      row_options,
      theme,
      is_selected,
      is_hovered,
      theme.selected_detail_bg or theme.panel_bg
    )
  )
end

---@param entry table
---@param is_selected boolean
---@param is_hovered boolean
---@param theme HollowUiTheme
---@param row_options table
---@param query string
---@return HollowUiRowNode
local function render_entry_row(entry, is_selected, is_hovered, theme, row_options, query)
  local chord_text = #entry.chords > 0 and ("  " .. table.concat(entry.chords, " ")) or ""
  local right_text = entry.domain_name and entry.desc or chord_text
  local label_text = (entry.mode_label ~= "" and (entry.mode_label .. " ") or "")
    .. (
      entry.domain_name and entry.display_name
      or (entry.desc ~= "" and entry.desc or entry.display_name)
    )
  local fg =
    util.state_value(is_selected, is_hovered, theme.selected_fg, theme.selected_fg, theme.fg)
  local active_color = shared.resolve_theme().palette.bright_green
  local label_fg = entry.domain_name and entry.is_active and active_color or fg
  local label_nodes = {
    list_style.indicator(ui, theme, is_selected, is_hovered, "  "),
    ui.when(entry.domain_name, function()
      return ui.span(
        entry.is_active and "• " or "  ",
        ui.styled(
          theme,
          DOMAIN_BULLET,
          entry.is_active and DOMAIN_ACTIVE,
          entry.is_active and { fg = active_color }
        )
      )
    end),
    shared.highlight_inline_nodes(
      { ui.span(label_text, { fg = label_fg, bold = entry.domain_name and entry.is_active }) },
      query,
      ui.styled(theme, KEY_HINT)
    ),
    ui.when(right_text ~= "", function()
      return {
        ui.spacer(),
        ui.group(
          shared.highlight_inline_nodes(
            { ui.span(right_text, { fg = theme.panel_border or theme.muted }) },
            query,
            ui.styled(theme, KEY_HINT)
          )
        ),
      }
    end),
  }
  return ui.row(
    { ui.group(label_nodes) },
    list_style.row(row_options, theme, is_selected, is_hovered)
  )
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
            local is_hovered = list_style.hovered(state, row_id)
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
              return render_entry_row(
                entry.item,
                is_selected,
                is_hovered,
                theme,
                row_options,
                filter.value
              )
            end
          end)
          :get()
      or {
        ui.row({ ui.text("No matches", { fg = theme.empty }) }),
      }

    local rows = {
      ui.row({
        ui.text((opts.prompt or "Command Palette") .. ":", ui.styled(theme, TITLE)),
        ui.text(counter and ("  " .. counter) or "", { fg = theme.counter }),
      }),
      ui.divider(theme.divider),
      ui.row({
        ui.text("Filter: ", ui.styled(theme, TITLE)),
        ui.group(filter.render(theme)),
      }),
      ui.divider(theme.divider),
      entry_rows,
      ui.divider(theme.divider),
      ui.row({
        ui.text("<CR>", ui.styled(theme, KEY_HINT)),
        ui.text(" execute  ", ui.styled(theme, MUTED)),
        ui.text("<Esc>", ui.styled(theme, KEY_HINT)),
        ui.text(" dismiss", ui.styled(theme, MUTED)),
      }),
    }
    return ui.column(rows)
  end

  modal = ui.modal({
    theme = theme,
    render = render_content,
    keys = ui.keys(filter, nav, {
      ["escape|<C-[>"] = function()
        modal.close()
        util.safe_call(opts.on_cancel)
      end,
      ["arrow_down|<C-j>"] = function()
        nav.index = util.cycle_index(nav.index, 1, #current_flat())
      end,
      ["arrow_up|<C-k>"] = function()
        nav.index = util.cycle_index(nav.index, -1, #current_flat())
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
