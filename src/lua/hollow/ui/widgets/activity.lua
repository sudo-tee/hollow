local icons = require("hollow.ui.icons")
local program_status = require("hollow.program_status")
local shared = require("hollow.ui.shared")
local theme_api = require("hollow.theme")
local util = require("hollow.util")
local hollow = _G.hollow
local ui = hollow.ui

ui.activity = {}

local DEFAULT_WIDTH = 100
local DEFAULT_HEIGHT = 24
local PILL_PADDING = { left = 8, right = 8, top = 3, bottom = 3 }

local function age(timestamp)
  if not timestamp then
    return ""
  end
  local seconds = math.max(
    0,
    math.floor((util.host_now_ms(require("hollow.state").get().host_api) - timestamp) / 1000)
  )
  if seconds < 60 then
    return "now"
  end
  if seconds < 3600 then
    return math.floor(seconds / 60) .. "m"
  end
  return math.floor(seconds / 3600) .. "h"
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

local function row_label(entry)
  if entry.kind == "program" then
    local app = entry.app and entry.app ~= "" and entry.app or "Program"
    local state = entry.state or "idle"
    return (app .. " · " .. state:gsub("^%l", string.upper)):gsub("%s+", " ")
  end
  local label = title(entry)
  if entry.kind == "notification" and entry.message and entry.message ~= "" then
    label = label == "Notification" and entry.message
      or entry.message == entry.title and label
      or (label .. " · " .. entry.message)
  end
  return label:gsub("%s+", " ")
end

local function marker(entry)
  if entry.kind == "program" then
    return program_status.badge({
      {
        program_status = {
          { state = entry.state, kind = entry.block_kind, progress = entry.progress },
        },
      },
    }) or ""
  end
  return entry.kind == "bell" and (icons.bell .. " ") or "● "
end

