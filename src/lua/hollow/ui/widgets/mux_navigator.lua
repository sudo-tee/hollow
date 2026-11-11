local color = require("hollow.color")
local icons = require("hollow.ui.icons")
local list_item = require("hollow.ui.components.list_item")
local list_row = require("hollow.ui.recipes.list_row")
local program_status = require("hollow.program_status")
local props = require("hollow.ui.components.props")
local rich = require("hollow.ui.components.rich")
local shared = require("hollow.ui.shared")
local styles = require("hollow.ui.recipes.mux_navigator")
local util = require("hollow.util")

---@type Hollow
local hollow = _G.hollow
---@type HollowUi
local ui = hollow.ui

ui.mux_navigator = ui.mux_navigator or {}

local DEFAULT_TOTAL_ROWS = 30
local DEFAULT_WIDTH = 100
local FILTER_ORDER = { "all", "pane_bell", "hidden" }
local function row_styles(theme, row, selected, hovered, active, attention)
  local s = styles(theme, { variant = row.kind, selected = selected, hovered = hovered })
  local marker_fg
  if row.kind == "pane" then
    marker_fg = attention and theme.notify_levels[program_status.attention_level({ row.item })]
      or (row.item.is_focused and theme.notify_levels.success or nil)
  end
  local emphasis = active and { bold = true }
  return {
    prefix = ui.style(s.prefix, emphasis),
    marker = ui.style(
      s.marker,
      marker_fg and { fg = marker_fg },
      (attention or active) and { bold = true }
    ),
    status = row.status_badge
      and ui.style(s.status, { fg = program_status.color(row.status_state) }),
    value = ui.style(s.value, emphasis),
  }
end

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
  hidden = {
    label = "Hidden panes",
    matches = function(pane)
      return pane.is_hidden == true
    end,
  },
}

local FILTER_ICONS = { pane_bell = icons.bell, hidden = icons.pane_hidden }

---@param query string
---@param text string
---@return boolean
local function matches(query, text)
  return query == "" or shared.select_item_matches(query, text, true)
end

---@param pane HollowPane
---@return string|nil
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

