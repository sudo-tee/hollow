local shared = require("hollow.ui.shared")
local theme_api = require("hollow.theme")
local w = require("hollow.ui.builder")

local table_unpack = table.unpack or unpack

local hollow = _G.hollow
local ui = hollow.ui

ui.command_palette = ui.command_palette or {}

local CATEGORY_LABELS = {
  tab = "Tab",
  pane = "Pane",
  workspace = "Workspace",
  window = "Window",
  scroll = "Scroll",
  copy_mode = "Copy Mode",
  general = "General",
  user = "User",
}

local CATEGORY_ORDER = {
  tab = 1,
  pane = 2,
  workspace = 3,
  window = 4,
  scroll = 5,
  copy_mode = 6,
  general = 7,
  user = 8,
}

local DEFAULT_TOTAL_ROWS = 16
local DEFAULT_WIDTH = 100

local function resolve_palette_theme(theme, opts)
  if type(opts.theme) == "table" then
    local u = require("hollow.util")
    u.merge_tables(theme, u.clone_value(opts.theme))
  end
  return theme
end

local function build_entries()
  local action_list = hollow.action.list()
  local entries = {}
  for _, a in ipairs(action_list) do
    local chords = {}
    if type(hollow.keymap.find_by_action) == "function" then
      chords = hollow.keymap.find_by_action(a.name, "normal")
      local copy_chords = hollow.keymap.find_by_action(a.name, "copy_mode")
      for _, c in ipairs(copy_chords) do
        chords[#chords + 1] = c
      end
    end
    local category_label = CATEGORY_LABELS[a.category] or a.category or "General"
    local display_name = a.name:gsub("_", " ")
    local mode_label = ""
    if a.category == "copy_mode" then
      display_name = display_name:gsub("^copy mode ", "")
      mode_label = "[cm]"
    end
    local searchable = a.name .. " " .. (a.desc or "") .. " " .. category_label .. " " .. a.category
    entries[#entries + 1] = {
      name = a.name,
      display_name = display_name,
      mode_label = mode_label,
      desc = a.desc or "",
      category = a.category or "general",
      category_label = category_label,
      chords = chords,
      run = a.run,
      workspace_targetable = a.workspace_targetable or false,
      searchable = searchable,
      searchable_lower = searchable:lower(),
    }
  end
  return entries
end

local function build_workspace_entries()
  local workspaces = hollow.term.workspaces()
  local entries = {}
  for _, ws in ipairs(workspaces) do
    local name = ws.name or ("Workspace " .. ws.index)
    local searchable = name .. " " .. ws.index .. " workspace"
    entries[#entries + 1] = {
      name = name,
      display_name = name,
      mode_label = ws.is_active and "[current]" or "",
      desc = "",
      category = "workspace",
      category_label = "Workspace",
      chords = {},
      run = nil,
      workspace_targetable = false,
      workspace_index = ws.index,
      workspace_id = ws.id,
      searchable = searchable,
      searchable_lower = searchable:lower(),
    }
  end
  return entries
end

local function filtered_entries(all_entries, query)
  local query_lower = query:lower()
  local out = {}
  for _, entry in ipairs(all_entries) do
    local matches, score
    if query == "" then
      matches = true
      score = 0
    else
      matches, score = shared.select_item_matches(query, entry.searchable, true)
    end
    if matches then
      out[#out + 1] = {
        name = entry.name,
        display_name = entry.display_name,
        mode_label = entry.mode_label,
        desc = entry.desc,
        category = entry.category,
        category_label = entry.category_label,
        chords = entry.chords,
        run = entry.run,
        workspace_targetable = entry.workspace_targetable,
        workspace_index = entry.workspace_index,
        workspace_id = entry.workspace_id,
        domain_name = entry.domain_name,
        searchable = entry.searchable,
        score = score or 0,
      }
    end
  end
  if query ~= "" then
    table.sort(out, function(a, b)
      if a.score ~= b.score then
        return a.score > b.score
      end
      if a.name ~= b.name then
        return a.name < b.name
      end
      return a.category < b.category
    end)
  end
  return out
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
    return (CATEGORY_ORDER[a] or 99) < (CATEGORY_ORDER[b] or 99)
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

local function selected_item(flat, cursor)
  if cursor < 1 or cursor > #flat then
    return nil
  end
  local entry = flat[cursor]
  if entry._type ~= "item" then
    return nil
  end
  return entry.item
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

---@param flat table
---@param cursor integer
---@return integer, integer
local function flat_item_index(flat, cursor)
  local item_count = 0
  for _, entry in ipairs(flat) do
    if entry._type == "item" then
      item_count = item_count + 1
    end
  end
  if cursor < 1 or cursor > #flat then
    return 0, item_count
  end
  local count = 0
  for idx = 1, cursor do
    if flat[idx]._type == "item" then
      count = count + 1
    end
  end
  return count, item_count
end

local function clamp_cursor(flat, cursor)
  if #flat == 0 then
    return 0
  end
  if cursor < 1 then
    return 1
  end
  if cursor > #flat then
    return #flat
  end
  return cursor
end

---@param flat table
---@param cursor integer
---@return integer
local function prev_item(flat, cursor)
  if #flat == 0 then
    return 0
  end
  cursor = cursor - 1
  if cursor < 1 then
    cursor = #flat
  end
  return cursor
end

---@param flat table
---@param cursor integer
---@return integer
local function next_item(flat, cursor)
  if #flat == 0 then
    return 0
  end
  cursor = cursor + 1
  if cursor > #flat then
    cursor = 1
  end
  return cursor
end

---@param theme HollowUiTheme
---@param label string
---@param is_selected boolean
---@param is_collapsed boolean
---@return HollowUiOverlayRow
local function render_section_header(theme, label, is_selected, is_collapsed)
  local tags = ui.tags
  local arrow = is_collapsed and "\226\150\182" or "\226\150\188"
  return tags.overlay_row(
    { fill_bg = is_selected and theme.selected_bg or (theme.selected_detail_bg or theme.panel_bg) },
    tags.text(
      { fg = theme.title, bold = true },
      (is_selected and "> " or "  ") .. arrow .. " " .. label
    )
  )
end

---@param entry table
---@param is_selected boolean
---@param theme HollowUiTheme
---@param show_scrollbar boolean
---@param visible_index integer
---@param thumb_index integer
---@return HollowUiRows
local function render_entry_row(
  entry,
  is_selected,
  theme,
  show_scrollbar,
  visible_index,
  thumb_index
)
  local tags = ui.tags
  local chord_text = ""
  if #entry.chords > 0 then
    chord_text = "  " .. table.concat(entry.chords, " ")
  end

  local label_text = ""
  if entry.mode_label and entry.mode_label ~= "" then
    label_text = entry.mode_label .. " "
  end
  if entry.desc and entry.desc ~= "" then
    label_text = label_text .. entry.desc
  else
    label_text = label_text .. entry.display_name
  end

  local label_nodes = {
    ui.span(is_selected and "  > " or "    ", {
      fg = is_selected and theme.selected_fg or theme.fg,
      bold = is_selected,
    }),
    ui.span(label_text, {
      fg = is_selected and theme.selected_fg or theme.fg,
    }),
  }

  if chord_text ~= "" then
    label_nodes[#label_nodes + 1] = ui.spacer()
    label_nodes[#label_nodes + 1] = ui.span(chord_text, {
      fg = theme.panel_border or theme.muted,
    })
  end

  return ui.rows(tags.overlay_row({
    fill_bg = is_selected and theme.selected_bg or nil,
    scrollbar_track = show_scrollbar,
    scrollbar_thumb = show_scrollbar and visible_index == thumb_index,
    scrollbar_track_color = theme.scrollbar_track,
    scrollbar_thumb_color = theme.scrollbar_thumb,
  }, ui.group(label_nodes)))
end

---@param opts table|nil
function ui.command_palette.open(opts)
  opts = opts or {}

  local theme = resolve_palette_theme(theme_api.resolve_widget("select"), opts)
  local backdrop = opts.backdrop ~= nil and opts.backdrop or theme.backdrop
  local all_entries = opts.entries or build_entries()

  local nav = w.scroll_nav(0, { row_budget = DEFAULT_TOTAL_ROWS - 5 })

  local filter = w.text_input({ initial = opts.query or "" })
  local collapsed = {}

  local widget
  widget = ui.overlay.new({
    render = function()
      local tags = ui.tags
      local filtered = filtered_entries(all_entries, filter.value)
      local flat = grouped_entries(filtered, collapsed)
      nav.index = clamp_cursor(flat, nav.index)
      local item_idx, total_items = flat_item_index(flat, nav.index)
      local counter = (total_items > 0) and string.format(" %d/%d", item_idx, total_items) or nil

      local budget = shared.normalize_overlay_size(opts.height)
        or shared.normalize_overlay_size(opts.max_height)
        or DEFAULT_TOTAL_ROWS
      local row_budget = budget - 5

      local start_idx, end_idx, show_scrollbar, thumb_index = nav.visible_range(flat, row_budget)

      local rows = ui.rows(
        tags.overlay_row(
          nil,
          tags.text({ fg = theme.title, bold = true }, (opts.prompt or "Command Palette") .. ":"),
          tags.text({ fg = theme.counter }, counter and ("  " .. counter) or "")
        ),
        tags.divider({ color = theme.divider }),
        tags.overlay_row(
          nil,
          tags.text({ fg = theme.title, bold = true }, "Filter: "),
          table_unpack(filter.render(theme))
        ),
        tags.divider({ color = theme.divider })
      )

      if #flat == 0 then
        rows[#rows + 1] = tags.overlay_row(nil, tags.text({ fg = theme.empty }, " No matches"))
      else
        local display_item_count = 0
        for idx = start_idx, end_idx do
          local entry = flat[idx]
          if entry._type == "header" then
            local is_selected = (idx == nav.index)
            rows[#rows + 1] = render_section_header(
              theme,
              entry.label,
              is_selected,
              collapsed[entry.category]
            )
          elseif entry._type == "item" then
            display_item_count = display_item_count + 1
            local is_selected = (idx == nav.index)
            append_rows(
              rows,
              render_entry_row(
                entry.item,
                is_selected,
                theme,
                show_scrollbar,
                display_item_count,
                thumb_index
              )
            )
          end
        end
      end

      append_rows(rows, tags.divider({ color = theme.divider }))
      append_rows(
        rows,
        tags.overlay_row(
          nil,
          tags.text({ fg = theme.panel_border, bold = true }, "<CR>"),
          tags.text({ fg = theme.muted }, " execute  "),
          tags.text({ fg = theme.panel_border, bold = true }, "<Esc>"),
          tags.text({ fg = theme.muted }, " dismiss")
        )
      )

      return rows
    end,
    on_key = w.keys(filter, nav, {
      escape = function()
        ui.overlay.pop()
        if type(opts.on_cancel) == "function" then
          opts.on_cancel()
        end
      end,
      arrow_down = function()
        local filtered = filtered_entries(all_entries, filter.value)
        local flat = grouped_entries(filtered, collapsed)
        nav.index = clamp_cursor(flat, nav.index)
        if #flat > 0 then
          nav.index = next_item(flat, nav.index)
        end
      end,
      arrow_up = function()
        local filtered = filtered_entries(all_entries, filter.value)
        local flat = grouped_entries(filtered, collapsed)
        nav.index = clamp_cursor(flat, nav.index)
        if #flat > 0 then
          nav.index = prev_item(flat, nav.index)
        end
      end,
      enter = function()
        local filtered = filtered_entries(all_entries, filter.value)
        local flat = grouped_entries(filtered, collapsed)
        nav.index = clamp_cursor(flat, nav.index)
        local entry = flat[nav.index]
        if entry and entry._type == "header" then
          collapsed[entry.category] = not collapsed[entry.category]
          return
        end
        local item = selected_item(flat, nav.index)
        if item ~= nil then
          ui.overlay.pop()
          if type(item.run) == "function" then
            item.run()
          end
          if type(opts.on_confirm) == "function" then
            opts.on_confirm(item)
          end
        end
      end,
    }),
    width = opts.width or DEFAULT_WIDTH,
    height = opts.height,
    max_height = opts.max_height,
    chrome = opts.chrome or shared.theme_overlay_chrome(theme),
    backdrop = backdrop,
  })

  ui.overlay.push(widget)
end

function ui.command_palette.close()
  ui.overlay.pop()
end

local function build_domain_entries()
  local domains = hollow.config.get("domains") or {}
  local current_domain = nil
  local current_pane_id = host_api.current_pane_id and host_api.current_pane_id() or nil
  if current_pane_id and host_api.get_pane_domain then
    current_domain = host_api.get_pane_domain(current_pane_id)
  end
  local entries = {}
  for name, config in pairs(domains) do
    local shell = type(config) == "table" and config.shell or config
    local desc = type(shell) == "string" and ("(" .. shell .. ")") or ""
    local searchable = name .. " " .. (type(shell) == "string" and shell or "") .. " domain"
    entries[#entries + 1] = {
      name = name,
      display_name = name,
      mode_label = (name == current_domain) and "[current]" or "",
      desc = desc,
      category = "general",
      category_label = "Domain",
      chords = {},
      run = nil,
      workspace_targetable = false,
      domain_name = name,
      searchable = searchable,
      searchable_lower = searchable:lower(),
    }
  end
  table.sort(entries, function(a, b)
    return a.name < b.name
  end)
  return entries
end

ui.command_palette.build_workspace_entries = build_workspace_entries
ui.command_palette.build_domain_entries = build_domain_entries

return {}
