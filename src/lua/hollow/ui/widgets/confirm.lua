local shared = require("hollow.ui.shared")
local theme_api = require("hollow.theme")
local util = require("hollow.util")

local table_unpack = table.unpack or unpack

local hollow = _G.hollow
local ui = hollow.ui

ui.confirm = ui.confirm or {}

local function resolve_confirm_theme(theme, opts)
  if type(opts.theme) == "table" then
    util.merge_tables(theme, util.clone_value(opts.theme))
  end
  return theme
end

local function default_buttons()
  return {
    { text = "Yes", style = "primary", value = true },
    { text = "No", value = false },
  }
end

local function button_style(theme, btn, is_selected, is_hovered)
  local style = btn.style or "default"

  local result = {
    radius = theme.radius or 4,
  }

  if is_selected then
    result.bold = true
    if style == "primary" then
      result.fg = theme.primary_fg
      result.bg = theme.primary_bg
    elseif style == "destructive" then
      result.fg = theme.destructive_fg
      result.bg = theme.destructive_bg
    else
      result.fg = theme.selected_fg
      result.bg = util.brighten_hex_color(theme.selected_bg, 0.25, theme.panel_bg)
    end
  elseif is_hovered then
    result.bold = true
    if style == "primary" then
      result.fg = theme.primary_fg
      result.bg = theme.primary_bg
    elseif style == "destructive" then
      result.fg = theme.destructive_fg
      result.bg = theme.destructive_bg
    else
      result.fg = theme.selected_fg
      result.bg = util.brighten_hex_color(theme.selected_bg, 0.25, theme.panel_bg)
    end
  else
    if style == "primary" then
      result.fg = theme.primary_bg
    elseif style == "destructive" then
      result.fg = theme.destructive_bg
    else
      result.fg = theme.fg
    end
  end

  return result
end

local function render_confirm(theme, opts, buttons, selected_index, hovered_index)
  local tags = ui.tags
  local rows = {}

  if opts.title ~= nil and opts.title ~= "" then
    rows = ui.rows(
      tags.overlay_row(nil, tags.group(tags.text({ fg = theme.title, bold = true }, opts.title))),
      tags.divider({ color = theme.divider })
    )
  end

  rows[#rows + 1] = tags.overlay_row(nil, tags.group(tags.text({ fg = theme.fg }, opts.prompt)))
  rows[#rows + 1] = tags.overlay_row(nil, tags.text({}, " "))

  local button_nodes = {}
  button_nodes[#button_nodes + 1] = ui.spacer()
  for i, btn in ipairs(buttons) do
    if #button_nodes > 1 then
      button_nodes[#button_nodes + 1] = tags.text({}, "  ")
    end
    local style = button_style(theme, btn, i == selected_index, i == hovered_index)
    style.id = "confirm:btn:" .. i
    button_nodes[#button_nodes + 1] = tags.text(style, " " .. btn.text .. " ")
  end
  rows[#rows + 1] = tags.overlay_row(nil, table_unpack(button_nodes))

  return rows
end

function ui.confirm.open(opts)
  opts = opts or {}

  if opts.prompt == nil or opts.prompt == "" then
    error("hollow.ui.confirm.open() requires a 'prompt' string")
  end

  local theme = resolve_confirm_theme(theme_api.resolve_widget("confirm"), opts)
  local backdrop = opts.backdrop ~= nil and opts.backdrop or true
  local buttons = type(opts.buttons) == "table" and #opts.buttons > 0 and opts.buttons
    or default_buttons()
  local selected_index = 1
  local hovered_index = nil

  local function find_btn_by_id(id)
    local prefix = "confirm:btn:"
    if type(id) == "string" and id:sub(1, #prefix) == prefix then
      return tonumber(id:sub(#prefix + 1))
    end
    return nil
  end

  local widget

  local function confirm_and_close(btn)
    if type(opts.on_confirm) == "function" then
      opts.on_confirm(btn.value)
    end
    if type(btn.on_confirm) == "function" then
      btn.on_confirm(btn.value)
    end
    ui.close_overlay_widget(widget)
  end

  widget = ui.overlay.new({
    render = function()
      return render_confirm(theme, opts, buttons, selected_index, hovered_index)
    end,
    on_event = function(name, payload)
      if name == "overlay:hover" then
        local i = payload and find_btn_by_id(payload.id)
        hovered_index = i
      elseif name == "overlay:leave" then
        hovered_index = nil
      elseif name == "overlay:click" then
        local i = payload and find_btn_by_id(payload.id)
        if i then
          confirm_and_close(buttons[i])
        end
      end
    end,
    on_key = function(key, mods)
      if key == "tab" or key == "arrow_right" then
        selected_index = selected_index + 1
        if selected_index > #buttons then
          selected_index = 1
        end
        return true
      end

      if key == "arrow_left" then
        selected_index = selected_index - 1
        if selected_index < 1 then
          selected_index = #buttons
        end
        return true
      end
      if key == "enter" then
        confirm_and_close(buttons[selected_index])
        return true
      end

      if key == "escape" then
        ui.close_overlay_widget(widget)
        if type(opts.on_cancel) == "function" then
          opts.on_cancel()
        end
        return true
      end

      return false
    end,
    width = opts.width or 50,
    height = opts.height,
    chrome = opts.chrome or shared.theme_overlay_chrome(theme),
    align = opts.align or "center",
    backdrop = backdrop,
  })

  ui.overlay.push(widget)
end

function ui.confirm.close()
  ui.overlay.pop()
end
