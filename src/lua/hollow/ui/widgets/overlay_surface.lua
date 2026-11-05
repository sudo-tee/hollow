-- Shared Clay surface construction for overlays and modal shells.
-- Hosts own lifecycle and input policy; this module only prepares their
-- frame, chrome, and single component-tree root.
local box = require("hollow.ui.style.box")
local shared = require("hollow.ui.shared")
local util = require("hollow.util")
local ui = _G.hollow.ui

local M = {}

-- Compatibility chrome fields replace whole boxes, unlike style layers.
local function chrome_for(widget, palette)
  if type(widget.style) ~= "table" then
    return shared.normalize_overlay_chrome(widget.chrome, palette) or {}
  end
  local style = util.clone_value(widget.style)
  for key, value in pairs(type(widget.chrome) == "table" and widget.chrome or {}) do
    style[key] = util.clone_value(value)
  end
  return shared.normalize_overlay_chrome(style, palette) or {}
end

-- Options only specialize the shell (modal inset, title and preferred height);
-- both overlay hosts serialize the same Clay tree.
function M.create(widget, opts)
  opts = opts or {}
  local align = shared.normalize_overlay_align(widget.align)
  local surface
  surface = ui.layout.new({
    theme = widget._palette,
    frame = {
      width = shared.normalize_overlay_size(widget.width),
      height = shared.normalize_overlay_size(widget.height),
      max_height = shared.normalize_overlay_size(widget.max_height),
      align_x = align:find("left") and 0 or (align:find("right") and 2 or 1),
      align_y = (align == "center" or align:find("top")) and 0
        or (align:find("bottom") and 2 or 1),
    },
    render = function(ctx)
      local palette = widget._palette or shared.palette(widget._kind or "overlay")
      local chrome = chrome_for(widget, palette)
      surface.frame.margin = box.normalize(chrome.margin)

      local content, preferred_height
      if opts.render then
        content, preferred_height = opts.render(ctx)
      else
        content = widget.render(ctx)
      end
      local panel_props = {
        id = "dialog",
        label = opts.label,
        theme = palette,
        ctx = ctx,
        inset = opts.inset or "overlay",
        -- Modal panels use their own inset; overlays pass explicit padding.
        padding = opts.inset and nil or chrome.padding,
        -- A toast group paints its own chrome inside this root.
        chrome = widget._notify and false or chrome,
        content,
      }
      local panel = ui.components.panel(panel_props)
      if opts.after_panel then
        opts.after_panel(ctx, panel, preferred_height, surface)
      end
      return panel
    end,
  })
  return surface
end

return M
