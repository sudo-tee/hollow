local color = require("hollow.color")
local icons = require("hollow.ui.icons")
local list_style = require("hollow.ui.widgets.list_style")
local program_status = require("hollow.program_status")
local shared = require("hollow.ui.shared")
local util = require("hollow.util")

local hollow = _G.hollow
local ui = hollow.ui

ui.mux_navigator = ui.mux_navigator or {}

local DEFAULT_TOTAL_ROWS = 30
local DEFAULT_WIDTH = 100
local FILTER_ORDER = { "all", "pane_bell" }
local TITLE = ui.styles.title
local MUTED = ui.styles.muted

local FILTERS = {
  all = {
    label = "All panes",
    matches = function()
      return true
    end,
  },
  pane_bell = {
    label = "Pane attention",
    matches = function(pane)
      return program_status.pane_has_attention(pane)
    end,
  },
}

local function matches(query, text)
  return query == "" or shared.select_item_matches(query, text, true)
end

local function pane_value(pane)
  if pane.foreground_process and pane.foreground_process ~= "" then
    return pane.foreground_process
  end
  if pane.title and pane.title ~= "" then
    return pane.title
  end
  return nil
end

local function resolve_filter(id)
  if FILTERS[id] ~= nil then
    return id, FILTERS[id]
  end
  return "all", FILTERS.all
end

