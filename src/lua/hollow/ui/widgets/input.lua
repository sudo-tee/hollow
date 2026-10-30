--- Text input dialog built on the builder API.
---
--- Usage:
--- ```lua
--- hollow.ui.input.open({
---   prompt = "Enter name:",
---   default = "world",
---   on_confirm = function(value)
---     print("hello " .. value)
---   end,
--- })
--- ```
local shared = require("hollow.ui.shared")
---@type HollowUi
local ui = _G.hollow.ui

ui.input = ui.input or {}

---@param opts HollowUiInputOptions|nil
function ui.input.open(opts)
  opts = opts or {}

  local base_theme = shared.widget_theme("input", opts.theme)

  local input = ui.text_input({
    initial = opts.default,
  })

  ---@type HollowUiModalHandle
  local m

  local backdrop = opts.backdrop
  if backdrop == nil then
    backdrop = base_theme.backdrop
  end

  m = ui.modal({
    title = opts.prompt or "Text input",
    theme = base_theme,
    render = function(theme, _, ctx)
      return require("hollow.ui.components.dialog")({
        title = opts.prompt,
        body = require("hollow.ui.components.input")(input, theme, ctx),
      }, theme, ctx)
    end,
    width = opts.width,
    height = opts.height,
    chrome = opts.chrome,
    align = opts.align or "center",
    backdrop = backdrop,
    theme_backdrop = opts.backdrop == nil,
    keys = ui.keys(input, {
      enter = function()
        m.close()
        ui.fire(opts.on_confirm, input.value)
      end,
      escape = function()
        m.close()
        ui.fire(opts.on_cancel)
      end,
    }),
  })
end

function ui.input.close()
  ui.overlay.pop()
end
