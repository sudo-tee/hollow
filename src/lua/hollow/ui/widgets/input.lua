local shared = require("hollow.ui.shared")
local util   = require("hollow.util")

local hollow = _G.hollow

hollow.ui.input = hollow.ui.input or {}

function hollow.ui.input.open(opts)
  opts = opts or {}
  local theme = shared.resolve_widget_theme("input")
  if type(opts.theme) == "table" then util.merge_tables(theme, util.clone_value(opts.theme)) end
  local backdrop   = opts.backdrop ~= nil and opts.backdrop or theme.backdrop
  local state_local = { prompt = opts.prompt or "", value = opts.default or "" }

  local widget = hollow.ui.overlay.new({
    render = function()
      local t     = hollow.ui.tags
      local caret = " "
      return hollow.ui.rows(
        state_local.prompt ~= "" and hollow.ui.rows(
          t.overlay_row(nil, t.text({ fg = theme.title, bold = true }, state_local.prompt)),
          t.divider({ color = theme.divider })
        ),
        t.overlay_row(nil,
          t.text({ fg = theme.input_fg,  bg = theme.input_bg  }, state_local.value),
          t.text({ fg = theme.cursor_fg, bg = theme.cursor_bg, bold = true }, caret)
        )
      )
    end,
    width    = opts.width,
    height   = opts.height,
    chrome   = opts.chrome or { bg = theme.panel_bg, border = theme.panel_border },
    backdrop = backdrop,
    on_key   = function(key, mods)
      if key == "escape" then
        hollow.ui.overlay.pop()
        if type(opts.on_cancel) == "function" then opts.on_cancel() end
        return true
      end
      if key == "enter" then
        hollow.ui.overlay.pop()
        if type(opts.on_confirm) == "function" then opts.on_confirm(state_local.value) end
        return true
      end
      if key == "backspace" then
        state_local.value = state_local.value:sub(1, math.max(0, #state_local.value - 1))
        return true
      end
      local printable = shared.printable_char_for_key(key, mods)
      if printable ~= nil then state_local.value = state_local.value .. printable; return true end
      return false
    end,
  })
  hollow.ui.overlay.push(widget)
end

function hollow.ui.input.close() hollow.ui.overlay.pop() end