local function flatten_tree(tree, collapsed, query, pane_filter)
  local rows = {}
  local searching = query ~= ""

  for _, workspace in ipairs(tree) do
    local workspace_searchable = util.words(workspace.name, workspace.index, "workspace")
    local workspace_matches = matches(query, workspace_searchable)
    local visible_tabs = {}
    local workspace_panes = {}

    for _, tab in ipairs(workspace.tabs) do
      local tab_searchable = util.words(tab.title, tab.index, "tab", workspace_searchable)
      local tab_matches = workspace_matches or matches(query, tab_searchable)
      local visible_panes = {}

      for pane_index, pane in ipairs(tab.panes) do
        local pane_searchable = util.words(
          pane.id,
          pane_value(pane),
          pane.title,
          pane.cwd,
          pane.domain,
          program_status.pane_has_attention(pane) and "bell" or nil,
          "pane",
          tab_searchable
        )
        if pane_filter.matches(pane) and (tab_matches or matches(query, pane_searchable)) then
          visible_panes[#visible_panes + 1] = { pane = pane, index = pane_index }
        end
      end

      if #visible_panes > 0 then
        visible_tabs[#visible_tabs + 1] = { tab = tab, panes = visible_panes }
        for _, visible_pane in ipairs(visible_panes) do
          workspace_panes[#workspace_panes + 1] = visible_pane
        end
      end
    end

    if #visible_tabs > 0 then
      local workspace_key = "workspace:" .. workspace.id
      local workspace_badge, workspace_state = program_status.workspace_badge(workspace)
      rows[#rows + 1] = {
        kind = "workspace",
        key = workspace_key,
        item = workspace,
        depth = 0,
        count = #workspace_panes,
        panes = workspace_panes,
        status_badge = workspace_badge,
        status_state = workspace_state,
      }
      if searching or not collapsed[workspace_key] then
        for _, visible_tab in ipairs(visible_tabs) do
          local tab = visible_tab.tab
          local tab_key = "tab:" .. tab.id
          local tab_badge, tab_state = program_status.badge(tab.panes)
          rows[#rows + 1] = {
            kind = "tab",
            key = tab_key,
            item = tab,
            depth = 1,
            panes = visible_tab.panes,
            status_badge = tab_badge,
            status_state = tab_state,
          }
          if searching or not collapsed[tab_key] then
            for _, visible_pane in ipairs(visible_tab.panes) do
              local pane = visible_pane.pane
              local pane_badge, pane_state = program_status.badge({ pane })
              rows[#rows + 1] = {
                kind = "pane",
                key = "pane:" .. pane.id,
                item = pane,
                index = visible_pane.index,
                depth = 2,
                status_badge = pane_badge,
                status_state = pane_state,
              }
            end
          end
        end
      end
    end
  end

  return rows
end

local function resolve_theme(opts)
  return shared.widget_theme("select", opts.theme, function(theme)
    if theme.subtle == nil then
      local palette = shared.resolve_theme().palette
      theme.subtle = color.brighten_hex_color(palette.background, 0.35, palette.foreground)
    end
  end)
end

local function row_budget(opts)
  local total = shared.normalize_overlay_size(opts.height)
    or shared.normalize_overlay_size(opts.max_height)
    or DEFAULT_TOTAL_ROWS
  return math.max(1, total - 2)
end

local function row_detail(row)
  if row.kind == "workspace" and row.count > 1 then
    return string.format("· %d panes", row.count)
  end
  return ""
end

function ui.mux_navigator.open(opts)
  opts = opts or {}
  local theme = resolve_theme(opts)
  local tree = hollow.term.mux_tree()
  local filter_id, pane_filter = resolve_filter(opts.filter)
  local collapsed = {}
  local nav
  local modal
  local filter = ui.text_input({
    initial = opts.query or "",
    on_change = function()
      if nav then
        nav.index = 1
      end
    end,
  })
  local search_mode = filter.value ~= ""

  local function current_rows()
    return flatten_tree(tree, collapsed, filter.value, pane_filter)
  end

  local function set_filter(id)
    filter_id, pane_filter = resolve_filter(id)
    filter.set("")
    search_mode = false
    if nav then
      nav.index = 1
    end
  end

  local function cycle_filter()
    local current_index = 1
    for index, id in ipairs(FILTER_ORDER) do
      if id == filter_id then
        current_index = index
        break
      end
    end
    local next_index = current_index % #FILTER_ORDER + 1
    set_filter(FILTER_ORDER[next_index])
  end

  local function activate(index)
    local row = current_rows()[index or nav.index]
    if row == nil then
      return
    end
    modal.close()
    if row.kind == "workspace" then
      local target = filter_id == "pane_bell" and row.panes[1] or nil
      target = target and (target.pane or target) or nil
      if target then
        hollow.term.focus_pane_by_id(target.id)
      else
        hollow.term.switch_workspace(row.item.index)
      end
    elseif row.kind == "tab" then
      local target = filter_id == "pane_bell" and row.panes[1] or row.item.pane
      target = target and (target.pane or target) or nil
      if target then
        hollow.term.focus_pane_by_id(target.id)
      end
    else
      hollow.term.focus_pane_by_id(row.item.id)
    end
  end

  local selectable = ui.selectable_list({
    id_prefix = "mux-navigator",
    items = current_rows,
    row_budget = function()
      return row_budget(opts)
    end,
    on_activate = activate,
  })
  nav = selectable.nav

  -- Returns the currently-highlighted row if it can be expanded/collapsed, else nil.
  local function collapsible_row()
    local row = current_rows()[nav.index]
    if row and row.kind ~= "pane" then
      return row
    end
    return nil
  end

  local function set_collapsed(value)
    local row = collapsible_row()
    if row then
      collapsed[row.key] = value
    end
  end

  local function toggle_collapsed()
    local row = collapsible_row()
    if row then
      collapsed[row.key] = not collapsed[row.key]
    end
  end

  local function nav_or_search(fn)
    return function(key, mods)
      if search_mode and #key == 1 then
        return filter.handlers._else(key, mods)
      end
      fn()
    end
  end

  local function render_content(_, state)
    tree = hollow.term.mux_tree()
    local rows = current_rows()
    nav.index = math.max(1, math.min(#rows, nav.index or 1))
    local viewport = selectable.visible_range()
    local tree_rows = #rows > 0
        and hollow.tbl
          .range(viewport.start_idx, viewport.end_idx)
          :map(function(index, visible_index)
            local row = rows[index]
            local row_id, options = selectable.row(index, row.key, visible_index, viewport)
            local selected = index == nav.index
            local hovered = list_style.hovered(state, row_id)
            local active = row.item.is_active or row.item.is_focused
            local is_workspace = row.kind == "workspace"
            local row_fg =
              util.state_value(selected, hovered, theme.selected_fg, theme.hover_fg, theme.fg)
            local base_prefix_fg = row.kind == "pane" and theme.muted or theme.title
            local prefix_fg =
              util.state_value(selected, hovered, theme.selected_fg, theme.title, base_prefix_fg)
            local branch = row.kind == "pane" and ""
              or (collapsed[row.key] and icons.collapsed or icons.expanded) .. " "
            local indent = string.rep("  ", row.depth)
            local pane_attention = row.kind == "pane"
              and program_status.pane_has_attention(row.item)
            local marker = row.kind == "pane"
                and (pane_attention and icons.bell or (row.item.is_focused and icons.pane_active or icons.pane_inactive)) .. " "
              or ""
            local marker_fg = row.kind == "pane"
                and (pane_attention and theme.notify_levels[program_status.attention_level({
                  row.item,
                })] or (row.item.is_focused and theme.notify_levels.success or theme.muted))
              or prefix_fg
            local label = row.kind == "workspace"
                and (row.item.name or ("Workspace " .. row.item.index))
              or row.kind == "tab" and ("Tab " .. row.item.index)
              or ("Pane " .. row.index)
            local value = row.kind == "workspace" and nil
              or row.kind == "tab" and (row.item.title ~= "" and row.item.title or nil)
              or pane_value(row.item)
            local value_fg = row.kind == "pane"
                and value
                and not selected
                and not hovered
                and theme.notify_levels.success
              or row_fg
            local detail = row_detail(row)
            local row_nodes = {
              list_style.indicator(ui, theme, selected, hovered),
              ui.text(indent),
              ui.text(branch, {
                fg = prefix_fg,
                bold = is_workspace or selected or active,
              }),
              ui.text(marker, {
                fg = marker_fg,
                bold = pane_attention or active,
              }),
              ui.text(label, {
                fg = prefix_fg,
                bold = is_workspace or selected or active,
              }),
              ui.when(row.status_badge, function()
                return ui.text(" " .. row.status_badge, {
                  fg = program_status.color(row.status_state),
                  bold = true,
                })
              end),
              ui.when(value ~= nil, function()
                return ui.text(": " .. value, { fg = value_fg, bold = selected or active })
              end),
              ui.when(detail ~= "", function()
                return {
                  ui.spacer(),
                  ui.text(detail, ui.styled(theme, MUTED)),
                }
              end, function()
                return ui.when(row.kind == "pane" and row.item.cwd ~= "", function()
                  return { ui.spacer(), ui.text(row.item.cwd, { fg = theme.subtle }) }
                end)
              end),
            }

            list_style.row(
              options,
              theme,
              selected,
              hovered,
              is_workspace and (theme.selected_detail_bg or theme.panel_bg) or nil
            )

            return ui.row(row_nodes, options)
          end)
          :get()
      or { ui.row({ ui.text("No matching panes", { fg = theme.empty }) }) }

    local search_row = ui.row({
      ui.text("/ ", ui.styled(theme, TITLE)),
      search_mode and ui.group(filter.render(theme))
        or ui.text("search panes", ui.styled(theme, MUTED)),
      ui.spacer(),
      ui.text(filter_id == "pane_bell" and (icons.bell .. " ") or "  ", {
        fg = filter_id == "pane_bell" and theme.notify_levels.warn or theme.muted,
      }),
      ui.text(pane_filter.label, ui.styled(theme, MUTED)),
    })
    return ui.column({ search_row, ui.divider(theme.divider), tree_rows })
  end

  local handlers = {
    ["escape|<C-[>"] = function()
      if search_mode then
        search_mode = false
        filter.set("")
        nav.index = 1
      else
        modal.close()
      end
    end,
    ["arrow_down|j"] = nav_or_search(function()
      nav.index = util.cycle_index(nav.index, 1, #current_rows())
    end),
    ["arrow_up|k"] = nav_or_search(function()
      nav.index = util.cycle_index(nav.index, -1, #current_rows())
    end),
    ["arrow_left|h"] = nav_or_search(function()
      set_collapsed(true)
    end),
    ["arrow_right|l"] = nav_or_search(function()
      set_collapsed(false)
    end),
    space = nav_or_search(toggle_collapsed),
    f = function(key, mods)
      if search_mode then
        return filter.handlers._else(key, mods)
      end
      cycle_filter()
    end,
    enter = function()
      activate(nav.index)
    end,
    slash = function(key, mods)
      if search_mode then
        filter.handlers._else(key, mods)
      else
        search_mode = true
      end
    end,
    backspace = function()
      if search_mode then
        filter.handlers.backspace()
      end
    end,
    _else = function(key, mods)
      if search_mode then
        return filter.handlers._else(key, mods)
      end
      return false
    end,
  }

  local chrome = shared.theme_overlay_chrome(theme)
  if opts.chrome ~= nil then
    chrome = opts.chrome
  end

  local backdrop = opts.backdrop
  if backdrop == nil then
    backdrop = theme.backdrop
  end

  modal = ui.modal({
    theme = theme,
    render = render_content,
    keys = ui.keys(handlers),
    on_event = selectable.on_event,
    width = opts.width or DEFAULT_WIDTH,
    height = opts.height,
    max_height = opts.max_height,
    chrome = chrome,
    backdrop = backdrop,
    theme_backdrop = opts.backdrop == nil,
  })
end

function ui.mux_navigator.close()
  ui.overlay.pop()
end

return {}