-- Docks render as a pseudo tab per workspace, plus a pseudo workspace for
-- global docks, so they share search, filters, and activation with tabs.
local function with_docks(tree, global_docks)
  local result = {}
  if #global_docks > 0 then
    result[1] = {
      id = "global-docks",
      name = "Global docks",
      index = 0,
      is_dock = true,
      tabs = {
        { id = "dock:global", title = "", index = 0, is_dock = true, panes = global_docks },
      },
    }
  end
  for _, workspace in ipairs(tree) do
    if workspace.docks and #workspace.docks > 0 then
      local tabs = {}
      for _, tab in ipairs(workspace.tabs) do
        tabs[#tabs + 1] = tab
      end
      tabs[#tabs + 1] = {
        id = "dock:" .. tostring(workspace.id),
        title = "",
        index = #workspace.tabs + 1,
        is_dock = true,
        panes = workspace.docks,
      }
      local copy = setmetatable({ tabs = tabs }, { __index = workspace })
      result[#result + 1] = copy
    else
      result[#result + 1] = workspace
    end
  end
  return result
end

local function global_docks()
  local docks = {}
  for _, pane in ipairs(util.safe_call(hollow.term.docks, {}) or {}) do
    if pane.dock and pane.dock.scope == "global" then
      docks[#docks + 1] = pane
    end
  end
  return docks
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
      local tab_searchable =
        util.words(tab.title, tab.index, tab.is_dock and "dock" or "tab", workspace_searchable)
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
          pane.is_hidden == true and "hidden" or nil,
          pane.dock and ("dock " .. pane.dock.edge) or nil,
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
  if row.kind == "tab" then
    local hidden = 0
    for _, pane in ipairs(row.item.panes or {}) do
      if pane.is_hidden == true then
        hidden = hidden + 1
      end
    end
    if hidden > 0 then
      return string.format("%s %d hidden", icons.pane_hidden, hidden)
    end
  end
  return ""
end

-- Hidden panes reject focus, so reveal them first; both requests are queued in order.
local function focus_pane(pane)
  if pane.is_hidden == true then
    hollow.term.set_pane_visible(pane.id, true)
  end
  hollow.term.focus_pane_by_id(pane.id)
end

---@param opts HollowUiMuxNavigatorOptions|nil
function ui.mux_navigator.open(opts)
  opts = opts or {}
  local theme = resolve_theme(opts)
  local clay_budget, reveal_start = math.min(20, row_budget(opts)), false
  local tree = with_docks(hollow.term.mux_tree(), global_docks())
  local filter_id, pane_filter = resolve_filter(opts.filter)
  local collapsed = {}
  local nav
  local modal
  local refresh_after
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
      local target = (filter_id ~= "all" or row.item.is_dock) and row.panes[1] or nil
      target = target and (target.pane or target) or nil
      if target then
        focus_pane(target)
      else
        hollow.term.switch_workspace(row.item.index)
      end
    elseif row.kind == "tab" then
      local target = (filter_id ~= "all" or row.item.is_dock) and row.panes[1] or row.item.pane
      target = target and (target.pane or target) or nil
      if target then
        focus_pane(target)
      end
    else
      focus_pane(row.item)
    end
  end

  -- Toggle the selected pane's visibility without leaving the navigator.
  local function toggle_visibility()
    local row = current_rows()[nav.index]
    if row and row.kind == "pane" then
      -- The row snapshot lags until the layout event re-renders; read live state.
      local pane = hollow.term.pane_by_id(row.item.id) or row.item
      hollow.term.set_pane_visible(pane.id, pane.is_hidden == true)
    end
  end

  local selectable = ui.selectable_list({
    id_prefix = "mux-navigator",
    items = current_rows,
    row_budget = function()
      return clay_budget
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

  local function row_nodes(row, index, hovered)
    local selected = index == nav.index
    local active = row.item.is_active or row.item.is_focused
    local branch = row.kind == "pane" and ""
      or (collapsed[row.key] and icons.collapsed or icons.expanded) .. " "
    local indent = string.rep("  ", row.depth)
    local pane_attention = row.kind == "pane" and program_status.pane_has_attention(row.item)
    local pane_hidden = row.kind == "pane" and row.item.is_hidden == true
    local marker = row.kind == "pane"
        and (pane_attention and icons.bell or pane_hidden and icons.pane_hidden or (row.item.is_focused and icons.pane_active or icons.pane_inactive)) .. " "
      or ""
    local label = row.kind == "workspace" and (row.item.name or ("Workspace " .. row.item.index))
      or row.kind == "tab" and (row.item.is_dock and "Docks" or ("Tab " .. row.item.index))
      or row.item.dock and ("Dock " .. row.item.dock.edge)
      or ("Pane " .. row.index)
    local value = row.kind == "workspace" and nil
      or row.kind == "tab" and (row.item.title ~= "" and row.item.title or nil)
      or pane_value(row.item)
    local row_s = row_styles(theme, row, selected, hovered, active, pane_attention)
    local detail = row_detail(row)
    return {
      ui.text("  ", list_row(theme, { selected = selected }).indicator),
      ui.text(indent),
      ui.text(branch, row_s.prefix),
      ui.text(marker, row_s.marker),
      ui.text(label, row_s.prefix),
      ui.when(row.status_badge, function()
        return ui.text(" " .. row.status_badge, row_s.status)
      end),
      ui.when(value ~= nil, function()
        return ui.text(": " .. value, row_s.value)
      end),
      ui.when(pane_hidden, function()
        return ui.text(" (hidden)", styles(theme).muted)
      end),
      ui.when(detail ~= "", function()
        return {
          ui.spacer(),
          ui.text(detail, styles(theme).muted),
        }
      end, function()
        return ui.when(row.kind == "pane" and row.item.cwd ~= "", function()
          return { ui.spacer(), ui.text(row.item.cwd, styles(theme).subtle) }
        end)
      end),
    }
  end

  local handlers = {
    page_down = function()
      nav.page_down()
    end,
    page_up = function()
      nav.page_up()
    end,
    home = function()
      nav.index = 1
    end,
    ["end"] = function()
      nav.index = #current_rows()
    end,
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
    v = nav_or_search(toggle_visibility),
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
    title = opts.title or "Mux Navigator",
    theme = theme,
    layout_events = {
      "term:program_status_changed",
      "term:bell",
      "term:pane_focused",
      "term:pane_created",
      "term:pane_exited",
      "term:pane_closed",
      "term:pane_layout_changed",
      "term:title_changed",
      "term:cwd_changed",
      "term:foreground_process_changed",
      "term:tab_activated",
      "term:tab_closed",
      "workspace:new",
      "workspace:changed",
      "workspace:closed",
      "config:reloaded",
      "config:changed",
      "theme:changed",
      "term:command_started",
      "term:command_finished",
    },
    layout_refresh_after = function()
      return refresh_after
    end,
    render = function(render_theme, state, ctx)
      local c = ui.components
      tree = with_docks(hollow.term.mux_tree(), global_docks())
      local rows = current_rows()
      refresh_after = nil
      for _, row in ipairs(rows) do
        if row.status_state == "working" then
          local now = util.host_now_ms(require("hollow.state").get().host_api)
          refresh_after = 100 - now % 100
          break
        end
      end
      nav.index = math.max(1, math.min(#rows, nav.index or 1))
      local line_h = rows[1] and rich.height(row_nodes(rows[1], 1, false), ctx)
        or list_item.line_height(render_theme, ctx)
      local measured = ctx.metrics and ctx.metrics["mux:viewport"]
      if measured then
        clay_budget = math.max(1, math.min(20, math.floor(measured.height / line_h)))
      end
      local viewport = selectable.visible_range()
      local function render_item(row, index, view)
        local id = "mux-navigator:item:" .. row.key
        local hovered = state and state.hovered_id == id
        return c.list_item({
          id = id,
          theme = theme,
          variant = row.kind == "workspace" and "section" or nil,
          selected = index == nav.index,
          hovered = hovered,
          on_activate = function()
            for current_index, current in ipairs(current_rows()) do
              if current.key == row.key then
                nav.index, reveal_start = current_index, false
                activate(current_index)
                return
              end
            end
          end,
          c.rich({
            width = "grow",
            prefix = id,
            plain = view.plain,
            row_nodes(row, index, hovered),
          }),
        })
      end
      local s = styles(render_theme)
      local target = rows[reveal_start and viewport.start_idx or nav.index]
      local cell_h = props.cell_h(ctx)
      return c.picker({
        id = "mux:picker",
        theme = render_theme,
        header = c.rich({
          width = "grow",
          height = cell_h,
          scroll_x = true,
          ui.text("/ ", s.title),
          search_mode and ui.group(filter.render(render_theme)) or ui.text("search panes", s.muted),
          ui.spacer(),
          ui.text(
            FILTER_ICONS[filter_id] and (FILTER_ICONS[filter_id] .. " ") or "  ",
            filter_id == "pane_bell" and s.filter_bell or s.filter
          ),
          ui.text(pane_filter.label, s.muted),
        }),
        list = {
          id = "mux:viewport",
          measure = true,
          reveal = target and ("mux-navigator:item:" .. target.key) or nil,
          reveal_start = reveal_start,
          viewport = viewport,
          items = rows,
          selected = nav.index,
          render_item = render_item,
          empty = c.empty({ text = "No matching panes", style = s.empty, wrap = "words" }),
        },
      }),
        2 * cell_h + math.max(1, math.min(#rows, row_budget(opts))) * line_h
    end,
    keys = function(key, mods)
      local consumed = ui.keys(handlers)(key, mods)
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
