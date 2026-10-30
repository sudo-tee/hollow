package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("overlay lifecycle retention", function()
  local ui, stack
  before_each(function()
    ui = harness.boot().hollow.ui
    stack = require("hollow.state").get().ui.overlay_stack
  end)

  it("releases a closed Clay palette, theme and surface after rendering", function()
    local refs = setmetatable({}, { __mode = "v" })
    local function open_and_close()
      ui.command_palette.open({
        entries = {
          { name = "example", desc = "Example", category = "general", chords = {} },
        },
      })
      local widget = assert(stack[1])
      ui._overlay_state()
      ui._layout_prepare(1200, 900, 8, 19)
      refs[1], refs[2], refs[3], refs[4] =
        widget, widget._palette, widget.chrome, widget._layout_surface
      ui.overlay.clear()
    end
    open_and_close()
    -- Compiled traces may retain recently used Lua values until flushed.
    jit.flush()
    collectgarbage("collect")
    collectgarbage("collect")
    assert.is_nil(refs[1])
    assert.is_nil(refs[2])
    assert.is_nil(refs[3])
    assert.is_nil(refs[4])
  end)

  it("preserves callbacks while another overlay remains", function()
    local clicks = 0
    local surface = ui.layout.new({
      render = function()
        return ui.layout.button({
          id = "existing",
          text = "Existing",
          on_click = function()
            clicks = clicks + 1
          end,
        })
      end,
    })
    surface:show()
    ui._layout_prepare(1200, 900, 8, 19)
    local id = surface.namespace .. "existing"
    local modal = ui.modal({
      render = function()
        return ui.layout.row({})
      end,
    })
    modal.close()
    ui._layout_prepare(1200, 900, 8, 19)
    surface:dispatch(id)
    assert.equals(1, clicks)
    surface:destroy()
  end)
end)
