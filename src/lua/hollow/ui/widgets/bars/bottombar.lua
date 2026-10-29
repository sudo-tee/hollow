local color = require("hollow.color")
local shared = require("hollow.ui.shared")
local styles = require("hollow.ui.styles.bottombar")
local hollow = _G.hollow
local state = require("hollow.state").get()
local ui = hollow.ui
local tbl = hollow.tbl
local M = {}
function M.leader_state()
  local value = hollow.keymap.get_leader_state()
  return value and value.active and value or nil
end

function M.copy_mode_state()
  local value = state.copy_mode
  return value and value.active == true and value or nil
end

function M.quick_select_state()
  local value = state.quick_select
  return value and value.active == true and value or nil
end

local function special_mode_theme()
  local resolved = shared.resolve_theme().ui
  local all = resolved.widgets.all
  local base_bg = color.normalize_hex_color(all.panel_bg, resolved.top_bar.background)
  local mode_copy_bg =
    color.normalize_hex_color(color.brighten_hex_color(base_bg, 0.08, base_bg), base_bg)
  local mode_leader_bg =
    color.normalize_hex_color(color.darken_hex_color(base_bg, 0.04, base_bg), base_bg)
  local hint_key_bg =
    color.normalize_hex_color(color.brighten_hex_color(base_bg, 0.14, base_bg), base_bg)
  return {
    bg = color.normalize_hex_color(
      resolved.status and resolved.status.bg,
      resolved.top_bar.background
    ),
    fg = color.normalize_hex_color(resolved.status and resolved.status.fg, all.title),
    chip_bg = base_bg,
    chip_fg = color.normalize_hex_color(all.fg, resolved.status and resolved.status.fg),
    accent = color.normalize_hex_color(resolved.accent, all.title),
    muted = color.normalize_hex_color(all.muted, all.fg),
    divider = color.normalize_hex_color(all.divider, resolved.status and resolved.status.fg),
    counter = color.normalize_hex_color(all.counter, all.muted),
    styles = all.styles,
    copy_bg = mode_copy_bg,
    quick_select_bg = color.normalize_hex_color(
      color.brighten_hex_color(base_bg, 0.12, base_bg),
      base_bg
    ),
    leader_bg = mode_leader_bg,
    hint_key_bg = hint_key_bg,
  }
end

local function special_mode_chip(text, theme, kind)
  return ui.span(text, styles(theme, { variant = kind }).chip)
end

local function special_mode_key(text, theme)
  return ui.span(text, styles(theme).key)
end

local function special_mode_hint(key, label, theme)
  return {
    special_mode_key(key, theme),
    ui.span(" " .. label .. " ", styles(theme).label),
  }
end

local function copy_mode_search_chip(copy_mode, theme)
  local s = styles(theme)
  return ui.group({
    special_mode_key("/", theme),
    ui.span(copy_mode.query ~= "" and copy_mode.query or "search", s.query),
    ui.when(copy_mode.match_count > 0, function()
      return ui.span(
        string.format("  %d/%d", copy_mode.match_index or 0, copy_mode.match_count),
        s.counter
      )
    end, function()
      return ui.when(copy_mode.query ~= "", function()
        return ui.span("  0/0", s.counter)
      end)
    end),
    ui.when(copy_mode.selecting, function()
      return ui.span(copy_mode.block and "  BLK" or "  SEL", s.selection)
    end),
    ui.span(" "),
  }, s.search)
end

local function special_mode_legend(copy_mode, quick_select, theme)
  local leader = copy_mode == nil and quick_select == nil and M.leader_state() or nil
  local hints = copy_mode ~= nil
      and {
        special_mode_hint("h/j/k/l", "move", theme),
        special_mode_hint("gg/G", "ends", theme),
        special_mode_hint("v", "sel", theme),
        special_mode_hint("C-v", "blk", theme),
        special_mode_hint("n/N", "match", theme),
        special_mode_hint("y", "copy", theme),
        special_mode_hint("q", "exit", theme),
      }
    or quick_select ~= nil and {
      special_mode_hint("a-z", "choose", theme),
      special_mode_hint("Backspace", "undo", theme),
      special_mode_hint("Esc", "exit", theme),
    }
    or (leader ~= nil and leader.next_display and #leader.next_display > 0) and tbl(leader.next_display)
      :map(function(item)
        local key, label = item:match("^([^:]+):(.+)$")
        return special_mode_hint(key or item, label or "", theme)
      end)
      :get()
    or {}

  return ui.bar.custom({
    id = copy_mode ~= nil and "mode:copy-legend"
      or quick_select ~= nil and "mode:quick-select-legend"
      or "mode:leader-legend",
    cache_ttl_ms = leader ~= nil and math.max(1, tonumber(leader.remaining_ms) or 0) or nil,
    render = function()
      return shared.normalize_inline_nodes(hints)
    end,
  })
end

function M.widget()
  local theme = special_mode_theme()
  return ui.new_widget("bottombar", {
    height = shared.resolve_topbar_theme().height,
    style = { bg = theme.chip_bg },
    layout = {
      padding = { left = 1, right = 1, top = 0, bottom = 0 },
    },
    render = function()
      local copy_mode = M.copy_mode_state()
      local quick_select = copy_mode == nil and M.quick_select_state() or nil
      local leader = copy_mode == nil and quick_select == nil and M.leader_state() or nil
      if copy_mode == nil and quick_select == nil and leader == nil then
        return {}
      end

      local mode_items
      if copy_mode ~= nil then
        mode_items = {
          ui.bar.custom({
            id = "mode:copy",
            render = function()
              return special_mode_chip(" COPY ", theme, "copy")
            end,
          }),
          ui.bar.custom({
            id = "mode:search",
            render = function()
              return copy_mode_search_chip(copy_mode, theme)
            end,
          }),
        }
      elseif quick_select ~= nil then
        mode_items = {
          ui.bar.custom({
            id = "mode:quick-select",
            render = function()
              return special_mode_chip(" QUICK SELECT ", theme, "quick_select")
            end,
          }),
          ui.bar.custom({
            id = "mode:quick-select-action",
            render = function()
              return special_mode_chip(
                " " .. (quick_select.action == "copy" and "copy" or "open/copy") .. " ",
                theme,
                "action"
              )
            end,
          }),
        }
      elseif leader ~= nil then
        mode_items = {
          ui.bar.custom({
            id = "mode:leader",
            render = function()
              return special_mode_chip(" LEADER ", theme, "leader")
            end,
          }),
        }
      end

      return tbl(mode_items)
        :concat({ ui.spacer(), special_mode_legend(copy_mode, quick_select, theme) })
        :get()
    end,
  })
end

function M.visible_item_count(items)
  return tbl(items):count(function(item)
    return item.kind ~= "spacer"
  end)
end
return M
