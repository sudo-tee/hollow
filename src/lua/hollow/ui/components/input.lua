-- Two nodes plus two per run. The `behavior` (a `ui.text_input`) owns editing;
-- these are ordinary layout boxes with a caret reveal target.
---@type HollowUiComponents
local c = require("hollow.ui.components")
local color = require("hollow.color")
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")
local sheet = require("hollow.ui.style.sheet")
local util = require("hollow.util")

local PLACEHOLDER_BACKGROUND_WEIGHT = 0.55

local function placeholder_color(theme)
  local resolved = shared.resolve_tokens({
    fg = theme.input_fg or theme.fg,
    bg = theme.input_bg,
  }, theme)
  local foreground = color.normalize_hex_color(resolved.fg, nil)
  local background = color.normalize_hex_color(resolved.bg, nil)
  if not foreground or not background then
    return resolved.fg or theme.input_fg or theme.fg or theme.muted
  end

  local function channel(offset)
    local from = tonumber(foreground:sub(offset, offset + 1), 16)
    local to = tonumber(background:sub(offset, offset + 1), 16)
    return math.floor(from + (to - from) * PLACEHOLDER_BACKGROUND_WEIGHT + 0.5)
  end
  return string.format("#%02x%02x%02x", channel(2), channel(4), channel(6))
end

---@param value HollowUiInputProps
---@return HollowUiLayoutNode
return function(value)
  local options = props.split(value)
  local input = options.behavior
  assert(type(input) == "table" and type(input.render) == "function", "input requires a behavior")
  local explicit = options.theme ~= nil
  local theme, ctx = props.theme(options), props.ctx(options)
  local boxed = options.boxed ~= false
  local prefix = options.id or "input"
  local cell_h = props.cell_h(ctx)
  -- A focusable field only takes keys while focused (and its pane is), so show
  -- a hollow caret otherwise; widget-routed fields pass `focused = true`.
  local focused = options.focused
  if focused == nil then
    focused = options.focusable == false or (ctx.focus_id == prefix and ctx.focused ~= false)
  end
  options.focused = nil
  local runs = {}
  local function add_run(index, span)
    local style = explicit and shared.resolve_tokens(span.style, theme) or span.style
    runs[#runs + 1] = c.column({ c.text(span.text, style, { wrap = "none" }) }, {
      id = index == 2 and (prefix .. ":caret") or nil,
      height = cell_h,
      style = style,
    })
  end
  local placeholder = options.placeholder
  assert(placeholder == nil or type(placeholder) == "string", "input placeholder must be a string")
  local rendered = input.render(theme, { focused = focused })
  if placeholder and placeholder ~= "" and input.value == "" then
    local clusters = util.text_graphemes(placeholder)
    local first = clusters[1] and clusters[1].text or placeholder
    local remainder = placeholder:sub(#first + 1)
    local hint_style = { fg = placeholder_color(theme), bg = theme.input_bg }
    local spans = {}
    for index, span in ipairs(rendered) do
      spans[index] = span
    end
    if spans[2] then
      -- Put first hint grapheme under the normal inverse/hollow caret cell.
      spans[2] = { text = first, style = spans[2].style }
      if remainder ~= "" then
        spans[#spans + 1] = {
          text = remainder,
          style = hint_style,
        }
      end
    else
      spans[#spans + 1] = {
        text = placeholder,
        style = hint_style,
      }
    end
    rendered = spans
  end
  for index, span in ipairs(rendered) do
    add_run(index, span)
  end
  options.width = options.width or "grow"
  options.padding = options.padding or (boxed and { x = props.cell_w(ctx) * 0.5, y = 2 } or nil)
  local default_style = boxed and { bg = theme.input_bg } or nil
  options.style = options.style and sheet.merge(default_style, options.style) or default_style
  if explicit and options.style then
    options.style = shared.resolve_tokens(options.style, theme)
  end
  -- Tab focuses the field; a focused field receives keys before its widget.
  if options.focusable ~= false then
    options.id, options.focusable = prefix, true
    options.on_key = options.on_key or require("hollow.ui.keys").keys(input)
  end
  return c.column({
    c.row(runs, {
      id = prefix .. ":viewport",
      width = "grow",
      height = cell_h,
      scroll_x = true,
      reveal = prefix .. ":caret",
    }),
  }, options)
end