---@param opts? HollowUiActivityOptions
---@return HollowUiModalHandle|nil
function ui.activity.open(opts)
  opts = opts or {}
  local view = opts.view or "inbox"
  assert(view == "inbox" or view == "history", "activity view must be inbox or history")
  local theme = theme_api.resolve_widget("select")
  if opts.theme then
    util.merge_tables(theme, util.clone_value(opts.theme))
  end
  local chrome = opts.chrome
  if chrome == nil then
    chrome = shared.theme_overlay_chrome(theme)
  end
  local backdrop = opts.backdrop
  if backdrop == nil then
    backdrop = theme.backdrop
  end
  local show_running = true
  local searching = false
  local width = opts.width or DEFAULT_WIDTH
  local height = opts.height or opts.max_height or DEFAULT_HEIGHT
  height = math.min(height, opts.max_height or height)
  local modal, list, details
  local copy_feedback
  local detail_view = ui.text_view({
    width = width - 6,
    row_budget = height - 4,
  })
  local rows = {}
  local filter = ui.text_input({
    on_change = function()
      if list then
        list.nav.index = 1
      end
    end,
  })

  local function refresh()
    local selected = list and rows[list.nav.index]
    local selected_id = selected and selected.id
    local entries = hollow.activity.list({ view = view })
    local running = view == "inbox" and show_running and hollow.activity.running() or {}
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
    rows = {}
    local function add(items, section)
      local first = true
      for _, entry in ipairs(items) do
        local text =
          util.words(row_label(entry), title(entry), entry.message, location(entry), entry.state)
        if filter.value == "" or shared.select_item_matches(filter.value, text, true) then
          entry.section = first and section or nil
          rows[#rows + 1] = entry
          first = false
        end
      end
    end
    add(entries)
    add(running, "Running")
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

  local function set_view(value)
    view = value
    list.nav.index = 1
    refresh()
  end

  local function activate(index)
    local entry = rows[index]
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
    details = rows[list.nav.index]
    if details then
      detail_view.set(
        title(details) .. "\n\n" .. (details.message or "") .. "\n\n" .. location(details)
      )
    end
  end

  local function copy()
    local entry = details or rows[list.nav.index]
    if not entry then
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
    row_count_fn = function(entry)
      return entry.section and 2 or 1
    end,
    row_budget = function()
      return math.max(2, height - (searching and 6 or 4))
    end,
    on_activate = activate,
  })

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
    r = command(function()
      show_running = not show_running
      refresh()
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

  modal = ui.modal({
    theme = theme,
    width = width,
    height = opts.height,
    max_height = opts.max_height or height,
    chrome = chrome,
    backdrop = backdrop,
    on_event = function(name, event)
      return (details and detail_view or list).on_event(name, event)
    end,
    keys = function(key, mods)
      if not details then
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
    render = function(_, state)
      if details then
        return ui.column(hollow
          .tbl({
            ui.row({
              ui.text("Activity details", { fg = theme.title, bold = true }),
              ui.spacer(),
              ui.button({
                id = "activity:copy",
                text = copy_feedback or "Copy",
                style = { fg = theme.title },
                on_click = copy,
              }),
            }),
            ui.divider(theme.divider),
          })
          :concat(detail_view.render(theme), {
            ui.divider(theme.divider),
            ui.row({
              ui.text(
                "↑/↓ scroll   PgUp/PgDn page   y/Ctrl-C copy   Esc back",
                { fg = theme.muted }
              ),
            }),
          })
          :get())
      end
      refresh()
      local summary = hollow.activity.summary()
      local content = {
        ui.row({
          ui.text("Activity  ", { fg = theme.title, bold = true }),
          ui.button({
            id = "activity:inbox",
            text = "Inbox (" .. summary.count .. ")",
            style = {
              fg = view == "inbox" and theme.selection_fg or theme.muted,
              bg = view == "inbox" and theme.selection_bg or nil,
              bold = view == "inbox",
              radius = 4,
              padding = PILL_PADDING,
            },
            on_click = function()
              set_view("inbox")
            end,
          }),
          ui.text("  "),
          ui.button({
            id = "activity:history",
            text = "History",
            style = {
              fg = view == "history" and theme.selection_fg or theme.muted,
              bg = view == "history" and theme.selection_bg or nil,
              bold = view == "history",
              radius = 4,
              padding = PILL_PADDING,
            },
            on_click = function()
              set_view("history")
            end,
          }),
          ui.spacer(),
          summary.count > 0 and ui.button({
            id = "activity:dismiss-all",
            text = "Dismiss all  ",
            style = { fg = theme.muted },
            on_click = function()
              hollow.activity.dismiss_all()
            end,
          }) or ui.text(""),
          ui.button({
            id = "activity:running",
            text = (show_running and icons.expanded or icons.collapsed) .. " Running",
            style = { fg = theme.muted },
            on_click = function()
              show_running = not show_running
            end,
          }),
        }),
        ui.divider(theme.divider),
      }
      if searching then
        content[#content + 1] = ui.row({
          ui.text("/ ", { fg = theme.title }),
          ui.group(filter.render(theme)),
        })
        content[#content + 1] = ui.divider(theme.divider)
      end
      local viewport = list.visible_range()
      for index = viewport.start_idx, viewport.end_idx do
        local entry = rows[index]
        local id, options = list.row(index, entry.id, index - viewport.start_idx + 1, viewport)
        local selected = index == list.nav.index
        local hovered = state.hovered_id == id
        local fg = util.state_value(selected, hovered, theme.selection_fg, theme.hover_fg, theme.fg)
        local workspace =
          util.truncate_end(entry.workspace or "", math.min(20, math.floor(width / 4)))
        local time = age(entry.timestamp_ms)
        local workspace_colors = shared.workspace_colors(
          entry.workspace or "",
          require("hollow.ui.workspace.source").switcher_state().workspace_color_fn
        )
        local reserved = 8
          + util.utf8_len(time)
          + (workspace ~= "" and util.utf8_len(workspace) + 4 or 0)
          + (entry.pane_closed and 14 or 0)
        options.fill_bg = util.state_value(selected, hovered, theme.selection_bg, theme.hover_bg)
        options.scrollbar_track_color = theme.scrollbar_track
        options.scrollbar_thumb_color = theme.scrollbar_thumb
        if entry.section then
          content[#content + 1] =
            ui.row({ ui.text(entry.section, { fg = theme.muted, bold = true }) })
        end
        content[#content + 1] = ui.row({
          ui.text(selected and "> " or "  ", { fg = fg }),
          ui.text(
            marker(entry),
            { fg = program_status.color(entry.state) or theme.notify_levels[entry.level] or fg }
          ),
          ui.text(
            util.truncate_end(row_label(entry), math.max(8, width - reserved)),
            { fg = fg, bold = selected }
          ),
          ui.spacer(),
          ui.text(entry.pane_closed and "pane closed  " or "", { fg = theme.muted }),
          ui.text(workspace, {
            fg = workspace_colors.fg,
            bg = workspace_colors.bg,
            radius = 4,
            padding = PILL_PADDING,
          }),
          ui.text(time ~= "" and ("  " .. time) or "", { fg = theme.muted }),
          ui.text("  "),
          entry.pending and ui.button({
            id = "activity:dismiss:" .. entry.id,
            text = "×",
            style = { fg = fg },
            on_click = function()
              hollow.activity.dismiss(entry.id)
            end,
          }) or ui.text(""),
        }, options)
      end
      if #rows == 0 then
        content[#content + 1] = ui.row({
          ui.text(
            filter.value ~= "" and "No matching activity"
              or view == "inbox" and "All caught up"
              or "No activity recorded",
            { fg = theme.empty }
          ),
        })
      end
      content[#content + 1] = ui.divider(theme.divider)
      content[#content + 1] = ui.row({
        ui.text(
          copy_feedback or "Enter open   v details   y copy   d dismiss   / search   Tab views",
          { fg = theme.muted }
        ),
      })
      return ui.column(content)
    end,
  })
  return modal
end

return ui.activity
