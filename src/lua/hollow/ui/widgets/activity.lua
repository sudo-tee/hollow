local color = require("hollow.color")
local icons = require("hollow.ui.icons")
local list_row = require("hollow.ui.recipes.list_row")
local program_status = require("hollow.program_status")
local shared = require("hollow.ui.shared")
local styles = require("hollow.ui.recipes.activity")
local util = require("hollow.util")
local hollow = _G.hollow
local ui = hollow.ui

ui.activity = {}

local DEFAULT_WIDTH = 100
local DEFAULT_HEIGHT = 24
local BADGE_LEVELS = { error = true, warn = true }
local LEVEL_RANK = { info = 1, success = 1, warn = 2, error = 3 }
local SECTIONS = { tasks = "Tasks", commands = "Commands", today = "Today", earlier = "Earlier" }

local function now_ms()
  return util.host_now_ms(require("hollow.state").get().host_api)
end

local function seconds_since(timestamp)
  return math.max(0, math.floor((now_ms() - timestamp) / 1000))
end

-- Live work shows elapsed seconds; finished items read as a coarse age.
local function age(entry)
  local live = entry.started_ms ~= nil
  local timestamp = entry.started_ms or entry.timestamp_ms
  if not timestamp then
    return "", 0
  end
  local seconds = seconds_since(timestamp)
  if seconds < 60 then
    return live and (seconds .. "s") or "now", seconds
  end
  if seconds < 3600 then
    return math.floor(seconds / 60) .. "m", seconds
  end
  return math.floor(seconds / 3600) .. "h", seconds
end

local function same_day(timestamp)
  local a = os.date("*t", math.floor(timestamp / 1000))
  local b = os.date("*t", math.floor(now_ms() / 1000))
  return a.year == b.year and a.yday == b.yday
end

local function title(entry)
  local label = entry.title
  if not label or label == "" then
    label = entry.state and ("Program " .. entry.state) or "Notification"
  end
  return label .. ((entry.count or 1) > 1 and (" ×" .. entry.count) or "")
end

local function location(entry)
  return util.words(
    entry.workspace,
    entry.pane_title,
    entry.cwd,
    entry.pane_closed and "(pane closed)" or nil
  )
end

local function squash(value)
  return value and (value:gsub("%s+", " ")) or nil
end

-- Primary text carries identity; secondary carries state or message detail.
local function row_parts(entry)
  if entry.source == "shell_command" then
    return squash(entry.title or "Command"), "Running"
  end
  if entry.kind == "program" then
    local app = entry.app and entry.app ~= "" and entry.app or "Program"
    local state = entry.state or "idle"
    return squash(app), (state:gsub("^%l", string.upper))
  end
  local label = title(entry)
  local message = entry.kind == "notification" and entry.message ~= "" and entry.message or nil
  if message and label == "Notification" then
    return squash(message), nil
  end
  if message == entry.title then
    message = nil
  end
  return squash(label), squash(message)
end

local function row_label(entry)
  local primary, secondary = row_parts(entry)
  return secondary and (primary .. " · " .. secondary) or primary
end

