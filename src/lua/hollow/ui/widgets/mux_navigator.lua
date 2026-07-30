local shared = require("hollow.ui.shared")
local theme_api = require("hollow.theme")
local util = require("hollow.util")

local hollow = _G.hollow
local ui = hollow.ui

ui.mux_navigator = ui.mux_navigator or {}

local DEFAULT_TOTAL_ROWS = 30
local DEFAULT_WIDTH = 100

-- ▶ collapsed / ▼ expanded
local ICON_COLLAPSED = "\226\150\182"
local ICON_EXPANDED = "\226\150\188"
local ICON_BELL = "\226\151\143 "

local function matches(query, text)
  return query == "" or shared.select_item_matches(query, text, true)
end

local function flatten_tree(tree, collapsed, query)
  local rows = {}
  local searching = query ~= ""

  for _, workspace in ipairs(tree) do
    local workspace_searchable = util.words(workspace.name, workspace.index, "workspace")
    local workspace_matches = matches(query, workspace_searchable)
    local visible_tabs = {}

    for _, tab in ipairs(workspace.tabs) do
      local tab_searchable = util.words(tab.title, tab.index, "tab", workspace_searchable)
      local tab_matches = workspace_matches or matches(query, tab_searchable)
      local visible_panes = {}

      for pane_index, pane in ipairs(tab.panes) do
        local pane_searchable =
          util.words(pane.title, pane.foreground_process, pane.cwd, pane.id, "pane", tab_searchable)
        if tab_matches or matches(query, pane_searchable) then
          visible_panes[#visible_panes + 1] = { pane = pane, index = pane_index }
        end
      end

      if tab_matches or #visible_panes > 0 then
        visible_tabs[#visible_tabs + 1] = { tab = tab, panes = visible_panes }
      end
    end

    if workspace_matches or #visible_tabs > 0 then
      local workspace_key = "workspace:" .. workspace.id
      rows[#rows + 1] = {
        kind = "workspace",
        key = workspace_key,
        item = workspace,
        depth = 0,
        count = #workspace.tabs,
      }
      if searching or not collapsed[workspace_key] then
        for _, visible_tab in ipairs(visible_tabs) do
          local tab = visible_tab.tab
          local tab_key = "tab:" .. tab.id
          rows[#rows + 1] = {
            kind = "tab",
            key = tab_key,
            item = tab,
            depth = 1,
            count = #tab.panes,
          }
          if searching or not collapsed[tab_key] then
            for _, visible_pane in ipairs(visible_tab.panes) do
              local pane = visible_pane.pane
              rows[#rows + 1] = {
                kind = "pane",
                key = "pane:" .. pane.id,
                item = pane,
                index = visible_pane.index,
                depth = 2,
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
  local theme = theme_api.resolve_widget("select")
  if type(opts.theme) == "table" then
    util.merge_tables(theme, util.clone_value(opts.theme))
  end
  return theme
end

local function row_budget(opts)
  local total = shared.normalize_overlay_size(opts.height)
    or shared.normalize_overlay_size(opts.max_height)
    or DEFAULT_TOTAL_ROWS
  return math.max(1, total - 5)
end

local function row_text(row, collapsed)
  local branch = row.kind == "pane" and " "
    or (collapsed[row.key] and ICON_COLLAPSED or ICON_EXPANDED)
  local indent = string.rep("  ", row.depth)
  if row.kind == "workspace" then
    return indent .. branch .. " " .. (row.item.name or ("Workspace " .. row.item.index))
  elseif row.kind == "tab" then
    local title = row.item.title ~= "" and (": " .. row.item.title) or ""
    return indent .. branch .. " " .. row.item.index .. title
  end
  return indent .. branch .. " Pane " .. row.index
end

local function row_detail(row)
  if row.kind == "workspace" then
    return string.format("%d tab%s", row.count, row.count == 1 and "" or "s")
  elseif row.kind == "tab" then
    return string.format("%d pane%s", row.count, row.count == 1 and "" or "s")
  end
  return row.item.foreground_process or ""
end

function ui.mux_navigator.open(opts)
  opts = opts or {}
  local theme = resolve_theme(opts)
  local tree = hollow.term.mux_tree()
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
    return flatten_tree(tree, collapsed, filter.value)
  end

  local function activate(index)
    local row = current_rows()[index or nav.index]
    if row == nil then
      return
    end
    modal.close()
    if row.kind == "workspace" then
      hollow.term.switch_workspace(row.item.index)
    elseif row.kind == "tab" then
      -- Focus the tab's first pane; tabs themselves have no single "active" pane field.
      local first_pane = row.item.panes[1]
      if first_pane then
        hollow.term.focus_pane_by_id(first_pane.id)
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
            local hovered = state and state.hovered_id == row_id
            local active = row.item.is_active or row.item.is_focused
            local is_workspace = row.kind == "workspace"
            local fg = is_workspace and theme.title
              or util.state_value(selected, active, theme.selected_fg, theme.title, theme.fg)

            options.fill_bg = util.state_value(
              selected,
              hovered,
              theme.selection_bg,
              theme.hover_bg,
              is_workspace and (theme.selected_detail_bg or theme.panel_bg) or nil
            )

            options.scrollbar_track_color = theme.scrollbar_track
            options.scrollbar_thumb_color = theme.scrollbar_thumb

            return ui.row({
              ui.text(selected and "> " or "  ", {
                fg = fg,
                bold = is_workspace or selected or active,
              }),
              ui.text(row.kind == "pane" and row.item.has_bell and ICON_BELL or "  ", {
                fg = row.item.has_bell and theme.notify_levels.warn or fg,
                bold = row.item.has_bell,
              }),
              ui.text(row_text(row, collapsed), {
                fg = fg,
                bold = is_workspace or selected or active,
              }),
              ui.spacer(),
              ui.text(row_detail(row), { fg = theme.muted }),
            }, options)
          end)
          :get()
      or { ui.row({ ui.text("No matching panes", { fg = theme.empty }) }) }

    local search_row = search_mode
        and ui.row({
          ui.text("/ ", { fg = theme.title, bold = true }),
          ui.group(filter.render(theme)),
        })
      or ui.row({ ui.text("/ search panes", { fg = theme.muted }) })
    return ui.column(hollow
      .tbl({
        search_row,
        ui.divider(theme.divider),
      })
      :concat(tree_rows, {
        ui.divider(theme.divider),
        ui.row({
          ui.text("enter switch  space/h/l collapse  j/k move  esc close", { fg = theme.muted }),
        }),
      })
      :get())
  end

  local handlers = {
    escape = function()
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

  modal = ui.modal({
    theme = theme,
    render = render_content,
    keys = ui.keys(handlers),
    on_event = selectable.on_event,
    width = opts.width or DEFAULT_WIDTH,
    height = opts.height,
    max_height = opts.max_height,
    chrome = chrome,
    backdrop = opts.backdrop ~= nil and opts.backdrop or theme.backdrop,
  })
end

function ui.mux_navigator.close()
  ui.overlay.pop()
end

return {}
