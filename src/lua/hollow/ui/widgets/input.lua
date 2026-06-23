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
local util = require("hollow.util")
local theme_api = require("hollow.theme")
local w = require("hollow.ui.builder")

local ui = _G.hollow.ui

ui.input = ui.input or {}

---@param opts HollowUiInputOptions|nil
function ui.input.open(opts)
  opts = opts or {}

  local base_theme = theme_api.resolve_widget("input")
  if type(opts.theme) == "table" then
    util.merge_tables(base_theme, util.clone_value(opts.theme))
  end

  local input = w.text_input({
    initial = opts.default,
  })

  local m

  m = w.modal({
    theme = base_theme,
    render = function(theme)
      return w.dialog({
        title = opts.prompt,
        body = {
          input.render(theme),
        },
      }, theme)
    end,
    width = opts.width,
    height = opts.height,
    chrome = opts.chrome,
    align = opts.align or "center",
    backdrop = opts.backdrop ~= nil and opts.backdrop or base_theme.backdrop,
    keys = w.keys(
      input,
      {
        enter = function()
          m.close()
          w.fire(opts.on_confirm, input.value)
        end,
        escape = function()
          m.close()
          w.fire(opts.on_cancel)
        end,
      }
    ),
  })
end

function ui.input.close()
  ui.overlay.pop()
end
