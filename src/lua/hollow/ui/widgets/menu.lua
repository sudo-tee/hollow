local hollow = _G.hollow
local ui = hollow.ui
local color = require("hollow.color")
local shared = require("hollow.ui.shared")
local state = require("hollow.state").get()
local util = require("hollow.util")
local M = {}
local active

local function clamp(value, high)
  return math.max(0, math.min(value, high))
end

-- Fade toward the panel instead of using the theme's potentially chromatic
-- "muted" accent, which can make unavailable actions look like links.
local function fade(fg, bg, opacity)
  if not color.is_hex_color(fg) or not color.is_hex_color(bg) then
    return fg
  end
  local function channel(i)
    local front = tonumber(fg:sub(i, i + 1), 16)
    local back = tonumber(bg:sub(i, i + 1), 16)
    return math.floor(back + (front - back) * opacity + 0.5)
  end
  return string.format("#%02x%02x%02x", channel(2), channel(4), channel(6))
end

-- Mirror open menu surfaces natively so mouse routing avoids the Lua lock.
local function sync()
  if state.host_api.menu_surfaces then
    state.host_api.menu_surfaces(ui._menu_surface_id, ui._submenu_surface_id)
  end
end

function M.fit(text, cells)
  local clusters = util.text_graphemes(text)
  local width = 0
  for _, cluster in ipairs(clusters) do
    width = width + cluster.width
  end
  if width <= cells then
    return text
  end
  local parts = {}
  cells = cells - 1
  for _, cluster in ipairs(clusters) do
    if cluster.width > cells then
      break
    end
    cells = cells - cluster.width
    parts[#parts + 1] = cluster.text
  end
  return cells >= 0 and table.concat(parts) .. "…" or ""
end

function M.place(anchor, area, width, height)
  local x, y = anchor.x - area.x, anchor.y - area.y
  local right, bottom = x + (anchor.width or 0), y + (anchor.height or 0)
  x = x + width > area.width and right - width or x
  y = bottom + height > area.height and y - height or bottom
  return clamp(x, area.width - width), clamp(y, area.height - height)
end

function M.place_submenu(anchor, area, width, height)
  local left = anchor.x - area.x
  local right = left + anchor.width
  local x = right + width <= area.width and right or left - width
  return clamp(x, area.width - width), clamp(anchor.y - area.y, area.height - height)
end

function M.close(reason)
  if active then
    active.close(reason or "invalidated")
  end
end

local function open_level(spec, parent)
  local stack = state.ui.overlay_stack
  for _, widget in ipairs(stack) do
    if widget._exclusive then
      return
    end
  end
  if #spec.items == 0 or (spec.valid and not spec.valid()) then
    return
  end
  if not parent then
    M.close()
    if hollow.keymap.cancel then
      hollow.keymap.cancel()
    end
  end

  local menu, first, visible, selected = {}, 1, 1, nil
  local widget, surface, close_reason, child
  local anchors = {}
  local has_icons = false
  local has_submenus = false
  for _, item in ipairs(spec.items) do
    has_icons = has_icons or (item.icon and item.icon ~= "")
    has_submenus = has_submenus or (not parent and item.submenu and #item.submenu > 0)
  end
  local function valid()
    return ui._menu_anchor_bounds ~= false and (not spec.valid or spec.valid())
  end
  local function enabled(i)
    local item = spec.items[i]
    return item
      and not item.separator
      and not item.disabled
      and ((not parent and item.submenu and #item.submenu > 0) or type(item.action) == "function")
  end
  function menu.close(reason)
    if surface.destroyed then
      return
    end
    if child then
      child.close()
      child = nil
    end
    close_reason = valid() and reason or "invalidated"
    ui.overlay.remove(widget)
  end
  local function redraw()
    surface:invalidate()
    if state.host_api.request_redraw then
      state.host_api.request_redraw()
    end
  end
  local function activate(i)
    if not valid() then
      M.close()
    elseif enabled(i) then
      local item = spec.items[i]
      if not parent and item.submenu and #item.submenu > 0 then
        if child then
          child.close()
          child = nil
        end
        if anchors[i] then
          selected = i
          child = open_level({
            items = item.submenu,
            anchor = anchors[i],
            current_anchor = function()
              return anchors[i]
            end,
            valid = valid,
          }, menu)
          redraw()
        end
      else
        M.close("selection")
        item.action()
      end
    end
  end
  local function move(direction)
    local count = #spec.items
    local i = selected or (direction == 1 and 0 or 1)
    for _ = 1, count do
      i = (i - 1 + direction) % count + 1
      if enabled(i) then
        selected = i
        first = math.max(i - visible + 1, math.min(first, i))
        break
      end
    end
  end
  if parent then
    move(1)
  end
  widget = ui.overlay.new({
    render = function() end,
    on_unmount = function()
      if parent then
        ui._submenu_surface_id = nil
        sync()
        if state.host_api.request_redraw then
          state.host_api.request_redraw()
        end
      elseif active == menu then
        active, ui._menu_surface_id, ui._menu_anchor_id, ui._menu_anchor_bounds = nil, nil, nil, nil
        sync()
        if state.host_api.request_redraw then
          state.host_api.request_redraw()
        end
        if spec.on_close then
          spec.on_close(close_reason or "invalidated")
        end
      end
    end,
    on_key = function(key)
      if not valid() then
        M.close()
      elseif key == "escape" then
        menu.close("escape")
      elseif key == "left" and parent then
        menu.close()
      elseif key == "up" or key == "down" then
        move(key == "up" and -1 or 1)
        redraw()
      elseif
        key == "enter"
        or (
          key == "right"
          and not parent
          and spec.items[selected or 0]
          and spec.items[selected].submenu
        )
      then
        activate(selected or 0)
      end
      return true
    end,
    on_event = function(name, payload)
      if name == "overlay:invalidate_menu" then
        M.close()
      elseif name == "overlay:outside" then
        M.close("outside")
      elseif name == "overlay:menu_background" and child then
        child.close()
        child = nil
      elseif name == "overlay:scroll" then
        if child then
          child.close()
          child = nil
        end
        first = 1 + clamp(first - 1 + (payload.delta > 0 and -3 or 3), #spec.items - visible)
        selected = nil
        redraw()
      end
    end,
  })
  local frame = { align_x = 0, align_y = 0, pixels = true }
  surface = ui.layout.new({
    frame = frame,
    render = function(ctx)
      local area = ui._menu_area or { x = 0, y = 0, width = ctx.width, height = ctx.height }
      local inset = math.max(0, math.min(5, math.floor((area.height - 1) / 2)))
      local available = math.max(1, area.height - 2 * inset)
      local row = math.max(1, math.min(available, math.ceil(ctx.cell_h * 1.4)))
      local separator = math.min(row, math.max(1, math.floor(ctx.cell_h * 0.55)))
      visible =
        math.max(1, math.min(has_submenus and 80 or 120, #spec.items, math.floor(available / row)))
      first = 1 + clamp(first - 1, #spec.items - visible)
      if selected then
        first = math.max(selected - visible + 1, math.min(first, selected))
      end
      local width =
        math.min(area.width, math.max(parent and 115 or 170, ctx.cell_w * (parent and 16 or 27)))
      local height = 2 * inset
      for i = first, first + visible - 1 do
        height = height + (spec.items[i].separator and separator or row)
      end
      local place = parent and M.place_submenu or M.place
      local anchor = (not parent and ui._menu_anchor_bounds)
        or (spec.current_anchor and spec.current_anchor())
        or spec.anchor
      local x, y = place(anchor, area, width, height)
      frame.width, frame.height, frame.margin = width, height, { left = x, top = y }
      local palette = shared.palette("select")
      local disabled_fg = fade(palette.fg, palette.panel_bg, 0.52)
      local divider = fade(palette.panel_border, palette.panel_bg, 0.45)
      local c, rows = ui.components, {}
      local row_pad = math.max(0, math.min(10, math.floor((width - 2 * inset - 1) / 4)))
      local icon_width = has_icons and math.ceil(ctx.cell_w * 2.75) or 0
      local arrow_width = has_submenus and math.ceil(ctx.cell_w * 2) or 0
      local label_cells = math.max(
        1,
        math.floor((width - 2 * (inset + row_pad) - icon_width - arrow_width) / ctx.cell_w)
      )
      local row_y = y + inset
      anchors = {}
      for i = first, first + visible - 1 do
        local item = spec.items[i]
        local index = i
        if item.separator then
          rows[#rows + 1] = c.column({
            c.row({}, { width = "grow", height = 1, style = { bg = divider } }),
          }, {
            width = "grow",
            height = separator,
            align_y = "center",
            padding = { left = row_pad, right = row_pad },
          })
          row_y = row_y + separator
        else
          anchors[i] = { x = area.x + x, y = area.y + row_y - inset, width = width }
          row_y = row_y + row
          local enabled_row = enabled(i)
          local fg = enabled_row and (selected == i and palette.selection_fg or palette.fg)
            or disabled_fg
          local children = {}
          if has_icons then
            children[1] = c.column({
              c.text(item.icon or "", { fg = fg }, { wrap = "none" }),
            }, { width = icon_width })
          end
          children[#children + 1] = c.text(
            M.fit(item.label, label_cells),
            { fg = fg },
            { wrap = "none" }
          )
          if has_submenus then
            children[#children + 1] = c.row({}, { width = "grow" })
            if item.submenu and #item.submenu > 0 then
              children[#children + 1] = c.text("›", { fg = fg }, { wrap = "none" })
            end
          end
          rows[#rows + 1] = c.row(children, {
            id = "row-" .. i,
            role = "listitem",
            label = item.label,
            width = "grow",
            height = row,
            align_y = "center",
            padding = { left = row_pad, right = row_pad },
            style = {
              radius = 4,
              bg = selected == i and palette.selection_bg or nil,
              hover = enabled_row and { bg = palette.hover_bg, fg = palette.hover_fg } or nil,
            },
            disabled = not enabled_row,
            on_click = function()
              activate(index)
            end,
          })
        end
      end
      return c.panel({
        id = "menu",
        inset = "none",
        padding = inset,
        theme = palette,
        ctx = ctx,
        rows,
      })
    end,
  })
  widget._layout_surface = surface
  widget._layout_live = true
  widget._layout_visible = valid
  if parent then
    ui._submenu_surface_id = surface.id
  else
    active, ui._menu_surface_id = menu, surface.id
    ui._menu_anchor_id = spec.anchor_id
  end
  sync()
  ui.overlay.push(widget)
  redraw()
  return menu
end

function M.open(spec)
  return open_level(spec)
end

return M