local function hint_row(theme, text)
  local hints = {}
  for key, label in text:gmatch("(%S+) ([^%s]+)") do
    hints[#hints + 1] = { key = key, label = label }
  end
  local s = styles(theme)
  return ui.row(ui.each(hints, function(hint)
    return {
      ui.text(hint.key, s.title),
      ui.text(" " .. hint.label .. "   ", s.muted),
    }
  end))
end

local function marker(entry)
  if entry.source == "shell_command" and entry.category ~= "task" then
    return "▸ "
  end
  if entry.kind == "program" then
    return program_status.badge({
      {
        program_status = {
          { state = entry.state, kind = entry.block_kind, progress = entry.progress },
        },
      },
    }) or ""
  end
  if entry.kind == "bell" then
    return icons.bell .. " "
  end
  return entry.pending == false and "○ " or "● "
end

local function state_color(theme, entry)
  if entry.source == "shell_command" and entry.category ~= "task" then
    return theme.muted
  end
  return program_status.color(entry.state) or theme.notify_levels[entry.level]
end

local function entry_styles(theme, entry, row_state, columns, seconds)
  local read = entry.pending == false and not entry.started_ms
  local accent = state_color(theme, entry)
  local status_like = entry.kind == "program" or entry.source == "shell_command"
  local selected = row_state.selected
  local s = styles(theme, {
    variant = read and "read" or nil,
    selected = selected,
    hovered = row_state.hovered,
  })
  return {
    marker = ui.style(s.marker, not read and { fg = accent or row_state.fg }),
    primary = s.primary,
    secondary = ui.style(s.secondary, status_like and accent and { fg = accent }),
    stale = { fg = columns.stale },
    time = ui.style(s.time, seconds >= 3600 and not selected and { fg = columns.stale }),
  }
end

---@param opts? HollowUiActivityOptions
---@return HollowUiModalHandle | nil
function ui.activity.open(opts)
  opts = opts or {}
  local view = opts.view or "inbox"
  assert(view == "inbox" or view == "history", "activity view must be inbox or history")
  local theme = shared.widget_theme("select", opts.theme)
  local chrome = opts.chrome
  if chrome == nil then
    chrome = shared.theme_overlay_chrome(theme)
  end
  local backdrop = opts.backdrop
  if backdrop == nil then
    backdrop = theme.backdrop
  end
  local expanded = { tasks = true, commands = false, today = true, earlier = true }
  local search_expanded = {}
  local searching = false
  local width = opts.width or DEFAULT_WIDTH
  local height = opts.height or opts.max_height or DEFAULT_HEIGHT
  height = math.min(height, opts.max_height or height)
  local clay_budget = math.min(20, math.max(1, height - 6))
  local reveal_start = false
  local modal, list, details
  local copy_feedback
  local detail_options = {
    width = width - 6,
    row_budget = math.min(20, math.max(1, height - 4)),
  }
  local detail_view = ui.text_view(detail_options)
  local rows = {}
  local row_group = {}
  local filter = ui.text_input({
    on_change = function()
      search_expanded = {}
      if list then
        list.nav.index = 1
      end
    end,
  })

  local function category_expanded(category)
    if filter.value ~= "" then
      return search_expanded[category] ~= false
    end
    return expanded[category]
  end

  local function refresh()
    local selected = list and rows[list.nav.index]
    local selected_id = selected and selected.id
    local entries = hollow.activity.list({ view = view })
    local running = view == "inbox" and hollow.activity.running() or {}
    local blocked = {}
    for _, entry in ipairs(entries) do
      if entry.kind == "program" and entry.state == "blocked" then
        blocked["program:" .. entry.pane_id .. ":" .. entry.program_id] = true
      end
    end
    running = hollow
      .tbl(running)
      :filter(function(entry)
        return entry.state ~= "blocked" or not blocked[entry.id]
      end)
      :get()
    local function matching(items)
      local matches = {}
      for _, entry in ipairs(items) do
        local text =
          util.words(row_label(entry), title(entry), entry.message, location(entry), entry.state)
        if filter.value == "" or shared.select_item_matches(filter.value, text, true) then
          matches[#matches + 1] = entry
        end
      end
      return matches
    end
    rows = {}
    row_group = {}
    local groups = { tasks = {}, commands = {}, today = {}, earlier = {} }
    local order = { "tasks", "commands" }
    if view == "history" then
      order = { "today", "earlier" }
      for _, entry in ipairs(entries) do
        local category = (not entry.timestamp_ms or same_day(entry.timestamp_ms)) and "today"
          or "earlier"
        groups[category][#groups[category] + 1] = entry
      end
    else
      rows = matching(entries)
    end
    for _, entry in ipairs(running) do
      local category = entry.source == "shell_command" and entry.category ~= "task" and "commands"
        or "tasks"
      groups[category][#groups[category] + 1] = entry
    end
    for _, category in ipairs(order) do
      local items = matching(groups[category])
      if #items > 0 then
        local open = category_expanded(category)
        rows[#rows + 1] = {
          id = "category:" .. category,
          header_category = category,
          title = SECTIONS[category],
          count = #items,
          expanded = open,
        }
        if open then
          for _, entry in ipairs(items) do
            rows[#rows + 1] = entry
            row_group[entry] = category
          end
        end
      end
    end
    if list then
      for index, entry in ipairs(rows) do
        if entry.id == selected_id then
          list.nav.index = index
          return
        end
      end
      list.nav.index = math.max(1, math.min(list.nav.index, #rows))
    end
  end

  local function skip_leading_header()
    if rows[1] and rows[1].header_category and rows[2] and not rows[2].header_category then
      list.nav.index = 2
    end
  end

  local function set_view(value)
    view = value
    list.nav.index = 1
    refresh()
    skip_leading_header()
  end

  local function toggle_category(category)
    local selected = rows[list.nav.index]
    local target = filter.value ~= "" and search_expanded or expanded
    target[category] = not category_expanded(category)
    if selected and row_group[selected] == category and not target[category] then
      for index, entry in ipairs(rows) do
        if entry.header_category == category then
          list.nav.index = index
          break
        end
      end
    end
    refresh()
  end

  local function activate(index)
    local entry = rows[index]
    if entry and entry.header_category then
      toggle_category(entry.header_category)
      return
    end
    if not entry or not entry.pane_id or entry.pane_closed then
      return
    end
    if hollow.term.pane_by_id(entry.pane_id) == nil then
      return
    end
    hollow.term.focus_pane_by_id(entry.pane_id)
    if type(entry.id) == "number" then
      hollow.activity.dismiss(entry.id)
    end
    modal.close()
  end

  local function dismiss()
    local entry = rows[list.nav.index]
    if entry and type(entry.id) == "number" then
      hollow.activity.dismiss(entry.id)
      refresh()
    end
  end

  local function inspect()
    copy_feedback = nil
    local entry = rows[list.nav.index]
    details = entry and not entry.header_category and entry or nil
    if details then
      detail_view.set(
        title(details) .. "\n\n" .. (details.message or "") .. "\n\n" .. location(details)
      )
    end
  end

  local function copy()
    local entry = details or rows[list.nav.index]
    if not entry or entry.header_category then
      return
    end
    local heading = entry.title
    if not heading or heading == "" then
      heading = entry.state and ("Program " .. entry.state) or "Notification"
    end
    local message = entry.message or ""
    local text = message == "" and heading
      or message == heading and message
      or (heading .. "\n\n" .. message)
    copy_feedback = hollow.clipboard.write(text) and "Copied" or "Copy failed"
  end

  local copy_keys = ui.keys({
    ["y|<C-c>"] = copy,
  })

  refresh()
  list = ui.selectable_list({
    id_prefix = "activity",
    items = function()
      return rows
    end,
    row_budget = function()
      return clay_budget
    end,
    on_activate = activate,
  })
  skip_leading_header()

  local function command(fn)
    return function(key, mods)
      if searching then
        return filter.handlers._else(key, mods)
      end
      fn()
    end
  end

  local main_keys = ui.keys(list.nav, {
    ["escape|<C-[>"] = function()
      if searching then
        searching = false
        filter.set("")
        refresh()
      else
        modal.close()
      end
    end,
    ["arrow_down|<C-j>"] = function()
      list.nav.index = util.cycle_index(list.nav.index, 1, #rows)
    end,
    ["arrow_up|<C-k>"] = function()
      list.nav.index = util.cycle_index(list.nav.index, -1, #rows)
    end,
    j = command(function()
      list.nav.index = util.cycle_index(list.nav.index, 1, #rows)
    end),
    k = command(function()
      list.nav.index = util.cycle_index(list.nav.index, -1, #rows)
    end),
    tab = function()
      set_view(view == "inbox" and "history" or "inbox")
    end,
    h = command(function()
      set_view("history")
    end),
    i = command(function()
      set_view("inbox")
    end),
    ["r|t"] = command(function()
      toggle_category("tasks")
    end),
    c = command(function()
      toggle_category("commands")
    end),
    space = command(function()
      local entry = rows[list.nav.index]
      if entry and entry.header_category then
        toggle_category(entry.header_category)
      end
    end),
    d = command(dismiss),
    ["<C-d>"] = function()
      hollow.activity.dismiss_all()
      refresh()
    end,
    v = command(inspect),
    y = command(copy),
    ["<C-c>"] = copy,
    enter = function()
      activate(list.nav.index)
    end,
    slash = function(key, mods)
      if searching then
        return filter.handlers._else(key, mods)
      end
      searching = true
    end,
    backspace = function()
      if searching then
        filter.handlers.backspace()
      end
    end,
    _else = function(key, mods)
      if searching then
        return filter.handlers._else(key, mods)
      end
      return false
    end,
  })

  local function render_details()
    return ui.column({
      ui.row({
        ui.text("Activity details", styles(theme).title),
        ui.spacer(),
        ui.action_button({
          id = "activity:copy",
          text = copy_feedback or "Copy",
          theme = theme,
          style = styles(theme).label,
          on_click = copy,
        }),
      }),
      ui.divider(theme.divider),
      detail_view.render(theme),
      ui.divider(theme.divider),
      hint_row(theme, "↑/↓ scroll   PgUp/PgDn page   y/Ctrl-C copy   Esc back"),
    })
  end

  local function render_header()
    local summary = hollow.activity.summary()
    local worst
    for _, entry in ipairs(hollow.activity.list({ view = "inbox" })) do
      if (LEVEL_RANK[entry.level] or 0) > (LEVEL_RANK[worst] or 0) then
        worst = entry.level
      end
    end
    return ui.row({
      ui.text("Activity  ", styles(theme).title),
      ui.tab_bar({
        theme = theme,
        tabs = {
          {
            id = "activity:inbox",
            label = "Inbox",
            active = view == "inbox",
            badge = summary.count > 0 and {
              text = tostring(summary.count),
              color = BADGE_LEVELS[worst] and theme.notify_levels[worst] or theme.title,
            } or nil,
            on_click = function()
              return set_view("inbox")
            end,
          },
          {
            id = "activity:history",
            label = "History",
            active = view == "history",
            on_click = function()
              return set_view("history")
            end,
          },
        },
      }),
      ui.spacer(),
      ui.when(summary.count > 0, function()
        return ui.action_button({
          id = "activity:dismiss-all",
          text = "Dismiss all",
          theme = theme,
          style = styles(theme).muted,
          on_click = function()
            return hollow.activity.dismiss_all()
          end,
        })
      end, function()
        return ui.text("")
      end),
    })
  end

  local function measure_columns()
    -- Fixed-width trailing columns keep pills and ages aligned across rows.
    local pill_cap = math.min(20, math.floor(width / 4))
    local pill_width, time_width = 0, 0
    for _, entry in ipairs(rows) do
      if not entry.header_category then
        pill_width = math.max(
          pill_width,
          util.display_width(util.truncate_end(entry.workspace or "", pill_cap))
        )
        time_width = math.max(time_width, util.display_width((age(entry))))
      end
    end
    return {
      pill_cap = pill_cap,
      pill_width = pill_width,
      time_width = time_width,
      stale = theme.stale or color.darken_hex_color(theme.muted, 0.35, theme.muted),
      color_fn = require("hollow.ui.workspace.source").switcher_state().workspace_color_fn,
    }
  end

  local function render_category_row(entry, row_state)
    local selected, hovered = row_state.selected, row_state.hovered
    local s = styles(theme, { selected = selected })
    return ui.row({
      ui.text("  ", list_row(theme, { selected = selected }).section_indicator),
      ui.text((entry.expanded and icons.expanded or icons.collapsed) .. " ", s.category_arrow),
      ui.text(entry.title, s.category_title),
      ui.text(" (" .. entry.count .. ")", s.category_count),
    }, row_state.options)
  end

  local function render_workspace_pill(entry, workspace, columns)
    return ui.when(columns.pill_width > 0, function()
      return ui.when(workspace ~= "", function()
        local colors = shared.workspace_colors(entry.workspace, columns.color_fn)
        return {
          ui.text(workspace, ui.style(styles(theme).pill, { fg = colors.fg, bg = colors.bg })),
          ui.text(string.rep(" ", columns.pill_width - util.display_width(workspace))),
        }
      end, function()
        return ui.text(string.rep(" ", columns.pill_width), styles(theme).pill_gap)
      end)
    end)
  end

  local function render_dismiss_button(entry, row_state)
    return ui.when(entry.pending, function()
      return ui.action_button({
        id = "activity:dismiss:" .. entry.id,
        text = "×",
        theme = theme,
        style = styles(theme, { selected = row_state.selected }).dismiss,
        on_click = function()
          return hollow.activity.dismiss(entry.id)
        end,
      })
    end, function()
      return ui.text(" ", styles(theme).dismiss_gap)
    end)
  end

  local function render_entry_row(entry, row_state, columns)
    local selected, hovered = row_state.selected, row_state.hovered
    local workspace = util.truncate_end(entry.workspace or "", columns.pill_cap)
    local time, seconds = age(entry)
    local indent = row_group[entry] and "  " or ""
    local reserved = 11
      + util.display_width(indent)
      + columns.time_width
      + (columns.pill_width > 0 and columns.pill_width + 4 or 0)
      + (entry.pane_closed and 13 or 0)
    local budget = math.max(8, width - reserved)
    local primary, secondary = row_parts(entry)
    primary = util.truncate_end(primary, budget)
    local rest = budget - util.display_width(primary) - 3
    secondary = secondary and rest > 0 and util.truncate_end(secondary, rest) or nil
    local entry_s = entry_styles(theme, entry, row_state, columns, seconds)
    return ui.row({
      ui.text("  ", list_row(theme, { selected = selected }).indicator),
      ui.text(indent),
      ui.text(marker(entry), entry_s.marker),
      ui.text(primary, entry_s.primary),
      ui.text(secondary and " · " or "", styles(theme).muted),
      ui.text(secondary or "", entry_s.secondary),
      ui.spacer(),
      ui.text(entry.pane_closed and "pane closed  " or "", entry_s.stale),
      render_workspace_pill(entry, workspace, columns),
      ui.text(
        "  " .. string.rep(" ", columns.time_width - util.display_width(time)) .. time,
        entry_s.time
      ),
      ui.text("  "),
      render_dismiss_button(entry, row_state),
    }, row_state.options)
  end

  local function render_layout(render_theme, state, ctx)
    local c = ui.components
    local component = require("hollow.ui.components.select")
    local cell_h = ctx.cell_h or 19
    local function line(node)
      return component.inline(
        node.children,
        nil,
        { width = "grow", height = cell_h, scroll_x = true }
      )
    end
    if details then
      local measured = ctx.metrics and ctx.metrics["activity:details"]
      if measured then
        detail_options.row_budget = math.max(1, math.min(20, math.floor(measured.height / cell_h)))
      end
      local detail_rows = detail_view.render(theme)
      local body = {}
      for _, row in ipairs(detail_rows) do
        body[#body + 1] = c.text(
          shared.nodes_plain_text(row.children),
          { fg = theme.fg },
          { wrap = "none" }
        )
      end
      local header = render_details().children[1]
      local scrollbar = detail_rows[1] or {}
      return component.sections({
        line(header),
        c.column(body, {
          id = "activity:details",
          width = "grow",
          height = "grow",
          scroll = true,
          measure = true,
          padding = {
            left = 0,
            right = scrollbar.scrollbar_track and math.max(8, ctx.cell_w or 8) or 0,
          },
          scrollbar_id = scrollbar.scrollbar_track and scrollbar.scrollbar_id or nil,
          scrollbar_thumb_ratio = scrollbar.scrollbar_thumb_ratio,
          scrollbar_thumb_size = scrollbar.scrollbar_thumb_size,
          scrollbar_track_color = scrollbar.scrollbar_track_color,
          scrollbar_thumb_color = scrollbar.scrollbar_thumb_color,
        }),
        line(hint_row(theme, "↑/↓ scroll   PgUp/PgDn page   y/Ctrl-C copy   Esc back")),
      }, theme, cell_h),
        height * cell_h
    end
    refresh()
    local measured = ctx.metrics and ctx.metrics["activity:viewport"]
    local columns = measure_columns()
    local sample = rows[1]
      and (
        rows[1].header_category
          and render_category_row(rows[1], { selected = false, options = {} })
        or render_entry_row(
          rows[1],
          { selected = false, hovered = false, options = {}, fg = theme.fg },
          columns
        )
      )
    local row_height = sample and component.row_height(sample, ctx) or cell_h
    if measured then
      clay_budget = math.max(1, math.min(20, math.floor(measured.height / row_height)))
    end
    local viewport = list.visible_range()
    local first = math.max(1, viewport.start_idx - math.floor((23 - clay_budget) / 2))
    local last = math.min(#rows, first + 22)
    first = math.max(1, last - 22)
    local items, costs, total = {}, {}, 0
    local function count(node)
      local result = 1
      for _, child in ipairs(node.children or {}) do
        result = result + count(child)
      end
      return result
    end
    local function make_item(index, plain)
      local entry = rows[index]
      local id = "activity:item:" .. tostring(entry.id)
      local selected, hovered = index == list.nav.index, state.hovered_id == id
      local options = list_row(theme, { selected = selected, hovered = hovered }).paint
      local row_state = {
        options = options,
        selected = selected,
        hovered = hovered,
        fg = styles(theme, { selected = selected, hovered = hovered }).row.fg,
      }
      local row = entry.header_category and render_category_row(entry, row_state)
        or render_entry_row(entry, row_state, columns)
      local entry_id = entry.id
      return component.from_row(
        row,
        id,
        entry.header_category and entry.title or row_label(entry),
        theme,
        ctx,
        function()
          refresh()
          for current, candidate in ipairs(rows) do
            if candidate.id == entry_id then
              list.nav.index = current
              activate(current)
              break
            end
          end
        end,
        plain
      )
    end
    for index = first, last do
      local item = make_item(index, false)
      items[#items + 1] = item
      costs[#costs + 1] = count(item)
      total = total + costs[#costs]
    end
    local simplified = {}
    while total > component.row_budget do
      local farthest, distance
      for offset = 1, #items do
        local index = first + offset - 1
        local d = math.abs(index - list.nav.index)
        if not simplified[offset] and (not distance or d > distance) then
          farthest, distance = offset, d
        end
      end
      if not farthest then
        break
      end
      local item = make_item(first + farthest - 1, true)
      total = total - costs[farthest] + count(item)
      items[farthest], costs[farthest], simplified[farthest] = item, count(item), true
    end
    if #rows == 0 then
      items[1] = c.text(
        filter.value ~= "" and "No matching activity"
          or view == "inbox" and "All caught up"
          or "No activity recorded",
        styles(theme).empty
      )
    end
    local target = rows[reveal_start and viewport.start_idx or list.nav.index]
    local scrollbar = viewport.show_scrollbar
        and shared.serialize_row_paint({ scrollbar_track = true }, theme)
      or {}
    local children = { line(render_header()) }
    if searching then
      children[#children + 1] = c.row({
        c.text("/ ", styles(theme).label),
        require("hollow.ui.components.input")(filter, theme, ctx, true),
      }, { width = "grow" })
    end
    children[#children + 1] = c.column(items, {
      id = "activity:viewport",
      width = "grow",
      height = "grow",
      scroll = true,
      scroll_x = true,
      measure = true,
      reveal = target and ("activity:item:" .. tostring(target.id)) or nil,
      reveal_start = reveal_start,
      padding = { left = 0, right = viewport.show_scrollbar and math.max(8, ctx.cell_w or 8) or 0 },
      scrollbar_id = viewport.show_scrollbar and viewport.scrollbar_id or nil,
      scrollbar_thumb_ratio = viewport.thumb_ratio,
      scrollbar_thumb_size = viewport.thumb_size,
      scrollbar_track_color = scrollbar.scrollbar_track_color,
      scrollbar_thumb_color = scrollbar.scrollbar_thumb_color,
    })
    children[#children + 1] = line(
      copy_feedback and ui.row({ ui.text(copy_feedback, styles(theme).success) })
        or hint_row(theme, "Enter open   v details   y copy   d dismiss   / search   Tab views")
    )
    return component.sections(children, theme, cell_h), height * cell_h
  end

  modal = ui.modal({
    title = "Activity",
    theme = theme,
    width = width,
    height = opts.height,
    max_height = opts.max_height or height,
    chrome = chrome,
    backdrop = backdrop,
    theme_backdrop = opts.backdrop == nil,
    layout_events = {
      "activity:changed",
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
      "term:command_started",
      "term:command_finished",
      "config:reloaded",
      "config:changed",
      "theme:changed",
    },
    layout_refresh_after = function()
      if details then
        return nil
      end
      local now = now_ms()
      local delay
      for _, entry in ipairs(rows) do
        local timestamp = entry.started_ms or entry.timestamp_ms
        if not entry.header_category and timestamp then
          local seconds = math.max(0, math.floor((now - timestamp) / 1000))
          local interval = seconds < 60 and (entry.started_ms and 1000 or 60000)
            or seconds < 3600 and 60000
            or 3600000
          local next_delay = interval - math.max(0, now - timestamp) % interval
          delay = math.min(delay or next_delay, next_delay)
        end
        if entry.kind == "program" and entry.state == "working" then
          delay = math.min(delay or 100, 100 - now % 100)
        end
      end
      return delay
    end,
    render = render_layout,
    on_event = function(name, event)
      local consumed = (details and detail_view or list).on_event(name, event)
      if
        not details
        and consumed
        and (
          name == "overlay:scrollbar"
          or name == "overlay:scroll" and (event and event.delta or 0) ~= 0
        )
      then
        reveal_start = true
      end
      return consumed
    end,
    keys = function(key, mods)
      if not details then
        reveal_start = false
        return main_keys(key, mods)
      end
      if key == "escape" then
        details = nil
        copy_feedback = nil
        return true
      end
      if copy_keys(key, mods) ~= false then
        return true
      end
      return detail_view.keys(key, mods)
    end,
  })
  return modal
end

return ui.activity
